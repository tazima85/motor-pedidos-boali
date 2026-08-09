import { requireAuth, logout } from './auth-guard.js';

await requireAuth();

document.getElementById('logout-btn').addEventListener('click', logout);
