-- Rota de Embarque -> Acompanhamento Interno (Onboarding e Competências por Módulo).
-- Onboarding ePLAT = Onboarding de abertura; Expert = Expert; eSIS = eSIS.
-- "Agendado" (ou data preenchida) registra a data agendada; "Concluído" registra a data realizada
-- (a data da etapa, ou hoje se ela ainda estiver no futuro). Desmarcar "Concluído" desfaz o registro
-- feito pela Rota. Com ePLAT e eSIS concluídos, marca a competência "Acesso às plataformas".
create or replace function public.embarque_sincroniza_onboarding()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare
  par record; e jsonb; d date; ag boolean; ok boolean; o onboarding_jornada%rowtype; v_ag date; v_re date;
  antigo jsonb; d_antiga date;
begin
  if new.aluno_id is null or not exists (select 1 from profiles where id = new.aluno_id) then return new; end if;
  insert into onboarding_jornada(student_id, updated_at) values (new.aluno_id, now()) on conflict (student_id) do nothing;
  for par in select * from (values ('eplat','abertura'),('expert','expert'),('esis','esis')) t(emb, ob) loop
    e := coalesce(new.etapas->par.emb, '{}'::jsonb);
    antigo := case when tg_op = 'UPDATE' then coalesce(old.etapas->par.emb, '{}'::jsonb) else '{}'::jsonb end;
    d := case when coalesce(e->>'data','') ~ '^\d{4}-\d{2}-\d{2}$' then (e->>'data')::date end;
    d_antiga := case when coalesce(antigo->>'data','') ~ '^\d{4}-\d{2}-\d{2}$' then (antigo->>'data')::date end;
    ag := coalesce((e->'checks'->>'agendado')::boolean, false);
    ok := coalesce((e->'checks'->>'concluido')::boolean, false);
    execute format('select %I, %I from onboarding_jornada where student_id = $1', par.ob||'_agendada', par.ob||'_realizada') into v_ag, v_re using new.aluno_id;
    if d is not null and (ag or ok) then v_ag := d; end if;
    if ok then
      v_re := coalesce(v_re, least(coalesce(d, current_date), current_date));
    elsif coalesce((antigo->'checks'->>'concluido')::boolean, false) then
      -- desmarcou "Concluído" na Rota: desfaz só a data que a própria Rota tinha registrado
      if v_re is not null and (v_re = least(coalesce(d_antiga, current_date), current_date) or v_re = d) then v_re := null; end if;
    end if;
    execute format('update onboarding_jornada set %I = $1, %I = $2, updated_at = now(), updated_by = coalesce(auth.uid(), updated_by) where student_id = $3', par.ob||'_agendada', par.ob||'_realizada')
      using v_ag, v_re, new.aluno_id;
  end loop;
  if coalesce((new.etapas->'eplat'->'checks'->>'concluido')::boolean,false) and coalesce((new.etapas->'esis'->'checks'->>'concluido')::boolean,false) then
    insert into acompanhamento_evolucao(student_id, competencias) values (new.aluno_id, '{"ABERTURA-1":true}'::jsonb)
    on conflict (student_id) do update set competencias = coalesce(acompanhamento_evolucao.competencias,'{}'::jsonb) || '{"ABERTURA-1":true}'::jsonb;
  end if;
  return new;
end $$;
drop trigger if exists tg_embarque_onboarding on public.embarque;
create trigger tg_embarque_onboarding after insert or update of etapas, aluno_id on public.embarque
  for each row execute function public.embarque_sincroniza_onboarding();
