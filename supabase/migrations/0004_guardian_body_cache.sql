-- Bite · Guardian body cache (final key-removal step).
-- Run in the SQL editor AFTER deploying the "guardian-body" Edge Function:
--   supabase secrets set BODY_FN_SECRET=<value from supabase/functions/.env.secrets>
--   supabase functions deploy guardian-body --no-verify-jwt
--
-- The reader now fetches Guardian bodies through guardian-body instead of
-- calling the Guardian API itself, so GUARDIAN_API_KEY leaves the app bundle
-- — zero news-API keys ship in the client. Fetched bodies are cached here
-- briefly: repeat opens skip the Guardian API (softening the shared
-- 5,000/day dev-tier cap), while the short retention honors the Guardian's
-- takedown obligation — the function re-fetches after 24h (and drops the row
-- outright on an upstream 404/410), and nothing survives here past the purge
-- below.

create table if not exists public.article_bodies (
  article_id text primary key,
  paragraphs jsonb not null,
  fetched_at timestamptz not null default now()
);

-- Service-role only (i.e. the Edge Function): RLS on with no policies means
-- clients can't read cached bodies directly, and the explicit revoke keeps
-- Supabase's default table grants from suggesting otherwise.
alter table public.article_bodies enable row level security;
revoke all on table public.article_bodies from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- purge_old_articles, rev 2 (from 0003): additionally expires cached bodies.
-- 48h is deliberately longer than the function's 24h freshness window so a
-- stale row can still serve as the fallback when the Guardian API errors,
-- but no cached body outlives two days. The existing daily cron
-- (bite-purge-articles, 04:43 UTC) picks this up unchanged.
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
     and not exists (select 1 from public.swipe_events e where e.article_id = a.id);
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

revoke all on function public.purge_old_articles() from public, anon, authenticated;
