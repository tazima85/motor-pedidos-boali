-- ============================================================================
-- Sistema de Previsão de Insumos — Boali
-- Migração 0006: desempate determinístico na contagem de estoque mais recente
--
-- calcular_pedido_sugerido() escolhe o estoque atual via
-- `order by data desc limit 1`. Se alguém recontar o mesmo ingrediente no
-- mesmo dia (esperado agora que existe uma tela de contagem — recontagens
-- no mesmo dia são normais), duas linhas empatam em `data` e a ordem entre
-- elas fica indefinida. Acrescenta `created_at desc` como critério de
-- desempate, preferindo sempre o lançamento mais recente.
-- ============================================================================

set search_path to motor_pedidos, public;

create or replace function calcular_pedido_sugerido(
  p_ingrediente_id        uuid,
  p_loja_id               uuid,
  p_data_pedido           date,
  p_consumo_teorico_base  numeric default 0
) returns table (
  periodo_inicio              date,
  periodo_fim                 date,
  dias_cobertura               integer,
  consumo_teorico_base        numeric,
  desperdicio_periodo         numeric,
  fator_sazonalidade_passada  numeric,
  fator_sazonalidade_futura   numeric,
  consumo_esperado            numeric,
  estoque_atual_base          numeric,
  necessidade_bruta           numeric,
  unidade_compra              text,
  lote_minimo                 numeric,
  pedido_sugerido             numeric
)
language plpgsql
stable
set search_path = motor_pedidos, public
as $$
declare
  v_periodo              record;
  v_dias                 integer;
  v_desperdicio_diario    numeric;
  v_desperdicio_periodo   numeric;
  v_fator_passada         numeric;
  v_fator_futura          numeric;
  v_consumo_esperado      numeric;
  v_estoque_base          numeric;
  v_necessidade_bruta     numeric;
  v_unidade_base          text;
  v_unidade_compra        text;
  v_lote                  numeric;
  v_pedido_unidade_compra numeric;
begin
  if extract(dow from p_data_pedido) <> 4 then
    raise exception
      'data_pedido (%) não é uma quinta-feira — o ciclo de reposição assume pedidos feitos às quintas',
      p_data_pedido;
  end if;

  select * into v_periodo from periodo_cobertura(p_data_pedido);
  v_dias := (v_periodo.periodo_fim - v_periodo.periodo_inicio) + 1;

  select ing.unidade_base, ing.unidade_compra_fornecedor, ing.lote_minimo_compra
    into v_unidade_base, v_unidade_compra, v_lote
  from ingredientes ing
  where ing.id = p_ingrediente_id;

  if v_unidade_base is null then
    raise exception 'Ingrediente % não encontrado', p_ingrediente_id;
  end if;
  if v_unidade_compra is null then
    raise exception 'Ingrediente % não tem unidade_compra_fornecedor cadastrada', p_ingrediente_id;
  end if;

  v_desperdicio_diario := calcular_desperdicio_medio_diario(p_ingrediente_id, p_loja_id, p_data_pedido);
  v_desperdicio_periodo := v_desperdicio_diario * v_dias;

  v_fator_passada := fator_sazonalidade_vigente('passada', 'ingrediente', p_ingrediente_id, p_data_pedido);
  v_fator_futura  := fator_sazonalidade_vigente('futura',  'ingrediente', p_ingrediente_id, p_data_pedido);

  v_consumo_esperado := (p_consumo_teorico_base + v_desperdicio_periodo) * v_fator_passada * v_fator_futura;

  select converter(ce.quantidade, ce.unidade, v_unidade_base, p_ingrediente_id)
    into v_estoque_base
  from contagens_estoque ce
  where ce.ingrediente_id = p_ingrediente_id
    and ce.loja_id = p_loja_id
    and ce.data <= p_data_pedido
  order by ce.data desc, ce.created_at desc
  limit 1;

  v_estoque_base := coalesce(v_estoque_base, 0);

  v_necessidade_bruta := greatest(v_consumo_esperado - v_estoque_base, 0);

  v_pedido_unidade_compra := ceil(
    converter(v_necessidade_bruta, v_unidade_base, v_unidade_compra, p_ingrediente_id) / v_lote
  ) * v_lote;

  return query select
    v_periodo.periodo_inicio,
    v_periodo.periodo_fim,
    v_dias,
    p_consumo_teorico_base,
    v_desperdicio_periodo,
    v_fator_passada,
    v_fator_futura,
    v_consumo_esperado,
    v_estoque_base,
    v_necessidade_bruta,
    v_unidade_compra,
    v_lote,
    v_pedido_unidade_compra;
end;
$$;
