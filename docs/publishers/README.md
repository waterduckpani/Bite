# Publisher qualification — Phase 14

Every publisher in the `publishers` registry was checked with
`tools/qualify_publisher.dart` before being added, and its report is committed
in this directory. **No publisher is added on assumption.** Re-run the script
and update the report before changing any registry row.

```bash
dart run tools/qualify_publisher.dart --all          # the full candidate slate
dart run tools/qualify_publisher.dart thehindu.com   # one domain

# One exact feed, for a publisher that runs several (discovery only ever finds
# the first feed that parses):
dart run tools/qualify_publisher.dart theguardian.com \
    --feed=https://www.theguardian.com/world/rss \
    --slug=theguardian.com-world --name="The Guardian (world)"
```

Checked on **2026-07-25** with the honest User-Agent
`BiteNewsBot/1.0 (+https://waterduckpani.github.io/Bite/bot)`.

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
  `MAX_ARTICLES_PER_RUN_TOTAL = 25`**, not an addition to it. Total daily
  volume is unchanged and still tied to `DAILY_SUMMARY_CAP`; Guardian takes a
  share of it. Its freshness also drops from the old 30-minute API cron to the
  3-hourly RSS cycle.

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
