import { supabase } from './supabase-client.js';
import { requireAuth } from './auth-guard.js';

await requireAuth();

const tbody = document.getElementById('tbody');
const lojaLabel = document.getElementById('loja-label');
const saveBtn = document.getElementById('save-btn');
const msg = document.getElementById('msg');

let loja = null;
let ingredientes = [];        // { id, nome, unidade, posicao }
const quantidades = {};       // ingrediente_id -> string digitada
let sortKey = 'posicao';
let sortDir = 'asc';

async function carregar() {
  const { data: lojas, error: lojaErr } = await supabase
    .from('lojas')
    .select('id, nome')
    .eq('ativa', true)
    .limit(1);

  if (lojaErr || !lojas || lojas.length === 0) {
    lojaLabel.textContent = 'Não foi possível identificar a loja.';
    lojaLabel.className = 'error';
    return;
  }
  loja = lojas[0];
  lojaLabel.textContent = `Loja: ${loja.nome}`;

  const { data, error } = await supabase
    .from('ingredientes')
    .select('id, nome, unidade_contagem_padrao, unidade_base, setor:setores(ordem)')
    .eq('ativo', true);

  if (error) {
    msg.innerHTML = `<div class="error">Erro ao carregar ingredientes: ${error.message}</div>`;
    return;
  }

  ingredientes = data.map((i) => ({
    id: i.id,
    nome: i.nome,
    // nem todo ingrediente ainda tem unidade_contagem_padrao cadastrada
    // (só os que já passaram pelo de-para com o fornecedor) — cai pra
    // unidade_base nesse caso.
    unidade: i.unidade_contagem_padrao || i.unidade_base,
    posicao: i.setor?.ordem ?? 1,
  }));

  render();
}

function sortIngredientes() {
  const dir = sortDir === 'asc' ? 1 : -1;
  ingredientes.sort((a, b) => {
    const va = a[sortKey];
    const vb = b[sortKey];
    if (typeof va === 'number') return (va - vb) * dir;
    return String(va).localeCompare(String(vb), 'pt-BR') * dir;
  });
}

function render() {
  sortIngredientes();

  document.querySelectorAll('th[data-key]').forEach((th) => {
    const arrow = th.querySelector('.arrow');
    if (th.dataset.key === sortKey) {
      arrow.textContent = sortDir === 'asc' ? '▲' : '▼';
    } else {
      arrow.textContent = '';
    }
  });

  tbody.innerHTML = '';
  for (const ing of ingredientes) {
    const tr = document.createElement('tr');

    const tdPos = document.createElement('td');
    tdPos.textContent = ing.posicao;

    const tdNome = document.createElement('td');
    tdNome.textContent = ing.nome;

    const tdUnidade = document.createElement('td');
    tdUnidade.textContent = ing.unidade;

    const tdQtd = document.createElement('td');
    const input = document.createElement('input');
    input.type = 'number';
    input.inputMode = 'decimal';
    input.min = '0';
    input.step = 'any';
    input.value = quantidades[ing.id] ?? '';
    input.addEventListener('input', () => {
      if (input.value === '') {
        delete quantidades[ing.id];
      } else {
        quantidades[ing.id] = input.value;
      }
      saveBtn.disabled = Object.keys(quantidades).length === 0;
    });
    tdQtd.appendChild(input);

    tr.append(tdPos, tdNome, tdUnidade, tdQtd);
    tbody.appendChild(tr);
  }
}

document.querySelectorAll('th[data-key]').forEach((th) => {
  th.addEventListener('click', () => {
    const key = th.dataset.key;
    if (sortKey === key) {
      sortDir = sortDir === 'asc' ? 'desc' : 'asc';
    } else {
      sortKey = key;
      sortDir = 'asc';
    }
    render();
  });
});

saveBtn.addEventListener('click', async () => {
  const hoje = new Date().toISOString().slice(0, 10);
  const linhas = Object.entries(quantidades)
    .filter(([, v]) => v !== '' && !Number.isNaN(Number(v)))
    .map(([ingrediente_id, v]) => {
      const ing = ingredientes.find((i) => i.id === ingrediente_id);
      return {
        data: hoje,
        loja_id: loja.id,
        ingrediente_id,
        quantidade: Number(v),
        unidade: ing.unidade,
      };
    });

  if (linhas.length === 0) return;

  saveBtn.disabled = true;
  saveBtn.textContent = 'Salvando...';
  msg.innerHTML = '';

  const { error } = await supabase.from('contagens_estoque').insert(linhas);

  saveBtn.textContent = 'Salvar contagem';

  if (error) {
    msg.innerHTML = `<div class="error">Erro ao salvar: ${error.message}</div>`;
    saveBtn.disabled = false;
    return;
  }

  msg.innerHTML = `<div class="success">${linhas.length} item(ns) registrado(s) com sucesso.</div>`;
  for (const key of Object.keys(quantidades)) delete quantidades[key];
  saveBtn.disabled = true;
  render();
});

carregar();
