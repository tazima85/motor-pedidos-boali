import { supabase } from './supabase-client.js';
import { requireAuth } from './auth-guard.js';

await requireAuth();

const lojaLabel = document.getElementById('loja-label');
const dataPedidoInput = document.getElementById('data-pedido');
const calcularBtn = document.getElementById('calcular-btn');
const msg = document.getElementById('msg');
const resultadoWrap = document.getElementById('resultado-wrap');
const periodoLabel = document.getElementById('periodo-label');
const resultadoTbody = document.getElementById('resultado-tbody');
const pdfBtn = document.getElementById('pdf-btn');
const pdfMsg = document.getElementById('pdf-msg');
const pdfConfirm = document.getElementById('pdf-confirm');
const pdfSimBtn = document.getElementById('pdf-sim-btn');
const pdfNaoBtn = document.getElementById('pdf-nao-btn');

let loja = null;
let ultimoCalculo = null; // { dataPedido, resultados }
let pendentePdf = null;   // { dataPedido, resultados, validos } aguardando confirmação

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
}

function ehQuinta(dataStr) {
  const [y, m, d] = dataStr.split('-').map(Number);
  return new Date(y, m - 1, d).getDay() === 4;
}

calcularBtn.addEventListener('click', async () => {
  msg.innerHTML = '';
  resultadoWrap.classList.add('hidden');
  pdfConfirm.classList.add('hidden');
  pendentePdf = null;

  const dataPedido = dataPedidoInput.value;
  if (!dataPedido) {
    msg.innerHTML = '<div class="error">Escolha uma data.</div>';
    return;
  }
  if (!ehQuinta(dataPedido)) {
    msg.innerHTML = '<div class="error">A data do pedido precisa ser uma quinta-feira.</div>';
    return;
  }

  calcularBtn.disabled = true;
  calcularBtn.textContent = 'Calculando...';

  const { data: ingredientes, error: ingErr } = await supabase
    .from('ingredientes')
    .select('id, nome, unidade_compra_fornecedor, unidade_base')
    .eq('ativo', true)
    .not('unidade_compra_fornecedor', 'is', null);

  if (ingErr) {
    msg.innerHTML = `<div class="error">Erro ao carregar ingredientes: ${ingErr.message}</div>`;
    calcularBtn.disabled = false;
    calcularBtn.textContent = 'Calcular pedido sugerido';
    return;
  }

  const resultados = await Promise.all(
    ingredientes.map(async (ing) => {
      const { data, error } = await supabase.rpc('calcular_pedido_sugerido', {
        p_ingrediente_id: ing.id,
        p_loja_id: loja.id,
        p_data_pedido: dataPedido,
      });
      if (error) return { ing, erro: error.message };
      return { ing, linha: data[0] };
    })
  );

  const comPeriodo = resultados.find((r) => r.linha);
  if (comPeriodo) {
    const l = comPeriodo.linha;
    periodoLabel.textContent = `Período de cobertura: ${l.periodo_inicio} a ${l.periodo_fim} (${l.dias_cobertura} dias)`;
  }

  resultadoTbody.innerHTML = resultados
    .map(({ ing, linha, erro }) => {
      if (erro) {
        return `<tr><td>${ing.nome}</td><td colspan="3" class="error">${erro}</td></tr>`;
      }
      return `<tr>
        <td>${ing.nome}</td>
        <td>${Number(linha.consumo_esperado).toFixed(1)} ${ing.unidade_base}</td>
        <td>${Number(linha.estoque_atual_base).toFixed(1)} ${ing.unidade_base}</td>
        <td><strong>${linha.pedido_sugerido} ${linha.unidade_compra}</strong></td>
      </tr>`;
    })
    .join('');

  resultadoWrap.classList.remove('hidden');
  pdfMsg.innerHTML = '';
  calcularBtn.disabled = false;
  calcularBtn.textContent = 'Calcular pedido sugerido';

  ultimoCalculo = { dataPedido, resultados };
});

function gerarPdf(dataPedido, resultados, validos) {
  const { jsPDF } = window.jspdf;
  const doc = new jsPDF();
  let y = 15;

  doc.setFontSize(14);
  doc.text(`Pedido Sugerido — ${loja.nome}`, 14, y);
  y += 8;
  doc.setFontSize(10);
  doc.text(`Data do pedido: ${dataPedido}`, 14, y);
  y += 6;
  if (validos.length) {
    const l = validos[0].linha;
    doc.text(`Período de cobertura: ${l.periodo_inicio} a ${l.periodo_fim} (${l.dias_cobertura} dias)`, 14, y);
    y += 10;
  }

  doc.setFontSize(11);
  doc.text('Ingrediente', 14, y);
  doc.text('Consumo esp.', 90, y);
  doc.text('Estoque atual', 130, y);
  doc.text('Pedido', 172, y);
  y += 2;
  doc.line(14, y, 196, y);
  y += 6;

  doc.setFontSize(10);
  for (const { ing, linha, erro } of resultados) {
    if (y > 280) {
      doc.addPage();
      y = 15;
    }
    if (erro) {
      doc.text(ing.nome, 14, y);
      doc.text('erro no cálculo', 90, y);
      y += 6;
      continue;
    }
    doc.text(ing.nome, 14, y);
    doc.text(`${Number(linha.consumo_esperado).toFixed(1)} ${ing.unidade_base}`, 90, y);
    doc.text(`${Number(linha.estoque_atual_base).toFixed(1)} ${ing.unidade_base}`, 130, y);
    doc.text(`${linha.pedido_sugerido} ${linha.unidade_compra}`, 172, y);
    y += 6;
  }

  // Método nativo do jsPDF: abre a janela e escreve nela um <iframe src="data:...">, em
  // vez de navegar a aba inteira pra data URI — navegação de aba inteira pra data: URI é
  // bloqueada silenciosamente pelo Safari (ficava com aba em branco). Chamado a partir de
  // um clique real no botão "Sim" — encadear direto depois do await de salvar no histórico
  // não conta como gesto do usuário no iOS Safari.
  doc.output('dataurlnewwindow', { filename: `pedido-sugerido-${dataPedido}.pdf` });
}

pdfBtn.addEventListener('click', async () => {
  if (!ultimoCalculo) return;

  pdfBtn.disabled = true;
  pdfBtn.textContent = 'Salvando...';
  pdfMsg.innerHTML = '';
  pdfConfirm.classList.add('hidden');

  const { dataPedido, resultados } = ultimoCalculo;
  const validos = resultados.filter((r) => r.linha);

  const registros = validos.map(({ ing, linha }) => ({
    data_pedido: dataPedido,
    loja_id: loja.id,
    ingrediente_id: ing.id,
    periodo_inicio: linha.periodo_inicio,
    periodo_fim: linha.periodo_fim,
    consumo_teorico_base: linha.consumo_teorico_base,
    desperdicio_periodo: linha.desperdicio_periodo,
    fator_sazonalidade_passada: linha.fator_sazonalidade_passada,
    fator_sazonalidade_futura: linha.fator_sazonalidade_futura,
    consumo_esperado: linha.consumo_esperado,
    estoque_atual_base: linha.estoque_atual_base,
    necessidade_bruta: linha.necessidade_bruta,
    unidade_compra: linha.unidade_compra,
    lote_minimo: linha.lote_minimo,
    pedido_sugerido: linha.pedido_sugerido,
  }));

  if (registros.length) {
    const { error } = await supabase.from('pedidos_sugeridos').insert(registros);
    if (error) {
      pdfMsg.innerHTML = `<div class="error">Erro ao salvar histórico: ${error.message} (pode gerar o PDF mesmo assim)</div>`;
    } else {
      pdfMsg.innerHTML = '<div class="success">Salvo no histórico.</div>';
    }
  }

  pdfBtn.disabled = false;
  pdfBtn.textContent = 'Salvar no histórico';
  pendentePdf = { dataPedido, resultados, validos };
  pdfConfirm.classList.remove('hidden');
});

pdfSimBtn.addEventListener('click', () => {
  if (!pendentePdf) return;
  gerarPdf(pendentePdf.dataPedido, pendentePdf.resultados, pendentePdf.validos);
  pdfConfirm.classList.add('hidden');
  pendentePdf = null;
});

pdfNaoBtn.addEventListener('click', () => {
  pdfConfirm.classList.add('hidden');
  pendentePdf = null;
});

carregar();
