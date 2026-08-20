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

## Needs your account or a device

- [ ] **Paid Apple Developer Program membership.** `DEVELOPMENT_TEAM =
      YSY2WW4RRP` is set but `AppConfig` still lists "join the Program" as step
      one — confirm it is a paid team, not a personal one.
- [ ] **Rotate the leaked Edge Function secrets** — see migration 0026. Until
      this is done the old secrets remain valid on the live project.
- [ ] **Apply migrations 0025 and 0027** (re-queue summaries; account deletion).
- [ ] **Verify deletion end-to-end on TestFlight** with a throwaway account,
      using the verification block at the foot of migration 0027. This is the
      one compliance path with no automated test behind it.
- [ ] **App Store Connect record**: name, subtitle, keywords, description,
      support URL, 17+ age rating, App Privacy answers (use
      [app-privacy.md](app-privacy.md)).
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
