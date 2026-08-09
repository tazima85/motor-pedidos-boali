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

-- Frango Desfiado (não Frango Crocante!) como opção padrão do grupo
-- Proteína de "Wrap Frango Picante" — corrigido pelo usuário: a associação
-- original com Frango Crocante estava errada. Pra desperdício desse prato,
-- o sistema não pergunta mais qual proteína foi usada, assume a marcada aqui.
update receita_opcoes_variaveis
set padrao = (ingrediente_id = (select id from ingredientes where nome = 'Frango desfiado'))
where grupo_id = (
    select g.id from receita_grupos_variaveis g
    join pratos p on p.id = g.prato_id
    where p.nome = 'Wrap Frango Picante' and g.nome = 'Proteína'
  );

-- ----------------------------------------------------------------------------
-- Pratos de teste adicionais para Frango Crocante (indicados pelo usuário,
-- não extraídos do Quadro de Receitas — "Wrap Crocante ao Pesto" não tinha
-- valor na linha "Frango crocante" da planilha original). Modelagem mínima
-- só para exercitar o fluxo: grupo Proteína com uma única opção (Frango
-- Crocante, 55g — mesma quantidade usada nos demais pratos da família Wrap),
-- marcada como padrão. Sem componentes_fixos (base do prato) — fora do
-- escopo do que foi pedido, não inventado.
-- ----------------------------------------------------------------------------

insert into pratos (nome, tipo)
select v.nome, 'customizavel'
from (values ('Wrap Crocante ao Pesto'), ('Bowl da Fazenda')) as v(nome)
where not exists (select 1 from pratos p where p.nome = v.nome);

insert into receita_grupos_variaveis (prato_id, nome, obrigatorio)
select p.id, 'Proteína', true
from pratos p
where p.nome in ('Wrap Crocante ao Pesto', 'Bowl da Fazenda')
  and not exists (
    select 1 from receita_grupos_variaveis g where g.prato_id = p.id and g.nome = 'Proteína'
  );

insert into receita_opcoes_variaveis (grupo_id, ingrediente_id, quantidade, unidade, padrao)
select g.id, i.id, 55, 'g', true
from receita_grupos_variaveis g
join pratos p on p.id = g.prato_id
join ingredientes i on i.nome = 'Frango Crocante'
where p.nome in ('Wrap Crocante ao Pesto', 'Bowl da Fazenda') and g.nome = 'Proteína'
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
-- Módulo 5 — Vendas reais da semana de 02/08/2026 a 08/08/2026
--
-- Fonte: relatório semanal por PLU do PDV (uploads/Vendas_PLU.xlsx, fora do
-- git — tem faturamento real). Granularidade real do dado é por período
-- (semana), não por venda individual, daí vendas.data_inicio/data_fim.
--
-- "Frango Crocante 70g (Proteína Extra)" modela o PLU 240004 — quando a
-- proteína de um prato é extra ou de um item montável, ela sai como PLU
-- próprio no PDV, então vira aqui um prato 'fixo' de um componente só,
-- reaproveitando a mesma decomposição por receita.
-- ----------------------------------------------------------------------------

update pratos set codigo_plu = '220002'
where nome = 'Wrap Frango Picante' and codigo_plu is distinct from '220002';

insert into pratos (nome, tipo, codigo_plu)
select 'Frango Crocante 70g (Proteína Extra)', 'fixo', '240004'
where not exists (select 1 from pratos where codigo_plu = '240004');

insert into receita_componentes (prato_id, ingrediente_id, quantidade, unidade)
select p.id, i.id, 70, 'g'
from pratos p
join ingredientes i on i.nome = 'Frango Crocante'
where p.codigo_plu = '240004'
  and not exists (
    select 1 from receita_componentes rc where rc.prato_id = p.id and rc.ingrediente_id = i.id
  );

insert into vendas (data_inicio, data_fim, loja_id, prato_id, quantidade, valor_total, desconto, impostos, liquido)
select '2026-08-02', '2026-08-08', l.id, p.id, v.quantidade, v.valor_total, v.desconto, v.impostos, v.liquido
from lojas l
join (values
  ('220002', 19,  846.10, 63.01, 0, 783.09),
  ('240004', 67,  608.20, 38.94, 0, 569.26)
) as v(codigo_plu, quantidade, valor_total, desconto, impostos, liquido) on true
join pratos p on p.codigo_plu = v.codigo_plu
where l.nome = 'Boali São Carlos'
  and not exists (
    select 1 from vendas ve
    where ve.prato_id = p.id and ve.loja_id = l.id
      and ve.data_inicio = '2026-08-02' and ve.data_fim = '2026-08-08'
  );

-- ----------------------------------------------------------------------------
-- Módulo 4 — catálogo completo de produtos (uploads/CONTAGEM ESTOQUE 25.2026.pdf)
--
-- Tabela-base real da Comfrio usada na contagem física da loja. Extração
-- automática de nome/unidade a partir do texto do PDF (código de 13
-- dígitos colado ao fim do nome do produto, sem separador) — primeira
-- passada, tal como o spec original já previa ("pode conter alguns itens
-- a ajustar manualmente antes de considerar definitiva"). Use a tela
-- ingredientes.html pra corrigir nome/unidade/posição depois de revisar.
-- unidade_contagem_padrao nulo = nenhum token de unidade reconhecível no
-- texto original (ex. "ABACAXI CONG 20X100GR- 2KG") — completar na mão.
-- Itens sem código de fornecedor (hortifruti fresco, sem SKU Comfrio) usam
-- TEMP-XXX, seguindo a convenção do Módulo 1.
--
-- unidade_base é um chute conservador (a maioria em 'g'; 'ml' para líquidos
-- óbvios; 'un' para descartáveis/embalagens) — só importa de verdade quando
-- o item entrar numa receita; não bloqueia nada até lá.
-- ----------------------------------------------------------------------------

insert into ingredientes (codigo_fornecedor, nome, unidade_base, unidade_contagem_padrao)
select v.codigo, v.nome, v.unidade_base, v.unidade_contagem
from (values
  ('0101013100028', 'FILE FRANGO GRELHAD', 'g', 'cx'),
  ('0101013100026', 'FRANGO DESFIADO', 'g', 'cx'),
  ('0101013100300', 'FRANGO EMPANADISSIMO', 'g', 'cx'),
  ('0101013100192', 'CARNE DESFIADA BOVINA', 'g', 'cx'),
  ('0101013100101', 'BROWNIE CHOCOLATE', 'g', 'cx'),
  ('0101013100100', 'COOKIE DE CHOCOLATE', 'g', 'cx'),
  ('0101013100188', 'ABACAXI CONG 20X100GR- 2KG', 'g', null),
  ('0101013100055', 'ACAI FROOTY', 'ml', 'bd'),
  ('0101013100060', 'BROCOLIS GRANO', 'g', 'pct'),
  ('0101013100307', 'ESPINAFRE FOLHA', 'g', 'pct'),
  ('0101013100190', 'FRUTAS VERMELHAS CONG 20X100GR- 2KG', 'g', null),
  ('0101013100186', 'LIMAO CONG 20X100G', 'g', null),
  ('0101013100189', 'MANGA CONG 20X100GR - 2KG', 'g', null),
  ('0101013100185', 'MARACUJA CONG 20X100GR- 2KG', 'g', null),
  ('0101013100139', 'MILHO DOCE', 'g', 'pct'),
  ('0101013100187', 'MORANGO CONG 20X100GR- 2KG', 'g', null),
  ('0101013100056', 'PITAYA FROOTY', 'ml', 'bd'),
  ('0101013100239', 'POLPA DE AVOCADO', 'g', 'cx'),
  ('0101013100398', 'BRIGADEIRO', 'g', 'cx'),
  ('0101013100380', 'CANJA DE QUINOA', 'g', 'cx'),
  ('0101013100399', 'EMPANADA MISTA', 'g', 'cx'),
  ('0101013100400', 'FALAFEL', 'g', 'cx'),
  ('0101013100249', 'HOMUS DERBAK', 'g', 'cx'),
  ('0101013100022', 'MOLHO PESTO', 'g', 'cx'),
  ('0101013100397', 'TORTINHA DE MACA', 'g', 'cx'),
  ('0101013100230', 'CIABATTA PRE ASSADO', 'g', 'cx'),
  ('0101013100316', 'PAO D/BAT INT PERU C/CR', 'g', 'cx'),
  ('0101013100415', 'PAO DE QUEIJO BOALI 12PCT 8UN', 'g', null),
  ('0101013100110', 'TORTILLA TRIGO INTEG', 'g', 'cx'),
  ('0101013100365', 'SALMAO CONG CUBOS', 'g', 'cx'),
  ('0101013100207', 'OVO DE CODORNA CONS.', 'g', 'pct'),
  ('0101013100118', 'CREAM CHEESE DANUBIO', 'g', 'cx'),
  ('0101013100070', 'MUSSARELA DE BUFALA', 'g', 'bd'),
  ('0101013100325', 'MUSSARELA FIORLAT', 'g', 'pc'),
  ('0101013100119', 'QJO GORGONZOLA VIGOR', 'g', 'pc'),
  ('0101013100409', 'QJO PARMESAO BURITIS', 'g', 'pc'),
  ('0101013100410', 'RICOTA FRESCA BURITIS APROX 400GR', 'g', null),
  ('0101013100387', 'KOMBUCHA FRUTAS VERMELHAS', 'g', 'fd'),
  ('0101013100214', 'ACUCAR GUARANI', 'g', 'cx'),
  ('0101013100215', 'ADOCANTE SUCRALOSE', 'g', 'cx'),
  ('0101013100216', 'SAL SACHE', 'g', 'cx'),
  ('0101013100376', 'CHIPS DE COCO FLOWPACK', 'g', 'cx'),
  ('0101013100052', 'CHIPS MIX BATAT DOCE', 'g', 'cx'),
  ('0101013100240', 'COLHER MESA OGMA 6', 'un', 'pc'),
  ('0101013100385', 'CHA GASEIFICADO HIBISCO MORAN', 'g', 'fd'),
  ('0101013100384', 'REFR. DEVI GUARANA ACAI', 'g', 'fd'),
  ('0101013100382', 'REFR. DEVI LIMAO SICILIANO', 'g', 'fd'),
  ('0101013100277', 'SUCO LARANJA', 'g', 'fd'),
  ('0101013100080', 'SUCO UVA E MACA', 'g', 'fd'),
  ('0101013100121', 'WEWI GUARANA ORG', 'g', 'fd'),
  ('0101013100123', 'WEWI GUARANA ZERO', 'g', 'fd'),
  ('0101013100077', 'AZEITONA PRETA FAT', 'g', 'cx'),
  ('0101013100248', 'CEBOLA CRISPY', 'g', 'cx'),
  ('0101013100324', 'PALMITO PUP PICADO', 'g', 'cx'),
  ('0101013100000', 'BOBINA PLAST PIC 20X30', 'un', 'un'),
  ('0101013100232', 'BOBINA TERMICA BOALI', 'un', 'cx'),
  ('0101013100369', 'CANUDO BIO 10MM', 'un', 'cx'),
  ('0101013100290', 'COPO 330 ML BOALI', 'un', 'cx'),
  ('0101013100203', 'COPO 440ML BOALI', 'un', 'cx'),
  ('0101013100105', 'ETIQUETA BROWNIE', 'un', 'rl'),
  ('0101013100106', 'ETIQUETA COOKIE', 'un', 'rl'),
  ('0101013100103', 'ETIQUETA DELIVERY', 'un', 'rl'),
  ('0101013100102', 'ETIQUETA VALIDADE', 'un', 'rl'),
  ('0101013100318', 'ETIQUETAS CHIPS', 'un', 'rl'),
  ('0101013100250', 'FOLHA DUOFRESH', 'un', 'cx'),
  ('0101013100144', 'GARRAFA PET 500 ML', 'un', 'fd'),
  ('0101013100116', 'GUARDANAPO 40X15', 'un', 'cx'),
  ('0101013100117', 'LAMINA WRAP LIS', 'un', 'cx'),
  ('0101013100003', 'LUVA DESC', 'un', 'pct'),
  ('0101013100004', 'PANO MULTIUSO', 'un', 'pct'),
  ('0101013100005', 'PAPEL TOALHA BRANCO', 'un', 'pct'),
  ('0101013100342', 'PORTA TALHER 25X7CM', 'un', 'pct'),
  ('0101013100401', 'POTE P/ MOLHOS BOALI 60ML', 'un', 'cx'),
  ('0101013100006', 'REDE CABELO PRETA', 'un', 'pct'),
  ('0101013100007', 'ROLO FILME PVC 40CM', 'un', 'un'),
  ('0101013100008', 'SACO COOKIE E PROT', 'un', 'pct'),
  ('0101013100349', 'SACO G BOALI', 'un', 'pct'),
  ('0101013100009', 'SACO LIXO PRETO 200LT', 'un', 'pct'),
  ('0101013100343', 'SACO M BOALI', 'un', 'pct'),
  ('0101013100363', 'TAMPA COPO 440ML', 'un', 'cx'),
  ('0101013100330', 'COOKIE PROTEICO', 'g', 'cx'),
  ('0101013100361', 'PACOCA ZERO ACUCAR BOALI DISPLAY 24', 'g', 'un'),
  ('0101013100073', 'AMENDOA', 'g', 'pct'),
  ('0101013100407', 'ARROZ MIX BOALI', 'g', 'pct'),
  ('0101013100371', 'GERGELIM ESCURO', 'g', 'pct'),
  ('0101013100362', 'BEBIDA DE AVEIA NUDE BARISTA 1L', 'ml', null),
  ('0101013100151', 'MOLHO ARABE', 'g', 'cx'),
  ('0101013100299', 'MOLHO BUFALLO RANCH', 'g', 'cx'),
  ('0101013100154', 'MOLHO CAESAR', 'g', 'cx'),
  ('0101013100340', 'MOLHO HONEY MUSTARD', 'g', 'cx'),
  ('0101013100176', 'MOLHO LIMAO AZEITE', 'g', 'cx'),
  ('0101013100328', 'AZEITE OLIV EV GALLO', 'ml', 'gl'),
  ('0101013100273', 'BANANINHA ZR ACUCAR 04X32X23G', 'g', null),
  ('0101013100408', 'BARRA CHOC CARAM FLOR DE SAL', 'g', 'cx'),
  ('0101013100346', 'BOWL BOALI 1L', 'ml', 'cx'),
  ('0101013100347', 'BOWL BOALI 500ML', 'g', 'cx'),
  ('0101013100345', 'CAIXA WRAP BOALI', 'g', 'pct'),
  ('0101013100243', 'FACA CHURR OGMA 6', 'un', 'pc'),
  ('0101013100075', 'FROOTIVA ACAI MACA', 'g', 'pct'),
  ('0101013100241', 'GARFO MESA OGMA 6', 'un', 'pc'),
  ('0101013100350', 'PAPEL BANDEJA', 'un', 'pct'),
  ('0101013100413', 'PINATI BANANA CHOC DISPLAY 32UN', 'g', null),
  ('0101013100334', 'PIPOC CARA. FLOR SAL', 'g', 'cx'),
  ('0101013100335', 'PIPOC PARMES AZEITE', 'g', 'cx'),
  ('0101013100358', 'PUSH MATCHA 120G', 'g', null),
  ('0101013100352', 'TAMPA BOWL 1L', 'un', 'cx'),
  ('0101013100351', 'TAMPA BOWL 500 ML', 'un', 'cx'),
  ('0101013100378', 'WHEY BAUNILHA 100% PURE POTE 900G', 'un', null),
  ('0101013100360', 'CROUTON INTEGRAL', 'g', 'cx'),
  ('0101013100406', 'MACARRAO FUSILLI SUPERIORE 500GR', 'g', 'fd'),
  ('0101013100002', 'ESPONJA DUPLA FACE', 'un', 'pct'),
  ('0101013100357', 'GEL HIGIENIZADOR 4X500ML', 'g', null),
  ('0101013100042', 'KAY OV LIMP FORNO TURB 1LT', 'g', null),
  ('0101013100355', 'KAY QSR DET CONCENT SP BB 2L', 'ml', null),
  ('0101013100353', 'KAY QSR VIDRO E MULTIUSO BB 2L', 'ml', null),
  ('0101013100041', 'KAY-5 SANITIZANTE', 'g', 'bd'),
  ('0101013100356', 'QSR SAB LIQ ANTISSEPT 4X500ML', 'g', null),
  ('TEMP-001', 'EXTRATO DE TOMATE', 'g', null),
  ('TEMP-002', 'VINAGRE DE MAÇA', 'g', null),
  ('TEMP-003', 'FEIJÃO COM FAROFA DE AMÊNDOAS', 'g', null),
  ('TEMP-004', 'GERGELIM PRETO', 'g', null),
  ('TEMP-005', 'MOLHO POKE', 'g', null),
  ('TEMP-006', 'MOLHO TERIRIAKY', 'g', null),
  ('TEMP-007', 'MIX BRASIL', 'g', null),
  ('TEMP-008', 'MIX DE VERDES', 'g', null),
  ('TEMP-009', 'ALFACE AMERICANA', 'g', null),
  ('TEMP-010', 'CENOURA RALADA', 'g', null),
  ('TEMP-011', 'CENOURA PALITO', 'g', null),
  ('TEMP-012', 'TOMATE', 'g', null),
  ('TEMP-013', 'PEPINO', 'g', null),
  ('TEMP-014', 'HORTELÃ', 'g', null),
  ('TEMP-015', 'ALHO EM PÓ', 'g', null),
  ('TEMP-016', 'GENGIBRE EM PÓ', 'g', null),
  ('TEMP-017', 'AGUA SEM GAS', 'g', null),
  ('TEMP-018', 'AGUA COM GAS', 'g', null),
  ('TEMP-019', 'OVO IN NATURA', 'g', null)
) as v(codigo, nome, unidade_base, unidade_contagem)
where not exists (
  select 1 from ingredientes i where i.codigo_fornecedor = v.codigo
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
