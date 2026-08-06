-- Bite · fix: run_tracker_matching aborted with an ambiguous column reference.
-- Run in the SQL editor after 0015. No function redeploy needed.
--
-- THE BUG
--
--   ERROR: 42702 column reference "tracker_id" is ambiguous
--   DETAIL: It could refer to either a PL/pgSQL variable or a table column.
--
-- The function declares out-parameters named tracker_id / article_id /
-- match_score through RETURNS TABLE. Inside the body, the INSERT's
--
--     on conflict (tracker_id, article_id) do nothing
--
-- names those same identifiers, and PL/pgSQL cannot tell whether they mean its
-- own variables or the target table's columns. The whole RETURN QUERY aborts.
--
-- HOW LONG THIS HAS BEEN BROKEN
--
-- This clause is unchanged from the Phase 13 original, so tracker matching has
-- been failing since Phase 13 was deployed — not since Phase 14. It failed
-- QUIETLY: match-trackers returned 500 and logged the error, but the pg_cron
-- job still reported success, because invoke_match_trackers only fires an
-- async net.http_post and never sees the response. Empty tracker timelines
-- read as "no developments yet" rather than as a fault, which is exactly why
-- it survived a phase.
--
-- THE FIX
--
-- `#variable_conflict use_column` tells PL/pgSQL to resolve an ambiguous name
-- to the COLUMN, which is what every such reference in this body means. The
-- function never reads its out-parameters as variables, so this is safe.
--
-- The alternative — renaming the out-parameters — would change the result
-- column names that match-trackers reads, so it would need a coordinated
-- function redeploy. This way the signature is untouched and the deployed
-- Edge Function keeps working as-is.
--
-- Body is otherwise IDENTICAL to 0013.

create or replace function public.run_tracker_matching(
  p_w_tag           double precision,
  p_w_embed         double precision,
  p_threshold       double precision,
  p_threshold_notag double precision,
  p_window_hours    integer,
  p_drift           double precision,
  p_max_drift       double precision)
returns table (
  tracker_id  uuid,
  article_id  text,
  match_score double precision,
  tag_score   double precision,
  embed_score double precision,
  match_path  text)
language plpgsql
security definer
set search_path = public, extensions
as $$
#variable_conflict use_column
begin
  return query
  with candidates as (
    select a.id, a.tags, a.embedding
      from articles a
     where a.source <> 'mock'
       and (a.publisher_id is null
            or exists (select 1 from publishers pb
                        where pb.id = a.publisher_id and pb.enabled))
       and coalesce(a.published_at, a.created_at)
             > now() - make_interval(hours => p_window_hours)
  ),
  scored as (
    select t.id as s_tracker_id,
           c.id as s_article_id,
           (cardinality(t.tag_set) > 0 and cardinality(c.tags) > 0)
             as s_hybrid,
           (case
              when cardinality(t.tag_set) = 0 or cardinality(c.tags) = 0 then 0
              else (
                (select count(*)::double precision
                   from (select unnest(t.tag_set)
                         intersect
                         select unnest(c.tags)) inter)
                / nullif((select count(*)::double precision
                            from (select unnest(t.tag_set)
                                  union
                                  select unnest(c.tags)) uni), 0))
            end) as s_tag,
           (case
              when t.centroid_embedding is not null and c.embedding is not null
              then 1 - (c.embedding <=> t.centroid_embedding)
              else 0
            end) as s_embed
      from story_trackers t
      cross join candidates c
     where not t.muted
       and c.id is distinct from t.seed_article_id
       and not exists (
         select 1 from tracker_articles ta
          where ta.tracker_id = t.id and ta.article_id = c.id)
  ),
  eligible as (
    select s_tracker_id, s_article_id, s_tag, s_embed, s_hybrid,
           (case when s_hybrid
                 then p_w_tag * s_tag + p_w_embed * s_embed
                 else s_embed
            end) as s_score,
           (case when s_hybrid then p_threshold else p_threshold_notag end)
             as s_bar,
           (case when s_hybrid then 'hybrid' else 'embed_only' end) as s_path
      from scored
  ),
  inserted as (
    insert into tracker_articles (tracker_id, article_id, match_score, seen)
    select e.s_tracker_id, e.s_article_id, e.s_score, false
      from eligible e
     where e.s_score >= e.s_bar
    on conflict (tracker_id, article_id) do nothing
    returning tracker_articles.tracker_id   as i_tracker_id,
              tracker_articles.article_id   as i_article_id,
              tracker_articles.match_score  as i_score
  )
  select i.i_tracker_id, i.i_article_id, i.i_score, e.s_tag, e.s_embed, e.s_path
    from inserted i
    join eligible e
      on e.s_tracker_id = i.i_tracker_id and e.s_article_id = i.i_article_id;

  if p_drift > 0 then
    update story_trackers t
       set centroid_embedding = d.new_centroid
      from (
        select st.id as tracker_id,
               st.seed_article_id,
               l2_normalize(
                 (1 - p_drift) * st.centroid_embedding
                 + p_drift * avg(a.embedding))::vector(384) as new_centroid
          from tracker_articles ta
          join story_trackers st on st.id = ta.tracker_id
          join articles a on a.id = ta.article_id
         where ta.matched_at > now() - interval '2 minutes'
           and st.centroid_embedding is not null
           and a.embedding is not null
         group by st.id, st.seed_article_id, st.centroid_embedding
      ) d
     where t.id = d.tracker_id
       and (
         d.seed_article_id is null
         or exists (
           select 1 from articles seed
            where seed.id = d.seed_article_id
              and seed.embedding is not null
              and (1 - (d.new_centroid <=> seed.embedding)) >= (1 - p_max_drift)));
  end if;
end;
$$;

revoke all on function public.run_tracker_matching(
  double precision, double precision, double precision, double precision,
  integer, double precision, double precision)
  from public, anon, authenticated;
