// Bite · Phase 18: article category classification.
//
// Lifted out of ingest-rss so there is exactly one implementation and the
// before/after harness (tools/category_harness.mjs) can import the REAL code
// rather than a transcription of it. The previous classifier lived inline and
// was audited at roughly 50% noise; the harness exists so that number is
// something we measure rather than assert.
//
// WHAT THE OLD ONE GOT WRONG, AND WHAT REPLACES IT
//
//   1. It never saw the FEED url. ingest-rss pulls BBC items from
//      feeds.bbci.co.uk/news/technology/rss.xml and then classified them from
//      the article url, which is /news/articles/c23579jzv08o — no section, so
//      every BBC tech and business story became `world`. The section feeds in
//      migrations 0018 and 0023 were built precisely to fill those gaps and
//      the classifier was throwing the answer away. Feed section is now
//      checked FIRST and is decisive.
//
//   2. `news` was a `world` keyword, so the ubiquitous <category>News</category>
//      and every /news/ path scored world — 276 of 923 world rows in the audit.
//      `world` is now reachable only through real geography.
//
//   3. Matching was substring, not token: "transportation".includes("sport")
//      tagged a Tesla story `sports`, ESPN trade stories became `business`,
//      and "the-global-memory-shortage" became `world`. Matching is now on
//      whole tokens, with an explicit phrase list for the multi-word terms
//      that tokenising would otherwise break.
//
//   4. It returned on the FIRST category that hit, evaluating one haystack at
//      a time, so the publisher's own tag ORDER silently decided the answer:
//      ["Gaming", "Microsoft", "News"] resolved to world. All evidence is now
//      scored together and the best total wins.
//
//   5. `world` was both a real category and the null value. 431 rows — 47% of
//      all world rows — reached it by matching nothing whatsoever. A row that
//      matches nothing now falls to the PUBLISHER's declared default_category
//      (migration 0024), which for a pure-beat wire is its beat and for a
//      general daily is an explicit editorial 'world', not a silent one.
//
// The ranker is deliberately untouched. get_personalized_feed already fights
// a lopsided pool (the dom_rank topic penalty and the cat_fresh explore slice
// both favour thin categories); it was never the cause and needs no change.

import type { RssItem } from "./rss.ts";

export type AppCategory =
  | "tech" | "world" | "business" | "sports" | "science" | "entertainment";

/// Priority order, used ONLY to break score ties. `world` is last on purpose:
/// when the evidence is genuinely balanced between world and a specific beat,
/// the specific beat is the more informative label.
export const CATEGORY_PRIORITY: AppCategory[] = [
  "tech", "business", "sports", "science", "entertainment", "world",
];

// -- Signal weights ---------------------------------------------------------
// The three evidence sources are not equally trustworthy, and the audit is
// what set the ordering.

/// A publisher's own <category> tags. Curated by a human at the publisher, so
/// one tag alone is enough to decide.
const W_TAG = 2;

/// A site SECTION segment of the article url (/mlb/story/…, /technology/2026/…).
/// Structural and reliable. See sectionAndSlug for what counts as one.
const W_PATH_SECTION = 3;

/// Everything deeper in the path: the headline slug. This is where every
/// substring false positive in the audit came from ("…-global-memory-…",
/// "…-gausman-trade"), so a slug word is evidence but never enough on its own.
const W_PATH_SLUG = 1;

/// Minimum total score to accept a match. Set to W_TAG so that exactly one
/// curated tag, or one section segment, or two corroborating slug words will
/// classify — but a LONE slug word (weight 1) never will. That single
/// threshold is what retires the whole class of false positives found in the
/// audit, without needing a blocklist of unlucky words.
const MIN_SCORE = 2;

// -- Feed section -> category ----------------------------------------------
// Matched against the segments of the FEED url, not the article url. These are
// sections the publisher deliberately splits its own feed by, so when one is
// present it is the most authoritative signal available and short-circuits
// everything below.
//
// `world` is included alongside the five beats: the Guardian's /world/rss is
// an explicit editorial section in exactly the way that a /news/ path is not.
const FEED_SECTIONS: { segment: string; category: AppCategory }[] = [
  { segment: "technology", category: "tech" },
  { segment: "tech", category: "tech" },
  { segment: "business", category: "business" },
  { segment: "economy", category: "business" },
  { segment: "sport", category: "sports" },
  { segment: "sports", category: "sports" },
  { segment: "science", category: "science" },
  { segment: "environment", category: "science" },
  { segment: "health", category: "science" },
  { segment: "culture", category: "entertainment" },
  { segment: "entertainment", category: "entertainment" },
  { segment: "arts", category: "entertainment" },
  { segment: "world", category: "world" },
];

// -- Vocabulary -------------------------------------------------------------
// Single tokens are matched whole-word. Phrases are matched against the
// token-joined string, so "artificial intelligence" works while "art" does not
// leak into it.
//
// `world` carries GEOGRAPHY ONLY. Not "news", not "politics", not "national" —
// those were catch-alls that made world the default by accident. A political
// story from a general daily now reaches world through that publisher's
// default_category, which is a decision someone made, rather than through a
// keyword that happens to match everything.

interface Vocab {
  category: AppCategory;
  tokens: string[];
  phrases: string[];
}

const VOCAB: Vocab[] = [
  {
    category: "tech",
    tokens: [
      "tech", "technology", "gadget", "gadgets", "computing", "computer",
      "computers", "internet", "cyber", "cybersecurity", "software",
      "hardware", "ai", "robotics", "robot", "startup", "startups", "app",
      "apps", "semiconductor", "semiconductors", "chip", "chips", "crypto",
      "cryptocurrency", "smartphone", "smartphones", "silicon", "gizmo",
      "innovation", "telecom", "telecoms",
      // WIRED files all consumer hardware under "Gear", which is the section
      // name for what every other publisher calls tech. Without it a headset
      // review scored only on its "Gaming" tag and landed in entertainment.
      "gear",
    ],
    phrases: [
      "artificial intelligence", "machine learning", "science and tech",
      "consumer tech", "information technology", "social media",
    ],
  },
  {
    category: "business",
    tokens: [
      "business", "economy", "economic", "economics", "market", "markets",
      "finance", "financial", "money", "trade", "trading", "companies",
      "company", "industry", "industries", "banking", "bank", "banks",
      "stocks", "shares", "investing", "investment", "investors", "earnings",
      "retail", "ipo", "inflation", "tariff", "tariffs", "commerce",
    ],
    phrases: ["stock market", "personal finance", "real estate"],
  },
  {
    category: "sports",
    tokens: [
      "sport", "sports", "cricket", "football", "soccer", "tennis", "olympic",
      "olympics", "hockey", "athletics", "basketball", "baseball", "golf",
      "rugby", "boxing", "cycling", "wrestling", "badminton", "kabaddi",
      "nfl", "nba", "mlb", "nhl", "ncaa", "ipl", "fifa", "uefa", "motorsport",
      "f1", "formula1", "swimming", "marathon", "wimbledon",
    ],
    phrases: ["formula 1", "premier league", "champions league"],
  },
  {
    category: "science",
    tokens: [
      "science", "sciences", "scientific", "scientists", "environment",
      "environmental", "climate", "health", "space", "research", "nature",
      "medicine", "medical", "biology", "physics", "chemistry", "astronomy",
      "wildlife", "earth", "animals", "neuroscience", "genetics", "ecology",
      "conservation", "archaeology", "psychology", "nasa", "disease",
    ],
    phrases: [
      "health and medicine", "science and environment", "climate change",
      "public health", "space exploration",
    ],
  },
  {
    category: "entertainment",
    tokens: [
      "entertainment", "culture", "film", "films", "movie", "movies", "music",
      "arts", "art", "books", "book", "television", "tv", "celebrity",
      "celebrities", "bollywood", "hollywood", "gaming", "games",
      "game", "theatre", "theater", "fashion", "streaming", "showbiz",
      "cinema", "comedy", "festival",
      // "lifestyle" is deliberately ABSENT. It is a section name that spans
      // food, travel, home, wellness and shopping, and it put WIRED's office
      // chair roundup in entertainment. An ambiguous tag is worse than no tag:
      // no tag falls to the publisher's declared beat, which is at least a
      // decision someone made.
    ],
    phrases: ["video games", "box office", "red carpet"],
  },
  {
    category: "world",
    tokens: [
      "world", "international", "global", "asia", "africa", "europe",
      "americas", "geopolitics", "diplomacy", "foreign",
    ],
    phrases: ["middle east", "latin america", "foreign policy", "world news"],
  },
];

// -- Tokenising -------------------------------------------------------------

/// Lowercased alphanumeric tokens. Used for both the token set and the
/// space-joined string that phrases are matched against, so the two can never
/// disagree about where a word boundary is.
function tokenize(text: string): string[] {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim()
    .split(/\s+/)
    .filter((t) => t.length > 0);
}

/// Adds the score for every vocabulary hit in [text] into [scores].
function scoreText(
  text: string,
  weight: number,
  scores: Map<AppCategory, number>,
  hits: string[],
): void {
  const tokens = tokenize(text);
  if (tokens.length === 0) return;
  const tokenSet = new Set(tokens);
  const joined = ` ${tokens.join(" ")} `;

  for (const { category, tokens: words, phrases } of VOCAB) {
    let matched = 0;
    for (const word of words) {
      if (tokenSet.has(word)) {
        matched += weight;
        hits.push(`${category}+${weight}:${word}`);
      }
    }
    for (const phrase of phrases) {
      if (joined.includes(` ${phrase} `)) {
        matched += weight;
        hits.push(`${category}+${weight}:"${phrase}"`);
      }
    }
    if (matched > 0) {
      scores.set(category, (scores.get(category) ?? 0) + matched);
    }
  }
}

/// Splits an article path into its SECTION words and its SLUG words.
///
/// Position alone is not enough to tell them apart. Science News files at
/// /article/<headline-slug>, so segment 1 is the slug — and weighting it as a
/// section is what made "mammals-moving-americas-stopped-mexico" score
/// world+3 and beat its own `Earth` tag. Real section segments are short
/// ("mlb", "tech", "college-football", "australia-news"); headline slugs are
/// long. So a segment is a section only if it is in the first two positions
/// AND tokenises to at most two words.
function sectionAndSlug(articleUrl: string): { section: string; slug: string } {
  let segments: string[];
  try {
    segments = new URL(articleUrl).pathname.split("/").filter((s) => s.length > 0);
  } catch {
    return { section: "", slug: "" };
  }
  const section: string[] = [];
  const slug: string[] = [];
  segments.forEach((segment, index) => {
    const isSection = index < 2 && tokenize(segment).length <= 2;
    (isSection ? section : slug).push(segment);
  });
  return { section: section.join(" "), slug: slug.join(" ") };
}

/// The section a FEED url declares, if any.
export function feedSection(feedUrl: string): AppCategory | null {
  let segments: string[];
  try {
    segments = new URL(feedUrl).pathname.toLowerCase().split("/")
      .filter((s) => s.length > 0);
  } catch {
    return null;
  }
  for (const segment of segments) {
    // Split so "australia-news" or "rss-en-all" are examined by word rather
    // than needing an exact segment match.
    const parts = tokenize(segment);
    for (const { segment: name, category } of FEED_SECTIONS) {
      if (parts.includes(name)) return category;
    }
  }
  return null;
}

// -- Result -----------------------------------------------------------------

export interface CategoryResult {
  category: AppCategory;
  /// How the decision was reached. Logged by ingest-rss so a wrong label is
  /// traceable to the rule that produced it rather than being a mystery in the
  /// deck — the same discipline the opinion filter already follows.
  via: "feed_section" | "signals" | "publisher_default";
  detail: string;
}

/// Classify one feed item.
///
/// [feedUrl] is the feed the item came from, [articleUrl] the canonical
/// article url, and [publisherDefault] the registry's default_category for the
/// publisher — the answer when nothing else is confident. Passing a null
/// default falls back to `world`, which is only reachable for rows whose
/// publisher predates migration 0024.
export function categorize(
  item: RssItem,
  articleUrl: string,
  feedUrl: string,
  publisherDefault: AppCategory | null,
): CategoryResult {
  // 1. The feed's own section. Decisive: the publisher split this feed out.
  const section = feedSection(feedUrl);
  if (section) {
    return { category: section, via: "feed_section", detail: feedUrl };
  }

  // 2. Everything else, scored together rather than first-hit.
  const scores = new Map<AppCategory, number>();
  const hits: string[] = [];

  for (const tag of item.categories) scoreText(tag, W_TAG, scores, hits);

  const { section: pathSection, slug: pathSlug } = sectionAndSlug(articleUrl);
  scoreText(pathSection, W_PATH_SECTION, scores, hits);
  scoreText(pathSlug, W_PATH_SLUG, scores, hits);

  let best: AppCategory | null = null;
  let bestScore = 0;
  for (const category of CATEGORY_PRIORITY) {
    const score = scores.get(category) ?? 0;
    // Strictly greater, walking CATEGORY_PRIORITY in order, so a tie resolves
    // to the higher-priority category and `world` only wins a tie outright
    // when nothing else scored at all.
    if (score > bestScore) {
      best = category;
      bestScore = score;
    }
  }

  if (best !== null && bestScore >= MIN_SCORE) {
    return {
      category: best,
      via: "signals",
      detail: `${bestScore} [${hits.join(" ")}]`,
    };
  }

  // 3. No confident signal. This is the case the old classifier disguised as
  //    `world`; it is now the publisher's declared beat.
  return {
    category: publisherDefault ?? "world",
    via: "publisher_default",
    detail: publisherDefault === null
      ? "no default_category on publisher row"
      : `below MIN_SCORE=${MIN_SCORE} (best=${bestScore})`,
  };
}
