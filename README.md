# AI For Accountability Hackathon

A multi-dataset analysis platform for Canadian government transparency and accountability research, built for the **AI For Accountability Hackathon** (April 29, 2026).

## Overview

This repository unifies four major sources of Canadian government open data into a single PostgreSQL database, with each dataset in its own schema so tables never collide. On top of that raw data sits a **cross-dataset entity resolution pipeline** that reconciles ~1 million source records into ~851,000 canonical organizations, each with a golden record linking every funding stream across CRA charity filings, federal grants, and Alberta grants/contracts/sole-source.

All data is redistributed under the original publishers' open-government licences — Canada Revenue Agency T3010 filings, federal Grants & Contributions disclosures, and Alberta open data. See [ATTRIBUTIONS.md](ATTRIBUTIONS.md) for data sources and third-party library credits.

## Prerequisites

| Component | Version | Notes |
|-----------|---------|-------|
| **Node.js** | 18 or newer | Required by every module |
| **Python** | 3.10 or newer | Required only for the Splink stage of the entity-resolution pipeline |
| **PostgreSQL** | 14 or newer | With the `pg_trgm` extension enabled |
| **Disk space** | ~20 GB | Full local database copy (~13 GB JSONL data bundle + loaded tables + indexes). Splink's intermediate parquet files add ~60 MB on top while that stage is running. |
| **Memory** | 4 GB minimum, 8 GB recommended | The Splink + LLM-pipeline stages benefit from more RAM; everything else is light. |

### Credentials

> **Hackathon participants:** the `.env.public` files for each module (`CRA/`, `FED/`, `AB/`, `general/`) are **distributed by the hackathon organizers in the info pack provided on event day (April 29, 2026)**. Drop the info-pack files into their matching module directories before running any `npm run` commands that touch the database. Without them a fresh clone cannot connect to the shared database. See [SECURITY.md](SECURITY.md) for details and for what to do if you want to run against your own local Postgres instead (no info pack needed).

## Architecture

```
hackathon/
├── CRA/             # CRA T3010 Charity Data (cra schema)
├── FED/             # Federal Grants & Contributions (fed schema)
├── AB/              # Alberta Open Data (ab schema)
├── general/         # Cross-dataset entity resolution pipeline (general schema)
├── .local-db/       # Recreate the hackathon database in your own Postgres
├── index.html       # Landing page / documentation browser
├── ATTRIBUTIONS.md  # Third-party libraries and data source citations
├── SECURITY.md      # Credentials, .env convention, data sensitivity
├── tests/           # Cross-module unit + integration tests
├── LICENSE          # MIT (covers source code — NOT the data, which follows
│                      the original open-government licences)
└── README.md        # This file
```

All four data modules share the same PostgreSQL database on Render (`cra`, `fed`, `ab`, `general` schemas). Every module follows the same conventions:

- **`.env.public`** — shared read-only credentials, **gitignored** (distributed by the hackathon organizers in the event-day info pack)
- **`.env`** — personal admin overrides, gitignored
- `.env.public` loads first; `.env` overrides

## Datasets

### CRA — Canada Revenue Agency T3010 Charity Data

**Schema:** `cra` · **Rows:** ~8.76M (7.3M T3010 raw + ~1.42M pre-computed analysis) · **Tables:** 49 + 3 views · **Years:** 2020–2024

Annual filings from ~85,000 registered Canadian charities: financial statements, directors, gift flows between charities, program descriptions. Also includes pre-computed accountability-analysis tables (loop detection across 2–6 hops, SCC decomposition, overhead rollups, government-funding breakdown, T3010 data-quality violation flags, donee-name quality scoring).

```bash
cd CRA && npm install && npm run setup
```

Features: circular-gifting detection, 0–30 risk scoring, SCC + Johnson's algorithm cross-validation, interactive charity lookup + risk profiling.

### FED — Federal Grants & Contributions

**Schema:** `fed` · **Rows:** ~1.275M · **Tables:** 6 + 3 views

Every federal grant, contribution, and transfer payment from 51+ departments to 422K+ recipients, as published via the Government of Canada Open Data portal.

```bash
cd FED && npm install && npm run setup
```

Features: 7-dimension risk scoring (0–35), provincial-equity analysis, amendment creep, recipient concentration (HHI), cross-reference with CRA registry.

### AB — Alberta Open Data

**Schema:** `ab` · **Rows:** ~2.61M · **Tables:** 9 + 3 views · **Years:** 2014–2026

| Dataset | Table | Rows |
|---------|-------|------|
| Alberta Grants | `ab_grants` | 1,986,676 |
| Blue Book Contracts | `ab_contracts` | 67,079 |
| Sole-Source Contracts | `ab_sole_source` | 15,533 |
| Non-Profit Registry | `ab_non_profit` | 69,271 |

```bash
cd AB && npm install && npm run setup
```

Features: sole-source deep dive (repeat vendors, contract splitting, geographic concentration), grant/contract ratio analysis, non-profit lifecycle + sector-health scoring, 6 advanced analysis scripts producing JSON + TXT reports.

### general — Cross-Dataset Entity Resolution

**Schema:** `general` · **Rows:** ~10.5M · **Tables:** 14 + 2 views

The module that unifies everything else. Produces one canonical **golden record** per real-world organization, linked to every source row that contributed to it. After a full pipeline run: **~851K golden records**, ~5.2M source links, ~67K LLM-confirmed merges, ~65K RELATED cross-links.

```bash
cd general && npm install && npm run setup
```

See the [Entity Resolution](#entity-resolution) section below + [general/README.md](general/README.md) for the full pipeline.

## Entity Resolution

The core challenge across these datasets: the same organization appears under dozens of name variations. A typical mid-sized registered charity operating across all three datasets will have 10+ distinct name variants in the source data, spread across 6 tables, with multiple Business Number suffix variants (the `RR` charity account, the `RC` corporate-tax account, the `RP` payroll account). Without reconciling them to one canonical entity, cross-dataset accountability analysis is impossible.

The `general` module combines three complementary techniques:

1. **Deterministic matching** — business-number anchoring + exact + normalized-name + trade-name extraction, walked across the six source tables in trust order (CRA first, federal next, Alberta last). Catches the easy cases.
2. **Probabilistic matching via [Splink](https://moj-analytical-services.github.io/splink/)** — UK Ministry of Justice's Fellegi-Sunter record-linkage library, with feature weights learned from the data via expectation-maximization. Catches hierarchical organizations, truncated variants, and no-BN cross-dataset matches that rules miss.
3. **LLM verdict and authoring** — Claude Sonnet 4.6, 100+100 concurrent workers against Anthropic's direct API and Google Vertex AI in parallel. The LLM decides SAME / RELATED / DIFFERENT per candidate pair and, when SAME, *authors the canonical golden record* (canonical name, entity type, exhaustive alias list) in the same call.

The output is a single `entity_golden_records` table — one row per real-world organization — with canonical name, every observed alias, primary BN + all variants, per-dataset profiles (CRA registration + financials, federal grants summary, Alberta totals), addresses, merge history, and cross-references to related entities.

### Two browser tools (run both simultaneously)

- **Pipeline Dashboard** at `http://localhost:3800` (`npm run entities:dashboard`) — operator interface. Reset, migrate, and run each pipeline stage with one-click buttons; streaming log for each. Real-time metrics on entity counts, source links, Splink build status, LLM progress + ETA. Six test-entity sanity cards flag regressions instantly.
- **Dossier Explorer** at `http://localhost:3801` (`npm run entities:dossier`) — analyst interface. Search by name or BN, view the complete per-entity dossier (7 tabs: Overview, CRA T3010 by year, Qualified Donees, Source Links, Related / maybe-merge, Accountability flags, International, Merge History, Raw JSON). Multi-select merge from search results. Full-dossier JSON download including pre-aggregated combined view across any browser-merged entities.

Key design principles:

- **BN is the primary identifier** — every stage treats the 9-digit Canadian Business Number root as authoritative.
- **Every stage is idempotent and resumable** — interruptions pick up cleanly.
- **Every stage is observable** — dashboard polls the database directly; no separate event stream to drift out of sync.

See [general/README.md](general/README.md) for the full pipeline documentation (seven stages, libraries, outcomes, year-alignment conventions, verification checklist against the Splink reference implementation).

## Local Database Recreation (`.local-db/`)

If you need a full local copy of the hackathon database — either because you don't have access to the shared Render instance or because you want to rebuild the pipeline end-to-end on your own Postgres — the `.local-db/` directory contains everything required.

```
.local-db/
├── README.md       # Quick-start instructions
├── export.js       # (maintainers) dump the live DB to local files
├── import.js       # (participants) recreate the DB in your local Postgres
├── manifest.json   # Table inventory with row counts + column metadata
├── schemas/        # DDL (CREATE TABLE + INDEX + VIEW) per schema
│   ├── cra.sql
│   ├── fed.sql
│   ├── ab.sql
│   └── general.sql
└── data/           # JSONL files, one per table (gitignored — ~13 GB total)
    ├── cra/ fed/ ab/ general/
```

**Auto-discovering**: both `export.js` and `import.js` enumerate all tables via `information_schema.tables` at runtime, so new tables added to any schema (e.g. the entity-resolution or Splink tables in `general`) are picked up automatically — no code change required on either side.

**For participants** (spinning up a local copy):
```bash
createdb hackathon                                     # or through your Postgres admin
cd .local-db && npm install
DB_CONNECTION_STRING=postgresql://user:pass@localhost/hackathon npm run import
```

**For maintainers** (refreshing the export from the live database):
```bash
cd .local-db && npm install
DB_CONNECTION_STRING=postgresql://admin:pass@render.com:5432/... npm run export
```

Re-running `export` regenerates the schemas, manifest, and JSONL data for all four schemas (including the latest entity-resolution pipeline output). JSONL was chosen over CSV so that `jsonb`, `text[]`, nulls, and strings with embedded newlines/commas/quotes round-trip without escaping games. The JSONL data files in `.local-db/data/` are gitignored (~13 GB total); only the export/import code, DDL, and manifest travel with the repo.

## Environment Configuration

Each module loads environment variables in this order:

1. **`.env.public`** loaded first — shared defaults. **Gitignored**, distributed by the hackathon organizers in the event-day info pack.
2. **`.env`** loaded second with `override: true` — personal overrides, gitignored.

Participants who drop the info-pack `.env.public` files into each module directory get read-only credentials automatically. Maintainers with a `.env` file (containing admin credentials) override for write operations like migrations and imports.

## Quick Start

```bash
# Clone and install everything
git clone <repo-url> && cd hackathon
for dir in CRA FED AB general; do (cd $dir && npm install); done

# Option 1 — connect to the shared Render database (read-only for participants)
# Nothing to do; the schemas are already loaded. Verify:
cd CRA && npm run verify
cd ../FED && npm run verify
cd ../AB && npm run verify

# Option 2 — recreate the database in your own local Postgres
createdb hackathon
cd .local-db && npm install && DB_CONNECTION_STRING=postgresql://... npm run import

# Run the dataset analysis scripts
cd ../AB && npm run analyze:all
cd ../CRA && npm run analyze:all

# Run the entity-resolution pipeline (produces golden records across CRA+FED+AB)
cd ../general
npm install
npm run entities:splink:install     # one-time: Splink Python dependencies
npm run entities:dashboard          # http://localhost:3800 — pipeline control
npm run entities:dossier            # http://localhost:3801 — per-entity explorer
```

## Database Access

**Option A — shared read-only** (for querying from the hosted database):

```
postgresql://hackathon_readonly:...@render.com:5432/database_database_w2a1
```

Credentials are in each module's `.env.public`, distributed by the hackathon organizers in the event-day info pack. Read-only: `SELECT` works; `INSERT`/`UPDATE`/`DELETE` blocked. Suitable for participants doing analysis without a local setup.

**Option B — local full copy** (for running the full pipeline or needing write access):

Use `.local-db/` to recreate the database in your own Postgres instance. Run `.local-db/export.js` against the shared Render DB to produce fresh JSONL files, then `.local-db/import.js` to reload into your local DB. See [.local-db/README.md](.local-db/README.md) for details.

**Schemas:** `cra`, `fed`, `ab`, `general` (`search_path` set via each module's `lib/db.js`).

## Running the tests

Cross-module unit and integration tests live in `tests/end-to-end.test.js` — they cover the shared libraries (transformers, loggers, CSV parsers, fuzzy-match, entity-resolver, LLM-review), database pool connectivity, and key integration paths.

```bash
node --test tests/end-to-end.test.js
```

Pure-function tests run instantly. DB-dependent tests require the modules' `.env` / `.env.public` files to be in place (they connect via the same pool configuration as the rest of the pipeline).

## License

Source code and pipeline: **MIT** — see [LICENSE](LICENSE).

Data: redistributed under the original publishers' licences — **[Open Government Licence – Canada](https://open.canada.ca/en/open-government-licence-canada)** (CRA and federal data) and **[Open Government Licence – Alberta](https://open.alberta.ca/licence)** (Alberta data). The MIT licence on this repository covers the source code only and does not relicense the underlying data. See [ATTRIBUTIONS.md](ATTRIBUTIONS.md) for full source-attribution details and third-party library credits; see [SECURITY.md](SECURITY.md) for the credential-handling convention.

## Deploy to Azure

This section is for **hackathon participants** who want to publish their team's Dashboard and Dossier apps to Azure Container Apps so judges and teammates can use them from a public URL.

> **You only deploy the two apps** (`Dashboard` and `Dossier`). The shared base infrastructure — Azure Container Registry, Container Apps Environment, Key Vault, API Management gateway, and the Foundry-backed LLM endpoint — is **already provisioned and locked by the organizers**. You will not create, modify, or have access to it. Each team is given a per-team APIM subscription key that lets your apps call the shared LLM gateway.

### Application architecture

The diagram below shows what **your team deploys** (the two Container Apps in the blue zone) and the shared services they call. Everything outside the blue zone is organizer-managed and read-only from your perspective.

![Participant application architecture](docs/app-architecturepng.png)

- **Client** — your browser hits the public HTTPS URL of each Container App.
- **Team-Deployed (Azure Container Apps)** — `Dashboard` (port 3800) and `Dossier` (port 3801), built from [general/](general/) and pushed via `deploy-app.ps1`.
- **Image Source** — the shared **Azure Container Registry** that both apps pull their image from.
- **LLM Gateway** — **Azure API Management** fronts the Foundry endpoint; your apps authenticate with the per-team `Ocp-Apim-Subscription-Key` header.
- **Microsoft Foundry (organizer-managed)** — exposes `gpt-5`, `gpt-5-mini`, and `text-embedding-3-large` via the standard `/openai/deployments/{model}/chat/completions?api-version=2024-10-21` path.
- **Read-Only Data Store** — the shared **PostgreSQL read replica** on Render. Writes are blocked at the protocol level — your apps can only `SELECT`.

Source diagram: [docs/participant-app-architecture.drawio](docs/participant-app-architecture.drawio) (open in the Draw.io VS Code extension to edit).

### What you will deploy

| App | Purpose | Public URL pattern |
|---|---|---|
| **Dashboard** | Pipeline control panel + LLM provider smoke test | `https://ca-<prefix>-dashboard.<env-domain>` |
| **Dossier** | Per-entity dossier read-only viewer | `https://ca-<prefix>-dossier.<env-domain>` |

Both apps are built from the [general/](general/) folder, packaged as Docker images, pushed to the shared Azure Container Registry, and run on the shared Container Apps Environment.

### Prerequisites

Install these on your laptop **before** starting:

| Tool | Why | Install |
|---|---|---|
| **Azure CLI** ≥ 2.60 | Builds images on ACR, deploys Container Apps | https://learn.microsoft.com/cli/azure/install-azure-cli |
| **Azure CLI `containerapp` extension** | Deploys to Azure Container Apps | `az extension add --name containerapp --upgrade` |
| **PowerShell 7+** (`pwsh`) | Runs the deployment script (works on Windows, macOS, Linux) | https://learn.microsoft.com/powershell/scripting/install/installing-powershell |
| **Git** | Clone this repo | https://git-scm.com/downloads |

You do **not** need Docker installed locally. Image builds run remotely on Azure Container Registry via `az acr build`.

You also need:

- An **Azure account** that the organizer has added as a contributor on the platform resource group (or Reader + ACR Push). Sign in once with `az login`.
- The **organizer info pack** containing your team's:
  - APIM subscription key (for calling the Foundry LLM gateway)
  - Render Postgres read-only connection string

### Step 1 — Sign in to Azure

```powershell
az login
az account set --subscription <SUBSCRIPTION_ID_FROM_ORGANIZER>
az extension add --name containerapp --upgrade
```

### Step 2 — Configure your `.env` file

From the repo root, copy the template and fill in the blanks:

```powershell
cp .env.example .env
```

Edit `.env` and set **at minimum** these two values from the organizer info pack:

```
APIM_SUBSCRIPTION_KEY=<your team's key>
DB_CONNECTION_STRING=postgresql://<user>:<pass>@<host>/<db>
```

The other values (subscription id, resource group, ACR name, APIM gateway URL, app names) are pre-filled with the shared platform defaults — leave them as-is unless your organizer tells you otherwise. `.env` is gitignored.

### Step 3 — Deploy

From the repo root:

```powershell
pwsh ./deploy-app.ps1
```

The script will:

1. Build `agency26/dashboard:latest` and `agency26/dossier:latest` remotely on the shared ACR (no local Docker needed).
2. Create or update the `ca-<prefix>-dashboard` and `ca-<prefix>-dossier` Container Apps in the shared environment.
3. Inject `APIM_GATEWAY_URL`, `APIM_SUBSCRIPTION_KEY`, and `DB_CONNECTION_STRING` as Container App secrets.
4. Print the public HTTPS URLs of both apps.

Typical run time: **2–4 minutes** for the first deploy, **1–2 minutes** for redeploys.

#### Useful flags

| Flag | What it does |
|---|---|
| `-SkipBuild` | Reuse the existing image in ACR; only update the Container Apps. Fast redeploy after config changes. |
| `-SkipDeploy` | Build images only; skip the Container App update. Useful for warming the registry. |
| `-Tag <value>` | Push and deploy a custom image tag (default: short git SHA, falling back to a timestamp). |

### Step 4 — Verify your deployment

The script prints both URLs at the end. To smoke-test the Foundry LLM connection (no DB writes — completely safe):

1. Open the **Dashboard** URL in a browser.
2. Find the **"LLM provider smoke test (no DB writes)"** panel near the top.
3. Pick `foundry`, click **Test**. You should see a JSON response like:
   ```json
   { "ok": true, "provider": "foundry", "model": "gpt-5-mini", "text": "PONG", ... }
   ```

That confirms your APIM key is valid and routes through to the shared Foundry endpoint.

> **Important — do NOT click `Run` on the `08c · LLM review` button** unless the organizer has pointed your `DB_CONNECTION_STRING` at a writable database. The default Render connection string is a **read-only replica** and the pipeline phases will error out trying to write back. Use the LLM smoke test panel instead — it never writes to the database.

### Redeploying after code changes

```powershell
pwsh ./deploy-app.ps1            # full rebuild + redeploy
pwsh ./deploy-app.ps1 -SkipBuild # config-only redeploy (faster)
```

### Tearing down your team's apps

If you want to remove your apps without touching the shared infrastructure:

```powershell
az containerapp delete -n ca-<prefix>-dashboard -g <PLATFORM_RG> --yes
az containerapp delete -n ca-<prefix>-dossier   -g <PLATFORM_RG> --yes
```

The shared ACR images, KV, APIM, and Foundry endpoint are organizer-managed and stay in place.

### Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `az: command not found` | Azure CLI not installed | Install from the link in Prerequisites. |
| `pwsh: command not found` | Running in Windows PowerShell 5.x or no PowerShell | Install PowerShell 7+. |
| `Forbidden` / `AuthorizationFailed` on ACR or Container Apps | Your Azure account isn't on the shared resource group | Ask the organizer to grant you Contributor on `PLATFORM_RG`. |
| `cannot execute UPDATE in a read-only transaction` in app logs | App is hitting the Render read-replica during a write | Expected with the read-replica DB; only the LLM smoke-test path is safe. |
| `Foundry/APIM error 401` / `403` from the LLM smoke test | Wrong or missing `APIM_SUBSCRIPTION_KEY` | Re-check the value in `.env` and rerun `pwsh ./deploy-app.ps1 -SkipBuild`. |
| Container App stuck in `ProvisioningState: Failed` | A previous failed deploy left a bad revision | Delete the app (see Tearing down above) and rerun `pwsh ./deploy-app.ps1 -SkipBuild`. |

