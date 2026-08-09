-- ============================================================================
-- Sistema de Previsão de Insumos — Boali
-- Migração 0011: ocultar ingrediente da tela de contagem
--
-- Campo separado de `ativo` de propósito: `ativo=false` tira o ingrediente
-- do sistema inteiro (desperdício, pedido sugerido, etc.), enquanto isso
-- aqui só precisa afetar a tela de Contagem de Estoque — um item pode
-- continuar válido para receita/pedido mas não fazer sentido contar
-- fisicamente toda semana.
-- ============================================================================

set search_path to motor_pedidos, public;

alter table ingredientes
  add column oculto_contagem boolean not null default false;
