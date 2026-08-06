-- Bite · Phase 18: publishers.default_category.
--
-- Run in the SQL editor AFTER redeploying ingest-rss:
--   supabase functions deploy ingest-rss --no-verify-jwt
--
-- ---------------------------------------------------------------------------
-- WHAT THIS FIXES, AND HOW WE KNOW
--
-- The category classifier was audited against all 26 live feeds (1,378 real
-- items, replayed through the shipping code by tools/category_harness.mjs).
-- It was wrong often enough that the category axis was close to noise:
--
--   world 66.2%  sports 11.2%  entertainment 7.6%  business 6.4%
--   science 5.6%  tech 3.0%
--
-- Four separate defects produced that, and three of them are fixed in
-- TypeScript (see _shared/categorize.ts, which now owns the classifier). This
-- migration exists for the fourth:
--
--   `world` was doing double duty as a real category AND as the return
--   statement when nothing matched. 431 of 923 world rows — 47% — had matched
--   NOTHING. Science Daily, a pure science wire, was 100% `world`. ESPN was
--   50% `world`. TechCrunch was 55% `world`.
--
-- A missing label is not the same thing as a label, and hiding one inside the
-- other meant the deck could not distinguish "this is international news" from
-- "we have no idea what this is". get_personalized_feed reads a.category for
-- the cold-start preference partition, the w_cat boost, the dom_rank topic
-- penalty and v_strong_cats — so half of every one of those signals was being
-- computed off a default value.
--
-- default_category is the fix: each publisher declares what its unlabelled
-- output IS. For a pure-beat wire that is its beat. For a general daily it is
-- 'world' — which is the same answer the old code produced, but now as a
-- decision someone made and can be argued with, rather than a fallthrough.
--
-- MEASURED EFFECT of the full Phase 18 change, same 26 feeds, same day:
--
--   world 66.2% -> 51.6%   tech      3.0% ->  9.1%   business 6.4% -> 10.6%
--   science 5.6% ->  9.4%  sports   11.2% -> 12.8%   entertainment 7.6% -> 6.5%
--
--   sciencedaily on-beat    0.0% -> 100.0%     espn on-beat  17.6% -> 100.0%
--   techcrunch   on-beat   15.0% -> 100.0%     cnbc on-beat  13.3% ->  96.7%
--   wired        on-beat    2.0% ->  76.0%
--   BBC technology feed  100% world -> 100% tech
--   BBC business feed    100% world -> 100% business
--
-- THE RANKER IS NOT TOUCHED. get_personalized_feed already fights a lopsided
-- pool — the dom_rank topic penalty sinks the Nth story in a category and the
-- explore slice orders by cat_fresh, both of which favour thin categories. It
-- was never the cause of the imbalance and it needs no change; it needed
-- correct labels, which is what it now gets.
-- ---------------------------------------------------------------------------

alter table public.publishers
  add column if not exists default_category text;

-- The same six values as public.articles.category and the client's enum. NULL
-- is permitted and means "not yet decided": ingest-rss logs a warning and falls
-- back to 'world' for such a row, so a publisher added without this column set
-- degrades to the old behaviour LOUDLY rather than silently.
alter table public.publishers
  drop constraint if exists publishers_default_category_check;
alter table public.publishers
  add constraint publishers_default_category_check
    check (default_category is null or default_category in
      ('tech', 'world', 'business', 'sports', 'science', 'entertainment'));

comment on column public.publishers.default_category is
  'Category for this publisher''s stories when neither the feed section nor '
  'the item''s own tags are confident. For a pure-beat wire this is its beat; '
  'for a general daily it is an explicit ''world''. Exists so that `world` is '
  'never again both a real category and the null value — see migration 0024.';

-- ---------------------------------------------------------------------------
-- The slate. Every enabled publisher gets a value: leaving one NULL would
-- reintroduce exactly the silent fallthrough this column removes.
--
-- The seven beat wires are the rows that were most wrong before, and the ones
-- this column is really for. The nineteen general dailies are 'world' because
-- that is genuinely what their unlabelled output is — their tech, business and
-- sport stories are still picked up by the feed-section and tag rules in
-- _shared/categorize.ts, which run FIRST and override this.
-- ---------------------------------------------------------------------------

update public.publishers set default_category = 'science'
 where id in ('sciencedaily', 'sciencenews');

update public.publishers set default_category = 'sports'
 where id = 'espn';

update public.publishers set default_category = 'tech'
 where id in ('techcrunch', 'theverge', 'wired');

update public.publishers set default_category = 'business'
 where id = 'cnbc';

-- General news outlets. Explicit, not defaulted.
update public.publishers set default_category = 'world'
 where id in (
   'bbc', 'npr', 'euronews', 'france24', 'skynews', 'independent', 'pbs',
   'thehill', 'abcnewsau', 'theguardianau', 'thehindu', 'newindianexpress',
   'deccanherald', 'scroll', 'aljazeera', 'dw', 'csmonitor', 'reason',
   'theguardian');

-- Anything the two statements above missed (a publisher added between phases)
-- is a general outlet until someone says otherwise.
update public.publishers set default_category = 'world'
 where default_category is null;

-- ---------------------------------------------------------------------------
-- Reporting. The audit that produced Phase 18 was only possible by replaying
-- feeds offline with tools/category_harness.mjs; this makes the same question
-- answerable from the database, so the next skew is noticed from the deck
-- rather than from a hand-run script.
--
-- ingest-rss also logs per_category on every run, which covers the write side.
-- This covers what is actually LIVE in the 48h feed pool.
-- ---------------------------------------------------------------------------

create or replace function public.category_mix_report(p_hours integer default 48)
returns table (
  category      text,
  articles      integer,
  share_pct     numeric,
  with_bite     integer,
  publishers    integer)
language sql
stable
security definer
set search_path = public, extensions
as $$
  with pool as (
    select a.category, a.publisher_id, a.ai_summary
      from articles a
      left join publishers pb on pb.id = a.publisher_id
     where a.source <> 'mock'
       and a.source <> 'newsdata'
       and (a.publisher_id is null or pb.enabled)
       and coalesce(a.published_at, a.created_at)
             > now() - make_interval(hours => p_hours)
  )
  select p.category,
         count(*)::integer,
         round(100.0 * count(*) / nullif(sum(count(*)) over (), 0), 1),
         count(*) filter (where btrim(coalesce(p.ai_summary, '')) <> '')::integer,
         count(distinct p.publisher_id)::integer
    from pool p
   group by p.category
   order by count(*) desc;
$$;

revoke all on function public.category_mix_report(integer) from public, anon;
grant execute on function public.category_mix_report(integer) to authenticated;

-- Verify after the next ingest cycle (up to 6h — migration 0021):
--   select * from category_mix_report();
--   select id, region, default_category from publishers where enabled order by id;
