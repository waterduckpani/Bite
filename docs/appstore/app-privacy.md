# App Store Connect · App Privacy answers

The exact selections to make in **App Store Connect → App Privacy**, with the
reason for each. Fill it from this file rather than from memory: the answers
have to agree with `ios/Runner/PrivacyInfo.xcprivacy` and with
[the privacy policy](../privacy/index.html), and the commonest way apps get a
metadata rejection is three documents drifting apart.

**If any of the three changes, change all three.**

---

## Does your app collect data? → **Yes**

Not "no". Bite stores an email address for account holders and a reading
history for everybody, on a server it controls. Answering "no" here because the
app has no analytics SDK is the classic mistake.

## Tracking → **No**

"Tracking" in Apple's sense means linking data to third-party data for targeted
advertising or measurement, or sharing with a data broker. Bite does none of
it: no ad SDK, no attribution SDK, no IDFA, no data broker, and no third-party
analytics. Therefore **no App Tracking Transparency prompt** and
`NSPrivacyTracking = false`.

---

## Data types to declare

For each: **linked to identity = Yes** (it hangs off the account ID),
**used for tracking = No**.

| Apple data type | Category | Purpose(s) | Why |
|---|---|---|---|
| **Email Address** | Contact Info | App Functionality | Only for account holders. Sign-in code + carrying saves across devices. Guests never provide one. |
| **User ID** | Identifiers | App Functionality | The Supabase account ID, including the anonymous one issued to guests. What row-level security keys on. |
| **Product Interaction** | Usage Data | App Functionality, **Analytics** | Swipes, saves, opens — the recommendation engine. Also impressions/click-outs behind publisher CTR reporting, which is why Analytics is ticked too. |

### Deliberately NOT declared

- **Precise/Coarse Location** — Bite has no location permission and cannot read
  your position. "Region" is a preference picked from a list of six. If you are
  ever tempted to tick this because of the region feature: don't. It is not
  location data.
- **Search History, Browsing History** — Bite has no search, and the in-app
  browser's history is not recorded or transmitted.
- **Device ID** — no IDFA, no IDFV collection, no fingerprinting.
- **Crash Data / Performance Data** — there is no crash reporter in the app. If
  one is ever added (Sentry, Crashlytics), this table changes.

---

## Other questionnaire answers

| Question | Answer |
|---|---|
| Account deletion offered in-app? | **Yes** — Profile → Delete account (`delete_account` RPC, migration 0027) |
| Privacy policy URL | `https://waterduckpani.github.io/Bite/privacy/` |
| Age rating | **17+** — the in-app browser is Unrestricted Web Access. Answer that question honestly; a news app that opens arbitrary publisher pages cannot claim otherwise. |
| Content rights (does it contain third-party content?) | **Yes** — publisher RSS under a published bot policy, link-out only, per-publisher qualification reports in `docs/publishers/`, takedown at bitenewsapp@gmail.com. |
| Third-party content documentation | Point reviewers at `https://waterduckpani.github.io/Bite/bot` if asked. |

---

## Keep in sync when...

- **Apple Sign-In is switched on** (`AppConfig.appleSignInEnabled`): Apple
  returns a name and an email. Email is already declared; add **Name** (Contact
  Info, App Functionality, linked, not tracking) and update the privacy policy's
  "What Bite stores" table.
- **Push notifications are added** for trackers: declare nothing new by itself,
  but the policy needs a line about the device token.
- **Any analytics or crash SDK is added**: re-do this entire page, add the SDK's
  own privacy manifest requirement, and re-check the Tracking answer.
