# Publisher qualification

Every publisher in the `publishers` registry was checked with
`tools/qualify_publisher.dart` before being added, and its report is committed
in this directory. **No publisher is added on assumption.** Re-run the script
and update the report before changing any registry row.

```bash
dart run tools/qualify_publisher.dart --all          # the Phase 14 slate
dart run tools/qualify_publisher.dart --phase16      # the Phase 16 expansion
dart run tools/qualify_publisher.dart thehindu.com   # one domain

# One exact feed, for a publisher that runs several (discovery only ever finds
# the first feed that parses):
dart run tools/qualify_publisher.dart theguardian.com \
    --feed=https://www.theguardian.com/world/rss \
    --slug=theguardian.com-world --name="The Guardian (world)"
```

Checked on **2026-07-25** (Phase 14), **2026-07-28** (Guardian, Phase 15.1) and
**2026-07-30** (Phase 16) with the honest User-Agent
`BiteNewsBot/1.0 (+https://waterduckpani.github.io/Bite/bot)`.

## Phase 16 — regional expansion (migration 0023)

The slate goes from 9 live publishers to **26**, and gains a six-value region
taxonomy: `GLOBAL | US | UK | EU | IN | AU`.

**What a region tag is.** A fact about the publisher, stored on the registry
row, read for exactly one purpose: a mild additive ranking boost
(`REGION_BOOST = 0.12`, against `w_sim = 0.55`) when a reader has selected that
region. It is **never a filter** — every enabled publisher is a candidate in
every reader's pool on every query, and `Global` applies no boost at all, so a
Global reader's ranking is arithmetically identical to Phase 15.2's.

This **replaces** the Phase 12 country nudge entirely. That nudge scored an
article by looking for country words in its URL slug and category strings,
which measured slug style rather than relevance — `/join-us/` scored the nudge
for a US reader, and migration 0019's own header says so. `w_country`,
`v_country_words` and `profiles.country` are all deleted in 0023, not zeroed:
"this is an Indian outlet" is a fact, "this URL contains india" was an accident.

### Added in Phase 16 — 17 rows, all qualified

| Publisher | Region | Feed | Mode | `full_text_allowed` | ~items/day | `max_per_run` |
| --- | --- | --- | --- | --- | --- | --- |
| [BBC News](bbc.com-world.md) | GLOBAL | 4 section feeds | description-only | false | 17 (world) | 6 |
| [NPR](npr.org.md) | GLOBAL | `feeds.npr.org/1001` | body-fetch-allowed | **true** | 30 | 4 |
| [Euronews](euronews.com.md) | EU | `/rss` | body-fetch-allowed | **true** | 113 | 3 |
| [France 24](france24.com.md) | EU | `/en/rss` | description-only | false | 83 | 3 |
| [Sky News](news.sky.com.md) | UK | `feeds.skynews.com` | description-only | false | 1* | 4 |
| [The Independent](independent.co.uk.md) | UK | `/news/uk/rss` | description-only | false (paywall) | 107 | 3 |
| [PBS NewsHour](pbs.org.md) | US | `/newshour/feeds/rss/headlines` | body-fetch-allowed | **true** | 24 | 4 |
| [The Hill](thehill.com.md) | US | `/feed` | description-only | false (403) | 99 | 3 |
| [ABC News Australia](abc.net.au.md) | AU | `/news/feed/45910` | body-fetch-allowed | **true** | 30 | 4 |
| [Guardian Australia](theguardian.com-australia.md) | AU | `/australia-news/rss` | body-fetch-allowed | **true** | 1* | 3 |
| [TechCrunch](techcrunch.com.md) | GLOBAL | `/feed/` | body-fetch-allowed | **true** | 21 | 4 |
| [WIRED](wired.com.md) | GLOBAL | `/feed/rss` | description-only | false (paywall) | 32 | 4 |
| [The Verge](theverge.com.md) | GLOBAL | `/rss/index.xml` | **RSS full content** | false (not needed) | 38 | 4 |
| [Science Daily](sciencedaily.com.md) | GLOBAL | `/rss/all.xml` | body-fetch-allowed | **true** | 8 | 4 |
| [Science News](sciencenews.org.md) | GLOBAL | `/feed` | description-only | false (paywall) | 2 | 3 |
| [CNBC](cnbc.com.md) | GLOBAL | `/id/100003114/…` | description-only | false (paywall) | 43 | 4 |
| [ESPN](espn.com.md) | GLOBAL | `/espn/rss/news` | description-only | false (paywall) | 23 | 4 |

\* Feeds carrying a long evergreen tail produce a meaningless span-based
items/day estimate — the same caveat recorded for the Guardian sections below.
What bounds a run is `MAX_ITEM_AGE_HOURS = 48` and `max_per_run`, not feed
length.

Existing rows were retagged: **Deutsche Welle GLOBAL → EU**. The Christian
Science Monitor and Reason stay GLOBAL despite being US outlets — CSM's brief
is explicitly international and Reason's is national politics, and neither is
what a reader picking "United States" is asking for.

Final distribution: **13 GLOBAL, 4 IN, 3 EU, 2 UK, 2 US, 2 AU.**

### Where the probe disagreed with the plan — the probe won

The Phase 16 plan predicted modes for several sources. Four of those
predictions were wrong, and the seed follows the measurement:

| Source | Plan said | Probe found | Seeded as |
| --- | --- | --- | --- |
| WIRED | "full-text free, priority" | **paywall** on honest fetch | description-only |
| The Verge | "excerpt-only, add anyway" | full `content:encoded` on 10/10 items | **RSS full content** |
| CNBC, ESPN, Science News, The Independent | (unstated) | **paywall**, aborted | description-only |
| Sky News | (unstated) | HTTP **403**, robots.txt also 403 | description-only |

**The Verge is the interesting case.** Because its feed carries real bodies,
`ingest-rss` reads them straight from the feed and never requests an article
page at all — `hasUsableFullContent` is checked *before* `full_text_allowed`.
It gets full-text bites at zero request cost to the publisher, which is the
politest outcome available. Its `full_text_allowed` stays `false` (the article
page is walled), and that costs nothing because no page fetch is needed.

No walled source is retried with different headers. There is no code path in
the repository that could, and none was added.

### EU is tagged, not left inert

The Phase 16 plan put DW, France 24 and Euronews in the global core *and*
listed Europe as a selectable region — which would have made "Europe" a
preference that boosted precisely nothing. That is the same silent no-signal
failure migration 0019 documents at length, and shipping a knowing second
instance of it would be worse than the first. All three are tagged `EU`.

This costs nothing, because a `GLOBAL` tag confers no visibility a regional tag
lacks — both appear in every reader's pool. `GLOBAL` only means "not boosted".

### Rejected in Phase 16

| Publisher | Why |
| --- | --- |
| [Axios](axios.com.md) | `api.axios.com/feed/` is **disallowed by robots.txt**, and all 28 conventional paths on `axios.com` return 404 (one returns 200 with no parseable items). No usable feed. |
| [USA Today](usatoday.com.md) | No parseable feed at any probed path. Qualified as an Axios replacement; failed. |
| [CBS News](cbsnews.com.md) | No parseable feed at any probed path. Qualified as an Axios replacement; failed. |

**US is thinner than planned, and that is a live gap.** Axios was the plan's
primary US pick and it failed on technical grounds. Of the three replacements
tried, only The Hill qualified. US therefore runs on NPR (core, GLOBAL) + PBS
NewsHour + The Hill, with only the latter two carrying the `US` tag. Worth
revisiting rather than leaving: candidates not yet tried include `apnews.com`,
`politico.com` and `thehill.com`'s sibling verticals.

### Qualified but not seeded

- **[BBC News (UK)](bbc.com-uk.md)** — the BBC's UK section feed passes. It is
  *not* seeded, because the Phase 16 plan places BBC in the global core and
  covers UK with Sky News and The Independent. It is the ready lever if UK
  needs depth: add a second `bbc.com` row tagged `UK` (which
  `UNIQUE (canonical_domain, region)` now permits, exactly as Guardian
  Australia does).
- **The Conversation** — unchanged from Phase 14; see below.

### Regional editions of one domain

`publishers.canonical_domain` dropped its `UNIQUE` constraint in favour of
`UNIQUE (canonical_domain, region)`. Some outlets run genuinely separate
regional desks off one domain — Guardian Australia is a different newsroom with
its own feed and has to carry `AU` while `theguardian.com` carries `GLOBAL`.

This does **not** reopen the thing the original constraint prevented: section
feeds still go in `rss_urls` on one row (see 0018 Part A), and one row per
`(domain, region)` is a different axis. The cost is one extra robots.txt fetch
per `ROBOTS_CACHE_HOURS` per edition, and CTR reported per edition — the second
arguably an improvement.

### Supply caps

`MAX_ARTICLES_PER_RUN_TOTAL` goes **25 → 48**. At 4 runs/day that is ~192
articles/day, just under the unchanged `DAILY_SUMMARY_CAP` of 200 and under
`get_personalized_feed`'s `p_limit` of 200 — deliberately under both, so the
cap stays a safety ceiling rather than something the pipeline hits daily.

`MAX_REGION_SHARE = 0.35` caps any one **non-GLOBAL** region's share of a run
(16 of 48). Round-robin already spreads a run across publishers, so this
normally never binds; it exists for the run where the quiet specialists came up
empty and the high-volume regional dailies would otherwise take a share nothing
editorial justifies. GLOBAL is exempt — it is half the slate and capping it
would starve the pool. When the ceiling does bind, `ingest-rss` logs which
region and by how much; it is never a silent truncation.

Cost is now **measured, not projected**: `summarize-articles` logs day-to-date
token spend on every run, and `ai_spend_report()` (migration 0023) reports the
history. `publisher_input_modes()` reports the description-only vs full-text
split per publisher.

---

## Phase 14 — the original slate

## Governing principle

Bite is a **referrer, not a replacement**. Every publisher below is link-out
only — and since Phase 15.1 so is every story in the app, from any source: their bite is capped at 80 words, their name is on the card, and swiping
up opens their page. The measurable output of this phase is per-publisher
click-through rate (`publisher_ctr()` — see the root README).

## The Guardian — added in Phase 15.1 (migration 0018)

The Guardian was in Bite from the start via the **Open Platform API**: licensed
full text, a native in-app reader, an API key in Edge Function secrets. Phase
15.1 dropped that API and kept the content. Guardian is now an ordinary
publisher here, held to exactly the same bar as everyone else — and it is the
first registry row with **more than one feed**, because it publishes per
section rather than one firehose.

Checked **2026-07-28**. All six section feeds PASS:

| Feed | Items parsed | Mode | `full_text_allowed` |
| --- | --- | --- | --- |
| [`/world/rss`](theguardian.com-world.md) | 45 | body-fetch-allowed | **true** |
| [`/business/rss`](theguardian.com-business.md) | 39 | body-fetch-allowed | **true** |
| [`/technology/rss`](theguardian.com-technology.md) | 27 | body-fetch-allowed | **true** |
| [`/science/rss`](theguardian.com-science.md) | 27 | body-fetch-allowed | **true** |
| [`/sport/rss`](theguardian.com-sport.md) | 53 | body-fetch-allowed | **true** |
| [`/culture/rss`](theguardian.com-culture.md) | 69 | body-fetch-allowed | **true** |

Registry row: `theguardian`, GLOBAL, `max_per_run = 6` (one per section on a
typical run). The id is deliberately **not** `guardian` — that is the legacy
value in `articles.source` for API-era rows, and a CTR report must not read the
two as one thing.

Notes worth carrying forward:

- The feeds are **description-only** (0 of 45 world items carried
  `content:encoded`), and robots.txt allows article paths with no stated
  `Crawl-delay`. So Guardian joins DW as a publisher that routinely exercises
  the body fetch — for **summariser input only**. That verdict is
  robots-derived, re-checked by `ingest-rss` every `ROBOTS_CACHE_HOURS`, and it
  puts no body in front of a reader.
- The **items/day figures in these reports are not usable** for Guardian. The
  section feeds carry a long evergreen tail (the sport feed spans years), which
  drags the span-based estimate to ~0/day. What actually bounds a run is
  `MAX_ITEM_AGE_HOURS = 48` plus `max_per_run`, not the feed length.
- Guardian is a **ninth publisher sharing the same
  `MAX_ARTICLES_PER_RUN_TOTAL = 25`**, not an addition to it; Guardian takes a
  share of the run rather than adding to it. Its freshness also drops from the
  old 30-minute API cron to the RSS cycle — 6-hourly since migration 0021,
  which also halved total daily volume to ~100 articles (4 runs x 25), so
  ingestion rather than `DAILY_SUMMARY_CAP` is now what bounds the pool.

## Selected — seeded into migration 0013

Eight publishers, an even IN/GLOBAL split, spread deliberately across the
political spectrum. `lean` is recorded for auditability only; nothing at
runtime reads it. (The Guardian above makes nine.)

| Publisher | Region | Lean | Feed | Mode | `full_text_allowed` | ~items/day | `max_per_run` |
| --- | --- | --- | --- | --- | --- | --- | --- |
| The Hindu | IN | left-of-centre | `/feeder/default.rss` | description-only | false (paywall) | 271 | 3 |
| The New Indian Express | IN | centre-right | `/feed` | RSS full content | false (paywall) | 183 | 3 |
| Deccan Herald | IN | centrist | `/feed` | RSS full content | false | 33 | 5 |
| Scroll.in | IN | left | Feedburner | RSS full content | **true** | 24 | 5 |
| Al Jazeera | GLOBAL | left-of-centre | `/xml/rss/all.xml` | description-only | false | 60 | 4 |
| Deutsche Welle | GLOBAL | centrist | `rss.dw.com` | description-only | **true** | high | 5 |
| The Christian Science Monitor | GLOBAL | centrist | `rss.csmonitor.com` | description-only | false (paywall) | 9 | 5 |
| Reason | GLOBAL | libertarian-right | `/feed/` | RSS full content | false | 25 | 5 |

Only **Scroll.in** and **Deutsche Welle** have `full_text_allowed = true` —
robots.txt permits their article paths *and* an honest fetch returned a real
body. Everyone else is description-only, either because robots says so or
because the page is paywalled. Scroll's RSS already carries full content, so in
practice **DW is the only publisher that exercises the Part C body fetch.**

`max_per_run` holds the two high-volume Indian dailies back so they cannot
crowd out the quieter outlets; the global `MAX_ARTICLES_PER_RUN_TOTAL = 25` and
round-robin fair-share are the real limiters.

## Rejected — checked and excluded

| Publisher | Why |
| --- | --- |
| The Indian Express | Feed emits **empty** `<description>` and `<content:encoded>` on every item — title and link only — and the article page is paywalled. Nothing to summarise. |
| ThePrint | `/feed` and every conventional path return HTTP 200 with an empty body. No usable feed. |
| Swarajya | No parseable feed at any probed path. |
| The Tribune | No parseable feed at any probed path. |
| The Telegraph India | No parseable feed at any probed path. |
| Mint | No parseable feed at any probed path. |
| Firstpost | No parseable feed at any probed path. |

Two publishers **passed but were not seeded**, to keep the starting slate at
eight:

- **France 24** — passed (description-only, ~30/day). Dropped as redundant with
  Deutsche Welle: both are European public broadcasters at the same lean.
- **The Conversation** — passed (RSS full content, ~34/day). Dropped because its
  output is academic analysis and commentary rather than reporting, which sits
  awkwardly against the Part D2 opinion filter.

Both have committed reports and can be enabled later by adding a registry row.

## Known gap in the balance — read this

**No right-of-centre Indian outlet qualified.** Firstpost, Swarajya, ThePrint
and Mint were all tested specifically to fill that slot and all four failed on
technical grounds (no usable feed), not editorial ones. The Indian slate
therefore runs left → centre-right (Scroll, The Hindu, Deccan Herald, The New
Indian Express) with nothing further right.

This is a real skew, not a neutral outcome, and it should not be left to sit.
Options when revisiting: retry the four failures periodically (feeds come and
go), or qualify additional candidates such as `organiser.org`,
`opindia.com`, or `news18.com` — weighing each against the Part A requirement
for a real reporting desk and a corrections policy.

## What the script checks

1. Does an RSS/Atom feed exist, and where?
2. Does `robots.txt` allow `BiteNewsBot` on article paths? What `Crawl-delay`?
3. Does the feed carry `content:encoded`, or description only?
4. Does it expose `<category>` values (needed for opinion filtering)?
5. Roughly how many items per day?

It respects robots.txt for every request it makes — including the feed itself
and any separate feed host — sends one fixed honest User-Agent, and **never
retries anything with different headers**. A paywall, consent wall or bot
challenge is recorded as a finding and the probe stops there.
