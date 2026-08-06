-- Bite · Phase 13: Story Trackers.
-- Run in the SQL editor AFTER deploying the "match-trackers" Edge Function:
--   supabase secrets set MATCH_SECRET=b4e8a1f7c92d5063a8f14e7b3c096d2fa5813e6d47b9c0a2
--   supabase functions deploy match-trackers --no-verify-jwt
--
-- Trackers are a self-contained system that lives ALONGSIDE the swipe feed:
-- get_personalized_feed, the taste vector, and the exploration slice are all
-- untouched here. A tracker never boosts or bypasses main-feed ranking — the
-- two systems stay independently debuggable (Phase 13 hard constraint #1).
--
-- Matching is hybrid (Guardian tags AND embedding), so the article pool needs
-- to carry its Guardian tags; the tags column below is populated by the
-- reworked ingest-news function. No notifications this phase: unread state is
-- tracked per matched article (tracker_articles.seen) for an in-app badge, and
-- the schema leaves room to add push later without migration churn.

-- ---------------------------------------------------------------------------
-- Article tags (Guardian keyword tag ids, e.g. "world/russia"). The same-story
-- signal the matcher leans on hardest. Backfills empty; ingest-news fills new
-- rows and re-upserts refresh existing ones.
-- ---------------------------------------------------------------------------

alter table public.articles
  add column if not exists tags text[] not null default '{}';

-- ---------------------------------------------------------------------------
-- Trackers and their matched-article timelines.
--
-- centroid_embedding + tag_set are seeded from the seed article at creation
-- (reusing the Phase 7 embedding — never recomputed). seed_article_id is
-- nullable / ON DELETE SET NULL so a tracker outlives its seed article if the
-- article is ever purged; the seed also lives on as the first tracker_articles
-- row. muted stops future matching without deleting history. last_viewed_at +
-- tracker_articles.seen drive the in-app unread badge.
-- ---------------------------------------------------------------------------

create table if not exists public.story_trackers (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references auth.users (id) on delete cascade,
  title              text not null,
  seed_article_id    text references public.articles (id) on delete set null,
  centroid_embedding extensions.vector(384),
  tag_set            text[] not null default '{}',
  created_at         timestamptz not null default now(),
  muted              boolean not null default false,
  last_viewed_at     timestamptz,
  -- One tracker per (user, seed story): the guard behind "can't double-follow".
  unique (user_id, seed_article_id)
);

create index if not exists story_trackers_user_idx
  on public.story_trackers (user_id);

create table if not exists public.tracker_articles (
  tracker_id  uuid not null references public.story_trackers (id) on delete cascade,
  article_id  text not null references public.articles (id) on delete cascade,
  matched_at  timestamptz not null default now(),
  match_score double precision,
  seen        boolean not null default false,
  primary key (tracker_id, article_id)
);

create index if not exists tracker_articles_tracker_idx
  on public.tracker_articles (tracker_id);

-- ---------------------------------------------------------------------------
-- RLS: a tracker and its articles are private to the owning user. Guests
-- (anonymous auth) own trackers exactly like saves/swipes, so an email-OTP
-- upgrade — which keeps the same uid — carries them over untouched.
-- The match-trackers Edge Function uses the service-role key and bypasses RLS.
-- ---------------------------------------------------------------------------

alter table public.story_trackers  enable row level security;
alter table public.tracker_articles enable row level security;

create policy "own trackers: all" on public.story_trackers
  for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

-- tracker_articles has no user_id of its own; ownership flows through the
-- parent tracker.
create policy "own tracker_articles: all" on public.tracker_articles
  for all to authenticated
  using (exists (select 1 from public.story_trackers t
                  where t.id = tracker_id and t.user_id = (select auth.uid())))
  with check (exists (select 1 from public.story_trackers t
                       where t.id = tracker_id and t.user_id = (select auth.uid())));

grant select, insert, update, delete on public.story_trackers  to authenticated;
grant select, insert, update, delete on public.tracker_articles to authenticated;

-- ---------------------------------------------------------------------------
-- create_tracker: seed a tracker from an article, copying its existing
-- embedding + Guardian tags (SECURITY INVOKER, so RLS + auth.uid() gate it).
-- Idempotent on (user, seed) so a double-tap or an offline-queue retry can't
-- create a second tracker for the same story. Returns the tracker id (existing
-- one on a duplicate), or null when the per-user cap is hit or the article is
-- unknown.
-- ---------------------------------------------------------------------------

create or replace function public.create_tracker(
  p_id              uuid,
  p_seed_article_id text,
  p_title           text)
returns uuid
language plpgsql
security invoker
set search_path = public, extensions
as $$
declare
  max_trackers constant integer := 20;  -- MAX_TRACKERS_PER_USER
  v_count integer;
  v_id    uuid;
begin
  select count(*) into v_count
    from story_trackers where user_id = auth.uid();
  if v_count >= max_trackers then
    return null;
  end if;

  insert into story_trackers (id, user_id, title, seed_article_id,
                              centroid_embedding, tag_set)
  select p_id, auth.uid(),
         coalesce(nullif(trim(p_title), ''), a.title),
         a.id, a.embedding, a.tags
    from articles a
   where a.id = p_seed_article_id
  on conflict (user_id, seed_article_id) do nothing
  returning id into v_id;

  if v_id is null then
    -- Already following this story (or the article is unknown to the pool).
    select id into v_id from story_trackers
     where user_id = auth.uid() and seed_article_id = p_seed_article_id;
    return v_id;
  end if;

  -- The seed article is the first entry in the timeline, marked seen.
  insert into tracker_articles (tracker_id, article_id, match_score, seen)
  values (v_id, p_seed_article_id, 1.0, true)
  on conflict (tracker_id, article_id) do nothing;

  return v_id;
end;
$$;

grant execute on function public.create_tracker(uuid, text, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- get_trackers: the Tracked list view — one row per tracker with its article
-- count, unread count, and most-recent development (headline + time). Sorted
-- newest-activity first. SECURITY INVOKER: RLS scopes it to the caller.
-- ---------------------------------------------------------------------------

create or replace function public.get_trackers(p_user_id uuid default auth.uid())
returns table (
  id              uuid,
  title           text,
  seed_article_id text,
  created_at      timestamptz,
  muted           boolean,
  last_viewed_at  timestamptz,
  article_count   integer,
  unread_count    integer,
  latest_title    text,
  latest_at       timestamptz)
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
         l.matched_at
    from story_trackers t
    left join lateral (
      select count(*) as article_count,
             count(*) filter (where not ta.seen) as unread_count
        from tracker_articles ta
       where ta.tracker_id = t.id) c on true
    left join lateral (
      select a.title, ta.matched_at
        from tracker_articles ta
        join articles a on a.id = ta.article_id
       where ta.tracker_id = t.id
       order by ta.matched_at desc
       limit 1) l on true
   where t.user_id = p_user_id
   order by coalesce(l.matched_at, t.created_at) desc;
$$;

grant execute on function public.get_trackers(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- get_tracker_articles: a tracker's developing timeline in reverse-chronological
-- order (newest match first). Not personalised — a story timeline, not a feed.
-- Carries the Phase 10 bite (ai_summary/hook) for rendering.
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
   order by ta.matched_at desc;
$$;

grant execute on function public.get_tracker_articles(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- mark_tracker_seen: clear a tracker's unread articles and stamp last_viewed_at
-- when its detail view is opened. RLS scopes both updates to the caller.
-- ---------------------------------------------------------------------------

create or replace function public.mark_tracker_seen(p_tracker_id uuid)
returns void
language sql
security invoker
set search_path = public, extensions
as $$
  update public.tracker_articles
     set seen = true
   where tracker_id = p_tracker_id and not seen;
  update public.story_trackers
     set last_viewed_at = now()
   where id = p_tracker_id;
$$;

grant execute on function public.mark_tracker_seen(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- run_tracker_matching: the hybrid matcher, set-based in SQL so pgvector does
-- the cosine work. Called by the match-trackers Edge Function, which owns the
-- tunable weights/threshold and logs the returned matches (Phase 9 style).
--
-- Hybrid score = W_TAG * jaccard(tags, tracker.tag_set)
--              + W_EMBED * cosine(embedding, tracker.centroid).
-- Tags are Guardian's structured same-story signal; the embedding catches
-- related coverage tagged differently. A row is matched when score >=
-- threshold and it isn't already on the tracker (nor the seed).
--
-- SECURITY DEFINER + service-role only: it writes across every user's
-- trackers, so it must never be reachable by authenticated/anon.
-- ---------------------------------------------------------------------------

create or replace function public.run_tracker_matching(
  p_w_tag        double precision,
  p_w_embed      double precision,
  p_threshold    double precision,
  p_window_hours integer,
  p_drift        double precision,
  p_max_drift    double precision)
returns table (
  tracker_id  uuid,
  article_id  text,
  match_score double precision,
  tag_score   double precision,
  embed_score double precision)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  return query
  with candidates as (
    select a.id, a.tags, a.embedding
      from articles a
     where a.source <> 'mock'
       and coalesce(a.published_at, a.created_at)
             > now() - make_interval(hours => p_window_hours)
  ),
  scored as (
    select t.id as s_tracker_id,
           c.id as s_article_id,
           -- Jaccard tag overlap: |A∩B| / |A∪B| (0 when both sets empty).
           (case
              when cardinality(t.tag_set) = 0 or cardinality(c.tags) = 0 then 0
              else (
                (select count(*)::double precision
                   from (select unnest(t.tag_set)
                         intersect
                         select unnest(c.tags)) inter)
                / nullif((select count(*)::double precision
                            from (select unnest(t.tag_set)
                                  union
                                  select unnest(c.tags)) uni), 0))
            end) as s_tag,
           (case
              when t.centroid_embedding is not null and c.embedding is not null
              then 1 - (c.embedding <=> t.centroid_embedding)
              else 0
            end) as s_embed
      from story_trackers t
      cross join candidates c
     where not t.muted
       and c.id is distinct from t.seed_article_id
       and not exists (
         select 1 from tracker_articles ta
          where ta.tracker_id = t.id and ta.article_id = c.id)
  ),
  eligible as (
    select s_tracker_id, s_article_id, s_tag, s_embed,
           (p_w_tag * s_tag + p_w_embed * s_embed) as s_score
      from scored
  ),
  inserted as (
    insert into tracker_articles (tracker_id, article_id, match_score, seen)
    select e.s_tracker_id, e.s_article_id, e.s_score, false
      from eligible e
     where e.s_score >= p_threshold
    on conflict (tracker_id, article_id) do nothing
    -- Qualify to the table: bare tracker_id/article_id/match_score would be
    -- ambiguous with the RETURNS TABLE out-params of the same name.
    returning tracker_articles.tracker_id   as i_tracker_id,
              tracker_articles.article_id   as i_article_id,
              tracker_articles.match_score  as i_score
  )
  select i.i_tracker_id, i.i_article_id, i.i_score, e.s_tag, e.s_embed
    from inserted i
    join eligible e
      on e.s_tracker_id = i.i_tracker_id and e.s_article_id = i.i_article_id;

  -- Centroid drift (default off, p_drift = 0). Nudge each tracker's centroid
  -- toward the mean embedding of the articles JUST matched to it, renormalised
  -- — but only while the drifted centroid stays within p_max_drift cosine
  -- distance of the seed article's embedding (the anchor), so a long-running
  -- tracker can evolve without wandering off its original story.
  if p_drift > 0 then
    update story_trackers t
       set centroid_embedding = d.new_centroid
      from (
        select st.id as tracker_id,
               st.seed_article_id,
               l2_normalize(
                 (1 - p_drift) * st.centroid_embedding
                 + p_drift * avg(a.embedding))::vector(384) as new_centroid
          from tracker_articles ta
          join story_trackers st on st.id = ta.tracker_id
          join articles a on a.id = ta.article_id
         where ta.matched_at > now() - interval '2 minutes'  -- just inserted
           and st.centroid_embedding is not null
           and a.embedding is not null
         group by st.id, st.seed_article_id, st.centroid_embedding
      ) d
     where t.id = d.tracker_id
       and (
         d.seed_article_id is null
         or exists (
           select 1 from articles seed
            where seed.id = d.seed_article_id
              and seed.embedding is not null
              and (1 - (d.new_centroid <=> seed.embedding)) >= (1 - p_max_drift)));
  end if;
end;
$$;

revoke all on function public.run_tracker_matching(
  double precision, double precision, double precision,
  integer, double precision, double precision)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Matching pipeline: nudge the match-trackers Edge Function on the ingestion
-- cadence, AFTER ingest (0,30) and summarise (5,35). Mirrors invoke_embed:
-- vault-stored url+secret so they rotate without touching this function.
-- ---------------------------------------------------------------------------

select vault.create_secret(
  'https://sbykpnhswupezuetpzhl.supabase.co/functions/v1/match-trackers',
  'match_trackers_fn_url');
select vault.create_secret(
  'b4e8a1f7c92d5063a8f14e7b3c096d2fa5813e6d47b9c0a2',
  'match_trackers_fn_secret');

create or replace function public.invoke_match_trackers()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url    text;
  v_secret text;
begin
  select decrypted_secret into v_url
    from vault.decrypted_secrets where name = 'match_trackers_fn_url';
  select decrypted_secret into v_secret
    from vault.decrypted_secrets where name = 'match_trackers_fn_secret';
  if v_url is null then
    return;
  end if;
  perform net.http_post(
    url     := v_url,
    body    := '{}'::jsonb,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-match-secret', coalesce(v_secret, '')));
end;
$$;

revoke all on function public.invoke_match_trackers() from public, anon, authenticated;

-- 15,45: after ingest (0,30) and summarise (5,35), so newly matched articles
-- already carry embeddings and bites.
select cron.schedule(
  'bite-match-trackers', '15,45 * * * *',
  'select public.invoke_match_trackers()');

-- ---------------------------------------------------------------------------
-- purge_old_articles, rev 3 (from 0004): additionally keep any article a
-- tracker still references — either as a seed or anywhere in a timeline — so
-- retention can't silently gut a long-running tracker's history.
-- ---------------------------------------------------------------------------

create or replace function public.purge_old_articles()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  retention_days       constant integer := 14;
  body_retention_hours constant integer := 48;
  v_deleted integer;
begin
  delete from public.article_bodies b
   where b.fetched_at < now() - make_interval(hours => body_retention_hours);

  delete from public.articles a
   where a.created_at < now() - make_interval(days => retention_days)
     and a.source <> 'mock'
     and not exists (select 1 from public.saves s where s.article_id = a.id)
     and not exists (select 1 from public.swipe_events e where e.article_id = a.id)
     and not exists (select 1 from public.tracker_articles ta where ta.article_id = a.id)
     and not exists (select 1 from public.story_trackers st where st.seed_article_id = a.id);
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

revoke all on function public.purge_old_articles() from public, anon, authenticated;
