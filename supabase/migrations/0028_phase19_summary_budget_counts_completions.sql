-- Bite · Phase 19.1: the daily AI budget counts summaries, not intentions.
--
-- Run in the SQL editor, then redeploy:
--   supabase functions deploy summarize-articles --no-verify-jwt
--
-- ===========================================================================
-- CORRECTION, WRITTEN AFTER THIS MIGRATION WAS APPLIED. READ THIS FIRST.
--
-- The diagnosis below — that leaked reservations had saturated the daily
-- counter and were wedging the pipeline — IS WRONG. It is left in place rather
-- than deleted, because a migration that quietly rewrites its own reasoning is
-- worse than one that shows it.
--
-- The ledger, read straight after this ran, refutes it outright:
--
--   day          summaries_done      bites actually written that day
--   2026-08-21   193                 192
--   2026-08-20   172                 (same shape)
--
-- Against a 600 cap. If reservations had been leaking, summaries_done would
-- have run far AHEAD of completions and pinned itself to 600. Instead it
-- tracked completions to within one. Nothing leaked, the budget was never
-- close to exhausted, and the early return on `granted === 0` was therefore
-- never being taken. The mechanism described below was not occurring.
--
-- WHAT WAS ACTUALLY HAPPENING: nothing was wrong. Migration 0025 had been
-- applied only minutes before the measurement that prompted this file. Before
-- that moment the 741 stranded rows still carried status='failed' and were
-- correctly excluded from selection — so between six-hourly ingests the queue
-- was genuinely EMPTY, and the runs that "did nothing" were runs with nothing
-- to do. The five-hour silences that looked like a stall were an idle worker
-- behaving exactly as designed.
--
-- The error was reading a fresh backlog as a stuck one: 601 rows had been
-- eligible for a few minutes, not two days, and had simply not had a tick yet.
-- The very next tick after this file was applied wrote 25 of them, and the
-- backlog began draining at 25/tick — which it would have done regardless.
--
-- WHY THIS MIGRATION IS KEPT ANYWAY, on its own merits rather than the false
-- ones below: the reservation leak it removes is real but LATENT, not
-- observed. A run that dies between claiming and refunding does burn those
-- slots until UTC midnight, with nothing able to reconcile them. That has not
-- happened here — runs finish in well under a minute against a limit measured
-- in minutes — so this is defence against a failure that has never occurred,
-- bought at the cost of the atomic guarantee described under THE TRADE.
--
-- That is a genuine trade and a close one. It was made here on a mistaken
-- premise, and if the atomic reservation is worth more to you than crash
-- tolerance, reverting to 0013's claim_summary_slots is correct and costs
-- nothing but a redeploy.
-- ===========================================================================
--
-- ---------------------------------------------------------------------------
-- THE SYMPTOM (as diagnosed at the time — see the correction above)
--
-- Migration 0025 re-queued 696 stranded articles. Two days later 601 of them
-- were still sitting at ai_summary_status = null with ai_summary_attempts = 0
-- — never selected, never attempted, never failed. Meanwhile NEW articles were
-- being summarised perfectly: 192/day, exactly the ingest rate, up from ~135
-- before 0025. So the summariser was alive and correct, and simply never got
-- to the backlog.
--
-- The give-away was the clock. Bites are only ever written in the 15-45
-- minutes following a 6-hourly ingest:
--
--   00:35 (25)  01:05 (23)   ...silence for five hours...
--   06:35 (25)  07:05 (23)   ...silence for five hours...
--   12:35 (25)  13:05 (22)  13:35 (1)
--   18:35 (25)  19:05 (23)
--
-- The cron fires every 30 minutes (48/day, '5,35 * * * *', never unscheduled).
-- So ~37 runs a day were doing nothing while 601 eligible rows waited. In
-- summarize-articles there is exactly ONE path that consumes a run without
-- touching a single row: the early return when the day's budget reports as
-- exhausted. Rows untouched, attempts untouched, nothing left pending — which
-- is precisely the state those 601 rows were in.
--
-- ---------------------------------------------------------------------------
-- THE CAUSE: A RESERVATION LEDGER THAT CANNOT SELF-CORRECT
--
-- ai_usage_daily.summaries_done was never a count of summaries. It was a count
-- of RESERVATIONS:
--
--   claim_summary_slots()   adds p_want   (= how many rows the run selected)
--   release_summary_slots() subtracts, but ONLY when called from inside a run
--                           that reached its own end
--
-- Every run reserves a full batch — 25 — the moment it finds 25 candidates,
-- before a single token is spent. The reservation is only ever reconciled by
-- the run that made it. Nothing else can lower the counter: no timeout, no
-- reconciliation pass, no expiry. If a run reserves and then does not reach
-- its refund line, those slots are gone for the rest of the UTC day.
--
-- With an empty backlog this is invisible: each run finds only the handful of
-- genuinely new rows, reserves that handful, and spends it. With a 601-row
-- backlog every run reserves the full 25 whether or not it produces anything,
-- so the counter races the ceiling and sticks — and the more work there is to
-- do, the faster the system stops doing it. That is exactly backwards.
--
-- It also explains why raising DAILY_SUMMARY_CAP from 200 to 600 earlier in
-- Phase 19 did not free the backlog. Raising the ceiling on a counter that is
-- measuring the wrong thing buys a few more runs and then stops in the same
-- place. The cap was never the problem; what it was counting was.
--
-- ---------------------------------------------------------------------------
-- THE FIX
--
-- Count completions. `summaries_done` now only ever increases when a bite is
-- actually written, so the number in the table is the number a human would
-- count by hand, and the daily ceiling means what its name says.
--
--   claim_summary_slots()    -> ASKS how much room is left. Reads, does not
--                               write. Same signature, so the call site keeps
--                               working; same clamp to p_want.
--   record_summaries_done()  -> NEW. Called once at the end of a run with the
--                               number of bites actually written.
--   release_summary_slots()  -> kept as a no-op-safe function so an older
--                               deployed copy of the worker cannot error, but
--                               nothing calls it any more.
--
-- THE TRADE, STATED PLAINLY. Reserving up front made two overlapping runs
-- impossible to double-spend. Asking instead of reserving gives that up: two
-- runs starting in the same instant could each see room and together exceed
-- the cap by at most one batch (25 summaries, about $0.004). In exchange, the
-- ledger cannot drift upward, cannot leak, and cannot wedge the pipeline shut
-- — and a run that dies costs nothing rather than costing 25 slots until
-- midnight. A bounded, self-correcting overshoot beats an unbounded,
-- self-inflicted stall. The runs are 30 minutes apart and take under a minute,
-- so the overlap this protects against is close to hypothetical anyway, while
-- the stall it prevents has already happened.
-- ---------------------------------------------------------------------------

begin;

-- Ask, don't reserve. Read-only: no insert, no update, no side effect.
create or replace function public.claim_summary_slots(
  p_want      integer,
  p_daily_cap integer)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select greatest(0, least(
    greatest(0, p_want),
    p_daily_cap - coalesce(
      (select summaries_done from public.ai_usage_daily
        where day = (now() at time zone 'utc')::date), 0)
  ));
$$;

comment on function public.claim_summary_slots(integer, integer) is
  'How many more summaries may be written today, clamped to p_want. READ ONLY '
  'as of migration 0028 — it no longer reserves. Reservations could leak when '
  'a run did not reach its refund, and a leaked reservation wedged the '
  'pipeline until UTC midnight. Completions are recorded by '
  'record_summaries_done() once the work is actually done.';

-- Record what was actually produced.
create or replace function public.record_summaries_done(p_n integer)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.ai_usage_daily (day, summaries_done)
  values ((now() at time zone 'utc')::date, greatest(0, p_n))
  on conflict (day) do update
    set summaries_done = public.ai_usage_daily.summaries_done + greatest(0, p_n),
        updated_at     = now();
$$;

comment on function public.record_summaries_done(integer) is
  'Adds the number of bites actually written by one run to today''s ledger. '
  'The only thing that increments summaries_done as of migration 0028.';

revoke all on function public.claim_summary_slots(integer, integer)
  from public, anon, authenticated;
revoke all on function public.record_summaries_done(integer)
  from public, anon, authenticated;

-- Clear today's leaked reservations so the backlog starts draining on the next
-- tick rather than at midnight. Safe: the figure it replaces was reservations,
-- not spend, and the token columns that back the real cost report are
-- untouched.
update public.ai_usage_daily
   set summaries_done = 0, updated_at = now()
 where day = (now() at time zone 'utc')::date;

commit;

-- ---------------------------------------------------------------------------
-- VERIFY
--
-- Within an hour (two cron ticks) the backlog should be visibly draining, and
-- runs should no longer be silent between ingest cycles:
--
--   select ai_summary_status, count(*)
--     from public.articles group by 1 order by 2 desc;
--
--   select day, summaries_done, input_tokens, output_tokens
--     from public.ai_usage_daily order by day desc limit 5;
--
-- summaries_done should now track the number of bites written that day, and
-- should agree with:
--
--   select count(*) from public.articles
--    where ai_summarized_at >= (now() at time zone 'utc')::date;
-- ---------------------------------------------------------------------------
