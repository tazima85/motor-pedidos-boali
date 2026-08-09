-- ============================================================================
-- Sistema de Previsão de Insumos — Boali
-- Migração 0013: histórico de pedidos sugeridos
--
-- calcular_pedido_sugerido() sempre foi um cálculo puro, sob demanda, sem
-- efeito colateral — nada era salvo. Passa a existir um registro histórico
-- só quando o usuário efetivamente gera o PDF do pedido (não a cada
-- "Calcular"), pra não poluir o histórico com cálculos exploratórios.
--
-- `quantidade_pedida_real` fica aberto de propósito, sem preencher ainda —
-- é o gancho pro backlog de validação de acurácia (previsto × real) que o
-- spec original já deixou reservado, sem pedir implementação agora.
-- ============================================================================

set search_path to motor_pedidos, public;

create table pedidos_sugeridos (
  id                          uuid primary key default gen_random_uuid(),
  data_pedido                 date not null,
  loja_id                     uuid not null references lojas(id),
  ingrediente_id              uuid not null references ingredientes(id),

  periodo_inicio              date not null,
  periodo_fim                 date not null,
  consumo_teorico_base        numeric not null,
  desperdicio_periodo         numeric not null,
  fator_sazonalidade_passada  numeric not null,
  fator_sazonalidade_futura   numeric not null,
  consumo_esperado            numeric not null,
  estoque_atual_base          numeric not null,
  necessidade_bruta           numeric not null,
  unidade_compra              text not null,
  lote_minimo                 numeric not null,
  pedido_sugerido             numeric not null,

  -- backlog explícito do spec original — não preenchido por enquanto.
  quantidade_pedida_real      numeric,

  created_at                  timestamptz not null default now()
);

create index idx_pedidos_sugeridos_data_loja on pedidos_sugeridos (data_pedido, loja_id);

alter table pedidos_sugeridos enable row level security;

create policy pedidos_sugeridos_authenticated_all
  on pedidos_sugeridos
  for all to authenticated using (true) with check (true);
