-- Bite · Phase 15.1 fix: the country nudge was dead for three publishers.
-- Run in the SQL editor after 0018. No function redeploy needed.
--
-- WHAT 0018 GOT WRONG
--
-- 0018 rebuilt the country nudge on three signals after articles.tags went
-- dead with the Guardian API: legacy tags, the publisher's own
-- rss_categories, and the article URL's path segments. Its comment claimed
-- that kept the nudge alive. Measured against the live pool, it did not:
--
--     publisher      rows   rows with NO rss_categories
--     scroll           53            53
--     dw               45            45
--     csmonitor        16            16
--     reason           30             5
--     (the other four)                0
--
-- 114 of 420 rows — 27% of the pool — expose no <category> at all, so for
-- those the URL path was the only signal left. And whole-segment matching
-- finds nothing in the URLs those publishers actually emit:
--
--     dw.com/en/india-and-china-resume-border-talks/a-12345
--                 ^ one segment, equal to no country word
--     scroll.in/article/1076234/the-centre-told-the-court-...
--
-- So Scroll, DW and CSM scored the nudge on exactly zero rows. Not an error,
-- not a log line — just a preference the user set during onboarding quietly
-- meaning nothing for a quarter of what they were shown. Same class of silent
-- no-signal failure as the tag trap 0018 was written to fix.
--
-- THE FIX
--
-- Match hyphen-separated TOKENS within a path segment, not just whole
-- segments. Still purely structural publisher metadata — the URL the
-- publisher chose — and still never the title or snippet, which would turn a
-- placement nudge into keyword filtering.
--
-- KNOWN COST, accepted deliberately: 'us' becomes a matchable token, so a slug
-- like /join-us/ scores the nudge for a US user. This is a +0.1 ADDITIVE
-- placement bonus, not a filter, so a false positive costs one card sitting
-- slightly higher in the deck and nothing else. 'uk', 'india', 'canada' and
-- 'australia' carry no equivalent collision. If US precision ever matters more
-- than US recall, drop the bare 'us' from v_country_words and keep 'us-news'.
--
-- Body is otherwise IDENTICAL to the 0018 version. Return type unchanged, so
-- CREATE OR REPLACE.

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
            -- expose no categories at all (Scroll, DW, CSM) — see the header.
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
                     as e_rank/
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
