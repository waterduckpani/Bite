// Bite · Phase 7: article embedding worker.
//
// Embeds TITLE + SNIPPET only (the metadata we already store — never full
// bodies) with the Edge runtime's built-in gte-small model (384 dims,
// English-only, truncates past 512 tokens — title+snippet fits comfortably)
// and writes the vector back to articles.embedding.
//
// Invoked with an empty POST body by:
//   - the statement-level triggers on public.articles (via pg_net), and
//   - the pg_cron sweep every 10 minutes (retries + one-time backfill).
// Each invocation drains up to BATCH null-embedding rows, then re-invokes
// itself while more remain, so callers never need to pass row payloads.
//
// Deploy with --no-verify-jwt (the anon key may be the new non-JWT
// sb_publishable_ format); access is gated by the EMBED_SECRET header
// instead (set via `supabase secrets set`, matched by the vault secret the
// database callers read).

import { createClient } from "jsr:@supabase/supabase-js@2";

// Provided by the Edge runtime; declared here so local tooling type-checks.
declare const Supabase: {
  ai: {
    Session: new (model: string) => {
      run(
        input: string,
        options: { mean_pool: boolean; normalize: boolean },
      ): Promise<number[]>;
    };
  };
};

const session = new Supabase.ai.Session("gte-small");

// Small batches keep each request far inside the CPU budget; the self-chain
// below picks up whatever is left.
const BATCH = 20;

Deno.serve(async (req) => {
  const secret = Deno.env.get("EMBED_SECRET");
  if (secret && req.headers.get("x-embed-secret") !== secret) {
    return new Response("forbidden", { status: 403 });
  }

  // Service role: this function is the only writer of articles.embedding.
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: rows, error } = await supabase
    .from("articles")
    .select("id, title, snippet")
    .is("embedding", null)
    .order("created_at", { ascending: false })
    .limit(BATCH);
  if (error) {
    return Response.json({ error: error.message }, { status: 500 });
  }

  let embedded = 0;
  for (const row of rows ?? []) {
    const input = `${row.title}\n\n${row.snippet}`.trim();
    if (!input) continue;
    const vector = await session.run(input, {
      mean_pool: true,
      normalize: true,
    });
    const { error: writeError } = await supabase
      .from("articles")
      .update({ embedding: JSON.stringify(vector) })
      .eq("id", row.id)
      .is("embedding", null); // concurrent invocation may have won the row
    if (!writeError) embedded++;
  }

  // More waiting? Chain another invocation after the response is sent.
  const { count } = await supabase
    .from("articles")
    .select("id", { count: "exact", head: true })
    .is("embedding", null);
  const remaining = count ?? 0;
  if (remaining > 0 && (rows?.length ?? 0) > 0) {
    const self = fetch(req.url, {
      method: "POST",
      headers: secret ? { "x-embed-secret": secret } : {},
    }).catch(() => {});
    (globalThis as unknown as {
      EdgeRuntime?: { waitUntil(p: Promise<unknown>): void };
    }).EdgeRuntime?.waitUntil?.(self);
  }

  return Response.json({ embedded, remaining });
});
