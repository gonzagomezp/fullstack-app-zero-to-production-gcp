---
name: fullstack-app
description: Orchestrate a complete, deploy-ready full-stack app in a single monorepo by coordinating the ui-design, frontend-static-vite, frontend-dashboard-next, api-fastapi, modulos and deploy-gcp-cloudrun skills. Use whenever the user wants to build a whole app/product/MVP end to end — frontend + API + database + auth + deploy — or says "build me an app", "full-stack", "from scratch", or names several layers at once. Asks the few per-build choices (which frontend, auth type, database, webhooks, which reusable modules — login, feedback button, complaints bot, mail, superadmin panel, subscriptions), then scaffolds each service self-contained in its own folder, and deploys to GCP Cloud Run with one of two models: Terraform (infra/, applied by hand; CI swaps only the image) or classic gcloud workflows. Triggers whenever a multi-layer application is requested, even if not named explicitly.
---

# fullstack-app — orchestrator

Builds a deploy-ready full-stack app as **one GitHub repo**, with **each service self-contained in its own folder** (its own Dockerfile, deploy config, and docs) — like independent projects inside a monorepo. This skill **decides which subskills to invoke and in what order**; it does not reimplement them.

## Subskills it coordinates

| Skill | Role |
|---|---|
| `ui-design` | Shared visual design system (tokens, components) — consumed by both frontends. Source of truth: `Manual_UI.html`. |
| `frontend-static-vite` | Static frontend (Vite + React + TS), with server-side BFF. |
| `frontend-dashboard-next` | Dynamic dashboard frontend (Next.js App Router + TS), Server Actions. |
| `api-fastapi` | Modular FastAPI backend (`routers/ functions/ models/ db?/`). |
| `modulos` | Catalog of reusable cross-cutting modules already built in real projects (login, sugerencias, reclamos, mail, superadmin, suscripciones). One recipe per module; read only the ones selected. |
| `deploy-gcp-cloudrun` | Multistage Dockerfiles + Cloud Run config per service. |

## Step 0 — ALWAYS re-verify versions first

Before fixing any dependency version, **search the internet** for the most recent, least-vulnerable versions and current best practices. Do NOT trust memory. Record chosen version + reason in each service's docs. Re-verify on **every** build:

- Frontend: Next.js, React, Vite, Tailwind, Motion (package `motion`, import `motion/react`).
- Backend: FastAPI, Pydantic, uvicorn, PyJWT, pwdlib, DB clients, Python 3.12.x patch.
- Deploy: distroless base tags, Cloud Run guidance, **Terraform** and the **`hashicorp/google` provider** (registry API), GitHub Actions majors.

Verified baseline (June 2026 — re-confirm, may have drifted): Next.js 16.2.x · React 19.2.7 · Vite 8.0.16 · Tailwind v4.3 · Motion 12.40.0 · FastAPI 0.136.1 · Python 3.12.13. Infra: Terraform 1.16.2 · `hashicorp/google` 8.5.0 · `hashicorp/random` 3.9.1. DB drivers: SQLAlchemy 2.1.4 · psycopg 3.3.6 · pymongo 4.18.3 (async API; `motor` is end of life) · cloud-sql-python-connector 1.22.0.

## Step 1 — Ask the per-invocation parameters

These are **chosen each time**, never hardcoded. If the user didn't specify, ask:

1. **Which frontend?** static (Vite) · dashboard (Next.js) · both.
2. **Auth type?** own JWT access+refresh **(default — built from the `login` module)** · Firebase.
3. **Database?** Firestore **(default, GCP)** · Postgres by connection URL (`DB_URI`: Cloud SQL
   by IP, Neon, Supabase, self-hosted) · Cloud SQL Postgres via Google's connector (instance + user +
   password) · MongoDB by connection URL (`DB_URI`; **MongoDB Atlas in production**) · none (omit
   `db/`). Chosen here, at build time: only the selected adapter is generated (`api-fastapi` →
   `references/db-adapters.md`).
4. **Webhooks?** yes (adds a separate `webhooks` service) · no.
5. **Modules?** any of the `modulos` catalog, none by default beyond what auth implies:
   - `login` — users, password or Google, admin can go Google-only (**implied by own-JWT auth**).
   - `mail` — transactional email (**implied by `login`**).
   - `superadmin` — the admin app (`web-admin/`) and `/admin/*` (**implied by any module with an inbox**).
   - `sugerencias` — floating feedback button + admin inbox.
   - `reclamos` — complaints chatbot on a cheap Gemini model + admin inbox.
   - `suscripciones` — plans + MercadoPago subscriptions (**implies `webhooks`**).

   Show the list with what each one drags in. Each module has its own "Choices": ask those
   when that module is applied (Step 2), not here.
6. **Deploy model?** (`deploy-gcp-cloudrun` → "Choose the deploy model")
   - **A — Terraform (default):** all of GCP in `infra/`, applied by hand; a push deploys only the
     new image.
   - **B — gcloud in the workflows (classic):** a one-time bootstrap script; each workflow re-applies
     the service's full config on every push. Simpler to set up; no drift detection.

Confirm before scaffolding. Everything else follows the global invariants below.

## Step 2 — Decide order and invoke subskills

1. `ui-design` first — establish the shared design system both frontends consume.
2. `api-fastapi` — scaffold backend with chosen auth + DB (omit `db/` if none).
3. Frontend(s): `frontend-static-vite` and/or `frontend-dashboard-next`, wired to the API **server-side only** and consuming `ui-design`.
4. `modulos` — apply each selected module, **dependencies first**: `mail` → `login` →
   `superadmin` → `sugerencias` / `reclamos` / `suscripciones`. For each one: read its recipe
   whole, ask its "Choices" together, build api → tests → dashboard → admin → docs. The
   recipes describe a reference implementation; map them onto what Steps 2–3 just scaffolded
   instead of duplicating pieces (auth dependency, tenant dependency, error envelope, ui kit).
5. `deploy-gcp-cloudrun` last:
   - a multistage Dockerfile per service (both models);
   - the DB: with a URL option (Postgres or MongoDB) the URL is the `db-uri` secret → `DB_URI` in the
     `api` (in `infra/secrets/`, `must_start_with` = `postgres` or `mongodb` to match); with the Cloud
     SQL connector, the instance name goes as env and the password as a secret instead of `db-uri`. With
     MongoDB Atlas, ask how to open its IP Access List (the `api` has no fixed outbound IP:
     `0.0.0.0/0` or Cloud NAT with a static IP);
   - **Model A:** `infra/` from its Terraform templates — one entry per service in the services map
     (backend internal, fronts public, `webhooks` if requested, `web-admin` public with its own login),
     plus the secrets, crons and domains the modules added; one workflow per service from its template
     (tests → build → push → **swap only the image**); `scripts/gcp-bootstrap.sh` (project + state
     bucket) and `infra/README.md`. Follow "New project from zero" in `references/terraform.md`.
     **Never run `terraform apply` against a real project without the user's explicit OK**: show the
     `plan` first.
   - **Model B:** `scripts/gcp-bootstrap.sh` with every fixed piece (SAs, WIF, IAM, secret containers,
     bucket, queue, crons, placeholder services), a secrets script, and one workflow per service that
     deploys with the **complete** config, plus a rollback workflow (`references/model-gcloud.md`, which
     describes the battle-tested version). Document it in `docs/INFRA.md`.

## Step 3 — Monorepo layout

```
<project>/
├─ README.md                # root: what each service is, how to run/deploy
├─ CLAUDE.md                # root architecture + "update docs on change" rule
├─ .gitignore
├─ web-static/   (if Vite)      → self-contained: src/, server/ (BFF), Dockerfile, README.md, CLAUDE.md
├─ web-dashboard/ (if Next.js)  → self-contained: app/, lib/, Dockerfile, README.md, CLAUDE.md
├─ web-admin/ (if `superadmin`) → self-contained Next.js app for the superadmin: app/, lib/, Dockerfile, README.md, CLAUDE.md
├─ api/                         → routers/ functions/ models/ db?/ main.py, Dockerfile,
│                                 README.md, CLAUDE.md, requirements.md
├─ webhooks/   (if requested)   → self-contained proxy service, Dockerfile, README.md, CLAUDE.md
├─ infra/ (model A)             → Terraform: ALL the GCP infrastructure + each service's config,
│  │                              terraform.tfvars (not secret), .terraform.lock.hcl, README.md
│  └─ secrets/                  → separate root module that loads secret VALUES
├─ scripts/gcp-bootstrap.sh     → A: project, billing, Terraform state bucket · B: all the fixed infra (once)
├─ scripts/secrets.sh (model B) → secret values
└─ .github/workflows/deploy-<service>.yml → A: tests, build, push, swap the image · B: + full config on every deploy
```

Each service folder is independent: its own Dockerfile and dependency manifest, as if it were its own project. Its runtime config (env, secrets, resources, network) lives in `infra/` (model A) or in its workflow (model B), not in the folder.

## Global invariants (NEVER change)

- **Live versioning:** search the internet each build for newest/safest versions; record choice + reason in docs.
- **Frontend language:** TypeScript always (Vite and Next.js).
- **Styles:** Tailwind in both frontends.
- **Animations:** Motion (`motion/react`) in both. Entrance **and exit** (mount **and** unmount) via `AnimatePresence` + `exit`, layout animations (`layout`/`layoutId`), and motion on interaction (hover, scroll/viewport, state changes, navigation between views/tabs/routes). Next.js App Router: client `AnimatePresence` + `template.tsx`.
- **Responsive (mandatory):** mobile-first, Tailwind breakpoints, no overflow/clipping. Navigation uses a **hamburger** that on **mobile** opens a drawer/off-canvas, and on **desktop** collapses the nav to give the page more breathing room. Open/close animated with Motion (enter + exit).
- **Front → back calls:** originate **server-side**, never directly from the browser. Next.js → **Server Actions**; Vite → equivalent **server/BFF** layer. The API key/secrets never reach the browser.
- **Backend:** Python 3.12.x (latest secure patch). Env via **uv** (preferred) or **pyenv + venv**; exact flow documented in `CLAUDE.md` and `requirements.md`.
- **Backend structure:** `routers/` (routes + their schemas only), `functions/` (modular logic), `models/`, `db/` (only if a DB exists). `main.py` imports and registers routers. **API key on every endpoint.** **Auth on every endpoint except health/status** (health still carries API key — but consider exempting health from the API key if used as a Cloud Run probe; document the choice).
- **Deploy:** GCP Cloud Run. **One service = one multistage Dockerfile** (non-root, minimal/distroless or slim base, no secrets in layers, `.dockerignore`, healthcheck).
- **Infrastructure in one place, never the console.** Model A (default): everything in GCP is described in `infra/` (Terraform) and applied **by hand**. CI builds, pushes and **swaps only the image**; its identity can write images and update those services, nothing else. Terraform takes the latest tagged image, so `plan` after a push says "No changes". Secret values never touch Terraform state, plans or workflows (`infra/secrets/`). Model B: fixed pieces in the bootstrap script, each service's full config in its workflow (commit = deploy); CI never gets IAM admin nor secret values.
- **Network:** backend **NOT exposed** (internal ingress + IAM); **the fronts are the only public services** (`invoker_iam_disabled`, never `allUsers`), reaching the backend through Direct VPC egress. If webhooks are needed, a separate `webhooks` service proxies to internal services.
- **Repo:** single GitHub repo; each service self-contained in its own folder.
- **Docs (mandatory):** every service has `CLAUDE.md` **and** `README.md`; backend also `requirements.md`. Both docs must state explicitly: *"Ante cualquier cambio de arquitectura o cambio relevante, actualizar esta documentación"* (preferably in `CLAUDE.md`, but in both).

## Acceptance checklist

- [ ] Per-invocation params asked (frontend, auth, DB, webhooks, modules, deploy model).
- [ ] DB: only the chosen adapter exists; URL options read `DB_URI` (psycopg 3 for Postgres, PyMongo Async for MongoDB — never `motor`); Atlas access-list choice recorded.
- [ ] Selected modules applied from the `modulos` recipes, dependencies first; each module's choices asked and recorded.
- [ ] `ui-design` applied; both frontends consume it; based on `Manual_UI.html`.
- [ ] Backend: `routers/ functions/ models/ db?/`, `main.py` registers routers, API key everywhere, auth everywhere except health.
- [ ] Frontends in TS + Tailwind + Motion; backend calls server-side only.
- [ ] Responsive (mobile + desktop) with hamburger that also collapses on desktop.
- [ ] Motion entrance **and** exit (AnimatePresence), not just on mount.
- [ ] Each service: secure multistage Dockerfile; backend internal, fronts public, webhooks separate when applicable.
- [ ] Deploy model asked (A Terraform · B gcloud) and recorded in the decisions log.
- [ ] Model A: `infra/` validates (`terraform fmt -check` + `validate`), every service in the services map, secrets as containers only; `plan` shown before any `apply`; one workflow per service that swaps only the image; CI identity limited to images + those services; `infra/README.md` says how to deploy, roll back and load a secret.
- [ ] Model B: bootstrap idempotent; each workflow carries the service's complete config; optional secrets mounted only if they have a value; rollback workflow; `docs/INFRA.md` documents it.
- [ ] Single monorepo, services self-contained per folder.
- [ ] Versions searched online + documented; "update docs on change" note present in every service.
