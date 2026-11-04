-- Convite para a comunidade E27 (WhatsApp): liberado no 8º dia depois que o card entrou na Rota de
-- Embarque vindo do eCRM (embarque_leads.criado_em + 7 dias) ou por liberação manual da equipe.
create table if not exists public.comunidade_e27_convite (
  aluno_id uuid primary key references public.profiles(id) on delete cascade,
  visto_em timestamptz, entrou_em timestamptz, liberado_manual timestamptz);
alter table public.comunidade_e27_convite enable row level security;
create policy "aluno le o seu" on public.comunidade_e27_convite for select using (aluno_id = auth.uid() or is_staff());
create policy "aluno registra o seu" on public.comunidade_e27_convite for insert with check (aluno_id = auth.uid());
create policy "aluno atualiza o seu" on public.comunidade_e27_convite for update using (aluno_id = auth.uid());
create policy "equipe libera" on public.comunidade_e27_convite for all using (is_staff()) with check (is_staff());
create or replace function public.comunidade_e27_pendente()
returns table(liberado_em timestamptz, link text, visto_em timestamptz)
language sql stable security definer set search_path to 'public' as $$
  with base as (
    select l.criado_em + interval '7 days' as lib from embarque_leads l where l.aluno_id = auth.uid() and l.status = 'ativo'
    union all
    select c.liberado_manual from comunidade_e27_convite c where c.aluno_id = auth.uid() and c.liberado_manual is not null)
  select min(b.lib), 'https://chat.whatsapp.com/JDi8a3rlJhLIJKTT9LYFWh'::text, max(c.visto_em)
  from base b join profiles p on p.id = auth.uid() left join comunidade_e27_convite c on c.aluno_id = auth.uid()
  where p.role = 'aluno' and coalesce(p.tier,'mentorado') <> 'curso' and now() >= b.lib and c.entrou_em is null
  having min(b.lib) is not null;
$$;
