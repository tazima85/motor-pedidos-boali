-- ============================================================================
-- Sistema de Previsão de Insumos — Boali
-- Migração 0003: grants do schema motor_pedidos para os roles do PostgREST
--
-- Expor um schema custom nas "Exposed schemas" do Data API (feito manualmente
-- no dashboard) só ensina o PostgREST a rotear pra ele — os roles do Postgres
-- ainda não têm privilégio nenhum sobre um schema novo (diferente de
-- `public`, que já vem com isso de fábrica). Sem isso toda query retorna
-- 42501 "permission denied for schema motor_pedidos" antes mesmo de chegar
-- no RLS.
--
-- `anon` fica de fora de propósito: o MVP pressupõe usuário logado (equipe
-- de loja) pra qualquer leitura/escrita, e as policies de RLS (migração
-- 0001) já só cobrem `authenticated` — não há motivo pra dar visibilidade de
-- schema a um role sem nenhuma policy aplicável.
-- ============================================================================

grant usage on schema motor_pedidos to authenticated, service_role;

grant select, insert, update, delete on all tables in schema motor_pedidos to authenticated;
grant all on all tables in schema motor_pedidos to service_role;

grant execute on all functions in schema motor_pedidos to authenticated, service_role;

-- garante que tabelas/funções criadas em migrações futuras neste schema já
-- nascem com os mesmos grants, sem precisar repetir isso a cada migração.
alter default privileges in schema motor_pedidos
  grant select, insert, update, delete on tables to authenticated;
alter default privileges in schema motor_pedidos
  grant all on tables to service_role;
alter default privileges in schema motor_pedidos
  grant execute on functions to authenticated, service_role;
