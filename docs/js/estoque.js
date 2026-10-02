import { supabase } from './supabase-client.js';
import { requireAuth } from './auth-guard.js';

await requireAuth();

const tbody = document.getElementById('tbody');
const lojaLabel = document.getElementById('loja-label');
const saveBtn = document.getElementById('save-btn');
const msg = document.getElementById('msg');
const pdfConfirm = document.getElementById('pdf-confirm');
const pdfSimBtn = document.getElementById('pdf-sim-btn');
const pdfNaoBtn = document.getElementById('pdf-nao-btn');
const ultimasContagensDiv = document.getElementById('ultimas-contagens');

let loja = null;
let ingredientes = [];        // { id, nome, unidade, posicao }
const quantidades = {};       // ingrediente_id -> string digitada
let sortKey = 'posicao';
let sortDir = 'asc';
let pendentePdf = null;       // { hoje, quantidadesSalvas } aguardando confirmação

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
    .eq('ativo', true)
    .eq('oculto_contagem', false);

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
  await carregarUltimasContagens();
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

function gerarPdf(dataContagem, quantidadesSalvas) {
  const { jsPDF } = window.jspdf;
  const doc = new jsPDF();
  let y = 15;

  doc.setFontSize(14);
  doc.text(`Contagem de Estoque — ${loja?.nome ?? ''}`, 14, y);
  y += 6;
  doc.setFontSize(10);
  doc.text(`Data: ${dataContagem.split('-').reverse().join('/')}`, 14, y);
  y += 10;

  doc.setFontSize(11);
  doc.text('Posição', 14, y);
  doc.text('Produto', 34, y);
  doc.text('Unid.', 150, y);
  doc.text('Contagem', 170, y);
  y += 2;
  doc.line(14, y, 196, y);
  y += 6;

  doc.setFontSize(9);
  for (const ing of ingredientes) {
    if (y > 285) {
      doc.addPage();
      y = 15;
    }
    doc.text(String(ing.posicao), 14, y);
    doc.text(ing.nome, 34, y, { maxWidth: 110 });
    doc.text(ing.unidade, 150, y);
    const contado = quantidadesSalvas[ing.id];
    if (contado !== undefined) {
      doc.text(String(contado), 170, y);
    } else {
      doc.line(170, y + 1, 196, y + 1);
    }
    y += 7;
  }

  // window.open() direto com blob URL, chamado de forma síncrona a partir de um clique
  // real do usuário (botão "Sim") — sem esse gesto fresco (ex.: encadeado depois de um
  // await), o Safari bloqueia ou faz besteira; com um clique genuíno deve funcionar.
  const blobUrl = doc.output('bloburl');
  const pdfWindow = window.open(blobUrl, '_blank');
  if (!pdfWindow) {
    doc.save(`contagem-estoque-${dataContagem}.pdf`);
  }
}

// Agrupa contagens_estoque por created_at exato: um "Salvar Contagem" insere
// várias linhas de uma vez, todas com o mesmo now() (mesma instrução SQL), o
// que torna created_at idêntico a chave natural de "uma contagem" — inclusive
// distinguindo duas contagens no mesmo dia (recontagem), que têm a mesma
// `data` mas created_at diferentes.
async function carregarUltimasContagens() {
  if (!loja) return;

  const { data, error } = await supabase
    .from('contagens_estoque')
    .select('data, created_at, ingrediente_id, quantidade')
    .eq('loja_id', loja.id)
    .order('created_at', { ascending: false })
    .limit(600);

  if (error) {
    ultimasContagensDiv.innerHTML = `<div class="error">Erro ao carregar: ${error.message}</div>`;
    return;
  }

  const sessoesPorChave = new Map();
  for (const row of data) {
    if (!sessoesPorChave.has(row.created_at)) {
      sessoesPorChave.set(row.created_at, { data: row.data, created_at: row.created_at, quantidades: {} });
    }
    sessoesPorChave.get(row.created_at).quantidades[row.ingrediente_id] = row.quantidade;
  }

  const ultimasTres = [...sessoesPorChave.values()].slice(0, 3);

  if (!ultimasTres.length) {
    ultimasContagensDiv.innerHTML = 'Nenhuma contagem registrada ainda.';
    return;
  }

  ultimasContagensDiv.innerHTML = '';
  ultimasTres.forEach((sessao) => {
    const dataFmt = sessao.data.split('-').reverse().join('/');
    const horaFmt = new Date(sessao.created_at).toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' });
    const nItens = Object.keys(sessao.quantidades).length;

    const linha = document.createElement('div');
    linha.className = 'ultima-contagem-linha';
    linha.innerHTML = `<span>${dataFmt} às ${horaFmt} — ${nItens} item(ns)</span> `;

    const btn = document.createElement('button');
    btn.textContent = 'Gerar PDF desta contagem';
    btn.addEventListener('click', () => gerarPdf(sessao.data, sessao.quantidades));
    linha.appendChild(btn);

    ultimasContagensDiv.appendChild(linha);
  });
}

saveBtn.addEventListener('click', async () => {
  const hoje = new Date().toISOString().slice(0, 10);
  const quantidadesSalvas = { ...quantidades }; // snapshot pro PDF, antes de limpar

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
  pdfConfirm.classList.add('hidden');

  const { error } = await supabase.from('contagens_estoque').insert(linhas);

  saveBtn.textContent = 'Salvar Contagem';

  if (error) {
    msg.innerHTML = `<div class="error">Erro ao salvar: ${error.message}</div>`;
    saveBtn.disabled = false;
    return;
  }

  msg.innerHTML = `<div class="success">${linhas.length} item(ns) registrado(s).</div>`;
  // pergunta em vez de gerar direto: no iOS Safari, abrir o PDF em nova aba só funciona
  // com um toque real do usuário — encadear depois do await do salvamento não conta.
  pendentePdf = { hoje, quantidadesSalvas };
  pdfConfirm.classList.remove('hidden');
  for (const key of Object.keys(quantidades)) delete quantidades[key];
  saveBtn.disabled = true;
  render();
  carregarUltimasContagens();
});

pdfSimBtn.addEventListener('click', () => {
  if (!pendentePdf) return;
  gerarPdf(pendentePdf.hoje, pendentePdf.quantidadesSalvas);
  pdfConfirm.classList.add('hidden');
  pendentePdf = null;
});

pdfNaoBtn.addEventListener('click', () => {
  pdfConfirm.classList.add('hidden');
  pendentePdf = null;
});

carregar();
