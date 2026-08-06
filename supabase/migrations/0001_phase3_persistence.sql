-- Bite · Phase 3: Supabase persistence.
-- Run in the SQL editor (or `supabase db push`). Identity is anonymous auth:
-- every device gets an auth.users row via signInAnonymously(), so anonymous
-- users carry the `authenticated` role (with jwt claim is_anonymous = true)
-- and all the per-user policies below apply to them unchanged.

-- pgvector, used from Phase 7 for article embeddings.
create extension if not exists vector with schema extensions;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table public.profiles (
  id            uuid primary key references auth.users (id) on delete cascade,
  onboarded     boolean not null default false,
  -- Feed resets are represented as a watermark rather than deleting rows from
  -- the append-only swipe_events log: hydration ignores left-swipes older
  -- than this, so "reset feed" survives restarts without losing feedback data.
  feed_reset_at timestamptz,
  created_at    timestamptz not null default now()
);

create table public.category_prefs (
  user_id    uuid not null references auth.users (id) on delete cascade,
  category   text not null,
  created_at timestamptz not null default now(),
  primary key (user_id, category)
);

-- Article METADATA only — never full bodies (Guardian text is licensed for
-- display, not for storage; bodies are re-fetched on demand by the reader).
create table public.articles (
  id                  text primary key,          -- e.g. guardian:<path>, newsdata:<id>
  source              text not null,             -- provider: guardian | newsdata | mock
  source_name         text not null,             -- outlet display name
  category            text not null,
  title               text not null,
  snippet             text not null default '',
  image_url           text not null default '',
  original_url        text not null default '',
  author              text,
  read_minutes        integer,
  source_icon_url     text,
  full_text_available boolean not null default false,
  published_at        timestamptz,
  embedding           extensions.vector(384),    -- stays null until Phase 7
  created_at          timestamptz not null default now()
);

-- Implicit feedback log: one row per swipe (left = skip, right = save,
-- up = opened the story).
create table public.swipe_events (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users (id) on delete cascade,
  article_id text not null references public.articles (id) on delete cascade,
  direction  text not null check (direction in ('left', 'right', 'up')),
  created_at timestamptz not null default now()
);

create index swipe_events_user_created_idx
  on public.swipe_events (user_id, created_at desc);

create table public.saves (
  user_id    uuid not null references auth.users (id) on delete cascade,
  article_id text not null references public.articles (id) on delete cascade,
  saved_at   timestamptz not null default now(),
  primary key (user_id, article_id)
);

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------

alter table public.profiles       enable row level security;
alter table public.category_prefs enable row level security;
alter table public.articles       enable row level security;
alter table public.swipe_events   enable row level security;
alter table public.saves          enable row level security;

-- Per-user tables: a user (anonymous included) touches only their own rows.
create policy "own profile: select" on public.profiles
  for select to authenticated using ((select auth.uid()) = id);
create policy "own profile: insert" on public.profiles
  for insert to authenticated with check ((select auth.uid()) = id);
create policy "own profile: update" on public.profiles
  for update to authenticated
  using ((select auth.uid()) = id) with check ((select auth.uid()) = id);

create policy "own prefs: all" on public.category_prefs
  for all to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

create policy "own swipes: select" on public.swipe_events
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "own swipes: insert" on public.swipe_events
  for insert to authenticated with check ((select auth.uid()) = user_id);

create policy "own saves: all" on public.saves
  for all to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

-- Shared article metadata: readable and upsertable by any signed-in user
-- (anonymous sessions included — they are how the app caches metadata on
-- interaction). No delete policy: clients never remove articles.
create policy "articles: select" on public.articles
  for select to authenticated using (true);
create policy "articles: insert" on public.articles
  for insert to authenticated with check (true);
create policy "articles: update" on public.articles
  for update to authenticated using (true) with check (true);

-- ---------------------------------------------------------------------------
-- Data API exposure
-- ---------------------------------------------------------------------------
-- Tables in `public` are exposed through PostgREST by default (Settings →
-- API → Exposed schemas includes `public`). The grants below make that
-- explicit; RLS above is what actually gates every row.

grant usage on schema public to authenticated;
grant select, insert, update on public.profiles       to authenticated;
grant select, insert, update, delete on public.category_prefs to authenticated;
grant select, insert, update on public.articles       to authenticated;
grant select, insert on public.swipe_events           to authenticated;
grant select, insert, update, delete on public.saves  to authenticated;
