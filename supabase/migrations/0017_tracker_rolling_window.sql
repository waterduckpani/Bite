-- Bite · Trackers: a rolling 15-article window.
-- Run in the SQL editor after 0016, then redeploy match-trackers.
--
-- A tracker is a window onto a developing story, not an archive of it. Left
-- unbounded, a tracker on a well-covered story grows without limit — the CJP
-- protest tracker took 22 matches in a single backfill — and the timeline stops
-- reading as "what's new" and starts reading as a second feed.
--
-- So the newest TRACKER_MAX_ARTICLES are kept and older entries fall off as
-- fresh coverage arrives. This is applied at BOTH ends:
--
--   - get_tracker_articles caps what it returns, so the cap holds immediately
--     even before a prune has run;
--   - prune_tracker_timelines deletes the overflow, so storage stays bounded
--     and the article/unread counts on the Tracked list stay honest rather
--     than counting rows nobody can see.
--
-- Note the seed article is NOT pinned: once fifteen newer developments exist,
-- the story you originally followed scrolls off the timeline like anything
-- else. The tracker keeps its title and seed_article_id regardless, and the
-- matcher still refuses to re-add the seed, so nothing breaks.

-- ---------------------------------------------------------------------------
-- prune_tracker_timelines: drop everything past the newest p_max per tracker.
-- Called by match-trackers after each matching pass.
-- ---------------------------------------------------------------------------

create or replace function public.prune_tracker_timelines(
  p_max integer default 15)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_deleted integer;
begin
  with ranked as (
    select tracker_id,
           article_id,
           row_number() over (
             partition by tracker_id order by matched_at desc) as rn
      from public.tracker_articles
  )
  delete from public.tracker_articles ta
   using ranked r
   where ta.tracker_id = r.tracker_id
     and ta.article_id = r.article_id
     and r.rn > p_max;
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

revoke all on function public.prune_tracker_timelines(integer)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- get_tracker_articles, capped. IDENTICAL to the 0013 body except for the
-- LIMIT — including the Phase 14 kill-switch predicate, which stays.
--
-- The cap lives here as well as in the prune so the UI is correct the instant
-- this migration lands, without waiting for a matching cycle.
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
   order by ta.matched_at desc
   limit 15;  -- TRACKER_MAX_ARTICLES; mirrored in prune_tracker_timelines
$$;

grant execute on function public.get_tracker_articles(uuid) to authenticated;

-- Apply the cap once now, so existing over-long timelines are trimmed without
-- waiting for the next matching cycle.
select public.prune_tracker_timelines(15);
