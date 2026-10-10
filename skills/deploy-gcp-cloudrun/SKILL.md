---
name: deploy-gcp-cloudrun
description: Containerize and deploy each service to GCP Cloud Run with secure multistage Dockerfiles (non-root, distroless/slim, no baked secrets), with two deploy models to choose from — A (default) ALL infrastructure in Terraform (infra/) applied by hand while CI only builds, pushes and swaps the image; B (classic) a one-time gcloud bootstrap script plus workflows that re-apply each service's complete config on every deploy. Use whenever the user wants to deploy, dockerize, ship a service to Cloud Run / GCP, set up or change infrastructure, Terraform, CI/CD, secrets, domains, or roll back. Keeps the backend internal, exposes only the fronts, and adds a separate `webhooks` service that proxies to internal services when webhooks are needed. Triggers on any deploy/Docker/Cloud Run/Terraform/infra request.
---

# Deploy to GCP Cloud Run

Containerize services and run them on **Google Cloud Run**:

- **Dockerfiles**: one per service, multistage, non-root, no secrets in layers. Same in both models.
- **Two deploy models — ask which one** (see "Choose the deploy model" below):
  - **A — Terraform (default).** `infra/` owns the architecture: every Cloud Run service with its
    complete config, service accounts, IAM, secret containers, bucket, queue, crons, domains, budget.
    **Applied by hand.** CI builds, pushes `<service>:<short sha>` and **swaps only the image**.
  - **B — gcloud in the workflows (classic).** A one-time bootstrap script creates the fixed pieces;
    each workflow deploys with `gcloud run deploy` and **re-applies the service's complete config**
    on every push. Detail: `references/model-gcloud.md`.
- The backend is never public; only the fronts are. A separate `webhooks` service handles external
  callbacks and proxies them to internal services.

> **Re-verify before each build.** Image tags, distroless variants, Terraform and the `google` provider,
> and Cloud Run features move fast. Versions below were verified on the date stated next to them.

Both ran for real in production: model B first, then model A (adoption of the
live project with Terraform, first deploy by Terraform, then deploy-on-push swapping only the image,
and `plan` saying "No changes" afterwards). Detail and every gotcha: **`references/terraform.md`**
(A) and **`references/model-gcloud.md`** (B).

---

## Core rules

1. **ONE service = ONE Dockerfile**, self-contained in its folder with its `.dockerignore`. A service
   builds from its own directory.
2. **Multistage builds, always.** Builder stage installs/compiles; the final stage gets only runtime
   artifacts.
3. **The architecture lives in ONE place, never in the console.** Model A: `infra/` (Terraform) — a
   change of env, mounted secret, memory, scaling, network, permission, cron or domain = edit `infra/`
   + `terraform apply`. Model B: the service config in its workflow (commit = deploy), the fixed pieces
   in the bootstrap script. The console is for reading.
4. **CI identity, least privilege for the chosen model.** A: CI only swaps the image
   (`gcloud run services update <svc> --image …`); three grants declared in Terraform — write images,
   `run.developer` **only on the app's services**, act as their runtime accounts. B: `run.admin`,
   write images, act as the runtime accounts, `secretmanager.viewer` (metadata only) — never IAM admin
   nor secret values.
5. **Backend internal**: ingress internal-only + IAM check. Reachable only from the fronts (Direct VPC
   egress) and from Scheduler/Tasks, with an ID token.
6. **Only the fronts (and `webhooks`) are public.**
7. **No secrets in image layers, Terraform state, plans or workflows.** Secret Manager holds the
   values; Terraform or the bootstrap hold only the containers and who reads them.
8. **Every service has `CLAUDE.md` + `README.md`**, and the infra has its doc (model A:
   `infra/README.md`; model B: `docs/INFRA.md`) saying how to deploy, roll back and load a secret, with
   the rule: **update the docs whenever the architecture changes.**

---

## Multistage pattern

```
# ---- builder ----
FROM python:3.12.13-slim AS builder
# install build deps, create venv / install packages, build artifacts

# ---- final ----
FROM gcr.io/distroless/python3-debian12:nonroot
COPY --from=builder /app/.venv /app/.venv
COPY --from=builder /app /app
# runs as nonroot, no shell, no package manager
```

Concrete examples in `assets/`:
- `assets/Dockerfile.fastapi` — FastAPI backend (uvicorn).
- `assets/Dockerfile.next` — Next.js App Router (`output: 'standalone'`).
- `assets/Dockerfile.vite-bff` — Vite static + Node BFF (serves static, proxies `/api`).
- `assets/dockerignore.template` — copy to each service as `.dockerignore`.

## Distroless vs slim — which final base?

**Prefer Google distroless `:nonroot`** when no shell is needed at runtime:
`gcr.io/distroless/python3-debian12:nonroot`, `gcr.io/distroless/nodejs24-debian12:nonroot`,
`gcr.io/distroless/static-debian12:nonroot`. Use the Debian-suffixed tag.

**Use `slim` + explicit non-root USER** when you need a shell or when distroless pins a runtime that
breaks your wheels (in production, the distroless python pinned 3.11 and broke pydantic-core's cp312
wheels, so the api uses `python:3.12.x-slim` + a numeric user). Pin patch versions; never `:latest`.

## Security checklist (every image)

- [ ] Non-root USER. Minimal pinned base. Multistage.
- [ ] No secrets in any layer; `.dockerignore` excludes `.env`, keys, `.git`.
- [ ] Listens on `$PORT` (8080 on Cloud Run).
- [ ] Image scanned in CI (vuln scan + SBOM — CRA, see best practices §8).

Full rationale: `references/docker-security.md`.

---

## Choose the deploy model

Ask the user; do not pick silently. Default: **A**.

| | A — Terraform (default) | B — gcloud in the workflows |
|---|---|---|
| Service config lives in | `infra/services.tf` | each workflow's `gcloud run deploy` flags |
| A push | deploys, swapping **only the image** | deploys and **re-applies the full config** |
| Change an env / secret / memory | edit `infra/` + `terraform apply` by hand | edit the workflow + push |
| IAM, secrets, queue, crons, domains | Terraform | one-time bootstrap script, by hand |
| CI identity | images + `run.developer` on the app's services + actAs | `run.admin` on the project + actAs + `secretmanager.viewer` |
| Drift detection | `terraform plan` | none (one-time pieces drift silently) |
| Rollback | `terraform apply -var 'images={svc="<sha>"}'` | workflow that moves traffic to an old revision |
| Setup cost | higher (state bucket, provider, adoption) | lower: a small app or a prototype |

- **A**: follow the rest of this file and `references/terraform.md`.
- **B**: follow `references/model-gcloud.md` (the original text of this skill plus a real
  production bootstrap, secrets script and workflows).
- **Moving an existing project from B to A** is an adoption with `import`, not a rebuild:
  `references/terraform.md` → "Adopting a project that already exists".

---

## Model A — Terraform (`infra/`)

Start from the templates, don't write it from memory:

| Template | What it describes |
|---|---|
| `assets/terraform/versions.tf` | Terraform + provider versions, GCS state backend, the provider alias for billing |
| `assets/terraform/variables.tf` · `terraform.tfvars.example` | What is configurable (nothing secret) |
| `assets/terraform/base.tf` | APIs, Artifact Registry (immutable tags + cleanup), private bucket, Tasks queue, subnet check |
| `assets/terraform/identities.tf` | One SA per service, invoker SA, CI SA, WIF bound to the repo, runtime grants, who invokes the api |
| `assets/terraform/secrets.tf` | Secret containers + readers + "every mounted secret has a value" check |
| `assets/terraform/services.tf` | **The services map** (ingress, public, VPC, memory, timeout, env, secrets), latest-tagged-image resolution, the Cloud Run services, crons, domain mappings |
| `assets/terraform/budget.tf` · `outputs.tf` | Budget alert; outputs for GitHub variables and DNS |
| `assets/terraform/secrets/main.tf` | Separate root module that loads one secret **value** (asks which and the value; generates random ones) |
| `assets/workflow-deploy.yml` | The per-service workflow: tests → build → push → swap image |

The services map is the heart of it: one entry per service, with the per-service decisions explicit:

```hcl
api = {
  ingress   = "INGRESS_TRAFFIC_INTERNAL_ONLY"  # internal backend
  public    = false                             # IAM check on
  run_url   = true                              # keeps the run.app URL (Scheduler/Tasks need it)
  vpc       = false                             # goes straight to the DB and third parties
  calls_api = false
  memory    = "1Gi"
  timeout   = "300s"
  audiences = []
  env       = { ... }
  secrets   = { API_KEY = "api-key", ... }      # env var -> Secret Manager secret
}
```

Every service: `min_instance_count = 0`, `max_instance_count = 5` (bounds the bill), CPU only while
serving (`cpu_idle = true`), startup CPU boost, concurrency 80, `deletion_protection = true`.

### The image

Terraform deploys, per service, the **latest tagged** image in Artifact Registry — the one CI just
deployed, so `terraform plan` after a push says "No changes". Not "latest modified": the build leaves
untagged manifests with the same timestamp (see `references/terraform.md`). Roll back with
`terraform apply -var 'images={api="<sha>"}'`.

### Secrets

- Containers and readers: `infra/secrets.tf`. Values: `terraform -chdir=infra/secrets apply` (asks
  which and the value, not echoed; Enter generates random ones). Ephemeral variable + write-only
  attribute: the value is never in the plan or the state.
- A mounted secret without a value fails the `plan` with its name.
- Optional secrets are mounted only if listed in `optional_secrets`.
- Rotating: load it again; new instances pick it up (`latest` resolves when an instance starts).

### Deploying

```bash
export GOOGLE_OAUTH_ACCESS_TOKEN="$(gcloud auth print-access-token --account=<project owner>)"
terraform -chdir=infra plan     # what would change
terraform -chdir=infra apply    # architecture changes; by hand, never from CI
```

Code changes need none of this: pushing to `main` deploys the new image.

### Ingress and auth at a glance

| Service | Ingress | Invoker check | VPC egress | run.app URL |
|---|---|---|---|---|
| backend (api) | internal only | on (fronts, invoker SA) | none | **kept** (Scheduler/Tasks) |
| fronts | all | **off** (`invoker_iam_disabled`) | all-traffic, default subnet | disabled, unless something must reach it by run.app |
| webhooks | all | off (the signature is the auth) | all-traffic | disabled |
| private service with a public domain | all | on + custom audience = its domain | — | disabled |

Public services use `invoker_iam_disabled` instead of an `allUsers` grant: under an organization with
domain-restricted sharing `allUsers` is refused, and it is what Google recommends there.

---

## Service-to-service auth (fronts/webhooks -> backend)

The caller's service account has `roles/run.invoker` on the backend (Terraform:
`api_invoked_by`) and sends a Google-signed **ID token** whose audience is the backend URL. The fronts
send it in **`X-Serverless-Authorization`**, because `Authorization` carries the user's JWT; Cloud Run
validates it and strips the signature. Scheduler/Tasks send theirs in `Authorization` and the backend
re-validates it (audience = its own URL). Code: `references/cloudrun-best-practices.md` §2.

**Fronts reaching the internal backend need Direct VPC egress `ALL_TRAFFIC` + Private Google Access**
(without it: 404 from the Google Front End). Consequence: without Cloud NAT those fronts have **no
internet egress** — a public domain behind a CDN times out; reach other services by their `run.app`
URL. The first seconds of a new instance may have no egress yet: the fronts' fetch wrapper must retry
**only when the connection never opened**.

---

## The `webhooks` service (add only when needed)

External providers need a public endpoint, but the backend is internal. A small **public** `webhooks`
service:

1. Receives the webhook (public ingress, invoker check off).
2. **Verifies the provider signature** before anything else; empty secret = reject everything.
3. Mints an ID token and **forwards** the verified payload to the internal backend.
4. Answers the provider fast (200 once the signature is valid, even if the backend is down: a
   reconciliation job is the safety net).

No business logic there. Design + code sketch: `assets/webhooks-service.md`.

---

## Per-service docs requirement

Each service folder: `CLAUDE.md` + `README.md` (purpose, local dev, what it needs from `infra/`).
`infra/README.md`: how to deploy, roll back, load a secret, adopt or create from zero. Rule in all of
them: **"Update this file whenever the architecture changes."** An infra change that does not touch
the docs is incomplete.

---

## References

- `references/model-gcloud.md` — **model B**: the original gcloud commands of this skill (deploy,
  ingress, service-to-service, secrets, probes) and a real production bootstrap + workflows.
- `references/terraform.md` — **model A**: the model, why CI does not run Terraform, latest-tagged image, secrets
  module, **adopting an existing project with `import`**, gotchas (credentials, budget provider, state
  lock ID on GCS, org policy, VPC egress), new project from zero.
- `references/cloudrun-best-practices.md` — networking, ID-token auth code, instances/concurrency,
  probes, region, webhooks design, SBOM.
- `references/docker-security.md` — the secure-image checklist with rationale.
