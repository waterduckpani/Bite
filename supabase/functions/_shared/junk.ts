// Bite · Phase 9 junk / low-quality filter — SHARED.
//
// Moved here verbatim from ingest-news/index.ts in Phase 14 so that Guardian
// ingestion and RSS ingestion apply the SAME filter rather than two copies
// that drift. This is a pure code move: the rules, their order, the matching
// behaviour and the log format are all byte-for-byte what Phase 9 shipped.
// ingest-news must be redeployed alongside ingest-rss, but its behaviour is
// unchanged.
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

/// The first junk rule an article hits, or null if it's clean. Order:
/// phrases → guarded "buy now" → prediction-with-odds → listicles → URL paths.
export function junkMatch(
  title: string,
  url: string,
): { category: string; rule: string } | null {
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

/// Accumulates the per-run drop breakdown that a handler logs and returns.
export interface JunkSummary {
  total: number;
  byCategory: Record<string, number>;
  samplesByCategory: Record<string, string[]>;
}

export function emptyJunkSummary(): JunkSummary {
  return { total: 0, byCategory: {}, samplesByCategory: {} };
}

/// The minimum an article row needs to be junk-checked.
export interface JunkCheckable {
  title: string;
  original_url: string;
  source_name: string;
}

/// Drops junk rows, mutating `summary` with the breakdown and logging every
/// drop (matched rule, title, source) for over-filter spotting. [tag] names
/// the calling function in the log line.
export function filterJunk<T extends JunkCheckable>(
  rows: T[],
  summary: JunkSummary,
  tag = "ingest-news",
): T[] {
  const kept: T[] = [];
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
      `[${tag}] junk drop rule=${match.category}:${match.rule}` +
        ` source=${row.source_name} title=${JSON.stringify(row.title)}`,
    );
  }
  return kept;
}
