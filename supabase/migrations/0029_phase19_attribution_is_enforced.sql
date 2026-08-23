-- Bite · Phase 19.2: make the attribution guarantee true in the schema.
--
-- ---------------------------------------------------------------------------
-- WHAT THIS CLOSES
--
-- The README, the terms page and the bot policy all make the same structural
-- claim, in almost the same words:
--
--   "Attribution can't be dropped. Publisher name and canonical URL are
--    required columns; a card cannot render without them."
--
-- Half of that was enforced. `source_name` is `text not null` with no default,
-- so a row genuinely cannot exist without an outlet name. But `original_url`
-- was declared in 0001 as:
--
--   original_url text not null default ''
--
-- and an empty string satisfies `not null` perfectly well. The guarantee for
-- the link — the half that makes Bite a referrer rather than a republisher —
-- rested on ingest-rss always populating it, which it does. That is a habit of
-- the ingestion code, not a property of the database, and the claim as written
-- promises the second thing.
--
-- Nothing is known to have gone wrong. This is not a bug report; it is closing
-- the distance between a public commitment and the mechanism behind it, which
-- is the whole reason the commitment was phrased structurally in the first
-- place. A promise enforced by convention is one refactor away from being
-- false, and nobody would find out from the code.
--
-- ---------------------------------------------------------------------------
-- WHY A CHECK RATHER THAN DROPPING THE DEFAULT
--
-- Removing `default ''` would stop a caller omitting the column, but would not
-- stop one passing '' explicitly, and would break any insert that relies on
-- the default being there. The CHECK is the direct statement of the rule: this
-- column may not be blank, ever, by any path.
--
-- Both columns get one, so the two halves of the claim are enforced the same
-- way rather than one by omission and one by constraint.
-- ---------------------------------------------------------------------------

begin;

-- Fail loudly rather than silently skipping if any existing row would violate
-- the constraint — that would itself be worth knowing about.
do $$
declare
  v_bad integer;
begin
  select count(*) into v_bad
    from public.articles
   where btrim(coalesce(original_url, '')) = ''
      or btrim(coalesce(source_name,  '')) = '';
  if v_bad > 0 then
    raise exception
      'phase19.2: % article row(s) have a blank source_name or original_url; '
      'inspect before adding the constraint', v_bad;
  end if;
  raise notice 'phase19.2: all article rows carry attribution; adding constraints';
end $$;

alter table public.articles
  add constraint articles_original_url_present
  check (btrim(original_url) <> '');

alter table public.articles
  add constraint articles_source_name_present
  check (btrim(source_name) <> '');

comment on constraint articles_original_url_present on public.articles is
  'Bite is a referrer: every stored article must carry the publisher''s own '
  'canonical link. Previously only `not null default ''''` — which an empty '
  'string satisfies — so the guarantee published in the terms and bot policy '
  'was upheld by ingestion habit rather than by the schema.';

comment on constraint articles_source_name_present on public.articles is
  'Every stored article must name its outlet. Attribution is not optional and '
  'is not a rendering concern.';

commit;

-- ---------------------------------------------------------------------------
-- VERIFY
--
--   select conname, pg_get_constraintdef(oid)
--     from pg_constraint
--    where conrelid = 'public.articles'::regclass
--      and contype = 'c';
--
-- And confirm the rule actually bites (expect an error, not a row):
--
--   insert into public.articles (id, source, source_name, category, title)
--   values ('test:blank', 'test', 'Test', 'world', 'x');
-- ---------------------------------------------------------------------------
