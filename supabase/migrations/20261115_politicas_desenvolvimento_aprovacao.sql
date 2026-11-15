-- Políticas Internas: responsável (documentos em desenvolvimento) e registro da aprovação
-- (data e quem aprovou, sócios e demais participantes da reunião).
alter table public.politicas_docs add column if not exists responsavel text;
alter table public.politicas_docs add column if not exists aprovada_em date;
alter table public.politicas_docs add column if not exists aprovada_por uuid[] not null default '{}';
