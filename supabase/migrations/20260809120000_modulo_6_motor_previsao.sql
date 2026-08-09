-- ============================================================================
-- Sistema de Previsão de Insumos — Boali
-- Migração 0005: Módulo 6 — Motor de Previsão
--
-- Módulo 5 (Ingestão de Vendas) ainda não existe, então o "consumo teórico
-- base" (vendas × receita) não pode ser calculado aqui dentro — é recebido
-- como parâmetro explícito de calcular_pedido_sugerido() por enquanto. O
-- resto do pipeline (desperdício médio, estoque atual, sazonalidade,
-- arredondamento por lote) usa dados reais já existentes no banco.
-- ============================================================================

set search_path to motor_pedidos, public;

-- ----------------------------------------------------------------------------
-- Fatores de sazonalidade — passada (observada) e futura (informada
-- manualmente, ex. feriado/evento/promoção). Nível fica em aberto por
-- ingrediente/prato/loja (ver "Pontos em aberto" no spec); sem trigger de
-- integridade cross-table pra referencia_id (mesma decisão já tomada em
-- registros_desperdicio) — a aplicação garante que referencia_id aponta pro
-- tipo certo de acordo com nivel.
-- ----------------------------------------------------------------------------

create table fatores_sazonalidade (
  id              uuid primary key default gen_random_uuid(),
  nivel           text not null check (nivel in ('prato', 'ingrediente', 'loja')),
  referencia_id   uuid not null,
  tipo            text not null check (tipo in ('passada', 'futura')),
  periodo_inicio  date not null,
  periodo_fim     date not null,
  fator           numeric not null check (fator > 0),
  motivo          text,
  created_at      timestamptz not null default now(),

  constraint chk_periodo_valido check (periodo_fim >= periodo_inicio)
);

create index idx_sazonalidade_lookup
  on fatores_sazonalidade (tipo, nivel, referencia_id, periodo_inicio, periodo_fim);

alter table fatores_sazonalidade enable row level security;

create policy fatores_sazonalidade_authenticated_all
  on fatores_sazonalidade
  for all to authenticated using (true) with check (true);

-- ----------------------------------------------------------------------------
-- periodo_cobertura: traduz a regra de negócio do ciclo de reposição em
-- datas concretas.
--
-- Pedido feito quinta à noite, chega segunda (+4 dias) — o período ANTES da
-- chegada (quinta a segunda) é responsabilidade do pedido ANTERIOR, não
-- deste. Este pedido só precisa cobrir consumo a partir da chegada.
--
-- Da chegada (segunda) até a chegada do PRÓXIMO pedido semanal seriam só 7
-- dias; a spec pede +1 dia de margem de segurança pra atraso do fornecedor
-- ou pico de venda, estendendo a cobertura até a terça seguinte — resultando
-- no "período real de cobertura de ~8-9 dias" citado na especificação
-- (8 dias de diferença entre chegada e fim da margem; 9 dias se contados os
-- dois extremos inclusive).
-- ----------------------------------------------------------------------------

create or replace function periodo_cobertura(p_data_pedido date)
returns table (periodo_inicio date, periodo_fim date)
language sql
stable
as $$
  select
    p_data_pedido + 4 as periodo_inicio,  -- segunda de chegada
    p_data_pedido + 12 as periodo_fim     -- terça da semana seguinte à chegada (+1 dia de margem)
$$;

-- ----------------------------------------------------------------------------
-- fator_sazonalidade_vigente: busca o fator aplicável a uma data; 1.0
-- (neutro, não altera o cálculo) se nada estiver cadastrado pro
-- tipo/nivel/referencia informados.
-- ----------------------------------------------------------------------------

create or replace function fator_sazonalidade_vigente(
  p_tipo          text,
  p_nivel         text,
  p_referencia_id uuid,
  p_data          date
) returns numeric
language sql
stable
set search_path = motor_pedidos, public
as $$
  select coalesce(
    (
      select fator
      from fatores_sazonalidade
      where tipo = p_tipo
        and nivel = p_nivel
        and referencia_id = p_referencia_id
        and p_data between periodo_inicio and periodo_fim
      order by periodo_inicio desc
      limit 1
    ),
    1.0
  );
$$;

-- ----------------------------------------------------------------------------
-- calcular_desperdicio_medio_diario: desperdício médio por dia de um
-- ingrediente numa loja, na unidade_base, sobre uma janela histórica.
-- Soma três origens (todas convertidas via converter()):
--   1. perdas declaradas direto sobre o ingrediente bruto (Módulo 3)
--   2. perdas de prato, pela parte do componente fixo da receita
--   3. perdas de prato, pela opção variável selecionada (0002) que bate com
--      este ingrediente
-- Divide sempre por p_dias_historico (não pela contagem de dias com
-- lançamento) — dias sem desperdício são zero de verdade, não devem inflar
-- a média dos dias em que houve perda.
-- ----------------------------------------------------------------------------

create or replace function calcular_desperdicio_medio_diario(
  p_ingrediente_id  uuid,
  p_loja_id         uuid,
  p_data_referencia date default current_date,
  p_dias_historico  integer default 28
) returns numeric
language plpgsql
stable
set search_path = motor_pedidos, public
as $$
declare
  v_total_base numeric;
begin
  select coalesce(sum(qtd_base), 0) into v_total_base
  from (
    select converter(rd.quantidade, rd.unidade, i.unidade_base, i.id) as qtd_base
    from registros_desperdicio rd
    join ingredientes i on i.id = rd.ingrediente_id
    where rd.tipo_perda = 'ingrediente_bruto'
      and rd.ingrediente_id = p_ingrediente_id
      and rd.loja_id = p_loja_id
      and rd.data > p_data_referencia - p_dias_historico
      and rd.data <= p_data_referencia

    union all

    select converter(rd.quantidade * rc.quantidade, rc.unidade, i.unidade_base, i.id) as qtd_base
    from registros_desperdicio rd
    join receita_componentes rc on rc.prato_id = rd.prato_id
    join ingredientes i on i.id = rc.ingrediente_id
    where rd.tipo_perda = 'prato'
      and rc.ingrediente_id = p_ingrediente_id
      and rd.loja_id = p_loja_id
      and rd.data > p_data_referencia - p_dias_historico
      and rd.data <= p_data_referencia

    union all

    select converter(rd.quantidade * ov.quantidade, ov.unidade, i.unidade_base, i.id) as qtd_base
    from registros_desperdicio rd
    join registro_desperdicio_opcoes_selecionadas s on s.registro_desperdicio_id = rd.id
    join receita_opcoes_variaveis ov on ov.id = s.opcao_id
    join ingredientes i on i.id = ov.ingrediente_id
    where rd.tipo_perda = 'prato'
      and ov.ingrediente_id = p_ingrediente_id
      and rd.loja_id = p_loja_id
      and rd.data > p_data_referencia - p_dias_historico
      and rd.data <= p_data_referencia
  ) perdas;

  return v_total_base / p_dias_historico;
end;
$$;

-- ----------------------------------------------------------------------------
-- calcular_pedido_sugerido: implementa o cálculo do Módulo 6.
--
--   consumo_esperado  = (consumo_teorico_base + desperdicio_periodo)
--                        × fator_sazonalidade_passada × fator_sazonalidade_futura
--   necessidade_bruta = max(consumo_esperado − estoque_atual, 0)
--   pedido_sugerido   = ceil(necessidade_bruta em unidade_compra ÷ lote_minimo)
--                        × lote_minimo
--
-- p_consumo_teorico_base (unidade_base, referente ao período de cobertura
-- inteiro) é passado explicitamente por quem chama — não há Módulo 5 ainda
-- para calculá-lo aqui a partir de vendas × receita. Passar 0 (padrão)
-- isola o cálculo só na parte de desperdício/estoque/sazonalidade,
-- útil para testar o motor com os dados reais que já existem.
--
-- Simplificação conhecida: estoque_atual usa a contagem mais recente até
-- p_data_pedido, sem descontar o consumo que ainda vai acontecer entre a
-- data do pedido (quinta) e a chegada (segunda seguinte) — o formulário do
-- spec ("necessidade_bruta = consumo_esperado − estoque_atual") não separa
-- essa janela pré-chegada. Refinar se isso se mostrar relevante na prática.
-- ----------------------------------------------------------------------------

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
  order by ce.data desc
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
