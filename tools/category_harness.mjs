// Bite · Phase 18: before/after harness for the category classifier.
//
// Runs the OLD (pre-Phase-18) classifier and the NEW one over the SAME live
// feeds — all 26 enabled publishers — and prints both distributions side by
// side, plus a simulated fair-share run for each. The point is that "the
// classifier is ~50% noise" and "the fix works" are both measurements against
// real publisher output rather than claims.
//
// The new classifier is IMPORTED from supabase/functions/_shared/categorize.ts,
// so this harness exercises the code that actually ships. parseFeed is imported
// from _shared/rss.ts for the same reason. Node >= 22.18 strips the TypeScript
// types natively, so no build step is involved.
//
//   node tools/category_harness.mjs           # fetch live feeds
//   node tools/category_harness.mjs --cache   # reuse the last fetch
//
// It sends ONE request per feed, with the same honest User-Agent ingest-rss
// uses (_shared/bot.ts owns that identity). It never fetches an article page.

import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { parseFeed } from "../supabase/functions/_shared/rss.ts";
import { categorize } from "../supabase/functions/_shared/categorize.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const CACHE = join(HERE, ".category_harness_cache.json");
const USER_AGENT = "BiteNewsBot/1.0 (+https://waterduckpani.github.io/Bite/bot)";
const useCache = process.argv.includes("--cache");

// ---------------------------------------------------------------------------
// The OLD classifier, copied verbatim from ingest-rss/index.ts as it stood at
// commit f51f849. Kept here and ONLY here so the comparison is against what
// actually ran, not a paraphrase of it.
// ---------------------------------------------------------------------------

const OLD_CATEGORY_KEYWORDS = [
  { category: "tech", words: ["tech", "technology", "science and tech", "gadget", "computing", "artificial intelligence", "internet", "cyber", "software"] },
  { category: "business", words: ["business", "economy", "economic", "market", "finance", "financial", "money", "trade", "companies", "industry"] },
  { category: "sports", words: ["sport", "sports", "cricket", "football", "soccer", "tennis", "olympic", "hockey", "athletics"] },
  { category: "science", words: ["science", "environment", "climate", "health", "space", "research", "nature", "medicine"] },
  { category: "entertainment", words: ["entertainment", "culture", "film", "movie", "music", "arts", "books", "television", "tv", "celebrity", "bollywood", "lifestyle"] },
  { category: "world", words: ["world", "international", "global", "news", "india", "national", "politics", "asia", "africa", "europe", "americas", "middle east"] },
];

function oldCategoryFor(item, url) {
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
    for (const { category, words } of OLD_CATEGORY_KEYWORDS) {
      for (const word of words) {
        if (hay.includes(word)) return category;
      }
    }
  }
  return "world";
}

// ---------------------------------------------------------------------------
// Opinion filter, verbatim from ingest-rss, so both classifiers see exactly the
// candidate set ingestion would see.
// ---------------------------------------------------------------------------

const OPINION_URL_PATHS = ["/opinion/", "/opinions/", "/editorial/", "/editorials/", "/op-ed/", "/oped/", "/blogs/", "/blog/", "/columns/", "/column/", "/voices/", "/comment/", "/commentisfree/"];
const OPINION_CATEGORY_RE = /\b(opinion|opinions|editorial|editorials|op-?ed|column|columns|columnist|blog|blogs|voices|commentary|letters to the editor)\b/i;
const OPINION_TITLE_RE = /^\s*(opinion|comment|commentary|analysis|editorial|column|viewpoint|perspective)\s*[:–—-]/i;

function isOpinion(item, url) {
  let path = "";
  try { path = new URL(url).pathname.toLowerCase(); } catch { path = url.toLowerCase(); }
  if (OPINION_URL_PATHS.some((s) => path.includes(s))) return true;
  if (OPINION_TITLE_RE.test(item.title)) return true;
  return item.categories.some((c) => OPINION_CATEGORY_RE.test(c));
}

// ---------------------------------------------------------------------------
// The slate. Mirrors migrations 0013, 0018, 0023 and the default_category
// values seeded by 0024.
// ---------------------------------------------------------------------------

const PUBLISHERS = [
  { id: "bbc", region: "GLOBAL", maxPerRun: 6, def: "world", feeds: ["https://feeds.bbci.co.uk/news/world/rss.xml", "https://feeds.bbci.co.uk/news/business/rss.xml", "https://feeds.bbci.co.uk/sport/rss.xml", "https://feeds.bbci.co.uk/news/technology/rss.xml"] },
  { id: "npr", region: "GLOBAL", maxPerRun: 4, def: "world", feeds: ["https://feeds.npr.org/1001/rss.xml"] },
  { id: "euronews", region: "EU", maxPerRun: 3, def: "world", feeds: ["https://www.euronews.com/rss"] },
  { id: "france24", region: "EU", maxPerRun: 3, def: "world", feeds: ["https://www.france24.com/en/rss"] },
  { id: "skynews", region: "UK", maxPerRun: 4, def: "world", feeds: ["https://feeds.skynews.com/feeds/rss/home.xml"] },
  { id: "independent", region: "UK", maxPerRun: 3, def: "world", feeds: ["https://www.independent.co.uk/news/uk/rss"] },
  { id: "pbs", region: "US", maxPerRun: 4, def: "world", feeds: ["https://www.pbs.org/newshour/feeds/rss/headlines"] },
  { id: "thehill", region: "US", maxPerRun: 3, def: "world", feeds: ["https://www.thehill.com/feed"] },
  { id: "abcnewsau", region: "AU", maxPerRun: 4, def: "world", feeds: ["https://www.abc.net.au/news/feed/45910/rss.xml"] },
  { id: "theguardianau", region: "AU", maxPerRun: 3, def: "world", feeds: ["https://www.theguardian.com/australia-news/rss"] },
  { id: "techcrunch", region: "GLOBAL", maxPerRun: 4, def: "tech", feeds: ["https://techcrunch.com/feed/"] },
  { id: "wired", region: "GLOBAL", maxPerRun: 4, def: "tech", feeds: ["https://www.wired.com/feed/rss"] },
  { id: "theverge", region: "GLOBAL", maxPerRun: 4, def: "tech", feeds: ["https://www.theverge.com/rss/index.xml"] },
  { id: "sciencedaily", region: "GLOBAL", maxPerRun: 4, def: "science", feeds: ["https://www.sciencedaily.com/rss/all.xml"] },
  { id: "sciencenews", region: "GLOBAL", maxPerRun: 3, def: "science", feeds: ["https://www.sciencenews.org/feed"] },
  { id: "cnbc", region: "GLOBAL", maxPerRun: 4, def: "business", feeds: ["https://www.cnbc.com/id/100003114/device/rss/rss.html"] },
  { id: "espn", region: "GLOBAL", maxPerRun: 4, def: "sports", feeds: ["https://www.espn.com/espn/rss/news"] },
  { id: "thehindu", region: "IN", maxPerRun: 3, def: "world", feeds: ["https://www.thehindu.com/feeder/default.rss"] },
  { id: "newindianexpress", region: "IN", maxPerRun: 3, def: "world", feeds: ["https://www.newindianexpress.com/feed"] },
  { id: "deccanherald", region: "IN", maxPerRun: 5, def: "world", feeds: ["https://www.deccanherald.com/feed"] },
  { id: "scroll", region: "IN", maxPerRun: 5, def: "world", feeds: ["https://feeds.feedburner.com/ScrollinArticles.rss"] },
  { id: "aljazeera", region: "GLOBAL", maxPerRun: 4, def: "world", feeds: ["https://www.aljazeera.com/xml/rss/all.xml"] },
  { id: "dw", region: "GLOBAL", maxPerRun: 5, def: "world", feeds: ["https://rss.dw.com/rdf/rss-en-all"] },
  { id: "csmonitor", region: "GLOBAL", maxPerRun: 5, def: "world", feeds: ["https://rss.csmonitor.com/feeds/all"] },
  { id: "reason", region: "GLOBAL", maxPerRun: 5, def: "world", feeds: ["https://reason.com/feed/"] },
  { id: "theguardian", region: "GLOBAL", maxPerRun: 6, def: "world", feeds: ["https://www.theguardian.com/world/rss", "https://www.theguardian.com/business/rss", "https://www.theguardian.com/technology/rss", "https://www.theguardian.com/science/rss", "https://www.theguardian.com/sport/rss", "https://www.theguardian.com/culture/rss"] },
];

const CATS = ["world", "tech", "business", "sports", "science", "entertainment"];

// ---------------------------------------------------------------------------
// Fetch
// ---------------------------------------------------------------------------

async function collect() {
  if (useCache && existsSync(CACHE)) {
    console.log(`(using cached feeds from ${CACHE})\n`);
    return JSON.parse(readFileSync(CACHE, "utf8"));
  }
  const out = [];
  for (const pub of PUBLISHERS) {
    const rows = [];
    const errors = [];
    let fetched = 0;
    for (const feedUrl of pub.feeds) {
      try {
        const res = await fetch(feedUrl, {
          headers: { "User-Agent": USER_AGENT, Accept: "application/rss+xml, application/xml, text/xml, */*" },
          redirect: "follow",
        });
        if (!res.ok) { errors.push(`${feedUrl} HTTP ${res.status}`); continue; }
        const items = parseFeed(await res.text());
        fetched += items.length;
        for (const item of items) {
          if (!item.link.startsWith("http")) continue;
          if (isOpinion(item, item.link)) continue;
          rows.push({
            title: item.title,
            link: item.link,
            categories: item.categories,
            feedUrl,
          });
        }
      } catch (e) {
        errors.push(`${feedUrl} ${e.message}`);
      }
    }
    out.push({ ...pub, fetched, rows, errors });
    // One request per feed, spaced. Same politeness posture as ingest-rss.
    await new Promise((r) => setTimeout(r, 400));
  }
  mkdirSync(dirname(CACHE), { recursive: true });
  writeFileSync(CACHE, JSON.stringify(out));
  return out;
}

// ---------------------------------------------------------------------------
// Classify both ways
// ---------------------------------------------------------------------------

const data = await collect();

for (const pub of data) {
  for (const row of pub.rows) {
    const item = { title: row.title, link: row.link, categories: row.categories, description: "", fullContent: "", author: "", imageUrl: "", publishedAt: null };
    row.old = oldCategoryFor(item, row.link);
    const result = categorize(item, row.link, row.feedUrl, pub.def);
    row.new = result.category;
    row.via = result.via;
    row.detail = result.detail;
  }
}

const tally = (rows, key) => {
  const t = Object.fromEntries(CATS.map((c) => [c, 0]));
  for (const r of rows) t[r[key]]++;
  return t;
};
const pct = (n, total) => (total ? ((100 * n) / total).toFixed(1) : "0.0") + "%";

const all = data.flatMap((p) => p.rows);

// -- 1. Whole pool ----------------------------------------------------------
console.log("=".repeat(74));
console.log(`CANDIDATE POOL — ${data.length} publishers, ${all.length} items (post-opinion-filter)`);
console.log("=".repeat(74));
const oldAll = tally(all, "old");
const newAll = tally(all, "new");
console.log("category".padEnd(16) + "OLD".padStart(8) + "".padStart(9) + "NEW".padStart(8) + "".padStart(9) + "  change");
for (const c of CATS) {
  const o = oldAll[c], n = newAll[c];
  const d = n - o;
  console.log(
    c.padEnd(16) +
    String(o).padStart(6) + pct(o, all.length).padStart(9) +
    String(n).padStart(8) + pct(n, all.length).padStart(9) +
    "   " + (d >= 0 ? "+" : "") + d,
  );
}

// -- 2. Per publisher -------------------------------------------------------
console.log("\n" + "=".repeat(74));
console.log("PER PUBLISHER — % world, old -> new");
console.log("=".repeat(74));
// `blind` is the share of a publisher's rows the classifier could say NOTHING
// about — no feed section, no usable tag, no section in the article path — so
// they fell to default_category. It is the honest ceiling on how well any
// classifier can do for that source, and it is a SUPPLY fact, not a code one:
// a publisher at 90%+ blind can only ever contribute its default category, and
// the fix for it is a section feed in rss_urls, not a smarter classifier.
console.log("publisher".padEnd(19) + "default".padEnd(9) + "n".padStart(5) + "  old%world  new%world  blind%   dominant new category");
for (const p of data) {
  if (p.rows.length === 0) { console.log(p.id.padEnd(19) + p.def.padEnd(9) + "0".padStart(5) + (p.errors.length ? "   ERR " + p.errors.join("; ") : "")); continue; }
  const o = tally(p.rows, "old"), n = tally(p.rows, "new");
  const dom = CATS.map((c) => [c, n[c]]).sort((a, b) => b[1] - a[1])[0];
  const blind = p.rows.filter((r) => r.via === "publisher_default").length;
  console.log(
    p.id.padEnd(19) + p.def.padEnd(9) + String(p.rows.length).padStart(5) +
    pct(o.world, p.rows.length).padStart(11) + pct(n.world, p.rows.length).padStart(11) +
    pct(blind, p.rows.length).padStart(8) +
    "   " + dom[0] + " (" + pct(dom[1], p.rows.length) + ")" +
    (p.errors.length ? "   ERR " + p.errors.join("; ") : ""),
  );
}

// -- 3. Decision path -------------------------------------------------------
console.log("\n" + "=".repeat(74));
console.log("HOW THE NEW CLASSIFIER DECIDED");
console.log("=".repeat(74));
const viaTally = {};
for (const r of all) {
  const k = `${r.via} -> ${r.new}`;
  viaTally[k] = (viaTally[k] ?? 0) + 1;
}
for (const [k, v] of Object.entries(viaTally).sort((a, b) => b[1] - a[1])) {
  console.log("  " + k.padEnd(38) + String(v).padStart(5) + pct(v, all.length).padStart(9));
}
const viaOnly = {};
for (const r of all) viaOnly[r.via] = (viaOnly[r.via] ?? 0) + 1;
console.log("  " + "-".repeat(50));
for (const [k, v] of Object.entries(viaOnly).sort((a, b) => b[1] - a[1])) {
  console.log("  " + k.padEnd(38) + String(v).padStart(5) + pct(v, all.length).padStart(9));
}

// -- 4. Named regressions from the audit ------------------------------------
console.log("\n" + "=".repeat(74));
console.log("THE AUDIT'S NAMED FALSE POSITIVES");
console.log("=".repeat(74));
// "Bad" is deliberately precise: a row is only a false positive if the NOISE
// WORD is what carried it there. France 24 filing under an `Americas` tag is
// world for an honest reason and must not count against the fix — an earlier
// draft of this harness flagged exactly those rows and read as a regression
// when nothing had regressed.
const onlyEvidenceIs = (row, word, category) => {
  if (row.new !== category || row.via !== "signals") return false;
  const forCategory = [...row.detail.matchAll(/(\w+)\+\d+:"?([\w ]+)"?/g)]
    .filter((m) => m[1] === category)
    .map((m) => m[2]);
  return forCategory.length > 0 && forCategory.every((w) => w === word);
};

for (const p of data) for (const r of p.rows) r.pub = p.id;

const checks = [
  {
    name: '"transportation" tag -> sports',
    match: (r) => r.categories.some((c) => /transportation/i.test(c)),
    oldBad: (r) => r.old === "sports",
    newBad: (r) => r.new === "sports",
  },
  {
    name: 'ESPN "…-trade" slug -> business',
    match: (r) => r.pub === "espn" && /trade/i.test(r.link),
    oldBad: (r) => r.old === "business",
    newBad: (r) => r.new === "business",
  },
  {
    name: 'slug word "global" alone -> world',
    match: (r) => /-global-|\/global-/i.test(r.link),
    oldBad: (r) => r.old === "world",
    newBad: (r) => onlyEvidenceIs(r, "global", "world"),
  },
  {
    name: 'slug word "americas" alone -> world',
    match: (r) => /americas/i.test(r.link),
    oldBad: (r) => r.old === "world",
    newBad: (r) => onlyEvidenceIs(r, "americas", "world"),
  },
  {
    name: 'tag "News" -> world',
    match: (r) => r.categories.some((c) => /^news$/i.test(c)),
    oldBad: (r) => r.old === "world",
    newBad: (r) => onlyEvidenceIs(r, "news", "world"),
  },
];

for (const chk of checks) {
  const hits = all.filter(chk.match);
  const oldBad = hits.filter(chk.oldBad).length;
  const newBad = hits.filter(chk.newBad).length;
  console.log(
    `  ${chk.name.padEnd(36)} matched ${String(hits.length).padStart(4)}` +
    `   old ${String(oldBad).padStart(4)}   new ${String(newBad).padStart(4)}` +
    `   ${newBad === 0 ? "OK" : "STILL PRESENT"}`,
  );
}

// -- 5. Beat wires ----------------------------------------------------------
console.log("\n" + "=".repeat(74));
console.log("PURE-BEAT WIRES — do they now land on their beat?");
console.log("=".repeat(74));
for (const id of ["sciencedaily", "sciencenews", "espn", "techcrunch", "theverge", "wired", "cnbc"]) {
  const p = data.find((x) => x.id === id);
  if (!p || p.rows.length === 0) continue;
  const n = tally(p.rows, "new");
  const o = tally(p.rows, "old");
  console.log(`  ${id.padEnd(14)} beat=${p.def.padEnd(13)} on-beat old ${pct(o[p.def], p.rows.length).padStart(7)}  ->  new ${pct(n[p.def], p.rows.length).padStart(7)}   (n=${p.rows.length})`);
}

// -- 6. BBC / Guardian section feeds ----------------------------------------
console.log("\n" + "=".repeat(74));
console.log("SECTION FEEDS — the whole point of migrations 0018 / 0023");
console.log("=".repeat(74));
for (const id of ["bbc", "theguardian"]) {
  const p = data.find((x) => x.id === id);
  if (!p) continue;
  const feeds = [...new Set(p.rows.map((r) => r.feedUrl))];
  for (const f of feeds) {
    const rows = p.rows.filter((r) => r.feedUrl === f);
    const o = tally(rows, "old"), n = tally(rows, "new");
    const oDom = CATS.map((c) => [c, o[c]]).sort((a, b) => b[1] - a[1])[0];
    const nDom = CATS.map((c) => [c, n[c]]).sort((a, b) => b[1] - a[1])[0];
    console.log(`  ${id.padEnd(12)} ${f.replace(/^https?:\/\//, "").padEnd(46)} n=${String(rows.length).padStart(3)}  old=${oDom[0]} (${pct(oDom[1], rows.length)})  new=${nDom[0]} (${pct(nDom[1], rows.length)})`);
  }
}

// ---------------------------------------------------------------------------
// 7. Simulated fair-share run — round-robin exactly as ingest-rss does it.
//    Candidates are ordered newest-first there; the harness has no reliable
//    date on every feed, so it keeps feed order (which is reverse-chronological
//    for every publisher in the slate). Treat the run mix as indicative and the
//    pool mix above as exact.
// ---------------------------------------------------------------------------

const MAX_ARTICLES_PER_RUN_TOTAL = 48;
const MAX_REGION_SHARE = 0.35;

function simulateRun(key) {
  const regionCap = Math.max(1, Math.floor(MAX_ARTICLES_PER_RUN_TOTAL * MAX_REGION_SHARE));
  const selected = [];
  const perPub = new Map();
  const perRegion = new Map();
  for (let round = 0; selected.length < MAX_ARTICLES_PER_RUN_TOTAL && round < 50; round++) {
    let progressed = false;
    for (const p of data) {
      if (selected.length >= MAX_ARTICLES_PER_RUN_TOTAL) break;
      const taken = perPub.get(p.id) ?? 0;
      if (taken >= p.maxPerRun) continue;
      if (round >= p.rows.length) continue;
      const region = p.region ?? "GLOBAL";
      if (region !== "GLOBAL") {
        const rt = perRegion.get(region) ?? 0;
        if (rt >= regionCap) continue;
        perRegion.set(region, rt + 1);
      } else {
        perRegion.set(region, (perRegion.get(region) ?? 0) + 1);
      }
      selected.push(p.rows[round]);
      perPub.set(p.id, taken + 1);
      progressed = true;
    }
    if (!progressed) break;
  }
  return { selected, tally: tally(selected, key), perRegion };
}

const oldRun = simulateRun("old");
const newRun = simulateRun("new");
console.log("\n" + "=".repeat(74));
console.log(`SIMULATED 48-ARTICLE FAIR-SHARE RUN (n=${newRun.selected.length})`);
console.log("=".repeat(74));
console.log("category".padEnd(16) + "OLD".padStart(8) + "".padStart(9) + "NEW".padStart(8) + "".padStart(9));
for (const c of CATS) {
  const o = oldRun.tally[c], n = newRun.tally[c];
  console.log(
    c.padEnd(16) +
    String(o).padStart(6) + pct(o, oldRun.selected.length).padStart(9) +
    String(n).padStart(8) + pct(n, newRun.selected.length).padStart(9),
  );
}
const emptyOld = CATS.filter((c) => oldRun.tally[c] === 0);
const emptyNew = CATS.filter((c) => newRun.tally[c] === 0);
console.log(`\n  categories with ZERO articles in the run:  old=[${emptyOld.join(", ")}]  new=[${emptyNew.join(", ")}]`);
console.log(`  per-region: ${JSON.stringify(Object.fromEntries(newRun.perRegion))}`);

// -- 8. Sample of what moved -----------------------------------------------
console.log("\n" + "=".repeat(74));
console.log("SAMPLE OF RELABELLED ROWS (old -> new)");
console.log("=".repeat(74));
const moved = all.filter((r) => r.old !== r.new);
console.log(`  ${moved.length} of ${all.length} rows changed label (${pct(moved.length, all.length)})\n`);
for (const r of moved.slice(0, 15)) {
  console.log(`  ${r.old} -> ${r.new}  [${r.via}]  ${r.pub}`);
  console.log(`     ${r.title.slice(0, 82)}`);
  console.log(`     tags=${JSON.stringify(r.categories.slice(0, 3))} ${r.detail.slice(0, 90)}`);
}
