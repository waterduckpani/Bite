// Bite · Phase 13: story-tracker matching worker.
//
// Assigns newly ingested articles to users' story trackers, HYBRID on Guardian
// tags AND embedding (never embedding alone — pure vector similarity drifts
// toward "vaguely related topic" rather than "same developing story"; the
// structured tags are the stronger same-story signal, the embedding catches
// related coverage tagged differently). The scoring + thresholds live here as
// the single source of truth; the heavy set-based work (pgvector cosine, the
// inserts, optional centroid drift) runs in the run_tracker_matching RPC.
//
// PHASE 14 — the no-tag path. Publisher RSS articles have no Guardian tags, so
// hybrid scoring caps out at W_EMBED (0.4), below MATCH_THRESHOLD (0.55): left
// alone, no RSS article could EVER match a tracker, and nothing would error —
// the timelines would just quietly stop growing. The same trap runs the other
// way for trackers seeded FROM an RSS article, whose tag_set is empty.
//
// So tag overlap is only scored when BOTH sides carry tags. Otherwise the RPC
// falls back to a pure-embedding score judged against MATCH_THRESHOLD_NOTAG,
// which is higher precisely because cosine alone is the weaker signal. Every
// match logs which path produced it so the two thresholds tune independently.
//
// Kept logically SEPARATE from ingestion so it can be re-run independently:
// hitting this function re-runs matching over the recent window, and every
// insert is idempotent (unique on tracker_id, article_id).
//
// Invoked with an empty POST body by the pg_cron sweep (bite-match-trackers,
// at :15/:45 — after ingest at :00/:30 and summarise at :05/:35, so matched
// articles already carry embeddings + bites).
//
// Deploy with --no-verify-jwt; access is gated by the MATCH_SECRET header
// (set via `supabase secrets set`, matched by the vault secret the database
// caller reads).

import { createClient } from "jsr:@supabase/supabase-js@2";

// -- Tunable matching config (one place) ------------------------------------
// Tune MATCH_THRESHOLD against real matches via the per-match logs below.
const W_TAG = 0.6; // tag-overlap weight in the blended score
const W_EMBED = 0.4; // embedding-similarity weight
const MATCH_THRESHOLD = 0.55; // hybrid path: insert when blended score >= this
// Embedding-only path (either side has no tags — RSS articles, RSS-seeded
// trackers). Compared against RAW cosine, not a blend, so it is NOT on the
// same scale as MATCH_THRESHOLD and must be tuned separately from the
// path=embed_only log lines.
//
// TUNED AGAINST REAL DATA 2026-07-27, on a tracker seeded from a Guardian
// story about the "Cockroach" protests, over a 229-article publisher pool:
//
//     bar    matches   share of pool
//     0.75      195         85%      <- the initial guess. Unusable.
//     0.80       84         37%
//     0.84       21          9%      <- admits an unrelated J&K column
//     0.86        7          3%      <- exactly the same-story cluster
//     0.88        2          —
//
// gte-small puts ANY two same-topic news stories around 0.84, so the useful
// signal lives in a narrow band above that. 0.86 keeps the resignation, the
// Jantar Mantar coverage and the Bihar follow-ups while cutting a column about
// Jammu and Kashmir that scored 0.844.
//
// CAVEAT: tuned on ONE tracker, on an unusually well-covered national story.
// A quieter story's genuine follow-ups may sit lower. Re-check against a
// second tracker before trusting this generally; the path=embed_only log
// lines carry the scores needed to do it.
const MATCH_THRESHOLD_NOTAG = 0.86;
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
    p_w_tag: W_TAG,
    p_w_embed: W_EMBED,
    p_threshold: MATCH_THRESHOLD,
    p_threshold_notag: MATCH_THRESHOLD_NOTAG,
    p_window_hours: WINDOW_HOURS,
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
    tag_score: number;
    embed_score: number;
    match_path: string;
  }>;

  // Phase 9 logging style: one line per match, so both thresholds can be tuned
  // from real data without guessing. Score is broken into its tag/embed parts,
  // and `path` says which threshold judged it.
  for (const m of rows) {
    console.log(
      `[match-trackers] tracker=${m.tracker_id} article=${m.article_id}` +
        ` path=${m.match_path} score=${m.match_score.toFixed(3)}` +
        ` tag=${m.tag_score.toFixed(3)} embed=${m.embed_score.toFixed(3)}`,
    );
  }

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

  const byPath = rows.reduce<Record<string, number>>((acc, m) => {
    acc[m.match_path] = (acc[m.match_path] ?? 0) + 1;
    return acc;
  }, {});
  console.log(
    `[match-trackers] window=${WINDOW_HOURS}h threshold=${MATCH_THRESHOLD}` +
      ` thresholdNoTag=${MATCH_THRESHOLD_NOTAG} drift=${CENTROID_DRIFT}` +
      ` matched=${rows.length} byPath=${JSON.stringify(byPath)}` +
      ` pruned=${pruned} (cap ${TRACKER_MAX_ARTICLES}/tracker)`,
  );

  return Response.json({ matched: rows.length, by_path: byPath, pruned });
});
