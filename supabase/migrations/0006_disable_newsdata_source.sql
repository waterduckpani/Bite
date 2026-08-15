-- Bite · Dev phase: disable NewsData as an active source (Guardian-only).
-- Run in the SQL editor. Pairs with the ingest-news change that gates the
-- NewsData fetch behind SOURCE_ENABLED.newsdata = false.
--
-- Why a feed filter and not a DELETE: NewsData rows already in public.articles
-- are referenced by public.saves and public.swipe_events, both FK'd to
-- articles(id) ON DELETE CASCADE. Purging NewsData rows would cascade-delete
-- users' saved NewsData cards and their swipe history (which also trains the
-- recommender). So instead of deleting, we hide NewsData from the live deck at
-- the feed level. Existing rows are preserved: saved NewsData cards still open
-- from the saves→articles join, and the pool self-purges via
-- purge_old_articles once nothing references them.
--
-- To re-enable NewsData later: flip SOURCE_ENABLED.newsdata back to true in
-- ingest-news/index.ts and drop the `a.source <> 'newsdata'` line below
-- (recreate the function from the 0005 body).
--
-- IDENTICAL to the 0005 get_personalized_feed body except for the single added
-- WHERE predicate `a.source <> 'newsdata'`. Return type is unchanged, so
-- CREATE OR REPLACE is enough (no drop). RLS/grants/weights all unchanged.

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
  half_life_hours constant double precision := 36;
  cold_start_min  constant integer := 5;
  swipe_window    constant integer := 50;
  pool_hours      constant integer := 48;

  v_reset     timestamptz;
  v_taste     vector(384);
  v_avoid     vector(384);
  v_positives integer := 0;
begin
  select p.feed_reset_at into v_reset
    from profiles p where p.id = p_user_id;

  select count(e.embedding), avg(e.embedding)
    into v_positives, v_taste
    from (select a.embedding
            from swipe_events s
            join articles a on a.id = s.article_id
           where s.user_id = p_user_id
             and s.direction in ('right', 'up')
             and a.embedding is not null
           order by s.created_at desc
           limit swipe_window) e;

  select avg(e.embedding)
    into v_avoid
    from (select a.embedding
            from swipe_events s
            join articles a on a.id = s.article_id
           where s.user_id = p_user_id
             and s.direction = 'left'
             and a.embedding is not null
           order by s.created_at desc
           limit swipe_window) e;

  return query
  select a.id, a.source, a.source_name, a.category, a.title, a.snippet,
         a.image_url, a.original_url, a.author, a.read_minutes,
         a.source_icon_url, a.full_text_available, a.published_at,
         (case
            when v_positives >= cold_start_min then
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
          end)::double precision as score,
         a.ai_summary, a.ai_summary_hook
    from articles a
    left join category_prefs cp
      on cp.user_id = p_user_id and cp.category = a.category
   where a.source <> 'mock'
     -- Dev phase: NewsData disabled as an active source. Existing NewsData
     -- rows stay in the table (saved cards + swipe history reference them) but
     -- are hidden from the live deck here. Remove this line to re-enable.
     and a.source <> 'newsdata'
     and coalesce(a.published_at, a.created_at) > now() - make_interval(hours => pool_hours)
     and not exists (
       select 1 from swipe_events s
        where s.user_id = p_user_id
          and s.article_id = a.id
          and (s.direction in ('right', 'up')
               or s.created_at > coalesce(v_reset, '-infinity'::timestamptz)))
   -- 14 = score (see column list above): positional to avoid the plpgsql
   -- variable/column ambiguity on `score`.
   order by 14 desc, coalesce(a.published_at, a.created_at) desc
   limit p_limit;
end;
$$;

grant execute on function public.get_personalized_feed(uuid, integer)
  to authenticated;
revoke execute on function public.get_personalized_feed(uuid, integer)
  from anon;
