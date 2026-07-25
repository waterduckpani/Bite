// Bite · Phase 14: publisher-direct RSS ingestion.
//
// Separate from ingest-news (Guardian) on purpose: different cadence, different
// legal posture, different failure modes. Guardian is licensed full text with a
// native reader; everything here is LINK-OUT ONLY. Nothing in this file can
// change the Guardian path, and a total failure here leaves the Guardian deck
// working exactly as before.
//
// The governing principle is that Bite is a REFERRER, not a replacement. That
// shows up here as three concrete rules:
//   - full_text_available is written FALSE for every row, unconditionally, so
//     the Phase 6 router always sends these stories to the publisher's own page.
//   - source_name and original_url are always populated: attribution is
//     structural, and the card cannot render without them.
//   - any body text fetched is stored in rss_bodies (service-role only) purely
//     as summariser input, and is never reachable by the client.
//
// Politeness and honesty are enforced in _shared/bot.ts, which owns the single
// User-Agent and the robots.txt logic. There is no code path in this function
// that can fetch with a different identity or retry a refused page.
//
// Pipeline order matters and is a cost control (Part D3): junk filter →
// opinion filter → dedupe → fair-share cap → THEN the body fetch. Tokens and
// outbound requests are only ever spent on rows that will actually be shown.
//
// Invoked with an empty POST by the pg_cron job (bite-ingest-rss, every 3
// hours); gated by the INGEST_RSS_SECRET header. Deploy with --no-verify-jwt.
//   supabase secrets set INGEST_RSS_SECRET=c7d21e5a84f9b0362d1c8e47a5b93f60e284c71d9a3b5f08
//   supabase functions deploy ingest-rss --no-verify-jwt

import { createClient } from "jsr:@supabase/supabase-js@2";
import {
  botFetch,
  canonicalUrl,
  crawlDelayMs,
  detectWall,
  fetchRobots,
  politeWait,
  robotsAllows,
  ROBOTS_CACHE_HOURS,
  type Robots,
  rssArticleId,
  statusIsRefusal,
} from "../_shared/bot.ts";
import {
  emptyJunkSummary,
  filterJunk,
  type JunkSummary,
} from "../_shared/junk.ts";
import { hasUsableFullContent, parseFeed, type RssItem } from "../_shared/rss.ts";

/// Service-role client. Declared as a factory so `Db` is the exact inferred
/// client type — annotating helpers with `ReturnType<typeof createClient>`
/// instead resolves the table types to `never` and every .update() fails to
/// type-check.
const createDb = () =>
  createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
type Db = ReturnType<typeof createDb>;

// -- Config (one place) -----------------------------------------------------

/// Global ceiling per run, across ALL enabled publishers. 25 x 8 runs/day =
/// 200/day = DAILY_SUMMARY_CAP, so ingestion can never outrun the summariser's
/// budget. Raising this without raising DAILY_SUMMARY_CAP just means more rows
/// with no bite.
const MAX_ARTICLES_PER_RUN_TOTAL = 25;

/// How far back a story may be published and still be ingested. The feed pool
/// in get_personalized_feed is 48h, so anything older is dead on arrival.
const MAX_ITEM_AGE_HOURS = 48;

/// Window of existing rows checked for cross-source duplicates. Wider than
/// MAX_ITEM_AGE_HOURS so a story Guardian filed early still suppresses the
/// RSS copy filed later.
const DEDUP_WINDOW_HOURS = 72;

/// Title-token Jaccard at or above which two stories are "the same story".
/// Same value and same tokeniser as ingest-news, so the two functions agree.
const DEDUP_JACCARD = 0.5;

// -- Category mapping -------------------------------------------------------
// public.articles.category must be one of the app's six categories; the client
// maps anything unknown to `world`. Feeds use wildly inconsistent vocabulary,
// so we match the feed's own <category> values first, then fall back to the
// URL path, then to `world`.

type AppCategory =
  | "tech" | "world" | "business" | "sports" | "science" | "entertainment";

const CATEGORY_KEYWORDS: { category: AppCategory; words: string[] }[] = [
  {
    category: "tech",
    words: ["tech", "technology", "science and tech", "gadget", "computing",
      "artificial intelligence", "internet", "cyber", "software"],
  },
  {
    category: "business",
    words: ["business", "economy", "economic", "market", "finance",
      "financial", "money", "trade", "companies", "industry"],
  },
  {
    category: "sports",
    words: ["sport", "sports", "cricket", "football", "soccer", "tennis",
      "olympic", "hockey", "athletics"],
  },
  {
    category: "science",
    words: ["science", "environment", "climate", "health", "space",
      "research", "nature", "medicine"],
  },
  {
    category: "entertainment",
    words: ["entertainment", "culture", "film", "movie", "music", "arts",
      "books", "television", "tv", "celebrity", "bollywood", "lifestyle"],
  },
  {
    category: "world",
    words: ["world", "international", "global", "news", "india", "national",
      "politics", "asia", "africa", "europe", "americas", "middle east"],
  },
];

function categoryFor(item: RssItem, url: string): AppCategory {
  const haystacks = [
    ...item.categories.map((c) => c.toLowerCase()),
    (() => {
      try {
        return new URL(url).pathname.toLowerCase().replace(/[-_/]+/g, " ");
      } catch {
        return "";
      }
    })(),
  ];
  for (const hay of haystacks) {
    for (const { category, words } of CATEGORY_KEYWORDS) {
      for (const word of words) {
        if (hay.includes(word)) return category;
      }
    }
  }
  return "world";
}

// -- Part D2: opinion / editorial filter ------------------------------------
// Excludes non-reporting content STRUCTURALLY, before summarisation, so no
// tokens are spent on it and it never reaches the deck.
//
// This is the reliable, mechanical half of "no biased articles" — it removes
// content that is *labelled* as opinion by the publisher themselves. It makes
// no judgement about the content of reporting, which is not something a
// keyword list can do honestly.
//
// Tuning discipline is Phase 9's: CONSERVATIVE, and every drop is logged with
// the rule that caught it so false positives are catchable from the logs.

const OPINION_URL_PATHS = [
  "/opinion/", "/opinions/", "/editorial/", "/editorials/", "/op-ed/",
  "/oped/", "/blogs/", "/blog/", "/columns/", "/column/", "/voices/",
  "/comment/", "/commentisfree/",
];

/// Whole-word matches against the feed's own <category> values. "comment" is
/// deliberately absent here (it appears as a section name in URL paths but as
/// a noun in legitimate category strings); "analysis" is absent too, since
/// analysis is frequently straight reporting.
const OPINION_CATEGORY_RE =
  /\b(opinion|opinions|editorial|editorials|op-?ed|column|columns|columnist|blog|blogs|voices|commentary|letters to the editor)\b/i;

function opinionMatch(
  item: RssItem,
  url: string,
): { kind: string; rule: string } | null {
  let path = "";
  try {
    path = new URL(url).pathname.toLowerCase();
  } catch {
    path = url.toLowerCase();
  }
  for (const segment of OPINION_URL_PATHS) {
    if (path.includes(segment)) return { kind: "url_path", rule: segment };
  }
  for (const category of item.categories) {
    const m = OPINION_CATEGORY_RE.exec(category);
    if (m) return { kind: "rss_category", rule: `${category} ~ ${m[1]}` };
  }
  return null;
}

// -- Row shape (matches public.articles) ------------------------------------

interface ArticleRow {
  id: string;
  source: "rss";
  source_name: string;
  category: string;
  title: string;
  snippet: string;
  image_url: string;
  original_url: string;
  author: string;
  read_minutes: number;
  source_icon_url: string;
  /// ALWAYS false. This is the reader-routing flag, and every Phase 14
  /// publisher is link-out only — their body is never rendered natively, even
  /// when we are permitted to fetch it for summarisation. Do not make this
  /// conditional.
  full_text_available: false;
  published_at: string | null;
  publisher_id: string;
  rss_categories: string[];
  // `tags` is deliberately NOT set. It is Guardian tag space; writing RSS
  // categories into it would silently break tracker matching (see the note on
  // run_tracker_matching in migration 0013).
}

interface Publisher {
  id: string;
  name: string;
  canonical_domain: string;
  rss_url: string;
  full_text_allowed: boolean;
  robots_checked_at: string | null;
  robots_crawl_delay: number | null;
  robots_rules: { allow: boolean; pattern: string }[];
  max_per_run: number;
}

// -- Dedup ------------------------------------------------------------------
// Same tokeniser and threshold as ingest-news, so "the same story" means the
// same thing in both functions.

const STOPWORDS = new Set([
  "a", "an", "and", "as", "at", "be", "by", "for", "from", "in", "is",
  "it", "of", "on", "the", "to", "with", "after", "over", "says", "say",
]);

function titleTokens(title: string): Set<string> {
  return new Set(
    title
      .toLowerCase()
      .replace(/[^a-z0-9 ]/g, " ")
      .split(/\s+/)
      .filter((w) => w.length > 1 && !STOPWORDS.has(w)),
  );
}

function jaccard(a: Set<string>, b: Set<string>): number {
  if (a.size === 0 || b.size === 0) return 0;
  let intersection = 0;
  for (const t of a) if (b.has(t)) intersection++;
  return intersection / (a.size + b.size - intersection);
}

// -- robots.txt refresh -----------------------------------------------------

/// Returns the publisher's robots rules, refetching when the cache is older
/// than ROBOTS_CACHE_HOURS. Also re-derives full_text_allowed: it is set ONLY
/// from robots.txt, never by hand.
async function refreshRobots(
  supabase: Db,
  publisher: Publisher,
  log: string[],
): Promise<Robots> {
  const cachedAt = publisher.robots_checked_at
    ? Date.parse(publisher.robots_checked_at)
    : 0;
  const ageHours = (Date.now() - cachedAt) / 3_600_000;

  if (cachedAt && ageHours < ROBOTS_CACHE_HOURS) {
    return {
      fetched: true,
      status: 200,
      rules: publisher.robots_rules ?? [],
      crawlDelaySeconds: publisher.robots_crawl_delay,
      groupUsed: "cached",
    };
  }

  const origin = `https://www.${publisher.canonical_domain}`;
  await politeWait(new URL(origin).host, crawlDelayMs(publisher.robots_crawl_delay));
  let robots = await fetchRobots(origin);
  if (!robots.fetched) {
    const apex = `https://${publisher.canonical_domain}`;
    await politeWait(new URL(apex).host, crawlDelayMs(publisher.robots_crawl_delay));
    robots = await fetchRobots(apex);
  }

  // full_text_allowed is a DERIVED value: a representative article path under
  // the publisher's own domain must be allowed for our named bot. When
  // robots.txt could not be read at all we do not grant permission.
  const representative = `/article/`;
  const allowed = robots.fetched && robotsAllows(robots, representative);

  await supabase
    .from("publishers")
    .update({
      robots_checked_at: new Date().toISOString(),
      robots_crawl_delay: robots.crawlDelaySeconds,
      robots_rules: robots.rules,
      full_text_allowed: allowed,
    })
    .eq("id", publisher.id);

  publisher.full_text_allowed = allowed;
  publisher.robots_crawl_delay = robots.crawlDelaySeconds;
  log.push(
    `[ingest-rss] robots publisher=${publisher.id} status=${robots.status}` +
      ` group=${robots.groupUsed} rules=${robots.rules.length}` +
      ` crawlDelay=${robots.crawlDelaySeconds ?? "-"} full_text_allowed=${allowed}`,
  );
  return robots;
}

// -- Per-publisher fetch + normalise ----------------------------------------

interface PublisherRun {
  publisher: Publisher;
  robots: Robots;
  candidates: ArticleRow[];
  items: Map<string, RssItem>;
  fetched: number;
  droppedOld: number;
  droppedOpinion: number;
  error?: string;
}

async function fetchPublisher(
  supabase: Db,
  publisher: Publisher,
  junk: JunkSummary,
  log: string[],
): Promise<PublisherRun> {
  const run: PublisherRun = {
    publisher,
    robots: {
      fetched: false, status: 0, rules: [], crawlDelaySeconds: null,
      groupUsed: "none",
    },
    candidates: [],
    items: new Map(),
    fetched: 0,
    droppedOld: 0,
    droppedOpinion: 0,
  };

  run.robots = await refreshRobots(supabase, publisher, log);

  // The feed may live on a different host (rss.dw.com, feeds.feedburner.com);
  // that host's robots.txt governs fetching it.
  const feedUri = new URL(publisher.rss_url);
  const publisherHost = new URL(`https://www.${publisher.canonical_domain}`).host;
  const feedRobots = feedUri.host === publisherHost
    ? run.robots
    : await fetchRobots(`${feedUri.protocol}//${feedUri.host}`);

  if (!robotsAllows(feedRobots, feedUri.pathname)) {
    run.error = `robots.txt disallows the feed path ${feedUri.pathname}`;
    log.push(`[ingest-rss] SKIP publisher=${publisher.id} ${run.error}`);
    return run;
  }

  await politeWait(feedUri.host, crawlDelayMs(feedRobots.crawlDelaySeconds));
  const res = await botFetch(publisher.rss_url);
  if (!res.ok) {
    run.error = `feed HTTP ${res.status}${res.error ? ` (${res.error})` : ""}`;
    log.push(`[ingest-rss] SKIP publisher=${publisher.id} ${run.error}`);
    return run;
  }

  const items = parseFeed(res.body);
  run.fetched = items.length;
  if (items.length === 0) {
    run.error = "feed parsed to zero items";
    log.push(`[ingest-rss] publisher=${publisher.id} ${run.error}`);
    return run;
  }

  const cutoff = Date.now() - MAX_ITEM_AGE_HOURS * 3_600_000;
  const rows: ArticleRow[] = [];

  for (const item of items) {
    const url = canonicalUrl(item.link);
    if (!url.startsWith("http")) continue;

    // Too old to ever reach the 48h feed pool — drop before anything costly.
    const published = item.publishedAt ? Date.parse(item.publishedAt) : NaN;
    if (!Number.isNaN(published) && published < cutoff) {
      run.droppedOld++;
      continue;
    }

    // Part D2 — opinion / editorial, logged with its rule (Phase 9 style).
    const opinion = opinionMatch(item, url);
    if (opinion) {
      run.droppedOpinion++;
      log.push(
        `[ingest-rss] opinion drop rule=${opinion.kind}:${opinion.rule}` +
          ` source=${publisher.name} title=${JSON.stringify(item.title)}`,
      );
      continue;
    }

    const id = await rssArticleId(publisher.id, url);
    const description = item.description || item.fullContent.slice(0, 400);
    const words = item.fullContent.length > 0
      ? item.fullContent.split(/\s+/).length
      : 0;

    rows.push({
      id,
      source: "rss",
      source_name: publisher.name,          // attribution: NOT NULL
      category: categoryFor(item, url),
      title: item.title,
      snippet: description.slice(0, 600),
      image_url: item.imageUrl,
      original_url: url,                    // attribution: NOT NULL
      author: item.author || publisher.name,
      read_minutes: words > 0
        ? Math.min(30, Math.max(1, Math.ceil(words / 220)))
        : 2,
      source_icon_url: "",
      full_text_available: false,           // link-out only, always
      published_at: item.publishedAt,
      publisher_id: publisher.id,
      rss_categories: item.categories.slice(0, 12),
    });
    run.items.set(id, item);
  }

  // Phase 9 junk filter, unchanged and shared with ingest-news.
  run.candidates = filterJunk(rows, junk, "ingest-rss");
  return run;
}

// -- Part C: conditional body fetch -----------------------------------------

/// Fetches an article body for summarisation, ONLY when robots.txt allows the
/// specific path and the RSS did not already carry full content.
///
/// Any wall — paywall, login wall, consent wall, bot challenge — or any
/// refusal status ABORTS. The row keeps full_text_available = false (it always
/// does), the reason is logged, and we move on to the next article. Nothing is
/// ever retried with different headers; there is no code path here that could.
async function fetchBody(
  row: ArticleRow,
  robots: Robots,
  crawlDelay: number,
  log: string[],
): Promise<{ body: string } | { skipped: string }> {
  const uri = new URL(row.original_url);
  if (!robotsAllows(robots, uri.pathname)) {
    return { skipped: `robots_disallow:${uri.pathname}` };
  }

  await politeWait(uri.host, crawlDelay);
  const res = await botFetch(row.original_url);

  const refusal = statusIsRefusal(res.status);
  if (refusal || !res.ok) {
    const reason = refusal ?? `http_${res.status}`;
    log.push(
      `[ingest-rss] body abort id=${row.id} source=${row.source_name} reason=${reason}`,
    );
    return { skipped: reason };
  }

  const wall = detectWall(res.body);
  if (wall) {
    log.push(
      `[ingest-rss] body abort id=${row.id} source=${row.source_name} reason=wall:${wall}`,
    );
    return { skipped: `wall:${wall}` };
  }

  const body = readableText(res.body);
  if (body.length < 600) {
    log.push(
      `[ingest-rss] body abort id=${row.id} source=${row.source_name}` +
        ` reason=too_short:${body.length}`,
    );
    return { skipped: `too_short:${body.length}` };
  }
  return { body };
}

/// Readability-style extraction: paragraph text, minus boilerplate containers.
/// Intentionally simple — a thin extraction just means a thinner bite, and the
/// 80-word cap bounds the output either way.
function readableText(html: string): string {
  const cleaned = html
    .replace(/<script[\s\S]*?<\/script>/gi, " ")
    .replace(/<style[\s\S]*?<\/style>/gi, " ")
    .replace(/<noscript[\s\S]*?<\/noscript>/gi, " ")
    .replace(/<(nav|header|footer|aside|form)\b[\s\S]*?<\/\1>/gi, " ");

  const paragraphs: string[] = [];
  for (const m of cleaned.matchAll(/<p\b[^>]*>([\s\S]*?)<\/p>/gi)) {
    const text = m[1]
      .replace(/<[^>]+>/g, " ")
      .replace(/&nbsp;/g, " ")
      .replace(/&amp;/g, "&")
      .replace(/&quot;/g, '"')
      .replace(/&#0?39;/g, "'")
      .replace(/&lt;/g, "<")
      .replace(/&gt;/g, ">")
      .replace(/\s+/g, " ")
      .trim();
    // Short fragments are captions, bylines, share prompts and cookie notices.
    if (text.length >= 60) paragraphs.push(text);
  }
  return paragraphs.join("\n\n").slice(0, 12_000);
}

// -- Handler ----------------------------------------------------------------

Deno.serve(async (req) => {
  const secret = Deno.env.get("INGEST_RSS_SECRET");
  if (secret && req.headers.get("x-ingest-rss-secret") !== secret) {
    return new Response("forbidden", { status: 403 });
  }

  const supabase = createDb();

  const log: string[] = [];

  // Only enabled publishers are ever fetched — the kill switch stops
  // ingestion here, and the feed RPC hides existing cards on the read side.
  const { data: publisherRows, error: publisherError } = await supabase
    .from("publishers")
    .select(
      "id, name, canonical_domain, rss_url, full_text_allowed, robots_checked_at," +
        " robots_crawl_delay, robots_rules, max_per_run",
    )
    .eq("enabled", true)
    .order("id");
  if (publisherError) {
    return Response.json({ error: publisherError.message }, { status: 500 });
  }
  const publishers = (publisherRows ?? []) as unknown as Publisher[];
  if (publishers.length === 0) {
    console.log("[ingest-rss] no enabled publishers; nothing to do");
    return Response.json({ publishers: 0, upserted: 0 });
  }

  // 1. Fetch every publisher. Failures are per-publisher: one dead feed never
  //    stops the others.
  const junk: JunkSummary = emptyJunkSummary();
  const runs: PublisherRun[] = [];
  for (const publisher of publishers) {
    try {
      runs.push(await fetchPublisher(supabase, publisher, junk, log));
    } catch (e) {
      log.push(`[ingest-rss] publisher=${publisher.id} threw: ${e}`);
      runs.push({
        publisher,
        robots: {
          fetched: false, status: 0, rules: [], crawlDelaySeconds: null,
          groupUsed: "none",
        },
        candidates: [],
        items: new Map(),
        fetched: 0,
        droppedOld: 0,
        droppedOpinion: 0,
        error: `${e}`,
      });
    }
  }

  // 2. Dedupe against what is already in the pool — INCLUDING Guardian, which
  //    always wins: it is the copy with licensed full text and a native
  //    reader, so an RSS duplicate of a Guardian story adds nothing.
  const since = new Date(Date.now() - DEDUP_WINDOW_HOURS * 3_600_000)
    .toISOString();
  const { data: existingRows } = await supabase
    .from("articles")
    .select("title, original_url")
    .gte("created_at", since)
    .limit(2000);

  const seenUrls = new Set<string>();
  const seenTitles: Set<string>[] = [];
  for (const row of (existingRows ?? []) as { title: string; original_url: string }[]) {
    seenUrls.add(canonicalUrl(row.original_url ?? ""));
    seenTitles.push(titleTokens(row.title ?? ""));
  }

  let droppedDuplicate = 0;
  for (const run of runs) {
    const kept: ArticleRow[] = [];
    for (const row of run.candidates) {
      if (seenUrls.has(row.original_url)) {
        droppedDuplicate++;
        continue;
      }
      const tokens = titleTokens(row.title);
      if (seenTitles.some((t) => jaccard(t, tokens) >= DEDUP_JACCARD)) {
        droppedDuplicate++;
        continue;
      }
      seenUrls.add(row.original_url);
      seenTitles.push(tokens);
      kept.push(row);
    }
    // Newest first, so the fair-share pass takes each publisher's freshest.
    kept.sort((a, b) =>
      Date.parse(b.published_at ?? "") - Date.parse(a.published_at ?? "")
    );
    run.candidates = kept;
  }

  // 3. Fair share: round-robin across publishers so one high-volume outlet
  //    cannot take the whole run. (The same lesson as the NewsData allowlist
  //    grouping in ingest-news.) Each publisher is additionally capped at its
  //    own max_per_run.
  const selected: { row: ArticleRow; run: PublisherRun }[] = [];
  const takenPerPublisher = new Map<string, number>();
  for (
    let round = 0;
    selected.length < MAX_ARTICLES_PER_RUN_TOTAL && round < 50;
    round++
  ) {
    let progressed = false;
    for (const run of runs) {
      if (selected.length >= MAX_ARTICLES_PER_RUN_TOTAL) break;
      const taken = takenPerPublisher.get(run.publisher.id) ?? 0;
      if (taken >= run.publisher.max_per_run) continue;
      if (round >= run.candidates.length) continue;
      selected.push({ row: run.candidates[round], run });
      takenPerPublisher.set(run.publisher.id, taken + 1);
      progressed = true;
    }
    if (!progressed) break;
  }

  // Never silently truncate: say what was left on the floor.
  const totalCandidates = runs.reduce((n, r) => n + r.candidates.length, 0);
  if (totalCandidates > selected.length) {
    log.push(
      `[ingest-rss] fair-share cap: kept ${selected.length} of ${totalCandidates}` +
        ` candidates (MAX_ARTICLES_PER_RUN_TOTAL=${MAX_ARTICLES_PER_RUN_TOTAL});` +
        ` per-publisher=${JSON.stringify(Object.fromEntries(takenPerPublisher))}`,
    );
  }

  // 4. Part C — body fetch, only for selected rows, only where permitted, and
  //    only where the RSS did not already carry the full article.
  const bodies: { article_id: string; body: string }[] = [];
  const bodySkips: Record<string, number> = {};
  for (const { row, run } of selected) {
    const item = run.items.get(row.id);
    if (!item) continue;
    if (hasUsableFullContent(item)) {
      // The feed already gave us the article; no request to the publisher is
      // needed at all. The politest outcome.
      bodies.push({ article_id: row.id, body: item.fullContent.slice(0, 12_000) });
      continue;
    }
    if (!run.publisher.full_text_allowed) {
      bodySkips["not_allowed"] = (bodySkips["not_allowed"] ?? 0) + 1;
      continue;
    }
    const result = await fetchBody(
      row,
      run.robots,
      crawlDelayMs(run.publisher.robots_crawl_delay),
      log,
    );
    if ("body" in result) {
      bodies.push({ article_id: row.id, body: result.body });
    } else {
      const kind = result.skipped.split(":")[0];
      bodySkips[kind] = (bodySkips[kind] ?? 0) + 1;
    }
  }

  // 5. Write. Articles first (rss_bodies FKs to them).
  let upserted = 0;
  if (selected.length > 0) {
    const { error } = await supabase
      .from("articles")
      .upsert(selected.map((s) => s.row));
    if (error) {
      console.log(`[ingest-rss] upsert failed: ${error.message}`);
      return Response.json({ error: error.message, log }, { status: 500 });
    }
    upserted = selected.length;

    if (bodies.length > 0) {
      const { error: bodyError } = await supabase
        .from("rss_bodies")
        .upsert(bodies.map((b) => ({ ...b, fetched_at: new Date().toISOString() })));
      if (bodyError) {
        // Bodies are an optimisation: without them the article still gets a
        // description-mode bite. Never fail the run over this.
        log.push(`[ingest-rss] rss_bodies upsert failed: ${bodyError.message}`);
      }
    }
  }

  for (const line of log) console.log(line);
  console.log(
    `[ingest-rss] junk dropped=${junk.total}` +
      ` byCategory=${JSON.stringify(junk.byCategory)}` +
      ` samples=${JSON.stringify(junk.samplesByCategory)}`,
  );

  const report = {
    publishers: publishers.length,
    per_publisher: Object.fromEntries(
      runs.map((r) => [r.publisher.id, {
        fetched: r.fetched,
        candidates: r.candidates.length,
        taken: takenPerPublisher.get(r.publisher.id) ?? 0,
        dropped_old: r.droppedOld,
        dropped_opinion: r.droppedOpinion,
        full_text_allowed: r.publisher.full_text_allowed,
        error: r.error ?? null,
      }]),
    ),
    selected: selected.length,
    upserted,
    bodies_stored: bodies.length,
    body_skips: bodySkips,
    dropped_duplicate: droppedDuplicate,
    dropped_opinion: runs.reduce((n, r) => n + r.droppedOpinion, 0),
    junk_dropped: junk.total,
    junk_by_category: junk.byCategory,
  };
  console.log(`[ingest-rss] run ${JSON.stringify(report)}`);
  return Response.json(report);
});
