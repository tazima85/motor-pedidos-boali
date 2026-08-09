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

let loja = null;

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
  calcularBtn.disabled = false;
  calcularBtn.textContent = 'Calcular pedido sugerido';
});

carregar();
