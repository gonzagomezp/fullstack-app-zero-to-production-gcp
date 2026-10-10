# Infrastructure with Terraform (the deploy model of this stack)

Built and run for real in production (adoption of a live project, first deploy by
Terraform, then deploy-on-push swapping only the image). Templates: `../assets/terraform/` and
`../assets/workflow-deploy.yml`. Versions then: Terraform 1.16.2, `hashicorp/google` 8.5.0,
`hashicorp/random` 3.9.1 — **re-verify** (registry API:
`https://registry.terraform.io/v1/providers/hashicorp/google`).

## The model

| Piece | Owns | Runs |
|---|---|---|
| `infra/` (Terraform) | **All** of GCP: APIs, Artifact Registry, service accounts, WIF, IAM, secret *containers* and who reads them, bucket, queue, crons, **every Cloud Run service with its complete config** (ingress, SA, VPC, CPU/memory/timeout, scaling, env, which secret goes in which variable), domain mappings, budget alert | **By hand**: `terraform -chdir=infra apply` |
| `infra/secrets/` (Terraform, separate) | Secret **values**: asks which secret and its value, or generates random ones. Never in plan or state | By hand, once per secret / rotation |
| `.github/workflows/deploy-<svc>.yml` | Tests, build, push `<svc>:<short sha>`, and **swap only the image** (`gcloud run services update --image`) | CI, on every push to `main` |
| `scripts/gcp-bootstrap.sh` | The only things outside Terraform: project, billing link, the state bucket | Once per project |

- **Code change** → push → it is in production, image only.
- **Architecture change** (env, secret mounted, memory, cron, permission, new service) → edit
  `infra/` → `terraform apply` by hand.
- **Drift check** → `terraform plan`. After a push it says "No changes": Terraform takes the latest
  *tagged* image, which is the one CI just deployed.

### Why not CI running `terraform apply`

That identity would need to read and change everything Terraform manages (IAM, secrets, WIF, domains,
billing). A compromised workflow would own the project. With this model CI has three grants, all
declared in `identities.tf`: `artifactregistry.writer` on the repo, `run.developer` **only on the app's
services**, and `iam.serviceAccountUser` on their runtime accounts. No project-wide `run.admin`, no
Secret Manager, no IAM. IAM cannot restrict CI to "only the image"; if it ever touched the config,
`plan` shows it and `apply` reverts it.

## How "the latest image" is chosen (the trap)

`google_artifact_registry_docker_image` without tag or digest returns "the latest modified image".
**Do not use it**: next to every tagged image index, buildx leaves untagged manifests (the platform
image and the provenance attestation) with the **same** timestamp, and "latest modified" can pick one
of those. The template lists every image with `google_artifact_registry_docker_images`, keeps the
**tagged** ones per service, sorts `update_time|tag` and takes the last. Image reference is
`<registry>/<svc>:<tag>` (not the digest), so an adopted service shows no diff.

Rollback: `terraform apply -var 'images={api="0ed9d4b"}'`. It lasts until the next push, which deploys
the new image. To keep it pinned, write it in `terraform.tfvars`.

## Secrets: why a separate module

Terraform **cannot ask "only if missing"**: it prompts for every root variable without a value, on
every run. So:

- `infra/` manages containers + accessors and **asks for nothing**. A `data
  "google_secret_manager_secret_version"` with `fetch_secret_data = false` per mounted secret makes the
  `plan` fail naming a secret that has no value (metadata only, no value read).
- `infra/secrets/` takes `secret` and `value` (`ephemeral = true`, `sensitive = true`) and writes a
  version with the **write-only** `secret_data_wo`; `secret_data_wo_version` = the plan timestamp, so
  every apply writes a new version; `deletion_policy = "ABANDON"` keeps old versions. Enter on an empty
  value generates a random one (only for the `generated` list; Fernet keys supported).
- Optional secrets are mounted only if listed in `optional_secrets`. Deciding by "does it have a value
  in GCP" does not work in Terraform: a later apply would flip it back.
- Env secrets use `latest`: Cloud Run resolves them **when an instance starts** (verified in the Cloud
  Run docs), so a new value reaches new instances by itself with `min-instances 0`.

## Adopting a project that already exists

Never recreate a live service (it gets a new URL) or a secret (its value is lost). Adopt it:

1. Write the config to match reality. Read it first: `gcloud run services describe <svc> --format=json`
   for every service (env, secrets, annotations, timeout, concurrency, probes), IAM of secrets / SAs /
   bucket / repo, scheduler jobs, queue, domain mappings, budget.
2. Put `import` blocks in a throwaway `adoption.tf` (`for_each` works). IDs that took some finding:
   - project service `"<project>/<api>"`; secret `projects/<p>/secrets/<name>`
   - Cloud Run v2 service `projects/<p>/locations/<r>/services/<name>`
   - `_iam_member` resources: `"<resource id> <role> <member>"` (space-separated), e.g.
     `projects/<p>/secrets/<s> roles/secretmanager.secretAccessor serviceAccount:<email>`,
     `b/<bucket> roles/storage.objectAdmin serviceAccount:<email>`,
     `<project> roles/cloudtasks.enqueuer serviceAccount:<email>`
   - domain mapping `locations/<r>/namespaces/<project>/domainmappings/<domain>`
   - budget `billingAccounts/<id>/budgets/<uuid>`
3. `plan` until it says **N to import, 0 to add, 0 to change, 0 to destroy**. In production the only
   diff left was Cloud Scheduler's default `retry_config`; writing it explicitly fixed it.
4. `apply` (changes nothing real), delete `adoption.tf`, `plan` → "No changes".
5. Keep the URLs the services already use (`api_url` in tfvars): an old-style
   `…-xxxxxxxxxx-uc.a.run.app` is still valid and switching changes OIDC audiences.
6. Only then switch the workflows to image-only and **remove by hand** the broad grants CI had
   (`run.admin`, `secretmanager.viewer`, actAs): `_member` resources never delete bindings they do not
   know.

## Gotchas met for real

- **Credentials on a multi-account machine.** Terraform uses ADC, which may belong to another project.
  Pass a token of the right account instead of touching global gcloud config:
  `export GOOGLE_OAUTH_ACCESS_TOKEN="$(gcloud auth print-access-token --account=<owner account>)"`
  (valid 1 h; the GCS backend honours it too).
- **Budget alert** needs a quota project → provider alias with `user_project_override` and
  `billing_project`, used only by that resource. Putting it on the default provider made every call
  need `serviceusage.googleapis.com` enabled in the project.
- **Stale state lock** (an interrupted `plan`/`apply`): check no Terraform is running, then
  `terraform force-unlock <ID>`. With the **GCS backend the ID is the lock object's generation
  number** (`gcloud storage objects describe gs://<bucket>/<prefix>/default.tflock
  --format='value(generation)'`), not the UUID shown in the error.
- **Public services under an organization with domain-restricted sharing** cannot get `allUsers`:
  `invoker_iam_disabled = true` (the template does this for every public service).
- **Fronts calling the internal api** need Direct VPC egress `ALL_TRAFFIC` + Private Google Access on
  the subnet; without it the Google Front End answers 404. Without Cloud NAT those fronts then have
  **no internet egress** (a public domain behind Cloudflare times out) — call other services by their
  `run.app` URL.
- **The api keeps its default URL**: Cloud Scheduler and Cloud Tasks only count as internal traffic
  through it. It cannot read its own URL in Terraform (self-reference): `api_url` is computed
  (deterministic URL) or written, with a `check` that it is one of the service's `urls`.
- **Fronts send the Cloud Run ID token in `X-Serverless-Authorization`**, because `Authorization`
  carries the user's JWT. Scheduler/Tasks send theirs in `Authorization` and the api re-validates it.
- `lifecycle.ignore_changes = [client, client_version]` on services: whoever deployed last sets them.
- Loose bindings (`_member`) everywhere: they add and never remove, so they cannot delete a grant by
  mistake — and cannot express "this grant must not exist" either.
- `deletion_protection` on services and `prevent_destroy` on bucket and secrets.
- The default subnet is **checked** (`check` block), not managed.

## New project from zero

1. `scripts/gcp-bootstrap.sh`: project, billing, state bucket (versioned, private).
2. Copy `assets/terraform/` to `infra/`, set the backend bucket, `terraform.tfvars` from the example,
   delete the services/crons/bucket/queue the app does not have, adapt the `secrets` map and `env`.
3. `terraform -chdir=infra init`.
4. `terraform -chdir=infra apply -target=google_secret_manager_secret.secret` — containers only.
5. `terraform -chdir=infra/secrets apply` once per required secret.
6. `gcloud domains verify <domain>` (opens the browser).
7. `terraform -chdir=infra apply` — services start with Google's sample image until CI pushes.
8. GitHub Actions variables from `terraform output`: `GCP_PROJECT_ID`, `GCP_REGION`, `APP`,
   `WIF_PROVIDER`, `DEPLOYER_SA`. Push → CI builds, pushes and swaps the image.
9. DNS records from `terraform output dns_records` (Cloudflare with proxy works; the certificate just
   takes longer).

## Files in the repo

- Commit `.terraform.lock.hcl` of both roots and `terraform.tfvars` (not secret).
- `.gitignore`: `.terraform/`, `*.tfstate`, `*.tfstate.*`, `*.tfplan`, `crash.log`.
- Record the model as a decision in the project's decisions log, and document it in `infra/README.md`
  (how to deploy, roll back, load a secret).
