-- Bite · Phase 19: in-app account deletion.
--
-- ---------------------------------------------------------------------------
-- WHY THIS IS NOT OPTIONAL
--
-- App Store Review Guideline 5.1.1(v): an app that lets a person create an
-- account must let them delete it FROM INSIDE THE APP. Not by email, not by a
-- support form, not by a link to a web page. Bite offers email sign-up, so
-- until this exists the app cannot be submitted — it is a flat rejection, not
-- a risk. The same obligation arrives from the other direction under GDPR
-- Art. 17 and India's DPDP Act 2023 s.12(3), which Bite's privacy policy
-- grants to every reader regardless of where they live.
--
-- ---------------------------------------------------------------------------
-- WHAT "DELETE" MEANS HERE, PRECISELY
--
-- One statement does nearly all of it, because every user-owned table was
-- declared `references auth.users (id) on delete cascade` back in 0001 and
-- 0011. Deleting the auth row therefore removes, in the same transaction:
--
--   profiles         the onboarding flag and feed-reset watermark
--   category_prefs   chosen topics
--   saves            saved articles
--   swipe_events     the entire implicit-feedback log — i.e. the taste model.
--                    There is no separate "taste vector" row to clear: the
--                    profile is derived from these events at query time, so
--                    deleting them deletes the model.
--   story_trackers   followed stories, and tracker_articles beneath them via
--                    their own cascade
--
-- ONE table is deliberately NOT cascaded, and this is a decision rather than
-- an oversight:
--
--   referral_events  declared `on delete set null` in 0014. These rows are how
--                    Bite proves click-through to publishers. Detaching
--                    user_id leaves an anonymous "an impression happened, a
--                    link-out happened" fact with no identifier, no article
--                    preference attached to a person, and no way back to the
--                    deleted account. Under GDPR that is effectively anonymous
--                    data and outside Art. 17; the publisher CTR report keeps
--                    working. The privacy policy states this explicitly rather
--                    than burying it — a deletion promise with an undisclosed
--                    exception is the promise that gets you in trouble.
--
-- Articles themselves are shared content, not user data, and are untouched.
--
-- ---------------------------------------------------------------------------
-- SECURITY
--
-- security definer, because deleting from auth.users needs privileges the
-- caller does not have. That makes the function's authority the dangerous
-- part, so it takes NO PARAMETERS AT ALL. There is no user id to pass and
-- therefore no id to tamper with: the row deleted is auth.uid() and can only
-- ever be auth.uid(). A signed-out caller has no uid and is refused.
--
-- search_path is pinned empty and every name is schema-qualified, matching the
-- rest of this codebase's definer functions.
-- ---------------------------------------------------------------------------

create or replace function public.delete_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not authenticated'
      using errcode = '28000';
  end if;

  -- Detach the referral log before the cascade reaches it. `on delete set
  -- null` would do this anyway; doing it explicitly means the anonymisation is
  -- visible at the point of deletion rather than inferred from a constraint
  -- three migrations away.
  update public.referral_events
     set user_id = null
   where user_id = v_uid;

  -- Everything else goes with the auth row, by cascade.
  delete from auth.users where id = v_uid;
end;
$$;

revoke all on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated;

comment on function public.delete_account() is
  'Permanently deletes the CALLING user (auth.uid()) and every row that '
  'cascades from them: profile, topics, saves, swipe history and trackers. '
  'referral_events rows are anonymised (user_id set to null) rather than '
  'deleted, so publisher click-through reporting survives without retaining '
  'anything identifying. Takes no arguments by design — there is no id to '
  'tamper with. Required by App Store guideline 5.1.1(v), GDPR Art. 17 and '
  'DPDP s.12(3).';

-- ---------------------------------------------------------------------------
-- VERIFY (as a signed-in test user, from the client or with a user JWT):
--
--   select public.delete_account();
--   -- then, as service role:
--   select count(*) from auth.users where id = '<that uuid>';            -- 0
--   select count(*) from public.saves where user_id = '<that uuid>';     -- 0
--   select count(*) from public.swipe_events where user_id = '<uuid>';   -- 0
--   select count(*) from public.referral_events where user_id is null;   -- >0
-- ---------------------------------------------------------------------------
