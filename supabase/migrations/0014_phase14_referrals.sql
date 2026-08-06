-- Bite · Phase 14 · Part F: referral instrumentation.
-- Run in the SQL editor after 0013.
--
-- The long-term deliverable of this phase. Bite's claim is that it is a
-- REFERRER, not a replacement — and the only way that claim is provable
-- rather than nominal is a per-publisher click-through rate we can actually
-- produce on demand. This is the number that goes into a publisher email, so
-- pulling it is one function call over a date range:
--
--     select * from public.publisher_ctr(now() - interval '30 days', now());
--
-- Aggregate-only. There is no client UI for any of this.

-- ---------------------------------------------------------------------------
-- referral_events
--
-- Two FK decisions worth reading, because both are deliberate:
--
--   article_id has NO foreign key. purge_old_articles deletes untouched
--   articles after 14 days; an FK with ON DELETE CASCADE would quietly shred
--   the CTR history every night, and SET NULL would lose which story earned
--   the click. CTR is a long-horizon metric, so the id is stored as plain
--   text and outlives the article row.
--
--   user_id is ON DELETE SET NULL, not CASCADE, for the same reason: a user
--   deleting their account must not retroactively rewrite a publisher's
--   click-through rate.
--
-- publisher_id DOES cascade — but publishers are DISABLED, never deleted
-- (that is what the kill switch is for). Deleting a publisher row discards
-- its referral history along with it.
-- ---------------------------------------------------------------------------

create table if not exists public.referral_events (
  id           bigint generated always as identity primary key,
  publisher_id text not null references public.publishers (id) on delete cascade,
  article_id   text not null,
  event_type   text not null check (event_type in ('impression', 'linkout')),
  user_id      uuid references auth.users (id) on delete set null,
  created_at   timestamptz not null default now()
);

-- The reporting query is always "one publisher, one date range, grouped by
-- type", so that is the index.
create index if not exists referral_events_reporting_idx
  on public.referral_events (publisher_id, created_at desc, event_type);

alter table public.referral_events enable row level security;

-- Users may only append their own events, and may not read them back: this
-- table exists for aggregate reporting, not for anything the client renders.
create policy "referral_events: insert own" on public.referral_events
  for insert to authenticated
  with check ((select auth.uid()) = user_id);

grant insert on public.referral_events to authenticated;

-- ---------------------------------------------------------------------------
-- record_referral: the client's only entry point.
--
-- The client passes an article id and an event type; the publisher is
-- resolved SERVER-SIDE from the article row, so attribution cannot be forged
-- or drift out of sync with the registry. Guardian and mock articles have no
-- publisher and are silently ignored — there is nothing to refer.
--
-- SECURITY INVOKER: the insert policy above is what authorises the write.
-- ---------------------------------------------------------------------------

create or replace function public.record_referral(
  p_article_id text,
  p_event_type text)
returns void
language plpgsql
security invoker
set search_path = public, extensions
as $$
declare
  v_publisher text;
begin
  if p_event_type not in ('impression', 'linkout') then
    return;
  end if;

  select a.publisher_id into v_publisher
    from articles a where a.id = p_article_id;

  -- Guardian / mock / unknown article: nothing to attribute.
  if v_publisher is null then
    return;
  end if;

  insert into referral_events (publisher_id, article_id, event_type, user_id)
  values (v_publisher, p_article_id, p_event_type, auth.uid());
end;
$$;

grant execute on function public.record_referral(text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- publisher_ctr: THE report.
--
-- One row per publisher over [p_from, p_to):
--   impressions    cards actually shown (not prefetched)
--   linkouts       swipe-ups / taps through to the publisher's own page
--   ctr_percent    linkouts / impressions, as a percentage
--   readers_sent   DISTINCT users who linked out at least once — "how many
--                  real people we sent you" — the number a publisher cares
--                  about more than the ratio
--   stories_sent   distinct articles that earned at least one link-out
--
-- Publishers with no events in the window still appear, with zeros, so the
-- report never silently omits a publisher that is live but not performing.
--
-- SECURITY DEFINER and revoked from clients: it reads across every user.
-- ---------------------------------------------------------------------------

create or replace function public.publisher_ctr(
  p_from timestamptz default now() - interval '30 days',
  p_to   timestamptz default now())
returns table (
  publisher_id   text,
  publisher_name text,
  region         text,
  enabled        boolean,
  impressions    bigint,
  linkouts       bigint,
  ctr_percent    numeric,
  readers_sent   bigint,
  stories_sent   bigint)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select p.id,
         p.name,
         p.region,
         p.enabled,
         count(*) filter (where e.event_type = 'impression'),
         count(*) filter (where e.event_type = 'linkout'),
         round(
           100.0 * count(*) filter (where e.event_type = 'linkout')
           / nullif(count(*) filter (where e.event_type = 'impression'), 0),
           2),
         count(distinct e.user_id) filter (where e.event_type = 'linkout'),
         count(distinct e.article_id) filter (where e.event_type = 'linkout')
    from publishers p
    left join referral_events e
      on e.publisher_id = p.id
     and e.created_at >= p_from
     and e.created_at <  p_to
   group by p.id, p.name, p.region, p.enabled
   order by count(*) filter (where e.event_type = 'linkout') desc, p.name;
$$;

revoke all on function public.publisher_ctr(timestamptz, timestamptz)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Retention. Referral events are small (two integers' worth of meaning per
-- row) but unbounded, and the reporting horizon is months, not years.
-- ---------------------------------------------------------------------------

create or replace function public.purge_old_referrals()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  retention_days constant integer := 400;  -- a full year of comparisons
  v_deleted integer;
begin
  delete from public.referral_events
   where created_at < now() - make_interval(days => retention_days);
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

revoke all on function public.purge_old_referrals() from public, anon, authenticated;

select cron.schedule(
  'bite-purge-referrals', '51 4 * * *', 'select public.purge_old_referrals()');
