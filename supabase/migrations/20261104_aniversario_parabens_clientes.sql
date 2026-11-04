create table if not exists public.aniversario_parabens_clientes (
  cliente_id text not null, ano integer not null,
  por uuid references auth.users(id) on delete set null,
  em timestamptz not null default now(), primary key (cliente_id, ano));
alter table public.aniversario_parabens_clientes enable row level security;
create policy "equipe le" on public.aniversario_parabens_clientes for select using (is_staff());
create policy "equipe marca" on public.aniversario_parabens_clientes for insert with check (is_staff());
