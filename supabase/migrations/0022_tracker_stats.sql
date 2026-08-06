-- Bite · Tracker stats for the Tracked section.
--
-- The Tracked list could only say "N stories · 2h ago", because get_trackers
-- returned nothing else. A followed story is a thread with a shape — where it
-- started, how many outlets have picked it up, how long it has been running —
-- and none of that was reachable from the client without fetching every
-- tracker's full timeline.
--
-- This extends get_trackers with four columns computed in the same lateral
-- joins that already run, so the list stays one round trip:
--
--   seed_source      the outlet the story was followed FROM (its origin)
--   latest_source    the outlet that filed the most recent development
--   source_count     distinct outlets across the whole timeline
--   first_matched_at when the first development landed (NOT created_at)
--
-- Nothing here changes matching, ranking, or what counts as unread. Return
-- type changes require a drop first — the client reads every field null-safely
-- (StoryTracker.fromRow), so an app running against the old shape degrades to
-- the previous display rather than erroring.
-- ---------------------------------------------------------------------------

drop function if exists public.get_trackers(uuid);

create or replace function public.get_trackers(p_user_id uuid default auth.uid())
returns table (
  id               uuid,
  title            text,
  seed_article_id  text,
  created_at       timestamptz,
  muted            boolean,
  last_viewed_at   timestamptz,
  article_count    integer,
  unread_count     integer,
  latest_title     text,
  latest_at        timestamptz,
  seed_source      text,
  latest_source    text,
  source_count     integer,
  first_matched_at timestamptz)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select t.id, t.title, t.seed_article_id, t.created_at, t.muted,
         t.last_viewed_at,
         coalesce(c.article_count, 0)::integer,
         coalesce(c.unread_count, 0)::integer,
         l.title,
         l.matched_at,
         s.source_name,
         l.source_name,
         coalesce(c.source_count, 0)::integer,
         c.first_matched_at
    from story_trackers t
    left join lateral (
      select count(*) as article_count,
             count(*) filter (where not ta.seen) as unread_count,
             count(distinct a.source_name) as source_count,
             min(ta.matched_at) as first_matched_at
        from tracker_articles ta
        join articles a on a.id = ta.article_id
       where ta.tracker_id = t.id) c on true
    left join lateral (
      select a.title, a.source_name, ta.matched_at
        from tracker_articles ta
        join articles a on a.id = ta.article_id
       where ta.tracker_id = t.id
       order by ta.matched_at desc
       limit 1) l on true
    -- The seed article can be purged from the pool while the tracker lives on,
    -- so this is a left join: no origin outlet is a display gap, not a missing
    -- row.
    left join articles s on s.id = t.seed_article_id
   where t.user_id = p_user_id
   order by coalesce(l.matched_at, t.created_at) desc;
$$;

grant execute on function public.get_trackers(uuid) to authenticated;
