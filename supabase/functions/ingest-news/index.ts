// Bite · Phase 8: server-side news ingestion.
//
// Replaces the client-side feed fetch: pulls Guardian + NewsData on a pg_cron
// schedule and upserts article METADATA into public.articles. Clients read
// the ranked deck via get_personalized_feed and never call the news APIs for
// the feed, so NewsData credit usage is a function of cron frequency, not
// user count. (The reader's on-demand Guardian body fetch goes through the
// guardian-body function, so no news-API key ships in the client at all.)
//
// The quality pipeline:
//   - Guardian: configured sections only, real articles only (no liveblogs
//     or galleries).
//   - NewsData: a strict source ALLOWLIST (NEWSDATA_ALLOWLIST below) applied
//     via domainurl on the request — only curated, non-paywalled outlets are
//     ever fetched. The free tier caps domainurl at 5 domains per request, so
//     the allowlist is chunked into groups and each run fetches a rotating
//     window of NEWSDATA_GROUPS_PER_RUN groups to stay inside the daily
//     credit budget. datatype=news is still enforced on the response to drop
//     press releases even from allowlisted domains.
//   - Dedup: same story across outlets keeps the Guardian copy (it carries
//     licensed full text), matched by title-token Jaccard similarity.
// Storage order is irrelevant — ranking happens in get_personalized_feed —
// so the client's interleave/quality-sort steps are intentionally absent.
//
// Embeddings: the upsert fires the Phase 7 statement-level triggers on
// public.articles, which invoke the "embed" function for any new rows, so
// freshly ingested stories get embeddings with no extra wiring here.
//
// LEGAL: metadata only — bodies are never fetched or stored by ingestion.
//
// Invoked with an empty POST by the pg_cron job (via pg_net); gated by the
// INGEST_SECRET header like the embed function. Deploy with --no-verify-jwt.
// Secrets: GUARDIAN_API_KEY, NEWSDATA_API_KEY, INGEST_SECRET.

import { createClient } from "jsr:@supabase/supabase-js@2";

// -- Ingestion source config -------------------------------------------------
// Which providers the scheduled ingestion actually fetches. Flip a source to
// `false` to stop pulling it WITHOUT removing the integration — set it back to
// `true` to re-enable. Everything below (the NewsData allowlist, fetch, dedup
// and junk filter) stays wired up behind this switch; only the handler's fetch
// call is gated on it.
//
// NewsData is disabled for the dev phase (Guardian-only). Rows already in the
// pool from earlier NewsData runs are hidden from the live deck by a
// `source <> 'newsdata'` filter in get_personalized_feed (migration 0006) —
// they're kept, not deleted, so any saved NewsData cards survive. Re-enabling
// here should be paired with dropping that feed filter.
const SOURCE_ENABLED = {
  guardian: true,
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
  source: "guardian" | "newsdata";
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
  // Guardian keyword tag ids (e.g. "world/russia"). Omitted for sources with
  // no tags — the column defaults to '{}'. Phase 13 tracker matching leans on
  // these as its strongest same-story signal.
  tags?: string[];
  // never `embedding` — upserts must leave existing vectors untouched
}

function plainText(html: string): string {
  return html
    .replace(/<[^>]+>/g, "")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&#x27;/g, "'")
    .replace(/&nbsp;/g, " ")
    .trim();
}

// -- Junk / low-quality filter (Phase 9) ------------------------------------
// Applied to EVERY fetched article (Guardian + NewsData) BEFORE dedup, upsert
// and embedding — a junk hit means the row is never stored and never embedded.
//
// Tuning philosophy: CONSERVATIVE. A false positive (dropping a real news
// story) is worse than letting a little junk through, so every pattern below
// is a specific multi-word phrase or a URL-path segment. Bare ambiguous words
// ("odds", "sale", "deal", "amazon", "sponsored", "promoted") are deliberately
// NOT listed on their own — a few are kept commented out with a note so they
// can be reconsidered from the drop logs. Edit the arrays below to tune; each
// array maps to one rule category that appears in the per-run drop summary.
//
// Matching is case-insensitive. PHRASE lists are matched against the title AND
// a separator-normalised form of the URL path (so "black-friday" in a slug
// counts as "black friday"). URL_PATH lists match the raw URL path only.

// Promo / shopping / commerce.
const JUNK_PROMO_PHRASES = [
  "promo code", "coupon", "discount code", "best deals", "% off",
  "save up to", "shop now", "black friday", "cyber monday",
  "prime day", "giveaway", "gift guide", "gift ideas", "top picks",
  "our favorite", "worth buying",
  // Omitted on purpose — bare "deals"/"deal" catches real news ("trade
  // deals", "peace deal"); "best deals" above covers the shopping sense.
  // "buy now" is handled separately below so the finance topic "buy now,
  // pay later" (BNPL) isn't dropped as a shopping CTA.
];

// Betting / gambling. ("prediction" is handled separately below — it only
// counts when paired with an odds/betting context word.)
const JUNK_BETTING_PHRASES = [
  "betting odds", "best bets", "parlay", "sportsbook", "bonus code",
  "casino", "lottery numbers",
  // Omitted on purpose — bare "odds" is common in legit sport/politics
  // headlines ("against the odds", "odds of a recession").
];

// Horoscope / astrology.
const JUNK_HOROSCOPE_PHRASES = [
  "horoscope", "zodiac", "astrology", "tarot",
];

// Streaming / "how to watch" guides.
const JUNK_STREAMING_PHRASES = [
  "how to watch", "where to watch", "live stream", "livestream",
  "watch live", "streaming guide",
];

// Advertorial / paid placement.
const JUNK_ADVERTORIAL_PHRASES = [
  "advertorial", "in partnership with", "paid content",
  // Omitted on purpose — these hit real coverage of the ad/media world:
  // "advertisement" → "Super Bowl advertisement costs…", "sponsored" →
  // "state-sponsored hackers", "promoted" → sport/job promotions. Re-enable
  // from the drop logs if advertorials slip through the curated sources.
  // "advertisement", "sponsored", "promoted",
];

// Listicle / clickbait — anchored regexes matched against the TITLE only.
const JUNK_LISTICLE_PATTERNS = [
  /^\s*\d+\s+(best|things|ways|reasons|tips)\b/i,
  /things you need to know/i,
  /you won'?t believe/i,
  /here'?s why/i,
];

// Phrase lists grouped by the rule category they report as.
const JUNK_PHRASE_RULES: { category: string; phrases: string[] }[] = [
  { category: "promo_shopping", phrases: JUNK_PROMO_PHRASES },
  { category: "betting_gambling", phrases: JUNK_BETTING_PHRASES },
  { category: "horoscope_astrology", phrases: JUNK_HOROSCOPE_PHRASES },
  { category: "streaming_guides", phrases: JUNK_STREAMING_PHRASES },
  { category: "advertorial", phrases: JUNK_ADVERTORIAL_PHRASES },
];

// URL path segments, each tagged with the category it reports as. Matched
// against the raw (lowercased) URL path only, so they can't fire on titles.
const JUNK_URL_PATH_RULES: { category: string; path: string }[] = [
  { category: "promo_shopping", path: "/deals/" },
  { category: "promo_shopping", path: "/coupons/" },
  { category: "promo_shopping", path: "/shopping/" },
  { category: "promo_shopping", path: "/commerce/" },
  { category: "promo_shopping", path: "/affiliate/" },
  { category: "promo_shopping", path: "/promotions/" },
  { category: "betting_gambling", path: "/betting/" },
  { category: "betting_gambling", path: "/odds/" },
  { category: "betting_gambling", path: "/gambling/" },
  { category: "horoscope_astrology", path: "/horoscope/" },
  { category: "horoscope_astrology", path: "/astrology/" },
];

// The first junk rule an article hits, or null if it's clean. Order:
// phrases → guarded "buy now" → prediction-with-odds → listicles → URL paths.
function junkMatch(title: string, url: string): { category: string; rule: string } | null {
  const titleLc = title.toLowerCase();

  // URL path, lowercased; the normalised form turns slug separators into
  // spaces so phrase lists can match "/black-friday-deals" as "black friday".
  let path = "";
  try {
    path = new URL(url).pathname.toLowerCase();
  } catch {
    path = url.toLowerCase();
  }
  const urlNorm = path.replace(/[-_/.]+/g, " ");
  const haystack = `${titleLc} ${urlNorm}`;

  // 1. Phrase rules — title + normalised URL path.
  for (const { category, phrases } of JUNK_PHRASE_RULES) {
    for (const phrase of phrases) {
      if (haystack.includes(phrase)) return { category, rule: phrase };
    }
  }

  // 2. "buy now" is a shopping CTA, but "buy now, pay later" (BNPL) is a
  //    mainstream consumer-finance news topic — only the bare CTA is promo.
  if (
    haystack.includes("buy now") &&
    !haystack.includes("buy now, pay later") &&
    !haystack.includes("buy now pay later")
  ) {
    return { category: "promo_shopping", rule: "buy now" };
  }

  // 3. "prediction" only counts as betting junk with odds/betting context —
  //    bare "prediction" is legit ("election prediction", "weather forecast").
  if (
    titleLc.includes("prediction") &&
    /\b(odds|betting|parlay|sportsbook|moneyline|point spread)\b/.test(titleLc)
  ) {
    return { category: "betting_gambling", rule: "prediction+odds" };
  }

  // 4. Listicle / clickbait patterns — title only.
  for (const pattern of JUNK_LISTICLE_PATTERNS) {
    if (pattern.test(title)) return { category: "listicles", rule: pattern.source };
  }

  // 5. URL path segments — raw path only.
  for (const { category, path: seg } of JUNK_URL_PATH_RULES) {
    if (path.includes(seg)) return { category, rule: `path:${seg}` };
  }

  return null;
}

// Accumulates the per-run drop breakdown that the handler logs and returns.
interface JunkSummary {
  total: number;
  byCategory: Record<string, number>;
  samplesByCategory: Record<string, string[]>;
}

// Drops junk rows, mutating `summary` with the breakdown and logging every
// drop (matched rule, title, source) for over-filter spotting.
function filterJunk(rows: ArticleRow[], summary: JunkSummary): ArticleRow[] {
  const kept: ArticleRow[] = [];
  for (const row of rows) {
    const match = junkMatch(row.title, row.original_url);
    if (!match) {
      kept.push(row);
      continue;
    }
    summary.total++;
    summary.byCategory[match.category] = (summary.byCategory[match.category] ?? 0) + 1;
    const samples = (summary.samplesByCategory[match.category] ??= []);
    if (samples.length < 5) samples.push(`${row.title} — ${row.source_name}`);
    console.log(
      `[ingest-news] junk drop rule=${match.category}:${match.rule}` +
        ` source=${row.source_name} title=${JSON.stringify(row.title)}`,
    );
  }
  return kept;
}

// -- Guardian (full-text licensed; dev tier allows 5,000 calls/day) ----------

const GUARDIAN_SECTIONS: Record<string, string> = {
  technology: "tech",
  world: "world",
  business: "business",
  sport: "sports",
  science: "science",
  culture: "entertainment",
  film: "entertainment",
  music: "entertainment",
  "tv-and-radio": "entertainment",
  books: "entertainment",
  games: "entertainment",
};

async function fetchGuardian(apiKey: string): Promise<ArticleRow[]> {
  const params = new URLSearchParams({
    "api-key": apiKey,
    section: Object.keys(GUARDIAN_SECTIONS).join("|"),
    // No body field: ingestion stores metadata only.
    "show-fields": "trailText,byline,thumbnail,wordcount",
    // Keyword tags feed Phase 13 tracker matching (same-story signal).
    "show-tags": "keyword",
    "page-size": "30",
    "order-by": "newest",
  });
  const res = await fetch(`https://content.guardianapis.com/search?${params}`);
  if (!res.ok) throw new Error(`Guardian HTTP ${res.status}`);
  const response = (await res.json()).response;
  if (response?.status !== "ok") {
    throw new Error(`Guardian status ${response?.status}`);
  }

  const rows: ArticleRow[] = [];
  for (const item of response.results ?? []) {
    const category = GUARDIAN_SECTIONS[item.sectionId];
    if (!category) continue;
    // Real articles only. The client used to skip items whose body parsed to
    // no paragraphs; without fetching bodies, the type field is the
    // equivalent filter for liveblogs/galleries/video pages.
    if (item.type !== "article") continue;

    const fields = item.fields ?? {};
    const wordcount = parseInt(`${fields.wordcount ?? ""}`, 10) || 0;
    const byline = (fields.byline ?? "").trim();
    const tags: string[] = (item.tags ?? [])
      .map((t: { id?: string }) => t.id ?? "")
      .filter((id: string) => id.length > 0);
    rows.push({
      id: `guardian:${item.id}`,
      source: "guardian",
      source_name: "The Guardian",
      category,
      title: item.webTitle ?? "",
      snippet: plainText(fields.trailText ?? ""),
      image_url: fields.thumbnail ?? "",
      original_url: item.webUrl ?? "",
      author: byline || "The Guardian",
      read_minutes: Math.min(30, Math.max(1, Math.ceil(wordcount / 220))),
      source_icon_url: "",
      full_text_available: true,
      published_at: item.webPublicationDate ?? null,
      tags,
    });
  }
  return rows;
}

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

// -- Cross-outlet dedup (Guardian preferred: it carries full text) ----------

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

function dedupe(preferred: ArticleRow[], secondary: ArticleRow[]): ArticleRow[] {
  const kept: ArticleRow[] = [];
  const seen = preferred.map((r) => titleTokens(r.title));
  for (const candidate of secondary) {
    const tokens = titleTokens(candidate.title);
    if (seen.some((s) => jaccard(s, tokens) >= 0.5)) continue;
    kept.push(candidate);
    seen.push(tokens);
  }
  return kept;
}

// -- Handler -----------------------------------------------------------------

Deno.serve(async (req) => {
  const secret = Deno.env.get("INGEST_SECRET");
  if (secret && req.headers.get("x-ingest-secret") !== secret) {
    return new Response("forbidden", { status: 403 });
  }

  const guardianKey = Deno.env.get("GUARDIAN_API_KEY");
  const newsdataKey = Deno.env.get("NEWSDATA_API_KEY");

  const emptyRun: NewsdataRun = {
    rows: [],
    creditsUsed: 0,
    groupsFetched: [],
    groupErrors: [],
    offAllowlistDropped: [],
  };

  // Each source is guarded independently: one outlet failing (or its key
  // missing) never blocks the other.
  const [guardianResult, newsdataResult] = await Promise.allSettled([
    SOURCE_ENABLED.guardian && guardianKey
      ? fetchGuardian(guardianKey)
      : Promise.resolve([]),
    // Gated by SOURCE_ENABLED.newsdata (disabled for the dev phase). The key
    // check stays so a missing NEWSDATA_API_KEY is still a no-op, not a throw.
    SOURCE_ENABLED.newsdata && newsdataKey
      ? fetchNewsdata(newsdataKey)
      : Promise.resolve(emptyRun),
  ]);
  const guardian =
    guardianResult.status === "fulfilled" ? guardianResult.value : [];
  const newsdataRun =
    newsdataResult.status === "fulfilled" ? newsdataResult.value : emptyRun;
  const errors = [guardianResult, newsdataResult]
    .filter((r) => r.status === "rejected")
    .map((r) => `${(r as PromiseRejectedResult).reason}`);
  errors.push(...newsdataRun.groupErrors);

  // Per-source article counts for this run's NewsData window — makes the
  // function logs answer "which allowlisted sources actually return stories".
  const sourceCounts: Record<string, number> = {};
  for (const row of newsdataRun.rows) {
    const domain = domainOf(row.original_url);
    sourceCounts[domain] = (sourceCounts[domain] ?? 0) + 1;
  }
  console.log(
    `[ingest-news] newsdata credits=${newsdataRun.creditsUsed}` +
      ` groups=${JSON.stringify(newsdataRun.groupsFetched)}` +
      ` sources=${JSON.stringify(sourceCounts)}` +
      ` offAllowlistDropped=${JSON.stringify(newsdataRun.offAllowlistDropped)}` +
      (newsdataRun.groupErrors.length
        ? ` groupErrors=${JSON.stringify(newsdataRun.groupErrors)}`
        : ""),
  );

  // Junk / low-quality filter — applied to BOTH sources before dedup, upsert
  // and embedding, so junk never reaches storage or spends an embed call.
  const junk: JunkSummary = { total: 0, byCategory: {}, samplesByCategory: {} };
  const guardianClean = filterJunk(guardian, junk);
  const newsdataClean = filterJunk(newsdataRun.rows, junk);
  console.log(
    `[ingest-news] junk dropped=${junk.total}` +
      ` byCategory=${JSON.stringify(junk.byCategory)}` +
      ` samples=${JSON.stringify(junk.samplesByCategory)}`,
  );

  const rows = [...guardianClean, ...dedupe(guardianClean, newsdataClean)];
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
    guardian: guardianClean.length,
    newsdata: rows.length - guardianClean.length,
    upserted,
    errors,
    junk_dropped: junk.total,
    junk_by_category: junk.byCategory,
    junk_samples: junk.samplesByCategory,
    newsdata_credits: newsdataRun.creditsUsed,
    newsdata_groups: newsdataRun.groupsFetched,
    newsdata_sources: sourceCounts,
    off_allowlist_dropped: newsdataRun.offAllowlistDropped,
  });
});
