// Bite · Phase 10 (AI summaries) · reworked in Phase 14.
//
// Reads whatever article text Bite is entitled to hold and writes a Bite-voice
// hook + short summary back onto the article row (ai_summary / ai_summary_hook),
// so the swipe deck can show a summary without the client ever calling a model
// or holding the model key. Kept separate from ingestion so it retries and
// scales on its own cron.
//
// LICENSING GATE — read before touching the selection query below. We only
// summarise text Bite is entitled to hold, and since Phase 15.1 there is
// exactly ONE kind: PUBLISHER RSS rows (publisher_id is not null). Their text
// is either the body ingest-rss was permitted to fetch (stored in rss_bodies,
// service role only) or — often — just the feed's own description. These are
// LINK-OUT ONLY, and summarising is not permission to render their body
// anywhere.
//
// The Guardian full-body path is GONE. It ran through the guardian-body proxy
// on the licensed Open Platform API; that API and that function no longer
// exist. Guardian is now an ordinary RSS publisher and goes through the RSS
// path like everyone else.
//
// Rows with no publisher (legacy Guardian-API rows, mock) match nothing and
// are never selected. They keep whatever bite they already have and age out.
//
// full_text_available is NOT consulted here any more. Phase 15.1 decoupled it:
// it routes nothing (every article link-outs) and it selects nothing. Which
// input a row gets — body or description — is decided below from what is
// actually in rss_bodies.
//
// PHASE 14 CHANGES:
//   - Hard 80-word cap enforced IN CODE after generation, not merely requested
//     in the prompt. A model that ignores the instruction cannot produce an
//     over-long bite.
//   - The bite must INFORM, NOT COMPLETE. Bite is a referrer: the reader should
//     learn what happened and why it matters, and be able to decide whether to
//     go read the original. Extended quotes, granular detail and analysis
//     belong at the source.
//   - Two input modes, one output shape ('body' | 'description'), recorded per
//     row in summary_input_mode so quality can be compared later.
//   - DAILY_SUMMARY_CAP is a GLOBAL daily ceiling across all sources, enforced
//     by claiming slots in the database before spending anything.
//
// Existing bites are NOT regenerated: the status gate only selects rows that
// are null/pending.
//
// Deploy with --no-verify-jwt; access is gated by x-summarize-secret.
//   supabase secrets set --env-file supabase/functions/.env.secrets
//   supabase functions deploy summarize-articles --no-verify-jwt
// Secrets: OPENROUTER_KEY, SUMMARIZE_SECRET. SUPABASE_URL /
// SUPABASE_SERVICE_ROLE_KEY are injected.

import { createClient } from "jsr:@supabase/supabase-js@2";
import {
  SUMMARY_MAX_WORDS,
  truncateToWords,
  wordCount,
} from "../_shared/words.ts";

// -- Config (one place) -----------------------------------------------------
// Model note: news summarisation is light work — default to the bottom of the
// price ladder. VERIFY THESE SLUGS against https://openrouter.ai/api/v1/models
// before deploying; OpenRouter slugs drift. All slugs below were confirmed
// valid on 2026-07-16.
//
// CAVEAT: OpenRouter validates EVERY id in the `models` array up front — a
// single invalid slug 400s the whole request (even if the primary is fine),
// so this is not a "graceful degradation" list; keep every entry valid.
// provider.sort="price" still routes to the cheapest provider per model.
//
// The primary model is held CONSTANT so cost is predictable; the fallbacks are
// same-tier-or-cheaper and only fire when the primary is unavailable.
const SUMMARY_MODEL = "google/gemini-3.1-flash-lite";
const FALLBACK_MODELS = [
  "google/gemini-2.5-flash-lite",
  "deepseek/deepseek-chat",
];

/// GLOBAL daily ceiling across ALL sources — not per-feed. Claimed from
/// public.ai_usage_daily before any tokens are spent, so two overlapping runs
/// cannot both spend the last of the day's budget.
///
///   Cost per bite ~ 1500 in + 200 out ~ $0.0007
///   200/day  ->  ~$0.14/day  ->  ~$4/month
const DAILY_SUMMARY_CAP = 200;

const BATCH_SIZE = 25;
const CONCURRENCY = 4;
const MAX_ATTEMPTS = 3;
const INPUT_CHAR_CAP = 6000; // ~1.5k tokens of leading body text
const OUTPUT_MAX_TOKENS = 220; // one hook + <=80 words, with headroom

/// Below this, a description is too thin to summarise into anything better
/// than itself — the card falls back to the snippet, which reads the same.
const MIN_DESCRIPTION_CHARS = 160;

type InputMode = "body" | "description";

// -- Prompt -----------------------------------------------------------------
// Two input modes, ONE output shape. The mode changes what the model is given,
// never what it returns.

const SYSTEM_PROMPT =
  `You write short news summaries for Bite, a news reader that sends readers on to the original article. Produce a summary using ONLY facts stated in the text you are given.

What a Bite summary is for:
- It must INFORM, NOT COMPLETE. The reader should learn what happened and why it matters, and then be able to decide whether they want the full story from the publisher.
- Do NOT include extended quotes, granular detail, statistics beyond the headline figure, or analysis. Those belong in the original article, not here.
- Never imply the reader now has the whole story.

Rules:
- Use only information present in the provided text. Never add facts, context, names, numbers, or background from outside it. If the text is thin, summarise only what is there and stop.
- Neutral and factual. Report what occurred. STRIP the source's framing: remove editorialising, loaded or judgemental adjectives, emotive verbs, and any language that assigns blame, praise or motive that the text does not directly attribute to a named party. If the source says "slammed", write "criticised". If the source calls something "shocking", drop the word.
- Attribute contested claims rather than asserting them ("the ministry said", "according to the report").
- Plain, warm, confident voice. Clear sentences a smart general reader gets instantly. No jargon, no hype, no marketing tone.
- Never clickbait. No teasing, no "find out why", no cliffhangers, no withholding the point. Say what happened.
- Third person, present or past tense as the facts require. No "I", no "we", no addressing the reader.
- The hook is a single punchy line (6–12 words) capturing the core of the story — a plain-spoken headline, not a tease.
- The summary is 2–3 sentences and MUST be no more than ${SUMMARY_MAX_WORDS} words. Shorter is better. Count your words before answering.

Output STRICT JSON and nothing else — no markdown, no code fences, no preamble:
{"hook": "...", "summary": "..."}`;

// -- Summariser (SOURCE-AGNOSTIC) -------------------------------------------
// Pure over its inputs — it never knows or cares where the text came from, so
// it survives source changes untouched. The only thing the mode affects is the
// framing line, because summarising a 200-word description is a different job
// from summarising a 6,000-character body.

interface Usage {
  input: number;
  output: number;
}

/// One chat completion.
///
/// Thinking is pinned to minimal: this is extraction, not reasoning, and
/// reasoning tokens are the easiest way to blow the cost model. The `reasoning`
/// parameter is not accepted by every model/provider combination OpenRouter
/// routes to, though, and a 400 there would fail every summary — so a rejected
/// request is retried ONCE without that field and the fallback is logged.
/// (The retry changes only the reasoning parameter, never the prompt.)
interface ModelResponse {
  model?: string;
  usage?: { prompt_tokens?: number; completion_tokens?: number };
  choices?: { message?: { content?: string } }[];
}

async function callModel(
  openrouterKey: string,
  messages: { role: string; content: string }[],
): Promise<ModelResponse> {
  const send = async (withReasoning: boolean) => {
    const payload: Record<string, unknown> = {
      model: SUMMARY_MODEL,
      models: [SUMMARY_MODEL, ...FALLBACK_MODELS],
      provider: { sort: "price" },
      max_tokens: OUTPUT_MAX_TOKENS,
      temperature: 0.3,
      response_format: { type: "json_object" },
      messages,
    };
    if (withReasoning) {
      payload.reasoning = { effort: "minimal", exclude: true };
    }
    return await fetch("https://openrouter.ai/api/v1/chat/completions", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${openrouterKey}`,
        "HTTP-Referer": "https://bite.app",
        "X-Title": "Bite",
      },
      body: JSON.stringify(payload),
    });
  };

  let res = await send(true);
  if (res.status === 400) {
    const detail = await res.text();
    console.log(
      `summarize: reasoning param rejected (400), retrying without it: ` +
        detail.slice(0, 200),
    );
    res = await send(false);
  }
  if (!res.ok) {
    throw new Error(`OpenRouter HTTP ${res.status}: ${await res.text()}`);
  }
  return await res.json() as ModelResponse;
}

async function summarise(
  openrouterKey: string,
  text: string,
  headline: string,
  mode: InputMode,
  usage: Usage,
): Promise<{ hook: string; summary: string; model: string; capped: boolean }> {
  const body = text.slice(0, INPUT_CHAR_CAP);
  const framing = mode === "body"
    ? `Article:\n${body}`
    : `You are given only the publisher's own short description of this story, not the full article. Summarise strictly what it says — do not infer, extend, or fill gaps.\n\nDescription:\n${body}`;
  const userMessage = `Headline: ${headline}\n\n${framing}`;

  const messages: { role: string; content: string }[] = [
    { role: "system", content: SYSTEM_PROMPT },
    { role: "user", content: userMessage },
  ];

  let hook = "";
  let summary = "";
  let modelUsed = SUMMARY_MODEL;
  let capped = false;

  // Up to two passes: generate, and if the model blew the word cap, ask once
  // for a shorter rewrite. A third failure is truncated in code — we never
  // emit over the cap, whatever the model does.
  for (let pass = 0; pass < 2; pass++) {
    const data = await callModel(openrouterKey, messages);
    usage.input += Number(data?.usage?.prompt_tokens ?? 0);
    usage.output += Number(data?.usage?.completion_tokens ?? 0);

    const content: string = data?.choices?.[0]?.message?.content ?? "";
    modelUsed = data?.model ?? SUMMARY_MODEL;

    const parsed = parseSummary(content);
    if (!parsed) throw new Error("unparseable model output");
    hook = `${parsed.hook ?? ""}`.trim();
    summary = `${parsed.summary ?? ""}`.trim();
    if (!hook || !summary) throw new Error("empty hook or summary");

    if (wordCount(summary) <= SUMMARY_MAX_WORDS) break;

    capped = true;
    if (pass === 0) {
      // One corrective pass, in-conversation so the model sees its own output.
      messages.push({ role: "assistant", content });
      messages.push({
        role: "user",
        content:
          `That summary is ${wordCount(summary)} words, over the ${SUMMARY_MAX_WORDS}-word limit. ` +
          `Rewrite it to ${SUMMARY_MAX_WORDS} words or fewer, keeping the same facts and dropping detail rather than compressing into a run-on sentence. Same strict JSON shape.`,
      });
    }
  }

  // Belt and braces: the cap is a property of what we store, not of what the
  // model agreed to do.
  if (wordCount(summary) > SUMMARY_MAX_WORDS) {
    summary = truncateToWords(summary, SUMMARY_MAX_WORDS);
    capped = true;
  }

  return { hook, summary, model: modelUsed, capped };
}

/// Parse the model output as JSON. If it isn't valid, strip accidental code
/// fences and retry the parse once; still failing counts as a failure.
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

interface Candidate {
  id: string;
  title: string;
  snippet: string;
  publisher_id: string;
  ai_summary_attempts: number;
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

  // Service role: this function owns the ai_summary* columns.
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // Selection gate (see the licensing note at the top): Phase 14 RSS rows
  // only, not yet done/failed, under the retry cap. Freshest first.
  //
  // Rows already marked 'done' are never reselected, which is what guarantees
  // existing bites are not regenerated under a changed prompt.
  const { data: rows, error } = await supabase
    .from("articles")
    .select("id, title, snippet, publisher_id, ai_summary_attempts")
    .not("publisher_id", "is", null)
    .or("ai_summary_status.is.null,ai_summary_status.eq.pending")
    .lt("ai_summary_attempts", MAX_ATTEMPTS)
    .order("created_at", { ascending: false })
    .limit(BATCH_SIZE);
  if (error) {
    return Response.json({ error: error.message }, { status: 500 });
  }
  const candidates = (rows ?? []) as Candidate[];

  // -- Part D3: claim budget BEFORE spending anything -----------------------
  // The cap is global and the claim is atomic, so overlapping runs cannot both
  // spend the day's last slots. When the day is spent we stop and log — the
  // overflow is NOT queued, it is simply not summarised today.
  let granted = 0;
  if (candidates.length > 0) {
    const { data: claimed, error: claimError } = await supabase.rpc(
      "claim_summary_slots",
      { p_want: candidates.length, p_daily_cap: DAILY_SUMMARY_CAP },
    );
    if (claimError) {
      return Response.json({ error: claimError.message }, { status: 500 });
    }
    granted = Number(claimed ?? 0);
  }
  if (granted === 0) {
    console.log(
      `summarize halted: DAILY_SUMMARY_CAP=${DAILY_SUMMARY_CAP} reached` +
        ` (${candidates.length} rows waiting, not queued)`,
    );
    return Response.json({
      selected: 0,
      waiting: candidates.length,
      capped_out: true,
    });
  }

  const batch = candidates.slice(0, granted);
  // Slots claimed for rows we then declined to take back.
  let unusedSlots = granted - batch.length;

  // Claim the batch as pending so an overlapping run doesn't double-summarise.
  // A row left pending by a crash is re-selected next run (attempts untouched).
  if (batch.length) {
    await supabase
      .from("articles")
      .update({ ai_summary_status: "pending" })
      .in("id", batch.map((r) => r.id));
  }

  // RSS body text, where ingest-rss was permitted to fetch it. Absent rows
  // simply fall back to description mode.
  const rssIds = batch.map((r) => r.id);
  const rssBodies = new Map<string, string>();
  if (rssIds.length > 0) {
    const { data: bodyRows } = await supabase
      .from("rss_bodies")
      .select("article_id, body")
      .in("article_id", rssIds);
    for (const row of (bodyRows ?? []) as { article_id: string; body: string }[]) {
      if (row.body?.trim()) rssBodies.set(row.article_id, row.body);
    }
  }

  let done = 0;
  let failed = 0;
  let skipped = 0;
  let cappedCount = 0;
  const byMode: Record<string, number> = { body: 0, description: 0 };
  const usage: Usage = { input: 0, output: 0 };
  const summarisedRssIds: string[] = [];

  await runPool(batch, CONCURRENCY, async (row) => {
    const attempts = row.ai_summary_attempts ?? 0;
    // Roll a failure back to null so it retries next run, unless it has hit
    // the cap — then park it as failed. A failed row still displays fine.
    const markFailure = async (reason: string, refundSlot: boolean) => {
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
      // A row that never reached the model didn't spend its slot.
      if (refundSlot) unusedSlots++;
      console.log(
        `summarize drop id=${row.id} attempt=${next}/${MAX_ATTEMPTS} reason="${reason}"`,
      );
    };

    try {
      // Pick the input. Body wherever we legitimately have one, else the
      // publisher's own description.
      let text: string;
      let mode: InputMode;

      const body = rssBodies.get(row.id);
      if (body && body.length >= 600) {
        text = body;
        mode = "body";
      } else {
        text = `${row.snippet ?? ""}`.trim();
        mode = "description";
        if (text.length < MIN_DESCRIPTION_CHARS) {
          // Too thin to improve on — the card shows the snippet either way.
          await markFailure(`description too thin (${text.length} chars)`, true);
          return;
        }
      }

      const { hook, summary, model, capped } = await summarise(
        openrouterKey,
        text,
        `${row.title ?? ""}`,
        mode,
        usage,
      );
      if (capped) cappedCount++;

      const { error: writeError } = await supabase
        .from("articles")
        .update({
          ai_summary: summary,
          ai_summary_hook: hook,
          ai_summary_model: model,
          ai_summary_status: "done",
          summary_input_mode: mode,
          ai_summarized_at: new Date().toISOString(),
        })
        .eq("id", row.id);
      if (writeError) {
        await markFailure(`db write: ${writeError.message}`, false);
        return;
      }
      byMode[mode]++;
      summarisedRssIds.push(row.id);
      done++;
    } catch (e) {
      await markFailure(`${e}`, false);
    }
  });

  // RSS body text exists only to be summarised. Drop it as soon as that is
  // done rather than waiting for the 48h sweep.
  if (summarisedRssIds.length > 0) {
    await supabase.from("rss_bodies").delete().in("article_id", summarisedRssIds);
  }

  // Hand back what we claimed but never spent, so the day's budget is honest.
  if (unusedSlots > 0) {
    await supabase.rpc("release_summary_slots", { p_n: unusedSlots });
  }
  if (usage.input > 0 || usage.output > 0) {
    await supabase.rpc("record_summary_tokens", {
      p_input: usage.input,
      p_output: usage.output,
    });
  }

  const report = {
    selected: batch.length,
    granted,
    done,
    failed,
    skipped,
    by_mode: byMode,
    word_capped: cappedCount,
    tokens_in: usage.input,
    tokens_out: usage.output,
    daily_cap: DAILY_SUMMARY_CAP,
  };
  console.log(`summarize run ${JSON.stringify(report)}`);
  return Response.json(report);
});
