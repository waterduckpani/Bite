// Bite · Phase 10: AI summarisation worker.
//
// Reads LICENSED full body text and writes a Bite-voice hook + 2-3 sentence
// summary back onto the article row (ai_summary / ai_summary_hook), so the
// swipe deck can show a summary without the client ever calling a model or
// holding the model key. Kept separate from ingest-news so it retries and
// scales on its own cron (0005 schedules it 5 min after each ingest run).
//
// LICENSING GATE — read before touching the selection query below. We only
// summarise text Bite is licensed to hold. That means rows with FULL BODY
// TEXT present, NOT "source == Guardian". Right now the only such text is
// Guardian body fetched via the guardian-body proxy, so the gate is the
// `full_text_available` flag (the same flag the client uses to route the
// native reader vs. an in-app browser). Snippet-only rows (NewsData and
// anything else) have full_text_available = false and are never selected —
// no code change needed to keep skipping them. If a future licensed
// full-text source is added, flip its full_text_available true AND add a
// branch to fetchBody() below; the summariser itself (summarise()) is
// source-agnostic and needs no change.
//
// The client holds none of this: it reads ai_summary/ai_summary_hook off the
// feed RPC. A null/failed summary is normal — cards fall back to the snippet.
//
// Deploy with --no-verify-jwt (the anon key may be a non-JWT sb_publishable_
// key); access is gated by x-summarize-secret == SUMMARIZE_SECRET instead.
//   supabase secrets set --env-file supabase/functions/.env.secrets
//   supabase functions deploy summarize-articles --no-verify-jwt
// Secrets: OPENROUTER_KEY, SUMMARIZE_SECRET, BODY_FN_SECRET (reused, to call
// guardian-body). SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are injected.

import { createClient } from "jsr:@supabase/supabase-js@2";

// -- Config -----------------------------------------------------------------
// Model note: news summarisation is light work — default to the bottom of the
// price ladder. VERIFY THESE SLUGS against https://openrouter.ai/api/v1/models
// before deploying; OpenRouter slugs drift. All slugs below were confirmed
// valid on 2026-07-16.
//
// CAVEAT: OpenRouter validates EVERY id in the `models` array up front — a
// single invalid slug 400s the whole request (even if the primary is fine),
// so this is not a "graceful degradation" list; keep every entry valid. (The
// `latest` router alias is literally "~google/gemini-flash-latest" with the
// tilde — bare "google/gemini-flash-latest" is rejected.) provider.sort="price"
// still routes to the cheapest provider per model.
const SUMMARY_MODEL = "google/gemini-3.1-flash-lite";
const FALLBACK_MODELS = [
  "google/gemini-2.5-flash-lite",
  "deepseek/deepseek-chat",
];

const BATCH_SIZE = 25;
const CONCURRENCY = 4;
const MAX_ATTEMPTS = 3;
const INPUT_CHAR_CAP = 6000; // ~1.5k tokens of leading body text
const OUTPUT_MAX_TOKENS = 200; // the output is tiny (one hook + 2-3 sentences)

// The summariser prompt is spec-verbatim; do not paraphrase.
const SYSTEM_PROMPT =
  `You write concise news summaries for Bite, a news reader. You are given the full text of a single article. Produce a summary using ONLY facts stated in that text.

Rules:
- Use only information present in the provided article. Never add facts, context, names, numbers, or background from outside the text. If the text is thin, summarise only what is there.
- Neutral and factual. Report what the article says without taking a side, editorialising, or amplifying framing. No opinions, no adjectives of judgement.
- Plain, warm, confident voice. Clear sentences a smart general reader gets instantly. No jargon, no hype, no marketing tone.
- Never clickbait. No teasing, no "find out why", no cliffhangers, no withholding the point. Say what happened.
- Third person, present or past tense as the facts require. No "I", no "we", no addressing the reader.
- The hook is a single punchy line (6–12 words) capturing the core of the story — a plain-spoken headline, not a tease.
- The summary is 2–3 sentences, 40–60 words, that stand on their own: someone who reads only this understands the story.

Output STRICT JSON and nothing else — no markdown, no code fences, no preamble:
{"hook": "...", "summary": "..."}`;

// -- Full-text fetch --------------------------------------------------------
// Source-aware (Guardian today) so the summariser stays source-agnostic.
// Reuses the guardian-body proxy: one licensing boundary, and it warms the
// reader's body cache as a side effect. Returns "" when there is no readable
// body (liveblog/gallery/takedown) — which the caller treats as "no full
// text present" and does not summarise.
async function fetchBody(
  supabaseUrl: string,
  bodySecret: string | undefined,
  articleId: string,
): Promise<string> {
  const res = await fetch(`${supabaseUrl}/functions/v1/guardian-body`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(bodySecret ? { "x-body-secret": bodySecret } : {}),
    },
    body: JSON.stringify({ id: articleId }),
  });
  if (!res.ok) throw new Error(`guardian-body HTTP ${res.status}`);
  const data = await res.json();
  const paras: string[] = Array.isArray(data?.paragraphs) ? data.paragraphs : [];
  return paras.join("\n\n").trim();
}

// -- Summariser (SOURCE-AGNOSTIC: (fullText, headline) -> {hook, summary}) ---
// Pure over its inputs — it never knows or cares where the text came from, so
// it survives the eventual production source switch untouched.
async function summarise(
  openrouterKey: string,
  fullText: string,
  headline: string,
): Promise<{ hook: string; summary: string; model: string }> {
  const body = fullText.slice(0, INPUT_CHAR_CAP);
  const userMessage = `Headline: ${headline}\n\nArticle:\n${body}`;

  const res = await fetch("https://openrouter.ai/api/v1/chat/completions", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${openrouterKey}`,
      // Optional attribution headers OpenRouter recommends.
      "HTTP-Referer": "https://bite.app",
      "X-Title": "Bite",
    },
    body: JSON.stringify({
      model: SUMMARY_MODEL,
      models: [SUMMARY_MODEL, ...FALLBACK_MODELS], // ordered, cheapest-first fallback
      provider: { sort: "price" }, // cheapest qualifying provider per model
      max_tokens: OUTPUT_MAX_TOKENS,
      temperature: 0.3,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: SYSTEM_PROMPT },
        { role: "user", content: userMessage },
      ],
    }),
  });
  if (!res.ok) {
    throw new Error(`OpenRouter HTTP ${res.status}: ${await res.text()}`);
  }
  const data = await res.json();
  const content: string = data?.choices?.[0]?.message?.content ?? "";
  const modelUsed: string = data?.model ?? SUMMARY_MODEL;

  const parsed = parseSummary(content);
  if (!parsed) throw new Error("unparseable model output");
  const hook = `${parsed.hook ?? ""}`.trim();
  const summary = `${parsed.summary ?? ""}`.trim();
  if (!hook || !summary) throw new Error("empty hook or summary");
  return { hook, summary, model: modelUsed };
}

// Parse the model output as JSON. If it isn't valid, strip accidental code
// fences and retry the parse once; still failing counts as a failure.
function parseSummary(
  raw: string,
): { hook?: string; summary?: string } | null {
  const attempt = (s: string) => {
    try {
      return JSON.parse(s) as { hook?: string; summary?: string };
    } catch {
      return null;
    }
  };
  return attempt(raw.trim()) ??
    attempt(raw.replace(/```(?:json)?/gi, "").replace(/```/g, "").trim());
}

// -- Bounded-concurrency map ------------------------------------------------
async function runPool<T>(
  items: T[],
  limit: number,
  worker: (item: T) => Promise<void>,
): Promise<void> {
  let cursor = 0;
  const runners = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (cursor < items.length) {
      const i = cursor++;
      await worker(items[i]);
    }
  });
  await Promise.all(runners);
}

Deno.serve(async (req) => {
  const secret = Deno.env.get("SUMMARIZE_SECRET");
  if (secret && req.headers.get("x-summarize-secret") !== secret) {
    return new Response("forbidden", { status: 403 });
  }

  const openrouterKey = Deno.env.get("OPENROUTER_KEY");
  if (!openrouterKey) {
    return Response.json({ error: "OPENROUTER_KEY not set" }, { status: 500 });
  }
  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const bodySecret = Deno.env.get("BODY_FN_SECRET");

  // Service role: this function owns the ai_summary* columns.
  const supabase = createClient(
    supabaseUrl,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // Selection gate: full body text licensed (full_text_available), not yet
  // done/failed, under the retry cap. Freshest first — users see recent news.
  const { data: rows, error } = await supabase
    .from("articles")
    .select("id, title, ai_summary_attempts")
    .eq("full_text_available", true)
    .or("ai_summary_status.is.null,ai_summary_status.eq.pending")
    .lt("ai_summary_attempts", MAX_ATTEMPTS)
    .order("created_at", { ascending: false })
    .limit(BATCH_SIZE);
  if (error) {
    return Response.json({ error: error.message }, { status: 500 });
  }
  const batch = rows ?? [];

  // Claim the batch as pending so an overlapping run doesn't double-summarise.
  // A row left pending by a crash is re-selected next run (attempts untouched).
  if (batch.length) {
    await supabase
      .from("articles")
      .update({ ai_summary_status: "pending" })
      .in("id", batch.map((r) => r.id));
  }

  let done = 0;
  let failed = 0;
  let skipped = 0;

  await runPool(batch, CONCURRENCY, async (row) => {
    const attempts = (row.ai_summary_attempts as number) ?? 0;
    // Roll a failure back to null so it retries next run, unless it has hit
    // the cap — then park it as failed. A failed row still displays fine.
    const markFailure = async (reason: string) => {
      const next = attempts + 1;
      await supabase
        .from("articles")
        .update({
          ai_summary_attempts: next,
          ai_summary_status: next >= MAX_ATTEMPTS ? "failed" : null,
        })
        .eq("id", row.id);
      if (next >= MAX_ATTEMPTS) failed++;
      else skipped++;
      // One-line drop record (Phase 9 style).
      console.log(
        `summarize drop id=${row.id} attempt=${next}/${MAX_ATTEMPTS} reason="${reason}"`,
      );
    };

    try {
      const fullText = await fetchBody(supabaseUrl, bodySecret, row.id);
      if (!fullText) {
        // No readable body — not "full text present", so nothing to summarise.
        await markFailure("empty body");
        return;
      }
      const { hook, summary, model } = await summarise(
        openrouterKey,
        fullText,
        `${row.title ?? ""}`,
      );

      const { error: writeError } = await supabase
        .from("articles")
        .update({
          ai_summary: summary,
          ai_summary_hook: hook,
          ai_summary_model: model,
          ai_summary_status: "done",
          ai_summarized_at: new Date().toISOString(),
        })
        .eq("id", row.id);
      if (writeError) {
        await markFailure(`db write: ${writeError.message}`);
        return;
      }
      done++;
    } catch (e) {
      await markFailure(`${e}`);
    }
  });

  const report = { selected: batch.length, done, failed, skipped };
  console.log(`summarize run ${JSON.stringify(report)}`);
  return Response.json(report);
});
