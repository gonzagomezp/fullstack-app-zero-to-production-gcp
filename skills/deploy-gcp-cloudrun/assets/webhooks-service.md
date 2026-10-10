# The `webhooks` service

A separate, **public, minimal** Cloud Run service that receives external webhooks
and forwards the verified payload to the **internal** backend using Cloud Run IAM
(ID tokens). Add this only when external providers (Stripe, GitHub, etc.) must
POST to you. Skip it entirely if there are no inbound webhooks.

Re-verify base image tags and provider signature schemes before building.

---

## Why a separate service

- The backend is `--ingress internal --no-allow-unauthenticated`, so external
  providers cannot reach it directly (they cannot do GCP IAM).
- Exposing the backend publicly just for webhooks would widen the attack surface.
- A tiny dedicated service keeps the public surface minimal and single-purpose.

```
[Provider] --HTTPS--> [webhooks (ingress all, allow-unauth)]
   1. verify provider signature (secret from Secret Manager)
   2. mint ID token (audience = backend URL)
   3. forward verified event --internal + Bearer id_token--> [backend (internal)]
   4. return provider's expected ack fast; heavy work runs async on backend
```

## Responsibilities — and ONLY these

1. Accept the inbound request. It is `--allow-unauthenticated` because the
   provider has no GCP identity; **the signature IS the authentication.**
2. **Verify the provider signature** before anything else. Reject on failure.
3. Optionally validate/normalize payload shape.
4. Mint an ID token and forward to the internal backend.
5. Ack quickly. No business logic here — that lives in the backend.

## Deploy

> Model B deploys it with the command below. Model A makes it one more entry of the services map in
> `infra/services.tf` (`public = true`, `vpc = true`, secrets `API_KEY` + the signing secret) and CI
> only swaps its image.

```bash
gcloud run deploy webhooks \
  --image REGION-docker.pkg.dev/PROJECT/repo/webhooks \
  --region REGION \
  --ingress all \
  --allow-unauthenticated \
  --service-account webhooks-sa@PROJECT.iam.gserviceaccount.com \
  --set-secrets STRIPE_WEBHOOK_SECRET=stripe-wh:latest \
  --set-env-vars BACKEND_URL=https://backend-xxxx-uc.a.run.app \
  --min-instances 0 --max-instances 5 --concurrency 80 \
  --port 8080

# Invoker on the internal backend, secret access for the signing secret:
gcloud run services add-iam-policy-binding backend --region REGION \
  --member serviceAccount:webhooks-sa@PROJECT.iam.gserviceaccount.com \
  --role roles/run.invoker
gcloud secrets add-iam-policy-binding stripe-wh \
  --member serviceAccount:webhooks-sa@PROJECT.iam.gserviceaccount.com \
  --role roles/secretmanager.secretAccessor
```

---

## Minimal Dockerfile (Node, distroless nonroot)

```dockerfile
# ---------- deps ----------
FROM node:22-slim AS deps
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci --omit=dev

# ---------- final ----------
FROM gcr.io/distroless/nodejs22-debian12:nonroot
WORKDIR /app
ENV NODE_ENV=production PORT=8080
COPY --from=deps /app/node_modules ./node_modules
COPY . .
EXPOSE 8080
CMD ["index.js"]
```

(For Python/FastAPI, use the `Dockerfile.fastapi` pattern with an internal
forward step.)

---

## Minimal code sketch (Node — Stripe example)

```js
// index.js — verify Stripe signature, forward to internal backend with ID token.
import express from 'express';
import Stripe from 'stripe';
import { GoogleAuth } from 'google-auth-library';

const PORT = process.env.PORT || 8080;
const BACKEND_URL = process.env.BACKEND_URL;                 // internal backend
const WH_SECRET = process.env.STRIPE_WEBHOOK_SECRET;        // from Secret Manager
const stripe = new Stripe(process.env.STRIPE_KEY || 'sk_unused');
const auth = new GoogleAuth();
const app = express();

app.get('/healthz', (_req, res) => res.send('ok'));

// Raw body is required for signature verification.
app.post('/webhooks/stripe',
  express.raw({ type: 'application/json' }),
  async (req, res) => {
    let event;
    try {
      event = stripe.webhooks.constructEvent(
        req.body, req.headers['stripe-signature'], WH_SECRET);
    } catch (err) {
      return res.status(400).send(`signature verification failed: ${err.message}`);
    }

    // Forward the verified event to the internal backend with an ID token.
    const client = await auth.getIdTokenClient(BACKEND_URL);  // audience = backend URL
    await client.request({
      url: `${BACKEND_URL}/internal/events`,
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      data: event,
    });

    // Ack fast; heavy processing happens async on the backend.
    res.json({ received: true });
  });

app.listen(PORT, '0.0.0.0', () => console.log(`webhooks on ${PORT}`));
```

### Notes

- `getIdTokenClient(BACKEND_URL)` mints a Google-signed ID token with the backend
  URL as audience; the backend validates it via Cloud Run IAM. No service-account
  keys needed — the metadata server signs it.
- Store EVERY provider's signing secret in Secret Manager; never hardcode.
- For GitHub, verify `X-Hub-Signature-256` (HMAC SHA-256) instead.
- Keep `--max-instances` modest to bound abuse; consider Cloud Armor / rate
  limiting in front if the provider volume warrants it.
- This service has NO business logic and NO database access — verify and forward
  only. That is what keeps the public surface safe.

### Per-service docs

Like every service, `webhooks/` must contain `CLAUDE.md` and `README.md`
describing its providers, secrets, the backend endpoint it forwards to, and the
rule: **update these docs whenever the architecture changes** (new provider, new
forward target, changed signature scheme).
