-- Bite · Phase 11 (Part D): ranking quality — topic anti-domination.
-- Run in the SQL editor. Builds on 0008.
--
-- WHY: the feed is now single-source (Guardian). Without a guard, a strong
-- taste vector plus a busy news day means one hot section (say a dozen fresh
-- politics pieces) can monopolise the top of the deck, collapsing topic spread.
-- Recency alone won't fix it — those stories are genuinely fresh AND on-taste.
--
-- FIX: a soft topic-domination penalty on the PERSONALIZED path. Within each
-- category, stories are ranked by score; the Nth story of a category is docked
-- w_topic_penalty * (N-1). The single best story of a hot topic keeps its place;
-- its 4th/5th/6th are demoted enough that other topics' strong stories interleave.
-- It's a nudge, not a quota — a dominant taste still leads, it just can't run the
-- whole deck. w_topic_penalty is the tunable knob (0 = old pure-score behaviour).
--
-- The COLD-START path (0008 interleave) is unchanged — it already guarantees
-- spread. Recency/taste balance (w_sim 0.55 >> w_rec 0.25) is unchanged: taste
-- still leads, recency stays a meaningful secondary. Return type unchanged from
-- 0008 → CREATE OR REPLACE. Additive to Phase 10; Guardian-only preserved.

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
  -- Part D: per-rank score dock for repeated same-category stories (personalized
  -- path only). Score scale is ~0..1.05, so 0.05 means a category's 5th story
  -- loses ~0.20 — enough for other topics' leaders to interleave. Tunable.
  w_topic_penalty constant double precision := 0.05;
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
      -- Add the by-score freshness rank within each category (dom_rank), which
      -- needs `sc` from the inner select, so it lives one level out.
      select c0.*,
             row_number() over (
               partition by c0.category order by c0.sc desc) as dom_rank
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
        ) c0
    ) c
   order by
     -- Cold start: chosen categories first, then round-robin by freshness rank.
     -- Personalized: score with the topic-domination penalty, then recency.
     case when v_cold and not c.pref then 1 else 0 end,
     case when v_cold then c.rnk else 1 end,
     case when v_cold then c.sc
          else c.sc - w_topic_penalty * (c.dom_rank - 1) end desc,
     c.pub desc
   limit p_limit;
end;
$$;

grant execute on function public.get_personalized_feed(uuid, integer)
  to authenticated;
revoke execute on function public.get_personalized_feed(uuid, integer)
  from anon;
