-- ============================================================================
-- Sistema de Previsão de Insumos — Boali
-- Migração 0009: unicidade em vendas para importação idempotente
--
-- A tela de upload de vendas (Módulo 5) precisa poder reimportar o mesmo
-- período (ex. corrigir um arquivo, ou o usuário sobe o mesmo relatório de
-- novo sem querer) sem duplicar totais. Sem isso, um re-upload soma vendas
-- duas vezes no cálculo do Módulo 6.
-- ============================================================================

set search_path to motor_pedidos, public;

alter table vendas
  add constraint uq_vendas_prato_loja_periodo
  unique (prato_id, loja_id, data_inicio, data_fim);
