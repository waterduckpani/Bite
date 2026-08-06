-- Bite · Phase 10: AI summaries.
-- Run in the SQL editor AFTER deploying the "summarize-articles" Edge Function:
--   supabase secrets set --env-file supabase/functions/.env.secrets
--   supabase functions deploy summarize-articles --no-verify-jwt
--
-- A separate summarisation worker (summarize-articles) reads licensed full
-- body text — right now Guardian bodies via the guardian-body proxy — and
-- writes a Bite-voice hook + 2-3 sentence summary back onto the article row.
-- The client never summarises and never holds the model key; it just reads
-- two more display columns off the feed. A missing summary is normal: cards
-- fall back to the standfirst/snippet exactly as before.
--
-- Additive only. Nothing here changes ranking, ingestion, or retention.

-- ---------------------------------------------------------------------------
-- Summary columns on public.articles.
--   ai_summary        the 2-3 sentence body summary (client-visible)
--   ai_summary_hook   a one-line hook / plain-spoken headline (client-visible)
--   ai_summary_model  the model slug that produced it (A/B + debugging)
--   ai_summary_status null (never attempted) | pending | done | failed
--   ai_summary_attempts retry-cap counter
--   ai_summarized_at  when the summary was written
-- The status/attempts/model columns are server-internal — the RPC below only
-- surfaces ai_summary and ai_summary_hook to clients.
-- ---------------------------------------------------------------------------

alter table public.articles
  add column if not exists ai_summary          text,
  add column if not exists ai_summary_hook     text,
  add column if not exists ai_summary_model     text,
  add column if not exists ai_summary_status    text,
  add column if not exists ai_summary_attempts  integer not null default 0,
  add column if not exists ai_summarized_at     timestamptz;

-- Partial index so the worker's selection query (rows not yet done/failed)
-- stays cheap as the pool grows — it never scans finished rows.
create index if not exists idx_articles_needs_summary
  on public.articles (created_at)
  where ai_summary_status is distinct from 'done'
    and ai_summary_status is distinct from 'failed';

-- ---------------------------------------------------------------------------
-- get_personalized_feed, Phase 10 revision. IDENTICAL to the 0003 body except
-- two display columns are appended to the result: ai_summary, ai_summary_hook.
-- They go AFTER `score` deliberately so `score` stays the 14th output column
-- and the positional `order by 14` below keeps working unchanged. The client
-- maps rows by name, so column order past that is irrelevant to it.
-- RLS/grants/weights are unchanged.
--
-- Adding columns changes the function's return type, which CREATE OR REPLACE
-- cannot do — so drop the old signature first. Nothing else depends on it
-- (only the client calls it via RPC); the grants are restated below.
-- ---------------------------------------------------------------------------

drop function if exists public.get_personalized_feed(uuid, integer);

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

-- ---------------------------------------------------------------------------
-- Where the summarise worker lives. Vault (not hardcoded SQL) so the secret
-- rotates without touching cron. The secret must match SUMMARIZE_SECRET on
-- the deployed function. Mirrors invoke_ingest() from 0003.
-- ---------------------------------------------------------------------------

select vault.create_secret(
  'https://sbykpnhswupezuetpzhl.supabase.co/functions/v1/summarize-articles',
  'summarize_fn_url');
select vault.create_secret(
  -- Rotate freely; must equal SUMMARIZE_SECRET in the function's env. Distinct
  -- from ingest/body secrets so it unlocks only summarisation.
  'a4f1c7e9d20b83156ef4a9c0718d2b5e6390af41c8d5726b',
  'summarize_fn_secret');

create or replace function public.invoke_summarize()
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
    from vault.decrypted_secrets where name = 'summarize_fn_url';
  select decrypted_secret into v_secret
    from vault.decrypted_secrets where name = 'summarize_fn_secret';
  if v_url is null then
    return;
  end if;
  perform net.http_post(
    url     := v_url,
    body    := '{}'::jsonb,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-summarize-secret', coalesce(v_secret, '')));
end;
$$;

revoke all on function public.invoke_summarize() from public, anon, authenticated;

-- Every 30 minutes, offset 5 min after ingestion (*/30 at :00/:30) so fresh
-- rows exist to summarise. Cost is bounded by BATCH_SIZE in the function, not
-- by this cadence.
select cron.schedule(
  'bite-summarize-articles', '5,35 * * * *', 'select public.invoke_summarize()');
