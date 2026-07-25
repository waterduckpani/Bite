# Bite

**A swipe-based news reader that learns what you actually care about.**

Bite turns the news into a deck of cards. Swipe through stories the way you'd
swipe through anything else on your phone — and behind each gesture is a
recommendation engine that quietly builds a model of your taste, an AI that
rewrites every story into a two-line "bite," and a story-tracking system that
follows a developing news thread for you over time.

Built with **Flutter** (iOS-first) on a fully **server-driven Supabase
backend**: Postgres + pgvector for recommendations, Deno edge functions for
ingestion, summarization and matching, and cron-scheduled pipelines that keep
the feed fresh without the app ever touching a news API directly.

> **Note on licensing** — this repository is public for portfolio and
> code-sample purposes only. It is **source-available, not open-source**: you
> may read the code, but reuse, modification, and redistribution are not
> permitted. See [LICENSE](LICENSE).

---

## What it is

Most news apps give you an infinite scroll and a firehose of headlines. Bite
makes reading the news a series of small, deliberate decisions:

- **One story at a time**, presented as a full-bleed card with cover art, a
  source mark, and an AI-written hook.
- **Four gestures, four meanings** — every swipe is a signal, and the feed
  reorders itself around what you engage with.
- **A "bite" instead of a headline** — an LLM condenses each full article into
  a punchy hook and a short summary, so you get the gist before you decide to
  read.
- **Story trackers** — follow a developing story and Bite collects new
  coverage of that same thread into a dedicated timeline as it breaks.

Everything runs keyless on bundled mock data, so the app is always launchable
without any credentials.

---

## How it works

### The swipe model

The core interaction is a four-direction gesture map. Each direction is both a
navigation action *and* a preference signal fed to the recommender:

| Gesture      | Meaning  | Signal                                             |
| ------------ | -------- | -------------------------------------------------- |
| **← Left**   | Reject   | Negative signal · dismisses the card (resettable)  |
| **→ Right**  | Read     | Positive signal · permanently excluded from feed   |
| **↓ Down**   | Save     | Strong positive · added to your Saved list         |
| **↑ Up / Tap** | Open   | Additive interest boost · opens the reader (non-terminal) |

These weighted signals feed a taste model that reranks the feed. The system is
deliberately more than a simple like/dislike toggle:

- **Weighted taste centroid** — your taste is the weighted average of the
  embeddings of stories you read and saved, pushed *away* from what you reject.
- **Cold-start onboarding** — before the model has enough signal, the feed is
  a category-diverse interleave seeded by the topics (and region) you pick
  during onboarding.
- **Topic anti-domination** — a penalty prevents any single hot category from
  flooding the deck.
- **An exploration slice** — roughly one in six cards is an intentional
  off-taste pick, so the feed keeps discovering rather than collapsing into a
  filter bubble.

### From wire to card: the server pipeline

The client never calls a news API. Instead, a set of scheduled edge functions
keep a Postgres table of articles fresh, and the app reads a single
personalized RPC:

```
                Guardian API            publisher RSS feeds
                     │                          │
   (*/30 cron)  ┌────▼─────────┐   (:20 /3h) ┌──▼─────────┐
                │  ingest-news │             │ ingest-rss │
                └──────┬───────┘             └──────┬─────┘
                       │      articles + tags       │
                       └───────────┬────────────────┘
                                   │
                                   ▼
   (:05,:35)    ┌──────────────┐        ┌───────────┐
                │    embed     │◀───────│  Postgres │
                │  (pgvector)  │        │ + pgvector│
                └──────────────┘        └─────┬─────┘
                                              │
   (:05,:35)    ┌──────────────────┐          │
                │ summarize-       │◀─────────┤
                │ articles (LLM)   │          │
                └──────────────────┘          │
                                              │
   (:15,:45)    ┌──────────────────┐          │
                │ match-trackers   │◀─────────┤
                └──────────────────┘          │
                                              ▼
                             get_personalized_feed()  ──►  Flutter app
```

1. **`ingest-news`** pulls fresh stories from The Guardian (sections + keyword
   tags), deduplicates them, and upserts them with the service role.
2. **`ingest-rss`** reads the enabled publishers' RSS feeds under a published
   bot policy — robots.txt honoured, one honest User-Agent, a round-robin fair
   share so no single outlet crowds the run — and normalises them into the same
   table, link-out only.
3. **`embed`** turns each new article into a vector embedding (`gte-small`) via
   pg_net-triggered, self-chaining batches — this is what powers similarity.
4. **`summarize-articles`** calls an LLM (via OpenRouter, with a fallback model
   chain) to produce the Bite-voice hook and summary — from the full body where
   Bite holds one, otherwise from the publisher's own description. Output is
   capped at 80 words in code and metered against a global daily ceiling. A
   failed summary falls back gracefully to the standfirst.
5. **`match-trackers`** scores fresh articles against each story tracker using a
   hybrid of tag-Jaccard and embedding cosine similarity — falling back to an
   embedding-only path with its own threshold when either side has no tags, so
   publisher-direct stories can match too.
6. **`get_personalized_feed`** is a single Postgres RPC that assembles the deck:
   taste similarity + category affinity + recency, minus the topic penalty,
   plus a mild country nudge, with the exploration slice interleaved via
   collision-free slot math.

All of this runs behind Row-Level Security — every user sees only their own
saves, swipes, preferences, and trackers.

### Publisher-direct sources: a referrer, not a replacement

Alongside Guardian, Bite reads a small, version-controlled registry of
publisher RSS feeds (`ingest-rss`, every three hours). The governing rule is
that **Bite is a referrer, not a replacement**, and the design makes that
structural rather than aspirational:

- **Attribution can't be dropped.** Publisher name and canonical URL are
  required columns; a card cannot render without them.
- **Every publisher-direct story is link-out only.** `full_text_available` is
  written `false` unconditionally, so the reader router always sends these to
  the publisher's own page — their layout, their branding, their advertising.
- **The bite informs, it doesn't complete.** Summaries are capped at **80 words
  in code**, not merely in the prompt.
- **Nothing is circumvented.** One fixed, honest User-Agent
  (`BiteNewsBot/1.0`), `robots.txt` parsed and honoured per domain including
  `Crawl-delay`, and any paywall, consent wall or bot challenge aborts the
  fetch and falls back to the feed's own description. Nothing is ever retried
  with different headers. See [`docs/bot/`](docs/bot/index.html).
- **It's measured.** `referral_events` records impressions and link-outs so
  per-publisher click-through rate is a number we can produce, not a claim.

No publisher is added on assumption: `tools/qualify_publisher.dart` checks the
feed, robots.txt, content depth, categories and volume for each candidate, and
its report is committed under [`docs/publishers/`](docs/publishers/) — that
directory also records the slate's political spread and, honestly, where it is
still skewed.

### Reading a story

Tapping (or swiping up) opens the reader. Bite keeps a hard licensing boundary:

- **Full-text sources** (Guardian) render natively in-app, with a sage-tinted
  **"The Bite"** summary block above the original article body.
- **Everything else** — headline-only sources and every publisher-direct story
  — opens the publisher's own page in an in-app browser. Bite never re-hosts
  content it isn't licensed to show, and those cards carry a persistent
  *"Swipe up to read at {publisher}"* cue so the destination is never a
  surprise.

Article bodies are proxied and cached server-side (`guardian-body`) so the app
bundle never carries a news-API key.

### Story trackers

Follow a developing story from the reader (a bell toggle) and Bite creates a
tracker seeded from that article's embedding and tags. As new coverage of the
same thread is ingested, `match-trackers` collects it into a reverse-chronological
timeline with an in-app unread badge. Trackers live *alongside* the swipe feed
and never influence its ranking — they're a separate lens on the news, not a
change to your taste model.

---

## Architecture

```
Flutter (iOS-first)
├─ State           AppState — single source of truth, InheritedWidget scope
├─ Persistence     UserDataRepository — offline op-queue, optimistic writes,
│                  hydrate-on-startup, anonymous → email/Apple auth upgrade
├─ Feed            personalized RPC → mock fallback (always launchable keyless)
└─ Reader          native in-app reader ↔ in-app browser by licensing

Supabase
├─ Postgres        articles, profiles, saves, swipe_events, category_prefs,
│                  story_trackers, tracker_articles, publishers,
│                  referral_events  (+ pgvector, RLS everywhere)
├─ Edge Functions  ingest-news · ingest-rss · embed · summarize-articles ·
│                  match-trackers · guardian-body
└─ Scheduling      pg_cron pipelines: ingest → embed/summarize → match → purge
```

**Design principles that shaped the codebase:**

- **Server-driven, keyless client** — no news-API key ever ships in the app
  bundle; the client reads one personalized RPC and a body proxy.
- **Always launchable** — with no credentials the app runs entirely on bundled
  mock data and in-memory state.
- **Offline-first writes** — saves/swipes queue locally and reconcile on
  reconnect; the UI never blocks on the network.
- **Privacy by default** — anonymous auth by default, RLS on every table, the
  "region" question is a plain profile preference with no location permission.

---

## Tech stack

**Client** · Flutter · Dart · `flutter_card_swiper` · `supabase_flutter` ·
`sign_in_with_apple` · `webview_flutter` · `liquid_glass_renderer` · `animations`
· Inter variable font

**Backend** · Supabase (Postgres + pgvector) · Deno edge functions (TypeScript)
· pg_net · pg_cron · Row-Level Security

**AI** · sentence embeddings (`gte-small`) for taste & tracker matching · LLM
summarization via OpenRouter (Gemini Flash family, with a fallback chain)

**Content** · The Guardian Open Platform (licensed full text) · publisher RSS
feeds, link-out only, under a published bot policy

---

## Project structure

```
lib/
├─ config/        AppConfig + feed tuning constants
├─ data/          bundled mock articles, palettes, source metadata
├─ models/        Article, StoryTracker, Country
├─ screens/       feed · reader · browser · saved · tracked · discover ·
│                 onboarding · profile · tracker detail/management
├─ services/      UserDataRepository (persistence + auth)
├─ state/         AppState (app-wide state)
├─ theme/         design system (colors, type, motion)
└─ widgets/       article card, tab bar, gesture tutorial, glass, cover art …

supabase/
├─ functions/     ingest-news · ingest-rss · embed · summarize-articles ·
│                 match-trackers · guardian-body
│                 _shared/  bot identity + robots.txt · RSS parsing ·
│                           junk filter · the 80-word cap
└─ migrations/    (kept local — see note below)

tools/            qualify_publisher.dart  publisher vetting (Dart, standalone)
                  verify_phase14.ts       robots/cap/parser checks (Deno)

docs/
├─ publishers/    one qualification report per candidate + the slate rationale
└─ bot/           the public BiteNewsBot page (User-Agent's +url)

test/             widget/flow tests
```

> Database migrations are kept local (they embed deployed vault-secret values)
> and are intentionally not committed.

---

## Running locally

Bite is iOS-first and developed against the iOS Simulator.

```bash
flutter pub get
flutter run           # launches on the mock-data feed with no credentials
```

To enable live persistence and the personalized feed, copy `.env.example` to
`.env` and fill in the Supabase project URL/anon key (see the file's comments —
**no news-API keys belong in the client**). The backend edge functions and
cron schedule are deployed separately via the Supabase CLI.

---

## Operating the publisher registry

**Removing a publisher — the one query to know.** It takes effect on the next
ingest cycle *and* immediately hides their existing cards from every reader's
feed and tracker timeline, because `get_personalized_feed` joins the registry
on every read:

```sql
update public.publishers set enabled = false where id = 'thehindu';
```

Nothing is deleted. Saved articles, swipe history and tracker rows are all left
intact — deleting would cascade into users' bookmarks and the recommender's
training data. Re-enabling restores the timeline exactly as it was.

Enabling works the same way (publishers are seeded **disabled** on purpose —
adding a row and turning it on are two different decisions):

```sql
update public.publishers set enabled = true
 where id in ('thehindu', 'deccanherald', 'scroll', 'aljazeera');
```

**The click-through report.** This is the number that goes into a publisher
email — impressions, link-outs, CTR %, and how many distinct readers were sent
their way:

```sql
select * from public.publisher_ctr(now() - interval '30 days', now());
```

**Adding a publisher.** Qualify first, commit the report, then add the row:

```bash
dart run tools/qualify_publisher.dart example.com   # writes docs/publishers/
```

**Checking the AI spend** is real rather than assumed:

```sql
select * from public.ai_usage_daily order by day desc limit 14;
```

## Status

Bite is a personal project built in phases — design system and motion, live
content, Supabase persistence, authentication, a pgvector recommendation
engine, server-side ingestion, AI summaries, the four-gesture swipe rework,
story trackers, and publisher-direct ingestion with click-through reporting. It is a functional, end-to-end iOS app, not a shipped App Store
product.

---

## License

**Proprietary · source-available · view-only.** Copyright © 2026 Bharat Khanna.
All rights reserved. This code is published to be read as a work sample; it may
not be reused, modified, or redistributed. See [LICENSE](LICENSE) for the full
terms.
