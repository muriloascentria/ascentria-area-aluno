-- Pendências viram tarefas automaticamente e só concluem quando a pessoa fez de fato:
--   * Política em revisão  → tarefa para cada sócio que ainda não respondeu na rodada atual
--   * Ata de reunião        → tarefa para cada participante que ainda não assinou
-- A tarefa conclui sozinha quando a pessoa responde/assina, e o "concluir" manual é recusado antes disso.
-- Sócios (os mesmos de REU_SOCIOS no index.html): Murilo, Carmem, Diego, Sandra.

alter table public.tarefas add column if not exists origem text,
                           add column if not exists origem_ref text;
comment on column public.tarefas.origem is 'Pendência que gerou a tarefa: politica | ata. Nula nas tarefas comuns.';
comment on column public.tarefas.origem_ref is 'politica: "<doc_id>:<rodada>"; ata: reuniao_id.';
create unique index if not exists tarefas_origem_unica
  on public.tarefas (origem, origem_ref, responsavel_id) where origem is not null and not excluida;

create or replace function public.tarefas_pendencia_cumprida(p_origem text, p_ref text, p_user uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select case p_origem
    when 'politica' then exists(select 1 from public.politicas_respostas r
                                 where r.doc_id = split_part(p_ref, ':', 1)::bigint
                                   and r.rodada = split_part(p_ref, ':', 2)::int and r.user_id = p_user)
    when 'ata' then exists(select 1 from public.reuniao_assinaturas a
                            where a.reuniao_id = p_ref::uuid and a.user_id = p_user)
    else true end;
$$;

-- Concluir à mão só depois de cumprir
create or replace function public.tarefas_origem_conclusao_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'concluida' and old.status is distinct from 'concluida' and new.origem is not null
     and not public.tarefas_pendencia_cumprida(new.origem, new.origem_ref, new.responsavel_id) then
    raise exception '%', case new.origem
      when 'politica' then 'Esta tarefa conclui sozinha quando você responder a política ("Revisei" ou "Concordo") em Políticas.'
      when 'ata' then 'Esta tarefa conclui sozinha quando você assinar a ata em Reuniões.'
      else 'Pendência ainda não cumprida.' end;
  end if;
  return new;
end $$;
drop trigger if exists trg_tarefas_origem_conclusao on public.tarefas;
create trigger trg_tarefas_origem_conclusao
  before update of status on public.tarefas
  for each row execute function public.tarefas_origem_conclusao_guard();

-- Cria as tarefas que faltam, conclui as cumpridas e cancela as que perderam a origem
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
  -- prazo: 2 dias úteis
  v_prazo := v_hoje + case extract(isodow from v_hoje)::int when 4 then 4 when 5 then 4 when 6 then 3 else 2 end;
  perform set_config('request.jwt.claims', json_build_object('sub', v_murilo, 'role', 'authenticated')::text, true);

  -- Políticas em revisão sem resposta do sócio na rodada atual
  for x in
    select d.id, d.titulo, d.rodada, u.uid
      from public.politicas_docs d cross join unnest(v_socios) u(uid)
     where d.ativo and d.status = 'revisao'
       and exists(select 1 from public.tarefas_membros m where m.user_id = u.uid and m.ativo)
       and not exists(select 1 from public.politicas_respostas r where r.doc_id = d.id and r.rodada = d.rodada and r.user_id = u.uid)
       and not exists(select 1 from public.tarefas t where t.origem = 'politica' and t.origem_ref = d.id || ':' || d.rodada
                         and t.responsavel_id = u.uid and not t.excluida)
  loop
    insert into public.tarefas (titulo, descricao, responsavel_id, criador_id, prazo_data, prioridade, status, origem, origem_ref)
    values (left('Revisar política: ' || x.titulo, 200),
            'Tarefa automática. Abra Políticas, leia o documento e responda "Revisei" (com anotações) ou "Concordo". A tarefa conclui sozinha quando a resposta for registrada.',
            x.uid, v_murilo, v_prazo, 'alta', 'pendente', 'politica', x.id || ':' || x.rodada);
    v_n := v_n + 1;
  end loop;

  -- Atas sem assinatura do participante
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

  -- Cumpridas → concluídas
  update public.tarefas t set status = 'concluida'
   where t.origem is not null and not t.excluida and t.status not in ('concluida','cancelada')
     and public.tarefas_pendencia_cumprida(t.origem, t.origem_ref, t.responsavel_id);

  -- Origem sumiu (política saiu de revisão ou mudou de rodada; reunião desativada) → canceladas
  update public.tarefas t set status = 'cancelada'
   where t.origem = 'politica' and not t.excluida and t.status not in ('concluida','cancelada')
     and not exists(select 1 from public.politicas_docs d where d.ativo and d.status = 'revisao'
                     and d.id || ':' || d.rodada = t.origem_ref);
  update public.tarefas t set status = 'cancelada'
   where t.origem = 'ata' and not t.excluida and t.status not in ('concluida','cancelada')
     and not exists(select 1 from public.reunioes r where r.ativo and r.id::text = t.origem_ref);
  return v_n;
end $$;

-- Ao responder/assinar, a tarefa da própria pessoa conclui na hora
create or replace function public.tarefas_pendencia_auto_concluir()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name = 'politicas_respostas' then
    update public.tarefas set status = 'concluida'
     where origem = 'politica' and origem_ref = new.doc_id || ':' || new.rodada and responsavel_id = new.user_id
       and not excluida and status not in ('concluida','cancelada');
  elsif tg_table_name = 'reuniao_assinaturas' then
    update public.tarefas set status = 'concluida'
     where origem = 'ata' and origem_ref = new.reuniao_id::text and responsavel_id = new.user_id
       and not excluida and status not in ('concluida','cancelada');
  end if;
  return new;
end $$;
drop trigger if exists trg_politicas_resp_tarefa on public.politicas_respostas;
create trigger trg_politicas_resp_tarefa after insert or update on public.politicas_respostas
  for each row execute function public.tarefas_pendencia_auto_concluir();
drop trigger if exists trg_reuniao_assin_tarefa on public.reuniao_assinaturas;
create trigger trg_reuniao_assin_tarefa after insert on public.reuniao_assinaturas
  for each row execute function public.tarefas_pendencia_auto_concluir();

-- Roda a cada 15 minutos e uma vez agora
select cron.unschedule('tarefas-pendencias') where exists(select 1 from cron.job where jobname = 'tarefas-pendencias');
select cron.schedule('tarefas-pendencias', '*/15 * * * *', 'select public.tarefas_sync_pendencias()');
select public.tarefas_sync_pendencias();
