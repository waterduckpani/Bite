// Bite · Phase 14 verification.
//
// Exercises the rules that must hold for this phase to be honest, on the real
// shared modules the Edge Functions import. These are the checks that would
// otherwise be "trust the prompt" or "trust the comment":
//
//   - the User-Agent is BiteNewsBot and contains no browser tokens
//   - robots.txt: our named group beats the wildcard, longest-match wins,
//     and an unreadable robots.txt is treated as DISALLOW
//   - paywalls / consent walls / bot challenges are detected (so the caller
//     can abort; nothing here ever works around them)
//   - the 80-word cap holds IN CODE, fuzzed over 400 inputs
//   - the Phase 9 junk filter still fires on RSS-shaped rows
//   - feed parsing survives RSS, Atom, and a non-feed HTML soft-404
//
// Requires Deno (the same runtime the Edge Functions run on):
//   deno run --allow-read tools/verify_phase14.ts
import {
  canonicalUrl,
  detectWall,
  parseRobots,
  robotsAllows,
  USER_AGENT,
} from "../supabase/functions/_shared/bot.ts";
import {
  SUMMARY_MAX_WORDS,
  truncateToWords,
  wordCount,
} from "../supabase/functions/_shared/words.ts";
import {
  hasUsableFullContent,
  parseFeed,
} from "../supabase/functions/_shared/rss.ts";
import { junkMatch } from "../supabase/functions/_shared/junk.ts";

let pass = 0, fail = 0;
function check(name: string, cond: boolean, detail = "") {
  if (cond) { pass++; console.log(`  ok   ${name}`); }
  else { fail++; console.log(`  FAIL ${name} ${detail}`); }
}

console.log("\n1. Honest identity");
check("UA is BiteNewsBot with a +url",
  /^BiteNewsBot\/1\.0 \(\+https:\/\/\S+\/bot\)$/.test(USER_AGENT), USER_AGENT);
check("UA contains no browser tokens",
  !/mozilla|chrome|safari|webkit|gecko/i.test(USER_AGENT), USER_AGENT);

console.log("\n2. robots.txt — named group beats wildcard, longest match wins");
const robots = parseRobots(`
User-agent: *
Disallow: /
Crawl-delay: 5

User-agent: BiteNewsBot
Disallow: /premium/
Allow: /premium/free/
Disallow: /*.pdf$
Crawl-delay: 2
`, 200);
check("picked our own group", robots.groupUsed === "bitenewsbot", robots.groupUsed);
check("crawl-delay from our group is 2", robots.crawlDelaySeconds === 2,
  `${robots.crawlDelaySeconds}`);
check("ordinary article allowed", robotsAllows(robots, "/article/foo"));
check("/premium/ disallowed", !robotsAllows(robots, "/premium/x"));
check("longer Allow beats shorter Disallow",
  robotsAllows(robots, "/premium/free/x"));
check("wildcard + $ anchor works", !robotsAllows(robots, "/docs/a.pdf"));
check("$ anchor does not over-match", robotsAllows(robots, "/docs/a.pdf.html"));

const wildcardOnly = parseRobots("User-agent: *\nDisallow: /admin/\n", 200);
check("falls back to * group when unnamed",
  wildcardOnly.groupUsed === "*" && !robotsAllows(wildcardOnly, "/admin/x"));

const unreadable = { fetched: false, status: 503, rules: [], crawlDelaySeconds: null, groupUsed: "none" };
check("unreadable robots (5xx) is treated as DISALLOW",
  !robotsAllows(unreadable, "/article/foo"));

console.log("\n3. Walls are detected, never worked around");
check("paywall", detectWall("<p>Subscribe to continue reading</p>") !== null);
check("consent wall", detectWall("<div>We value your privacy</div>") !== null);
check("bot challenge", detectWall("Checking your browser before access") !== null);
check("clean article page is not a wall",
  detectWall("<p>The minister said on Tuesday that the policy would change.</p>") === null);

console.log(`\n4. The ${SUMMARY_MAX_WORDS}-word cap holds in code`);
const long = Array.from({ length: 200 }, (_, i) => `word${i}`).join(" ");
check("hard cut respects the cap",
  wordCount(truncateToWords(long, SUMMARY_MAX_WORDS)) <= SUMMARY_MAX_WORDS,
  `${wordCount(truncateToWords(long, SUMMARY_MAX_WORDS))}`);
const prose = ("The ministry announced a review on Tuesday. " +
  "Officials said the process would take three months. ").repeat(12);
const cut = truncateToWords(prose, SUMMARY_MAX_WORDS);
check("sentence-aware cut respects the cap",
  wordCount(cut) <= SUMMARY_MAX_WORDS, `${wordCount(cut)}`);
check("sentence-aware cut ends cleanly", /[.!?]$/.test(cut), cut.slice(-40));
check("already-short text is untouched",
  truncateToWords("Three words here", SUMMARY_MAX_WORDS) === "Three words here");
// Fuzz: no input may ever produce an over-cap output.
let overs = 0;
for (let n = 1; n <= 400; n++) {
  const t = Array.from({ length: n }, (_, i) => (i % 7 === 6 ? `w${i}.` : `w${i}`)).join(" ");
  if (wordCount(truncateToWords(t, SUMMARY_MAX_WORDS)) > SUMMARY_MAX_WORDS) overs++;
}
check("400 fuzz cases, none exceed the cap", overs === 0, `${overs} over`);

console.log("\n5. Canonical URLs (attribution + dedup key)");
check("strips utm params",
  canonicalUrl("https://scroll.in/article/1?utm_source=rss&utm_medium=public")
    === "https://scroll.in/article/1");
check("strips fragment + trailing slash",
  canonicalUrl("https://a.com/b/#top") === "https://a.com/b");
check("keeps meaningful query",
  canonicalUrl("https://a.com/b?id=7").includes("id=7"));

console.log("\n6. Phase 9 junk filter still fires on RSS-shaped rows");
check("promo caught", junkMatch("The best deals on laptops", "https://a.com/x") !== null);
check("horoscope caught", junkMatch("Daily horoscope", "https://a.com/x") !== null);
check("path rule caught", junkMatch("Anything", "https://a.com/deals/x") !== null);
check("real news survives",
  junkMatch("Cabinet approves trade deal with Japan", "https://a.com/india/x") === null);
check("BNPL guard survives",
  junkMatch("Buy now, pay later lending under scrutiny", "https://a.com/business/x") === null);

console.log("\n7. Feed parsing");
const rss = `<rss><channel>
<item><title>Ministry approves plan</title>
<link>https://x.com/a/1?utm_source=rss</link>
<description><![CDATA[A short standfirst about the plan.]]></description>
<category><![CDATA[India]]></category><category><![CDATA[Opinion]]></category>
<pubDate>Sat, 25 Jul 2026 06:44:53 +0000</pubDate>
<content:encoded><![CDATA[<p>${"Body sentence. ".repeat(80)}</p>]]></content:encoded>
</item></channel></rss>`;
const items = parseFeed(rss);
check("parsed one item", items.length === 1);
check("title", items[0]?.title === "Ministry approves plan");
check("categories", items[0]?.categories.join(",") === "India,Opinion");
check("date parsed to ISO", (items[0]?.publishedAt ?? "").startsWith("2026-07-25"));
check("full content detected", hasUsableFullContent(items[0]));

const atom = `<feed><entry><title>Study finds effect</title>
<link rel="alternate" href="https://y.com/b/2"/>
<summary>Short summary text.</summary>
<category term="Science"/>
<published>2026-07-24T10:00:00Z</published></entry></feed>`;
const aitems = parseFeed(atom);
check("atom entry parsed", aitems.length === 1 && aitems[0].link === "https://y.com/b/2");
check("atom category", aitems[0]?.categories.join(",") === "Science");
check("description-only detected", !hasUsableFullContent(aitems[0]));
check("non-feed HTML yields zero items, no throw",
  parseFeed("<html><body>404</body></html>").length === 0);

console.log(`\n${pass} passed, ${fail} failed\n`);
if (fail > 0) Deno.exit(1);
