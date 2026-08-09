-- ============================================================================
-- Sistema de Previsão de Insumos — Boali
-- Migração 0007: Módulo 5 — Ingestão de Vendas
--
-- Fonte real: relatório semanal por PLU do PDV (uploads/Vendas_PLU.xlsx,
-- mantido fora do git — dados de faturamento reais). Granularidade real do
-- dado: total por PLU/loja num PERÍODO (semana), não por venda individual —
-- então `vendas` registra agregados de período, não transações soltas.
--
-- Achado real que simplifica o modelo: quando o cliente escolhe uma opção
-- variável (ex. proteína) em um prato montável, OU pede um complemento
-- extra em qualquer prato, isso sai como um PLU próprio na venda — não
-- precisamos decompor "qual opção foi escolhida" a partir do prato base,
-- porque o complemento já É a sua própria linha de venda. Na prática isso
-- significa modelar cada PLU de complemento (ex. "Frango Crocante 70g" como
-- proteína avulsa) como um `prato` simples de tipo 'fixo' com um único
-- componente_fixo — reaproveita a decomposição por receita que já existe,
-- sem precisar de uma tabela de seleção de opções como a do Módulo 3 (0002).
-- ============================================================================

set search_path to motor_pedidos, public;

-- código do produto no PDV — chave de cruzamento com o relatório de vendas,
-- mesmo papel que ingredientes.codigo_fornecedor cumpre para o Módulo 1.
alter table pratos add column codigo_plu text unique;

-- Granularidade de período (não de venda individual) para bater com o
-- relatório real, que já vem agregado por semana/loja/PLU.
create table vendas (
  id              uuid primary key default gen_random_uuid(),
  data_inicio     date not null,
  data_fim        date not null,
  loja_id         uuid not null references lojas(id),
  prato_id        uuid not null references pratos(id),
  quantidade      numeric not null check (quantidade >= 0),

  -- não usados no cálculo do Módulo 6, mas vêm de graça no relatório e são
  -- dado valioso pra relatórios futuros.
  valor_total     numeric,
  desconto        numeric,
  impostos        numeric,
  liquido         numeric,

  created_at      timestamptz not null default now(),

  constraint chk_periodo_venda check (data_fim >= data_inicio)
);

create index idx_vendas_prato_loja_periodo on vendas (prato_id, loja_id, data_inicio, data_fim);

alter table vendas enable row level security;

create policy vendas_authenticated_all
  on vendas
  for all to authenticated using (true) with check (true);

-- ----------------------------------------------------------------------------
-- calcular_consumo_teorico_medio_diario: espelha
-- calcular_desperdicio_medio_diario (0005) na estrutura — soma o consumo
-- teórico real (vendas × receita, convertido pra unidade_base) numa janela
-- histórica e divide sempre pelo tamanho da janela inteira, não só pelos
-- dias com venda registrada.
--
-- Só considera componentes_fixos por enquanto. Grupos variáveis (Proteína,
-- Molho...) não entram aqui: pelo achado acima, um prato realmente
-- montável (ex. "Crie sua Salada") não deve ter essas opções como
-- componentes do SEU PRÓPRIO prato — elas chegam via PLUs de complemento
-- separados, que por sua vez são pratos 'fixo' de um componente só e caem
-- direto nesta mesma soma. Um prato de cardápio fixo (ex. Wrap Frango
-- Picante) que ainda usa receita_opcoes_variaveis sem uma opção `padrao`
-- marcada simplesmente não contribui a opção variável aqui — gap conhecido,
-- não dá pra assumir uma distribuição sem dado real de frequência de escolha.
-- ----------------------------------------------------------------------------

create or replace function calcular_consumo_teorico_medio_diario(
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
  select coalesce(sum(
    converter(v.quantidade * rc.quantidade, rc.unidade, i.unidade_base, i.id)
  ), 0) into v_total_base
  from vendas v
  join receita_componentes rc on rc.prato_id = v.prato_id
  join ingredientes i on i.id = rc.ingrediente_id
  where rc.ingrediente_id = p_ingrediente_id
    and v.loja_id = p_loja_id
    and v.data_inicio <= p_data_referencia
    and v.data_fim > p_data_referencia - p_dias_historico;

  return v_total_base / p_dias_historico;
end;
$$;

-- ----------------------------------------------------------------------------
-- calcular_pedido_sugerido: p_consumo_teorico_base passa a ser opcional
-- (default null). Quando null, calcula sozinho a partir de vendas reais
-- (calcular_consumo_teorico_medio_diario × dias_cobertura) — fecha o loop
-- ponta a ponta descrito no spec. Ainda aceita um valor explícito por
-- parâmetro pra testes/ajuste manual, como antes.
-- ----------------------------------------------------------------------------

create or replace function calcular_pedido_sugerido(
  p_ingrediente_id        uuid,
  p_loja_id               uuid,
  p_data_pedido           date,
  p_consumo_teorico_base  numeric default null
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
  v_periodo                record;
  v_dias                    integer;
  v_consumo_teorico_diario  numeric;
  v_consumo_teorico_base    numeric;
  v_desperdicio_diario      numeric;
  v_desperdicio_periodo     numeric;
  v_fator_passada           numeric;
  v_fator_futura            numeric;
  v_consumo_esperado        numeric;
  v_estoque_base            numeric;
  v_necessidade_bruta       numeric;
  v_unidade_base            text;
  v_unidade_compra          text;
  v_lote                    numeric;
  v_pedido_unidade_compra   numeric;
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

  if p_consumo_teorico_base is null then
    v_consumo_teorico_diario := calcular_consumo_teorico_medio_diario(p_ingrediente_id, p_loja_id, p_data_pedido);
    v_consumo_teorico_base := v_consumo_teorico_diario * v_dias;
  else
    v_consumo_teorico_base := p_consumo_teorico_base;
  end if;

  v_desperdicio_diario := calcular_desperdicio_medio_diario(p_ingrediente_id, p_loja_id, p_data_pedido);
  v_desperdicio_periodo := v_desperdicio_diario * v_dias;

  v_fator_passada := fator_sazonalidade_vigente('passada', 'ingrediente', p_ingrediente_id, p_data_pedido);
  v_fator_futura  := fator_sazonalidade_vigente('futura',  'ingrediente', p_ingrediente_id, p_data_pedido);

  v_consumo_esperado := (v_consumo_teorico_base + v_desperdicio_periodo) * v_fator_passada * v_fator_futura;

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
    v_consumo_teorico_base,
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
