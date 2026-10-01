-- ============================================================================
-- Sistema de Previsão de Insumos — Boali
-- Migração 0013: distinguir alimentos/bebidas de itens não-alimentícios
--
-- O catálogo de ~136 itens importado do PDF de contagem (ver seed.sql) mistura
-- comida/bebida de verdade com descartáveis, embalagens, utensílios e produtos
-- de limpeza (ex. "LUVA DESC", "GUARDANAPO 40X15", "KAY-5 SANITIZANTE"). A tela
-- de Registro de Desperdício, ao lançar perda de um "ingrediente_bruto", só
-- deve listar itens que são de fato comida/bebida — perder uma luva ou um
-- guardanapo não é desperdício de insumo alimentar.
--
-- Default `true`: a maioria do catálogo (e todo ingrediente cadastrado antes
-- da importação do PDF) é alimento de verdade; os ~41 itens não-alimentícios
-- do catálogo são marcados `false` explicitamente via UPDATE em seed.sql,
-- logo após a importação (mesmo padrão usado para `receita_opcoes_variaveis
-- .padrao`: UPDATE por correspondência, não um default que já nasce certo
-- pra tudo). Campo separado de `oculto_contagem` e `ativo` de propósito: um
-- item pode ser alimento e ainda assim estar oculto da contagem, e um item
-- não-alimentício continua válido pra compra/estoque — só não aparece como
-- opção de desperdício "ingrediente_bruto".
-- ============================================================================

set search_path to motor_pedidos, public;

alter table ingredientes
  add column eh_alimento boolean not null default true;
