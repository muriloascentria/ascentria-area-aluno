-- Análise cruzada de vendas na rotina, com prova:
--   Diego  (semanal): analisar 2 sessões da Carmem
--   Carmem (semanal): analisar 2 sessões do Diego
--   Diego  (diária) : analisar todas as sessões da Adriana (lead presente) desde a lista anterior
-- Para marcar o item, a pessoa escolhe as análises feitas (sessões com link da análise postado).
-- Depende de 20261105_rotina_conclusao_exige_itens.sql.

alter table public.gestao_itens add column if not exists prova jsonb;
comment on column public.gestao_itens.prova is
  'Prova exigida para marcar o item. {"tipo":"analise","vendedor":"Carmem","qtd":2} ou {"tipo":"analise","vendedor":"Adriana","todas":true}.';

alter table public.tarefas_subtarefas add column if not exists prova uuid[];
alter table public.tarefas_subtarefas add column if not exists prova_alunos uuid[];
alter table public.tarefas_subtarefas add column if not exists prova_meta int;
comment on column public.tarefas_subtarefas.prova_alunos is 'Mentorados do Radar apresentados como resolvidos ao marcar o item.';
comment on column public.tarefas_subtarefas.prova_meta is 'Meta do dia no momento da marcação: casos abertos no nível ÷ dias úteis restantes da semana.';
comment on column public.tarefas_subtarefas.prova is 'Análises (analise_sessoes.id) apresentadas como prova ao marcar o item.';

-- Configuração da prova + janela de datas do item
create or replace function public.rotina_prova_cfg(p_sub uuid)
returns table(prova jsonb, periodo date, desde date)
language sql stable security definer set search_path = public as $$
  select i.prova, d.periodo,
         coalesce((select max(d2.periodo) from public.gestao_disparos d2
                    where d2.pessoa_id = d.pessoa_id and d2.frequencia = d.frequencia and d2.periodo < d.periodo),
                  d.periodo - 1)
    from public.gestao_disparo_itens di
    join public.gestao_disparos d on d.id = di.disparo_id
    join public.gestao_itens i on i.id = di.item_id
   where di.subtarefa_id = p_sub and i.prova is not null;
$$;

-- Sessões que servem de prova para o item
create or replace function public.rotina_prova_candidatas(p_sub uuid)
returns table(analise_id uuid, venda_id uuid, lead text, data_sessao date, vendedor text, link_analise text, obrigatoria boolean, usada boolean)
language plpgsql stable security definer set search_path = public as $$
declare c record; v_tarefa uuid;
begin
  select tarefa_id into v_tarefa from public.tarefas_subtarefas where id = p_sub;
  if v_tarefa is null or not public.tarefas_pode_editar(v_tarefa) then raise exception 'sem permissão'; end if;
  select * into c from public.rotina_prova_cfg(p_sub);
  if c.prova is null or c.prova->>'tipo' <> 'analise' then return; end if;

  if coalesce((c.prova->>'todas')::boolean, false) then
    return query
      select a.id, v.id, coalesce(nullif(v.lead_nome,''), a.lead_nome), v.data_sessao, v.vendedor,
             nullif(btrim(coalesce(a.link_analise,'')), ''), true, false
        from public.venda_sessoes v
        left join public.analise_sessoes a on a.venda_sessao_id = v.id
       where v.vendedor = c.prova->>'vendedor' and v.presenca = 'Show'
         and v.data_sessao >= c.desde and v.data_sessao < c.periodo
       order by v.data_sessao, v.lead_nome;
  else
    return query
      select a.id, v.id, coalesce(nullif(v.lead_nome,''), a.lead_nome), v.data_sessao, v.vendedor,
             btrim(a.link_analise), false,
             exists(select 1 from public.tarefas_subtarefas s where s.id <> p_sub and a.id = any(s.prova))
        from public.analise_sessoes a
        join public.venda_sessoes v on v.id = a.venda_sessao_id
       where v.vendedor = c.prova->>'vendedor' and btrim(coalesce(a.link_analise,'')) <> ''
         and v.data_sessao >= c.periodo - 60
       order by v.data_sessao desc
       limit 40;
  end if;
end $$;

-- Devolve null quando a prova é válida, ou o motivo da recusa
-- Mentorados em que a pessoa registrou alguma ação hoje (horário de Brasília)
create or replace function public.rotina_radar_acoes_hoje(p_user uuid default auth.uid())
returns setof uuid language sql stable security definer set search_path = public as $$
  with h as (select (now() at time zone 'America/Sao_Paulo')::date d)
  select student_id from public.internal_records, h where autor_id = p_user and (created_at at time zone 'America/Sao_Paulo')::date = h.d
  union select aluno_id from public.mensagens, h where de = p_user and aluno_id is not null and (created_at at time zone 'America/Sao_Paulo')::date = h.d
  union select para from public.mensagens m, h where de = p_user and para is not null and (created_at at time zone 'America/Sao_Paulo')::date = h.d
    and exists(select 1 from public.profiles p where p.id = m.para and p.role = 'aluno')
  union select student_id from public.radar_momentos_resolvidos, h where resolvido_por = p_user and (resolvido_em at time zone 'America/Sao_Paulo')::date = h.d
  union select aluno_id from public.radar_espera_ok, h where por = p_user and (ate at time zone 'America/Sao_Paulo')::date = h.d
  union select student_id from public.acompanhamento_evolucao, h where updated_by = p_user and (updated_at at time zone 'America/Sao_Paulo')::date = h.d
  union select student_id from public.acompanhamento_acoes, h where created_by = p_user and (created_at at time zone 'America/Sao_Paulo')::date = h.d
  union select student_id from public.acompanhamento_observacoes, h where created_by = p_user and (created_at at time zone 'America/Sao_Paulo')::date = h.d;
$$;
grant execute on function public.rotina_radar_acoes_hoje(uuid) to authenticated;

-- Tipo de prova do item (para a tela decidir qual janela abrir)
create or replace function public.rotina_prova_tipo(p_sub uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_tarefa uuid; v jsonb;
begin
  select tarefa_id into v_tarefa from public.tarefas_subtarefas where id = p_sub;
  if v_tarefa is null or not public.tarefas_pode_editar(v_tarefa) then raise exception 'sem permissão'; end if;
  select prova into v from public.rotina_prova_cfg(p_sub);
  return v;
end $$;
grant execute on function public.rotina_prova_tipo(uuid) to authenticated;

create or replace function public.rotina_prova_erro(p_sub uuid, p_prova uuid[], p_alunos uuid[] default null, p_meta int default null)
returns text language plpgsql stable security definer set search_path = public as $$
declare c record; v_qtd int; v_ok int; v_faltam int; v_usadas int; v_sem_acao int;
begin
  select * into c from public.rotina_prova_cfg(p_sub);
  if c.prova is null then return null; end if;

  if c.prova->>'tipo' = 'radar' then
    -- Meta mínima de 1: sem casos no nível, o item fica desmarcado com justificativa ("nenhum caso hoje").
    p_meta := greatest(coalesce(p_meta, 1), 1);
    if coalesce(array_length(p_alunos, 1), 0) = 0 then
      return 'Escolha os mentorados que você resolveu hoje.';
    end if;
    select count(*) into v_sem_acao from unnest(coalesce(p_alunos,'{}')) a
     where a not in (select public.rotina_radar_acoes_hoje(auth.uid()));
    if v_sem_acao > 0 then
      return format('%s mentorado(s) escolhido(s) sem nenhuma ação sua registrada hoje (mensagem no Acompanhamento, registro de contato, próxima ação ou momento resolvido). Registre e tente de novo.', v_sem_acao);
    end if;
    if coalesce(array_length(p_alunos, 1), 0) < coalesce(p_meta, 1) then
      return format('A meta de hoje é %s caso(s). Você marcou %s.', coalesce(p_meta,1), coalesce(array_length(p_alunos, 1), 0));
    end if;
    return null;
  end if;

  if coalesce((c.prova->>'todas')::boolean, false) then
    select count(*) into v_faltam
      from public.venda_sessoes v
      left join public.analise_sessoes a on a.venda_sessao_id = v.id
     where v.vendedor = c.prova->>'vendedor' and v.presenca = 'Show'
       and v.data_sessao >= c.desde and v.data_sessao < c.periodo
       and (a.id is null or btrim(coalesce(a.link_analise,'')) = '' or not (a.id = any(coalesce(p_prova,'{}'))));
    if v_faltam > 0 then
      return format('Faltam %s sessão(ões) de %s sem análise marcada como prova. Poste o link da análise de cada uma e marque todas.', v_faltam, c.prova->>'vendedor');
    end if;
    return null;
  end if;

  v_qtd := coalesce((c.prova->>'qtd')::int, 1);
  select count(distinct a.id) into v_ok
    from public.analise_sessoes a join public.venda_sessoes v on v.id = a.venda_sessao_id
   where a.id = any(coalesce(p_prova,'{}')) and v.vendedor = c.prova->>'vendedor'
     and btrim(coalesce(a.link_analise,'')) <> '';
  select count(*) into v_usadas from public.tarefas_subtarefas s
   where s.id <> p_sub and s.prova && coalesce(p_prova,'{}');
  if v_usadas > 0 then
    return 'Uma das análises escolhidas já foi usada como prova em outro item. Escolha outra.';
  end if;
  if v_ok < v_qtd then
    return format('Marque %s análise(s) de sessões de %s com o link da análise postado (marcadas: %s).', v_qtd, c.prova->>'vendedor', v_ok);
  end if;
  return null;
end $$;

-- Guarda dos itens da rotina (substitui a versão da migration anterior, agora com a prova)
create or replace function public.tarefas_rotina_itens_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_status text; v_erro text;
begin
  if tg_op = 'DELETE' then
    if public.tarefas_eh_rotina(old.tarefa_id) and not public.tarefas_is_admin() then
      raise exception 'Itens da rotina não podem ser apagados. Se não fez, deixe desmarcado e escreva a justificativa.';
    end if;
    return old;
  end if;

  if not public.tarefas_eh_rotina(new.tarefa_id) then return new; end if;
  select status into v_status from public.tarefas where id = new.tarefa_id;

  if v_status = 'concluida' and old.concluida and not new.concluida then
    raise exception 'Esta rotina já foi concluída. Reabra a rotina antes de desmarcar um item.';
  end if;
  if v_status = 'concluida' and new.justificativa is distinct from old.justificativa
     and length(btrim(coalesce(new.justificativa, ''))) < 10 and not new.concluida then
    raise exception 'Esta rotina já foi concluída. Reabra a rotina antes de apagar a justificativa.';
  end if;

  if new.concluida and not old.concluida then
    v_erro := public.rotina_prova_erro(new.id, new.prova, new.prova_alunos, new.prova_meta);
    if v_erro is not null then raise exception '%', v_erro; end if;
    new.justificativa := null; new.justificada_em := null; new.justificada_por := null;
  elsif not new.concluida and old.concluida then
    new.prova := null; new.prova_alunos := null; new.prova_meta := null;
  elsif new.concluida and (new.prova is distinct from old.prova or new.prova_alunos is distinct from old.prova_alunos
                           or new.prova_meta is distinct from old.prova_meta) then
    raise exception 'A prova de um item já marcado não pode ser trocada. Desmarque e marque de novo.';
  end if;

  if not new.concluida and new.justificativa is distinct from old.justificativa then
    new.justificativa := nullif(btrim(coalesce(new.justificativa, '')), '');
    new.justificada_em := case when new.justificativa is null then null else now() end;
    new.justificada_por := case when new.justificativa is null then null else auth.uid() end;
  end if;
  return new;
end $$;

-- Correção: a rotina semanal nunca foi enviada. O item 504 (Viviane) gera um título
-- com mais de 200 caracteres e a restrição tarefas_subtarefas_titulo_check derruba o disparo inteiro.
-- Títulos longos passam a ser cortados com reticências (o texto completo continua em gestao_itens).
create or replace function public.tarefas_sub_titulo_curto()
returns trigger language plpgsql as $$
begin
  if length(btrim(new.titulo)) > 200 then
    new.titulo := left(btrim(new.titulo), 199) || '…';
  end if;
  return new;
end $$;
drop trigger if exists trg_tarefas_sub_titulo_curto on public.tarefas_subtarefas;
create trigger trg_tarefas_sub_titulo_curto
  before insert or update of titulo on public.tarefas_subtarefas
  for each row execute function public.tarefas_sub_titulo_curto();

-- Os itens novos
insert into public.gestao_itens (papel_id, frequencia, texto, ordem, ativo, prova)
select 5, 'semanal', 'Analisar 2 sessões de venda da Carmem e postar o link de cada análise.', 900, true,
       '{"tipo":"analise","vendedor":"Carmem","qtd":2}'::jsonb
 where not exists (select 1 from public.gestao_itens where papel_id = 5 and prova->>'vendedor' = 'Carmem');

insert into public.gestao_itens (papel_id, frequencia, texto, ordem, ativo, prova)
select 16, 'semanal', 'Analisar 2 sessões de venda do Diego e postar o link de cada análise.', 900, true,
       '{"tipo":"analise","vendedor":"Diego","qtd":2}'::jsonb
 where not exists (select 1 from public.gestao_itens where papel_id = 16 and prova->>'vendedor' = 'Diego');

insert into public.gestao_itens (papel_id, frequencia, texto, ordem, ativo, prova)
select 5, 'diaria', 'Analisar todas as sessões de venda da Adriana (lead presente) desde a última lista e postar o link de cada análise.', 900, true,
       '{"tipo":"analise","vendedor":"Adriana","todas":true}'::jsonb
 where not exists (select 1 from public.gestao_itens where papel_id = 5 and prova->>'vendedor' = 'Adriana');

-- Radar: os dois itens diários da Sandra passam a exigir prova
update public.gestao_itens set prova = '{"tipo":"radar","nivel":2}'::jsonb
 where id = 198 and texto ilike '%RISCO do Radar%';
update public.gestao_itens set prova = '{"tipo":"radar","nivel":1}'::jsonb
 where id = 491 and texto ilike '%ATENÇÃO do Radar%';

grant execute on function public.rotina_prova_candidatas(uuid) to authenticated;
