# Module: suscripciones — monthly plans billed with MercadoPago

Charge the SaaS's own customers a monthly plan: a plan catalogue edited from the admin, a free
trial, a MercadoPago subscription (the customer loads the card in MP's checkout), a signed
webhook that enters through the public `webhooks` service, upgrade / downgrade, stop paying and
come back, failed charges, and a daily reconciliation against MP that repairs whatever a webhook
lost. What a plan buys is expressed as generic **quotas** (N units per billing cycle).

It is **not** charging third parties on behalf of the customer (marketplace / OAuth). Treat that
as a separate feature; leave it out.

Reference: **project A**. Design additions from **project B**; usage-billing variant from
**project C**.

> **Re-verify MercadoPago before building.** Everything below about MP (endpoints, fields,
> statuses, signature format, what MP does when it cannot debit) is written **as the reference
> uses it**, not as a statement about MP. That API changes and its docs contradict
> themselves. Check the official documentation (and the sandbox) first, and ask the user about
> any difference. Nothing here authorises calling MP: test users, webhooks and credentials are
> actions on the user's MP account and need their explicit OK.

> **Resume status.** "Come back after stop paying" (cancel + recreate with `start_date`, including
> coming back on a more expensive plan) is **built and sandbox-tested, not yet verified in
> production**: no deploy, and the deferred first charge had not been observed
> firing on its own. Every such item below carries the tag **[unverified]**.

## Depends on

- **`login`**: a JWT user and a tenant (`account`) from the JWT. MP's payer email is the user's.
- **`mail`**: price-adjustment notice (and the past-due mails if that choice is taken).
- **`superadmin`**: plans, payments and the per-account operations live in the admin.
- **The `webhooks` service** from `deploy-gcp-cloudrun` and **Cloud Scheduler** with OIDC (two
  daily crons). MP must never reach the api directly.
- Secrets: `MP_ACCESS_TOKEN` (api; empty = billing off, the app still runs) and
  `MP_WEBHOOK_SECRET` (webhooks service only).
- From `ui-design`: bottom sheet, `Button`, custom checkbox, toasts, date picker (admin).

## Choices (ask, default first)

1. **How is the free trial limited?** by usage: a fixed number of units **in total**, never
   expires; when it runs out only the quota-consuming action is blocked **(default —
   project A; it replaced a 14-day trial)** · by time: N days with a paid plan's
   features, then a cron drops the account to a permanent free tier (project B: 14 days;
   subscribing during the trial defers the first charge to the trial's end with `start_date`).
2. **Upgrade with a live subscription?** pay the **full difference** now in a one-off checkout;
   the bigger plan applies the moment it is paid, this month's usage is kept, the subscription
   moves to the new price from the next charge **(default)** · hot change: `PUT` the new
   amount, new plan at once, new price from the next cycle (project B; gives the rest of the
   month away).
3. **Downgrade?** amount changed now, the smaller plan applies **from the next charge**, no
   refund, undoable until then **(default)** · not offered: cancel and subscribe again
   (project B answers `downgrade_not_supported`).
4. **User stops paying?** keeps the plan until the paid period ends, then quota 0 (existing
   data keeps working) **(default)** · drops to the free tier at once (project B).
5. **Failed charge (mora)?** mark `past_due`, show a notice, **restrict nothing**; access ends
   only when MP cancels the subscription **(default — this is all project A does)** · grace
   clock (project B): `past_due_since` set once, mail at day 0 / 5 / 8, a cron downgrades at day
   10 behind a dry-run flag, only an approved payment ends the episode · debt ledger (project C):
   unpaid periods accumulate and are added to the next subscription.
6. **Come back with paid days left? [unverified]** new subscription with a deferred first charge, plan
   and usage untouched **(default in the reference; say it is not production-verified when
   asking)** · new subscription that charges at once (simpler; the overlap is paid twice).
7. **Special plan built from the admin?** yes: per-account name, quotas (monthly or in total),
   optional last day, billed outside MP **(default)** · no.
8. **Currency?** prices stored and charged in ARS **(default)** · shown in USD, converted to
   ARS at a rate when the subscription is created (project C).
9. **Price increases for current subscribers?** scheduled adjustment per plan with mail notice,
   plus a per-account freeze **(default)** · price locked per subscriber at sign-up (project B).
10. **Going over a paid quota?** hard stop at 100 %, warning at 80 % **(default)** · keep
    working and bill the overage (project C).
11. **Show the trial's limits before sign-up?** no, only "Probalo gratis"; the numbers show
    inside the account and in the terms **(default)** · yes.

## Data model

Money is **integer cents** everywhere (`amount_cents`, `price_cents`). Never a float, not even
in transit: parse MP's amounts with `Decimal`.

**`plans`** — data, not code; the admin edits it without a deploy. `_id` is a stable code
(`plan1`…; the display `name` can change, the code never), `order`, `active`, `price_cents`
(changed **only** by a scheduled adjustment), `quotas: {key: int}` per cycle, and per-plan
feature flags. Seed with `$setOnInsert` at startup so an existing catalogue is never
overwritten; back-fill a new field only where it `$exists: false`.

**`account.plan`** (embedded in the tenant) — what applies **today**.

| Field | Type | Rule |
|---|---|---|
| `code` | str | `"trial"` \| a plan code \| `"special"`. Born `"trial"`. |
| `status` | `"active"` \| `"past_due"` \| `"cancelled"` | |
| `used_cycle`, `cycle_start` | `{key: int}`, datetime | Reset by each approved charge. |
| `active_until` | datetime \| None | Set on cancel: the plan works until then. |
| `quota_override` | `{key: int}` \| None | Special plan only. |
| `special` | object \| None | `name`, `renewal` (`"month"` \| `"total"`), `until`, `reason`, who and when it was activated / removed. Kept after it ends: it is history. |

Trial counters live on the account, outside `plan`: `trial_used`, `trial_extra` (admin gifts).

**`subscriptions`** — one document per MP preapproval. A cancelled one is never reused.

| Field | Type | Rule |
|---|---|---|
| `_id` | str UUID4 | Created **before** calling MP; `external_reference = "sub_<id>"`. |
| `account_id` | str | From the JWT. |
| `plan` | str | What **MP charges**. May differ from `account.plan.code` (see `scheduled_change`). |
| `status` | `"starting"` → `"pending"` → `"authorized"` \| `"paused"` \| `"cancelled"` | |
| `amount_cents` | int | What MP has today. |
| `mp_preapproval_id`, `init_point` | str \| None | |
| `next_charge` | datetime \| None | From MP's `next_payment_date`. |
| `scheduled_change` | `{current_plan, previous_amount, up?}` \| None | Plan and amount that apply until the next charge. `up` **[unverified]**: the pending change is to a dearer plan. |
| `upgrade` | object \| None | The one-off difference: `id`, `plan`, `amount_cents`, `new_price`, `order_id`, `checkout_url`, `status`, `created`, `payment_id`. |
| `target_amount` | int \| None | Difference paid but the `PUT` to MP failed: reconcile retries it. |
| `starts_at` | datetime \| None | **[unverified]** first charge deferred to this date. |
| `price_frozen` | bool | Excluded from price adjustments. |
| `amount_history` | list of `{at, amount_cents, reason}` | |
| `created`, `updated` | datetime UTC | `updated` drives the reconcile rotation. |

`upgrade.status`: `started → pending | rejected → paid` (also `refunded`). A rejected one can
still end paid: MP lets the payer retry in the same checkout.

**`payments`**: `_id`, `mp_payment_id`, `subscription_id`, `account_id`, `status`,
`amount_cents`, `invoice_id`, `kind` (`"difference"` for an upgrade), `plan`, `at`.

**`price_adjustments`**: `plan`, `previous_price`, `new_price`, `effective_date`, `status`
(`scheduled → applying → applied` \| `cancelled`), `notices_sent_at`, `notified`, `result[]`.

Indexes:
- `payments.mp_payment_id` **unique, sparse** — the idempotency key of the whole module.
- `subscriptions.account_id`; `subscriptions.mp_preapproval_id` sparse; `subscriptions.upgrade.id` sparse.
- **Add (from project B, missing in project A):** a partial unique index on
  `subscriptions(account_id)` where `status in ("starting", "pending")` — one open checkout per
  tenant, enforced by the database.

Account purge keeps `subscriptions` and `payments` (accounting), and the terms acceptances.

## Api

All routers carry the API key; tenant and user come from the JWT. Errors are `{"detail",
"code"}` and `detail` is shown to the user as is.

| Method + path | Auth | In | Out |
|---|---|---|---|
| `GET /public/plans` | API key | — | active plans, ordered (landing and dashboard) |
| `GET /billing` | JWT + tenant | — | `{subscription \| null, resume, billing_enabled}`; `subscription` = `{status, plan, amount_cents, next_charge, init_point, scheduled_change: bool, cycle_amount}` |
| `POST /billing/subscribe` | JWT + tenant | `{plan, accepts_terms}` | `{init_point}` — a URL to redirect to (MP, or back to settings on a downgrade) |
| `POST /billing/cancel` | JWT + tenant | — | `{ok}` |
| `POST /billing/undo-change` | JWT + tenant | — | `{ok}`; 404 if nothing is scheduled |
| `POST /billing/sync` | JWT + tenant | — | same as `GET /billing`, after asking MP |
| `POST /billing/upgrade/verify` | JWT + tenant | `{upgrade_id}` (UUID pattern) | `{status, plan}`; 404 if it belongs to another account |
| `POST /integrations/mp` | API key + Cloud Run IAM | `{type, data_id, user_id?}` | always `{ok: true}` |
| `POST /cron/mp-reconcile`, `/cron/price-adjustments` | Scheduler OIDC | — | counts |
| `GET/PATCH /admin/plans[/{code}]` | superadmin | `{name?, quotas?, active?, flags?}` — **no price** | plan |
| `POST /admin/plans/{code}/adjustment/preview` · `…/adjustment` | superadmin | `{price_cents, effective_date?}` | dry run (`affected`, `min_date`, per-subscription amounts) · the adjustment with `notified` |
| `GET /admin/adjustments` · `POST /admin/adjustments/{id}/cancel` | superadmin | | |
| `GET /admin/payments` · `POST /admin/reconcile` | superadmin | | last 200 · `{synced}` |
| `PUT/DELETE /admin/accounts/{id}/special` | superadmin | name, quotas, renewal, last day, reason | account detail |
| `POST /admin/accounts/{id}/{extend-trial, freeze-price}` | superadmin | `{amount}` / `{value}` | account detail |

Billing endpoints use the plain tenant dependency, **not** the "active account" one: an account
with no plan must still be able to subscribe.

### The single point that decides quotas

Every limit the product enforces goes through one function. Nothing else reads the plan.

```python
async def quota(account, key) -> Quota:                       # Quota(field, used, limit)
    if account.plan.code == "trial":                          # in total, never resets
        return Quota(f"trial_used.{key}", account.trial_used[key],
                     settings.trial[key] + account.trial_extra[key])
    override = (account.plan.quota_override or {}).get(key)   # special plan
    limit = override if override is not None else (await plans.get(account.plan.code) or {})["quotas"].get(key, 0)
    if stopped_paying(account):                               # cancelled and active_until passed
        limit = 0
    return Quota(f"plan.used_cycle.{key}", account.plan.used_cycle[key], limit)

async def consume(account_id, q) -> bool:                     # atomic: two requests cannot overshoot
    r = await db.accounts.update_one({"_id": account_id, q.field: {"$lt": q.limit}}, {"$inc": {q.field: 1}})
    return r.modified_count == 1
```

Failing to consume raises `402 quota_exhausted` with `{used, limit, available, warning}`
(`warning` = used ≥ 80 %). `GET /account` returns a `quotas` summary built from the same
function: plan name, cycle end (`{until, renews}`), each quota, feature flags, `no_plan`.

### Subscribe (one endpoint, several paths)

Order matters. Record the terms acceptance first, then:

1. MP not configured → 409. Special plan in force → 409 ("escribinos").
2. **Already paying** (`authorized`): same plan → 409; dearer than `cycle_amount` → upgrade
   (below); otherwise → schedule a downgrade and return the settings URL.
3. **[unverified]** cancelled with ≥ 1 paid day left: `starts_at = account.plan.active_until`; if the
   chosen plan differs from the paid one, add `scheduled_change` (`up` when it is not cheaper).
4. A `pending` checkout for the **same plan and same `starts_at`** → return its `init_point`.
5. Otherwise insert the row (`starting`), create the preapproval, store `pending` + ids.

`cycle_amount` = what the customer pays for the plan in force today:
`scheduled_change.previous_amount` if there is one, else `target_amount or amount_cents`. It is
the base of every difference.

### The state machine (webhook, return from checkout and reconcile all call this)

```python
async def sync_preapproval(pre: dict) -> None:                # `pre` was just fetched from MP
    sub = await repo.by_preapproval(pre["id"]) or await by_external_reference(pre)   # "sub_<id>"
    if sub is None: return
    new = mp.normalize(pre.get("status"))     # authorized | paused | cancelled | None ("pending": touch nothing)
    await repo.set(sub["id"], {"mp_preapproval_id": pre["id"], "next_charge": pre.get("next_payment_date"),
                               **amount_if_present(pre), **({"status": new} if new else {})})
    acc = sub["account_id"]
    if new == "authorized" and sub["status"] != "authorized":
        if await admin_owns_plan(acc, only_in_force=True): return
        if sub.get("starts_at") and sub["starts_at"] > now():          # [unverified] paid days left
            return await accounts.set(acc, {"plan.status": "active", "plan.active_until": None})
        await repo.set(sub["id"], {"scheduled_change": None})           # authorised late: nothing to wait for
        await accounts.set(acc, {"plan.code": sub["plan"], "plan.status": "active", "plan.used_cycle": ZERO,
                                 "plan.cycle_start": now(), "plan.active_until": None})
    elif await admin_owns_plan(acc): return
    elif new == "paused":
        await accounts.set(acc, {"plan.status": "past_due"})
    elif new == "cancelled" and sub["status"] != "cancelled":
        await accounts.set(acc, {"plan.status": "cancelled",
                                 "plan.active_until": parse(pre.get("next_payment_date")) or now()})
```

### A charge (invoice) — idempotent by payment id

```python
async def register_payment(mp_payment_id: str, data: dict) -> bool:    # True only the first time
    try:
        await db.payments.insert_one({"_id": new_id(), "mp_payment_id": mp_payment_id, **data, "at": now()})
        return True
    except DuplicateKeyError:
        await db.payments.update_one({"mp_payment_id": mp_payment_id}, {"$set": {"status": data.get("status")}})
        return False
```

An **approved** charge seen for the first time opens the cycle: counters to 0, `status: active`.
With a `scheduled_change`: a **late charge at the old amount** (`amount >= previous_amount` and
not `up`) keeps the current plan; any other approved charge applies the new plan and clears the
change. A `rejected` charge sets `past_due`. The payment row is always written, even when the
plan is admin-owned.

### Upgrade — the one-off difference

`difference = new price − cycle_amount` (not prorated). Create an MP **order** with
`external_reference = "upgrade_<uuid>"` and the same UUID as idempotency key; save it in
`subscription.upgrade` as `started`. A second tap reuses the order if it is the same plan and
amount, less than 12 h old and still unpaid. Applying it is **atomic**:

```python
r = await db.subscriptions.find_one_and_update(
    {"_id": sub_id, "upgrade.id": upgrade_id, "upgrade.status": {"$in": ["started", "pending", "rejected"]}},
    {"$set": {"upgrade.status": target, ...}}, return_document=AFTER)
if r is None: return await repo.get(sub_id)      # another request applied it just now
```

On `paid`: write the payment (`kind: "difference"`), set `account.plan.code` (usage and cycle
date untouched), `PUT` the new amount to MP. If the `PUT` fails, **enable the plan anyway** and
store `target_amount`. **[unverified]** if the subscription already has the new price, skip the `PUT`.
A refund after the plan was enabled is only logged: it is handled by hand. It arrives three
ways, all through the same function: the checkout return (`upgrade/verify` asks MP for the
order it stored — URL parameters are never trusted), the `order` webhook, and reconcile.

### Downgrade, undo, cancel

- **Downgrade**: `PUT` the smaller amount now; `subscription.plan` = the new one; the account
  keeps its plan; `scheduled_change` remembers today's plan and amount. Replacing a scheduled
  change keeps the original `current_plan`. **Undo**: `PUT` the previous amount back.
- **Cancel**: cancel in MP, then `subscription.status = cancelled`, `account.plan.status =
  cancelled`, `active_until = next_charge or now`.
- **Cancel everything MP could charge** (account deletion, special plan activated): every
  subscription in `authorized/paused/pending/starting`. If MP does not answer and the
  preapproval is not already cancelled there, **stop and do nothing** (409).

### Reconcile and crons

`reconcile()` (daily cron + the admin button): (1) up to 100 subscriptions in
`pending/authorized/paused` with a preapproval id, oldest `updated` first → `sync_preapproval`;
(2) upgrades still open from the last 2 days → re-apply the order; (3) subscriptions with
`target_amount` → retry the `PUT`. One failure never stops the loop.

Price adjustment: new price → **preview** (affected subscriptions; minimum date = today +
notice days, counted in local calendar days) → confirm → mail to each owner at once → the daily
cron takes each due adjustment atomically (`scheduled → applying`), updates `plans.price_cents`,
`PUT`s every authorized non-frozen subscription and stores a per-subscription result.

Special plan: activating it cancels everything in MP first and zeroes the counters; editing it
touches neither MP nor usage. While in force, subscribing is 409 and **no MP notice changes the
account's plan**. Monthly renewal needs no cron: the tenant dependency renews on the first
request of the new month (conditional update on `cycle_start`). Removed or past its last day →
**no plan**: reads work, whatever creates or edits answers 402 through a dedicated dependency,
and subscribing replaces it.

### MercadoPago as the reference uses it — re-verify all of this

- Subscriptions **without an associated plan**: `POST /preapproval` with `reason`,
  `external_reference`, `payer_email`, `back_url`, `status: "pending"`, `auto_recurring:
  {frequency: 1, frequency_type: "months", transaction_amount, currency_id: "ARS",
  start_date?}`. Response used: `id`, `init_point`, `next_payment_date`.
- `GET /preapproval/{id}` · `PUT /preapproval/{id}` with `auto_recurring.{transaction_amount,
  currency_id}` (amount) or `{status: "cancelled"}`. The reference relies on the new amount
  applying from the next charge and MP mailing the payer; its own checklist still lists
  "confirm in sandbox that the next charge uses the new amount" as open.
- Statuses seen: `pending`, `authorized`, `paused`, `cancelled` (also spelled `canceled`).
  Unknown → touch nothing.
- `subscription_authorized_payment` carries an **invoice** id: `GET /authorized_payments/{id}`
  (no `/v1`), with `preapproval_id`, `transaction_amount` (string **or** number) and the real
  payment nested in `payment.{id, status}`. `GET /v1/payments/{id}` for the `payment` topic.
- One-off difference: `POST /v1/orders` with header `X-Idempotency-Key`, amounts as strings
  (`"1234.50"`), `payer.email`, `config.online.{success_url, pending_url, failure_url}` and
  `config.payment_method.not_allowed_types: ["ticket"]` (no cash, so it is enabled at once).
  An order, because by the reference's reading of MP's docs a subscription cannot take an
  extra charge on its card. Order `status` as mapped: `processed` → paid (`refunded` detail →
  refunded), `processing` / `action_required` → pending, `failed` → rejected, `canceled` with
  payment attempts → rejected, `created` → nothing yet.
- Webhook topics accepted: `subscription_preapproval`, `preapproval`,
  `subscription_authorized_payment`, `payment`, and `order` / `orders` / `orders_v2`. The
  notification URL and its secret are set in the MP application's panel, not per request.
- Project B's code comments (production): MP pauses the preapproval on its own when it can
  no longer debit, and leaves it `authorized` while it retries a rejected charge.
- **[unverified]** sandbox only, absent from MP's docs: a future `start_date` becomes an
  N-day free trial, nothing is charged on authorising; N is whole calendar days (the charge can
  land up to ~24 h off); under one day it charges at once; a past date is a 400; a cancelled
  preapproval cannot go back to `authorized`; the checkout words it as "días gratis" and does
  not return to `back_url` by itself.

## Webhooks service

Public, tiny, no business logic. `POST /mp`:

```ts
export function manifest(dataId: string | null, requestId: string | null, ts: string): string {
  let m = "";
  if (dataId) m += `id:${/^[a-z0-9]+$/i.test(dataId) ? dataId.toLowerCase() : dataId};`;
  if (requestId) m += `request-id:${requestId};`;
  return m + `ts:${ts};`;
}
export function validSignature(o: { secret: string; xSignature: string | null; xRequestId: string | null; dataId: string | null }): boolean {
  if (!o.secret || !o.xSignature) return false;                     // no secret = reject everything
  const parts: Record<string, string> = {};
  for (const p of o.xSignature.split(",")) { const [k, v] = p.split("="); if (k && v) parts[k.trim()] = v.trim(); }
  if (!parts.ts || !parts.v1) return false;
  const a = Buffer.from(createHmac("sha256", o.secret).update(manifest(o.dataId, o.xRequestId, parts.ts)).digest("hex"), "hex");
  const b = Buffer.from(parts.v1, "hex");
  return a.length === b.length && timingSafeEqual(a, b);           // constant time
}
```

- `data.id` comes from the query (`data.id`), else the body, else `?id`; the topic from `type`
  or `topic`, body or query. The body may be missing.
- Invalid signature → **401**. Valid signature → **200 always**: unknown topic (ignored), api
  down, api error. Reconcile recovers it; a 5xx would make MP retry against a dead api.
- Forward `{type, data_id, user_id}` with `X-API-Key` + a Cloud Run ID token in
  `X-Serverless-Authorization`. The api **fetches the resource from MP again** and never trusts
  the notice.
- Retry the forward only while the connection never opened (cold instance), for at most 12 s;
  the reference notes MP waits 22 s for the 200.
- Deploy: `--ingress=all --no-invoker-iam-check`, no default URL; its service account is an
  invoker of the api. Bundle as CJS (google-auth-library's dynamic `require`).

## Dashboard

**Usage** (`components/plan/`): a bar per quota in the side menu, above the main list and in
Settings → Tu plan, with "Se renueva el 15/10" / "Tu plan termina el 15/10". The bar turns to
the warning colour at 80 %.

**Settings → Tu plan**: a card per plan (name, price "/mes", quotas, flags). The current one
says "Tu plan"; the others have a button — "Elegir este plan" (trial or no plan), "Cambiar a
este plan", "Volver a este plan" (stopped paying). **Every choice opens a sheet before anything
happens**; its mode is derived from `billing.subscription` exactly as the api does:

| Mode | Sheet says |
|---|---|
| new | "Te vamos a redirigir a Mercado Pago y ahí se hace la suscripción mensual al plan X ($ N por mes)." |
| upgrade | "Pagás $ D de diferencia, una sola vez, y el plan X se habilita apenas se aprueba el pago. Desde el próximo cobro tu suscripción pasa a $ N por mes." |
| downgrade | "Seguís con el plan A hasta el dd/mm (ya está pago). Desde ese cobro pasás al plan X y pagás $ N por mes." — button "Sí, bajar de plan" |
| **[unverified]** resume | "Hoy no se te cobra nada: ya lo tenés pago hasta el dd/mm." + "Mercado Pago lo muestra como "días gratis": son los días que ya tenés pagos." |

- Primary button "Sí, llevame a Mercado Pago"; secondary "Volver". A checkbox "Leí y acepto los
  términos…" is required (the api requires it too); the button is never disabled — without
  it, say what is missing. The action ends in a server-side `redirect(init_point)`.
- Scheduled change banner: "Pasás al plan X el dd/mm: desde ahí pagás $ N por mes." + "Deshacer".
  **[unverified]** to a dearer plan: "Empezás con el plan X el…" + "Empezar ya" (the upgrade sheet).
- "Dejar de pagar el plan" (muted link, only while `authorized`) → sheet "¿Dejar de pagar tu
  plan?" with primary **"Seguir con mi plan"** and outlined-danger "Sí, dejar de pagar".
- States in words: pending → "Tu suscripción está esperando el pago en Mercado Pago."; past due
  → "No pudimos cobrar el último mes: revisá tu medio de pago en Mercado Pago."; cancelled →
  "Dejaste de pagar: tu plan X sigue hasta el dd/mm."
- Special plan: no plan cards, "Estás en el plan X, que armamos para vos" + WhatsApp link.

**Returning from MP goes through a route handler, not the page.** `back_url` and the order's
`success_url` point to `/settings/plan?return=subscription` or `?upgrade=<id>` (no `#fragment`:
MP appends its parameters). The handler calls `billing/sync` or `billing/upgrade/verify` and
**then** redirects to settings. Why: in a render, layout and page both read `GET /account` and
Next dedupes that fetch, so a sync done inside the page showed the old plan next to the new
subscription. If MP has not confirmed yet: "Estamos esperando la confirmación de Mercado Pago."

## Admin

- **Plans**: name, quotas and flags editable in place. Price has its own row: new price →
  "Programar ajuste…" → sheet with old → new, % change, how many subscriptions change, date
  picker (minimum from the preview) → "Programar y avisar por mail". List of adjustments with
  status, `ok/total` once applied, and "Cancelar" while scheduled.
- **Payments**: last 200 (date, status, amount, MP payment id, link to the account) and a
  "Reconciliar con MP" button. The daily cron does the same.
- **Account detail**: current subscription, last 20 payments, special plan switch (confirms
  both ways; warns that it cancels the MP subscription), extend trial, freeze price.
- **Metrics**: MRR = sum of `amount_cents` of `authorized` subscriptions.

## Limits

| Rule | Value | Enforced in |
|---|---|---|
| Quota per cycle / trial total | per plan / settings | api, atomic |
| Warning | 80 % of the limit | api (`warning`), shown in the dashboard |
| Pending checkout reuse | same plan and same `starts_at` | api |
| Upgrade order reuse | same plan and amount, < 12 h, still unpaid | api |
| Resume **[unverified]** | ≥ 1 day of paid period left | api |
| Price-adjustment notice | 10 days (setting), calendar days | api |
| Reconcile batch | 100 subscriptions; upgrades of the last 2 days | api |
| Crons | reconcile 04:30, price adjustments 06:15, daily | Cloud Scheduler |
| MP client timeout · webhook forward retry | 15 s (5 s connect) · 12 s | api · webhooks |

## Decisions that matter

- **The webhook is the fast path; reconcile is the net.** That is why the webhook can answer
  200 to everything signed and why every handler must be safe to run twice.
- **Never trust the notice or the return URL.** Both only say "look at resource X"; the api
  fetches X from MP with its own token.
- **Two plans per account on purpose**: `subscription.plan` is what MP charges,
  `account.plan.code` is what applies today. That gap is what makes downgrade-from-next-charge,
  undo and resume possible without a scheduler.
- **The cycle belongs to the charge, not to the calendar**: counters reset when a charge is
  approved, so usage can never drift from what was actually paid.
- **Upgrade is a separate one-off payment**, without cash, so the plan is enabled at once and
  the month is not given away. If the follow-up `PUT` fails the customer already paid: enable
  and retry later.
- **Cancelling in MP comes first.** Account deletion and the special plan refuse to proceed if
  MP does not confirm: better to do nothing than to leave something charging.
- **Price is not an editable field.** It changes only through notice → date → cron, so nobody
  is charged an amount they were not told about.
- **The special plan is immune to MP**: a late charge or a reconcile must not overwrite what
  the admin set. The payment is still recorded, to refund by hand.
- **A plan's effects are computed at read time**, never stored on the data they affect: a
  downgrade takes effect everywhere at once and an upgrade restores it.

## Do not copy

- **Project C does not verify `x-signature`**: its proxy forwards the header untouched and
  its billing router never checks it. It also keeps money in **floats**.
- **Project B's signature check** accepts unsigned notices when neither secret nor token is set,
  does not lowercase `data.id`, and answers 200 to a bad signature. Use project A's version.
  Project B also stores whole pesos (`Math.round`), dropping cents.
- **Two live preapprovals.** Project A does not cancel a `pending` checkout of another plan
  when a new one is created, and has no unique constraint on open checkouts. Project B's code
  comments record the consequence in production (two authorised subscriptions, double debit).
  Take project B's design: the unique partial index, and when a newer checkout wins, cancel the
  older preapproval **after** storing the new id, with a durable retry (`cancel_pending` +
  backoff) and ignoring later notices from the superseded one.
- **Row stuck in `starting`.** If creating the preapproval fails, the reference raises an
  unhandled `MpError` (500) and leaves the row; nothing cleans it. Catch it, mark the row
  `failed`, answer 409. Project B additionally recovers an ambiguous `POST` by searching MP for
  the `external_reference`.
- **`cancel` has no state guard** in the reference: with only a `pending` checkout it still
  marks the account `cancelled` (overwriting `active_until`), and an MP error is a 500. Require
  `authorized`/`paused`, and catch the error (project B queues the cancellation for retry).
- The reference zeroes only its **main** quota after the paid period ends; its second quota
  keeps its limit. Decide per quota key, on purpose.
- **"Approved and first time"** opens the cycle. A payment id first stored as not approved and
  later approved would not open it. Read in the code, not reproduced; whether MP reuses the id
  across retries is unverified. Safer: an atomic `status != approved → approved` transition.
- **Reconcile does not look at invoices.** The reference says reconcile recovers anything a
  webhook loses (in its docs and in a code comment); the code only
  re-syncs the preapproval, open upgrades and failed `PUT`s. A lost charge notice leaves the
  counters un-reset. Project B's client has an invoice search by preapproval; neither project
  uses it for this. Add it, after verifying the endpoint.
- **`paused → authorized` re-runs activation** in project A (counters to 0). Project B
  deliberately does not leave mora on `authorized`: only an approved payment does.
- `next_charge` is stored as MP's raw string and parsed on every read. Store a datetime.
- Stale bits found (do not inherit): an admin doc still listing a feature that a later decision
  removed; the billing doc giving two different trial sizes (and the settings agreeing with only
  one); an error code whose name no longer matches what it means; a comment describing undo as
  downgrade-only; tests and docs saying the real-sandbox check is pending after it was partly
  done. Keep docs and code comments in step with the code.

## Tests

Api, against a real DB and an **in-memory fake MP** injected as the HTTP transport. At least:
1. Subscribe → same plan again reuses the checkout → authorised by webhook → plan quotas →
   approved charge resets the counters → **the same webhook twice writes one payment**.
2. Upgrade: order for the exact difference, no cash; nothing changes until paid; paid → plan
   now, usage kept, `PUT` sent; rejected then retried; another account gets 404; `PUT` down →
   plan enabled, `target_amount` set, reconcile clears it.
3. Downgrade: plan unchanged, undo, a late charge at the old amount does not apply it, the
   charge at the new amount does. Cancel: quota stays until `active_until`, then 0.
4. **[unverified]** resume on the same plan (no charge, usage kept, first charge opens the cycle),
   dearer plan (+ "start now" with no `PUT`), cheaper plan, and under one day left.
5. Price adjustment: frozen account excluded, the preview's minimum date accepted and the day
   before rejected, second cron run does nothing.
6. Special plan: activation cancels in MP (MP down → not activated); a late charge and
   reconcile do not change the plan; monthly renewal; removal leaves no plan.

Webhooks service: manifest with an uppercase alphanumeric id; valid / tampered / no secret;
401 on bad signature; unknown topic answered 200 and not forwarded.

e2e at 390 px with a **fake MP server** (`MP_API_BASE` pointing to it, fake checkout pages that
redirect to `back_url` / `success_url`): the whole plan journey, asserting that the page right
after returning already shows the new plan. Before production, with the user's OK, run the real
sandbox: subscribe, change the amount, and watch the next charge happen on its own.

## Checklist

- [ ] MP's current docs read and every item of "as the reference uses it" re-verified.
- [ ] Choices asked and recorded, including what failed charges do.
- [ ] All money in integer cents; MP amounts parsed with `Decimal`.
- [ ] `payments.mp_payment_id` unique; one open checkout per tenant enforced by an index.
- [ ] Every limit goes through the single quota function; consume is one conditional update.
- [ ] Webhooks service: 401 on bad signature, 200 otherwise, empty secret rejects everything.
- [ ] The api re-fetches every resource from MP; return URLs are never trusted.
- [ ] Webhook, checkout return and reconcile share the same handlers; each is safe to repeat.
- [ ] Return from MP lands on a route handler that syncs before redirecting.
- [ ] Price changes only through a scheduled adjustment with notice.
- [ ] Special plan: MP cancelled first, and MP notices cannot change the plan while it lasts.
- [ ] Creating a preapproval that fails leaves no `starting` row; cancel is state-guarded.
- [ ] Reconcile and price-adjustment crons scheduled with OIDC; admin button works.
- [ ] Anything tagged [unverified] stays flagged until a deferred charge has been seen in production.
