-- Bite · Phase 19: secret rotation, and why no migration may carry a value again.
--
-- ---------------------------------------------------------------------------
-- WHAT HAPPENED
--
-- Migrations 0002, 0003, 0005, 0011 and 0013 each contained the live shared
-- secret for one Edge Function as a plaintext SQL literal. Those migrations
-- were committed to a PUBLIC GitHub repository in Phase 18. The exposure was
-- confirmed rather than assumed: Supabase returns SHA-256 digests from
-- `supabase secrets list`, and the digest of every committed literal matched
-- the digest of the deployed secret exactly. All five were live.
--
-- What that granted an attacker: the functions deploy with --no-verify-jwt and
-- authenticate callers on that header alone, so anyone holding these could
-- invoke embed, summarize-articles, match-trackers, ingest-rss and ingest-news
-- directly — spending OpenRouter budget up to the daily ceiling and writing
-- into the article pool. Not database access (the service-role key was never
-- committed) but not nothing either.
--
-- ---------------------------------------------------------------------------
-- WHAT WAS DONE
--
--   1. All five secrets regenerated (24 random bytes each, `openssl rand`).
--   2. Vault rows updated from a generated, GITIGNORED supabase/*.local.sql —
--      never from a tracked file. See the procedure below.
--   3. Function env updated in the same window:
--        supabase secrets set --env-file supabase/functions/.env.secrets
--   4. The literals replaced with __PLACEHOLDER__ tokens in the working tree
--      AND rewritten out of every commit in git history, then force-pushed.
--   5. The functions changed to FAIL CLOSED when their secret env var is
--      missing (previously `if (secret && ...)` — an unset var disabled the
--      check entirely, so a botched rotation silently opened the door rather
--      than closing it).
--
-- ---------------------------------------------------------------------------
-- THE RULE FROM HERE
--
-- A tracked migration must never contain a secret value. Migrations are the
-- one artefact that is simultaneously (a) required to be committed so the
-- schema is reproducible and (b) a natural place to want to write a secret,
-- which is precisely the trap 0002 fell into. The split is:
--
--   tracked migration   -> the MECHANISM (vault names, which function reads
--                          which, how to verify). No values.
--   supabase/*.local.sql -> the VALUES. Gitignored, generated, run once,
--                          deleted. Regenerate by rotating again.
--
-- ---------------------------------------------------------------------------
-- ROTATING (the procedure, reproducible without this incident's specifics)
--
--   1. Generate. For each of the five names:
--        openssl rand -hex 24
--      Write them to supabase/functions/.env.secrets under the env-var names
--      EMBED_SECRET, INGEST_SECRET, SUMMARIZE_SECRET, MATCH_SECRET,
--      INGEST_RSS_SECRET. That file is gitignored.
--
--   2. Vault side. Write the same values into a supabase/rotate_secrets.local.sql
--      against the VAULT names (they differ from the env-var names — the
--      mapping is the table below) and run it in the SQL editor. Note that
--      vault.create_secret() ERRORS on a name that already exists; rotation
--      goes through vault.update_secret(id, value) after looking the id up.
--
--   3. Function side, in the same window:
--        supabase secrets set --env-file supabase/functions/.env.secrets
--        supabase functions deploy embed              --no-verify-jwt
--        supabase functions deploy summarize-articles --no-verify-jwt
--        supabase functions deploy match-trackers     --no-verify-jwt
--        supabase functions deploy ingest-rss         --no-verify-jwt
--
--      Between steps 2 and 3 the vault sends a secret the functions do not yet
--      accept, so cron invocations 403. This is safe and self-healing: every
--      function finds its own work, so a missed tick is picked up by the next
--      one (:05/:35 summarize, :15/:45 match, 6-hourly ingest). Do not leave
--      the window open for hours; do not "fix" it by reverting one side.
--
--   4. Verify. `supabase secrets list` prints SHA-256 digests, so confirm
--      without revealing anything:
--        printf '%s' "$NEW_VALUE" | shasum -a 256
--      must equal the digest listed for that name. Then confirm the pipeline
--      recovered on the next tick:
--        select max(created_at) from public.articles;
--
--   5. Delete the *.local.sql.
--
-- ---------------------------------------------------------------------------
-- THE MAPPING (vault name -> function env var -> request header)
--
--   embed_fn_secret          -> EMBED_SECRET       -> x-embed-secret
--   ingest_fn_secret         -> INGEST_SECRET      -> x-ingest-secret
--   summarize_fn_secret      -> SUMMARIZE_SECRET   -> x-summarize-secret
--   match_trackers_fn_secret -> MATCH_SECRET       -> x-match-secret
--   ingest_rss_fn_secret     -> INGEST_RSS_SECRET  -> x-ingest-rss-secret
--
-- The paired *_fn_url vault entries are NOT secrets and are unchanged.
-- ---------------------------------------------------------------------------

-- This migration deliberately changes no schema. It exists so the incident,
-- the rule it produced, and the procedure live in the same version-controlled
-- sequence as the mistake — a lesson kept next to the code that taught it.

do $$
declare
  v_missing text[];
begin
  select coalesce(array_agg(n), '{}') into v_missing
    from unnest(array['embed_fn_secret','ingest_fn_secret','summarize_fn_secret',
                      'match_trackers_fn_secret','ingest_rss_fn_secret']) as n
   where not exists (select 1 from vault.secrets s where s.name = n);

  if array_length(v_missing, 1) is null then
    raise notice 'phase19: all five function secrets present in vault';
  else
    raise warning 'phase19: MISSING vault secrets: % — run supabase/rotate_secrets.local.sql',
      array_to_string(v_missing, ', ');
  end if;
end $$;
