-- Bite · Phase 19: re-queue the articles a stale threshold stranded.
--
-- Run in the SQL editor AFTER redeploying summarize-articles:
--   supabase functions deploy summarize-articles --no-verify-jwt
--
-- ---------------------------------------------------------------------------
-- WHAT THIS FIXES, AND HOW WE KNOW
--
-- 729 articles — 25% of the entire pool — carried ai_summary_status='failed'
-- and were therefore invisible to every reader, because get_personalized_feed
-- has gated on the bite since migration 0020. They were audited row by row
-- against the live table:
--
--   failed rows                              729
--   failed because the description was thin  729   (100%)
--   failed for any other reason                0
--
-- Not a flaky model, not a rate limit, not a bad prompt: one constant.
-- summarize-articles refused to summarise any description under 160
-- characters, and the median failed description was 116.
--
-- The 160 was correct WHEN IT WAS WRITTEN (Phase 14). Its stated justification
-- was "the card falls back to the snippet, which reads the same" — so
-- declining to summarise a thin description cost the reader nothing, they saw
-- the publisher's description instead. Migration 0020 then put the bite on the
-- card face and made a bite-less row unrenderable. That deleted the fallback.
-- The threshold kept measuring against it for three phases.
--
-- The cost landed unevenly, because a short RSS description is a house style
-- rather than a random event:
--
--   aljazeera 121 · cnbc 110 · independent 100 · skynews 88 · espn 82
--   wired 56 · thehindu 56 · csmonitor 45 · sciencenews 27 · npr 19
--
-- Those ten publishers were not under-performing in the recommender. They were
-- being deleted from the deck before ranking ever saw them.
--
-- ---------------------------------------------------------------------------
-- WHAT THIS DOES
--
-- The function now floors at 60 characters and separates "permanently
-- ineligible" from "failed". This migration replays that distinction over the
-- rows the old rule already parked, so the backlog is corrected rather than
-- only new articles benefiting.
--
--   >= 60 chars  ->  status/attempts reset to null/0, re-enters the queue and
--                    is summarised on the next cron tick.
--   <  60 chars  ->  'skipped'. Genuinely headline-only; a bite would be
--                    padding. Terminal either way, but it stops claiming to be
--                    a failure, which keeps `failed` meaning something.
--
-- Nothing is deleted and no existing bite is touched: rows with a summary are
-- 'done' and are not matched by either statement.
--
-- Drain rate: summarize-articles runs at :05 and :35 (48 runs/day) with
-- BATCH_SIZE=25, under a ceiling this phase raises from 200 to 600/day. The
-- re-queued backlog plus the ~192/day of new articles clears in about a day
-- and a half, at roughly $0.10 of model spend in total.
-- ---------------------------------------------------------------------------

begin;

-- Report the before-state into the migration log, so applying this is also a
-- measurement rather than an act of faith.
do $$
declare
  v_failed    integer;
  v_requeue   integer;
  v_ineligible integer;
begin
  select count(*) into v_failed
    from public.articles where ai_summary_status = 'failed';
  select count(*) into v_requeue
    from public.articles
   where ai_summary_status = 'failed'
     and length(btrim(coalesce(snippet, ''))) >= 60;
  select count(*) into v_ineligible
    from public.articles
   where ai_summary_status = 'failed'
     and length(btrim(coalesce(snippet, ''))) < 60;
  raise notice 'phase19 requeue: failed=% requeue=% ineligible=%',
    v_failed, v_requeue, v_ineligible;
end $$;

-- Genuinely headline-only. Named honestly, not retried.
update public.articles
   set ai_summary_status = 'skipped'
 where ai_summary_status = 'failed'
   and length(btrim(coalesce(snippet, ''))) < 60;

-- Everything else goes back in the queue with a clean slate. attempts is reset
-- as well as status: the three attempts these rows burned were all spent on the
-- same rejected length check, so carrying them forward would park each row as
-- 'failed' again on its first real attempt under the new rule.
update public.articles
   set ai_summary_status   = null,
       ai_summary_attempts = 0
 where ai_summary_status = 'failed'
   and length(btrim(coalesce(snippet, ''))) >= 60;

commit;

-- ---------------------------------------------------------------------------
-- VERIFY (run after the next couple of cron ticks; expect done to climb and
-- the null bucket to drain toward zero):
--
--   select ai_summary_status, count(*)
--     from public.articles group by 1 order by 2 desc;
--
--   select p.id, count(*) filter (where a.ai_summary is not null) as with_bite,
--          count(*) as total
--     from public.articles a join public.publishers p on p.id = a.publisher_id
--    where a.created_at > now() - interval '7 days'
--    group by 1 order by 3 desc;
-- ---------------------------------------------------------------------------
