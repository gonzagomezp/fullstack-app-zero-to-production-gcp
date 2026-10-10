# Cloud Run best practices

Verified June 2026. Cloud Run flags, distroless tags, and runtime versions change
— re-verify against current Google docs before each release.

> **Model B** (`model-gcloud.md`) uses these `gcloud` flags as they are. **Model A** (`terraform.md`)
> puts the same config in `infra/services.tf`. Equivalences:
> `--ingress internal` = `ingress = "INGRESS_TRAFFIC_INTERNAL_ONLY"`, `--no-allow-unauthenticated` =
> the default IAM check, public service = `invoker_iam_disabled = true` (not `allUsers`: refused under
> domain-restricted sharing), `--set-secrets` = `env { value_source { secret_key_ref } }`,
> `--min/max-instances` = `template.scaling`, `--no-cpu-throttling` = `cpu_idle = false`.

---

## 1. Networking: internal vs public ingress

Cloud Run `--ingress` controls who can reach a service at the network layer:

- `all` — reachable from the public internet. Use only for the **frontend** and,
  if present, the **webhooks** service.
- `internal` — reachable only from the same project's VPC network and from other
  Cloud Run / internal Google services. Use for the **backend** and any service
  that should never be hit directly from outside.
- `internal-and-cloud-load-balancing` — internal plus an external HTTPS load
  balancer; use when you front a service with a global LB / Cloud Armor.

**Two independent layers — set both:**

1. **Ingress (network):** `--ingress internal` on the backend.
2. **Authentication (IAM):** `--no-allow-unauthenticated` on the backend so only
   callers with the Invoker role and a valid ID token succeed.

Network ingress alone is not authentication; IAM alone does not stop the public
internet from reaching the URL. The backend needs both.

```bash
gcloud run deploy backend \
  --ingress internal \
  --no-allow-unauthenticated \
  ...
```

For service-to-service traffic to be treated as "internal", the caller should be
on the same VPC (Direct VPC egress or a Serverless VPC Access connector) or be
another Cloud Run service in the project. If the frontend cannot reach an
`internal` backend, confirm VPC egress / connector configuration.

---

## 2. Service-to-service auth with ID tokens

The backend is private (`--no-allow-unauthenticated`). A caller must:

1. Have **`roles/run.invoker`** on the target service (granted to its service account).
2. Send a Google-signed **ID token** with **audience = the target service URL**.

Grant the invoker role:

```bash
gcloud run services add-iam-policy-binding backend \
  --region REGION \
  --member serviceAccount:frontend-sa@PROJECT.iam.gserviceaccount.com \
  --role roles/run.invoker
```

### Fetch + send the ID token

The token comes from the metadata server. The `audience` is the **base URL** of
the target service (no path).

**Python** (using `google-auth`):

```python
import google.auth.transport.requests
import google.oauth2.id_token
import httpx

AUDIENCE = "https://backend-xxxx-uc.a.run.app"

def call_backend(path: str):
    auth_req = google.auth.transport.requests.Request()
    token = google.oauth2.id_token.fetch_id_token(auth_req, AUDIENCE)
    return httpx.get(f"{AUDIENCE}{path}",
                     headers={"Authorization": f"Bearer {token}"})
```

**Node** (using `google-auth-library`):

```js
import { GoogleAuth } from 'google-auth-library';

const AUDIENCE = 'https://backend-xxxx-uc.a.run.app';
const auth = new GoogleAuth();

export async function callBackend(path) {
  const client = await auth.getIdTokenClient(AUDIENCE);
  return client.request({ url: `${AUDIENCE}${path}` });
}
```

On Cloud Run the service runs as its assigned service account automatically, so no
key files are needed — the metadata server signs the token. Never download or ship
service-account JSON keys.

---

## 3. Secret Manager

Store anything sensitive (DB URLs, API keys, signing secrets) in Secret Manager,
not in env vars set on the command line and never in the image.

```bash
echo -n "postgres://..." | gcloud secrets create db-url --data-file=-

gcloud run deploy backend \
  --set-secrets DATABASE_URL=db-url:latest,STRIPE_KEY=stripe-key:latest \
  ...
```

The service account needs `roles/secretmanager.secretAccessor`:

```bash
gcloud secrets add-iam-policy-binding db-url \
  --member serviceAccount:backend-sa@PROJECT.iam.gserviceaccount.com \
  --role roles/secretmanager.secretAccessor
```

- Pin a version (`db-url:1`) for reproducibility, or `:latest` to auto-pick up
  rotations (requires a new revision / restart to take effect when mounted as env).
  More precisely: as env vars, secrets are resolved **when each instance starts**, so with `latest`
  new instances get the new value by themselves (with `min-instances 0`, within minutes).
- Model A: containers + readers in `infra/secrets.tf`, values with
  `terraform -chdir=infra/secrets apply` (never in plan, state or workflows). Model B: containers
  from the bootstrap script, values with a secrets script (`model-gcloud.md`).
- Non-sensitive config -> `--set-env-vars`. Sensitive -> `--set-secrets`.
- Give each service its **own** service account with least-privilege grants.

---

## 4. Instances, concurrency, CPU

- `--min-instances` — keep warm instances to cut cold starts. `0` for backends
  that tolerate cold starts (cheapest); `1`+ for latency-sensitive frontends.
- `--max-instances` — cap to bound cost and protect downstreams (e.g. DB
  connection limits). Always set it.
- `--concurrency` — max simultaneous requests per instance (default 80). Lower it
  for CPU-bound or memory-heavy work; raise it for I/O-bound services.
- `--cpu` / `--memory` — size to the workload. Consider `--cpu-boost` for faster
  cold starts. By default CPU is only allocated during request processing; use
  `--no-cpu-throttling` (always-on CPU) only for background work.

```bash
--min-instances 0 --max-instances 10 --concurrency 80 --cpu 1 --memory 512Mi
```

Right-size concurrency against the backend's connection pool: instances x
concurrency should not exceed what the DB / downstream can handle.

---

## 5. Startup & liveness probes

Cloud Run supports HTTP **startup** and **liveness** probes. Distroless images
have no shell, so use **HTTP probes**, not `exec`.

- **Startup probe** — traffic is withheld until it passes; protects slow boots.
- **Liveness probe** — restarts a container that stops responding.

`service.yaml` snippet:

```yaml
spec:
  template:
    spec:
      containers:
        - image: REGION-docker.pkg.dev/PROJECT/repo/backend
          ports:
            - containerPort: 8080
          startupProbe:
            httpGet:
              path: /healthz
            initialDelaySeconds: 0
            periodSeconds: 5
            failureThreshold: 12   # ~60s to become ready
          livenessProbe:
            httpGet:
              path: /healthz
            periodSeconds: 30
            failureThreshold: 3
```

Implement a cheap `/healthz` that returns `200` without touching slow downstreams
(or with a fast, bounded check). Keep liveness lightweight so it does not cause
restart storms under load.

---

## 6. Region

- Pick a region close to users and to dependencies (DB, other services).
- Keep all services of one app in the **same region** to minimize latency and
  egress cost and to keep internal networking simple.
- For multi-region, front services with an external HTTPS load balancer and use
  `internal-and-cloud-load-balancing` ingress.

---

## 7. The webhooks-proxy service design

When external providers must POST to you but the backend is internal, run a
separate **public, minimal** `webhooks` service:

```
[Provider] --HTTPS--> [webhooks (ingress all)] --verify sig--> mint ID token
            --internal + Bearer ID token--> [backend (ingress internal)]
```

Responsibilities (and only these):

1. Accept the inbound request (`--ingress all`, `--allow-unauthenticated` because
   the provider cannot do GCP IAM). Under an organization with domain-restricted sharing
   `allUsers` is refused: use `--no-invoker-iam-check` (model A: `invoker_iam_disabled = true`).
2. **Verify the provider's signature** (e.g. Stripe `Stripe-Signature`, GitHub
   `X-Hub-Signature-256`) using a secret from Secret Manager. Reject on failure.
3. Optionally normalize/validate the payload shape.
4. Mint an ID token (audience = backend URL) and forward the verified event to the
   internal backend.
5. Return the provider's expected ack quickly; do heavy work async on the backend.

Keep it stateless, tiny, and free of business logic so the public surface is
minimal. Give it its own service account with Invoker on the backend and
`secretAccessor` on the signing secret. See `../assets/webhooks-service.md`.

---

## 8. Image scanning & SBOM (CRA)

The **EU Cyber Resilience Act** (effective Sep 2026) pushes SBOMs and ongoing vuln
management. Bake this into CI now:

- **Scan** images on push — Artifact Registry / Container Analysis scanning, or
  Trivy / Grype in the pipeline. Fail the build on high/critical CVEs.
- **Generate an SBOM** per image (e.g. `syft`, or `docker sbom`) and store/attach
  it as a build artifact or via Artifact Registry attestations.
- **Sign** images (cosign) and verify at deploy with Binary Authorization for a
  stronger supply chain.
- Rebuild regularly to pick up base-image patches; pinned tags do not auto-update.
