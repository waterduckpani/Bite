-- Bite · Phase 15.2: the feed surfaces only summarised articles.
-- Run in the SQL editor after 0019.
--
-- WHY
--
-- Phase 15.2 puts the AI bite on the card face: the hook is the headline and
-- the 50–80 word summary is the body. That makes the bite the product, and it
-- makes a bite-less row unrenderable — there is no raw publisher description
-- to fall back to any more, because falling back to one is precisely what the
-- card is no longer allowed to show.
--
-- The client keeps a minimal fallback (publisher headline, no body block) for
-- rows written before this gate — saved cards and tracker timelines still
-- hydrate straight from `articles` and are NOT gated, since a story the user
-- already kept should not vanish. But nothing bite-less enters the swipe deck.
--
-- WHAT THIS COSTS
--
-- Un-summarised rows are not dropped, only deferred: they sit in the pool
-- until the next summarise-articles cron run fills ai_summary, then enter the
-- feed normally. The deck is thinner in the window between an ingest tick and
-- the summarise tick that follows it. If it thins noticeably, that is a
-- summarisation-throughput signal — raise the cron rate or the per-run batch
-- size — not a reason to show bite-less cards.
--
-- Both halves are checked because the card needs both: the hook is the
-- headline and the summary is the body, and `hasSummary` on the client is
-- likewise an AND. A row with one half present would pass a single-column
-- gate and still render as a fallback card.
--
-- ALSO FIXED HERE: a stray '/' after `as e_rank` in the 0019 body
-- (explore_pick's inner select), which is a syntax error — if 0019 applied
-- cleanly, the live function is the 0018 body and the URL-token country nudge
-- never took effect. Re-applying this migration installs both fixes.
--
-- Ranking, exploration and slotting are UNCHANGED. The gate lives in `cand`,
-- so the explore slice and the main deck are both drawn from the same gated
-- pool and interleave exactly as before — there is no path by which an
-- un-summarised row reaches a slot. Return type unchanged, so CREATE OR
-- REPLACE.

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
  -- whole category value, or against a whole hyphen-separated TOKEN of a URL
  -- path segment. Never as a substring — 'us' as a substring would match half
  -- the web ("industry", "campus", "focus").
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
            -- section labels OR a hyphen-separated token of the article URL's
            -- path. The third branch is what carries the three publishers that
            -- expose no categories at all (Scroll, DW, CSM) — see 0019.
            + (case when (v_country_tag is not null and exists (
                  select 1 from unnest(a.tags) tg
                   where v_country_tag = any(string_to_array(tg, '/'))))
                 or (v_country_words is not null and exists (
                  select 1 from unnest(a.rss_categories) rc
                   where lower(trim(rc)) = any(v_country_words)))
                 or (v_country_words is not null and exists (
                  select 1
                    from unnest(string_to_array(
                           lower(coalesce(a.original_url, '')), '/')) seg,
                         unnest(string_to_array(seg, '-')) tok
                   where tok = any(v_country_words)))
                then w_country else 0 end))::double precision as sc,
           (cp.category is not null) as pref,
           coalesce(a.published_at, a.created_at) as pub,
           coalesce(a.category = any(v_strong_cats), false) as strong
      from articles a
      left join category_prefs cp
        on cp.user_id = p_user_id and cp.category = a.category
     where a.source <> 'mock'
       and a.source <> 'newsdata'
       -- PHASE 15.2 BITE GATE. Every card shows an AI bite, so a row without
       -- one is not a candidate. Deferred, not dropped: it enters the feed
       -- after the next summarise-articles run fills these two columns.
       and btrim(coalesce(a.ai_summary, '')) <> ''
       and btrim(coalesce(a.ai_summary_hook, '')) <> ''
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

-- Partial index for the gate: the pool scan now filters on both bite columns
-- before anything else, and the un-summarised tail grows between cron runs.
create index if not exists articles_bite_pool_idx
  on public.articles (coalesce(published_at, created_at) desc)
  where ai_summary is not null and ai_summary_hook is not null;
