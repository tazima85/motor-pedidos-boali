# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Sistema de Previsão de Insumos for Boali: generates purchase orders for a food-service supplier by
projecting real expected ingredient consumption from sales, waste, current stock, and seasonality.

The system is modeled generically from the start (built to hold hundreds of products), but real data
and end-to-end testing are scoped to a single product — **Frango Crocante** — until the recipe →
waste → stock → order-generation flow is validated for it. Expanding to the rest of the menu is meant
to be pure data population; the calculation logic should not need to change.

## Current state

Módulos 1-6 all have real schema + working logic, verified against the real hosted project, pushed to
GitHub and live on GitHub Pages. No package.json/build tooling (frontend is plain HTML/CSS/JS, no
bundler by design — see Frontend section). Public repo: `tazima85/motor-pedidos-boali` — public only
because GitHub Pages on the free plan requires it (see Deployment section for the full story, including
an incident worth reading before running `git add -A` again in this repo).

- `supabase/migrations/20260807120000_modulos_1_a_4.sql` — Módulos 1-4 schema.
- `supabase/migrations/20260807120100_customizacao_desperdicio.sql` — adds
  `registro_desperdicio_opcoes_selecionadas`, added after real recipe data (see below) showed that
  most pratos are built from a fixed base + variable option groups, and a waste record needs to know
  which option was picked per group to decompose correctly.
- `supabase/migrations/20260808120000_grants_motor_pedidos.sql` — `GRANT`s on schema `motor_pedidos`
  for `authenticated`/`service_role` (see schema-isolation note below for why this was needed at all).
  Uses `ALTER DEFAULT PRIVILEGES`, confirmed (via `information_schema.table_privileges`) to auto-apply
  to objects created by later migrations without repeating the grants each time.
- `supabase/migrations/20260809120000_modulo_6_motor_previsao.sql` — the forecasting engine itself; see
  its own section below.
- `supabase/migrations/20260809130000_desempate_contagem_recente.sql` — redefines
  `calcular_pedido_sugerido()`'s stock lookup to break same-day ties with `created_at desc`, not just
  `data desc`. Found while building the estoque frontend: recounting an item the same day is a normal
  workflow, and same-`data` ordering was previously undefined.
- `supabase/migrations/20260809140000_modulo_5_vendas.sql` — the `vendas` table and
  `calcular_consumo_teorico_medio_diario()`; see the Módulo 5 section below.
- `supabase/migrations/20260810120000_vendas_upsert.sql` — unique constraint on `vendas(prato_id,
  loja_id, data_inicio, data_fim)`, needed so the vendas-upload UI can `upsert` (re-importing the same
  period updates instead of duplicating).
- `supabase/migrations/20260811120000_ocultar_contagem.sql` — adds `ingredientes.oculto_contagem`, a
  column deliberately separate from `ativo` (see Frontend section) that only affects `estoque.html`.
- `supabase/migrations/20260812120000_pedidos_sugeridos.sql` — `pedidos_sugeridos` table, a historical
  log of `calcular_pedido_sugerido()` results. Written only when the user clicks "Gerar PDF" on
  `pedido.html`, not on every "Calcular" — an exploratory calculation the user never turns into a PDF
  isn't a real decision worth logging. Includes an unfilled `quantidade_pedida_real` column, an explicit
  hook for the accuracy-validation backlog item the original spec asked to leave room for, not to build.
- `supabase/seed.sql` — real end-to-end data for the Frango Crocante validation: ingrediente "Frango
  Crocante" (Comfrio code `0101013100300`, `FRANGO EMPANADISSIMO CX4KG`, 1 caixa = 10 pacotes × 400g),
  the prato "Wrap Frango Picante" (the only dish where Frango Crocante is a Proteína-group option), a
  waste record (2× the dish, decomposed via the recipe), an illustrative stock count by pacote, a real
  week of vendas (see Módulo 5 below), **and the full ~136-item product catalog** from `uploads/CONTAGEM
  ESTOQUE 25.2026.pdf` (see "Ingrediente catalog import" note below). Idempotent (safe to re-run).
  Sourced from `uploads/Quadro_Receitas_Completo_2026 (2).xlsx` (full recipe matrix), `uploads/Pedido
  1652340949691-01.xlsx` (a real Comfrio order), the real numbers from `uploads/Vendas_PLU.xlsx` (not
  tracked — see below), and `uploads/CONTAGEM ESTOQUE 25.2026.pdf`. Note: unlike migrations,
  `supabase/seed.sql` only auto-applies on `supabase db reset` (local dev) — against a remote/linked
  project it must be run explicitly (`supabase db query --linked --file supabase/seed.sql`).
- `uploads/` holds source spreadsheets/PDFs used as reference — treat the tracked ones (Quadro de
  Receitas, Pedido Comfrio, Contagem Estoque PDF) as read-only, not something to regenerate.
  `uploads/Vendas_PLU.xlsx` is deliberately **not tracked** (real revenue/discount/tax figures) — see
  Deployment section. Any other file that
  shows up in `uploads/` from outside a Claude Code session should be treated as unreviewed until
  checked: don't let a blanket `git add -A` sweep it into a commit without looking first.
- `docs/` — the static UI, served by GitHub Pages; see its own section below.

**Note**: manual browser testing of the frontend (see below) added a few extra rows beyond the seed —
one more `contagens_estoque` count (8 pacotes, today) and two more `registros_desperdicio` (3× and 1×
Frango Crocante). Left in place as evidence the write paths work end-to-end; harmless to delete if a
clean slate is wanted, just not done automatically.

## Módulo 6 — Motor de Previsão (`20260809120000_modulo_6_motor_previsao.sql`, extended by
`20260809140000_modulo_5_vendas.sql`)

Fully automatic end-to-end now that Módulo 5 exists: `calcular_pedido_sugerido()` no longer needs
`consumo_teorico_base` handed to it — left `null` (the default), it computes real theoretical
consumption itself from `vendas` × `receita_componentes`. Verified live for Frango Crocante with real
data at every stage:

- `periodo_cobertura(data_pedido)` — turns the replenishment-cycle prose into dates. Order (Thursday)
  doesn't need to cover consumption before its own arrival (Monday, +4 days) — that's the *previous*
  order's job. From arrival, normal weekly cadence would need 7 days of cover; +1 day of safety margin
  extends it to the following Tuesday. Net: `periodo_inicio = data_pedido + 4`,
  `periodo_fim = data_pedido + 12` — 9 days inclusive, which is what reconciles the spec's own
  "período de cobertura de ~8-9 dias" figure with its "quinta a terça" label (a literal Thursday→Tuesday
  count is only 5-6 days; this arrival-anchored reading is the only one that matches both). Verified:
  for `data_pedido = 2026-08-13`, returns `periodo_inicio = 2026-08-17` (Mon), `periodo_fim =
  2026-08-25` (Tue), `dias_cobertura = 9`.
- `calcular_desperdicio_medio_diario(ingrediente_id, loja_id, data_referencia, dias_historico=28)` —
  averages real waste (direct `ingrediente_bruto` entries + decomposed `prato` entries, both fixed
  components and the selected variable option) over a trailing window, always dividing by the full
  window length (not just days-with-waste) so quiet days genuinely pull the average down. Verified
  against the seeded 110g Frango Crocante waste event: `110g / 28 days × 9 days coverage = 35.36g`.
- `fator_sazonalidade_vigente(tipo, nivel, referencia_id, data)` — looks up the applicable factor,
  defaulting to `1.0` (neutral) when nothing is registered. `fatores_sazonalidade` supports
  `nivel IN ('prato','ingrediente','loja')` — the "Pontos em aberto #1" granularity question is left
  open at the data-model level rather than forced to one answer.
- `calcular_pedido_sugerido(ingrediente_id, loja_id, data_pedido, consumo_teorico_base=null)` — the
  master function; implements the spec's formula verbatim (`consumo_esperado = (consumo_teorico_base +
  desperdicio_periodo) × fator_passada × fator_futura`, `necessidade_bruta = max(consumo_esperado −
  estoque_atual, 0)`, `pedido_sugerido = ceil(necessidade_bruta_em_unidade_compra ÷ lote_minimo) ×
  lote_minimo`). `consumo_teorico_base` is `null` by default → auto-computed via
  `calcular_consumo_teorico_medio_diario() × dias_cobertura`; pass an explicit number to override (still
  useful for testing/manual adjustment). Rejects any `data_pedido` that isn't a Thursday
  (`extract(dow) = 4`) — verified this raises correctly for `2026-08-14` (a Friday). Verified rounding
  with an explicit `consumo_teorico_base = 5000`: necessidade_bruta 2635g → 0.66 caixa → rounds up to
  **1 caixa fechada**. Verified fully automatic (no override) for Frango Crocante at `data_pedido =
  2026-08-13`: auto-computed `consumo_teorico_base = 1507.5g` (167.5g/day × 9 days), `desperdicio_periodo
  = 216.96g`, `consumo_esperado = 1724.46g`, vs. `estoque_atual = 3200g` (8 pacotes from the live
  frontend test) → `necessidade_bruta = 0` → `pedido_sugerido = 0` (stock genuinely covers demand, so a
  zero order here is correct, not a bug).
- **Known simplification, not yet addressed**: `estoque_atual` uses the latest count at/before
  `data_pedido` without separately modeling the ~4 days of consumption between the order date (Thursday)
  and arrival (Monday) — the spec's own formula doesn't split that out either. Revisit if this proves
  material in practice.

## Módulo 5 — Ingestão de Vendas (`20260809140000_modulo_5_vendas.sql`)

Real source: a weekly PLU-level sales report from the POS (`uploads/Vendas_PLU.xlsx`, one row per
prato/loja/week — **not** per individual sale, and not tracked in the repo since it carries real
revenue/discount/tax figures — see Deployment). That granularity shaped the schema and two real
findings from the file changed the design from what the original spec draft assumed:

- **The file itself had two overlapping blocks** — rows with a PLU carrying a spurious leading `1`
  digit and all financial columns zeroed, and rows with the correct PLU and real `Valor total`/
  `Desconto`/`Líquido` figures for the same items and quantities. Confirmed with the user: the block
  *without* the extra leading digit is the real data; the other block is treated as noise, not a second
  data source.
- **Protein/modifier choices are their own PLU line items**, not an attribute captured on the base
  dish's sale. Confirmed with the user: for a genuinely build-your-own base (e.g. "Crie sua Salada")
  the protein is *always* a separate PLU sale in the same order; for *any* prato, ordering extra of a
  variable-group item beyond what's already included also rings up as its own separate PLU. This means
  Módulo 5 doesn't need a `registro_desperdicio_opcoes_selecionadas`-style link table at all — a
  modifier sale is just another normal prato sale of a very simple `prato` (one `componente_fixo`), and
  decomposing it via the existing recipe machinery is all that's needed. Implemented as: PLU `240004`
  ("Frango crocante 70g" in the POS) → prato "Frango Crocante 70g (Proteína Extra)", `tipo = 'fixo'`, a
  single `componente_fixo` of 70g Frango Crocante. Seeded with its real quantity (67 units, week of
  2026-08-02 to 2026-08-08).
- `pratos.codigo_plu` — the cross-module business key for this module, same role as
  `ingredientes.codigo_fornecedor` plays for Módulo 1. Set on "Wrap Frango Picante" (`220002`) and the
  new Proteína Extra prato (`240004`).
- `vendas` — one row per (período, loja, prato), not per individual sale, matching the real report's
  actual grain. `data_inicio`/`data_fim` instead of a single `data`. Also stores `valor_total`/
  `desconto`/`impostos`/`liquido` (free from the same report, not used by any calculation yet, kept for
  future reporting).
- `calcular_consumo_teorico_medio_diario(ingrediente_id, loja_id, data_referencia, dias_historico=28)` —
  mirrors `calcular_desperdicio_medio_diario` exactly: sums real `vendas.quantidade × receita_
  componentes.quantidade` (converted to unidade_base) over a trailing window, divided by the full window
  length. Only `componentes_fixos` are summed — variable-group contributions (e.g. Wrap Frango
  Picante's own Proteína group) are intentionally excluded here, because a real choice for a variable
  group either already arrives as its own separate prato sale (see above) or isn't known at all; there's
  no historical frequency data to justify assuming any one option as a fallback, so the honest choice is
  to contribute zero rather than guess. Verified against the real seeded week: Frango Crocante's only
  `componente_fixo` contribution is the 67× "Proteína Extra" sale → `67 × 70g / 28 dias = 167.5g/dia`,
  matching the function's output exactly.

**Update — no longer an open gap for desperdício, still open for vendas**: `receita_opcoes_variaveis
.padrao` was left unset everywhere initially because there was no real frequency data to justify
picking one protein over another, and guessing would quietly bias every forecast. The user gave an
explicit, deliberate instruction to resolve this for desperdício: "assuma que a proteína utilizada no
prato selecionado é a que consta na tabela de ingredientes por prato" — so `padrao = true` is now set
per prato in `supabase/seed.sql` (idempotently, via an `update` that sets `padrao` based on an
`ingrediente_id` match rather than a blind `insert`). **Corrected once already**: the first pass wrongly
assumed Wrap Frango Picante's padrão protein was Frango Crocante (convenient because that's what earlier
testing happened to use, but not actually true) — the user corrected this directly: Wrap Frango
Picante's real padrão protein is **Frango desfiado**. Current state, all confirmed live against real
data: Wrap Frango Picante → Frango desfiado; **Wrap Crocante ao Pesto** and **Bowl da Fazenda** (two
pratos created specifically for this, not present in the seed before) → Frango Crocante, both at 55g,
matching the portion size used everywhere else Frango Crocante appears as a protein option. Those two
new pratos only have a Proteína grupo — no `componentes_fixos` (base ingredients) were fabricated for
them since that wasn't asked for, just the protein association needed to test Frango Crocante-related
desperdício on dishes other than Wrap Frango Picante.

**This whole `padrao` mechanism is scoped to the desperdício flow only** (see Frontend section —
`desperdicio.js` no longer shows a selector, it silently uses whichever option has `padrao = true`).
`calcular_consumo_teorico_medio_diario` (Módulo 5) deliberately still does **not** read `padrao` and
still contributes 0 for variable groups — that's a separate question (vendas vs. waste) that hasn't been
asked or answered yet, don't assume the same "use padrao" rule applies there without it being asked for
explicitly.

**Duplicate ingredient rows, found while fixing this — not yet cleaned up**: `ingredientes` has both
`'Frango desfiado'` (from the original Wrap Frango Picante recipe seed) and `'FRANGO DESFIADO'` (from
the PDF catalog import, all-caps like every other catalog row) as two separate, unlinked rows for what
is almost certainly the same real ingredient — case-sensitive matching during the catalog import missed
it, same root cause as the earlier "Frango crocante"/"Frango Crocante" bug, just not caught this time
before shipping. Very likely more of these exist across the ~136-item catalog import (e.g. recipe-seed
`'Cream cheese'` vs. catalog `'CREAM CHEESE DANUBIO'` — similar but not identical, so not a safe
auto-merge candidate). Not fixed yet: needs a human pass to decide which pairs are really the same
ingredient before merging (reassign `receita_componentes`/`receita_opcoes_variaveis`/etc. to one row,
delete the other) — don't attempt an automatic merge across the whole catalog without that review, a
wrong merge would silently corrupt a recipe.

## Frontend (`docs/`)

Static HTML/CSS/vanilla JS, no build step — matches the spec's GitHub Pages + client-side-only
requirement directly. Lives in `docs/` (not `frontend/`) specifically because GitHub Pages can only
serve from a repo's root or a `/docs` folder, not an arbitrary path. The Supabase JS client is loaded
via ESM CDN (`https://esm.sh/@supabase/supabase-js@2`), not an npm dependency, so there's no
package.json here either. `.topbar` background is Boali's brand orange, `#e15c26` (given directly by
the user — not a guess) — only the header, not buttons or other green UI elements, since that's what
was actually asked for.

- `docs/js/supabase-client.js` — the shared client, configured with `db: { schema: 'motor_pedidos' }`
  so every query targets the right schema without repeating `.schema('motor_pedidos')` per call. Holds
  the project's anon key inline — intentional, anon keys are meant to be public; RLS is what actually
  protects data.
- `docs/js/auth-guard.js` — `requireAuth()` (redirects to `login.html` if no session) and `logout()`,
  imported by every page except `login.html` itself.
- `login.html` / `js/login.js` — email+password sign-in via `supabase.auth.signInWithPassword`. No
  self-serve signup UI — accounts are provisioned via the Supabase Admin API or Dashboard (see Auth
  below).
- `index.html` — post-login menu with five entries.
- `estoque.html` / `js/estoque.js` — Módulo 4 UI. Fetches active, non-`oculto_contagem` `ingredientes`
  (joined to `setores` for posição), renders a client-side-sortable table (click any header to toggle
  asc/desc — the spec's explicit requirement), one numeric input per row. **Single button**, "Salvar
  Contagem e Gerar PDF" — originally two separate buttons (save, and a blank-sheet PDF), merged into one
  on request. On click: bulk-inserts into `contagens_estoque` first; only if that succeeds does it
  generate the PDF (jsPDF via CDN, `<script src="https://cdn.jsdelivr.net/npm/jspdf@2.5.2/...">`, loaded
  as a plain non-module script so it attaches `window.jspdf` for the module script to read) — a snapshot
  of `quantidades` is taken at the top of the click handler, before the object gets cleared post-save, so
  the PDF reflects what was actually typed. The PDF is now **filled with the values just counted**, not
  a blank sheet: each row prints the typed number in the Contagem column when present, falling back to a
  blank line (the original behavior) for any item not filled in this round. Falls back to `unidade_base`
  for any ingrediente that doesn't have `unidade_contagem_padrao` set yet (some catalog items still
  don't, post-PDF-import).
- `vendas.html` / `js/vendas.js` — Módulo 5 UI. Parses an uploaded `.xlsx` client-side via SheetJS
  (`https://cdn.sheetjs.com/xlsx-latest/package/xlsx.mjs`, also CDN-loaded, no npm dep). Matches columns
  by **header text** (`PLU`, first `Nome`, exact `Qtd` — not `Qtd %`, `Valor total`, `Desconto`,
  `Impostos`, `Líquido`), not fixed column position, so reordered columns in a future export still work.
  De-duplicates by PLU keeping the **last** occurrence in the sheet — this is what makes the real
  reference file's two-block quirk (see Módulo 5 section) resolve correctly without any file-specific
  special-casing, since the correct block happens to come last. Shows a preview (matched prato vs. "não
  cadastrado") before an explicit import step; import is an `upsert` on `(prato_id, loja_id,
  data_inicio, data_fim)` (migration `20260810120000_vendas_upsert.sql`) so re-uploading the same period
  updates instead of duplicating. Período (data_inicio/data_fim) is a manual date input, not parsed from
  the file — the report's own period metadata lives in a separate sheet ("Dados de Origem") that isn't
  reliably present across exports.
- `pedido.html` / `js/pedido.js` — Módulo 6 UI. Date input (must be a Thursday, validated client-side
  before calling the DB, which would reject it anyway); on submit, calls `calcular_pedido_sugerido` via
  `supabase.rpc(...)` once per ingrediente that has `unidade_compra_fornecedor` set (in parallel via
  `Promise.all`), renders one row per ingrediente with consumo esperado / estoque atual / pedido
  sugerido. Per-ingrediente RPC errors (e.g. missing `unidades_conversao`) are caught and shown inline
  per row rather than aborting the whole calculation. Consumo esperado and estoque atual both display
  the ingrediente's `unidade_base` after the number — the RPC already returns both in that same unit
  internally (`calcular_pedido_sugerido` converts everything to `unidade_base` before comparing them),
  so this is a label added for clarity, not a unit-matching fix; `unidade_base` itself isn't part of the
  RPC's return columns, so it's fetched separately in the same `ingredientes` query used for the RPC
  parameters. "Gerar PDF (e salvar no histórico)" does two things on click, in order: **inserts one row
  per successfully-calculated ingrediente into `pedidos_sugeridos`**, then generates a PDF of the same
  table via jsPDF (same CDN pattern as `estoque.html`). The button is disabled until a calculation has
  run; results are held in a module-level `ultimoCalculo` variable so the PDF/save step doesn't need to
  recompute anything. If the DB insert fails, the PDF is still generated (shown with an inline error
  instead of silently losing the user's output) — a failed history write shouldn't block the one thing
  they actually clicked the button for.
- `desperdicio.html` / `js/desperdicio.js` — Módulo 3 UI. Toggles between "prato" and "ingrediente_bruto".
  For a prato, **does not ask which variable-group option (e.g. proteína) was used** — per explicit user
  instruction, it silently looks up whichever `receita_opcoes_variaveis` row has `padrao = true` for each
  of the prato's `receita_grupos_variaveis` and links that automatically on submit (a read-only line like
  "Proteína: Frango Crocante (assumido pela receita)" is shown for transparency, not as an input). A
  grupo with no `padrao` option set shows "nenhuma opção padrão definida ainda — não será registrada" and
  is silently skipped, same failure mode as everywhere else `padrao` is used. This *replaced* an earlier
  version with one `<select>` per grupo that let the user pick — removed on request, not layered on top.
  For an ingrediente bruto, the unit dropdown is built from that ingrediente's real `unidades_conversao`
  rows plus its `unidade_base`. Below the
  form, a table lists the loja's last 10 `registros_desperdicio` (data, item — prato or ingrediente name,
  whichever is set — quantidade+unidade, motivo mapped to a readable label), refreshed on page load and
  again right after a successful submit.
- `ingredientes.html` / `js/ingredientes.js` — catalog edit screen. Sortable/filterable table of every
  active ingrediente with inline-editable nome, posição, unidade de contagem, and an "Ocultar" checkbox.
  Columns use a `<colgroup>` with percentage widths + `table-layout: fixed` (20/38/14/18/10% —
  código/nome/posição/unidade/ocultar), not per-input pixel widths. **This replaced a first attempt that
  set the nome `<input>` to a fixed `320px`** — on a normal ~480px mobile viewport that pushed
  posição/unidade/ocultar off-screen entirely (not just needing a scroll — the user reported them as
  simply gone). Confirmed fixed by resizing the test window to 390px wide and checking
  `scrollWidth === clientWidth` (448px, zero overflow) before and after.
  **Batch save, not per-field**: edits are held in an in-memory `pendencias` map keyed by ingrediente id
  and only written on an explicit "Salvar alterações" button at the top of the page (shows a live pending
  count, e.g. "Salvar alterações (3)"); the first version auto-saved per field on blur with no button,
  which the user couldn't find — this was a deliberate redesign after that feedback, not the original
  plan. "Posição" is modeled as `setores.ordem`, not a raw column on `ingredientes` — saving it does a
  find-or-create on `setores` (look up a setor with that `ordem`, create `Setor N` if none exists, then
  repoint `ingrediente.setor_id`) rather than writing a number directly. "Ocultar" writes
  `ingredientes.oculto_contagem` (migration `20260811120000_ocultar_contagem.sql`) — deliberately a
  separate column from `ativo`: `ativo=false` would also pull the item out of desperdício/pedido
  calculations, which isn't what "hide from the counting screen" means. Built specifically to correct
  the catalog-import heuristics described below — this is the tool for fixing whatever the automated PDF
  parse got wrong, not a separate concern from it.

### Ingrediente catalog import (from `uploads/CONTAGEM ESTOQUE 25.2026.pdf`)

Real product list used for physical counting at the store — this is the "tabela-base de produtos"
described in the original spec, just arriving as a PDF instead of the anticipated `produtos_boali.xlsx`
with pre-cleaned columns. Brought the catalog from ~14 ingredientes (all sourced from a single recipe)
to 149. Parsed by a one-off script (not checked into the repo — the resulting `INSERT` is what's in
`supabase/seed.sql`), not something to re-derive by hand:

- Each PDF line is the product description with a 13-digit Comfrio code **glued directly onto the end,
  no separator** (e.g. `FRANGO EMPANADISSIMO CX4KG0101013100300`) — split via a trailing-13-digit regex.
- `unidade_contagem_padrao` extracted by finding the **leftmost** recognized packaging token in the
  remaining text (`CX`, `FD`, `GL`, `BD`, `RL`, `PCT`, `PC`, `UND`, `UN`, checked in that priority order
  so `PCT` doesn't get misread as `PC` and `UND` doesn't get misread as `UN`) — matches the exact
  vocabulary the original spec named. Leftmost match matters: `"CX 4PCT 1KG"` should resolve to `cx` (the
  outer purchase unit), not `pct` (what's inside the box). Product name = everything before that token.
  A word-boundary regex was tried first and **failed silently on ~40 items** where the unit is glued
  directly to a following digit with no space (`CX36X120GR`) — fixed by requiring the boundary only on
  the left side of the token, not both sides.
- 37 of 136 items had **no recognizable unit token at all** (e.g. `"ABACAXI CONG 20X100GR- 2KG"` — no
  `CX`/`PCT`/etc. anywhere) and imported with `unidade_contagem_padrao = null`. `unidade_base` is a
  conservative guess (liquids → `ml`, disposables/packaging keywords → `un`, otherwise `g`) that only
  matters once an item is actually used in a receita — nothing downstream breaks by it being wrong today.
- Matches spec's own expectation verbatim: *"a extração de unidade de medida é uma primeira passada
  automática e pode conter alguns itens a ajustar manualmente antes de considerar definitiva."* This
  import is that first pass; `ingredientes.html` (above) is the correction tool, not an afterthought.
- Items without a Comfrio code (fresh produce with no SKU: `MIX BRASIL`, `TOMATE`, `OVO IN NATURA`, etc.,
  19 total) got sequential `TEMP-XXX` codes, per the Módulo 1 convention already established.
- The import is keyed by `codigo_fornecedor` with a `not exists` guard, so the existing Frango Crocante
  row (same Comfrio code, already correctly named/configured) was left untouched, not overwritten.

### Auth

RLS requires `authenticated` for any access, so a login flow is required for the MVP to function at
all — there was no user account to begin with this session. Created one via the Admin API
(`POST /auth/v1/admin/users` with the service_role key, `email_confirm: true` to skip the confirmation
email):

- **Test/staff account**: `saocarlos@redeboali.com.br` — password was shared with the user in chat, not
  stored in any file in this repo. Meant as the first real login for the São Carlos store; create more
  accounts the same way (Admin API or Dashboard → Authentication → Users) as more staff need access.
  No self-serve signup page by design — this matches a small, known set of store staff rather than
  public registration.

### Verified live in-browser (not just visually)

Every page was exercised through an actual Chrome session against `http://localhost:5500` (served via
`npx serve docs`, since `type="module"` imports need an HTTP origin, not `file://`) and the real
Supabase project:

- Login → menu redirect works with the real staff account.
- Estoque: loaded live ingredientes (Frango Crocante correctly showing `pacote`), column sort verified
  (clicking "Produto" re-ordered the table alphabetically), saved a count → confirmed via direct SQL
  that the row landed with the right `data`/`quantidade`/`unidade`.
- Desperdício, prato path: selecting "Wrap Frango Picante" dynamically loaded its Proteína group with
  all 6 real options; submitted with Frango Crocante selected → confirmed both `registros_desperdicio`
  and the `registro_desperdicio_opcoes_selecionadas` link landed correctly in the database.
- Desperdício, ingrediente_bruto path: selecting Frango Crocante correctly repopulated the unit dropdown
  to `g`/`pacote`/`caixa`; submitted with `pacote` → confirmed in the database.
- Vendas: uploaded the actual real `uploads/Vendas_PLU.xlsx` through the file input — parsed 177 unique
  PLUs, correctly recognized exactly the 2 already-cataloged pratos (`220002`, `240004`) with the right
  quantities (19, 67), correctly left the other 175 as "não cadastrado". Import → upsert confirmed via
  SQL: same rows updated in place (new `created_at`), no duplicates, matching the unique constraint.
- Pedido Sugerido: computed live for `2026-08-13`, returned the same `periodo_inicio`/`periodo_fim`/
  `consumo_esperado`/`estoque_atual`/`pedido_sugerido` values as the direct SQL call in the Módulo 5/6
  sections above — UI and function agree exactly.
- Ingredientes: confirmed 149 rows render (matches `select count(*)`), edited a real row's posição
  (blank → `2`) and unidade (blank → `pct`) — confirmed via SQL the find-or-create-setor logic actually
  created a new `Setor 2` row and repointed `setor_id`, and `estoque.html` picked up both the new item
  count (149, up from ~14) and the edited posição on the very next load with no cache/refresh issue.
  Separately, checked "Ocultar" on that same row, saved via the batch button, confirmed
  `oculto_contagem = true` in the database, and confirmed `estoque.html` dropped to 148 rows with that
  item's name absent from the page text — then reverted the flag back to `false` directly via SQL since
  it was only a test toggle, not a real hide request for that specific item.
- No console errors from the app itself (3 exceptions seen on the login page early in this project are
  generic Chrome-extension noise, not app code — never recurred across any interaction on any page,
  across multiple separate test sessions).
- One flake worth knowing: on this round of testing, `computer` tool clicks via element `ref` on
  `analisar-btn`/`calcular-btn` didn't reliably fire the button's handler (no error, just nothing
  happening) even though the element was correctly targeted and enabled — triggering `.click()` via
  `javascript_tool` worked every time. Not an app bug (confirmed the DOM state was correct beforehand);
  if UI automation seems to silently do nothing on this project again, try a JS-driven click before
  assuming the app is broken.
- Another testing-only flake: `pedido.html`'s "Gerar PDF" download succeeded (a real file appeared in
  Downloads), but the very next `estoque.html` "Gerar PDF" attempt silently produced no file — no thrown
  JS error either from a scripted `.click()` **or** a genuine `computer` mouse click on the actual
  button. Root-caused as Chrome throttling repeated automatic downloads within one browser session
  (`jsPDF.save()` succeeds from the page's perspective either way — the browser can block the write
  without telling the page). Confirmed by opening a **fresh tab** and trying `estoque.html`'s PDF as the
  first download of that session: worked immediately (62KB file, all 149 rows, multi-page). Not a code
  bug — a real user's browser won't have just done a rapid string of automated downloads before their
  first click, so this shouldn't surface outside of testing. If a future PDF button here "does nothing"
  during testing, try a fresh tab before assuming the generation code is broken.
- Re-verified after merging estoque.html's save+PDF buttons into one: typed `7` into ACAI FROOTY (a real
  catalog item), clicked the single button (fresh tab, real mouse click), confirmed **both** effects —
  `contagens_estoque` got the row (via SQL) **and** the downloaded PDF (opened and read back) shows
  `ACAI FROOTY | bd | 7` filled in on that exact line, every other row still a blank line. That test
  count (7) is left in the database, same rationale as other real-input test rows in this doc.

### Deployment

Live at **https://tazima85.github.io/motor-pedidos-boali/**, verified with a real login end-to-end
against the deployed site (not just locally). GitHub repo `tazima85/motor-pedidos-boali`, source
`master` branch `/docs`.

The repo is **public**, not private — this is a real constraint, not a preference: GitHub Pages for
private repos requires GitHub Pro, and `gh api .../pages` fails with a 422 ("Your current plan does not
support GitHub Pages for this repository") on the free plan. Presented with pay-for-Pro vs.
deploy-elsewhere vs. go-public, the user chose to make the repo public, accepting that `uploads/`'s
tracked files (Quadro de Receitas, Pedido Comfrio) and all source code are publicly visible on GitHub.
Independently of repo visibility, the *site itself* was always going to be reachable by anyone with the
URL regardless — GitHub only restricts Pages visibility on Enterprise plans — so Supabase Auth + RLS
remains the actual data-access boundary (no session → login screen only, nothing queryable).

**Incident, now resolved**: during the `frontend/` → `docs/` rename, `git add -A` swept up
`uploads/Vendas_PLU.xlsx` — a file with real weekly revenue/discount/tax figures that had been placed
there (intentionally, by the user, as a format reference for this Módulo 5 work) but was not reviewed
before committing. It went public for a few minutes while the repo was public. Response: repo flipped
private immediately, the file untracked (`git rm --cached`) and gitignored, then re-confirmed with the
user — who clarified they'd placed it intentionally and didn't want git history rewritten (it's already
private, low urgency) or the deployment approach changed (still fine going public again). Repo was made
public again afterward once `uploads/Vendas_PLU.xlsx` was confirmed excluded. **Lesson for future
work here**: `uploads/` is a real folder the user drops files into outside of any conversation — never
run `git add -A` (or `git add uploads/`) without checking `git status`/diffing new files first, even
though the first two files in there turned out fine to track.

### Not done yet

- All six módulos now have working UI, including `ingredientes.html` for editing the catalog. Still
  missing: creating a *new* ingrediente or prato from the UI (only editing existing rows), any
  receita-editing screen (componentes/grupos/opções are SQL-only), and a way to view/set
  `fatores_sazonalidade` from the UI.
- `vendas.html`'s PLU→prato matching requires `pratos.codigo_plu` to already be set — there's no UI to
  set it (or to create a new prato) from the vendas screen itself, so cataloging the other 175 PLUs
  found in the real file is still a manual SQL job.
- `contagens_estoque` has no upsert/edit — recounting the same day always inserts a new row
  (intentional append-only log; the tie-break fix in migration 0006 makes "most recent" deterministic
  for `calcular_pedido_sugerido`, but there's no UI to see stock history yet).
- `pedidos_sugeridos` now exists and is written on every "Gerar PDF" in `pedido.html`, but there's no UI
  to browse that history yet — it's a write-only log from the frontend's point of view for now. One real
  test row lives in it from verifying the feature (2026-08-13, Frango Crocante, `pedido_sugerido = 0`) —
  harmless real output from real inputs, left in place same as other test-verification rows elsewhere in
  this doc, not cleaned up automatically.

### Supabase project & schema isolation

Both migrations and the seed have been applied and verified end-to-end against the real hosted
project **"Reports Boali"** (ref `fwwebebfagezdqsbybjy`, org `tazima85 Projects`) — chosen because the
org's free tier was already at its 2-project limit. To avoid mixing with whatever else lives in that
project, everything here lives in its own Postgres schema, **`motor_pedidos`**, not `public` — every
migration starts with `create schema if not exists motor_pedidos; set search_path to motor_pedidos,
public;`, and the `converter()` function additionally pins `set search_path = motor_pedidos, public`
on itself so it resolves correctly regardless of the caller's session state.

Getting `motor_pedidos` reachable from `supabase-js`/PostgREST took two separate steps, both now done
and verified with a real REST call (`.../rest/v1/ingredientes` with `Accept-Profile: motor_pedidos`):

1. **Expose the schema** — Dashboard → Project Settings → API → Data API settings → Exposed schemas.
   Manual, can't be done via CLI/migration; `supabase/config.toml`'s `api.schemas` only affects local
   dev, not the remote project.
2. **Grant the Postgres roles access to it** — exposing the schema only teaches PostgREST to route
   requests there; the `authenticated`/`service_role` roles still need `GRANT USAGE ON SCHEMA` +
   table/function grants, which `public` gets for free but a custom schema does not. Without this every
   query 404s as `permission denied for schema motor_pedidos` (42501), regardless of RLS. Fixed in
   `20260808120000_grants_motor_pedidos.sql`, including `ALTER DEFAULT PRIVILEGES` so future tables in
   this schema inherit the grants automatically. `anon` is deliberately left with no grant at all — the
   MVP requires a logged-in user for any access, and the RLS policies (0001) only cover `authenticated`
   anyway, so granting `anon` schema visibility would buy nothing.

CLI quirks hit while setting this up, worth knowing before repeating the process:
- Non-TTY environments can't do `supabase login`'s browser flow — use a Personal Access Token via
  `SUPABASE_ACCESS_TOKEN` instead (from Dashboard → Account → Access Tokens).
- `supabase link` can report a `LegacyPlatformAuthRequiredError`/schema-validation error while fetching
  API keys even though the link itself succeeded — check `supabase/.temp/linked-project.json` before
  assuming failure. If `supabase/.temp/project-ref` wasn't written because of that, `db push --linked`
  fails with "Cannot find project ref" — write that file manually (just the bare ref string) as a
  workaround.
- Direct Postgres connections (`db.<ref>.supabase.co:5432`) hit `LegacyDbConfigIpv6Error` on networks
  without IPv6 — re-running `supabase link` switches it to the IPv4-compatible pooler, after which
  `db push --linked` / `db query --linked` work.
- `supabase db query --linked` appears to run each semicolon-separated statement independently (e.g.
  possibly separate connections/transactions) — a leading `set search_path ...;` in the same
  invocation did **not** carry over to a later statement in that same call in testing. Fully
  schema-qualify (`motor_pedidos.table`, `motor_pedidos.converter(...)`) when using this command
  interactively; the migrations/seed files don't have this problem since the whole file runs as one
  script.

**Data lesson from this seed run**: the first pass silently dropped the "Frango crocante" protein
option from `receita_opcoes_variaveis` because the seed's VALUES list used the spreadsheet's literal
lowercase casing (`'Frango crocante'`) while the ingrediente had been inserted as `'Frango Crocante'`
— Postgres text equality is case-sensitive, so the join on `i.nome = v.ingrediente_nome` silently
matched zero rows instead of erroring. Caught by re-querying the seeded decomposition and noticing the
protein was missing from the totals, not by any constraint. Matching ingredient names by exact string
across independent VALUES lists is fragile — worth double-checking with a row-count sanity query after
any future seed that joins on `nome` this way.

### Quadro de Receitas matrix — structure to know before seeding more pratos

`uploads/Quadro_Receitas_Completo_2026 (2).xlsx` is ingredients-as-rows × pratos-as-columns, but rows
are grouped into named sections (row with only column A filled = a section divider):

- **BASE** — always-included componentes_fixos.
- **SALAD BAR, PROTEÍNA, MOLHO, CROCANTE, COBERTURA, FINALIZAÇÃO** — each is a `componentes_variaveis`
  group; a non-empty cell in a section for a given prato column is one option in that prato's group for
  that section, at that cell's quantity (bare numbers = grams; explicit suffixes like `1 uni`/`25ml`
  override the default).

Almost every prato in the sheet has at least one variable group — very few (if any) are purely
`tipo = 'fixo'`. Don't assume a dish is simple just because its name sounds fixed.

## Intended architecture (from the product spec)

- **Frontend**: static pages published via GitHub Pages, talking to Supabase directly from the
  client — no dedicated Node backend in production.
- **Database/auth**: Supabase (Postgres).
- **Motor de Previsão (Módulo 6)**: an isolated function (Supabase Edge Function or standalone
  script), deliberately decoupled from the UI so it can be tested independently of any frontend.
- **Registro de Desperdício** and **Contagem de Estoque** need simple, mobile-friendly UIs — waste is
  logged from the shop floor throughout the day, not just at closing.

Six modules form one pipeline:

```
Vendas (5) + Receitas (2) → consumo teórico
  + Desperdício normalizado (3) − Estoque atual (4)
  × fator de sazonalidade (passada + futura)
  → pedido sugerido (6)
```

### Replenishment cycle (drives Módulo 6's horizon — non-obvious, don't default to "one week")

Orders are placed Thursday night and arrive Monday; the store runs on hand-stock alone in between. A
Thursday order must cover consumption through the **following Tuesday**, not Monday — the extra day is
safety margin for supplier delays or demand spikes. So the engine's forecast horizon is the real
~8-9 day coverage window (Thu → Tue), not a generic 7-day week.

## Database schema (`supabase/migrations/`)

Covers all six módulos now. Key design decisions baked into the schema:

- `ingredientes.codigo_fornecedor` is the cross-module business key: the supplier's (Comfrio) SKU, or
  a `TEMP-XXX` placeholder for items without one (mostly fresh produce). One `ingredientes` row covers
  an item across its whole lifecycle (purchase, recipe use, stock count) — only the *unit* changes
  (e.g. Frango Crocante: bought by caixa, used in recipes by grama, counted by pacote), no
  purchased-vs-prepared split or cooking-yield factor modeled.
- `unidades_conversao.fator_para_base` is **pre-flattened** to `unidade_base` — a unit like "caixa"
  that's really `N sacos × 1000g` stores the single resulting multiplier directly, so conversion never
  needs to resolve a chain at query time.
- `converter(quantidade, unidade_origem, unidade_destino, ingrediente_id)` (Módulo 1's key function) is
  implemented as a Postgres `plpgsql` function in the migration itself, not in application code.
- `registros_desperdicio` is polymorphic between `prato_id` and `ingrediente_id` (waste can be declared
  against a finished dish or a raw ingredient), enforced by the `chk_referencia_por_tipo` CHECK
  constraint — exactly one of the two must be set, matching `tipo_perda`. When it's a `prato` with
  variable groups, `registro_desperdicio_opcoes_selecionadas` (0002) records which option was picked per
  group so the decomposition-by-recipe is complete, not just the fixed base.
- `ingredientes.setor_id` defaults to the seeded "Setor Único" row so every ingredient has a valid
  physical-position value from day one; real sector cadastro and proximity-based sort ordering for the
  counting UI are meant to layer on top later without a backfill. Implemented as a **hardcoded literal
  UUID default** (`00000000-0000-0000-0000-000000000001`), not a lookup-by-name subquery — Postgres
  column `DEFAULT` clauses cannot contain subqueries.
- RLS is enabled on every table with one permissive "authenticated can do anything" policy each
  (applied via a `DO` block loop over table names) — intentionally coarse for the single-loja MVP;
  tighten per-role/per-loja once more than one loja is live.

## Open decisions (from the spec, still unresolved)

1. Seasonality granularity: `fatores_sazonalidade.nivel` supports `prato`/`ingrediente`/`loja` at the
   data-model level, and `calcular_pedido_sugerido()` currently queries at `ingrediente` level — but no
   actual factors have been entered for anything yet, and nothing forces that choice going forward.
2. How the sales system represents customized dishes — resolved differently than originally assumed,
   and better than expected: the real POS report shows protein/modifier choices as their own separate
   PLU sales rather than an attribute of the base dish's sale, so `vendas` doesn't need a
   `registro_desperdicio_opcoes_selecionadas`-style link table (see Módulo 5 section).
   `receita_opcoes_variaveis.padrao` is now set (Wrap Frango Picante → Frango desfiado; Wrap Crocante ao
   Pesto and Bowl da Fazenda → Frango Crocante) and used by `desperdicio.html` — but only there.
   `calcular_consumo_teorico_medio_diario` (Módulo 5) still ignores `padrao` and still contributes 0 for
   variable groups; whether Módulo 5 should
   also start using `padrao` hasn't been asked or decided.
3. Supplier rounding/minimum-lot rules beyond simple closed-box rounding — implemented and verified
   (`ceil(necessidade / lote_minimo_compra) * lote_minimo_compra`), but only the "closed box" case has
   been exercised; no per-supplier minimum-order-value or mixed-lot rules yet.
4. Order-accuracy validation (suggested vs. actually-ordered vs. actual consumption) is explicitly
   backlog — don't implement it, but don't design the schema in a way that blocks storing real placed
   orders later.
5. `calcular_pedido_sugerido()`'s known estoque-at-arrival simplification (see Módulo 6 section above).
