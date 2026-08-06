-- Bite · Phase 7: content-based recommendations (closes Phase 5 cold start).
-- Run in the SQL editor AFTER deploying the "embed" Edge Function:
--   supabase functions deploy embed --no-verify-jwt
--   supabase secrets set EMBED_SECRET=fc2c879b849d43b465ddf1f2ae6a1219a164f52eca090482
--
-- Embedding pipeline choice: a direct pg_net trigger + a pg_cron sweep, not
-- the pgmq "automatic embeddings" queue. Volume is tiny (a few hundred
-- articles/day) and the cron sweep already provides retries and the one-time
-- backfill for free; a real queue would add moving parts with no benefit at
-- this scale. The triggers are statement-level, so the client's bulk upsert
-- of a whole fetched pool costs ONE function invocation, and the function
-- itself drains every null-embedding row in batches.

create extension if not exists pg_net;   -- installs the `net` schema
create extension if not exists pg_cron;

-- ---------------------------------------------------------------------------
-- Where the embed function lives. Vault (not hardcoded SQL) so the secret can
-- be rotated without touching triggers. The secret must match EMBED_SECRET on
-- the deployed function.
-- ---------------------------------------------------------------------------

select vault.create_secret(
  'https://sbykpnhswupezuetpzhl.supabase.co/functions/v1/embed',
  'embed_fn_url');
select vault.create_secret(
  'fc2c879b849d43b465ddf1f2ae6a1219a164f52eca090482',
  'embed_fn_secret');

-- ---------------------------------------------------------------------------
-- Embedding pipeline: nudge the Edge Function whenever articles may need
-- embeddings. Fire-and-forget; the function finds its own work.
-- ---------------------------------------------------------------------------

create or replace function public.invoke_embed()
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
    from vault.decrypted_secrets where name = 'embed_fn_url';
  select decrypted_secret into v_secret
    from vault.decrypted_secrets where name = 'embed_fn_secret';
  if v_url is null then
    return;
  end if;
  perform net.http_post(
    url     := v_url,
    body    := '{}'::jsonb,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-embed-secret', coalesce(v_secret, '')));
end;
$$;

-- Only the triggers and cron below should call this.
revoke all on function public.invoke_embed() from public, anon, authenticated;

create or replace function public.articles_embed_trigger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from new_rows where embedding is null) then
    perform public.invoke_embed();
  end if;
  return null;
end;
$$;

-- Statement-level with transition tables: one webhook call per bulk upsert,
-- and only when the statement actually produced rows that need embedding.
create trigger articles_embed_on_insert
  after insert on public.articles
  referencing new table as new_rows
  for each statement
  execute function public.articles_embed_trigger();

create trigger articles_embed_on_update
  after update on public.articles
  referencing new table as new_rows
  for each statement
  execute function public.articles_embed_trigger();

-- Sweep every 10 minutes: retries anything a trigger-time call missed (edge
-- function cold start, transient failure) and performs the one-time backfill
-- of pre-Phase-7 rows on its first run.
select cron.schedule(
  'bite-embed-sweep', '*/10 * * * *', 'select public.invoke_embed()');

-- ---------------------------------------------------------------------------
-- get_personalized_feed: ranked, unseen articles for the deck.
--
-- Taste vector = mean embedding of the user's recent positive swipes
-- (right = save, up = read); a separate "avoid" centroid from recent left
-- swipes pushes the ranking away from dismissed topics. Cosine distance is
-- scale-invariant, so the mean needs no explicit normalization.
--
-- COLD START (fewer than cold_start_min positive swipes with embeddings):
-- rank by onboarding category_prefs + recency — this is what closes Phase 5.
--
-- SECURITY INVOKER on purpose: every table read goes through the Phase 3 RLS
-- policies, so passing another user's id yields their (invisible) rows =
-- an unpersonalized recency feed, never their data.
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
  w_rec   constant double precision := 0.20;
  w_cat_cold constant double precision := 0.60;
  w_rec_cold constant double precision := 0.40;
  half_life_hours constant double precision := 36;
  cold_start_min  constant integer := 5;
  swipe_window    constant integer := 50;  -- most recent swipes per centroid
  pool_days       constant integer := 7;   -- candidate freshness window

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
     and coalesce(a.published_at, a.created_at) > now() - make_interval(days => pool_days)
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

grant execute on function public.get_personalized_feed(uuid, integer)
  to authenticated;
revoke execute on function public.get_personalized_feed(uuid, integer)
  from anon;
