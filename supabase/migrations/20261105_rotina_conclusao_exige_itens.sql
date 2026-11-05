-- Rotinas da Gestão do Time: a lista só pode ser concluída quando cada item
-- estiver marcado como feito OU tiver uma justificativa curta de por que não foi feito.
-- Também impede apagar itens da rotina (exceto administrador) e desmarcar item de
-- uma rotina já concluída sem antes reabri-la.

alter table public.tarefas_subtarefas
  add column if not exists justificativa text,
  add column if not exists justificada_em timestamptz,
  add column if not exists justificada_por uuid references public.profiles(id);

comment on column public.tarefas_subtarefas.justificativa is
  'Motivo de o item da rotina não ter sido feito (obrigatório para concluir a rotina com o item desmarcado).';

create or replace function public.tarefas_eh_rotina(p_tarefa uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.gestao_disparos d where d.tarefa_id = p_tarefa);
$$;

-- Conclusão da rotina
create or replace function public.tarefas_rotina_conclusao_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_faltam int;
begin
  if new.status = 'concluida' and old.status is distinct from 'concluida'
     and public.tarefas_eh_rotina(new.id) then
    select count(*) into v_faltam from public.tarefas_subtarefas s
     where s.tarefa_id = new.id and not s.concluida
       and length(btrim(coalesce(s.justificativa, ''))) < 10;
    if v_faltam > 0 then
      raise exception 'Rotina com % item(ns) sem marcar e sem justificativa. Marque o que foi feito ou escreva em poucas palavras por que não foi feito.', v_faltam
        using errcode = 'P0001';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_tarefas_rotina_conclusao on public.tarefas;
create trigger trg_tarefas_rotina_conclusao
  before update of status on public.tarefas
  for each row execute function public.tarefas_rotina_conclusao_guard();

-- Itens da rotina
create or replace function public.tarefas_rotina_itens_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_status text;
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
    -- item feito: a justificativa deixa de valer
    new.justificativa := null; new.justificada_em := null; new.justificada_por := null;
  elsif new.justificativa is distinct from old.justificativa then
    new.justificativa := nullif(btrim(coalesce(new.justificativa, '')), '');
    new.justificada_em := case when new.justificativa is null then null else now() end;
    new.justificada_por := case when new.justificativa is null then null else auth.uid() end;
  end if;
  return new;
end $$;

drop trigger if exists trg_tarefas_rotina_itens on public.tarefas_subtarefas;
create trigger trg_tarefas_rotina_itens
  before update or delete on public.tarefas_subtarefas
  for each row execute function public.tarefas_rotina_itens_guard();
