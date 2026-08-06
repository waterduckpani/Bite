-- Bite · Phase 14 fix: stop re-probing publishers that always wall us.
-- Run in the SQL editor after 0014, then redeploy ingest-rss.
--
-- Two problems this addresses, both found on the first live run:
--
-- 1. full_text_allowed came back TRUE for all eight publishers, when
--    qualification said only Scroll and DW should be. ingest-rss was testing a
--    hardcoded placeholder path ("/article/") against robots.txt, which almost
--    nothing disallows. The fix (in ingest-rss) is to test a REAL article path
--    sampled from the publisher's own feed — the same thing
--    tools/qualify_publisher.dart does.
--
-- 2. robots.txt allowing a path does NOT mean the page is served to us. The
--    Hindu, New Indian Express and CS Monitor all allow our crawler and then
--    return a paywall. The wall detection correctly aborted every time, so no
--    unlicensed text was ever stored — but we kept asking, every single run,
--    forever. That is a request a publisher would see in their logs and
--    reasonably object to.
--
-- So a publisher that walls us repeatedly gets backed off. This is the
-- opposite of circumvention: it is taking "no" for an answer and remembering
-- it. A successful fetch resets the counter, so a publisher that drops its
-- paywall is picked back up automatically.

alter table public.publishers
  -- Consecutive body fetches that ended in a wall or a refusal. Reset to 0 by
  -- any successful fetch.
  add column if not exists body_wall_streak    integer not null default 0,
  -- Why we last backed off, for the operator (and for answering a publisher
  -- who asks what we saw).
  add column if not exists body_wall_reason    text,
  add column if not exists body_wall_last_at   timestamptz;

comment on column public.publishers.body_wall_streak is
  'Consecutive walled/refused body fetches. At or above BODY_WALL_BACKOFF in '
  'ingest-rss, the body fetch is skipped entirely and the publisher is treated '
  'as description-only. Any successful fetch resets it to 0.';

-- Correct the values the placeholder-path bug wrote. ingest-rss re-derives
-- these on its next robots refresh from a real article path, but the paywalled
-- three would otherwise keep their wrong `true` until then.
--
-- These four are description-only per docs/publishers/: robots may allow the
-- path, but the page itself is paywalled.
update public.publishers
   set full_text_allowed = false
 where id in ('thehindu', 'newindianexpress', 'csmonitor', 'aljazeera');

-- Deccan Herald and Reason carry full content in the feed itself, so no body
-- fetch is ever needed for them.
update public.publishers
   set full_text_allowed = false
 where id in ('deccanherald', 'reason');

-- Scroll and DW keep full_text_allowed = true: robots allows their article
-- paths AND an honest fetch returned a real body during qualification.
