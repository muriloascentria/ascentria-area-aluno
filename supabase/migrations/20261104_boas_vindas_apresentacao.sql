-- Boas-vindas na comunidade dos mentorados: aviso no sino + 20 pontos por apresentação recebida com comentário.
-- Vale para apresentações publicadas a partir de 04/11/2026 14h30 (Brasília).
CREATE OR REPLACE FUNCTION public.comunidade_pendencias_detalhe()
 RETURNS TABLE(post_id bigint, course_id text, audience text, motivo text, quem_id uuid, quem_nome text, texto text, quando timestamp with time zone)
 LANGUAGE sql STABLE SET search_path TO 'public'
AS $function$
  select p.id, p.course_id, p.audience, 'duvida'::text, p.author_id, a.name, left(p.text, 140), p.created_at
  from community_posts p join profiles a on a.id = p.author_id
  where is_staff() and p.type = 'duvida'
    and not exists (select 1 from community_comments c join profiles x on x.id = c.author_id where c.post_id = p.id and x.role = 'staff')
  union all
  select p.id, p.course_id, p.audience, 'resposta'::text, uc.author_id, a.name, left(uc.text, 140), uc.created_at
  from community_posts p
  join lateral (select c.* from community_comments c where c.post_id = p.id and c.author_id <> auth.uid() order by c.created_at desc limit 1) uc on true
  join profiles a on a.id = uc.author_id
  where p.author_id = auth.uid() and p.notify_author
  union all
  select p.id, p.course_id, p.audience, 'resposta'::text, uc.author_id, a.name, left(uc.text, 140), uc.created_at
  from community_posts p
  join lateral (select c.* from community_comments c where c.post_id = p.id and c.author_id <> auth.uid() order by c.created_at desc limit 1) uc on true
  join profiles a on a.id = uc.author_id
  where p.author_id <> auth.uid()
    and exists (select 1 from community_comments c where c.post_id = p.id and c.author_id = auth.uid() and c.notify_author)
  union all
  select p.id, p.course_id, p.audience, 'mencao'::text,
    coalesce(cm.author_id, p.author_id), a.name, left(coalesce(cm.text, p.text), 140), m.created_at
  from community_mentions m
  join community_posts p on p.id = m.post_id
  left join community_comments cm on cm.id = m.comment_id
  join profiles a on a.id = coalesce(cm.author_id, p.author_id)
  where m.user_id = auth.uid() and not m.seen
  union all
  -- nova apresentação na comunidade dos mentorados: convida os outros mentorados a dar boas-vindas
  select p.id, p.course_id, p.audience, 'boasvindas'::text, p.author_id, a.name, left(p.text, 140), p.created_at
  from community_posts p join profiles a on a.id = p.author_id
  where p.type = 'apresentacao' and p.audience = 'mentorado' and p.course_id is null
    and p.author_id <> auth.uid()
    and p.created_at >= timestamptz '2026-11-04 17:30:00+00'
    and p.created_at > now() - interval '14 days'
    and exists (select 1 from profiles me where me.id = auth.uid() and me.role = 'aluno' and coalesce(me.tier,'mentorado') <> 'curso')
    and not exists (select 1 from community_comments c where c.post_id = p.id and c.author_id = auth.uid());
$function$;

CREATE OR REPLACE VIEW public.student_points AS
 SELECT p.id AS student_id,
    round((COALESCE(posts.conquistas, 0::bigint) * 600)::numeric + COALESCE(posts.mural_posts, 0::bigint)::numeric * 0.01 + COALESCE(posts.aula_posts, 0::bigint)::numeric * 0.01 + COALESCE(comments.mural_comments, 0::bigint)::numeric * 0.01 + COALESCE(comments.aula_comments, 0::bigint)::numeric * 0.01 + COALESCE(likes.mural_likes, 0::bigint)::numeric * 0.01 + COALESCE(likes.aula_likes, 0::bigint)::numeric * 0.01 + (COALESCE(mcs.dashboard_checks, 0::bigint) * 10)::numeric + (COALESCE(ci.metas_checks, 0::bigint) * 10)::numeric + (LEAST(COALESCE(posts.apresentacoes, 0::bigint), 1::bigint) * 10)::numeric + (COALESCE(bv.boas_vindas, 0::bigint) * 20)::numeric, 2) AS total_points,
    COALESCE(posts.conquistas, 0::bigint) AS conquistas_count,
    COALESCE(posts.mural_posts, 0::bigint) AS mural_posts_count,
    COALESCE(posts.aula_posts, 0::bigint) AS aula_posts_count,
    COALESCE(comments.mural_comments, 0::bigint) AS mural_comments_count,
    COALESCE(comments.aula_comments, 0::bigint) AS aula_comments_count,
    COALESCE(likes.mural_likes, 0::bigint) AS mural_likes_count,
    COALESCE(likes.aula_likes, 0::bigint) AS aula_likes_count,
    COALESCE(mcs.dashboard_checks, 0::bigint) AS dashboard_checks_count,
    COALESCE(ci.metas_checks, 0::bigint) AS metas_checks_count,
    LEAST(COALESCE(posts.apresentacoes, 0::bigint), 1::bigint) AS apresentacao_count,
    COALESCE(bv.boas_vindas, 0::bigint) AS boas_vindas_count
   FROM profiles p
     LEFT JOIN ( SELECT community_posts.author_id,
            count(*) FILTER (WHERE community_posts.type = 'conquista'::text) AS conquistas,
            count(*) FILTER (WHERE community_posts.type = 'apresentacao'::text) AS apresentacoes,
            count(*) FILTER (WHERE community_posts.type <> 'conquista'::text AND community_posts.type <> 'apresentacao'::text AND community_posts.course_id IS NULL) AS mural_posts,
            count(*) FILTER (WHERE community_posts.type <> 'conquista'::text AND community_posts.type <> 'apresentacao'::text AND community_posts.course_id IS NOT NULL) AS aula_posts
           FROM community_posts
          GROUP BY community_posts.author_id) posts ON posts.author_id = p.id
     LEFT JOIN ( SELECT cc.author_id,
            count(*) FILTER (WHERE cp.course_id IS NULL) AS mural_comments,
            count(*) FILTER (WHERE cp.course_id IS NOT NULL) AS aula_comments
           FROM community_comments cc
             JOIN community_posts cp ON cp.id = cc.post_id
          GROUP BY cc.author_id) comments ON comments.author_id = p.id
     LEFT JOIN ( SELECT cl.student_id,
            count(*) FILTER (WHERE cp.course_id IS NULL) AS mural_likes,
            count(*) FILTER (WHERE cp.course_id IS NOT NULL) AS aula_likes
           FROM community_likes cl
             JOIN community_posts cp ON cp.id = cl.post_id
          GROUP BY cl.student_id) likes ON likes.student_id = p.id
     LEFT JOIN ( SELECT module_checklist_state.student_id,
            count(*) FILTER (WHERE module_checklist_state.checked) AS dashboard_checks
           FROM module_checklist_state
          GROUP BY module_checklist_state.student_id) mcs ON mcs.student_id = p.id
     LEFT JOIN ( SELECT checklist_items.student_id,
            count(*) FILTER (WHERE checklist_items.status = 'Concluída'::text) AS metas_checks
           FROM checklist_items
          GROUP BY checklist_items.student_id) ci ON ci.student_id = p.id
     LEFT JOIN ( SELECT cc.author_id,
            count(DISTINCT cp.id) AS boas_vindas
           FROM community_comments cc
             JOIN community_posts cp ON cp.id = cc.post_id
          WHERE cp.type = 'apresentacao' AND cp.audience = 'mentorado' AND cp.course_id IS NULL
            AND cp.author_id <> cc.author_id
            AND cp.created_at >= timestamptz '2026-11-04 17:30:00+00'
          GROUP BY cc.author_id) bv ON bv.author_id = p.id
  WHERE p.role = 'aluno'::text;
