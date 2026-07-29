// Bite · Phase 13: story-tracker matching worker. Reworked in Phase 15.1.
//
// Assigns newly ingested articles to users' story trackers on EMBEDDING
// SIMILARITY ALONE. The scoring config lives here as the single source of
// truth; the heavy set-based work (pgvector cosine, the ranked insert,
// optional centroid drift) runs in the run_tracker_matching RPC.
//
// WHY THE TAG PATH IS GONE (Phase 15.1)
//
// Matching used to be hybrid: Guardian keyword tags (the strong same-story
// signal) blended with embedding similarity, falling back to embedding alone
// when either side had no tags. The Guardian Open Platform API was the only
// thing that ever wrote articles.tags, and it is gone — Guardian is now an
// ordinary RSS publisher. So every article and every tracker seed has an empty
// tag set, the hybrid branch can never fire, and leaving it in place would be
// dead scoring that still LOOKS live. It was removed rather than left to rot.
//
// What survives is the Phase 14 no-tag path: raw cosine against
// MATCH_THRESHOLD_NOTAG. That is the weaker signal, which is why its bar is
// high — and why the cap below exists.
//
// Kept logically SEPARATE from ingestion so it can be re-run independently:
// hitting this function re-runs matching over the recent window, and every
// insert is idempotent (unique on tracker_id, article_id).
//
// Invoked with an empty POST body by the pg_cron sweep (bite-match-trackers,
// at :15/:45 — after ingest and summarise, so matched articles already carry
// embeddings + bites).
//
// Deploy with --no-verify-jwt; access is gated by the MATCH_SECRET header
// (set via `supabase secrets set`, matched by the vault secret the database
// caller reads).

import { createClient } from "jsr:@supabase/supabase-js@2";

// -- Tunable matching config (one place) ------------------------------------

/// Insert when RAW cosine similarity to the tracker centroid is at least this.
///
/// TUNED AGAINST REAL DATA 2026-07-27, on a tracker seeded from a story about
/// the "Cockroach" protests, over a 229-article publisher pool:
///
///     bar    matches   share of pool
///     0.75      195         85%      <- the initial guess. Unusable.
///     0.80       84         37%
///     0.84       21          9%      <- admits an unrelated J&K column
///     0.86        7          3%      <- exactly the same-story cluster
///     0.88        2          —
///
/// gte-small puts ANY two same-topic news stories around 0.84, so the useful
/// signal lives in a narrow band above that. 0.86 keeps the resignation, the
/// Jantar Mantar coverage and the Bihar follow-ups while cutting a column
/// about Jammu and Kashmir that scored 0.844.
///
/// RE-TUNE ME. This was tuned on ONE tracker, on an unusually well-covered
/// national story — the kind of story where nearly everything genuinely IS
/// the same story. A quieter tracker's real follow-ups may sit lower, and
/// nothing here has been checked against one. Now that the tag path is gone
/// this single number is the ONLY quality gate on what enters a timeline, so
/// re-checking it against a second, quieter tracker is owed work, not
/// optional. The per-match logs below carry the scores needed to do it.
const MATCH_THRESHOLD_NOTAG = 0.86;

/// Ceiling on how many NEW articles one tracker may take in a single run.
///
/// This is the backstop the threshold cannot be. A bar tuned on one story is
/// a guess about every other story, and if it turns out to be a little low the
/// failure mode is not a subtly worse timeline — it is a tracker swallowing
/// the entire window in one pass and reading as a second feed. Capping the
/// per-run intake means a miscalibration costs a few wrong articles per cycle
/// instead of a flooded timeline, and it shows up in the logs (see `held`)
/// while it is still cheap to fix.
///
/// Five is deliberately generous against real coverage volume: a genuinely
/// developing story rarely produces more than five NEW pieces per 30-minute
/// cycle across the whole publisher slate. It bounds the pathological case
/// without touching the normal one.
const MAX_MATCHES_PER_TRACKER_PER_RUN = 5;

const CENTROID_DRIFT = 0.0; // 0 = static centroid; raise cautiously
const MAX_CENTROID_DRIFT = 0.25; // cap: max cosine distance of centroid from seed

// How far back to consider "newly ingested" articles. Wider than the 30-min
// cron gap so a story that finished embedding late still gets picked up on the
// next run; re-scoring an already-matched article is a no-op.
const WINDOW_HOURS = 3;

/// Newest N articles kept per tracker. A tracker is a window onto a developing
/// story, not an archive: past this, older entries fall off as fresh coverage
/// arrives. Mirrored by the LIMIT in get_tracker_articles, so the cap holds on
/// read even between prunes.
const TRACKER_MAX_ARTICLES = 15;

Deno.serve(async (req) => {
  const secret = Deno.env.get("MATCH_SECRET");
  if (secret && req.headers.get("x-match-secret") !== secret) {
    return new Response("forbidden", { status: 403 });
  }

  // Service role: matching writes across every user's trackers, bypassing RLS.
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: matches, error } = await supabase.rpc("run_tracker_matching", {
    p_threshold_notag: MATCH_THRESHOLD_NOTAG,
    p_window_hours: WINDOW_HOURS,
    p_max_per_tracker: MAX_MATCHES_PER_TRACKER_PER_RUN,
    p_drift: CENTROID_DRIFT,
    p_max_drift: MAX_CENTROID_DRIFT,
  });
  if (error) {
    console.log(`[match-trackers] error=${error.message}`);
    return Response.json({ error: error.message }, { status: 500 });
  }

  const rows = (matches ?? []) as Array<{
    tracker_id: string;
    article_id: string;
    match_score: number;
    inserted: boolean;
  }>;

  // Phase 9 logging style: one line per candidate that cleared the bar, so the
  // threshold can be re-tuned from real data without guessing. `held` rows
  // cleared it but lost the per-run ranking — a cap that truncates silently is
  // indistinguishable from a threshold that is working.
  for (const m of rows) {
    console.log(
      `[match-trackers] tracker=${m.tracker_id} article=${m.article_id}` +
        ` ${m.inserted ? "matched" : "held(cap)"}` +
        ` score=${m.match_score.toFixed(3)}`,
    );
  }

  const matched = rows.filter((m) => m.inserted).length;
  const held = rows.length - matched;

  // Roll the window forward: anything past the newest TRACKER_MAX_ARTICLES is
  // dropped, so a heavily-covered story can't turn a timeline into a feed.
  let pruned = 0;
  const { data: prunedCount, error: pruneError } = await supabase.rpc(
    "prune_tracker_timelines",
    { p_max: TRACKER_MAX_ARTICLES },
  );
  if (pruneError) {
    // Never fail the run over pruning — the read-side LIMIT still caps what
    // the user sees; this only reclaims storage and keeps counts honest.
    console.log(`[match-trackers] prune failed: ${pruneError.message}`);
  } else {
    pruned = Number(prunedCount ?? 0);
  }

  console.log(
    `[match-trackers] window=${WINDOW_HOURS}h threshold=${MATCH_THRESHOLD_NOTAG}` +
      ` capPerTracker=${MAX_MATCHES_PER_TRACKER_PER_RUN} drift=${CENTROID_DRIFT}` +
      ` matched=${matched} heldByCap=${held}` +
      ` pruned=${pruned} (cap ${TRACKER_MAX_ARTICLES}/tracker)`,
  );

  return Response.json({
    matched,
    held_by_cap: held,
    pruned,
    threshold: MATCH_THRESHOLD_NOTAG,
    cap_per_tracker: MAX_MATCHES_PER_TRACKER_PER_RUN,
  });
});
