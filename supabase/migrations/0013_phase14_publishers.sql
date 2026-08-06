-- Bite · Phase 14: publisher-direct ingestion.
-- Run in the SQL editor AFTER deploying the "ingest-rss" Edge Function:
--   supabase secrets set --env-file supabase/functions/.env.secrets
--   supabase functions deploy ingest-rss --no-verify-jwt
--   supabase functions deploy summarize-articles --no-verify-jwt   (reworked)
--   supabase functions deploy match-trackers --no-verify-jwt       (reworked)
--
-- Adds multi-source ingestion from publisher RSS feeds alongside Guardian.
-- The governing principle is that Bite is a REFERRER, not a replacement:
-- every publisher here is link-out only (full_text_available stays false, so
-- the Phase 6 router sends them to the in-app browser), their bite is capped
-- at 80 words in code, and their name and canonical URL are NOT NULL.
--
-- Guardian is untouched: it keeps its own ingest function, its native reader,
-- and its existing rows. Nothing in this migration changes the Guardian path.
--
-- Part F (referral_events + CTR reporting) lives in 0014.

-- ---------------------------------------------------------------------------
-- Part A — the publisher registry.
--
-- Version-controlled so the source list is reviewable, and so the ONE
-- operation that matters under time pressure — disabling a publisher — is a
-- single UPDATE against a table, not a redeploy:
--
--     update public.publishers set enabled = false where id = 'thehindu';
--
-- That takes effect on the next ingest cycle AND immediately hides their
-- existing cards, because get_personalized_feed (below) joins this table on
-- every read. Saved articles are deliberately NOT hidden — see the note on
-- the feed function.
--
-- full_text_allowed is set ONLY from a robots.txt check (refreshed by
-- ingest-rss every ROBOTS_CACHE_HOURS). There is no override flag, by design:
-- a publisher that disallows our crawler is RSS-description-only, full stop.
-- ---------------------------------------------------------------------------

create table if not exists public.publishers (
  id                  text primary key,              -- stable slug
  name                text not null,                 -- display attribution
  canonical_domain    text not null unique,
  rss_url             text not null,
  -- Kill switch. New publishers start DISABLED: adding a row is not the same
  -- decision as turning it on.
  enabled             boolean not null default false,
  -- Derived from robots.txt only. Never hand-set to true.
  full_text_allowed   boolean not null default false,
  robots_checked_at   timestamptz,
  robots_crawl_delay  double precision,              -- seconds, publisher-stated
  -- Parsed robots.txt rules for this domain, cached so a run doesn't refetch:
  -- [{"allow": bool, "pattern": "/path"}, ...]
  robots_rules        jsonb not null default '[]'::jsonb,
  region              text not null default 'GLOBAL'
                        check (region in ('IN', 'GLOBAL')),
  -- This publisher's ceiling within MAX_ARTICLES_PER_RUN_TOTAL. The global
  -- cap and round-robin fair share are the real limiters; this stops one
  -- high-volume outlet taking the whole run on a quiet cycle.
  max_per_run         integer not null default 3 check (max_per_run > 0),
  notes               text,
  created_at          timestamptz not null default now()
);

-- Publisher name and domain are public information — they are printed on every
-- card. The feed RPC is SECURITY INVOKER, so it needs this readable by the
-- calling user to enforce the kill switch. Read-only: only the service role
-- (ingest-rss) writes robots state, and only an operator flips `enabled`.
alter table public.publishers enable row level security;

create policy "publishers: select" on public.publishers
  for select to authenticated using (true);

grant select on public.publishers to authenticated;

-- ---------------------------------------------------------------------------
-- Seed: ONLY publishers that passed tools/qualify_publisher.dart, with their
-- reports committed under docs/publishers/. Checked 2026-07-25.
--
-- The slate is 4 IN + 4 GLOBAL, spread deliberately across the political
-- spectrum (balance is a spread of perspectives, not a hunt for bias-free
-- outlets — those don't exist). docs/publishers/README.md records the lean of
-- each and, honestly, the gap: no right-of-centre Indian outlet qualified,
-- because all four tested failed on missing feeds, not editorial grounds.
--
-- Every row lands DISABLED. Enable deliberately, after checking the reports:
--     update public.publishers set enabled = true where id in ('...');
--
-- full_text_allowed is seeded from the qualification robots check and is
-- re-derived by ingest-rss on every ROBOTS_CACHE_HOURS refresh.
-- ---------------------------------------------------------------------------

insert into public.publishers
  (id, name, canonical_domain, rss_url, region, max_per_run,
   full_text_allowed, notes)
values
  ('thehindu', 'The Hindu', 'thehindu.com',
   'https://www.thehindu.com/feeder/default.rss', 'IN', 3, false,
   'Qualified 2026-07-25. Description-only: article pages are paywalled, so no body fetch is attempted. ~271 items/day — capped low so it cannot crowd the slate.'),
  ('newindianexpress', 'The New Indian Express', 'newindianexpress.com',
   'https://www.newindianexpress.com/feed', 'IN', 3, false,
   'Qualified 2026-07-25. RSS carries full content. Article pages are paywalled ("premium article"), so full_text_allowed stays false. ~183 items/day.'),
  ('deccanherald', 'Deccan Herald', 'deccanherald.com',
   'https://www.deccanherald.com/feed', 'IN', 5, false,
   'Qualified 2026-07-25. RSS carries full content; no body fetch needed. ~33 items/day.'),
  ('scroll', 'Scroll.in', 'scroll.in',
   'https://feeds.feedburner.com/ScrollinArticles.rss', 'IN', 5, true,
   'Qualified 2026-07-25. robots.txt allows article paths and an honest fetch returned a real body. RSS already carries full content, so the body fetch is rarely needed. Feed is on feedburner.com — that host''s robots.txt governs the feed fetch.'),
  ('aljazeera', 'Al Jazeera', 'aljazeera.com',
   'https://www.aljazeera.com/xml/rss/all.xml', 'GLOBAL', 4, false,
   'Qualified 2026-07-25. Description-only. ~60 items/day.'),
  ('dw', 'Deutsche Welle', 'dw.com',
   'https://rss.dw.com/rdf/rss-en-all', 'GLOBAL', 5, true,
   'Qualified 2026-07-25. robots.txt allows article paths; honest fetch returned a real body. The ONLY publisher that routinely exercises the Part C body fetch (its RSS is description-only). Feed host is rss.dw.com.'),
  ('csmonitor', 'The Christian Science Monitor', 'csmonitor.com',
   'https://rss.csmonitor.com/feeds/all', 'GLOBAL', 5, false,
   'Qualified 2026-07-25. Description-only: article pages hit "subscribe to continue". robots.txt states Crawl-delay: 1s. ~9 items/day.'),
  ('reason', 'Reason', 'reason.com',
   'https://reason.com/feed/', 'GLOBAL', 5, false,
   'Qualified 2026-07-25. RSS carries full content; no body fetch needed. ~25 items/day.')
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- Article columns for RSS rows.
--
--   publisher_id       FK to the registry; NULL for Guardian / mock. This is
--                      what the kill switch and CTR reporting hang off.
--   rss_categories     the feed's own <category> values. Deliberately kept
--                      SEPARATE from `tags` — see run_tracker_matching below;
--                      mixing RSS categories into Guardian tag space would
--                      silently break tracker matching.
--   summary_input_mode 'body' | 'description' — which input produced the bite,
--                      recorded so summary quality can be compared later.
--
-- ON DELETE SET NULL, not CASCADE: removing a publisher row must never delete
-- articles that users have saved or that trackers reference.
-- ---------------------------------------------------------------------------

alter table public.articles
  add column if not exists publisher_id       text
    references public.publishers (id) on delete set null,
  add column if not exists rss_categories     text[] not null default '{}',
  add column if not exists summary_input_mode text;

create index if not exists articles_publisher_idx
  on public.articles (publisher_id) where publisher_id is not null;

-- ---------------------------------------------------------------------------
-- RSS body text, fetched under Part C for SUMMARISATION ONLY.
--
-- Structurally unreachable from the client: RLS on with NO policies, no grants
-- — only the service role can read it. This is why RSS bodies are not stored
-- in article_bodies (which the reader's guardian-body proxy serves): there
-- must be no path by which a non-Guardian body can reach the native reader.
-- Rows are deleted as soon as the summary is written, and swept after 48h.
-- ---------------------------------------------------------------------------

create table if not exists public.rss_bodies (
  article_id text primary key references public.articles (id) on delete cascade,
  body       text not null,
  fetched_at timestamptz not null default now()
);

alter table public.rss_bodies enable row level security;
revoke all on public.rss_bodies from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Part D3 — the global AI budget ledger.
--
-- DAILY_SUMMARY_CAP is a ceiling across ALL sources, not per-feed, so it has
-- to live in the database rather than in any one worker. Slots are CLAIMED
-- before generation and released if unused, so two overlapping runs cannot
-- both spend the last of the day's budget.
--
--   Cost per bite ~ 1500 in + 200 out ~ $0.0007
--   200/day  ->  ~$0.14/day  ->  ~$4/month
--
-- Token counts are recorded so the ceiling is verifiable rather than assumed.
-- ---------------------------------------------------------------------------

create table if not exists public.ai_usage_daily (
  day            date primary key,
  summaries_done integer not null default 0,
  input_tokens   bigint  not null default 0,
  output_tokens  bigint  not null default 0,
  updated_at     timestamptz not null default now()
);

alter table public.ai_usage_daily enable row level security;
revoke all on public.ai_usage_daily from anon, authenticated;

-- Atomically reserve up to p_want summary slots under p_daily_cap. Returns
-- how many were actually granted (0 when the day's budget is spent). The
-- caller must never summarise more rows than it was granted.
create or replace function public.claim_summary_slots(
  p_want      integer,
  p_daily_cap integer)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_today  date := (now() at time zone 'utc')::date;
  v_before integer;
  v_after  integer;
begin
  if p_want <= 0 then
    return 0;
  end if;

  select summaries_done into v_before
    from public.ai_usage_daily where day = v_today;
  v_before := coalesce(v_before, 0);

  insert into public.ai_usage_daily (day, summaries_done)
  values (v_today, least(p_want, p_daily_cap))
  on conflict (day) do update
    set summaries_done =
          least(p_daily_cap, public.ai_usage_daily.summaries_done + p_want),
        updated_at = now()
  returning summaries_done into v_after;

  return greatest(0, v_after - v_before);
end;
$$;

-- Hand back slots that were claimed but not spent (a batch that came up short,
-- or rows that failed before any model call).
create or replace function public.release_summary_slots(p_n integer)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.ai_usage_daily
     set summaries_done = greatest(0, summaries_done - greatest(0, p_n)),
         updated_at = now()
   where day = (now() at time zone 'utc')::date;
$$;

-- Record real token spend so the monthly projection can be checked, not guessed.
create or replace function public.record_summary_tokens(
  p_input bigint, p_output bigint)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.ai_usage_daily (day, input_tokens, output_tokens)
  values ((now() at time zone 'utc')::date, greatest(0, p_input),
          greatest(0, p_output))
  on conflict (day) do update
    set input_tokens  = public.ai_usage_daily.input_tokens + greatest(0, p_input),
        output_tokens = public.ai_usage_daily.output_tokens + greatest(0, p_output),
        updated_at    = now();
$$;

revoke all on function public.claim_summary_slots(integer, integer)
  from public, anon, authenticated;
revoke all on function public.release_summary_slots(integer)
  from public, anon, authenticated;
revoke all on function public.record_summary_tokens(bigint, bigint)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Part A / hard constraint 6 — the kill switch, on the read path.
--
-- IDENTICAL to the 0012 get_personalized_feed body except for ONE added
-- predicate in the `cand` CTE: an article whose publisher is disabled (or
-- whose publisher row is gone) never enters the deck. Guardian and mock rows
-- have publisher_id IS NULL and are unaffected.
--
-- Feed-level filtering, not deletion — the same lesson as the NewsData
-- disable in 0006. Deleting the rows would cascade into saves and
-- swipe_events (destroying users' bookmarks and the recommender's training
-- signal) and orphan tracker timelines.
--
-- Saved articles are deliberately NOT hidden: a save is the user's own
-- bookmark, and opening it still sends the publisher a referral. Disabling
-- stops NEW distribution; it does not reach into what people already kept.
--
-- Return type unchanged -> CREATE OR REPLACE. Weights, exploration slice,
-- topic penalty, country nudge and slot math are all untouched.
-- ---------------------------------------------------------------------------

create or replace function public.get_personalized_feed(
  p_user_id uuid default auth.uid(),
  p_limit   integer default 200)
returns table (
  id                  text,
  source              text,
  source_name         text,
  category            text,
  title               text,
  snippet             text,
  image_url           text,
  original_url        text,
  author              text,
  read_minutes        integer,
  source_icon_url     text,
  full_text_available boolean,
  published_at        timestamptz,
  score               double precision,
  ai_summary          text,
  ai_summary_hook     text)
language plpgsql
stable
set search_path = public, extensions
as $$
declare
  w_sim   constant double precision := 0.55;
  w_avoid constant double precision := 0.15;
  w_cat   constant double precision := 0.25;
  w_rec   constant double precision := 0.25;
  w_cat_cold constant double precision := 0.60;
  w_rec_cold constant double precision := 0.40;
  w_topic_penalty constant double precision := 0.05;
  w_country constant double precision := 0.1;   -- COUNTRY_WEIGHT (mild nudge)
  half_life_hours constant double precision := 36;
  cold_start_min  constant integer := 5;
  swipe_window    constant integer := 50;
  pool_hours      constant integer := 48;

  w_read       constant double precision := 1.0;
  w_save       constant double precision := 1.3;
  w_open_boost constant double precision := 0.6;

  explore_ratio constant double precision := 0.18;
  strong_min    constant integer := 2;
  v_every       integer;
  v_slots       integer;

  v_reset      timestamptz;
  v_country      text;
  v_country_tag  text;
  v_taste      vector(384);
  v_avoid      vector(384);
  v_positives  integer := 0;
  v_cold       boolean;
  v_strong_cats text[];
  v_has_prefs  boolean;
begin
  v_every := greatest(2, round(1 / explore_ratio))::int;
  v_slots := ceil(p_limit * explore_ratio)::int;

  select p.feed_reset_at, p.country into v_reset, v_country
    from profiles p where p.id = p_user_id;

  v_country_tag := case v_country
    when 'us'        then 'us-news'
    when 'uk'        then 'uk'
    when 'india'     then 'india'
    when 'australia' then 'australia-news'
    when 'canada'    then 'canada'
    else null
  end;

  select count(*), sum(e.emb * array_fill(e.weight, array[384])::vector(384))
    into v_positives, v_taste
    from (select a.embedding as emb,
                 (case s.direction
                    when 'read'   then w_read
                    when 'save'   then w_save
                    else               w_open_boost
                  end) as weight
            from swipe_events s
            join articles a on a.id = s.article_id
           where s.user_id = p_user_id
             and s.direction in ('read', 'save', 'opened')
             and a.embedding is not null
           order by s.created_at desc
           limit swipe_window) e;

  select avg(e.embedding)
    into v_avoid
    from (select a.embedding
            from swipe_events s
            join articles a on a.id = s.article_id
           where s.user_id = p_user_id
             and s.direction = 'reject'
             and a.embedding is not null
           order by s.created_at desc
           limit swipe_window) e;

  v_cold := v_positives < cold_start_min;

  select array_agg(t.category)
    into v_strong_cats
    from (select a.category
            from swipe_events s
            join articles a on a.id = s.article_id
           where s.user_id = p_user_id
             and s.direction in ('read', 'save', 'opened')
           group by a.category
          having count(*) >= strong_min) t;

  select exists (select 1 from category_prefs where user_id = p_user_id)
    into v_has_prefs;

  return query
  with cand as (
    select a.id, a.source, a.source_name, a.category, a.title, a.snippet,
           a.image_url, a.original_url, a.author, a.read_minutes,
           a.source_icon_url, a.full_text_available, a.published_at,
           a.ai_summary, a.ai_summary_hook,
           ((case
              when not v_cold then
                w_sim * coalesce(1 - (a.embedding <=> v_taste), 0.5)
                - (case when v_avoid is not null and a.embedding is not null
                     then w_avoid * (1 - (a.embedding <=> v_avoid))
                     else 0 end)
                + w_cat * (cp.category is not null)::int
                + w_rec * exp(-ln(2) * extract(epoch from
                      (now() - coalesce(a.published_at, a.created_at)))
                      / 3600 / half_life_hours)
              else
                w_cat_cold * (cp.category is not null)::int
                + w_rec_cold * exp(-ln(2) * extract(epoch from
                      (now() - coalesce(a.published_at, a.created_at)))
                      / 3600 / half_life_hours)
            end)
            + (case when v_country_tag is not null and exists (
                  select 1 from unnest(a.tags) tg
                   where v_country_tag = any(string_to_array(tg, '/')))
                then w_country else 0 end))::double precision as sc,
           (cp.category is not null) as pref,
           coalesce(a.published_at, a.created_at) as pub,
           coalesce(a.category = any(v_strong_cats), false) as strong
      from articles a
      left join category_prefs cp
        on cp.user_id = p_user_id and cp.category = a.category
     where a.source <> 'mock'
       and a.source <> 'newsdata'
       -- PHASE 14 KILL SWITCH. Guardian/mock rows (publisher_id IS NULL) pass
       -- through untouched; a Phase 14 row only shows while its publisher is
       -- enabled, so `enabled = false` empties their cards from every deck on
       -- the very next read.
       and (a.publisher_id is null
            or exists (select 1 from publishers pb
                        where pb.id = a.publisher_id and pb.enabled))
       and coalesce(a.published_at, a.created_at)
             > now() - make_interval(hours => pool_hours)
       and not exists (
         select 1 from swipe_events s
          where s.user_id = p_user_id
            and s.article_id = a.id
            and (s.direction in ('read', 'save')
                 or (s.direction = 'reject'
                     and s.created_at
                           > coalesce(v_reset, '-infinity'::timestamptz))))
  ),
  ranked as (
    select c.*,
           row_number() over (partition by c.category order by c.sc desc)
             as dom_rank,
           row_number() over (partition by c.category order by c.pub desc)
             as cat_fresh
      from cand c
  ),
  explore_pick as (
    select e.id, (e.e_rank * v_every) as slot
      from (select r.id,
                   row_number() over (order by r.cat_fresh asc, r.pub desc)
                     as e_rank
              from ranked r
             where not v_cold and not r.strong
               and (r.pref or not v_has_prefs)) e
     where e.e_rank <= v_slots
  ),
  main as (
    select r.id,
           (row_number() over (
             order by
               case when v_cold and not r.pref then 1 else 0 end,
               case when v_cold then r.cat_fresh else 1 end,
               case when v_cold then r.sc
                    else r.sc - w_topic_penalty * (r.dom_rank - 1) end desc,
               r.pub desc)) as m_rank
      from ranked r
     where r.id not in (select ep.id from explore_pick ep)
  ),
  slotted as (
    select m.id, (m.m_rank + div(m.m_rank - 1, v_every - 1)) as slot
      from main m
    union all
    select ep.id, ep.slot from explore_pick ep
  )
  select r.id, r.source, r.source_name, r.category, r.title, r.snippet,
         r.image_url, r.original_url, r.author, r.read_minutes,
         r.source_icon_url, r.full_text_available, r.published_at,
         r.sc, r.ai_summary, r.ai_summary_hook
    from slotted sl
    join ranked r on r.id = sl.id
   order by sl.slot
   limit p_limit;
end;
$$;

grant execute on function public.get_personalized_feed(uuid, integer)
  to authenticated;
revoke execute on function public.get_personalized_feed(uuid, integer)
  from anon;

-- ---------------------------------------------------------------------------
-- Kill switch, tracker side. A disabled publisher's articles drop out of
-- tracker timelines too — a removal request means "stop showing our content",
-- not "stop showing it in one place".
--
-- The tracker itself, its history rows, and any saves survive: only the
-- DISPLAY is filtered, so nothing is orphaned and no timeline crashes. If the
-- publisher is re-enabled the timeline comes back intact.
--
-- Return type unchanged -> CREATE OR REPLACE.
-- ---------------------------------------------------------------------------

create or replace function public.get_tracker_articles(p_tracker_id uuid)
returns table (
  id                  text,
  source              text,
  source_name         text,
  category            text,
  title               text,
  snippet             text,
  image_url           text,
  original_url        text,
  author              text,
  read_minutes        integer,
  source_icon_url     text,
  full_text_available boolean,
  published_at        timestamptz,
  ai_summary          text,
  ai_summary_hook     text,
  matched_at          timestamptz,
  seen                boolean,
  match_score         double precision)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select a.id, a.source, a.source_name, a.category, a.title, a.snippet,
         a.image_url, a.original_url, a.author, a.read_minutes,
         a.source_icon_url, a.full_text_available, a.published_at,
         a.ai_summary, a.ai_summary_hook,
         ta.matched_at, ta.seen, ta.match_score
    from tracker_articles ta
    join articles a on a.id = ta.article_id
    join story_trackers t on t.id = ta.tracker_id
   where ta.tracker_id = p_tracker_id
     and t.user_id = auth.uid()
     and (a.publisher_id is null
          or exists (select 1 from publishers pb
                      where pb.id = a.publisher_id and pb.enabled))
   order by ta.matched_at desc;
$$;

grant execute on function public.get_tracker_articles(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Part G1 — tracker matching for articles with no Guardian tags.
--
-- THE SILENT REGRESSION THIS PHASE. The Phase 13 score is
--     W_TAG(0.6) * jaccard(tags) + W_EMBED(0.4) * cosine
-- against a threshold of 0.55. An RSS article has no Guardian tags, so its
-- jaccard is 0 and its maximum achievable score is 0.4 — BELOW the threshold.
-- Left alone, no RSS article could ever match any tracker, and nothing would
-- error: the timelines would just quietly never grow.
--
-- The same trap runs in the other direction: a tracker SEEDED from an RSS
-- article has an empty tag_set, so it could never match a Guardian article
-- either. So the test is not "does the article have tags" but "are both sides
-- comparable" — tag overlap only means something when BOTH sets are non-empty.
--
-- When they are not, we fall back to a pure-embedding score judged against its
-- own, higher threshold (p_threshold_notag, ~0.75): cosine alone is a weaker
-- same-story signal than structured tags, so it has to clear a higher bar.
--
-- RSS <category> values are deliberately NOT written into articles.tags. They
-- live in articles.rss_categories instead. Putting them in tag space would
-- make cardinality(tags) > 0 and push RSS articles back onto the hybrid path,
-- where they would score jaccard 0 against Guardian vocabulary and silently
-- never match again — the exact bug this fixes, reintroduced.
--
-- Returns match_path so the worker can log which branch fired and the two
-- thresholds can be tuned independently.
--
-- Signature changes (new p_threshold_notag param, new output column), so the
-- old function is dropped first.
-- ---------------------------------------------------------------------------

drop function if exists public.run_tracker_matching(
  double precision, double precision, double precision,
  integer, double precision, double precision);

create or replace function public.run_tracker_matching(
  p_w_tag           double precision,
  p_w_embed         double precision,
  p_threshold       double precision,
  p_threshold_notag double precision,
  p_window_hours    integer,
  p_drift           double precision,
  p_max_drift       double precision)
returns table (
  tracker_id  uuid,
  article_id  text,
  match_score double precision,
  tag_score   double precision,
  embed_score double precision,
  match_path  text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  return query
  with candidates as (
    select a.id, a.tags, a.embedding
      from articles a
     where a.source <> 'mock'
       -- A disabled publisher stops feeding trackers on the next run, the
       -- same cycle its cards vanish from the deck.
       and (a.publisher_id is null
            or exists (select 1 from publishers pb
                        where pb.id = a.publisher_id and pb.enabled))
       and coalesce(a.published_at, a.created_at)
             > now() - make_interval(hours => p_window_hours)
  ),
  scored as (
    select t.id as s_tracker_id,
           c.id as s_article_id,
           -- Tag overlap is only meaningful when BOTH sides carry tags.
           (cardinality(t.tag_set) > 0 and cardinality(c.tags) > 0)
             as s_hybrid,
           (case
              when cardinality(t.tag_set) = 0 or cardinality(c.tags) = 0 then 0
              else (
                (select count(*)::double precision
                   from (select unnest(t.tag_set)
                         intersect
                         select unnest(c.tags)) inter)
                / nullif((select count(*)::double precision
                            from (select unnest(t.tag_set)
                                  union
                                  select unnest(c.tags)) uni), 0))
            end) as s_tag,
           (case
              when t.centroid_embedding is not null and c.embedding is not null
              then 1 - (c.embedding <=> t.centroid_embedding)
              else 0
            end) as s_embed
      from story_trackers t
      cross join candidates c
     where not t.muted
       and c.id is distinct from t.seed_article_id
       and not exists (
         select 1 from tracker_articles ta
          where ta.tracker_id = t.id and ta.article_id = c.id)
  ),
  eligible as (
    select s_tracker_id, s_article_id, s_tag, s_embed, s_hybrid,
           (case when s_hybrid
                 then p_w_tag * s_tag + p_w_embed * s_embed
                 else s_embed                      -- embedding-only path
            end) as s_score,
           (case when s_hybrid then p_threshold else p_threshold_notag end)
             as s_bar,
           (case when s_hybrid then 'hybrid' else 'embed_only' end) as s_path
      from scored
  ),
  inserted as (
    insert into tracker_articles (tracker_id, article_id, match_score, seen)
    select e.s_tracker_id, e.s_article_id, e.s_score, false
      from eligible e
     where e.s_score >= e.s_bar
    on conflict (tracker_id, article_id) do nothing
    returning tracker_articles.tracker_id   as i_tracker_id,
              tracker_articles.article_id   as i_article_id,
              tracker_articles.match_score  as i_score
  )
  select i.i_tracker_id, i.i_article_id, i.i_score, e.s_tag, e.s_embed, e.s_path
    from inserted i
    join eligible e
      on e.s_tracker_id = i.i_tracker_id and e.s_article_id = i.i_article_id;

  -- Centroid drift (default off, p_drift = 0) — unchanged from Phase 13.
  if p_drift > 0 then
    update story_trackers t
       set centroid_embedding = d.new_centroid
      from (
        select st.id as tracker_id,
               st.seed_article_id,
               l2_normalize(
                 (1 - p_drift) * st.centroid_embedding
                 + p_drift * avg(a.embedding))::vector(384) as new_centroid
          from tracker_articles ta
          join story_trackers st on st.id = ta.tracker_id
          join articles a on a.id = ta.article_id
         where ta.matched_at > now() - interval '2 minutes'
           and st.centroid_embedding is not null
           and a.embedding is not null
         group by st.id, st.seed_article_id, st.centroid_embedding
      ) d
     where t.id = d.tracker_id
       and (
         d.seed_article_id is null
         or exists (
           select 1 from articles seed
            where seed.id = d.seed_article_id
              and seed.embedding is not null
              and (1 - (d.new_centroid <=> seed.embedding)) >= (1 - p_max_drift)));
  end if;
end;
$$;

revoke all on function public.run_tracker_matching(
  double precision, double precision, double precision, double precision,
  integer, double precision, double precision)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Part B — the ingest-rss cron. Every 3 hours (8 runs/day), offset off the
-- Guardian cadence so the two ingests don't collide.
--
--   MAX_ARTICLES_PER_RUN_TOTAL (25) x 8 runs = 200/day = DAILY_SUMMARY_CAP.
--
-- Mirrors invoke_ingest: vault-stored url + secret so both rotate without
-- touching this function.
-- ---------------------------------------------------------------------------

select vault.create_secret(
  'https://sbykpnhswupezuetpzhl.supabase.co/functions/v1/ingest-rss',
  'ingest_rss_fn_url');
select vault.create_secret(
  -- Must equal INGEST_RSS_SECRET in the function's env. Distinct from the
  -- ingest/summarize/body secrets so it unlocks only RSS ingestion.
  'c7d21e5a84f9b0362d1c8e47a5b93f60e284c71d9a3b5f08',
  'ingest_rss_fn_secret');

create or replace function public.invoke_ingest_rss()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url    text;
  v_secret text;
begin
  select decrypted_secret into v_url
    from vault.decrypted_secrets where name = 'ingest_rss_fn_url';
  select decrypted_secret into v_secret
    from vault.decrypted_secrets where name = 'ingest_rss_fn_secret';
  if v_url is null then
    return;
  end if;
  perform net.http_post(
    url     := v_url,
    body    := '{}'::jsonb,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-ingest-rss-secret', coalesce(v_secret, '')));
end;
$$;

revoke all on function public.invoke_ingest_rss() from public, anon, authenticated;

-- At :20 past every third hour — clear of Guardian ingest (:00/:30),
-- summarise (:05/:35) and tracker matching (:15/:45).
select cron.schedule(
  'bite-ingest-rss', '20 */3 * * *', 'select public.invoke_ingest_rss()');

-- ---------------------------------------------------------------------------
-- purge_old_articles, rev 4: also sweep RSS body text. Bodies are held only
-- long enough to summarise, so they go on a much shorter clock than articles.
-- Everything else is unchanged from the 0011 body.
-- ---------------------------------------------------------------------------

create or replace function public.purge_old_articles()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  retention_days       constant integer := 14;
  body_retention_hours constant integer := 48;
  v_deleted integer;
begin
  delete from public.article_bodies b
   where b.fetched_at < now() - make_interval(hours => body_retention_hours);

  -- Phase 14: RSS bodies are summarisation input only. The summariser deletes
  -- each row as soon as it writes the bite; this sweeps anything it missed.
  delete from public.rss_bodies rb
   where rb.fetched_at < now() - make_interval(hours => body_retention_hours);

  delete from public.articles a
   where a.created_at < now() - make_interval(days => retention_days)
     and a.source <> 'mock'
     and not exists (select 1 from public.saves s where s.article_id = a.id)
     and not exists (select 1 from public.swipe_events e where e.article_id = a.id)
     and not exists (select 1 from public.tracker_articles ta where ta.article_id = a.id)
     and not exists (select 1 from public.story_trackers st where st.seed_article_id = a.id);
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

revoke all on function public.purge_old_articles() from public, anon, authenticated;
