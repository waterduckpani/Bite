// Bite · Phase 8: server-side news ingestion. Guardian removed in Phase 15.1.
//
// WHAT THIS FUNCTION IS NOW
//
// A NewsData-only ingester that is currently switched OFF. The Guardian Open
// Platform integration that used to live here was removed in Phase 15.1 — the
// licensed API is gone and Guardian is ingested as an ordinary RSS publisher
// by ingest-rss, like every other outlet. Its pg_cron job (bite-ingest-news)
// is unscheduled in migration 0018, because with NewsData disabled every run
// of this function is a no-op.
//
// It is kept, not deleted, for the same reason NewsData was disabled rather
// than removed (migration 0006): the allowlist, the request grouping, the
// rotating credit window and the credit accounting below are the expensive
// part of that integration, and they are all still correct. Re-enabling is a
// flag, a feed filter and a cron line — see the note on SOURCE_ENABLED.
//
// Upserts article METADATA into public.articles. Clients read the ranked deck
// via get_personalized_feed and never call a news API.
//
// The quality pipeline:
//   - NewsData: a strict source ALLOWLIST (NEWSDATA_ALLOWLIST below) applied
//     via domainurl on the request — only curated, non-paywalled outlets are
//     ever fetched. The free tier caps domainurl at 5 domains per request, so
//     the allowlist is chunked into groups and each run fetches a rotating
//     window of NEWSDATA_GROUPS_PER_RUN groups to stay inside the daily
//     credit budget. datatype=news is still enforced on the response to drop
//     press releases even from allowlisted domains.
//   - Junk filter: shared with ingest-rss via ../_shared/junk.ts.
// Storage order is irrelevant — ranking happens in get_personalized_feed.
//
// Embeddings: the upsert fires the Phase 7 statement-level triggers on
// public.articles, which invoke the "embed" function for any new rows, so
// freshly ingested stories get embeddings with no extra wiring here.
//
// LEGAL: metadata only — bodies are never fetched or stored by ingestion.
//
// Invoked with an empty POST by the pg_cron job (via pg_net); gated by the
// INGEST_SECRET header like the embed function. Deploy with --no-verify-jwt.
// Secrets: NEWSDATA_API_KEY, INGEST_SECRET.

import { createClient } from "jsr:@supabase/supabase-js@2";
import {
  filterJunk,
  type JunkSummary,
} from "../_shared/junk.ts";

// -- Ingestion source config -------------------------------------------------
// Flip a source to `false` to stop pulling it WITHOUT removing the
// integration — set it back to `true` to re-enable. Everything below (the
// allowlist, fetch and junk filter) stays wired up behind this switch; only
// the handler's fetch call is gated on it.
//
// NewsData is disabled for the dev phase. Rows already in the pool from
// earlier NewsData runs are hidden from the live deck by a
// `source <> 'newsdata'` filter in get_personalized_feed (migration 0006) —
// they're kept, not deleted, so any saved NewsData cards survive. Re-enabling
// here must be paired with dropping that feed filter AND re-scheduling the
// bite-ingest-news cron that migration 0018 unscheduled.
const SOURCE_ENABLED = {
  newsdata: false,
} as const;

// -- NewsData source allowlist ----------------------------------------------
// The ONLY NewsData sources allowed into the pool (curated, non-paywalled).
// This is the one place to edit when tuning the NewsData source mix. The
// grouping is editorial; each group's `category` is the fallback used when
// NewsData's own category tag doesn't map to an app category, so regional
// groups land in "world".
//
// IMPORTANT: every domain must exist in NewsData's database EXACTLY as
// written — one unrecognized domain 422s its whole domainurl request (the
// run skips that group and logs it, but its other domains get no articles
// until fixed). All entries below were validated against the live API on
// 2026-07-11. Rejected then: ign.com (only regional subdomains like
// in.ign.com exist), asia.nikkei.com / nikkei.com (only xtech.nikkei.com),
// euractiv.com, thelocal.com (indexed only as regional editions like
// thelocal.de).

const NEWSDATA_ALLOWLIST: { label: string; category: string; domains: string[] }[] = [
  {
    label: "World/General",
    category: "world",
    domains: [
      "reuters.com", "apnews.com", "bbc.com", "aljazeera.com", "dw.com",
      "france24.com", "npr.org", "pbs.org", "cbc.ca", "abc.net.au",
      "axios.com", "csmonitor.com",
    ],
  },
  {
    label: "Business",
    category: "business",
    domains: ["cnbc.com", "marketwatch.com"],
  },
  {
    label: "Technology",
    category: "tech",
    domains: ["theverge.com", "arstechnica.com", "techcrunch.com", "engadget.com"],
  },
  {
    label: "Science",
    category: "science",
    domains: ["nature.com", "sciencenews.org", "livescience.com", "sciencedaily.com"],
  },
  {
    label: "Sports",
    category: "sports",
    domains: ["espn.com", "skysports.com"],
  },
  {
    label: "Entertainment",
    category: "entertainment",
    domains: ["variety.com", "billboard.com", "polygon.com"],
  },
  {
    label: "Middle East",
    category: "world",
    domains: ["timesofisrael.com", "middleeasteye.net", "thenationalnews.com"],
  },
  {
    label: "Asia",
    category: "world",
    domains: ["scmp.com", "straitstimes.com", "japantimes.co.jp"],
  },
  {
    label: "Africa",
    category: "world",
    domains: ["dailymaverick.co.za", "theafricareport.com", "mg.co.za"],
  },
  {
    label: "Latin America",
    category: "world",
    domains: ["batimes.com.ar", "en.mercopress.com"],
  },
  {
    label: "Europe",
    category: "world",
    domains: ["euronews.com", "politico.eu"],
  },
];

// domain -> fallback app category, derived from the allowlist above.
const ALLOWLIST_CATEGORY = new Map<string, string>();
for (const group of NEWSDATA_ALLOWLIST) {
  for (const domain of group.domains) ALLOWLIST_CATEGORY.set(domain, group.category);
}

function domainOf(url: string): string {
  let host = "";
  try {
    host = new URL(url).host;
  } catch {
    return "";
  }
  return host.startsWith("www.") ? host.slice(4) : host;
}

// The allowlist entry covering `domain` (exact or subdomain), or null if the
// domain is off-allowlist. domainurl already restricts the request, but this
// belt-and-braces response check guarantees nothing off-list reaches the
// pool even if NewsData resolves a domain loosely.
function allowlistEntry(domain: string): string | null {
  if (ALLOWLIST_CATEGORY.has(domain)) return domain;
  for (const d of ALLOWLIST_CATEGORY.keys()) {
    if (domain.endsWith(`.${d}`)) return d;
  }
  return null;
}

// -- Shared article row shape (matches public.articles) ---------------------

interface ArticleRow {
  id: string;
  source: "newsdata";
  source_name: string;
  category: string;
  title: string;
  snippet: string;
  image_url: string;
  original_url: string;
  author: string;
  read_minutes: number;
  source_icon_url: string;
  full_text_available: boolean;
  published_at: string | null;
  // never `embedding` — upserts must leave existing vectors untouched
}

// -- Junk / low-quality filter (Phase 9) ------------------------------------
// Applied to EVERY fetched article BEFORE upsert and embedding — a junk hit
// means the row is never stored and never embedded.
//
// The rules themselves moved to ../_shared/junk.ts in Phase 14 so that RSS
// ingestion applies the SAME filter rather than a second copy that drifts.
// That was a pure code move: rules, order, matching and log format are
// unchanged from Phase 9. Tune the lists there.

// -- NewsData (headlines-only license; free tier: 200 credits/day) ----------

// NewsData category tag -> app category; anything unmapped falls back to the
// article's allowlist-group category.
const NEWSDATA_CATEGORIES: Record<string, string> = {
  technology: "tech",
  world: "world",
  business: "business",
  sports: "sports",
  science: "science",
  entertainment: "entertainment",
};

// The free tier accepts at most 5 domains per domainurl request, and each
// request returns only 10 articles shared by the whole group — so group
// composition decides share-of-voice. Two rules keep quiet sources visible:
// high-volume publishers are spread one per group, and the wire services
// get a group with no high-volume domain at all so they reliably win slots.

// Publishers that flood a group's 10-article page if paired together.
const HIGH_VOLUME = new Set([
  "bbc.com", "cnbc.com", "espn.com", "scmp.com", "straitstimes.com",
  "engadget.com",
]);
// Wire services, pinned to a hog-free group.
const WIRES = new Set(["reuters.com", "apnews.com"]);

const DOMAINS_PER_REQUEST = 5;
const REQUEST_GROUPS: string[][] = (() => {
  const all = NEWSDATA_ALLOWLIST.flatMap((g) => g.domains);
  const count = Math.ceil(all.length / DOMAINS_PER_REQUEST);
  const groups: string[][] = Array.from({ length: count }, () => []);

  // Wires share the last group; high-volume domains go one per remaining
  // group (doubling up only if there are more hogs than groups).
  groups[count - 1].push(...all.filter((d) => WIRES.has(d)));
  all
    .filter((d) => HIGH_VOLUME.has(d) && !WIRES.has(d))
    .forEach((d, i) => groups[count > 1 ? i % (count - 1) : 0].push(d));
  // Everyone else fills the currently-smallest group, keeping sizes even
  // (≤ DOMAINS_PER_REQUEST because count = ⌈total / 5⌉).
  for (const d of all) {
    if (HIGH_VOLUME.has(d) || WIRES.has(d)) continue;
    let smallest = 0;
    for (let i = 1; i < groups.length; i++) {
      if (groups[i].length < groups[smallest].length) smallest = i;
    }
    groups[smallest].push(d);
  }
  return groups;
})();

// Groups fetched per run — THE freshness-vs-budget knob. Each group request
// costs 1 NewsData credit (10 articles), so daily spend is
// NEWSDATA_GROUPS_PER_RUN × runs/day. At 3 groups × 48 runs (cron */30,
// migration 0003) = 144 credits/day, under the 190 safety budget
// (free-tier cap 200). 4 groups × 48 = 192 would exceed it. The rotating
// window advances by 3 over the current 8 groups, so every source is
// refreshed roughly every 80 minutes.
const NEWSDATA_GROUPS_PER_RUN = 3;

// Stateless rotation: the cron fires every 30 minutes, so bucketing the
// clock by the same period advances the window by one run's worth of groups
// each firing — no state table needed. (If the cron cadence changes in
// migration 0003, change this to match.)
const ROTATION_PERIOD_MS = 30 * 60 * 1000;

// A cover URL the app's image pipeline can decode: http(s) and not an SVG.
function validImageUrl(url: unknown): string {
  if (typeof url !== "string" || url.length === 0) return "";
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return "";
  }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return "";
  return parsed.pathname.toLowerCase().endsWith(".svg") ? "" : url;
}

async function newsdataGroup(
  apiKey: string,
  domains: string[],
): Promise<Record<string, unknown>> {
  const params = new URLSearchParams({
    apikey: apiKey,
    language: "en",
    domainurl: domains.join(","),
    removeduplicate: "1",
  });
  const res = await fetch(`https://newsdata.io/api/1/latest?${params}`);
  if (!res.ok) {
    // NewsData 4xx bodies name unrecognized domainurl values — surface them
    // so a bad allowlist entry is visible in the logs.
    const body = await res.text().catch(() => "");
    throw new Error(`NewsData HTTP ${res.status}: ${body.slice(0, 300)}`);
  }
  const json = await res.json();
  if (json.status !== "success") {
    throw new Error(`NewsData status ${json.status}`);
  }
  return json;
}

interface NewsdataRun {
  rows: ArticleRow[];
  creditsUsed: number;
  groupsFetched: string[][];
  groupErrors: string[];
  offAllowlistDropped: string[];
}

async function fetchNewsdata(apiKey: string): Promise<NewsdataRun> {
  const groupCount = Math.min(NEWSDATA_GROUPS_PER_RUN, REQUEST_GROUPS.length);
  const startIndex =
    (Math.floor(Date.now() / ROTATION_PERIOD_MS) * groupCount) %
    REQUEST_GROUPS.length;
  const window = Array.from(
    { length: groupCount },
    (_, i) => REQUEST_GROUPS[(startIndex + i) % REQUEST_GROUPS.length],
  );

  // Groups fetch concurrently and fail independently: one unrecognized
  // domain or upstream hiccup skips that group for the run, never the whole
  // ingest.
  const settled = await Promise.allSettled(
    window.map((domains) => newsdataGroup(apiKey, domains)),
  );

  const rows: ArticleRow[] = [];
  const groupErrors: string[] = [];
  const offAllowlistDropped: string[] = [];
  for (let g = 0; g < settled.length; g++) {
    const result = settled[g];
    if (result.status === "rejected") {
      groupErrors.push(`group [${window[g].join(",")}]: ${result.reason}`);
      continue;
    }
    const json = result.value;

    for (const item of (json.results as Record<string, unknown>[]) ?? []) {
      if (item.duplicate === true) continue;
      // Real reporting only — datatype=news drops press releases and blog
      // posts even from allowlisted domains.
      if (item.datatype != null && item.datatype !== "news") continue;

      const title = ((item.title as string) ?? "").trim();
      const url = (item.link as string) ?? "";
      if (!title || !url) continue;

      const domain = domainOf((item.source_url as string) || url);
      const allowed = allowlistEntry(domain);
      if (!allowed) {
        offAllowlistDropped.push(domain);
        continue;
      }

      const category = ((item.category as string[]) ?? [])
        .map((c) => NEWSDATA_CATEGORIES[c])
        .find((c) => c != null) ?? ALLOWLIST_CATEGORY.get(allowed)!;

      const source =
        (item.source_name as string) ?? ((item.source_id as string) ?? "");
      const creators = (item.creator as string[]) ?? [];
      // pubDate arrives as "2026-07-05 18:44:00" in UTC.
      const pubDate = (item.pubDate as string | undefined)?.replace(" ", "T");
      const publishedAt =
        pubDate && !isNaN(Date.parse(`${pubDate}Z`)) ? `${pubDate}Z` : null;

      rows.push({
        id: `newsdata:${item.article_id}`,
        source: "newsdata",
        source_name: source || "News",
        category,
        title,
        snippet: ((item.description as string) ?? "").trim(),
        // Null images are fine — the client renders a gradient cover.
        image_url: validImageUrl(item.image_url),
        original_url: url,
        author: creators[0] ?? (source || "News"),
        read_minutes: 2,
        source_icon_url: (item.source_icon as string) ?? "",
        full_text_available: false, // headline-only license
        published_at: publishedAt,
      });
    }
  }

  return {
    rows,
    // Every issued request spends a credit, successful or not.
    creditsUsed: window.length,
    groupsFetched: window,
    groupErrors,
    offAllowlistDropped,
  };
}

// -- Handler -----------------------------------------------------------------

Deno.serve(async (req) => {
  const secret = Deno.env.get("INGEST_SECRET");
  if (secret && req.headers.get("x-ingest-secret") !== secret) {
    return new Response("forbidden", { status: 403 });
  }

  const newsdataKey = Deno.env.get("NEWSDATA_API_KEY");

  const emptyRun: NewsdataRun = {
    rows: [],
    creditsUsed: 0,
    groupsFetched: [],
    groupErrors: [],
    offAllowlistDropped: [],
  };

  // Gated by SOURCE_ENABLED.newsdata (disabled for the dev phase). The key
  // check stays so a missing NEWSDATA_API_KEY is still a no-op, not a throw.
  const newsdataResult = await Promise.allSettled([
    SOURCE_ENABLED.newsdata && newsdataKey
      ? fetchNewsdata(newsdataKey)
      : Promise.resolve(emptyRun),
  ]);
  const run = newsdataResult[0].status === "fulfilled"
    ? newsdataResult[0].value
    : emptyRun;
  const errors = newsdataResult
    .filter((r) => r.status === "rejected")
    .map((r) => `${(r as PromiseRejectedResult).reason}`);
  errors.push(...run.groupErrors);

  // Per-source article counts for this run's window — makes the function logs
  // answer "which allowlisted sources actually return stories".
  const sourceCounts: Record<string, number> = {};
  for (const row of run.rows) {
    const domain = domainOf(row.original_url);
    sourceCounts[domain] = (sourceCounts[domain] ?? 0) + 1;
  }
  console.log(
    `[ingest-news] newsdata credits=${run.creditsUsed}` +
      ` groups=${JSON.stringify(run.groupsFetched)}` +
      ` sources=${JSON.stringify(sourceCounts)}` +
      ` offAllowlistDropped=${JSON.stringify(run.offAllowlistDropped)}` +
      (run.groupErrors.length
        ? ` groupErrors=${JSON.stringify(run.groupErrors)}`
        : ""),
  );

  // Junk / low-quality filter — applied before upsert and embedding, so junk
  // never reaches storage or spends an embed call.
  const junk: JunkSummary = { total: 0, byCategory: {}, samplesByCategory: {} };
  const rows = filterJunk(run.rows, junk);
  console.log(
    `[ingest-news] junk dropped=${junk.total}` +
      ` byCategory=${JSON.stringify(junk.byCategory)}` +
      ` samples=${JSON.stringify(junk.samplesByCategory)}`,
  );

  let upserted = 0;
  if (rows.length > 0) {
    // Service role: ingestion writes bypass RLS (clients can still upsert
    // metadata on interaction via their own policies).
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );
    const { error } = await supabase.from("articles").upsert(rows);
    if (error) {
      return Response.json(
        { error: error.message, errors },
        { status: 500 },
      );
    }
    upserted = rows.length;
  }

  return Response.json({
    newsdata: rows.length,
    upserted,
    errors,
    junk_dropped: junk.total,
    junk_by_category: junk.byCategory,
    junk_samples: junk.samplesByCategory,
    newsdata_credits: run.creditsUsed,
    newsdata_groups: run.groupsFetched,
    newsdata_sources: sourceCounts,
    off_allowlist_dropped: run.offAllowlistDropped,
  });
});
