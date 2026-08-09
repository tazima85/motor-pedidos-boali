import { supabase } from './supabase-client.js';
import { requireAuth } from './auth-guard.js';

await requireAuth();

const tbody = document.getElementById('tbody');
const msg = document.getElementById('msg');
const filtroInput = document.getElementById('filtro');
const salvarBtn = document.getElementById('salvar-btn');

let ingredientes = []; // { id, codigo, nome, posicao, unidade, oculto }
const pendencias = {}; // id -> { nome?, posicao?, unidade?, oculto? }
let sortKey = 'nome';
let sortDir = 'asc';
let filtro = '';

async function carregar() {
  const { data, error } = await supabase
    .from('ingredientes')
    .select('id, codigo_fornecedor, nome, unidade_contagem_padrao, oculto_contagem, setor:setores(ordem)')
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
    oculto: i.oculto_contagem,
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
    if (typeof va === 'boolean') return (va === vb ? 0 : va ? 1 : -1) * dir;
    return String(va).localeCompare(String(vb), 'pt-BR') * dir;
  });
  return linhas;
}

function marcarPendencia(ing, campo, valor) {
  pendencias[ing.id] = pendencias[ing.id] || {};
  pendencias[ing.id][campo] = valor;
  salvarBtn.disabled = false;
  salvarBtn.textContent = `Salvar alterações (${Object.keys(pendencias).length})`;
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
    const pend = pendencias[ing.id] || {};

    const tdCodigo = document.createElement('td');
    tdCodigo.textContent = ing.codigo;

    const tdNome = document.createElement('td');
    const inputNome = document.createElement('input');
    inputNome.value = pend.nome ?? ing.nome;
    inputNome.addEventListener('input', () => marcarPendencia(ing, 'nome', inputNome.value));
    tdNome.appendChild(inputNome);

    const tdPosicao = document.createElement('td');
    const inputPos = document.createElement('input');
    inputPos.type = 'number';
    inputPos.value = pend.posicao ?? ing.posicao;
    inputPos.addEventListener('input', () => marcarPendencia(ing, 'posicao', inputPos.value));
    tdPosicao.appendChild(inputPos);

    const tdUnidade = document.createElement('td');
    const inputUn = document.createElement('input');
    inputUn.value = pend.unidade ?? ing.unidade;
    inputUn.addEventListener('input', () => marcarPendencia(ing, 'unidade', inputUn.value));
    tdUnidade.appendChild(inputUn);

    const tdOculto = document.createElement('td');
    const inputOculto = document.createElement('input');
    inputOculto.type = 'checkbox';
    inputOculto.checked = pend.oculto ?? ing.oculto;
    inputOculto.addEventListener('change', () => marcarPendencia(ing, 'oculto', inputOculto.checked));
    tdOculto.appendChild(inputOculto);

    tr.append(tdCodigo, tdNome, tdPosicao, tdUnidade, tdOculto);
    tbody.appendChild(tr);
  }
}

// "Posição" é modelada como setores.ordem — encontra um setor com essa
// ordem, ou cria um novo ("Setor N"), e devolve o id pra reatribuir o
// ingrediente a ele.
async function resolverSetorId(ordemStr) {
  const ordem = Number(ordemStr);
  if (!Number.isFinite(ordem)) throw new Error('Posição precisa ser um número.');

  const { data: existente, error: buscaErr } = await supabase
    .from('setores')
    .select('id')
    .eq('ordem', ordem)
    .limit(1)
    .maybeSingle();
  if (buscaErr) throw buscaErr;
  if (existente) return existente.id;

  const { data: novo, error: criaErr } = await supabase
    .from('setores')
    .insert({ nome: `Setor ${ordem}`, ordem })
    .select('id')
    .single();
  if (criaErr) throw criaErr;
  return novo.id;
}

salvarBtn.addEventListener('click', async () => {
  const ids = Object.keys(pendencias);
  if (!ids.length) return;

  salvarBtn.disabled = true;
  salvarBtn.textContent = 'Salvando...';
  msg.innerHTML = '';

  let erros = 0;
  for (const id of ids) {
    const pend = pendencias[id];
    const update = {};
    if (pend.nome !== undefined) update.nome = pend.nome;
    if (pend.unidade !== undefined) update.unidade_contagem_padrao = pend.unidade || null;
    if (pend.oculto !== undefined) update.oculto_contagem = pend.oculto;

    try {
      if (pend.posicao !== undefined) {
        update.setor_id = await resolverSetorId(pend.posicao);
      }
      const { error } = await supabase.from('ingredientes').update(update).eq('id', id);
      if (error) throw error;
      delete pendencias[id];
    } catch (err) {
      erros++;
      console.error(`Erro ao salvar ingrediente ${id}:`, err.message);
    }
  }

  await carregar();

  if (erros) {
    msg.innerHTML = `<div class="error">${erros} item(ns) não salvos — veja o console.</div>`;
  } else {
    msg.innerHTML = '<div class="success">Alterações salvas com sucesso.</div>';
  }
  salvarBtn.disabled = Object.keys(pendencias).length === 0;
  salvarBtn.textContent = 'Salvar alterações';
});

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
