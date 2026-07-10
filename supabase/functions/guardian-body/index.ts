// Bite · reader body proxy (final key-removal step).
//
// The last news-API key leaves the app bundle: the reader asks this function
// for a Guardian article's body, and GUARDIAN_API_KEY lives only in Edge
// Function secrets (set in Phase 8 for ingest-news — reused here, nothing to
// re-add).
//
// Cache: fetched bodies are stored in public.article_bodies (migration 0004)
// and served from there while fresh, so repeat opens of the same story never
// re-hit the Guardian — protecting the shared 5,000/day dev-tier cap. The
// freshness window is deliberately short (24h re-fetch, 48h purge, 404/410
// deletes the row) because the Guardian's terms require honoring takedowns:
// pulled or corrected articles refresh within a day instead of persisting.
//
// Gated by x-body-secret == BODY_FN_SECRET — the same per-function shared-
// secret pattern as embed (x-embed-secret) and ingest-news (x-ingest-secret),
// but deliberately a DIFFERENT secret: this one ships in the app bundle to
// let the reader call in, and it must not unlock the functions that spend
// NewsData credits or write the article pool.
//
// Deploy (GUARDIAN_API_KEY is already set):
//   supabase secrets set BODY_FN_SECRET=<value from functions/.env.secrets>
//   supabase functions deploy guardian-body --no-verify-jwt
// Secrets: GUARDIAN_API_KEY, BODY_FN_SECRET.

import { createClient } from "jsr:@supabase/supabase-js@2";

// How long a cached body is served without re-checking the Guardian. Keep
// well under the 48h purge in purge_old_articles (migration 0004) so a
// stale-but-unpurged row can still back the Guardian-down fallback below.
const CACHE_FRESH_HOURS = 24;

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

// Readable paragraphs from the Guardian's HTML body — a faithful port of the
// retired client parser (guardian_api.dart), so stories render identically.
function paragraphs(html: string): string[] {
  const out: string[] = [];
  for (const m of html.matchAll(/<p>(.*?)<\/p>/gs)) {
    const text = plainText(m[1]);
    if (text.length > 1) out.push(text);
  }
  return out;
}

Deno.serve(async (req) => {
  const secret = Deno.env.get("BODY_FN_SECRET");
  if (secret && req.headers.get("x-body-secret") !== secret) {
    return new Response("forbidden", { status: 403 });
  }

  let id = "";
  try {
    id = `${(await req.json())?.id ?? ""}`;
  } catch {
    // fall through to the validation below
  }
  const path = id.startsWith("guardian:")
    ? id.slice("guardian:".length)
    : id;
  // Guardian item ids are plain slug paths (world/2026/jul/08/…). Reject
  // anything else before it's spliced into the URL below.
  if (!/^[a-z0-9][a-z0-9/._-]*$/i.test(path)) {
    return Response.json({ error: "bad article id" }, { status: 400 });
  }
  const cacheKey = `guardian:${path}`;

  // Service role: article_bodies has RLS on with no policies, so only this
  // function reads or writes the cache.
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: cached } = await supabase
    .from("article_bodies")
    .select("paragraphs, fetched_at")
    .eq("article_id", cacheKey)
    .maybeSingle();
  if (
    cached &&
    Date.now() - new Date(cached.fetched_at).getTime() <
      CACHE_FRESH_HOURS * 3600 * 1000
  ) {
    return Response.json({ paragraphs: cached.paragraphs, cached: true });
  }

  const apiKey = Deno.env.get("GUARDIAN_API_KEY");
  if (!apiKey) {
    return Response.json({ error: "GUARDIAN_API_KEY not set" }, { status: 500 });
  }

  let body: string[];
  try {
    const params = new URLSearchParams({
      "api-key": apiKey,
      "show-fields": "body",
    });
    const res = await fetch(
      `https://content.guardianapis.com/${path}?${params}`,
    );
    // Takedown: the item no longer exists upstream, so the cached copy must
    // go too — never serve a body the Guardian has pulled.
    if (res.status === 404 || res.status === 410) {
      await supabase.from("article_bodies").delete().eq("article_id", cacheKey);
      return Response.json({ paragraphs: [], cached: false });
    }
    if (!res.ok) throw new Error(`Guardian HTTP ${res.status}`);
    const content = (await res.json()).response?.content;
    body = paragraphs(content?.fields?.body ?? "");
  } catch (e) {
    // Guardian down or rate-limited: a stale (but unpurged, so <48h) cached
    // body beats an error. Otherwise the client degrades to its in-app
    // browser fallback.
    if (cached) {
      return Response.json({
        paragraphs: cached.paragraphs,
        cached: true,
        stale: true,
      });
    }
    return Response.json({ error: `${e}` }, { status: 502 });
  }

  // Empty bodies (liveblogs/galleries) are cached too, so repeat opens of an
  // unreadable story don't re-hit the Guardian either.
  await supabase.from("article_bodies").upsert({
    article_id: cacheKey,
    paragraphs: body,
    fetched_at: new Date().toISOString(),
  });

  return Response.json({ paragraphs: body, cached: false });
});
