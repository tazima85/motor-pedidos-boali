import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

// A anon key é pública por design — o RLS no banco (schema motor_pedidos)
// é quem decide o que cada usuário autenticado pode ler/escrever.
const SUPABASE_URL = 'https://fwwebebfagezdqsbybjy.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZ3d2ViZWJmYWdlemRxc2J5Ymp5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODU4MzU0ODQsImV4cCI6MjEwMTQxMTQ4NH0.VOFBhSC2jzkPU4mi0M3dW4lwa7jpHWY1u8S04Yp9wXA';

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  db: { schema: 'motor_pedidos' },
});
