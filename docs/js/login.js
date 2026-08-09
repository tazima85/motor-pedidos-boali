import { supabase } from './supabase-client.js';

const form = document.getElementById('login-form');
const msg = document.getElementById('msg');
const submitBtn = document.getElementById('submit-btn');

// já logado? pula direto pro menu
const { data: { session } } = await supabase.auth.getSession();
if (session) {
  window.location.href = 'index.html';
}

form.addEventListener('submit', async (e) => {
  e.preventDefault();
  msg.innerHTML = '';
  submitBtn.disabled = true;
  submitBtn.textContent = 'Entrando...';

  const email = document.getElementById('email').value.trim();
  const password = document.getElementById('password').value;

  const { error } = await supabase.auth.signInWithPassword({ email, password });

  if (error) {
    msg.innerHTML = `<div class="error">${error.message === 'Invalid login credentials' ? 'E-mail ou senha incorretos.' : error.message}</div>`;
    submitBtn.disabled = false;
    submitBtn.textContent = 'Entrar';
    return;
  }

  window.location.href = 'index.html';
});
