---
name: api-fastapi
description: Scaffold a modular, decoupled FastAPI backend (routers/ functions/ models/ db?/) with main.py registering routers, an API key required on every endpoint, and JWT-or-Firebase auth on all endpoints except health. Use whenever the user needs a Python API, REST backend, or service layer behind a frontend — with optional Firestore, Postgres (by connection URL or Cloud SQL connector), or MongoDB (by connection URL, Atlas in production). Backend is NOT publicly exposed (frontend is). Triggers whenever an API/backend in Python is requested.
---

# api-fastapi

Scaffold a modular, **maximally decoupled** FastAPI backend. The backend sits
**behind** a frontend and is **not publicly exposed** — every endpoint requires
an API key; every endpoint except health/status also requires user auth.

## Invocation parameters (decide these first, ask the user if unclear)

- **auth**: `jwt` (default — own JWT auth, PyJWT + pwdlib argon2id) OR `firebase`
  (verify Firebase ID tokens with firebase-admin).
- **db**: `firestore` (default if a DB is needed) OR `postgres-url` (any
  Postgres through a connection URL in `DB_URI` — Cloud SQL by IP, Neon,
  Supabase, self-hosted) OR `cloud-sql-postgres` (Cloud SQL through Google's
  connector: instance + user + password) OR `mongodb` (connection URL in
  `DB_URI`; **MongoDB Atlas in production**) OR `none` (omit the `db/` folder
  entirely). Chosen at build time: generate only the selected adapter.

Confirm the two choices, then scaffold only the matching pieces. Do not generate
adapters or auth code you did not select.

## Version facts (verified June 2026 — RE-VERIFY on every build)

Re-run a web search / `pip index versions` before pinning. As of June 2026:

- `fastapi[standard]==0.136.1` (pulls uvicorn[standard] + uvloop, pydantic v2).
- `pydantic>=2.7`, `pydantic-settings`, `uvicorn[standard]`.
- **Python 3.12.13** — latest 3.12.x security patch. Use this exact version.
- Auth: `PyJWT` (HS256; access ~15 min, longer refresh, rotation on refresh).
  Password hashing: `pwdlib[argon2]` (argon2id) — NOT old passlib.
- Firebase option: `firebase-admin`.
- DB: Firestore `google-cloud-firestore`; Postgres by URL = SQLAlchemy async +
  `psycopg` 3 (takes the provider's URL as is, `?sslmode=require` included —
  asyncpg rejects `sslmode`); Cloud SQL Postgres = SQLAlchemy async + `asyncpg`
  + Cloud SQL Python Connector (the connector only supports asyncpg/pg8000);
  MongoDB = **PyMongo Async API** (`pymongo`, `AsyncMongoClient`). **Not
  `motor`**: deprecated since 2025-05-14, end of life 2026-05-14.
  Verified 2026-10-10 on PyPI: SQLAlchemy 2.1.4 · psycopg 3.3.6 · pymongo 4.18.3
  · cloud-sql-python-connector 1.22.0.

## Environment setup

Prefer **uv**. Document the exact flow in CLAUDE.md and requirements.md.

```bash
# uv (preferred)
uv python install 3.12.13
uv venv --python 3.12.13
source .venv/bin/activate
uv pip install "fastapi[standard]==0.136.1" pydantic-settings \
  PyJWT "pwdlib[argon2]"            # + db/auth extras as selected
uv pip freeze > requirements.txt
```

```bash
# pyenv + venv (alternative)
pyenv install 3.12.13
pyenv local 3.12.13
python -m venv .venv && source .venv/bin/activate
pip install "fastapi[standard]==0.136.1" pydantic-settings PyJWT "pwdlib[argon2]"
pip freeze > requirements.txt
```

Extras per selection:
- firebase: `firebase-admin`
- firestore: `google-cloud-firestore`
- postgres-url: `sqlalchemy[asyncio]` `psycopg[binary]`
- cloud-sql-postgres: `sqlalchemy[asyncio]` `asyncpg` `cloud-sql-python-connector[asyncpg]`
- mongodb: `pymongo`

Run dev: `uvicorn app.main:app --reload`.

## Folder structure

```
app/
  main.py            # imports + registers routers ONLY
  settings.py        # pydantic-settings config
  dependencies.py    # api_key + auth dependencies (shared)
  routers/           # routes + their request/response Pydantic SCHEMAS only
    health.py
    auth.py          # (jwt option) login / refresh / logout
    <resource>.py
  functions/         # the logic endpoints call — maximally modular, no FastAPI
    auth.py          # (jwt option) hashing, token mint/verify, rotation
    <resource>.py
  models/            # domain models as needed (user.py, ...)
  db/                # connection/init IF a DB exists — OMIT if db=none
    __init__.py
.env                 # secrets (gitignored)
requirements.txt
CLAUDE.md
README.md
requirements.md
```

**Strict separation of concerns:**
- `routers/` = HTTP surface. Path operations + the Pydantic request/response
  schemas for that route. No business logic.
- `functions/` = plain Python, framework-agnostic, unit-testable. Routers call
  these. Keep functions small and single-purpose (maximally modular).
- `models/` = domain/persistence models.
- `db/` = connection + repositories. Omit entirely when `db=none`.

## Security model

**API key on EVERY endpoint** via an `APIKeyHeader` dependency (`X-API-Key`)
compared to a secret in env. Apply it at the app/router level so nothing is
missed. See `references/api-key.md`.

**Auth on every endpoint EXCEPT health/status.** Put auth-exempt routes
(health) on a router without the auth dependency; put everything else on routers
that include `Depends(get_current_user)`. See the auth reference for the
selected option.

**Health probe tradeoff (document clearly):** if `/health` is a Cloud Run /
load-balancer probe, the probe usually cannot send `X-API-Key`. Either:
1. Keep API key on `/health` and configure the probe to send the header (best
   when the platform supports custom probe headers), OR
2. Exempt `/health` from the API key too — simplest for probes, but the endpoint
   becomes unauthenticated. Keep it to a bare `{"status":"ok"}` with no
   sensitive data, and consider a separate authed `/status` for richer info.

State the chosen approach in README.md.

## main.py wiring

`main.py` creates the app, sets the global API-key dependency, and registers
each router with `app.include_router(...)`. Auth lives as a router-level
dependency on the protected routers, not on the health router. See
`assets/skeleton.md` for the full example.

## Mandatory docs (create all three, every build)

- **CLAUDE.md** — for future agents: exact env flow (uv / pyenv), how to run,
  the strict routers/functions/models/db separation, security model, the
  selected auth + db options.
- **README.md** — human-facing: setup, run, endpoints, env vars, the chosen
  health-probe approach.
- **requirements.md** — pinned versions + Python version + the verification step
  ("re-verify versions on each build").

**Rule (put in CLAUDE.md and README.md): update these docs on every
architecture change** (new router, new function module, auth/db change).

## References (read for full code)

- `references/api-key.md` — API-key dependency, global application, probe exempt.
- `references/auth-jwt.md` — own JWT auth (PyJWT access+refresh + pwdlib argon2id).
  Minimal sketch; for real users use the `modulos` skill's `login` recipe
  (`modulos/references/usuarios-login.md`), which supersedes it.
- `references/auth-firebase.md` — Firebase ID-token verification.
- `references/db-adapters.md` — Firestore / Postgres by URL / Cloud SQL Postgres
  (connector) / MongoDB by URL adapters.
- `assets/skeleton.md` — folder tree + working main.py, settings.py, example router.
