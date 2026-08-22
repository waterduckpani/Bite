# Bite · App Store submission checklist

State as of 20 August 2026. Ticked items are done and verified in the repo;
unticked ones need an account, a device, or a human decision.

## Done

- [x] **Account deletion in-app** — Profile → Delete account, `delete_account`
      RPC (migration 0027). Guideline 5.1.1(v).
- [x] **Privacy policy + terms**, published and linked from inside Profile.
- [x] **`PrivacyInfo.xcprivacy`** written and wired into the Runner target
      (verified present in the built `.app`).
- [x] **`ITSAppUsesNonExemptEncryption = false`** in Info.plist — no per-upload
      encryption prompt.
- [x] **iPhone-only** (`TARGETED_DEVICE_FAMILY = 1`), portrait-only. Removes an
      untested iPad layout from review's path.
- [x] **No placeholder UI** — the inert "Apple (coming soon)" button is gated
      behind `AppConfig.appleSignInEnabled`. Guideline 2.1.
- [x] **Branded launch screen** — was a blank white flash.
- [x] **Guest path** — the app is fully usable without an account, so the
      forced-registration half of 5.1.1(v) does not apply.

## Blocked on the Apple Developer Program

Confirmed **not a paid team**. `DEVELOPMENT_TEAM = YSY2WW4RRP` is a personal
team, which builds and runs on your own device and nothing more. Everything
below is gated on enrolment, so this is the critical path:

- [ ] **Enrol in the Apple Developer Program** — $99/year, at
      [developer.apple.com/programs](https://developer.apple.com/programs/).
      Individual enrolment is usually approved in 24-48h; if you enrol as an
      organisation it needs a D-U-N-S number and takes materially longer.
      Individual is the right choice here — the app ships under your own name.

Gated on it, and impossible before it:

- [ ] App Store Connect record (cannot be created without membership)
- [ ] TestFlight (needs a distribution certificate)
- [ ] Push notifications, if ever added (needs an APNs key)
- [ ] **Sign in with Apple** — the code is written and dormant behind
      `AppConfig.appleSignInEnabled`; the capability needs a paid team. Not
      required by guideline 4.8, so it stays off until you want it.

Nothing else in this repo is waiting on it: the app builds, the backend runs,
and every compliance item below is either done or a SQL statement away.

## Needs your Supabase project

- [x] **Rotate the leaked Edge Function secrets** — done 22 Aug. Verified by
      digest: all five deployed secrets now match the newly generated values,
      and the pipeline kept running across the change, which independently
      confirms the vault side and the function side agree. The committed
      literals are dead.
- [x] **Migration 0025** (re-queue stranded summaries) — applied 22 Aug.
      `failed` went 741 -> 0.
- [x] **Migration 0027** (account deletion RPC) — applied 22 Aug.
- [x] **Migration 0028** (budget counts completions) — applied 22 Aug. Note the
      correction at the top of that file: it was written on a mistaken
      diagnosis and is kept on narrower merits. The backlog drains at 25/tick
      either way.
- [x] **Verify deletion end-to-end** — done 22 Aug against the live project
      with a throwaway anonymous account: user created, a save written
      (1 row), `rpc/delete_account` returned 204, user afterwards 403, saves
      afterwards 0. Worth repeating once from the actual UI on a real device
      before submission, but the server contract is proven.
- [ ] **App Store Connect record**: name, subtitle, keywords, description,
      support URL, 17+ age rating, App Privacy answers (use
      [app-privacy.md](app-privacy.md)). *Requires membership.*
- [ ] **Screenshots** — 6.9" and 6.5" are required.
- [ ] **Version + build number** — pubspec is `0.1.0`; ship as `1.0.0+1`.
- [ ] **Archive, upload, TestFlight pass on a physical device, submit.**

## Deliberately not done

- **Crash reporting** — needs a third-party SDK and account, changes the App
  Privacy answers, and is a product decision rather than a fix.
- **Push notifications for trackers** — needs APNs setup under a paid team plus
  server work. The in-app unread badge ships as-is.
- **Sign in with Apple** — fully implemented, switched off. Not required by
  guideline 4.8, since Bite offers no third-party social login.

## Get a lawyer to read the legal pages

`docs/privacy/` and `docs/terms/` are written specifically against what this
codebase actually does — the Sydney data region, the referral-event
anonymisation carve-out, the 80-word cap, the DPDP grievance contact — rather
than adapted from a generic template. They are not a substitute for advice from
someone qualified to give it, and the summary-accuracy and publisher-content
sections are the ones worth a professional read before you ship.
