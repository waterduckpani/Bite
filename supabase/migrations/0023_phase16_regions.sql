-- Bite · Phase 16: regional source expansion.
-- Run in the SQL editor AFTER redeploying ingest-rss and summarize-articles:
--   supabase functions deploy ingest-rss          --no-verify-jwt
--   supabase functions deploy summarize-articles  --no-verify-jwt
--
-- The pool goes from 9 publishers to 26, gains a six-value region taxonomy,
-- and the Phase 12 country nudge is REMOVED — not zeroed, removed.
--
-- WHAT REGION MEANS HERE, EXACTLY
--
-- A region tag is a fact about a PUBLISHER ("The Hindu is an Indian outlet"),
-- stored on the registry row. It is read for one purpose: a mild additive
-- ranking boost when a user has selected that region.
--
-- It is NOT a filter, and nothing below can make it one:
--   - the candidate WHERE clause gains no region predicate whatsoever, so
--     every enabled publisher is in every user's pool on every query;
--   - 'Global' resolves v_region to NULL, so the boost term collapses to +0 on
--     every row and the score is arithmetically identical to Phase 15.2;
--   - the boost is additive only. In-region content is lifted; out-of-region
--     content is never penalised, so the pool a user sees is the whole pool,
--     re-ordered.
--
-- WHAT THIS REPLACES, AND WHY IT HAD TO GO
--
-- 0012 scored a country match off Guardian tag segments. 0018 rebuilt it on
-- rss_categories and URL path segments after the tags went dead; 0019 widened
-- it to hyphen-separated URL tokens because whole-segment matching scored
-- nothing at all for the three publishers that expose no categories. Each fix
-- was correct about the bug in front of it and wrong about the premise: the
-- signal being measured was SLUG STYLE, not relevance. /join-us/ scored the
-- nudge for a US reader — 0019 says so in its own header and accepts it.
--
-- "This is an Indian outlet" is a fact. "This URL contains india" was an
-- accident. So w_country, v_country_tag and v_country_words are deleted
-- outright below, along with profiles.country. There is no zeroed weight left
-- behind to be mistaken for a live signal later.
--
-- Sections:
--   A. publishers.region — six values, and regional editions of one domain.
--   B. The Phase 16 seed: 17 new rows, every one qualified.
--   C. profiles.region — the taxonomy, backfilled off country, country dropped.
--   D. get_personalized_feed — REGION_BOOST in, the country nudge out.
--   E. Reporting: daily AI spend, and the input-mode split per publisher.

-- ---------------------------------------------------------------------------
-- Part A — the region taxonomy, and regional editions.
--
-- Two changes to the registry shape.
--
-- 1. The check constraint goes from ('IN', 'GLOBAL') to the six selectable
--    values. GLOBAL is not "no region" — it is "not boosted by any region
--    selection", which is a different and deliberate thing: those rows are the
--    balanced core everyone sees at equal weight whatever they picked.
--
-- 2. canonical_domain drops UNIQUE in favour of UNIQUE (canonical_domain,
--    region). Some outlets run genuinely separate regional desks off one
--    domain — the Guardian's Australian edition is a different newsroom with
--    its own feed, and it has to carry region AU while theguardian.com carries
--    GLOBAL. One row per domain cannot express that.
--
--    The original UNIQUE existed to stop six Guardian SECTION feeds becoming
--    six registry rows (see 0018 Part A), and that reasoning is untouched:
--    sections still go in rss_urls on one row. What is now allowed is one row
--    per (domain, region), which is a different axis. The cost is one extra
--    robots.txt fetch per ROBOTS_CACHE_HOURS per extra edition, and CTR
--    reported per edition rather than per domain — both acceptable, the second
--    arguably an improvement.
-- ---------------------------------------------------------------------------

alter table public.publishers
  drop constraint if exists publishers_region_check;

alter table public.publishers
  add constraint publishers_region_check
    check (region in ('GLOBAL', 'US', 'UK', 'EU', 'IN', 'AU'));

comment on column public.publishers.region is
  'Region tag driving the additive REGION_BOOST in get_personalized_feed. '
  'GLOBAL means "never boosted by a region selection", NOT "hidden from '
  'regional users" — region never filters, only ranks.';

-- The constraint name is whatever the UNIQUE in 0013 produced; drop by both
-- the implicit name and the index, so this is safe whichever way it was made.
alter table public.publishers
  drop constraint if exists publishers_canonical_domain_key;
drop index if exists public.publishers_canonical_domain_key;

alter table public.publishers
  drop constraint if exists publishers_domain_region_key;
alter table public.publishers
  add constraint publishers_domain_region_key
    unique (canonical_domain, region);

-- ---------------------------------------------------------------------------
-- Part A2 — retag the existing nine.
--
-- Deutsche Welle, and later France 24 and Euronews, are tagged EU rather than
-- GLOBAL. This is the one place Phase 16's spec was self-defeating: it listed
-- Europe as a selectable region AND put every European outlet in the global
-- core, which would have made "Europe" a preference that boosted precisely
-- nothing. That is the same silent no-signal failure 0019 documents at length,
-- and shipping a second instance of it knowingly would be worse than the
-- first.
--
-- Tagging them EU costs nothing, because a GLOBAL tag confers no visibility a
-- regional tag lacks: both appear in every pool. GLOBAL only means "not
-- boosted". So a European reader now gets DW, France 24 and Euronews lifted,
-- and every other reader sees them exactly as before.
--
-- The Christian Science Monitor and Reason stay GLOBAL despite both being US
-- outlets: CSM's brief is explicitly international and Reason's is national
-- politics rather than US regional news. Neither is what a reader picking
-- "United States" is asking for.
-- ---------------------------------------------------------------------------

update public.publishers set region = 'EU' where id = 'dw';

-- ---------------------------------------------------------------------------
-- Part B — the Phase 16 seed. 17 rows, every one qualified.
--
-- Reports are committed under docs/publishers/ (checked 2026-07-30 with the
-- honest User-Agent BiteNewsBot/1.0). Nothing here is seeded on assumption,
-- and every row's mode is THE MODE ITS PROBE ACTUALLY RETURNED, not the mode
-- the plan assumed. Where those disagreed, the probe won:
--
--   WIRED           expected full-text  ->  paywall on honest fetch, description-only
--   The Verge       expected excerpts   ->  full content:encoded on 10/10 items
--   CNBC, ESPN, Science News, The Independent  ->  paywalled, description-only
--   Sky News        ->  HTTP 403 to our User-Agent, description-only
--
-- full_text_allowed is seeded false for every walled source and is NEVER
-- hand-set true; ingest-rss re-derives it from robots.txt against a real
-- article path on each refresh. A walled publisher is description-only, full
-- stop — there is no header-retry path in the codebase and none is added here.
--
-- max_per_run is set from measured items/day: high-volume outlets are held
-- back so they cannot crowd the slate. The global MAX_ARTICLES_PER_RUN_TOTAL
-- (48 as of this phase) and the round-robin fair share remain the real
-- limiters — these per-row caps only stop a single outlet dominating a quiet
-- cycle.
-- ---------------------------------------------------------------------------

insert into public.publishers
  (id, name, canonical_domain, rss_url, rss_urls, region, max_per_run,
   full_text_allowed, notes)
values
  -- -- Global core ---------------------------------------------------------
  ('bbc', 'BBC News', 'bbc.com',
   'https://feeds.bbci.co.uk/news/world/rss.xml',
   array[
     'https://feeds.bbci.co.uk/news/world/rss.xml',
     'https://feeds.bbci.co.uk/news/business/rss.xml',
     'https://feeds.bbci.co.uk/sport/rss.xml',
     'https://feeds.bbci.co.uk/news/technology/rss.xml'
   ],
   'GLOBAL', 6, false,
   'Qualified 2026-07-30, four section feeds (world/business/sport/technology) '
   'rather than one firehose, so the business, sport and tech coverage gaps are '
   'filled deliberately. Description-only: 0 of 26 world items carried '
   'content:encoded, and robots.txt (the * group) does not permit our article '
   'paths. Feeds are hosted on feeds.bbci.co.uk, so THAT host governs the feed '
   'fetch. The uk feed also qualified and is NOT seeded — see the README.'),
  ('npr', 'NPR', 'npr.org',
   'https://feeds.npr.org/1001/rss.xml', '{}', 'GLOBAL', 4, true,
   'Qualified 2026-07-30. robots.txt allows article paths and an honest fetch '
   'returned a real body, so the conditional body fetch applies. ~30 items/day. '
   'Serves the US desk from the core, per the Phase 16 plan.'),
  ('euronews', 'Euronews', 'euronews.com',
   'https://www.euronews.com/rss', '{}', 'EU', 3, true,
   'Qualified 2026-07-30. body-fetch-allowed. ~113 items/day — capped low so it '
   'cannot crowd the slate. Tagged EU so the Europe selection has something to '
   'boost; still in every pool, like every row here.'),
  ('france24', 'France 24', 'france24.com',
   'https://www.france24.com/en/rss', '{}', 'EU', 3, false,
   'Qualified 2026-07-25 (Phase 14) and re-checked 2026-07-30. '
   'Description-only. ~83 items/day. Passed in Phase 14 but was left unseeded '
   'as redundant with DW; Phase 16 seeds it because EU needs real depth, not '
   'because the redundancy argument changed.'),
  -- -- United Kingdom ------------------------------------------------------
  ('skynews', 'Sky News', 'news.sky.com',
   'https://feeds.skynews.com/feeds/rss/home.xml', '{}', 'UK', 4, false,
   'Qualified 2026-07-30. robots.txt itself returns HTTP 403 to our '
   'User-Agent, and the body probe returned 403 too — so description-only, and '
   'full_text_allowed can never derive true here (deriveFullTextAllowed '
   'requires a robots.txt we actually read). Not retried with other headers.'),
  ('independent', 'The Independent', 'independent.co.uk',
   'https://www.independent.co.uk/news/uk/rss', '{}', 'UK', 3, false,
   'Qualified 2026-07-30. robots.txt allows article paths but the page behind '
   'them is paywalled — the probe hit paywall and ABORTED. Description-only. '
   '~107 items/day, capped low.'),
  -- -- United States -------------------------------------------------------
  ('pbs', 'PBS NewsHour', 'pbs.org',
   'https://www.pbs.org/newshour/feeds/rss/headlines', '{}', 'US', 4, true,
   'Qualified 2026-07-30. body-fetch-allowed; robots.txt states Crawl-delay 1s, '
   'which our 1s floor already meets. ~24 items/day, all carrying categories.'),
  ('thehill', 'The Hill', 'thehill.com',
   'https://www.thehill.com/feed', '{}', 'US', 3, false,
   'Qualified 2026-07-30 as the replacement for Axios, which FAILED (its feed '
   'is robots-disallowed and no conventional path exists). Body probe returned '
   'HTTP 403 to our honest User-Agent, so description-only, not retried. '
   '~99 items/day, capped low.'),
  -- -- Australia -----------------------------------------------------------
  ('abcnewsau', 'ABC News Australia', 'abc.net.au',
   'https://www.abc.net.au/news/feed/45910/rss.xml', '{}', 'AU', 4, true,
   'Qualified 2026-07-30. body-fetch-allowed. ~30 items/day, 18 of 25 items '
   'carrying categories.'),
  ('theguardianau', 'Guardian Australia', 'theguardian.com',
   'https://www.theguardian.com/australia-news/rss', '{}', 'AU', 3, true,
   'Qualified 2026-07-30. A SECOND row on theguardian.com, which is what Part '
   'A''s UNIQUE (canonical_domain, region) exists to permit: the Australian '
   'edition is a separate desk and has to carry region AU while the main row '
   'carries GLOBAL. Overlap with the main row''s section feeds is handled by '
   'the existing URL + title-Jaccard dedup in ingest-rss, which runs across '
   'ALL publishers in a run.'),
  -- -- Category specialists (GLOBAL) ---------------------------------------
  ('techcrunch', 'TechCrunch', 'techcrunch.com',
   'https://techcrunch.com/feed/', '{}', 'GLOBAL', 4, true,
   'Qualified 2026-07-30. body-fetch-allowed. ~21 items/day. Tech was the '
   'thinnest category in the Phase 15 pool; this and WIRED/The Verge/BBC tech '
   'are the fix.'),
  ('wired', 'WIRED', 'wired.com',
   'https://www.wired.com/feed/rss', '{}', 'GLOBAL', 4, false,
   'Qualified 2026-07-30. The plan expected free full text; the honest probe '
   'hit a PAYWALL and aborted, so this seeds description-only. ~32 items/day, '
   'all 50 sampled items carrying categories.'),
  ('theverge', 'The Verge', 'theverge.com',
   'https://www.theverge.com/rss/index.xml', '{}', 'GLOBAL', 4, false,
   'Qualified 2026-07-30. The plan expected excerpt-only; the feed in fact '
   'carries real content:encoded on 10 of 10 items, so ingest-rss reads the '
   'body STRAIGHT FROM THE FEED and never requests the article page at all '
   '(hasUsableFullContent is checked before full_text_allowed). '
   'full_text_allowed stays false because the article page is walled — which '
   'costs nothing here, since no page fetch is needed. The politest outcome '
   'available: full-text bites, zero requests to the publisher.'),
  ('sciencedaily', 'Science Daily', 'sciencedaily.com',
   'https://www.sciencedaily.com/rss/all.xml', '{}', 'GLOBAL', 4, true,
   'Qualified 2026-07-30. body-fetch-allowed. ~8 items/day. Feed exposes no '
   'categories, so opinion filtering for this row relies on URL-path and '
   'title-prefix rules alone.'),
  ('sciencenews', 'Science News', 'sciencenews.org',
   'https://www.sciencenews.org/feed', '{}', 'GLOBAL', 3, false,
   'Qualified 2026-07-30. Body probe hit a paywall and aborted — '
   'description-only. ~2 items/day; a low-volume row that will often '
   'contribute nothing to a run, which is fine.'),
  ('cnbc', 'CNBC', 'cnbc.com',
   'https://www.cnbc.com/id/100003114/device/rss/rss.html', '{}',
   'GLOBAL', 4, false,
   'Qualified 2026-07-30. Body probe hit a paywall and aborted — '
   'description-only. ~43 items/day. Fills the business coverage gap alongside '
   'the BBC business feed.'),
  ('espn', 'ESPN', 'espn.com',
   'https://www.espn.com/espn/rss/news', '{}', 'GLOBAL', 4, false,
   'Qualified 2026-07-30. Body probe hit a paywall and aborted — '
   'description-only. ~23 items/day. Fills the sports coverage gap alongside '
   'the BBC sport feed.')
on conflict (id) do update
  set name              = excluded.name,
      canonical_domain  = excluded.canonical_domain,
      rss_url           = excluded.rss_url,
      rss_urls          = excluded.rss_urls,
      region            = excluded.region,
      max_per_run       = excluded.max_per_run,
      full_text_allowed = excluded.full_text_allowed,
      notes             = excluded.notes;

-- ---------------------------------------------------------------------------
-- Enable the slate.
--
-- Kept as its own statement, deliberately, so it stays the readable inverse of
-- the one-line kill switch:
--     update public.publishers set enabled = false where id = 'espn';
--
-- Every id listed here has a committed PASS report under docs/publishers/.
-- Rows land disabled by default (0013) precisely so that adding a row and
-- turning it on are two separate decisions; this is the second decision, made
-- once the reports were read.
--
-- 26 live sources: 13 GLOBAL, 4 IN, 3 EU, 2 UK, 2 US, 2 AU.
-- ---------------------------------------------------------------------------

update public.publishers set enabled = true
 where id in (
   -- Phase 14 / 15.1 slate
   'thehindu', 'newindianexpress', 'deccanherald', 'scroll',
   'aljazeera', 'dw', 'csmonitor', 'reason', 'theguardian',
   -- Phase 16
   'bbc', 'npr', 'euronews', 'france24',
   'skynews', 'independent',
   'pbs', 'thehill',
   'abcnewsau', 'theguardianau',
   'techcrunch', 'wired', 'theverge',
   'sciencedaily', 'sciencenews', 'cnbc', 'espn');

-- ---------------------------------------------------------------------------
-- Part C — profiles.region, and the end of profiles.country.
--
-- The stored value is the REGISTRY TAG ('GLOBAL' | 'US' | 'UK' | 'EU' | 'IN' |
-- 'AU'), not a friendly enum name, so the boost below compares it directly
-- against publishers.region. One vocabulary shared by client, profile and
-- registry — there is no mapping table that can drift, which is exactly how
-- 0012's country -> Guardian-tag mapping rotted without anyone noticing.
--
-- Backfill maps the Phase 12 countries onto it. 'canada' has no Phase 16
-- region and no Canadian publisher to boost, so it maps to GLOBAL: a
-- Canadian reader loses a preference that, being slug-derived, was scoring
-- close to noise anyway. That is a real (small) loss and it is stated here
-- rather than glossed.
--
-- country is then DROPPED. Leaving a dead column behind is how a removed
-- signal comes back to life in a later migration by accident.
-- ---------------------------------------------------------------------------

alter table public.profiles
  add column if not exists region text not null default 'GLOBAL';

alter table public.profiles
  drop constraint if exists profiles_region_check;
alter table public.profiles
  add constraint profiles_region_check
    check (region in ('GLOBAL', 'US', 'UK', 'EU', 'IN', 'AU'));

-- Guarded because the column it reads is dropped four lines below, and the
-- migrations in this project are written to be re-appliable (see 0020's
-- header). An unguarded UPDATE would work exactly once and then fail with
-- "column country does not exist" on every re-run, which is a trap for whoever
-- next replays the chain.
do $migrate_country$
begin
  if exists (
    select 1 from information_schema.columns
     where table_schema = 'public'
       and table_name   = 'profiles'
       and column_name  = 'country')
  then
    update public.profiles
       set region = case country
         when 'us'        then 'US'
         when 'uk'        then 'UK'
         when 'india'     then 'IN'
         when 'australia' then 'AU'
         else                  'GLOBAL'  -- 'global', 'canada', NULL, anything
       end
     where region = 'GLOBAL' and country is not null;
  end if;
end
$migrate_country$;

alter table public.profiles drop column if exists country;

-- ---------------------------------------------------------------------------
-- Part D — get_personalized_feed: REGION_BOOST in, the country nudge out.
--
-- THE WEIGHT. w_region = 0.12, against w_sim = 0.55.
--
-- The similarity term contributes w_sim * cosine, so it spans [0, 0.55] and in
-- practice sits between roughly 0.28 and 0.50 for a live pool. A flat 0.12
-- boost is therefore worth about the difference between a 0.60 and an 0.82
-- cosine match: enough that the region is plainly visible in the deck, not
-- enough for a weakly-matching in-region story to outrank a strongly-matching
-- global one. That is the stated requirement — noticeable, but taste still
-- wins — expressed as arithmetic rather than as a hope.
--
-- For scale: w_cat (a topic the user picked) is 0.25 and w_rec (full recency)
-- is 0.25, so a region match is worth about half of either. The old country
-- nudge was 0.1; this is barely above it, because the thing that changed is
-- that the signal is now CORRECT, not that it should shout louder.
--
-- THE JOIN IS A LEFT JOIN. This matters more than the weight. An inner join to
-- publishers would silently drop every row with publisher_id IS NULL — legacy
-- Guardian-API rows and mock rows — from the candidate set. That would be a
-- region FILTER introduced by accident through the boost's plumbing, which is
-- the exact failure mode this design is meant to exclude. Untagged rows get
-- pb.region IS NULL, match nothing, and score +0.
--
-- NO REGION PREDICATE EXISTS IN `cand`. The WHERE clause gates on source, the
-- bite gate, the publisher kill switch, the 48h pool window and the user's own
-- seen/rejected history. Region is absent from it by design: every enabled
-- publisher is a candidate for every user on every query, whatever they
-- picked. Global selection additionally makes the boost term literally +0, so
-- a Global reader's ranking is bit-for-bit the Phase 15.2 ranking.
--
-- REMOVED, not zeroed: w_country, v_country, v_country_tag and v_country_words
-- are all gone from the declare block, and the three-branch tags /
-- rss_categories / URL-token predicate is gone from the score. Nothing remains
-- that reads an article's slug or its category strings for placement.
--
-- SIDE EFFECT WORTH RECORDING: the country nudge was the LAST reader of
-- articles.tags and articles.rss_categories anywhere in the query path. Both
-- columns are kept — rss_categories is still written by ingest-rss on every
-- row, tags still holds values on legacy Guardian-API rows, and dropping either
-- would rewrite a large table for no gain — but nothing in Postgres reads them
-- now. (The opinion and category filters work on the parsed feed item in
-- TypeScript, before the row is written, not on these columns.) If a future
-- phase wants to rank on publisher sections, that is a new decision to argue
-- for, not a wire left conveniently live.
--
-- Everything else — exploration slice, topic penalty, cold start, slot math,
-- the Phase 15.2 bite gate — is UNCHANGED. Return type unchanged, so CREATE OR
-- REPLACE.
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
  -- REGION_BOOST. Additive, publisher-tagged, never a filter. See the header
  -- for why 0.12 against w_sim = 0.55.
  w_region constant double precision := 0.12;
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
  v_region     text;
  v_taste      vector(384);
  v_avoid      vector(384);
  v_positives  integer := 0;
  v_cold       boolean;
  v_strong_cats text[];
  v_has_prefs  boolean;
begin
  v_every := greatest(2, round(1 / explore_ratio))::int;
  v_slots := ceil(p_limit * explore_ratio)::int;

  select p.feed_reset_at, p.region into v_reset, v_region
    from profiles p where p.id = p_user_id;

  -- 'GLOBAL' is not a region to match — it is the balanced pool with no boost
  -- at all. Collapsing it (and a missing profile, and any unrecognised value)
  -- to NULL here is what makes the boost term below evaluate to +0 for every
  -- row, so a Global reader's score is identical to the pre-Phase-16 score.
  -- No publisher is ever tagged in a way that could match NULL.
  if v_region is null or v_region = 'GLOBAL' then
    v_region := null;
  end if;

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
            -- REGION_BOOST. Reads publishers.region and nothing else: no slug,
            -- no category string, no title. NULL v_region (Global, no profile,
            -- unknown value) and NULL pb.region (legacy/mock rows) both fall
            -- to +0, so this term can only ever ADD, and only to rows whose
            -- publisher is tagged with the region the reader chose.
            + (case when v_region is not null and pb.region = v_region
                then w_region else 0 end))::double precision as sc,
           (cp.category is not null) as pref,
           coalesce(a.published_at, a.created_at) as pub,
           coalesce(a.category = any(v_strong_cats), false) as strong
      from articles a
      -- LEFT, never inner: legacy Guardian-API and mock rows carry
      -- publisher_id IS NULL and MUST stay in the pool. An inner join here
      -- would turn the boost into a filter by accident.
      left join publishers pb
        on pb.id = a.publisher_id
      left join category_prefs cp
        on cp.user_id = p_user_id and cp.category = a.category
     where a.source <> 'mock'
       and a.source <> 'newsdata'
       -- PHASE 15.2 BITE GATE. Every card shows an AI bite, so a row without
       -- one is not a candidate. Deferred, not dropped.
       and btrim(coalesce(a.ai_summary, '')) <> ''
       and btrim(coalesce(a.ai_summary_hook, '')) <> ''
       -- PHASE 14 KILL SWITCH, restated against the LEFT JOIN. Rows with no
       -- publisher pass through untouched (pb.* is NULL); a registry row only
       -- shows while its publisher is enabled. NOTE: there is deliberately NO
       -- region predicate anywhere in this WHERE clause.
       and (a.publisher_id is null or pb.enabled)
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
-- Part E — reporting, so the cost claim and the input-mode split are
-- verifiable rather than asserted.
--
-- Phase 16 raises ingestion from ~100 to ~192 articles/day
-- (MAX_ARTICLES_PER_RUN_TOTAL 48 x 4 runs), which lands just under the
-- unchanged DAILY_SUMMARY_CAP of 200.
--
-- THE COST MODEL WAS WRONG, AND THIS IS HOW WE FOUND OUT. Every migration
-- since 0013 has repeated "~1500 in + 200 out per bite ~ $0.0007, so 200/day
-- ~ $4/month". The first reading of ai_spend_report() against real days says
-- otherwise: a full 200-summary day (2026-07-27) spent 230k input and 17k
-- output tokens — about 1150 in and 84 out per bite, roughly $0.00015 each,
-- $0.030/day, ~$0.90/month. The old figure was ~5x too high, in the safe
-- direction, and nobody could have known because nothing read the ledger back.
--
-- So at Phase 16's ~192/day the projection is ~$0.9/month, not ~$5. The
-- headroom under the $15 budget is far larger than assumed — which is an
-- argument for raising DAILY_SUMMARY_CAP later if supply justifies it, and a
-- reminder that a number repeated across five migrations is still a guess
-- until something measures it.
--
-- Prices are the ones the cost model was built on; they are parameters, not
-- facts about the world, so they are named at the call site rather than buried.
-- ---------------------------------------------------------------------------

create or replace function public.ai_spend_report(
  p_days          integer default 30,
  p_in_per_mtok   numeric default 0.10,
  p_out_per_mtok  numeric default 0.40)
returns table (
  day             date,
  summaries_done  integer,
  input_tokens    bigint,
  output_tokens   bigint,
  est_cost_usd    numeric,
  est_month_usd   numeric)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select u.day,
         u.summaries_done,
         u.input_tokens,
         u.output_tokens,
         round((u.input_tokens  / 1e6) * p_in_per_mtok
             + (u.output_tokens / 1e6) * p_out_per_mtok, 4) as est_cost_usd,
         round(((u.input_tokens  / 1e6) * p_in_per_mtok
              + (u.output_tokens / 1e6) * p_out_per_mtok) * 30, 2)
           as est_month_usd
    from ai_usage_daily u
   where u.day > (now() at time zone 'utc')::date - p_days
   order by u.day desc;
$$;

revoke all on function public.ai_spend_report(integer, numeric, numeric)
  from public, anon, authenticated;

-- Which publishers produce full-text bites and which produce description-only
-- ones. summary_input_mode is written per row by summarize-articles; this is
-- simply the split made readable, so "excerpt-only sources still produce valid
-- bites" is something that can be checked rather than assumed.
create or replace function public.publisher_input_modes(
  p_days integer default 7)
returns table (
  publisher_id   text,
  publisher_name text,
  region         text,
  body_bites     bigint,
  description_bites bigint,
  no_bite        bigint)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select p.id, p.name, p.region,
         count(*) filter (where a.summary_input_mode = 'body'),
         count(*) filter (where a.summary_input_mode = 'description'),
         -- `a.id is not null` is REQUIRED, not defensive. The LEFT JOIN emits
         -- one all-NULL row for a publisher with no articles in the window, and
         -- `summary_input_mode is null` is true of that phantom row — so
         -- without this guard a publisher that ingested NOTHING reports
         -- no_bite = 1, indistinguishable from one that ingested a single
         -- un-summarised article. Exactly the wrong distinction to blur in the
         -- report you would use to decide whether a new source is working.
         count(*) filter (where a.id is not null
                            and a.summary_input_mode is null)
    from publishers p
    left join articles a
      on a.publisher_id = p.id
     and a.created_at > now() - make_interval(days => p_days)
   group by p.id, p.name, p.region
   order by p.region, p.id;
$$;

revoke all on function public.publisher_input_modes(integer)
  from public, anon, authenticated;

-- Verify (run separately):
--   select region, count(*) from publishers where enabled group by region;
--   select * from ai_spend_report(14);
--   select * from publisher_input_modes(7);
