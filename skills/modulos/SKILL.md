---
name: modulos
description: Catalog of reusable cross-cutting feature modules, each already built and battle-tested in a real project, to plug into a full-stack app (FastAPI api + Next.js dashboard + Next.js admin on GCP Cloud Run) — users and login (password or Google, admin can go Google-only), floating feedback button (report a problem / suggest an idea, with screenshot), complaints chatbot on a cheap Gemini model, transactional email, superadmin panel base, MercadoPago subscriptions. Use whenever the user wants to add one of these features to a new or existing app, says "módulo", "agregá el módulo de…", "sugerencias", "reclamos", "login con Google", "panel de admin", "suscripciones", or when fullstack-app reaches its module-selection step. Also use to add a NEW module to the catalog from code that already exists in a project.
argument-hint: "[módulo] (sugerencias | reclamos | login | mail | superadmin | suscripciones)"
---

# modulos — catalog of reusable feature modules

A **module** is a cross-cutting feature (not business logic) that was already built and
debugged in a real project and is worth re-plugging into the next app instead of redesigning it.
Each module is one recipe file under `references/`. **Read only the recipe(s) being applied** —
they are long on purpose.

Requested module: $ARGUMENTS

This skill is the companion of `fullstack-app` (which calls it at its module-selection step) and
builds on the pieces scaffolded by `api-fastapi`, `frontend-dashboard-next`, `ui-design` and
`deploy-gcp-cloudrun`. It can also be applied to an existing app on its own.

## Catalog

| Module | Recipe | What it gives |
|---|---|---|
| `login` | [references/usuarios-login.md](references/usuarios-login.md) | Users + session. Password **or** Google (GIS ID token, no client secret), email-code signup, password reset, rotating refresh in httpOnly cookies, login throttle. Admin logs in with password or Google and can **switch the password off** (Google-only). |
| `sugerencias` | [references/sugerencias.md](references/sugerencias.md) | Floating button in the dashboard: "something's wrong" / "I have an idea", text + up to 5 photos with one-tap page screenshot. Admin inbox with unread counter, seen/resolved, internal note. |
| `reclamos` | [references/reclamos-bot.md](references/reclamos-bot.md) | Chat widget with a bot on a cheap Gemini model that takes a complaint, asks what is missing, and files it. Admin inbox with states + internal note. Optional: WhatsApp channel, anonymous chat, separate `agente/` service. |
| `mail` | [references/mail-transaccional.md](references/mail-transaccional.md) | `send_email` that never breaks the request, shared HTML shell, dev fallback to the log, marketing category with one-click unsubscribe. |
| `superadmin` | [references/superadmin.md](references/superadmin.md) | The admin app skeleton: superadmin guard, accounts list/detail, disable/enable, menu with unread counters. Where the inboxes of `sugerencias` and `reclamos` plug in. |
| `suscripciones` | [references/suscripciones-mercadopago.md](references/suscripciones-mercadopago.md) | Plans, free trial, MercadoPago subscription, signed webhook through the `webhooks` service, upgrade/downgrade, stop paying / come back, reconciliation. |

### Dependencies between modules

```
login ──────────────┬─► sugerencias ─┐
  └─► mail          ├─► reclamos ────┼─► superadmin (their admin inboxes live there)
                    └─► suscripciones ┘        (suscripciones also needs mail + webhooks service)
```

`login` needs `mail` (signup code, password reset). Everything with an admin side needs
`superadmin`. If the user picks a module whose dependency is missing, say so and add the
dependency first — do not stub it.

### Candidates (no recipe yet)

Do **not** improvise these from memory. If the user wants one, write its recipe first (see
"Adding a module to the catalog") from an existing project of theirs that already has it.

| Candidate |
|---|
| Rate limit by bucket in the DB (generic; the login-specific version is already inside the `login` recipe) |
| Close-the-loop on feedback (mail "ya está" to the reporter, dry-run) |
| Ops events (persistent errors with TTL + encrypted detail, shown in admin) |
| Encryption at rest for per-tenant secrets (Fernet, versioned prefix, fail-closed) |
| Deferred work on Cloud Run (Cloud Tasks + Scheduler sweep) |
| OTP verification of a notification destination (phone/email) |
| Google Calendar OAuth (encrypted refresh token, `needsReconnect`) |
| Private file storage with swappable backend (GCS/local; the minimum is inside `sugerencias`) |
| Product telemetry + signup attribution |
| Account deletion with grace period |
| Export to PDF with React-PDF |
| Install-as-app prompt (PWA) |

## How to apply a module

1. **Read the recipe** for the requested module, whole. Then read the recipes of its
   dependencies that are not in the app yet.
2. **Look at the target app first.** The recipe describes the reference implementation; the
   target may name things differently, use another DB, or already have half of it. Map the
   recipe's pieces onto what exists (auth dependency, tenant dependency, error envelope, UI kit,
   storage) before writing anything. If the target already has an equivalent piece, **reuse it**
   — do not add a second one.
3. **Ask the module's "Choices" section.** Each recipe lists the decisions that are the
   user's (not yours). Ask them together, once, with the recipe's default marked. Never pick
   silently.
4. **Re-verify versions online** for every dependency the recipe adds (same rule as
   `fullstack-app` Step 0). The versions written in a recipe are the ones the reference used on
   the date stated there, not a pin.
5. **Build it in this order:** data model + indexes → `functions/` → `routers/` → tests →
   dashboard (action + component) → admin (data + screens) → e2e → docs.
6. **Keep the invariants** of `fullstack-app`: browser never calls the api (Server Actions /
   route handlers only), API key on every router, tenant and user come from the JWT and never
   from the request body, money/limits validated in the api even if the front also checks.
7. **Infra goes where the project's deploy model keeps it**, never in the console. Model A
   (Terraform): a module that adds env vars, secrets, a bucket, a cron, a service (e.g.
   `agente/`) or a permission declares it in `infra/` — secrets as containers in
   `infra/secrets.tf`, values with `terraform -chdir=infra/secrets apply`; show the `plan`, the
   user runs the `apply`. Model B (gcloud): the fixed pieces in the bootstrap script, env and
   mounted secrets in the service's workflow. See `deploy-gcp-cloudrun` → "Choose the deploy model".
8. **Docs are part of the module.** Add the feature to the root `CLAUDE.md`, to each touched
   service's `CLAUDE.md` + `README.md`, and record the choices made in step 3 in the project's
   decisions log (`docs/DECISIONES.md` if it exists).
9. **Verify for real**: run the api tests for the module, typecheck + build the fronts, and
   walk the flow in a browser at 390 px. Report what was verified and what was not.

### Conventions used in every recipe

- **Identifiers are in English** (`reports`, `account`, `user`). Map them onto the target
  app's naming. Each recipe is self-contained: everything needed to rebuild the module is in it.
- **UI copy is given in rioplatense Spanish** as used in the reference. Adapt it to the
  product's voice; keep it short and in the user's words, never technical.
- **Data model is written for MongoDB** (the reference DB). For Firestore or Postgres keep the
  same fields, states and indexes, and re-express the atomic operations the recipe marks as
  **atomic** (they matter: they are what prevents double counts and races).
- **"Tenant"** means the unit that owns data (`account`, `org`, `business`). In a single-user
  app the tenant is the user.
- **"Do not copy"** sections list shortcuts or stale bits found in the reference. They are
  there so the next app does not inherit them.

## Adding a module to the catalog

When an existing project of yours has a cross-cutting feature worth reusing:

1. Read the feature end to end in that project (code, tests, decisions log). Do not write the
   recipe from the feature's docs alone — docs drift (every reference project had stale
   comments contradicting the code).
2. Write `references/<slug>.md` with the same sections as the existing recipes: what it is ·
   depends on · choices · data model · api · dashboard · admin ·
   limits · decisions (with the **why**) · do not copy · tests · docs · checklist.
3. Strip the business logic; keep the mechanism. If something only makes sense for that
   product, leave it out or mark it as a variant.
4. Add the row to the Catalog table above and remove it from Candidates. Update
   `fullstack-app` if the module changes what it asks.

## Checklist (any module)

- [ ] Recipe and its dependencies read whole; target app mapped before writing.
- [ ] Module choices asked and recorded in the decisions log.
- [ ] Versions of added dependencies verified online.
- [ ] Tenant/user taken from the JWT; every limit enforced in the api.
- [ ] Browser never calls the api directly.
- [ ] Api tests for the module pass; fronts typecheck and build.
- [ ] Walked in a browser at 390 px, no horizontal overflow.
- [ ] Root and per-service `CLAUDE.md` / `README.md` updated.
