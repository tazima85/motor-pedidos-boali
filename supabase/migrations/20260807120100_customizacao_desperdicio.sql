-- ============================================================================
-- Sistema de Previsão de Insumos — Boali
-- Migração 0002: rastreio de customização em registros de desperdício
--
-- Motivado por dado real: no Quadro de Receitas, quase todo prato é montado a
-- partir de uma base fixa + grupos de opções (Proteína, Molho, Crocante,
-- Cobertura, Finalização, Salad Bar). Uma perda de "prato" só decompõe
-- corretamente pela receita (Módulo 2) se soubermos qual opção foi
-- efetivamente usada em cada grupo variável daquele evento específico —
-- o schema 0001 só guardava o prato, não as escolhas dentro dele.
-- ============================================================================

set search_path to motor_pedidos, public;

-- Uma linha por grupo variável efetivamente resolvido num registro de
-- desperdício de tipo_perda='prato' (ex.: grupo "Proteína" → opção "Frango
-- crocante"). Grupos não mencionados aqui ficam em aberto — a decomposição
-- usa apenas os componentes fixos + as opções explicitamente registradas.
create table registro_desperdicio_opcoes_selecionadas (
  id                       uuid primary key default gen_random_uuid(),
  registro_desperdicio_id  uuid not null references registros_desperdicio(id) on delete cascade,
  grupo_id                 uuid not null references receita_grupos_variaveis(id),
  opcao_id                 uuid not null references receita_opcoes_variaveis(id),
  created_at               timestamptz not null default now(),

  -- uma escolha por grupo por evento (ex. não dá pra escolher duas proteínas
  -- na mesma unidade perdida). Revisar se algum grupo passar a aceitar
  -- múltiplas opções simultâneas (ex. dois toppings de um salad bar).
  unique (registro_desperdicio_id, grupo_id)
);

create index idx_desperdicio_opcoes_registro on registro_desperdicio_opcoes_selecionadas(registro_desperdicio_id);

-- Nota: não há trigger garantindo que opcao_id pertence a grupo_id, nem que
-- grupo_id pertence ao prato_id do registro_desperdicio referenciado — a
-- integridade dessa relação fica por conta da aplicação por enquanto.

alter table registro_desperdicio_opcoes_selecionadas enable row level security;

create policy registro_desperdicio_opcoes_selecionadas_authenticated_all
  on registro_desperdicio_opcoes_selecionadas
  for all to authenticated using (true) with check (true);
