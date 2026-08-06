-- Bite · Phase 15.1: drop the Guardian Open Platform API; one uniform pipeline.
-- Run in the SQL editor AFTER redeploying the functions:
--   supabase functions deploy ingest-rss           --no-verify-jwt
--   supabase functions deploy summarize-articles   --no-verify-jwt
--   supabase functions deploy match-trackers       --no-verify-jwt
--   supabase functions deploy ingest-news          --no-verify-jwt   (Guardian removed)
--   supabase functions delete guardian-body
--
-- WHAT CHANGES, AND WHAT DELIBERATELY DOES NOT
--
-- Guardian stays as CONTENT. Only the licensed API goes. Guardian's six
-- section feeds were qualified with tools/qualify_publisher.dart on 2026-07-28
-- (reports in docs/publishers/theguardian.com-*.md) and it joins the Phase 14
-- registry as one more publisher: same robots checks, same honest User-Agent,
-- same junk and opinion filters, same fair-share cap, same link-out.
--
-- After this there is no two-tier reader. EVERY article link-outs to the
-- publisher, so `articles.full_text_available` no longer routes anything — it
-- survives only as a summariser input hint, and the client ignores it.
--
-- Existing Guardian-API rows are NOT deleted. They carry a real original_url,
-- so under universal link-out they open correctly; saves and tracker timelines
-- that reference them keep working. They fall out of the 48h feed pool on
-- their own, which is why no feed-level filter is added here (contrast the
-- NewsData disable in 0006, where the rows had to be hidden because the source
-- stayed in the pool).
--
-- Sections:
--   A. publishers.rss_urls — multi-feed support, and the Guardian row.
--   B. run_tracker_matching — embedding-only + a per-tracker per-run cap.
--   C. get_personalized_feed — keep the country nudge alive without tags.
--   D. Drop the Guardian body cache; purge_old_articles rev 3.
--   E. Retire the bite-ingest-news cron.

-- ---------------------------------------------------------------------------
-- Part A — several feeds per publisher.
--
-- Until now one registry row meant one feed URL, which was true of every
-- Phase 14 publisher. The Guardian is not: it publishes per-section feeds and
-- there is no single "everything" feed worth ingesting. Six registry rows
-- would have been the cheap answer, and it is the wrong one — canonical_domain
-- is UNIQUE for a reason, and six rows would mean six robots.txt fetches
-- against the same host, six CTR lines for one publisher, and six slots in the
-- round-robin fair share while every other outlet gets one.
--
-- So a publisher may now list EXTRA feeds. rss_url stays the primary (nothing
-- else changes for the eight existing rows); rss_urls holds the full set when
-- there is more than one. ingest-rss reads rss_urls when it is non-empty and
-- falls back to rss_url otherwise, and merges the items before the age,
-- opinion, junk and dedup passes — so per-publisher caps still bind on the
-- publisher, not on the feed.
-- ---------------------------------------------------------------------------

alter table public.publishers
  add column if not exists rss_urls text[] not null default '{}';

comment on column public.publishers.rss_urls is
  'All feeds for this publisher. Empty means "use rss_url" — the single-feed '
  'case, which is every Phase 14 row. When set it REPLACES rss_url for '
  'ingestion, so include the primary feed in the array.';

-- The Guardian. Qualified 2026-07-28, all six section feeds PASS:
--
--   feed         items parsed   mode                 full_text_allowed
--   world             45        body-fetch-allowed   true
--   business          39        body-fetch-allowed   true
--   technology        27        body-fetch-allowed   true
--   science           27        body-fetch-allowed   true
--   sport             53        body-fetch-allowed   true
--   culture           69        body-fetch-allowed   true
--
-- robots.txt (the `*` group — the Guardian names no BiteNewsBot group) allows
-- article paths and states no Crawl-delay, so our 1s floor applies. An honest
-- single fetch of a real article returned 3.2k–8.8k readable characters with
-- no wall, which is what makes full_text_allowed true here. That verdict is
-- robots-derived like everyone else's, and ingest-rss re-derives it on every
-- ROBOTS_CACHE_HOURS refresh; it is not a licence, and it does NOT put the
-- body in front of a reader. It only decides whether the summariser reads the
-- article or the feed's description.
--
-- The feeds are description-only (0 of 45 items carried content:encoded), so
-- the Guardian is the second publisher after DW that routinely exercises the
-- Part C body fetch.
--
-- max_per_run 6 = one per section feed on a typical run. The section feeds
-- carry a long evergreen tail (the sport feed spans years), so ingest-rss's
-- MAX_ITEM_AGE_HOURS is what makes the run fresh, not the feed order.
--
-- id is 'theguardian', NOT 'guardian': `guardian` is the legacy value in
-- articles.source for API-era rows, and the two must not read as the same
-- thing in a CTR report.
insert into public.publishers
  (id, name, canonical_domain, rss_url, rss_urls, region, max_per_run,
   full_text_allowed, notes)
values
  ('theguardian', 'The Guardian', 'theguardian.com',
   'https://www.theguardian.com/world/rss',
   array[
     'https://www.theguardian.com/world/rss',
     'https://www.theguardian.com/business/rss',
     'https://www.theguardian.com/technology/rss',
     'https://www.theguardian.com/science/rss',
     'https://www.theguardian.com/sport/rss',
     'https://www.theguardian.com/culture/rss'
   ],
   'GLOBAL', 6, true,
   'Qualified 2026-07-28 (Phase 15.1), all six section feeds. Replaces the '
   'Guardian Open Platform API — same content, no licensed key, link-out like '
   'every other publisher. Description-only feeds; robots.txt allows article '
   'paths so the body fetch runs for summariser input only.')
on conflict (id) do update
  set rss_urls = excluded.rss_urls,
      rss_url  = excluded.rss_url,
      notes    = excluded.notes;

-- Enabled because it qualified — the reports are committed and every feed
-- passed. Separate statement so it stays the one-line kill switch:
--     update public.publishers set enabled = false where id = 'theguardian';
update public.publishers set enabled = true where id = 'theguardian';

-- ---------------------------------------------------------------------------
-- Part B — tracker matching, embedding-only, with a per-run cap per tracker.
--
-- Guardian tags were the last source of articles.tags, so the hybrid path is
-- now unreachable: every article and every tracker seed has an empty tag_set,
-- which means the hybrid branch would score jaccard 0 forever. Rather than
-- leave dead scoring in place that looks live, the tag half is REMOVED. What
-- survives is the Phase 14 embed-only path against MATCH_THRESHOLD_NOTAG.
--
-- THE NEW CAP. Until now a threshold was the only thing standing between a
-- miscalibrated bar and a tracker taking every article in the window in one
-- pass — and MATCH_THRESHOLD_NOTAG was tuned against exactly one story, so
-- "miscalibrated" is a live possibility, not a hypothetical. p_max_per_tracker
-- bounds the damage: a tracker takes at most its N best-scoring new articles
-- per run, and anything else has to wait for the next one.
--
-- The cap is NEVER silent. Candidates that cleared the threshold but lost the
-- ranking are returned with inserted=false, so match-trackers logs exactly
-- what was held back and the bar can be re-tuned from real numbers.
--
-- Held is not dropped: already-matched articles are excluded from `scored`,
-- and WINDOW_HOURS (3h) is six times the 30-minute cron gap, so a held
-- candidate is re-scored on the next run and admitted then if it still ranks.
-- The cap paces intake; it does not discard coverage.
--
-- Note the return is one row per candidate OVER the bar, not per insert. If a
-- future miscalibration puts hundreds of articles over it, the logs get loud —
-- which is the intended alarm, not a bug to quieten.
--
-- articles.tags and story_trackers.tag_set are kept (columns, not code): old
-- rows still carry values, dropping them would rewrite two tables for nothing,
-- and get_personalized_feed still reads tags for the legacy country nudge.
-- ---------------------------------------------------------------------------

-- The signature changes (tag weights out, cap in), so the old overload must go
-- rather than sit alongside as a second callable version.
drop function if exists public.run_tracker_matching(
  double precision, double precision, double precision, double precision,
  integer, double precision, double precision);

create or replace function public.run_tracker_matching(
  p_threshold_notag double precision,
  p_window_hours    integer,
  p_max_per_tracker integer,
  p_drift           double precision,
  p_max_drift       double precision)
returns table (
  tracker_id  uuid,
  article_id  text,
  match_score double precision,
  inserted    boolean)
language plpgsql
security definer
set search_path = public, extensions
as $$
#variable_conflict use_column
begin
  return query
  with candidates as (
    select a.id, a.embedding
      from articles a
     where a.source <> 'mock'
       and a.embedding is not null
       -- Phase 14 kill switch: a disabled publisher's stories stop matching.
       and (a.publisher_id is null
            or exists (select 1 from publishers pb
                        where pb.id = a.publisher_id and pb.enabled))
       and coalesce(a.published_at, a.created_at)
             > now() - make_interval(hours => p_window_hours)
  ),
  scored as (
    select t.id as s_tracker_id,
           c.id as s_article_id,
           (1 - (c.embedding <=> t.centroid_embedding)) as s_score
      from story_trackers t
      cross join candidates c
     where not t.muted
       and t.centroid_embedding is not null
       and c.id is distinct from t.seed_article_id
       and not exists (
         select 1 from tracker_articles ta
          where ta.tracker_id = t.id and ta.article_id = c.id)
  ),
  ranked as (
    select s.*,
           row_number() over (partition by s.s_tracker_id
                              order by s.s_score desc, s.s_article_id) as rn
      from scored s
     where s.s_score >= p_threshold_notag
  ),
  -- Data-modifying CTE: runs exactly once whether or not it is referenced.
  ins as (
    insert into tracker_articles (tracker_id, article_id, match_score, seen)
    select r.s_tracker_id, r.s_article_id, r.s_score, false
      from ranked r
     where r.rn <= p_max_per_tracker
    on conflict (tracker_id, article_id) do nothing
    returning tracker_articles.tracker_id as i_tracker_id
  )
  select r.s_tracker_id, r.s_article_id, r.s_score,
         (r.rn <= p_max_per_tracker)
    from ranked r;

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
  double precision, integer, integer, double precision, double precision)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Part C — the country nudge, without Guardian tags.
--
-- 0012's mild country bonus reads articles.tags and matches a Guardian tag
-- segment ("world/india" → india). With the API gone, tags is empty on every
-- new row, so that predicate would quietly evaluate false forever and the
-- country a user picked during onboarding would stop meaning anything. Nobody
-- would see an error; the nudge would just be gone. That is the same silent
-- no-tag trap Phase 14 hit with tracker matching, and it is worth not walking
-- into twice.
--
-- So the same signal is read from what RSS rows actually carry:
--   1. articles.tags        — legacy Guardian-API rows, unchanged;
--   2. articles.rss_categories — the publisher's OWN section labels;
--   3. the original_url path segments — e.g. /uk-news/2026/…
--
-- All three are structural publisher metadata. Deliberately NOT matched:
-- title and snippet. "India" in a headline is about a story, not a desk, and
-- scoring on it would turn a mild placement nudge into keyword filtering.
--
-- Body is otherwise IDENTICAL to the 0013 version. Return type unchanged, so
-- CREATE OR REPLACE.
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
  v_country_words text[];
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

  -- Legacy: Guardian tag segment, for API-era rows still in the pool.
  v_country_tag := case v_country
    when 'us'        then 'us-news'
    when 'uk'        then 'uk'
    when 'india'     then 'india'
    when 'australia' then 'australia-news'
    when 'canada'    then 'canada'
    else null
  end;

  -- Publisher section vocabulary. Lowercase; compared for EQUALITY against a
  -- whole category value or a whole URL path segment, never as a substring —
  -- 'us' as a substring would match half the web.
  v_country_words := case v_country
    when 'us'        then array['us', 'us-news', 'us news', 'usa',
                                'united states', 'america', 'americas']
    when 'uk'        then array['uk', 'uk-news', 'uk news', 'britain',
                                'united kingdom', 'england', 'scotland',
                                'wales', 'northern ireland']
    when 'india'     then array['india', 'india-news', 'india news', 'indian']
    when 'australia' then array['australia', 'australia-news',
                                'australia news', 'australian']
    when 'canada'    then array['canada', 'canada-news', 'canada news',
                                'canadian']
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
            -- Country nudge. Legacy Guardian tags OR the publisher's own
            -- section labels OR the article URL's path segments.
            + (case when (v_country_tag is not null and exists (
                  select 1 from unnest(a.tags) tg
                   where v_country_tag = any(string_to_array(tg, '/'))))
                 or (v_country_words is not null and exists (
                  select 1 from unnest(a.rss_categories) rc
                   where lower(trim(rc)) = any(v_country_words)))
                 or (v_country_words is not null and exists (
                  select 1 from unnest(string_to_array(
                           lower(coalesce(a.original_url, '')), '/')) seg
                   where seg = any(v_country_words)))
                then w_country else 0 end))::double precision as sc,
           (cp.category is not null) as pref,
           coalesce(a.published_at, a.created_at) as pub,
           coalesce(a.category = any(v_strong_cats), false) as strong
      from articles a
      left join category_prefs cp
        on cp.user_id = p_user_id and cp.category = a.category
     where a.source <> 'mock'
       and a.source <> 'newsdata'
       -- PHASE 14 KILL SWITCH. Legacy Guardian/mock rows (publisher_id IS
       -- NULL) pass through untouched; a registry row only shows while its
       -- publisher is enabled.
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
-- Part D — the Guardian body cache goes.
--
-- article_bodies existed to hold Guardian paragraphs for the native reader
-- (0004). There is no native reader and no Guardian API, so nothing writes it
-- and nothing reads it. It is not the RSS summariser cache — that is
-- rss_bodies, which stays exactly as it is.
--
-- purge_old_articles reverts to its 0003 shape (articles only). The 14-day
-- retention with the saves/swipe_events exemption is unchanged, which is what
-- keeps a saved Guardian-API story alive long after it leaves the feed pool.
-- ---------------------------------------------------------------------------

create or replace function public.purge_old_articles()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  retention_days constant integer := 14;
  v_deleted integer;
begin
  delete from public.articles a
   where a.created_at < now() - make_interval(days => retention_days)
     and a.source <> 'mock'
     and not exists (select 1 from public.saves s where s.article_id = a.id)
     and not exists (select 1 from public.swipe_events e where e.article_id = a.id);
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

revoke all on function public.purge_old_articles() from public, anon, authenticated;

drop table if exists public.article_bodies;

-- ---------------------------------------------------------------------------
-- Part E — retire the ingest-news cron.
--
-- ingest-news is not deleted: it still holds the whole NewsData integration
-- (allowlist, grouping, rotation, credit accounting) behind SOURCE_ENABLED,
-- and that is worth keeping — see 0006 for why NewsData was switched off
-- rather than removed. But with Guardian gone from it, every run of it is now
-- a no-op, and a no-op firing 48 times a day is just noise in the logs.
--
-- To bring NewsData back: flip SOURCE_ENABLED.newsdata in the function, drop
-- the `a.source <> 'newsdata'` filter in get_personalized_feed above, and
-- re-schedule:
--   select cron.schedule('bite-ingest-news', '*/30 * * * *',
--                        'select public.invoke_ingest()');
-- ---------------------------------------------------------------------------

select cron.unschedule('bite-ingest-news')
 where exists (select 1 from cron.job where jobname = 'bite-ingest-news');
