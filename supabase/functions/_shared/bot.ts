// Bite · Phase 14: bot identity, robots.txt, and the no-circumvention rules.
//
// THE ONE PLACE any outbound publisher request is made. Everything Phase 14
// fetches from a publisher goes through botFetch() so the hard constraints
// are enforced structurally rather than by remembering to follow them:
//
//   1. ONE fixed, honest User-Agent. Never a browser string, never rotated,
//      never varied per request or per retry. USER_AGENT is a const and
//      botFetch does not accept a header override.
//   2. robots.txt is parsed and honoured per domain, including Crawl-delay,
//      before any fetch. A disallowed article path means that publisher is
//      RSS-description-only. There is no override flag.
//   3. No circumvention of any technical protection. detectWall() classifies
//      paywalls, consent walls and bot challenges; the caller's only correct
//      response is to abort and fall back to the RSS description. Nothing is
//      ever retried with different headers.
//
// The +url in the User-Agent must be a real, reachable page describing the
// bot and carrying a contact address for removal requests (docs/bot/).

// ---------------------------------------------------------------------------
// Identity
// ---------------------------------------------------------------------------

export const BOT_URL = "https://waterduckpani.github.io/Bite/bot";
export const BOT_NAME = "BiteNewsBot";
export const USER_AGENT = `${BOT_NAME}/1.0 (+${BOT_URL})`;

/// Politeness floor between requests to the same host. A publisher's own
/// Crawl-delay wins whenever it is longer.
export const MIN_CRAWL_DELAY_MS = 1000;

/// How long a parsed robots.txt stays good before it is refetched.
export const ROBOTS_CACHE_HOURS = 24;

const FETCH_TIMEOUT_MS = 20_000;

// ---------------------------------------------------------------------------
// Fetching
// ---------------------------------------------------------------------------

export interface FetchResult {
  status: number;
  body: string;
  ok: boolean;
  error?: string;
}

/// The ONLY outbound fetch in Phase 14.
///
/// Deliberately takes no header/UA parameter: there is no way to call this
/// with a different identity, which is what makes "no rotating user agents,
/// no browser impersonation" a property of the code rather than a promise.
export async function botFetch(url: string): Promise<FetchResult> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
  try {
    const res = await fetch(url, {
      redirect: "follow",
      signal: controller.signal,
      headers: {
        "User-Agent": USER_AGENT,
        "Accept":
          "application/rss+xml, application/atom+xml, application/xml, text/xml, text/html;q=0.8",
        "Accept-Language": "en",
        "From": BOT_URL,
      },
    });
    const body = await res.text();
    return { status: res.status, body, ok: res.ok };
  } catch (e) {
    return { status: 0, body: "", ok: false, error: `${e}` };
  } finally {
    clearTimeout(timer);
  }
}

/// Per-host politeness. Ensures at least [delayMs] between two requests to the
/// same host across the whole run, not merely between consecutive awaits.
const lastHit = new Map<string, number>();

export async function politeWait(host: string, delayMs: number): Promise<void> {
  const wait = Math.max(MIN_CRAWL_DELAY_MS, delayMs);
  const last = lastHit.get(host) ?? 0;
  const due = last + wait - Date.now();
  if (due > 0) await new Promise((r) => setTimeout(r, due));
  lastHit.set(host, Date.now());
}

// ---------------------------------------------------------------------------
// robots.txt
// ---------------------------------------------------------------------------

export interface RobotsRule {
  allow: boolean;
  pattern: string;
}

export interface Robots {
  /// False when robots.txt could not be read at all.
  fetched: boolean;
  status: number;
  rules: RobotsRule[];
  crawlDelaySeconds: number | null;
  /// Which User-agent group the rules came from: our own name, "*", or "none".
  groupUsed: string;
}

/// Google / RFC 9309 path matching: `*` matches any run of characters, a
/// trailing `$` anchors the end, everything else is a literal prefix.
export function robotsPathMatches(pattern: string, path: string): boolean {
  const anchored = pattern.endsWith("$");
  const body = anchored ? pattern.slice(0, -1) : pattern;
  const parts = body.split("*");
  let index = 0;
  for (let i = 0; i < parts.length; i++) {
    const part = parts[i];
    if (part.length === 0) continue;
    if (i === 0) {
      if (!path.startsWith(part)) return false;
      index = part.length;
    } else {
      const found = path.indexOf(part, index);
      if (found < 0) return false;
      index = found + part.length;
    }
  }
  if (anchored && !body.endsWith("*")) return index === path.length;
  return true;
}

/// Longest matching rule wins; a tie resolves to allow; no matching rule means
/// allowed. A robots.txt we could not read because the server errored is
/// treated as DISALLOW — we do not fetch against rules we never saw.
export function robotsAllows(robots: Robots, path: string): boolean {
  if (!robots.fetched && robots.status >= 500) return false;
  let best: RobotsRule | null = null;
  let bestScore = -1;
  for (const rule of robots.rules) {
    if (!robotsPathMatches(rule.pattern, path)) continue;
    const score = rule.pattern.replace(/[*$]/g, "").length;
    if (score > bestScore || (score === bestScore && rule.allow)) {
      best = rule;
      bestScore = score;
    }
  }
  return best === null ? true : best.allow;
}

export function parseRobots(text: string, status: number): Robots {
  const groups = new Map<string, RobotsRule[]>();
  const delays = new Map<string, number>();
  let currentAgents: string[] = [];
  let expectingAgents = false;

  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.split("#")[0].trim();
    if (!line) continue;
    const colon = line.indexOf(":");
    if (colon < 0) continue;
    const field = line.slice(0, colon).trim().toLowerCase();
    const value = line.slice(colon + 1).trim();

    if (field === "user-agent") {
      // A consecutive run of User-agent lines opens one shared group.
      if (!expectingAgents) {
        currentAgents = [];
        expectingAgents = true;
      }
      const agent = value.toLowerCase();
      currentAgents.push(agent);
      if (!groups.has(agent)) groups.set(agent, []);
    } else if (field === "disallow" || field === "allow") {
      expectingAgents = false;
      // An empty Disallow means "allow everything" — no rule to record.
      if (!value) continue;
      for (const agent of currentAgents) {
        groups.get(agent)!.push({ allow: field === "allow", pattern: value });
      }
    } else if (field === "crawl-delay") {
      expectingAgents = false;
      const parsed = Number(value);
      if (!Number.isFinite(parsed)) continue;
      for (const agent of currentAgents) delays.set(agent, parsed);
    } else {
      expectingAgents = false;
    }
  }

  // Most specific group wins: our own name, then the wildcard.
  const botKey = BOT_NAME.toLowerCase();
  const key = groups.has(botKey) ? botKey : (groups.has("*") ? "*" : null);
  return {
    fetched: true,
    status,
    rules: key === null ? [] : groups.get(key)!,
    crawlDelaySeconds: key === null ? null : (delays.get(key) ?? null),
    groupUsed: key ?? "none",
  };
}

/// Fetches and parses `<origin>/robots.txt`. A 404 (no robots.txt) means no
/// stated restrictions; a 5xx or network failure is restrictive.
export async function fetchRobots(origin: string): Promise<Robots> {
  const res = await botFetch(`${origin}/robots.txt`);
  if (!res.ok) {
    return {
      fetched: false,
      status: res.status,
      rules: [],
      crawlDelaySeconds: null,
      groupUsed: "none",
    };
  }
  return parseRobots(res.body, res.status);
}

/// Crawl-delay in milliseconds, floored at MIN_CRAWL_DELAY_MS.
export function crawlDelayMs(seconds: number | null | undefined): number {
  const stated = Math.round((seconds ?? 0) * 1000);
  return stated > MIN_CRAWL_DELAY_MS ? stated : MIN_CRAWL_DELAY_MS;
}

// ---------------------------------------------------------------------------
// Technical-protection detection
//
// These are NOT things to work around. A hit means the page was not honestly
// served to an identified client, so we do not have it: the caller aborts,
// logs the reason, keeps full_text_available false, and falls back to the RSS
// description. There is no second attempt with different headers.
// ---------------------------------------------------------------------------

const WALL_SIGNALS: Record<string, string[]> = {
  paywall: [
    "subscribe to continue", "subscription required", "to continue reading",
    "this article is for subscribers", "premium article", "paywall",
    "already a subscriber", "unlock this article", "subscribers only",
    "register to read", "sign in to read",
  ],
  consent_wall: [
    "accept all cookies", "manage your privacy", "we value your privacy",
    "consent to the use of cookies", "privacy preference cent",
    "before you continue to",
  ],
  bot_challenge: [
    "enable javascript and cookies to continue", "checking your browser",
    "verify you are human", "cf-browser-verification", "ddos protection by",
    "attention required! | cloudflare", "just a moment...",
    "please enable cookies", "access to this page has been denied",
  ],
};

/// The wall a page is hiding behind, as "kind:signal", or null when the page
/// was served honestly.
export function detectWall(html: string): string | null {
  const lower = html.toLowerCase();
  for (const [kind, signals] of Object.entries(WALL_SIGNALS)) {
    for (const signal of signals) {
      if (lower.includes(signal)) return `${kind}:${signal}`;
    }
  }
  return null;
}

/// An HTTP status that means "not served to us". 401/402/403 are access
/// refusals and 429 is rate limiting — all are respected, never retried
/// differently.
export function statusIsRefusal(status: number): string | null {
  if (status === 401 || status === 402 || status === 403) {
    return `http_${status}_refused`;
  }
  if (status === 429) return "http_429_rate_limited";
  if (status >= 500) return `http_${status}_upstream`;
  if (status === 404 || status === 410) return `http_${status}_gone`;
  return null;
}

// ---------------------------------------------------------------------------
// URL canonicalisation + stable ids
// ---------------------------------------------------------------------------

const TRACKING_PARAMS = [
  "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
  "utm_id", "utm_name", "utm_reader", "fbclid", "gclid", "mc_cid", "mc_eid",
  "ref", "source", "at_medium", "at_campaign", "CMP", "cmp",
];

/// The canonical article URL: tracking parameters stripped, fragment dropped,
/// host lowercased. This is what is stored as source_url (attribution is
/// structural — it is NOT NULL) and what dedup keys on.
export function canonicalUrl(raw: string): string {
  try {
    const url = new URL(raw.trim());
    url.hash = "";
    for (const param of TRACKING_PARAMS) url.searchParams.delete(param);
    url.host = url.host.toLowerCase();
    // Normalise a lone trailing slash so "/a/" and "/a" dedupe together.
    if (url.pathname.length > 1 && url.pathname.endsWith("/")) {
      url.pathname = url.pathname.slice(0, -1);
    }
    return url.toString();
  } catch {
    return raw.trim();
  }
}

/// Stable article id for an RSS row: `rss:<publisher>:<sha256(canonical)[0..31]>`.
/// Derived from the canonical URL so re-ingesting the same story upserts the
/// existing row instead of duplicating it.
export async function rssArticleId(
  publisherId: string,
  canonical: string,
): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(canonical),
  );
  const hex = Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
  return `rss:${publisherId}:${hex.slice(0, 32)}`;
}
