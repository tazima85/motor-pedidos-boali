import { supabase } from './supabase-client.js';
import { requireAuth } from './auth-guard.js';

await requireAuth();

// SheetJS via CDN oficial — sem dependência de npm/build.
const XLSX = await import('https://cdn.sheetjs.com/xlsx-latest/package/xlsx.mjs');

const lojaLabel = document.getElementById('loja-label');
const dataInicioInput = document.getElementById('data-inicio');
const dataFimInput = document.getElementById('data-fim');
const arquivoInput = document.getElementById('arquivo');
const analisarBtn = document.getElementById('analisar-btn');
const msg = document.getElementById('msg');
const previewWrap = document.getElementById('preview-wrap');
const previewSummary = document.getElementById('preview-summary');
const previewTbody = document.getElementById('preview-tbody');
const importarBtn = document.getElementById('importar-btn');
const importMsg = document.getElementById('import-msg');

let loja = null;
let pratosPorPlu = {};
let linhasReconhecidas = []; // linhas prontas pra importar

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

  const { data: pratos, error: pratosErr } = await supabase
    .from('pratos').select('id, nome, codigo_plu').not('codigo_plu', 'is', null);

  if (!pratosErr) {
    pratosPorPlu = Object.fromEntries(pratos.map((p) => [p.codigo_plu, p]));
  }
}

arquivoInput.addEventListener('change', () => {
  analisarBtn.disabled = !arquivoInput.files.length;
});

function acharColuna(header, alvo) {
  return header.findIndex((h) => String(h).trim().toLowerCase() === alvo.toLowerCase());
}

analisarBtn.addEventListener('click', async () => {
  msg.innerHTML = '';
  previewWrap.classList.add('hidden');
  importMsg.innerHTML = '';

  if (!dataInicioInput.value || !dataFimInput.value) {
    msg.innerHTML = '<div class="error">Informe o período (início e fim) antes de analisar.</div>';
    return;
  }

  const file = arquivoInput.files[0];
  const buf = await file.arrayBuffer();
  const wb = XLSX.read(buf, { type: 'array' });
  const ws = wb.Sheets[wb.SheetNames[0]];
  const rows = XLSX.utils.sheet_to_json(ws, { header: 1, raw: true, defval: '' });

  const headerRowIdx = rows.findIndex((r) => r.some((c) => String(c).trim().toUpperCase() === 'PLU'));
  if (headerRowIdx === -1) {
    msg.innerHTML = '<div class="error">Não encontrei uma coluna "PLU" na primeira planilha do arquivo.</div>';
    return;
  }
  const header = rows[headerRowIdx];

  const pluCol = acharColuna(header, 'PLU');
  const nomeCol = header.findIndex((h) => String(h).trim().toLowerCase() === 'nome'); // primeira ocorrência = nome do produto
  const qtdCol = acharColuna(header, 'Qtd'); // exato — não confundir com "Qtd %"
  const valorCol = acharColuna(header, 'Valor total');
  const descontoCol = acharColuna(header, 'Desconto');
  const impostosCol = acharColuna(header, 'Impostos');
  const liquidoCol = acharColuna(header, 'Líquido');

  if (pluCol === -1 || nomeCol === -1 || qtdCol === -1) {
    msg.innerHTML = '<div class="error">Não encontrei as colunas PLU/Nome/Qtd no cabeçalho.</div>';
    return;
  }

  // Junta por PLU, mantendo a ÚLTIMA ocorrência — relatórios reais já vistos
  // trazem o mesmo PLU repetido (ex. um bloco com financeiro zerado seguido
  // do bloco correto); a última linha da planilha pra um PLU é a que vale.
  const porPlu = new Map();
  for (let i = headerRowIdx + 1; i < rows.length; i++) {
    const r = rows[i];
    const plu = String(r[pluCol] ?? '').trim();
    if (!plu) continue;
    porPlu.set(plu, {
      plu,
      nome: String(r[nomeCol] ?? '').trim(),
      quantidade: Number(r[qtdCol]) || 0,
      valor_total: valorCol !== -1 ? Number(r[valorCol]) || null : null,
      desconto: descontoCol !== -1 ? Number(r[descontoCol]) || null : null,
      impostos: impostosCol !== -1 ? Number(r[impostosCol]) || null : null,
      liquido: liquidoCol !== -1 ? Number(r[liquidoCol]) || null : null,
    });
  }

  const linhas = [...porPlu.values()];
  linhasReconhecidas = linhas.filter((l) => pratosPorPlu[l.plu]);

  previewTbody.innerHTML = linhas
    .map((l) => {
      const prato = pratosPorPlu[l.plu];
      return `<tr>
        <td>${l.plu}</td>
        <td>${l.nome}</td>
        <td>${l.quantidade}</td>
        <td>${prato ? '✓ ' + prato.nome : '— não cadastrado —'}</td>
      </tr>`;
    })
    .join('');

  previewSummary.textContent =
    `${linhas.length} PLU(s) únicos encontrados no arquivo — ${linhasReconhecidas.length} reconhecido(s) ` +
    `(têm prato cadastrado com esse código PLU), ${linhas.length - linhasReconhecidas.length} serão ignorados.`;

  previewWrap.classList.remove('hidden');
});

importarBtn.addEventListener('click', async () => {
  if (!linhasReconhecidas.length) return;

  importarBtn.disabled = true;
  importarBtn.textContent = 'Importando...';
  importMsg.innerHTML = '';

  const registros = linhasReconhecidas.map((l) => ({
    data_inicio: dataInicioInput.value,
    data_fim: dataFimInput.value,
    loja_id: loja.id,
    prato_id: pratosPorPlu[l.plu].id,
    quantidade: l.quantidade,
    valor_total: l.valor_total,
    desconto: l.desconto,
    impostos: l.impostos,
    liquido: l.liquido,
  }));

  const { error } = await supabase
    .from('vendas')
    .upsert(registros, { onConflict: 'prato_id,loja_id,data_inicio,data_fim' });

  importarBtn.disabled = false;
  importarBtn.textContent = 'Importar linhas reconhecidas';

  if (error) {
    importMsg.innerHTML = `<div class="error">Erro ao importar: ${error.message}</div>`;
    return;
  }

  importMsg.innerHTML = `<div class="success">${registros.length} venda(s) importada(s)/atualizada(s) com sucesso.</div>`;
});

carregar();
