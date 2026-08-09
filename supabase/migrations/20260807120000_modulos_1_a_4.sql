-- ============================================================================
-- Sistema de Previsão de Insumos — Boali
-- Migração 0001: Módulos 1-4 (Ingredientes, Receitas, Desperdício, Estoque)
--
-- Escopo: modelagem genérica para centenas de produtos; dados reais de
-- testes limitados ao Frango Crocante (ver supabase/seed.sql).
--
-- Roda no schema motor_pedidos (não em public) para conviver isolado de
-- outros projetos hospedados no mesmo projeto Supabase (Reports Boali). O
-- search_path é setado uma vez aqui; toda referência não qualificada neste
-- arquivo (tabelas, índices, FKs) resolve para motor_pedidos por causa disso.
-- gen_random_uuid() é built-in desde o Postgres 13, não precisa de extensão.
-- ============================================================================

create schema if not exists motor_pedidos;
set search_path to motor_pedidos, public;

-- ----------------------------------------------------------------------------
-- Suporte: lojas, fornecedores, setores
-- ----------------------------------------------------------------------------

create table lojas (
  id          uuid primary key default gen_random_uuid(),
  nome        text not null,
  ativa       boolean not null default true,
  created_at  timestamptz not null default now()
);

create table fornecedores (
  id          uuid primary key default gen_random_uuid(),
  nome        text not null,
  created_at  timestamptz not null default now()
);

-- "Posição na Loja": setor/local físico de armazenamento. Todo ingrediente
-- começa no setor único (seed abaixo); setores reais são cadastrados depois
-- para permitir ordenar a lista de contagem por proximidade física.
--
-- id fixo (não gerado) para o setor seed: o Postgres não permite subquery
-- em DEFAULT de coluna, então ingredientes.setor_id usa esta constante
-- diretamente como valor padrão em vez de resolver "Setor Único" por nome.
create table setores (
  id          uuid primary key default gen_random_uuid(),
  nome        text not null,
  ordem       integer not null default 1,
  created_at  timestamptz not null default now()
);

insert into setores (id, nome, ordem)
values ('00000000-0000-0000-0000-000000000001', 'Setor Único', 1);

-- ----------------------------------------------------------------------------
-- Módulo 1 — Cadastro de Ingredientes
-- ----------------------------------------------------------------------------

create table ingredientes (
  id                        uuid primary key default gen_random_uuid(),

  -- código do produto no fornecedor (ou TEMP-XXX para itens sem SKU, ex.
  -- hortifruti fresco) — chave de negócio usada para cruzar dados entre
  -- todos os módulos e para o de-para com a planilha do fornecedor (Comfrio).
  codigo_fornecedor         text unique,

  nome                      text not null,
  unidade_base              text not null check (unidade_base in ('g', 'ml', 'un')),

  fornecedor_padrao_id      uuid references fornecedores(id),

  -- unidade em que o fornecedor vende (deve existir em unidades_conversao
  -- para este ingrediente) — usada para converter o pedido sugerido na saída
  -- final do Módulo 6.
  unidade_compra_fornecedor text,

  -- unidade usada na tela de contagem de estoque (cx, pct, bd, fd, gl, pc,
  -- rl, unid...) — corresponde à coluna "Unidade de Medida" da planilha
  -- produtos_boali.xlsx. Pode ou não coincidir com unidade_base/compra.
  unidade_contagem_padrao   text,

  -- lote mínimo de compra, na unidade_compra_fornecedor (ex. 1 caixa fechada).
  -- Usado para arredondamento do pedido sugerido no Módulo 6.
  lote_minimo_compra        numeric not null default 1 check (lote_minimo_compra > 0),

  setor_id                  uuid not null references setores(id)
    default '00000000-0000-0000-0000-000000000001',

  ativo                     boolean not null default true,
  created_at                timestamptz not null default now()
);

create index idx_ingredientes_setor on ingredientes(setor_id);

-- Módulo 1 — unidades_alternativas: conversões para a unidade_base.
-- fator_para_base já é o multiplicador direto e achatado (ex. "caixa" com
-- N sacos de 1000g cada guarda fator_para_base = N * 1000), evitando
-- resolução recursiva de cadeias de conversão em tempo de cálculo.
create table unidades_conversao (
  id                uuid primary key default gen_random_uuid(),
  ingrediente_id    uuid not null references ingredientes(id) on delete cascade,
  unidade           text not null,
  fator_para_base   numeric not null check (fator_para_base > 0),
  created_at        timestamptz not null default now(),
  unique (ingrediente_id, unidade)
);

-- Função-chave do Módulo 1: converte uma quantidade entre unidades de um
-- ingrediente, sempre passando pela unidade_base internamente.
create or replace function converter(
  p_quantidade      numeric,
  p_unidade_origem  text,
  p_unidade_destino text,
  p_ingrediente_id  uuid
) returns numeric
language plpgsql
stable
set search_path = motor_pedidos, public
as $$
declare
  v_unidade_base    text;
  v_fator_origem    numeric;
  v_fator_destino   numeric;
  v_quantidade_base numeric;
begin
  select unidade_base into v_unidade_base
  from ingredientes where id = p_ingrediente_id;

  if v_unidade_base is null then
    raise exception 'Ingrediente % não encontrado', p_ingrediente_id;
  end if;

  if p_unidade_origem = v_unidade_base then
    v_fator_origem := 1;
  else
    select fator_para_base into v_fator_origem
    from unidades_conversao
    where ingrediente_id = p_ingrediente_id and unidade = p_unidade_origem;
  end if;

  if p_unidade_destino = v_unidade_base then
    v_fator_destino := 1;
  else
    select fator_para_base into v_fator_destino
    from unidades_conversao
    where ingrediente_id = p_ingrediente_id and unidade = p_unidade_destino;
  end if;

  if v_fator_origem is null then
    raise exception 'Conversão de "%" não cadastrada para o ingrediente %', p_unidade_origem, p_ingrediente_id;
  end if;
  if v_fator_destino is null then
    raise exception 'Conversão de "%" não cadastrada para o ingrediente %', p_unidade_destino, p_ingrediente_id;
  end if;

  v_quantidade_base := p_quantidade * v_fator_origem;
  return v_quantidade_base / v_fator_destino;
end;
$$;

-- ----------------------------------------------------------------------------
-- Módulo 2 — Receitas
-- ----------------------------------------------------------------------------

create table pratos (
  id          uuid primary key default gen_random_uuid(),
  nome        text not null,
  tipo        text not null check (tipo in ('fixo', 'customizavel')),
  ativo       boolean not null default true,
  created_at  timestamptz not null default now()
);

-- componentes_fixos: parte da receita presente em toda venda do prato,
-- independente de customização.
create table receita_componentes (
  id              uuid primary key default gen_random_uuid(),
  prato_id        uuid not null references pratos(id) on delete cascade,
  ingrediente_id  uuid not null references ingredientes(id),
  quantidade      numeric not null check (quantidade > 0),
  unidade         text not null,
  created_at      timestamptz not null default now()
);

create index idx_receita_componentes_prato on receita_componentes(prato_id);

-- componentes_variaveis: grupos de opções para pratos "montáveis"
-- (ex. saladas), cada grupo com uma lista de opções e sua quantidade padrão.
create table receita_grupos_variaveis (
  id          uuid primary key default gen_random_uuid(),
  prato_id    uuid not null references pratos(id) on delete cascade,
  nome        text not null,
  obrigatorio boolean not null default true,
  created_at  timestamptz not null default now()
);

create table receita_opcoes_variaveis (
  id              uuid primary key default gen_random_uuid(),
  grupo_id        uuid not null references receita_grupos_variaveis(id) on delete cascade,
  ingrediente_id  uuid not null references ingredientes(id),
  quantidade      numeric not null check (quantidade > 0),
  unidade         text not null,

  -- usada como fallback de distribuição média quando o Módulo 5 não
  -- registra os componentes efetivamente escolhidos por pedido.
  padrao          boolean not null default false,

  created_at      timestamptz not null default now()
);

create index idx_receita_opcoes_grupo on receita_opcoes_variaveis(grupo_id);

-- ----------------------------------------------------------------------------
-- Módulo 3 — Registro de Desperdício
-- ----------------------------------------------------------------------------

create table registros_desperdicio (
  id              uuid primary key default gen_random_uuid(),
  data            date not null,
  loja_id         uuid not null references lojas(id),
  tipo_perda      text not null check (tipo_perda in ('prato', 'ingrediente_bruto')),

  prato_id        uuid references pratos(id),
  ingrediente_id  uuid references ingredientes(id),

  quantidade      numeric not null check (quantidade > 0),
  unidade         text not null,

  -- não afeta o cálculo do motor, mas é dado valioso para relatórios
  -- (validade vencida, erro de preparo, queda/acidente, etc.)
  motivo          text,

  created_at      timestamptz not null default now(),

  constraint chk_referencia_por_tipo check (
    (tipo_perda = 'prato' and prato_id is not null and ingrediente_id is null)
    or
    (tipo_perda = 'ingrediente_bruto' and ingrediente_id is not null and prato_id is null)
  )
);

create index idx_desperdicio_loja_data on registros_desperdicio(loja_id, data);
create index idx_desperdicio_ingrediente on registros_desperdicio(ingrediente_id);
create index idx_desperdicio_prato on registros_desperdicio(prato_id);

-- ----------------------------------------------------------------------------
-- Módulo 4 — Contagem de Estoque
-- ----------------------------------------------------------------------------

create table contagens_estoque (
  id              uuid primary key default gen_random_uuid(),
  data            date not null,
  loja_id         uuid not null references lojas(id),
  ingrediente_id  uuid not null references ingredientes(id),
  quantidade      numeric not null check (quantidade >= 0),
  unidade         text not null,
  created_at      timestamptz not null default now()
);

create index idx_contagens_loja_data on contagens_estoque(loja_id, data);
create index idx_contagens_ingrediente on contagens_estoque(ingrediente_id);

-- ----------------------------------------------------------------------------
-- RLS — MVP: qualquer usuário autenticado (equipe de loja) pode ler e
-- escrever. Refinar por papel/loja quando houver mais de uma loja em uso.
-- ----------------------------------------------------------------------------

alter table lojas enable row level security;
alter table fornecedores enable row level security;
alter table setores enable row level security;
alter table ingredientes enable row level security;
alter table unidades_conversao enable row level security;
alter table pratos enable row level security;
alter table receita_componentes enable row level security;
alter table receita_grupos_variaveis enable row level security;
alter table receita_opcoes_variaveis enable row level security;
alter table registros_desperdicio enable row level security;
alter table contagens_estoque enable row level security;

do $$
declare
  t text;
begin
  foreach t in array array[
    'lojas', 'fornecedores', 'setores', 'ingredientes', 'unidades_conversao',
    'pratos', 'receita_componentes', 'receita_grupos_variaveis',
    'receita_opcoes_variaveis', 'registros_desperdicio', 'contagens_estoque'
  ]
  loop
    execute format(
      'create policy %I on motor_pedidos.%I for all to authenticated using (true) with check (true)',
      t || '_authenticated_all', t
    );
  end loop;
end $$;
