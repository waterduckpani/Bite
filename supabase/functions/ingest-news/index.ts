// Bite · Phase 8: server-side news ingestion.
//
// Replaces the client-side feed fetch: pulls Guardian + NewsData on a pg_cron
// schedule and upserts article METADATA into public.articles. Clients read
// the ranked deck via get_personalized_feed and never call the news APIs for
// the feed, so NewsData credit usage is a function of cron frequency, not
// user count. (The reader's on-demand Guardian body fetch goes through the
// guardian-body function, so no news-API key ships in the client at all.)
//
// The quality pipeline is a faithful port of the retired client code
// (content_service.dart + newsdata_api.dart + source_quality.dart):
//   - Guardian: configured sections only, real articles only (no liveblogs
//     or galleries).
//   - NewsData: prioritydomain=top + excludedomain on the request (degrading
//     gracefully if the plan rejects those params), then datatype=news,
//     allow/blocklist and category mapping on the response.
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

// -- Source quality (mirror of the retired lib/data/source_quality.dart) ----
// This is now the one place to edit when tuning NewsData feed quality.

const TRUSTED_DOMAINS = new Set([
  // Wires & broadcasters
  "apnews.com", "reuters.com", "bbc.com", "bbc.co.uk", "npr.org",
  "aljazeera.com", "cnn.com", "nbcnews.com", "cbsnews.com",
  "abcnews.go.com", "theguardian.com",
  // Papers & magazines
  "nytimes.com", "washingtonpost.com", "wsj.com", "latimes.com",
  "usatoday.com", "independent.co.uk", "telegraph.co.uk", "time.com",
  "theatlantic.com", "economist.com", "newyorker.com",
  // Business
  "bloomberg.com", "cnbc.com", "ft.com", "axios.com", "politico.com",
  "fortune.com", "businessinsider.com",
  // Tech
  "theverge.com", "arstechnica.com", "wired.com", "techcrunch.com",
  "engadget.com", "zdnet.com", "macrumors.com", "9to5mac.com",
  // Sport
  "espn.com", "skysports.com", "theathletic.com", "bleacherreport.com",
  // Science
  "nature.com", "scientificamerican.com", "newscientist.com",
  "sciencedaily.com", "space.com", "nationalgeographic.com",
  "phys.org", "livescience.com",
  // Culture
  "variety.com", "hollywoodreporter.com", "rollingstone.com",
  "billboard.com", "deadline.com", "pitchfork.com",
]);

// Junk that must never reach the feed: press-release wires, scraper
// aggregators and SEO content farms.
const BLOCKED_DOMAINS = new Set([
  "prnewswire.com", "businesswire.com", "globenewswire.com",
  "einpresswire.com", "einnews.com", "openpr.com", "newswire.com",
  "accesswire.com", "issuewire.com", "prlog.org",
  "menafn.com", "biztoc.com", "headtopics.com", "wn.com",
  "newsbreak.com", "knewz.com", "onenewspage.com", "devdiscourse.com",
  "bignewsnetwork.com", "streetinsider.com",
]);

// The five worst offenders, passed as `excludedomain` on every NewsData
// request so their stories never spend result slots.
const EXCLUDE_ON_REQUEST = [
  "menafn.com", "prnewswire.com", "globenewswire.com",
  "businesswire.com", "einpresswire.com",
];

function domainOf(url: string): string {
  let host = "";
  try {
    host = new URL(url).host;
  } catch {
    return "";
  }
  return host.startsWith("www.") ? host.slice(4) : host;
}

function matches(domains: Set<string>, domain: string): boolean {
  if (domains.has(domain)) return true;
  for (const d of domains) if (domain.endsWith(`.${d}`)) return true;
  return false;
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
    });
  }
  return rows;
}

// -- NewsData (headlines-only license; free tier: 200 credits/day) ----------

const NEWSDATA_CATEGORIES: Record<string, string> = {
  technology: "tech",
  world: "world",
  business: "business",
  sports: "sports",
  science: "science",
  entertainment: "entertainment",
};
// The API accepts at most five category filters per request; entertainment
// coverage comes from the Guardian's culture sections instead.
const NEWSDATA_REQUESTED = "technology,business,science,sports,world";

// Pages fetched per run (10 stories each, 1 credit each). At 3 pages the
// daily credit spend is 3 × runs/day — see the cron comment in migration
// 0003 before changing either knob.
const NEWSDATA_PAGES = 3;

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

async function newsdataPage(
  apiKey: string,
  page: string | null,
  withQualityParams: boolean,
): Promise<Record<string, unknown>> {
  const params = new URLSearchParams({
    apikey: apiKey,
    language: "en",
    category: NEWSDATA_REQUESTED,
    removeduplicate: "1",
  });
  if (withQualityParams) {
    params.set("prioritydomain", "top");
    params.set("excludedomain", EXCLUDE_ON_REQUEST.join(","));
  }
  if (page) params.set("page", page);
  const res = await fetch(`https://newsdata.io/api/1/latest?${params}`);
  if (!res.ok) throw new Error(`NewsData HTTP ${res.status}`);
  const json = await res.json();
  if (json.status !== "success") {
    throw new Error(`NewsData status ${json.status}`);
  }
  return json;
}

async function fetchNewsdata(apiKey: string): Promise<ArticleRow[]> {
  const rows: ArticleRow[] = [];
  let page: string | null = null;
  // Plan may not accept prioritydomain/excludedomain; degrade to response
  // filtering only after one rejected request instead of losing the source.
  let qualityParamsOk = true;

  for (let i = 0; i < NEWSDATA_PAGES; i++) {
    let json: Record<string, unknown>;
    try {
      json = await newsdataPage(apiKey, page, qualityParamsOk);
    } catch (e) {
      if (!qualityParamsOk) throw e;
      qualityParamsOk = false;
      json = await newsdataPage(apiKey, page, false);
    }

    for (const item of (json.results as Record<string, unknown>[]) ?? []) {
      if (item.duplicate === true) continue;
      // Real reporting only — no blogs, press releases, or forum posts.
      if (item.datatype != null && item.datatype !== "news") continue;

      const title = ((item.title as string) ?? "").trim();
      const url = (item.link as string) ?? "";
      if (!title || !url) continue;

      const domain = domainOf((item.source_url as string) || url);
      if (matches(BLOCKED_DOMAINS, domain)) continue;

      const category = ((item.category as string[]) ?? [])
        .map((c) => NEWSDATA_CATEGORIES[c])
        .find((c) => c != null);
      if (!category) continue;

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
        image_url: validImageUrl(item.image_url),
        original_url: url,
        author: creators[0] ?? (source || "News"),
        read_minutes: 2,
        source_icon_url: (item.source_icon as string) ?? "",
        full_text_available: false, // headline-only license
        published_at: publishedAt,
      });
    }
    page = (json.nextPage as string) ?? null;
    if (!page) break;
  }
  return rows;
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

  // Each source is guarded independently: one outlet failing (or its key
  // missing) never blocks the other.
  const [guardianResult, newsdataResult] = await Promise.allSettled([
    guardianKey ? fetchGuardian(guardianKey) : Promise.resolve([]),
    newsdataKey ? fetchNewsdata(newsdataKey) : Promise.resolve([]),
  ]);
  const guardian =
    guardianResult.status === "fulfilled" ? guardianResult.value : [];
  const newsdata =
    newsdataResult.status === "fulfilled" ? newsdataResult.value : [];
  const errors = [guardianResult, newsdataResult]
    .filter((r) => r.status === "rejected")
    .map((r) => `${(r as PromiseRejectedResult).reason}`);

  const rows = [...guardian, ...dedupe(guardian, newsdata)];
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
    guardian: guardian.length,
    newsdata: rows.length - guardian.length,
    upserted,
    errors,
  });
});
