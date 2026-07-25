// Bite · Phase 14: RSS / Atom parsing.
//
// Regex-based rather than a DOM parser, on purpose: publisher feeds are
// frequently malformed (unescaped ampersands, stray tags inside CDATA,
// mismatched namespaces) and a strict parser turns one bad item into a failed
// run for the whole publisher. This mirrors tools/qualify_publisher.dart, so
// what qualification reported is what ingestion actually sees.
//
// Handles RSS 2.0 (<item>), RDF/RSS 1.0 (<item> at top level) and Atom
// (<entry>). Namespaced tags are matched on their local name, so dc:creator,
// content:encoded and media:thumbnail all resolve without namespace bookkeeping.

export interface RssItem {
  title: string;
  /// Raw link exactly as the feed gave it. Canonicalise before storing.
  link: string;
  description: string;
  /// content:encoded (RSS) or content (Atom), tags stripped. Empty when the
  /// feed carries only a description.
  fullContent: string;
  author: string;
  imageUrl: string;
  categories: string[];
  publishedAt: string | null;
}

export function stripTags(html: string): string {
  return html
    .replace(/<script[\s\S]*?<\/script>/gi, " ")
    .replace(/<style[\s\S]*?<\/style>/gi, " ")
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

export function decodeEntities(s: string): string {
  return s
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#0?39;/g, "'")
    .replace(/&#x27;/gi, "'")
    .replace(/&apos;/g, "'")
    .replace(/&nbsp;/g, " ")
    .replace(/&#8217;/g, "’")
    .replace(/&#8216;/g, "‘")
    .replace(/&#8220;/g, "“")
    .replace(/&#8221;/g, "”")
    .replace(/&#8211;/g, "–")
    .replace(/&#8212;/g, "—")
    // &amp; last, so "&amp;lt;" doesn't collapse into a tag.
    .replace(/&amp;/g, "&");
}

function unwrapCdata(value: string): string {
  const cdata = /<!\[CDATA\[([\s\S]*?)\]\]>/.exec(value);
  return cdata ? cdata[1] : value;
}

/// Inner text of the first `<tag>` in [xml], CDATA unwrapped, entities decoded.
function tagText(xml: string, tag: string): string {
  const re = new RegExp(
    `<(?:[a-zA-Z0-9-]+:)?${tag}(?:\\s[^>]*)?>([\\s\\S]*?)</(?:[a-zA-Z0-9-]+:)?${tag}>`,
    "i",
  );
  const m = re.exec(xml);
  if (!m) return "";
  return decodeEntities(unwrapCdata(m[1])).trim();
}

function tagTexts(xml: string, tag: string): string[] {
  const re = new RegExp(
    `<(?:[a-zA-Z0-9-]+:)?${tag}(?:\\s[^>]*)?>([\\s\\S]*?)</(?:[a-zA-Z0-9-]+:)?${tag}>`,
    "gi",
  );
  const out: string[] = [];
  for (const m of xml.matchAll(re)) {
    const value = decodeEntities(unwrapCdata(m[1])).trim();
    if (value) out.push(value);
  }
  return out;
}

function attr(tagMarkup: string, name: string): string {
  const m = new RegExp(`${name}\\s*=\\s*["']([^"']*)["']`, "i").exec(tagMarkup);
  return m ? decodeEntities(m[1]) : "";
}

/// Atom puts the link in an attribute; prefer rel="alternate".
function atomLink(xml: string): string {
  for (const m of xml.matchAll(/<link\b([^>]*?)\/?>/gi)) {
    const attrs = m[1] ?? "";
    const rel = attr(attrs, "rel");
    if (rel && rel !== "alternate") continue;
    const href = attr(attrs, "href");
    if (href) return href;
  }
  return "";
}

/// A cover URL the app's image pipeline can decode: http(s) and not an SVG.
/// Mirrors the same guard in ingest-news.
function validImageUrl(url: string): string {
  if (!url) return "";
  try {
    const parsed = new URL(url);
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return "";
    return parsed.pathname.toLowerCase().endsWith(".svg") ? "" : url;
  } catch {
    return "";
  }
}

/// First usable image for an item: media:content / media:thumbnail /
/// enclosure, else the first <img> inside the content.
function itemImage(block: string): string {
  for (const re of [
    /<media:content\b([^>]*)>/i,
    /<media:thumbnail\b([^>]*)>/i,
    /<enclosure\b([^>]*)>/i,
  ]) {
    const m = re.exec(block);
    if (!m) continue;
    const type = attr(m[1], "type");
    if (type && !type.startsWith("image")) continue;
    const url = validImageUrl(attr(m[1], "url"));
    if (url) return url;
  }
  const img = /<img\b[^>]*src\s*=\s*["']([^"']+)["']/i.exec(block);
  return img ? validImageUrl(decodeEntities(img[1])) : "";
}

const MONTHS: Record<string, number> = {
  jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6,
  jul: 7, aug: 8, sep: 9, oct: 10, nov: 11, dec: 12,
};

/// RFC 822 ("Mon, 21 Jul 2026 14:03:00 +0530") and ISO 8601, to an ISO string.
export function parseFeedDate(raw: string): string | null {
  if (!raw) return null;
  const direct = Date.parse(raw);
  if (!Number.isNaN(direct)) return new Date(direct).toISOString();

  const m =
    /(\d{1,2})\s+([A-Za-z]{3})[a-z]*\s+(\d{4})\s+(\d{2}):(\d{2})(?::(\d{2}))?\s*([+-]\d{4})?/
      .exec(raw);
  if (!m) return null;
  const month = MONTHS[m[2].toLowerCase()];
  if (!month) return null;
  let ms = Date.UTC(
    Number(m[3]), month - 1, Number(m[1]),
    Number(m[4]), Number(m[5]), Number(m[6] ?? "0"),
  );
  const zone = m[7];
  if (zone) {
    const sign = zone.startsWith("-") ? 1 : -1;
    ms += sign * (Number(zone.slice(1, 3)) * 3600 + Number(zone.slice(3, 5)) * 60) * 1000;
  }
  return new Date(ms).toISOString();
}

/// Parses a feed body into items. Returns an empty array when the body is not
/// a feed at all (a soft-404 HTML page, an empty response) — the caller treats
/// that as "this publisher produced nothing this run", never as a crash.
export function parseFeed(body: string): RssItem[] {
  const isAtom = /<feed\b/i.test(body) && !/<rss\b/i.test(body);
  const blockRe = isAtom
    ? /<entry\b[\s\S]*?<\/entry>/gi
    : /<item\b[\s\S]*?<\/item>/gi;

  const items: RssItem[] = [];
  for (const match of body.matchAll(blockRe)) {
    const block = match[0];

    const link = isAtom ? atomLink(block) : tagText(block, "link");
    const rawDescription = isAtom
      ? (tagText(block, "summary") || tagText(block, "content"))
      : tagText(block, "description");
    const rawContent = isAtom ? tagText(block, "content") : tagText(block, "encoded");

    const categories = isAtom
      ? Array.from(block.matchAll(/<category\b([^>]*)>/gi))
          .map((m) => attr(m[1], "term"))
          .filter((c) => c.length > 0)
      : tagTexts(block, "category");

    const dateRaw = isAtom
      ? (tagText(block, "published") || tagText(block, "updated"))
      : (tagText(block, "pubDate") || tagText(block, "date"));

    const title = stripTags(tagText(block, "title"));
    if (!title || !link) continue;

    items.push({
      title,
      link,
      description: stripTags(rawDescription),
      fullContent: stripTags(rawContent),
      author: stripTags(tagText(block, "creator") || tagText(block, "author")),
      imageUrl: itemImage(block),
      categories,
      publishedAt: parseFeedDate(dateRaw),
    });
  }
  return items;
}

/// Whether an item's own content is substantial enough to summarise without
/// fetching the article page at all. Deliberately conservative: a truncated
/// "read more" teaser must NOT count as full content, or we would summarise a
/// stub and skip the body fetch that would have produced a real bite.
export function hasUsableFullContent(item: RssItem): boolean {
  return item.fullContent.length >= 900;
}
