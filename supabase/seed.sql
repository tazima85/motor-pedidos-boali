-- ============================================================================
-- Sistema de Previsão de Insumos — Boali
-- Seed 0001: Frango Crocante ponta a ponta
--
-- Fontes reais:
--   - uploads/Quadro_Receitas_Completo_2026 (2).xlsx → receita do prato
--     "Wrap Frango Picante" (único prato onde "Frango crocante" aparece como
--     opção do grupo Proteína) — seção BASE (linhas 5-12) + seção PROTEÍNA
--     (linhas 36-41).
--   - uploads/Pedido 1652340949691-01.xlsx → item real da Comfrio
--     "FRANGO EMPANADISSIMO CX4KG" (código 0101013100300), 1 caixa = 10
--     pacotes de 400g.
--
-- Idempotente: cada bloco só insere se o registro correspondente ainda não
-- existir, então pode rodar mais de uma vez sem duplicar.
-- ============================================================================

set search_path to motor_pedidos, public;

-- ----------------------------------------------------------------------------
-- Fornecedor e loja
-- ----------------------------------------------------------------------------

insert into fornecedores (nome)
select 'Comfrio'
where not exists (select 1 from fornecedores where nome = 'Comfrio');

-- BOA-SAO / saocarlos@redeboali.com.br no cabeçalho do pedido Comfrio.
insert into lojas (nome)
select 'Boali São Carlos'
where not exists (select 1 from lojas where nome = 'Boali São Carlos');

-- ----------------------------------------------------------------------------
-- Módulo 1 — Frango Crocante (o ingrediente sob teste)
--
-- Mesmo ingrediente usado tanto na compra (Comfrio, em caixa) quanto na
-- receita (em gramas) e na contagem (em pacote) — só muda a unidade, sem
-- fator de rendimento de cocção modelado por enquanto.
-- ----------------------------------------------------------------------------

insert into ingredientes (
  codigo_fornecedor, nome, unidade_base, fornecedor_padrao_id,
  unidade_compra_fornecedor, unidade_contagem_padrao, lote_minimo_compra
)
select
  '0101013100300', 'Frango Crocante', 'g', f.id,
  'caixa', 'pacote', 1
from fornecedores f
where f.nome = 'Comfrio'
  and not exists (select 1 from ingredientes where codigo_fornecedor = '0101013100300');

-- 1 caixa Comfrio = 10 pacotes de 400g = 4000g
insert into unidades_conversao (ingrediente_id, unidade, fator_para_base)
select i.id, 'pacote', 400
from ingredientes i
where i.codigo_fornecedor = '0101013100300'
  and not exists (
    select 1 from unidades_conversao uc where uc.ingrediente_id = i.id and uc.unidade = 'pacote'
  );

insert into unidades_conversao (ingrediente_id, unidade, fator_para_base)
select i.id, 'caixa', 4000
from ingredientes i
where i.codigo_fornecedor = '0101013100300'
  and not exists (
    select 1 from unidades_conversao uc where uc.ingrediente_id = i.id and uc.unidade = 'caixa'
  );

-- ----------------------------------------------------------------------------
-- Módulo 1 — ingredientes de apoio (demais componentes do Wrap Frango
-- Picante). Cadastro mínimo (nome + unidade_base) — sem código de fornecedor
-- nem conversões de compra ainda, fora do escopo desta validação.
-- ----------------------------------------------------------------------------

insert into ingredientes (nome, unidade_base)
select v.nome, v.unidade_base
from (values
  -- BASE
  ('Mix de alfaces',  'g'),
  ('Tortilha',        'un'),
  ('Folhas estação',  'g'),
  ('Cream cheese',    'g'),
  ('Homus',           'g'),
  ('Pão ciabatta',    'g'),
  ('Mix de arroz',    'g'),
  ('Pasta salad',     'g'),
  -- PROTEÍNA (demais opções do grupo, além de Frango Crocante)
  ('Frango desfiado', 'g'),
  ('Salmão',          'g'),
  ('Falafel',          'g'),
  ('Frango em cubos', 'g'),
  ('Carne desfiada',  'g')
) as v(nome, unidade_base)
where not exists (select 1 from ingredientes i where i.nome = v.nome);

-- ----------------------------------------------------------------------------
-- Módulo 2 — Wrap Frango Picante
-- ----------------------------------------------------------------------------

insert into pratos (nome, tipo)
select 'Wrap Frango Picante', 'customizavel'
where not exists (select 1 from pratos where nome = 'Wrap Frango Picante');

-- Componentes fixos (seção BASE do Quadro de Receitas)
insert into receita_componentes (prato_id, ingrediente_id, quantidade, unidade)
select p.id, i.id, v.quantidade, v.unidade
from pratos p
join (values
  ('Mix de alfaces',  40, 'g'),
  ('Tortilha',         1, 'un'),
  ('Folhas estação',  14, 'g'),
  ('Cream cheese',    20, 'g'),
  ('Homus',           31, 'g'),
  ('Pão ciabatta',    17, 'g'),
  ('Mix de arroz',    23, 'g'),
  ('Pasta salad',     27, 'g')
) as v(ingrediente_nome, quantidade, unidade) on true
join ingredientes i on i.nome = v.ingrediente_nome
where p.nome = 'Wrap Frango Picante'
  and not exists (
    select 1 from receita_componentes rc where rc.prato_id = p.id and rc.ingrediente_id = i.id
  );

-- Grupo variável Proteína (seção PROTEÍNA do Quadro de Receitas)
insert into receita_grupos_variaveis (prato_id, nome, obrigatorio)
select p.id, 'Proteína', true
from pratos p
where p.nome = 'Wrap Frango Picante'
  and not exists (
    select 1 from receita_grupos_variaveis g where g.prato_id = p.id and g.nome = 'Proteína'
  );

insert into receita_opcoes_variaveis (grupo_id, ingrediente_id, quantidade, unidade)
select g.id, i.id, v.quantidade, 'g'
from receita_grupos_variaveis g
join pratos p on p.id = g.prato_id
join (values
  ('Frango desfiado', 60),
  ('Frango Crocante', 55),  -- quantidade padrão de 55g nesta receita
  ('Salmão',          57),
  ('Falafel',         25),
  ('Frango em cubos', 60),
  ('Carne desfiada',  35)
) as v(ingrediente_nome, quantidade) on true
join ingredientes i on i.nome = v.ingrediente_nome
where p.nome = 'Wrap Frango Picante' and g.nome = 'Proteína'
  and not exists (
    select 1 from receita_opcoes_variaveis o where o.grupo_id = g.id and o.ingrediente_id = i.id
  );

-- ----------------------------------------------------------------------------
-- Módulo 3 — Desperdício: 2 Wrap Frango Picante com Frango Crocante
-- ----------------------------------------------------------------------------

insert into registros_desperdicio (data, loja_id, tipo_perda, prato_id, quantidade, unidade)
select '2026-08-06', l.id, 'prato', p.id, 2, 'un'
from lojas l
join pratos p on p.nome = 'Wrap Frango Picante'
where l.nome = 'Boali São Carlos'
  and not exists (
    select 1 from registros_desperdicio rd
    where rd.loja_id = l.id and rd.prato_id = p.id and rd.data = '2026-08-06' and rd.quantidade = 2
  );

-- registra que, nesse evento, a opção usada no grupo Proteína foi "Frango Crocante"
insert into registro_desperdicio_opcoes_selecionadas (registro_desperdicio_id, grupo_id, opcao_id)
select rd.id, g.id, o.id
from registros_desperdicio rd
join pratos p on p.id = rd.prato_id and p.nome = 'Wrap Frango Picante'
join receita_grupos_variaveis g on g.prato_id = p.id and g.nome = 'Proteína'
join receita_opcoes_variaveis o on o.grupo_id = g.id
join ingredientes ic on ic.id = o.ingrediente_id and ic.nome = 'Frango Crocante'
where rd.data = '2026-08-06' and rd.quantidade = 2
  and not exists (
    select 1 from registro_desperdicio_opcoes_selecionadas s
    where s.registro_desperdicio_id = rd.id and s.grupo_id = g.id
  );

-- ----------------------------------------------------------------------------
-- Módulo 4 — Contagem de estoque, por pacote
--
-- Valor de exemplo (6 pacotes) só para exercitar o fluxo — substituir pela
-- contagem física real na próxima rodada.
-- ----------------------------------------------------------------------------

insert into contagens_estoque (data, loja_id, ingrediente_id, quantidade, unidade)
select '2026-08-07', l.id, i.id, 6, 'pacote'
from lojas l
join ingredientes i on i.codigo_fornecedor = '0101013100300'
where l.nome = 'Boali São Carlos'
  and not exists (
    select 1 from contagens_estoque ce
    where ce.loja_id = l.id and ce.ingrediente_id = i.id and ce.data = '2026-08-07'
  );

-- ----------------------------------------------------------------------------
-- Verificação manual (não faz parte do seed — só para conferir o resultado):
--
-- -- estoque atual de Frango Crocante convertido para a unidade base (g)
-- select converter(ce.quantidade, ce.unidade, i.unidade_base, i.id) as estoque_g
-- from contagens_estoque ce
-- join ingredientes i on i.id = ce.ingrediente_id
-- where i.codigo_fornecedor = '0101013100300';
--
-- -- pedido sugerido: converter o mesmo estoque para a unidade de compra (caixa)
-- select converter(ce.quantidade, ce.unidade, i.unidade_compra_fornecedor, i.id) as estoque_caixas
-- from contagens_estoque ce
-- join ingredientes i on i.id = ce.ingrediente_id
-- where i.codigo_fornecedor = '0101013100300';
--
-- -- decomposição do desperdício de "2 Wrap Frango Picante" em ingredientes base
-- select ing.nome, rd.quantidade * rc.quantidade as qtd_total, rc.unidade
-- from registros_desperdicio rd
-- join receita_componentes rc on rc.prato_id = rd.prato_id
-- join ingredientes ing on ing.id = rc.ingrediente_id
-- where rd.data = '2026-08-06' and rd.tipo_perda = 'prato'
-- union all
-- select ing.nome, rd.quantidade * ov.quantidade, ov.unidade
-- from registros_desperdicio rd
-- join registro_desperdicio_opcoes_selecionadas s on s.registro_desperdicio_id = rd.id
-- join receita_opcoes_variaveis ov on ov.id = s.opcao_id
-- join ingredientes ing on ing.id = ov.ingrediente_id
-- where rd.data = '2026-08-06' and rd.tipo_perda = 'prato';
-- ----------------------------------------------------------------------------
