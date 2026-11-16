-- Nova rodada de revisão de política: quem já concordou numa rodada anterior não recebe a pendência.
create or replace function public.tarefas_sync_pendencias()
returns int language plpgsql security definer set search_path = public as $$
declare
  v_murilo uuid := '8b4539a4-4c0e-4be5-a9d3-0b13eba7c8c3';
  v_socios uuid[] := array['8b4539a4-4c0e-4be5-a9d3-0b13eba7c8c3','3ac4f0c3-4db3-4f98-b9b8-c021da4db519',
                           '8b5e35ad-0e4a-48ca-bca3-ad7fdcfae3cc','a29026ae-d252-4456-bb26-eec09ba778c4']::uuid[];
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_prazo date;
  v_n int := 0; x record;
begin
  v_prazo := v_hoje + case extract(isodow from v_hoje)::int when 4 then 4 when 5 then 4 when 6 then 3 else 2 end;
  perform set_config('request.jwt.claims', json_build_object('sub', v_murilo, 'role', 'authenticated')::text, true);

  for x in
    select d.id, d.titulo, d.rodada, u.uid
      from public.politicas_docs d cross join unnest(v_socios) u(uid)
     where d.ativo and d.status = 'revisao'
       and exists(select 1 from public.tarefas_membros m where m.user_id = u.uid and m.ativo)
       and not exists(select 1 from public.politicas_respostas r where r.doc_id = d.id and r.rodada = d.rodada and r.user_id = u.uid)
       and not exists(select 1 from public.politicas_respostas r where r.doc_id = d.id and r.rodada < d.rodada and r.user_id = u.uid and r.tipo = 'concordo')
       and not exists(select 1 from public.tarefas t where t.origem = 'politica' and t.origem_ref = d.id || ':' || d.rodada
                         and t.responsavel_id = u.uid and not t.excluida)
  loop
    insert into public.tarefas (titulo, descricao, responsavel_id, criador_id, prazo_data, prioridade, status, origem, origem_ref)
    values (left('Revisar política: ' || x.titulo, 200),
            'Tarefa automática. Abra Políticas, leia o documento e responda "Revisei" (com anotações) ou "Concordo". A tarefa conclui sozinha quando a resposta for registrada.',
            x.uid, v_murilo, v_prazo, 'alta', 'pendente', 'politica', x.id || ':' || x.rodada);
    v_n := v_n + 1;
  end loop;

  for x in
    select r.id, r.titulo, r.data, (p->>'user_id')::uuid uid
      from public.reunioes r cross join jsonb_array_elements(coalesce(r.participantes, '[]'::jsonb)) p
     where r.ativo and r.status = 'completa' and (p->>'user_id') is not null
       and exists(select 1 from public.tarefas_membros m where m.user_id = (p->>'user_id')::uuid and m.ativo)
       and not exists(select 1 from public.reuniao_assinaturas a where a.reuniao_id = r.id and a.user_id = (p->>'user_id')::uuid)
       and not exists(select 1 from public.tarefas t where t.origem = 'ata' and t.origem_ref = r.id::text
                         and t.responsavel_id = (p->>'user_id')::uuid and not t.excluida)
  loop
    insert into public.tarefas (titulo, descricao, responsavel_id, criador_id, prazo_data, prioridade, status, origem, origem_ref)
    values (left('Assinar ata: ' || coalesce(nullif(x.titulo,''), 'Reunião') || ' · ' || to_char(x.data at time zone 'America/Sao_Paulo', 'DD/MM'), 200),
            'Tarefa automática. Abra Reuniões, leia a ata e assine. A tarefa conclui sozinha quando a assinatura for registrada.',
            x.uid, v_murilo, v_prazo, 'media', 'pendente', 'ata', x.id::text);
    v_n := v_n + 1;
  end loop;

  update public.tarefas t set status = 'concluida'
   where t.origem is not null and not t.excluida and t.status not in ('concluida','cancelada')
     and public.tarefas_pendencia_cumprida(t.origem, t.origem_ref, t.responsavel_id);

  update public.tarefas t set status = 'cancelada'
   where t.origem = 'politica' and not t.excluida and t.status not in ('concluida','cancelada')
     and not exists(select 1 from public.politicas_docs d where d.ativo and d.status = 'revisao'
                     and d.id || ':' || d.rodada = t.origem_ref);
  update public.tarefas t set status = 'cancelada'
   where t.origem = 'ata' and not t.excluida and t.status not in ('concluida','cancelada')
     and not exists(select 1 from public.reunioes r where r.ativo and r.id::text = t.origem_ref);
  return v_n;
end $$;
