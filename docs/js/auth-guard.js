import { supabase } from './supabase-client.js';

// Chame no topo de qualquer página que exija login. Redireciona pro login
// se não houver sessão; devolve { session, user } se houver.
export async function requireAuth() {
  const { data: { session } } = await supabase.auth.getSession();
  if (!session) {
    window.location.href = 'login.html';
    return null;
  }
  return session;
}

export async function logout() {
  await supabase.auth.signOut();
  window.location.href = 'login.html';
}
