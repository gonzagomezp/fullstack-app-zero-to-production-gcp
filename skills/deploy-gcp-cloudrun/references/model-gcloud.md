# Deploy model B — gcloud in the workflows (classic)

The model this skill used before Terraform, **restored verbatim** below (sections "Cloud Run deploy"
through "Healthcheck / probes" of the original SKILL.md). Choose it with the user; the default of this
skill is model A (Terraform, `terraform.md`). When to prefer each:

| | A — Terraform (`terraform.md`) | B — gcloud in the workflows (this file) |
|---|---|---|
| Where the service config lives | `infra/services.tf` | The `gcloud run deploy` flags of each workflow |
| A push | Deploys, swapping **only the image** | Deploys the image **and re-applies the complete config** |
| Changing an env / secret / memory | Edit `infra/` + `terraform apply` by hand | Edit the workflow + push |
| IAM, secrets, queue, crons, domains | Terraform | A one-time bootstrap script, run by hand |
| CI identity | Write images + `run.developer` on the app's services + actAs | `run.admin` (project) + actAs + `secretmanager.viewer` |
| Drift detection | `terraform plan` | None: the next deploy overwrites the config; one-time pieces drift silently |
| Rollback | `terraform apply -var 'images={svc="<sha>"}'` | A workflow that moves traffic to an old revision |
| Setup cost | Higher (state bucket, provider, adoption) | Lower; fine for a small app or a prototype |

---

## Cloud Run deploy

Build and push to Artifact Registry, then deploy. Replace `REGION`, `PROJECT`,
and service names.

```bash
# Build & push (Cloud Build, or local buildx)
gcloud builds submit --tag REGION-docker.pkg.dev/PROJECT/repo/backend ./backend

# Backend — INTERNAL only, dedicated service account, no unauth access
gcloud run deploy backend \
  --image REGION-docker.pkg.dev/PROJECT/repo/backend \
  --region REGION \
  --ingress internal \
  --no-allow-unauthenticated \
  --service-account backend-sa@PROJECT.iam.gserviceaccount.com \
  --set-secrets DATABASE_URL=db-url:latest \
  --min-instances 0 --max-instances 10 --concurrency 80 \
  --port 8080

# Frontend — PUBLIC
gcloud run deploy frontend \
  --image REGION-docker.pkg.dev/PROJECT/repo/frontend \
  --region REGION \
  --ingress all \
  --allow-unauthenticated \
  --service-account frontend-sa@PROJECT.iam.gserviceaccount.com \
  --min-instances 1 --max-instances 20 --concurrency 80 \
  --port 8080
```

### Ingress at a glance

| Service    | Ingress   | Unauth        | Public? |
|------------|-----------|---------------|---------|
| backend    | internal  | no            | no      |
| frontend   | all       | yes           | yes     |
| webhooks   | all       | yes (verify sig) | yes  |

---

## Service-to-service auth (frontend/webhooks -> backend)

The backend is `--no-allow-unauthenticated`. The caller's service account must
have the **Cloud Run Invoker** role on the backend, and must send a Google-signed
**ID token** whose audience is the backend URL.

```bash
gcloud run services add-iam-policy-binding backend \
  --region REGION \
  --member serviceAccount:frontend-sa@PROJECT.iam.gserviceaccount.com \
  --role roles/run.invoker
```

The caller fetches an ID token from the metadata server (audience = backend URL)
and sends it as `Authorization: Bearer <id_token>`. See
`references/cloudrun-best-practices.md` for code patterns (Python and Node).

---

## Secrets & env

- Non-sensitive config: `--set-env-vars KEY=VALUE`.
- Secrets: store in **Secret Manager**, mount with `--set-secrets`. The service
  account needs `roles/secretmanager.secretAccessor`.
- Never bake secrets into the image. Never log them.

---

## Healthcheck / probes

Cloud Run supports **startup** and **liveness** probes. Add an HTTP startup probe
on a lightweight endpoint (e.g. `/healthz`) so Cloud Run does not route traffic
until the container is ready, and a liveness probe to restart hung containers.
Distroless has no shell, so use **HTTP** probes (not `exec`). Details and a
`service.yaml` snippet in `references/cloudrun-best-practices.md`.

---

## The real implementation (in production)

This model ran in production on a real project until it moved to Terraform. The battle-tested version
of model B is a handful of files:

```text
scripts/gcp-bootstrap.sh              # one-time infra, idempotent
scripts/secrets.sh                    # secret values (generates random ones, asks the rest)
scripts/artifact-cleanup-policy.json  # keep the last 15 images, drop untagged > 24 h
.github/workflows/deploy-api.yml      # tests + build + push + deploy with FULL config
.github/workflows/deploy-dashboard.yml
.github/workflows/rollback.yml        # move 100 % traffic to a revision, no rebuild
```

How it was split:

- **`gcp-bootstrap.sh`, by hand, once (idempotent):** project + billing, APIs, budget alert, Artifact
  Registry (immutable tags + cleanup policy), one service account per service, Workload Identity
  Federation bound to the repo, IAM, **empty** secret containers and who reads each, private bucket,
  Private Google Access on the default subnet, the services as **closed placeholders** (`hello` image,
  internal ingress — they must exist to grant invoker between them and to know the api URL), the invoker
  bindings, the Cloud Tasks queue and the Cloud Scheduler jobs. It prints the `gh variable set` lines
  and the domain-mapping commands at the end.
- **`secrets.sh`, by hand:** generates the random secrets that have no value yet (never overwrites one
  unless named explicitly), asks the external ones without echo, and can copy a secret from another
  project secret-to-secret.
- **`deploy-<service>.yml`, on every push:** tests → build → push `<service>:<short sha>` →
  `gcloud run deploy` with the **complete** config (ingress, SA, `--network/--subnet/--vpc-egress`,
  CPU/memory/timeout, `--min-instances=0 --max-instances=5 --cpu-throttling`, `--env-vars-file`,
  `--set-secrets`). The YAML is the source of truth: changing an env = commit.
  - URLs of sibling services are resolved live with `gcloud run services describe … --format='value(status.url)'`.
  - **Optional secrets are mounted only if they have an enabled version** (the deployer has
    `secretmanager.viewer`, metadata only): a placeholder value would make the service believe the
    feature is configured.
  - If the image of that commit already exists (GitHub delivered the push twice), skip the build: tags
    are immutable.
- **CI identity:** `run.admin` on the project, `artifactregistry.writer` on the repo, actAs on the six
  runtime accounts, `secretmanager.viewer`. No IAM admin, cannot read secret values.
- **Public services:** `--no-invoker-iam-check` instead of `--allow-unauthenticated` once the project
  was under an organization with domain-restricted sharing (`allUsers` refused).

Lessons that apply to both models are in `terraform.md` → "Gotchas met for real" (VPC egress and
Private Google Access, `X-Serverless-Authorization`, the api keeping its default URL for
Scheduler/Tasks, cold-start retries only when the connection never opened).
