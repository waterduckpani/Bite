-- Bite · Phase 11 (Part C): onboarding tutorial flag + cold-start diversity.
-- Run in the SQL editor. Pairs with the client's gesture tutorial + the
-- picks-seeded cold start.
--
-- WHAT CHANGES
--   1. profiles.gesture_tutorial_version — persists that a user has seen the
--      gesture coach-mark at a given TUTORIAL_VERSION (client re-shows when the
--      constant is bumped). Mirrors `onboarded`.
--   2. get_personalized_feed cold-start path is reworked from "category flag +
--      recency" (which lets one hot category flood the deck) into a
--      CATEGORY-DIVERSE INTERLEAVE: the freshest story of each preferred
--      category first, then the second-freshest of each, and so on. A brand-new
--      user with only onboarding picks (zero swipes) gets a coherent feed spread
--      across every topic they chose — the picks ARE the cold-start taste seed.
--
-- The personalized path (>= cold_start_min positive swipes) is byte-for-byte the
-- 0007 behaviour. Additive to Phase 10 (ai_summary/ai_summary_hook still flow);
-- Guardian-only NewsData filter preserved. Return type unchanged from 0007, so
-- CREATE OR REPLACE is enough.

-- ---------------------------------------------------------------------------
-- 1. Tutorial-seen watermark on profiles.
-- ---------------------------------------------------------------------------

alter table public.profiles
  add column if not exists gesture_tutorial_version integer not null default 0;

-- ---------------------------------------------------------------------------
-- 2. get_personalized_feed, Phase 11 Part C revision (cold-start diversity).
--
-- The scoring math is unchanged; only the COLD-START ORDERING changes. A single
-- subquery computes, per candidate:
--   sc   — the blended score (personalized OR cold, same CASE as 0007)
--   pref — is the article in one of the user's chosen categories
--   rnk  — freshness rank WITHIN its category (1 = freshest of that category)
--   pub  — published/created timestamp for recency tie-breaks
-- The outer ORDER BY then branches on v_cold:
--   personalized → order by sc desc, pub desc          (exactly as before)
--   cold-start   → preferred categories first, then round-robin by rnk (spread
--                  across topics), then sc/recency inside each interleave tier.
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
  half_life_hours constant double precision := 36;
  cold_start_min  constant integer := 5;
  swipe_window    constant integer := 50;
  pool_hours      constant integer := 48;

  w_read       constant double precision := 1.0;
  w_save       constant double precision := 1.3;
  w_open_boost constant double precision := 0.6;

  v_reset     timestamptz;
  v_taste     vector(384);
  v_avoid     vector(384);
  v_positives integer := 0;
  v_cold      boolean;
begin
  select p.feed_reset_at into v_reset
    from profiles p where p.id = p_user_id;

  -- Weighted positive centroid over recent read/save/opened signals.
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

  return query
  select c.id, c.source, c.source_name, c.category, c.title, c.snippet,
         c.image_url, c.original_url, c.author, c.read_minutes,
         c.source_icon_url, c.full_text_available, c.published_at,
         c.sc, c.ai_summary, c.ai_summary_hook
    from (
      select a.id, a.source, a.source_name, a.category, a.title, a.snippet,
             a.image_url, a.original_url, a.author, a.read_minutes,
             a.source_icon_url, a.full_text_available, a.published_at,
             a.ai_summary, a.ai_summary_hook,
             (case
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
              end)::double precision as sc,
             (cp.category is not null) as pref,
             row_number() over (
               partition by a.category
               order by coalesce(a.published_at, a.created_at) desc) as rnk,
             coalesce(a.published_at, a.created_at) as pub
        from articles a
        left join category_prefs cp
          on cp.user_id = p_user_id and cp.category = a.category
       where a.source <> 'mock'
         and a.source <> 'newsdata'   -- dev-phase Guardian-only (see 0006)
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
    ) c
   order by
     -- Cold start only: chosen categories first, then round-robin across them
     -- (freshest-of-each before any second-of-each). Personalized: both keys
     -- collapse to constants, leaving score-then-recency exactly as 0007.
     case when v_cold and not c.pref then 1 else 0 end,
     case when v_cold then c.rnk else 1 end,
     c.sc desc,
     c.pub desc
   limit p_limit;
end;
$$;

grant execute on function public.get_personalized_feed(uuid, integer)
  to authenticated;
revoke execute on function public.get_personalized_feed(uuid, integer)
  from anon;
