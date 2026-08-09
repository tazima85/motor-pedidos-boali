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
- `supabase/seed.sql` — real end-to-end data for the Frango Crocante validation: ingrediente "Frango
  Crocante" (Comfrio code `0101013100300`, `FRANGO EMPANADISSIMO CX4KG`, 1 caixa = 10 pacotes × 400g),
  the prato "Wrap Frango Picante" (the only dish where Frango Crocante is a Proteína-group option), a
  waste record (2× the dish, decomposed via the recipe), an illustrative stock count by pacote, and a
  real week of vendas (see Módulo 5 below). Idempotent (safe to re-run). Sourced from
  `uploads/Quadro_Receitas_Completo_2026 (2).xlsx` (full recipe matrix), `uploads/Pedido
  1652340949691-01.xlsx` (a real Comfrio order), and the real numbers from `uploads/Vendas_PLU.xlsx`
  (see below — that file itself is *not* tracked in the repo). Note: unlike migrations,
  `supabase/seed.sql` only auto-applies on `supabase db reset` (local dev) — against a remote/linked
  project it must be run explicitly (`supabase db query --linked --file supabase/seed.sql`).
- `uploads/` holds source spreadsheets used as reference — treat the tracked ones (Quadro de Receitas,
  Pedido Comfrio) as read-only, not something to regenerate. `uploads/Vendas_PLU.xlsx` is deliberately
  **not tracked** (real revenue/discount/tax figures) — see Deployment section. Any other file that
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

**Open gap, not fabricated**: `receita_opcoes_variaveis.padrao` (the flag meant to mark a fallback
"assumed" option per group, per the original spec's "distribuição média" idea) is not set to `true` on
any option yet, for any grupo — there's no real frequency data yet to justify picking one protein over
another as "the default," and marking one arbitrarily would quietly bias every future forecast. Until
real choice-frequency data exists (or the business states a deliberate assumption), Wrap Frango
Picante's own protein simply contributes 0 to consumo teórico from `vendas` — only its BASE components
and any separately-sold modifier PLUs (like the Proteína Extra prato) are counted.

## Frontend (`docs/`)

Static HTML/CSS/vanilla JS, no build step — matches the spec's GitHub Pages + client-side-only
requirement directly. Lives in `docs/` (not `frontend/`) specifically because GitHub Pages can only
serve from a repo's root or a `/docs` folder, not an arbitrary path. The Supabase JS client is loaded
via ESM CDN (`https://esm.sh/@supabase/supabase-js@2`), not an npm dependency, so there's no
package.json here either.

- `docs/js/supabase-client.js` — the shared client, configured with `db: { schema: 'motor_pedidos' }`
  so every query targets the right schema without repeating `.schema('motor_pedidos')` per call. Holds
  the project's anon key inline — intentional, anon keys are meant to be public; RLS is what actually
  protects data.
- `docs/js/auth-guard.js` — `requireAuth()` (redirects to `login.html` if no session) and `logout()`,
  imported by every page except `login.html` itself.
- `login.html` / `js/login.js` — email+password sign-in via `supabase.auth.signInWithPassword`. No
  self-serve signup UI — accounts are provisioned via the Supabase Admin API or Dashboard (see Auth
  below).
- `index.html` — post-login menu with two entries.
- `estoque.html` / `js/estoque.js` — Módulo 4 UI. Fetches all active `ingredientes` (joined to `setores`
  for posição), renders a client-side-sortable table (click any header to toggle asc/desc — the spec's
  explicit requirement), one numeric input per row, bulk-inserts into `contagens_estoque` on save. Falls
  back to `unidade_base` for any ingrediente that doesn't have `unidade_contagem_padrao` set yet (most
  of the stub ingredients from the seed don't).
- `desperdicio.html` / `js/desperdicio.js` — Módulo 3 UI. Toggles between "prato" and "ingrediente_bruto".
  For a prato, dynamically loads its `receita_grupos_variaveis` + `receita_opcoes_variaveis` and renders
  one `<select>` per group (this is what feeds `registro_desperdicio_opcoes_selecionadas`); optional
  groups get a "— nenhuma —" option, required groups don't. For an ingrediente bruto, the unit dropdown
  is built from that ingrediente's real `unidades_conversao` rows plus its `unidade_base`.

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
- No console errors from the app itself (3 exceptions seen are generic Chrome-extension noise tied to
  the login page's first load, not app code — didn't recur across any later interaction).

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

- No UI yet for anything beyond Módulos 3/4 — Módulo 5 (vendas) and Módulo 6 (pedido sugerido) are
  fully working in the database, but there's no page to upload/import a sales report or to view a
  computed pedido sugerido. No ingrediente/receita cadastro screens either.
- `contagens_estoque` has no upsert/edit — recounting the same day always inserts a new row
  (intentional append-only log; the tie-break fix in migration 0006 makes "most recent" deterministic
  for `calcular_pedido_sugerido`, but there's no UI to see stock history yet).

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
   `registro_desperdicio_opcoes_selecionadas`-style link table (see Módulo 5 section). What's still open
   is `receita_opcoes_variaveis.padrao` — no option is marked as the assumed default for any grupo
   variável, since there's no real choice-frequency data to justify picking one. A prato's own variable
   group currently contributes 0 to consumo teórico until either real frequency data or a deliberate
   business assumption sets `padrao` on something.
3. Supplier rounding/minimum-lot rules beyond simple closed-box rounding — implemented and verified
   (`ceil(necessidade / lote_minimo_compra) * lote_minimo_compra`), but only the "closed box" case has
   been exercised; no per-supplier minimum-order-value or mixed-lot rules yet.
4. Order-accuracy validation (suggested vs. actually-ordered vs. actual consumption) is explicitly
   backlog — don't implement it, but don't design the schema in a way that blocks storing real placed
   orders later.
5. `calcular_pedido_sugerido()`'s known estoque-at-arrival simplification (see Módulo 6 section above).
