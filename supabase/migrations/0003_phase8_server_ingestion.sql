-- Bite · Phase 8: server-side ingestion, freshness, and retention.
-- Run in the SQL editor AFTER deploying the "ingest-news" Edge Function:
--   supabase secrets set --env-file supabase/functions/.env.secrets
--   supabase functions deploy ingest-news --no-verify-jwt
--
-- News ingestion moves off the client: a pg_cron job invokes ingest-news
-- (Guardian + NewsData → public.articles) so NewsData credit spend is a
-- function of cron frequency, not user count, and the news-API keys live in
-- Edge Function secrets instead of the app bundle. The Phase 7 triggers on
-- public.articles already invoke the embed function for new rows, so
-- ingested stories get embeddings with no extra wiring.

-- ---------------------------------------------------------------------------
-- Where the ingest function lives. Vault (not hardcoded SQL) so the secret
-- can be rotated without touching the cron job. The secret must match
-- INGEST_SECRET on the deployed function.
-- ---------------------------------------------------------------------------

select vault.create_secret(
  'https://sbykpnhswupezuetpzhl.supabase.co/functions/v1/ingest-news',
  'ingest_fn_url');
select vault.create_secret(
  '89e3f4305c90013c09a7f0c365c4f97317a1df9688d1118f',
  'ingest_fn_secret');

create or replace function public.invoke_ingest()
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
    from vault.decrypted_secrets where name = 'ingest_fn_url';
  select decrypted_secret into v_secret
    from vault.decrypted_secrets where name = 'ingest_fn_secret';
  if v_url is null then
    return;
  end if;
  perform net.http_post(
    url     := v_url,
    body    := '{}'::jsonb,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-ingest-secret', coalesce(v_secret, '')));
end;
$$;

-- Only the cron job below should call this.
revoke all on function public.invoke_ingest() from public, anon, authenticated;

-- Every 30 minutes. CREDIT MATH before tuning: each run spends 3 NewsData
-- credits (NEWSDATA_PAGES in ingest-news/index.ts) against the free tier's
-- 200/day — 48 runs × 3 = 144/day. Every 20 minutes would be 216/day and
-- BLOW THE BUDGET; drop to 2 pages before going faster. Guardian is a
-- non-issue (48 of 5,000/day).
select cron.schedule(
  'bite-ingest-news', '*/30 * * * *', 'select public.invoke_ingest()');

-- ---------------------------------------------------------------------------
-- get_personalized_feed, Phase 8 revision. Two changes from 0002:
--   - pool window: 7 days → pool_hours (48h). The deck is news again; 48h
--     rather than 24h because NewsData's free tier delivers stories ~12h
--     late, so a tighter floor would starve the NewsData half of the pool.
--   - w_rec 0.20 → 0.25: recency gets a slightly louder voice so
--     stale-but-similar stories stop topping the deck.
-- Everything else (taste/avoid centroids, cold start, unseen filtering,
-- SECURITY INVOKER + RLS) is unchanged from 0002.
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
  score               double precision)
language plpgsql
stable
set search_path = public, extensions
as $$
declare
  -- Tunable weights. Personalized blend: embedding similarity dominates,
  -- category prefs keep the feed anchored to chosen topics, recency decay
  -- keeps it news. w_avoid subtracts similarity to recently dismissed
  -- stories. Cold start reweights onto prefs + recency only.
  w_sim   constant double precision := 0.55;
  w_avoid constant double precision := 0.15;
  w_cat   constant double precision := 0.25;
  w_rec   constant double precision := 0.25;
  w_cat_cold constant double precision := 0.60;
  w_rec_cold constant double precision := 0.40;
  half_life_hours constant double precision := 36;
  cold_start_min  constant integer := 5;
  swipe_window    constant integer := 50;  -- most recent swipes per centroid
  -- Candidate freshness window. Tune here; keep >= 24 or NewsData's ~12h
  -- free-tier delay starves that half of the pool.
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
              -- Not-yet-embedded articles score a neutral 0.5 similarity so
              -- brand-new stories still surface until the pipeline catches up.
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
          end)::double precision as score
    from articles a
    left join category_prefs cp
      on cp.user_id = p_user_id and cp.category = a.category
   where a.source <> 'mock'  -- bundled demo stories never enter live feeds
     and coalesce(a.published_at, a.created_at) > now() - make_interval(hours => pool_hours)
     -- UNSEEN only: saves and reads are excluded forever; dismissals (left)
     -- only since the profile's feed-reset watermark, so "reset feed"
     -- resurfaces previously skipped stories — mirroring the client.
     and not exists (
       select 1 from swipe_events s
        where s.user_id = p_user_id
          and s.article_id = a.id
          and (s.direction in ('right', 'up')
               or s.created_at > coalesce(v_reset, '-infinity'::timestamptz)))
   -- 14 = score: RETURNS TABLE makes `score` a plpgsql variable, so naming
   -- it here would be ambiguous.
   order by 14 desc, coalesce(a.published_at, a.created_at) desc
   limit p_limit;
end;
$$;

-- Grants from 0002 carry over (create or replace keeps ACLs), restated for
-- self-containedness.
grant execute on function public.get_personalized_feed(uuid, integer)
  to authenticated;
revoke execute on function public.get_personalized_feed(uuid, integer)
  from anon;

-- ---------------------------------------------------------------------------
-- Retention: without a purge, cron ingestion grows public.articles without
-- bound (~a few hundred rows/day). Delete old articles nobody interacted
-- with. NEVER delete saved articles. Swiped articles are also kept — not
-- just because swipe_events must stay intact (they train the recommender,
-- and its FK cascades article deletion onto them), but because the taste
-- centroids in get_personalized_feed read the embeddings of recently swiped
-- articles. Untouched pool rows are the unbounded growth; interacted rows
-- grow only with actual usage.
-- ---------------------------------------------------------------------------

create or replace function public.purge_old_articles()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  retention_days constant integer := 14;
  v_deleted integer;
begin
  delete from public.articles a
   where a.created_at < now() - make_interval(days => retention_days)
     and a.source <> 'mock'
     and not exists (select 1 from public.saves s where s.article_id = a.id)
     and not exists (select 1 from public.swipe_events e where e.article_id = a.id);
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

revoke all on function public.purge_old_articles() from public, anon, authenticated;

-- Daily, at a quiet minute offset (pg_cron runs in UTC).
select cron.schedule(
  'bite-purge-articles', '43 4 * * *', 'select public.purge_old_articles()');
