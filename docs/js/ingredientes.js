import { supabase } from './supabase-client.js';
import { requireAuth } from './auth-guard.js';

await requireAuth();

const tbody = document.getElementById('tbody');
const msg = document.getElementById('msg');
const filtroInput = document.getElementById('filtro');

let ingredientes = []; // { id, codigo, nome, posicao, unidade }
let sortKey = 'nome';
let sortDir = 'asc';
let filtro = '';

async function carregar() {
  const { data, error } = await supabase
    .from('ingredientes')
    .select('id, codigo_fornecedor, nome, unidade_contagem_padrao, setor:setores(ordem)')
    .eq('ativo', true);

  if (error) {
    msg.innerHTML = `<div class="error">Erro ao carregar: ${error.message}</div>`;
    return;
  }

  ingredientes = data.map((i) => ({
    id: i.id,
    codigo: i.codigo_fornecedor ?? '',
    nome: i.nome,
    posicao: i.setor?.ordem ?? 1,
    unidade: i.unidade_contagem_padrao ?? '',
  }));

  render();
}

function linhasFiltradas() {
  if (!filtro) return ingredientes;
  const f = filtro.toLowerCase();
  return ingredientes.filter(
    (i) => i.nome.toLowerCase().includes(f) || i.codigo.toLowerCase().includes(f)
  );
}

function sortLinhas(linhas) {
  const dir = sortDir === 'asc' ? 1 : -1;
  linhas.sort((a, b) => {
    const va = a[sortKey];
    const vb = b[sortKey];
    if (typeof va === 'number') return (va - vb) * dir;
    return String(va).localeCompare(String(vb), 'pt-BR') * dir;
  });
  return linhas;
}

async function salvarNome(ing, valor) {
  const { error } = await supabase.from('ingredientes').update({ nome: valor }).eq('id', ing.id);
  return error;
}

async function salvarUnidade(ing, valor) {
  const { error } = await supabase
    .from('ingredientes')
    .update({ unidade_contagem_padrao: valor || null })
    .eq('id', ing.id);
  return error;
}

// "Posição" é modelada como setores.ordem — encontra um setor com essa
// ordem, ou cria um novo ("Setor N"), e reatribui o ingrediente a ele.
async function salvarPosicao(ing, valorStr) {
  const ordem = Number(valorStr);
  if (!Number.isFinite(ordem)) return { message: 'Posição precisa ser um número.' };

  const { data: existente, error: buscaErr } = await supabase
    .from('setores')
    .select('id')
    .eq('ordem', ordem)
    .limit(1)
    .maybeSingle();
  if (buscaErr) return buscaErr;

  let setorId = existente?.id;
  if (!setorId) {
    const { data: novo, error: criaErr } = await supabase
      .from('setores')
      .insert({ nome: `Setor ${ordem}`, ordem })
      .select('id')
      .single();
    if (criaErr) return criaErr;
    setorId = novo.id;
  }

  const { error } = await supabase.from('ingredientes').update({ setor_id: setorId }).eq('id', ing.id);
  return error;
}

function celulaEditavel(valor, onSave) {
  const input = document.createElement('input');
  input.value = valor;
  input.addEventListener('change', async () => {
    input.disabled = true;
    const error = await onSave(input.value);
    input.disabled = false;
    if (error) {
      msg.innerHTML = `<div class="error">Erro ao salvar: ${error.message}</div>`;
    } else {
      msg.innerHTML = '';
    }
  });
  return input;
}

function render() {
  const linhas = sortLinhas(linhasFiltradas());

  document.querySelectorAll('th[data-key]').forEach((th) => {
    const arrow = th.querySelector('.arrow');
    arrow.textContent = th.dataset.key === sortKey ? (sortDir === 'asc' ? '▲' : '▼') : '';
  });

  tbody.innerHTML = '';
  for (const ing of linhas) {
    const tr = document.createElement('tr');

    const tdCodigo = document.createElement('td');
    tdCodigo.textContent = ing.codigo;

    const tdNome = document.createElement('td');
    tdNome.appendChild(celulaEditavel(ing.nome, (v) => salvarNome(ing, v)));

    const tdPosicao = document.createElement('td');
    const inputPos = celulaEditavel(ing.posicao, (v) => salvarPosicao(ing, v));
    inputPos.type = 'number';
    inputPos.style.width = '70px';
    tdPosicao.appendChild(inputPos);

    const tdUnidade = document.createElement('td');
    const inputUn = celulaEditavel(ing.unidade, (v) => salvarUnidade(ing, v));
    inputUn.style.width = '80px';
    tdUnidade.appendChild(inputUn);

    tr.append(tdCodigo, tdNome, tdPosicao, tdUnidade);
    tbody.appendChild(tr);
  }
}

document.querySelectorAll('th[data-key]').forEach((th) => {
  th.addEventListener('click', () => {
    const key = th.dataset.key;
    if (sortKey === key) sortDir = sortDir === 'asc' ? 'desc' : 'asc';
    else { sortKey = key; sortDir = 'asc'; }
    render();
  });
});

filtroInput.addEventListener('input', () => {
  filtro = filtroInput.value;
  render();
});

carregar();
