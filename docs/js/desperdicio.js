import { supabase } from './supabase-client.js';
import { requireAuth } from './auth-guard.js';

await requireAuth();

const lojaLabel = document.getElementById('loja-label');
const form = document.getElementById('form');
const tipoPerdaSel = document.getElementById('tipo-perda');
const blocoPrato = document.getElementById('bloco-prato');
const blocoIngrediente = document.getElementById('bloco-ingrediente');
const pratoSel = document.getElementById('prato');
const gruposDiv = document.getElementById('grupos-variaveis');
const ingredienteSel = document.getElementById('ingrediente');
const unidadeIngredienteSel = document.getElementById('unidade-ingrediente');
const submitBtn = document.getElementById('submit-btn');
const msg = document.getElementById('msg');
const ultimosTbody = document.getElementById('ultimos-tbody');

const MOTIVO_LABEL = {
  validade_vencida: 'Validade vencida',
  erro_preparo: 'Erro de preparo',
  queda_acidente: 'Queda / acidente',
  outro: 'Outro',
};

let loja = null;
let ingredientesPorId = {};
let gruposPadrao = []; // [{ grupoId, grupoNome, opcaoId, opcaoNome }] do prato selecionado

async function carregarUltimos() {
  if (!loja) return;

  const { data, error } = await supabase
    .from('registros_desperdicio')
    .select('data, quantidade, unidade, motivo, prato:pratos(nome), ingrediente:ingredientes(nome)')
    .eq('loja_id', loja.id)
    .order('created_at', { ascending: false })
    .limit(10);

  if (error) {
    ultimosTbody.innerHTML = `<tr><td colspan="4" class="error">Erro ao carregar: ${error.message}</td></tr>`;
    return;
  }

  if (!data.length) {
    ultimosTbody.innerHTML = '<tr><td colspan="4" class="hint">Nenhum lançamento ainda.</td></tr>';
    return;
  }

  ultimosTbody.innerHTML = data
    .map((r) => {
      const item = r.prato?.nome ?? r.ingrediente?.nome ?? '—';
      const motivo = r.motivo ? (MOTIVO_LABEL[r.motivo] ?? r.motivo) : '—';
      return `<tr>
        <td>${r.data}</td>
        <td>${item}</td>
        <td>${r.quantidade} ${r.unidade}</td>
        <td>${motivo}</td>
      </tr>`;
    })
    .join('');
}

async function carregar() {
  const { data: lojas, error: lojaErr } = await supabase
    .from('lojas').select('id, nome').eq('ativa', true).limit(1);

  if (lojaErr || !lojas || lojas.length === 0) {
    lojaLabel.textContent = 'Não foi possível identificar a loja.';
    lojaLabel.className = 'error';
    return;
  }
  loja = lojas[0];
  lojaLabel.textContent = `Loja: ${loja.nome}`;

  const [{ data: pratos, error: pratosErr }, { data: ingredientes, error: ingErr }] = await Promise.all([
    supabase.from('pratos').select('id, nome').eq('ativo', true).order('nome'),
    supabase.from('ingredientes').select('id, nome, unidade_base').eq('ativo', true).eq('oculto_contagem', false).order('nome'),
  ]);

  if (pratosErr || ingErr) {
    msg.innerHTML = `<div class="error">Erro ao carregar dados: ${(pratosErr || ingErr).message}</div>`;
    return;
  }

  pratoSel.innerHTML = pratos.map((p) => `<option value="${p.id}">${p.nome}</option>`).join('');
  ingredienteSel.innerHTML = ingredientes.map((i) => `<option value="${i.id}">${i.nome}</option>`).join('');
  ingredientesPorId = Object.fromEntries(ingredientes.map((i) => [i.id, i]));

  if (pratos.length) await carregarGruposDoPrato(pratos[0].id);
  if (ingredientes.length) await carregarUnidadesDoIngrediente(ingredientes[0].id);

  await carregarUltimos();
}

// Não pergunta qual opção variável (ex. proteína) foi usada — assume a
// opção marcada como `padrao` na receita do prato (decisão do usuário, não
// inferida por nós: "assuma que a proteína ... é a que consta na tabela de
// ingredientes por prato"). Só mostra uma linha informativa, sem seletor.
async function carregarGruposDoPrato(pratoId) {
  gruposDiv.textContent = 'Carregando...';
  gruposPadrao = [];

  const { data: grupos, error } = await supabase
    .from('receita_grupos_variaveis')
    .select('id, nome')
    .eq('prato_id', pratoId)
    .order('nome');

  if (error) {
    gruposDiv.innerHTML = `<span class="error">Erro ao carregar grupos: ${error.message}</span>`;
    return;
  }

  if (!grupos.length) {
    gruposDiv.textContent = '';
    return;
  }

  const linhas = [];
  for (const grupo of grupos) {
    const { data: padrao, error: opErr } = await supabase
      .from('receita_opcoes_variaveis')
      .select('id, ingrediente:ingredientes(nome)')
      .eq('grupo_id', grupo.id)
      .eq('padrao', true)
      .limit(1)
      .maybeSingle();

    if (!opErr && padrao) {
      gruposPadrao.push({ grupoId: grupo.id, grupoNome: grupo.nome, opcaoId: padrao.id });
      linhas.push(`${grupo.nome}: ${padrao.ingrediente.nome} (assumido pela receita)`);
    } else {
      gruposPadrao.push({ grupoId: grupo.id, grupoNome: grupo.nome, opcaoId: null });
      linhas.push(`${grupo.nome}: nenhuma opção padrão definida ainda — não será registrada`);
    }
  }

  gruposDiv.innerHTML = linhas.join('<br>');
}

async function carregarUnidadesDoIngrediente(ingredienteId) {
  const ing = ingredientesPorId[ingredienteId];
  const { data: conversoes, error } = await supabase
    .from('unidades_conversao')
    .select('unidade')
    .eq('ingrediente_id', ingredienteId);

  const unidades = new Set([ing.unidade_base]);
  if (!error) for (const c of conversoes) unidades.add(c.unidade);

  unidadeIngredienteSel.innerHTML = [...unidades]
    .map((u) => `<option value="${u}">${u}</option>`)
    .join('');
}

tipoPerdaSel.addEventListener('change', () => {
  const isPrato = tipoPerdaSel.value === 'prato';
  blocoPrato.classList.toggle('hidden', !isPrato);
  blocoIngrediente.classList.toggle('hidden', isPrato);
});

pratoSel.addEventListener('change', () => carregarGruposDoPrato(pratoSel.value));
ingredienteSel.addEventListener('change', () => carregarUnidadesDoIngrediente(ingredienteSel.value));

form.addEventListener('submit', async (e) => {
  e.preventDefault();
  msg.innerHTML = '';
  submitBtn.disabled = true;
  submitBtn.textContent = 'Registrando...';

  const hoje = new Date().toISOString().slice(0, 10);
  const motivo = document.getElementById('motivo').value || null;
  const tipoPerda = tipoPerdaSel.value;

  try {
    if (tipoPerda === 'prato') {
      const quantidade = Number(document.getElementById('qtd-prato').value);
      const { data: registro, error } = await supabase
        .from('registros_desperdicio')
        .insert({
          data: hoje,
          loja_id: loja.id,
          tipo_perda: 'prato',
          prato_id: pratoSel.value,
          quantidade,
          unidade: 'un',
          motivo,
        })
        .select('id')
        .single();

      if (error) throw error;

      const selecoes = gruposPadrao
        .filter((g) => g.opcaoId)
        .map((g) => ({
          registro_desperdicio_id: registro.id,
          grupo_id: g.grupoId,
          opcao_id: g.opcaoId,
        }));

      if (selecoes.length) {
        const { error: selErr } = await supabase
          .from('registro_desperdicio_opcoes_selecionadas')
          .insert(selecoes);
        if (selErr) throw selErr;
      }
    } else {
      const quantidade = Number(document.getElementById('qtd-ingrediente').value);
      const { error } = await supabase.from('registros_desperdicio').insert({
        data: hoje,
        loja_id: loja.id,
        tipo_perda: 'ingrediente_bruto',
        ingrediente_id: ingredienteSel.value,
        quantidade,
        unidade: unidadeIngredienteSel.value,
        motivo,
      });
      if (error) throw error;
    }

    msg.innerHTML = '<div class="success">Perda registrada com sucesso.</div>';
    form.reset();
    tipoPerdaSel.dispatchEvent(new Event('change'));
    await carregarUltimos();
  } catch (err) {
    msg.innerHTML = `<div class="error">Erro ao registrar: ${err.message}</div>`;
  } finally {
    submitBtn.disabled = false;
    submitBtn.textContent = 'Registrar perda';
  }
});

carregar();
