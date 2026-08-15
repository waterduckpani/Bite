-- Bite · Phase 11 (Parts A+B): new swipe semantics + weighted taste model.
-- Run in the SQL editor. Pairs with the client's four-gesture rework
-- (feed_screen.dart / app_state.dart).
--
-- WHAT CHANGES
--   swipe_events.direction vocabulary is replaced:
--       OLD  left  = skip        right = save         up = opened
--       NEW  reject (left)       read (right)         save (down)
--            opened (up/tap, non-terminal — layered on the resolving swipe)
--   The recommender is reweighted onto these signals (see get_personalized_feed).
--
-- HISTORICAL DATA RESET (dev phase, DELIBERATE):
--   Every existing swipe_events row was written under the OLD semantics, where
--   `right` meant SAVE, not READ. Rebuilding the taste vector from them would
--   invert the strongest positive signal and pollute the model. So this
--   migration TRUNCATES swipe_events — the vector rebuilds cleanly under the
--   new meaning. Saves (public.saves) and category prefs are untouched; only
--   the implicit-feedback log is cleared. Not silent: this is the flag.
--
-- Additive to Phase 10: ai_summary/ai_summary_hook still flow through the RPC.
-- Source-agnostic: the Guardian-only NewsData filter from 0006 is preserved.

-- ---------------------------------------------------------------------------
-- 1. Widen the direction vocabulary + clear old-semantics history.
-- ---------------------------------------------------------------------------

-- One row per gesture. `opened` is non-terminal: it never removes a card from
-- the deck, it only feeds the taste vector — the resolving reject/read/save row
-- is what excludes the story.
alter table public.swipe_events
  drop constraint if exists swipe_events_direction_check;

-- Clear before re-constraining so no legacy value trips the new check.
truncate table public.swipe_events;

alter table public.swipe_events
  add constraint swipe_events_direction_check
  check (direction in ('reject', 'read', 'save', 'opened'));

-- ---------------------------------------------------------------------------
-- 2. get_personalized_feed, Phase 11 revision.
--
-- TASTE VECTOR is now a WEIGHTED centroid of the recent positive signals:
--   read   → w_read        (base positive)
--   save   → w_save        (>= read; "interested but deferred" is a strong marker)
--   opened → w_open_boost  (additive: choosing to go deep shows stronger pull)
-- Because a card can log BOTH an `opened` row and its resolving row, the boost
-- is additive for free — the article's embedding simply appears twice.
--
-- Weighting is done with an element-wise Hadamard multiply against a constant
-- weight-vector: `embedding * array_fill(w, array[384])::vector`. Cosine
-- distance is scale-invariant, so the weighted SUM needs no normalization.
--   Requires pgvector >= 0.7 (element-wise `*`). Supabase ships >= 0.7.
--   DEGRADE PATH: if `*` is unavailable, replace the weighted sum with a plain
--   `avg(e.emb)` (uniform positive weights) — still correct in direction.
--
-- AVOID CENTROID is the mean of recent `reject` embeddings (the sole negative);
-- its influence is scaled by w_avoid in the score (this is where W_REJECT lives).
--
-- UNSEEN rule: read/save exclude a story forever; reject only since the feed
-- reset watermark (so "reset feed" resurfaces skipped stories). `opened` does
-- NOT exclude — an opened-but-unresolved card must stay so the user can resolve it.
--
-- Return type is unchanged from 0006, so CREATE OR REPLACE is enough.
-- RLS/grants/blend weights are unchanged (Part D revisits the blend).
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
  -- Ranking blend (unchanged from 0006; Part D revisits).
  w_sim   constant double precision := 0.55;
  w_avoid constant double precision := 0.15;   -- scales the reject centroid
  w_cat   constant double precision := 0.25;
  w_rec   constant double precision := 0.25;
  w_cat_cold constant double precision := 0.60;
  w_rec_cold constant double precision := 0.40;
  half_life_hours constant double precision := 36;
  cold_start_min  constant integer := 5;
  swipe_window    constant integer := 50;
  pool_hours      constant integer := 48;

  -- Phase 11 signal weights for the positive taste centroid.
  w_read       constant double precision := 1.0;
  w_save       constant double precision := 1.3;
  w_open_boost constant double precision := 0.6;

  v_reset     timestamptz;
  v_taste     vector(384);
  v_avoid     vector(384);
  v_positives integer := 0;
begin
  select p.feed_reset_at into v_reset
    from profiles p where p.id = p_user_id;

  -- Weighted positive centroid over the most recent read/save/opened signals.
  select count(*), sum(e.emb * array_fill(e.weight, array[384])::vector(384))
    into v_positives, v_taste
    from (select a.embedding as emb,
                 (case s.direction
                    when 'read'   then w_read
                    when 'save'   then w_save
                    else               w_open_boost   -- 'opened'
                  end) as weight
            from swipe_events s
            join articles a on a.id = s.article_id
           where s.user_id = p_user_id
             and s.direction in ('read', 'save', 'opened')
             and a.embedding is not null
           order by s.created_at desc
           limit swipe_window) e;

  -- Avoid centroid: mean of recent reject embeddings (unweighted — reject is
  -- the only negative, so intra-negative weighting is moot; w_avoid scales it).
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
     -- Dev phase: NewsData disabled as an active source (see 0006). Remove to
     -- re-enable.
     and a.source <> 'newsdata'
     and coalesce(a.published_at, a.created_at) > now() - make_interval(hours => pool_hours)
     -- UNSEEN: read/save are excluded forever; reject only since the feed
     -- reset watermark. `opened` is intentionally absent — an opened card stays
     -- until a resolving swipe removes it.
     and not exists (
       select 1 from swipe_events s
        where s.user_id = p_user_id
          and s.article_id = a.id
          and (s.direction in ('read', 'save')
               or (s.direction = 'reject'
                   and s.created_at > coalesce(v_reset, '-infinity'::timestamptz))))
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
