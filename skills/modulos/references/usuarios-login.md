# Module: login — users, session, password or Google

The base of every app with accounts. A user signs up with **email + password** (the account is
created only after a 6-digit code sent by mail) or with **"Continuar con Google"** (one client,
ID-token flow, no client secret, no redirect). Session is the app's own JWT: short access token +
rotating refresh token, both in httpOnly cookies set by Next, renewed before render. The
**admin** app uses the same api: it accepts password or Google for the superadmin, and the
superadmin can **switch the password off** ("entrar solo con Google") from the admin itself.

This recipe **replaces** the basic JWT sketch in `api-fastapi/references/auth-jwt.md` whenever
the app has real users.

Reference: **project A**, in production (pattern hardened by three production incidents, all noted
below). Versions are the ones used at the time of writing.

## Depends on

- **`mail`**: signup code and password-reset link. Without mail credentials (local, e2e) the
  mail — code included — goes to the log, which is what makes local signup testable.
- `api-fastapi` base: API key on every router, domain-error envelope `{detail, code}`.
- `frontend-dashboard-next` base: Server Actions, `output: "standalone"`.

## Choices (ask, default first)

1. **Self-serve signup?** yes: anyone can create an account, and Google creates it on first
   login **(default for a SaaS)** · no: users are created by an admin, and Google login only
   lets in emails that already exist (that is how the admin endpoint already behaves).
2. **Google login?** yes **(default)** · no (the module works with `GOOGLE_OAUTH_CLIENT_ID`
   empty: no button, api answers 503).
3. **Tenant model**: one user ↔ one account **(default; what the reference does)** · several
   members per account with roles (not in the reference — another project, project C, has
   owner/admin/member guards as FastAPI dependencies; design it before building).
4. **Admin access**: password or Google, with the Google-only switch **(default)** · Google-only
   from day one (seed the superadmin with `google_only=true`; requires Google configured and the
   superadmin's email to be a real Google account, or nobody can get in).
5. **Session lengths**: access 15 min, refresh 14 days **(default)**.

## Data model

### `users`

| Field | Type | Rule |
|---|---|---|
| `_id` | str UUID4 | The superadmin has the fixed id `"superadmin"`. |
| `email` | str | **Always lowercased and stripped**, in the repo, on every read and write. Unique. |
| `name` | str | From Google's `name` claim, else `""`. |
| `password_hash` | str | argon2id. **`""` if the user was born with Google** (then password login can never match). |
| `google_sub` | str \| None | Stored on the first Google login. |
| `google_only` | bool | The password is switched off. Default `false`. |
| `role` | `"user"` \| `"superadmin"` | The reference calls the first one `comerciante`. |
| `account_id` | str \| None | The tenant. |
| `disabled` | bool | |
| `created`, `last_login` | datetime | |

`PublicUser` — what travels to the front and sits in the `user` cookie: `id, email, name, role,
account_id`. Nothing else.

### Auxiliary collections

| Collection | Shape | Notes |
|---|---|---|
| `refresh_tokens` | `_id` = **the jti**, `user_id`, `valid`, `consumed_at`, `revoked`, `expires_at` | |
| `pending_signups` | `_id` = lowercased email, `password_hash`, signup fields, `code_hmac`, `attempts`, `sent_at`, `expires` | The account does **not** exist yet. |
| `password_resets` | `_id` uuid, `user_id`, `token_hash` (sha256), `expires_at`, `used` | |
| `limits` | `_id` = `login:<email>` (`attempts`, `since`, `expires`) or `reset:<email>` (`expires`) | |

Indexes: `users.email` unique · `users.google_sub` sparse · `users.account_id` ·
`refresh_tokens.user_id` · `password_resets.token_hash` · and **TTL indexes**
(`expireAfterSeconds=0`) on `refresh_tokens.expires_at`, `password_resets.expires_at`,
`pending_signups.expires`, `limits.expires`.

Index creation at startup must be **non-fatal** if the DB does not answer: the app still boots
and `/health` replies.

## Api

Every router carries the API key. "JWT" = `Authorization: Bearer <access>`.

`TokenPair`: `{access_token, refresh_token, token_type: "bearer", user: PublicUser, new: bool}`.
`new=true` means the account was just created → the front sends them to onboarding.

| Method + path | Auth | In | Out |
|---|---|---|---|
| `POST /auth/signup` | key | `{email, password (8–200), …signup fields}` | 202 `{email, resend_in}` · 409 exists · 503 mail failed |
| `POST /auth/signup/confirm` | key | `{email, code: 6 digits}` | 201 `TokenPair(new=true)` · 400 expired / wrong (says attempts left) · 429 out of attempts |
| `POST /auth/signup/resend` | key | `{email}` | 202 · 404 expired · 429 "wait N s" |
| `POST /auth/login` | key | `{email, password}` | 200 · 401 · 403 Google-only · 409 mail not confirmed · 429 |
| `POST /auth/google` | key | `{credential}` | 200 (`new=true` if it created the account) · 401 · 403 disabled · 503 not configured |
| `POST /auth/admin/google` | key | `{credential}` | 200 · 403 unless it is an existing, enabled superadmin. **Never creates anything.** |
| `GET /auth/admin/access` | key, **no JWT** | — | `{google_only, google_configured}` — the admin login screen needs it before there is a session |
| `POST /auth/refresh` | key | `{refresh_token}` | 200 `TokenPair` · 401 |
| `POST /auth/logout` | key | `{refresh_token}` | 204; revokes **that** token |
| `POST /auth/password-reset/request` | key | `{email}` | **always 204** |
| `POST /auth/password-reset/confirm` | key | `{token, new_password}` | 200 `TokenPair` (logged in) · 400 expired/used · 403 Google-only |
| `GET /admin/access` | superadmin | — | `{email, google_only, google_linked, google_configured}` |
| `POST /admin/access` | superadmin | `{value: bool}` | turns `google_only` on/off; 409 if it would lock them out |

### Dependencies

```python
async def get_current_user(creds = Depends(_bearer)) -> User:
    if creds is None: raise HTTPException(401, "Missing bearer token")
    try:
        payload = auth_fn.decode_token(creds.credentials, expected_type="access")
    except pyjwt.PyJWTError:
        raise HTTPException(401, "Invalid token")
    user = await users_repo.get_by_id(payload["sub"])      # read from the DB on EVERY request
    if user is None or user.disabled:
        raise HTTPException(401, "User not found or disabled")
    return user
```

Reading the user on every request is what makes "disable" cut a live session instantly,
without waiting for the access token to expire.

`get_account(user)` resolves the tenant **from the user**; no endpoint ever takes an
`account_id` from the client. `require_superadmin` = `get_current_user` + `role` check, applied
once at router level on `/admin/*`.

`require_api_key` compares with `secrets.compare_digest`.

### Tokens

HS256 with `JWT_SECRET`. Every token carries `type` (`access` / `refresh`) and `decode_token`
rejects the wrong type — a refresh token can never be used as an access token. Password hashing:
`pwdlib` `PasswordHash.recommended()` (argon2id); `verify_password` returns `False` on an empty
hash or on any exception.

### Refresh rotation (the part that has bitten twice)

```python
async def rotate_refresh(user_id: str, old_jti: str) -> str:
    if not await users_repo.consume_refresh(user_id, old_jti):          # atomic
        if not await users_repo.recently_consumed(user_id, old_jti, settings.refresh_grace_seconds):
            await users_repo.revoke_all_refresh(user_id)                # real reuse → kill every session
            raise PermissionError("refresh token reuse detected")
    new_token, new_jti = create_refresh_token(user_id)
    await users_repo.store_refresh(user_id, new_jti)
    return new_token
```

- `consume_refresh` is **one atomic update** with the whole criterion in the filter
  (`{_id: jti, user_id, valid: true}` → `{valid: false, consumed_at: now}`).
- **Grace window (30 s)**: a jti consumed less than 30 s ago and **not revoked** is a benign
  race (two dashboard instances, a prefetch and the real navigation) → issue anyway. A revoked
  token never enters grace.
- Outside the window it is theft → revoke all of that user's refresh tokens.
- After rotating, `/auth/refresh` re-reads the user and answers 401 if missing or disabled.

### Signup with code (two steps)

1. `POST /auth/signup`: 409 if the email already has a user. Otherwise hash the password and
   upsert the pending signup with a fresh 6-digit code (`secrets.randbelow(10**6)`), TTL 15 min.
   **Only the HMAC is stored**, never the code:
   `HMAC-SHA256(secret, f"{email_lower}|{code}")`.
   If a code was sent less than 60 s ago, update the data and keep the same code (no new mail).
2. The mail is sent **inside the request**. If it fails → 503 with a message for the user.
3. `POST /auth/signup/confirm`: **atomic** `find_one_and_delete` with the HMAC, `expires > now`
   and `attempts < max` in the filter — two requests with the same code cannot create two
   accounts. On a miss, increment attempts and answer how many are left; 5 attempts.
4. Re-check the email is still free (they may have entered with Google meanwhile), create
   tenant + user, issue the pair with `new=true`.

Login of someone who signed up but never entered the code: if the password matches the pending
signup, clear the throttle, send a code and answer **409**; the front shows the code step.

### Login

```python
blocked = await limits_repo.note_login(body.email)       # counted BEFORE looking at the password
if blocked: raise HTTPException(429, f"Demasiados intentos. Probá de nuevo en {minutes} minutos…")
user = await users_repo.get_by_email(body.email)
…pending-signup branch…
if user is not None and user.google_only:
    raise HTTPException(403, "Esta cuenta entra solo con Google.")
if user is None or user.disabled or not verify_password(body.password, user.password_hash):
    await limits_repo.failed_login(body.email)
    raise HTTPException(401, "El email o la contraseña no coinciden.")
await limits_repo.clear_login(body.email)
return await _issue_pair(user)
```

**Throttle**: 8 attempts per email in a 15-minute window; on reaching the cap the wait lasts
another full window. One document per key, **atomic** (an aggregation-pipeline update with
upsert that either resets or increments in one command), TTL-cleaned. It counts for emails that
do not exist too — answering differently would reveal which emails have accounts.

It lives **in the api and is keyed by email**, not in the CDN/WAF by IP: the dashboard login is a
Server Action that Next posts from whatever route the form is on (a per-path rule never sees
it), and the api is the single point every login passes through, dashboard and admin alike.

### Google

```python
_request = google_requests.Request()      # process-level: reuses the connection to Google's certs

def verify_id_token(credential: str) -> dict:
    return google_id_token.verify_oauth2_token(credential, _request, settings.google_oauth_client_id)
```

Validates signature, `aud` (our client id), `iss` and `exp`; raises `ValueError` otherwise. It
is blocking → `run_in_threadpool`. The router additionally requires `email_verified`.

`POST /auth/google`: look the user up **by email**. Missing → (self-serve) create tenant + user
with `google_sub`, `name`, empty `password_hash`, delete any pending signup, `new=true`.
Existing → 403 if disabled; store `google_sub` if it had none; issue the pair. So an account
born with a password gets Google linked on its first Google login, and keeps both.

`POST /auth/admin/google`: same verification, then **403 unless the user exists, is
`superadmin` and is enabled**. It must be a separate endpoint: if the admin button hit
`/auth/google`, anyone tapping it would be registered as a regular user.

One OAuth client for everything: no nonce, no client secret, no redirect URI.

### Password reset

- `request`: **always 204**. Does nothing if the user is missing, disabled or Google-only. One
  mail per minute per email — the turn is reserved atomically (upsert with `expires <= now` in
  the filter; the duplicate-key error *is* the "no"). Invalidates earlier tokens, generates
  `secrets.token_urlsafe(32)`, stores its sha256 with a 30-min TTL, mails the link.
- The link points to the **dashboard or the admin according to the user's role**.
- `confirm`: atomic one-use consume → 403 if Google-only → set the hash → **revoke all refresh
  tokens** → clear the login throttle → return a pair (they are logged in).
- A Google-born user has no password but can create one this way.

### Superadmin seed

`ensure_superadmin()` at startup, from `SUPERADMIN_EMAIL` + `SUPERADMIN_PASSWORD`:
- Already exists → **the password is never touched** (the env one is only the seed; overwriting
  it would erase the one set later via "Olvidé mi contraseña"). The email **does** follow
  `SUPERADMIN_EMAIL` on every boot, unless that email already belongs to another user.
- `SUPERADMIN_PASSWORD` empty → not created, with a warning.
- Make `SUPERADMIN_EMAIL` a **real mailbox that is also a Google account**: that is what lets
  the superadmin recover the password and enter with Google.

### The Google-only switch

`POST /admin/access {value: true}` refuses with **409** unless (a) the server has
`GOOGLE_OAUTH_CLIENT_ID` and (b) the superadmin has a `google_sub`, i.e. **has already entered
with Google once**. That interlock is the whole point: switching the password off without a
linked Google account locks them out, and getting back in would mean touching the DB.

With it on: `/auth/login` → 403 *"Esta cuenta entra solo con Google."* (the real message — it is
not a secret, the login screen says so, and "no coinciden" would leave them retrying the right
password); reset `request` sends nothing; reset `confirm` with an already-mailed link → 403.

## Fronts (dashboard and admin share all of this)

### Cookies

Three httpOnly cookies: `access` (max-age = access TTL), `refresh` and `user` (max-age = refresh
TTL). `secure` in production, `sameSite: "lax"`, `path: "/"`, **no `domain`** — host-only, so
admin and dashboard never share a session. Keep the cookie options in a file with **no
`next/headers` import** (`sessionCookies.ts`): both `session.ts` and `proxy.ts` need them and the
proxy cannot import `next/headers`.

The `user` cookie is unsigned JSON. It only drives UX (which screen to show); **the api is the
barrier** and re-validates everything.

### Renewal lives in `proxy.ts`, never in `apiFetch`

During render Next does not let you write cookies. If the refresh happens there, the api
rotates the token but the new one is lost; the next request arrives with the old one, the api
reads it as reuse and **kills every session of the user** — a guaranteed 500 about 15 minutes
after login (seen in production). The proxy can write cookies, so rotation completes.

(`proxy.ts` is what `middleware.ts` became in Next 16; verify the current name and runtime for
the Next version in use.)

```ts
const pair = await pending;          // one exchange in flight per refresh token (Map<string, Promise>)

if (pair === "no_answer") {          // network error, 5xx, Cloud Run's own 403/404
  const headers = new Headers(request.headers);
  headers.set(NOT_RENEWED_HEADER, "1");                 // cookies untouched
  return NextResponse.next({ request: { headers } });
}
if (pair === "rejected") {           // the api said 401
  if (request.method === "GET") return clearSession(NextResponse.redirect(new URL("/login?sesion=vencida", request.url)));
  return clearSession(NextResponse.next());             // Server Action: it fails and redirects itself
}
request.cookies.set("access", pair.access_token);       // THIS render must already see the new token
…
response.cookies.set("access", pair.access_token, { ...SESSION_COOKIE, maxAge: ACCESS_MAX_AGE });
```

Rules:
- Runs on everything except a list of public paths and static assets. The matcher **must
  include Server Actions** (they are POSTs to the page route).
- Renews when there is a `refresh` cookie and the access has less than 60 s left (read `exp`
  without verifying — it only decides whether to renew).
- **De-duplicate exchanges in flight by token**: a prefetch and the navigation firing together
  must share one exchange, or the api sees a reuse.
- **"Rejected" and "no answer" are different outcomes.** Only a 401 from the api means the
  session is dead. Anything else leaves the cookies alone and marks the request; `apiFetch`
  then fails that request with a 503 **without calling the api** (a 401 there would route to
  `/session-expired`, which does wipe the session). Confusing the two logged users out on every
  cold start.

### `apiFetch`

Server-only. Adds `X-API-Key`, the Cloud Run ID token in `X-Serverless-Authorization`, and the
bearer from the `access` cookie. With a `FormData` body it sets no `Content-Type`. On a 401 it
tells a **session** rejection from an **API-key** rejection (by the `detail`): a bad API key is
a deploy error and sending the user to the login would disguise it as "session expired". A
session 401 → `redirect("/session-expired")`, a **route handler** that clears the cookies and
redirects to `/login?sesion=vencida` (during render cookies cannot be deleted; without this step
the `user` cookie survives and login ↔ panel loop forever).

Every `fetch` to the api goes through a wrapper that retries **only if the connection never
opened** (cold start without egress ready); a request that left is never repeated.

### Server Actions

- `call(fn)` (server): turns an `ApiError` into `ActionResult`; **`unstable_rethrow(e)` first**
  in every `catch`, or the redirect thrown by `apiFetch` gets swallowed.
- `callAction(fn)` (browser): every action invoked from a handler or transition goes through
  it. A Server Action **throws** in the browser with no signal or when the tab is from an older
  deploy (action ids change per build); without the wrapper the spinner never stops
  `<form action>` / `useActionState` stay unwrapped so they work without JS.
- Login/signup/reset call the api with API key + ID token and **no** JWT; on success
  `setSession(...)` then `redirect(...)` (`new` → onboarding).
- **Logout** (see "Do not copy"): call `POST /auth/logout` with the refresh cookie, *then*
  clear the cookies and redirect — clear them even if the api call fails.

### Google button

- The client id comes down as a **prop from the Server Component**
  (`process.env.GOOGLE_OAUTH_CLIENT_ID`), never `NEXT_PUBLIC_`: those are frozen at build time
  and this must be changeable with a redeploy. Empty → renders nothing, password login still
  works.
- Load `https://accounts.google.com/gsi/client` once;
  `initialize({client_id, callback, use_fedcm_for_button: true, auto_select: false})`.
- **What the user sees is our own outline button** with the official "G" (unaltered, per
  Google's brand rules). Google's real button is rendered on top, **invisible and stretched**
  with a CSS `scale` to cover ours, because the ID token is only delivered from Google's own
  button or One Tap. Re-stretch with a `ResizeObserver`.
- The callback hands `response.credential` to the Server Action; **the front never validates
  the token**.
- One Tap (`prompt()`) once per page load — Google throttles sites that ask repeatedly.
- GIS gives no "popup open" event: poll `document.hasFocus()` + focus inside the overlay every
  300 ms to show "Entrando…" and freeze the form (`inert`) meanwhile.
- The admin copy has no One Tap, and hides the "o" separator when Google-only.

### Screens

Dashboard: `/login`, `/signup` (form → "Revisá tu mail" code step in the same component, resend
every 60 s), `/forgot`, `/reset?token=`, `/session-expired`. The panel layout guards by the
`user` cookie; "already logged in" on `/login` and `/` must use the **same** condition as the
guard or they loop.

Admin: `/login` first asks `GET /auth/admin/access` and draws only the Google button when
`google_only`; if the api does not answer it draws the normal form (the api decides anyway).
After a password login the action requires `role === "superadmin"` and answers a regular user
with the **same** message as a wrong password. "Mi cuenta" holds the switch, behind a
confirmation sheet, and does not offer it if the admin itself lacks the client id.

## Configuration

| Service | Secrets (Secret Manager) | Env |
|---|---|---|
| api | `API_KEY`, `JWT_SECRET`, `SUPERADMIN_PASSWORD` (seed only), mail credentials | `SUPERADMIN_EMAIL`, `GOOGLE_OAUTH_CLIENT_ID`, `DASHBOARD_URL`, `ADMIN_URL`, DB |
| dashboard | `API_KEY` | `BACKEND_URL`, `GOOGLE_OAUTH_CLIENT_ID`, `PUBLIC_URL` |
| admin | `API_KEY` | `BACKEND_URL`, `GOOGLE_OAUTH_CLIENT_ID` |

Only the api reads `JWT_SECRET`. `GOOGLE_OAUTH_CLIENT_ID` is not a secret: one CI variable shared
by the three deploys. Generate `API_KEY` / `JWT_SECRET` with `openssl rand -base64 48`.

Tunables (defaults): access 15 min · refresh 14 days · refresh grace 30 s · reset link 30 min ·
login 8 attempts / 15 min · reset mail 1 per 60 s · signup code 15 min, 5 attempts, resend 60 s.

**Google Cloud Console** (do it by hand, once): OAuth consent screen, then **one** OAuth client
of type *Web application* with **Authorized JavaScript origins** = the dashboard origin **and**
the admin origin (without the admin's, its button errors on origin). No redirect URIs, no
client secret. To test Google locally add the `http://localhost:<port>` origins; otherwise
leave the client id empty in local/e2e.

## Decisions that matter

- **No verified mail, no account.** Password signup creates nothing until the code is entered.
  Google needs no code: Google already verified the mail.
- **No existence oracles.** Login throttles unknown emails too; reset always answers 204; the
  admin answers a regular user like a wrong password.
- **Mail is sent inside the request**, not in a background task: with `--cpu-throttling` Cloud
  Run gives no CPU after the response and the mail may never leave.
- **Cookies are host-only** so the admin and the dashboard are separate sessions.
- **Admin has no impersonation**: support happens by looking at the account from the admin,
  never by becoming the user.
- **Disable, never delete, from the admin.** Disabling marks the user, revokes every refresh
  token and refuses to disable the superadmin (409). Deletion is the user's own action.

## Do not copy (where this recipe differs from the reference on purpose)

- **Logout does not revoke anything server-side** in the reference: the action only deletes
  cookies and the refresh token stays valid until it expires. Here `POST /auth/logout` takes
  the refresh token, verifies it and revokes **that jti** (not all — logging out on the phone
  must not log out the laptop), and the action calls it before clearing cookies.
- **`refresh_tokens` grows forever** in the reference (no expiry field, no TTL). Here every
  document carries `expires_at` = the token's `exp` and the collection has a TTL index.
- The reference's `POST /auth/logout` and `GET /auth/me` exist but nothing calls them. Do not
  add endpoints no front uses.
- The signup-code HMAC is keyed with `JWT_SECRET`: rotating it invalidates pending codes. Fine,
  but know it; or give it its own secret.
- `/auth/google`, `/auth/admin/google` and `/auth/signup` have no throttle of their own beyond
  the 60-s resend. If signup abuse is a concern, add a per-IP bucket (candidate module "rate
  limit").
- A regular user who tries their password on the admin login gets a token pair issued and
  discarded. Harmless; to avoid it give the admin its own login endpoint that checks the role
  before issuing, as Google already has.
- Turning `google_only` on does not close sessions already open. Decide whether it should.
- `web-admin/.env.example` in the reference still says "Admin: sin login con Google" and lacks
  `GOOGLE_OAUTH_CLIENT_ID`. The code is right; the example is stale.
- There is no "change password while logged in" nor "change email" in the reference: the only
  path is the reset link. Add them only if the product needs them.

## Tests

Api (real DB): signup → wrong code (attempts left) → right code → logged in; resend wait;
login throttle reaching 429 and clearing on success; refresh rotation, the 30-s grace and reuse
killing all sessions; Google login creating / linking (mock `verify_id_token`); admin Google
refusing a regular user; the Google-only interlock (409 without `google_sub`), login 403 and
reset refusal once on; disable cutting a live access token; logout revoking only that token.

e2e: signup with the code read from the api log, login, session-expired redirect, admin login
refusing a regular user, the "Me olvidé la contraseña" round trip.

## Checklist

- [ ] Emails lowercased in the repo on every path.
- [ ] Refresh consume is one atomic update; grace window honours `revoked`.
- [ ] Renewal is in `proxy.ts` only; `apiFetch` never refreshes.
- [ ] Proxy distinguishes "rejected" from "no answer"; de-duplicates by token; matcher covers actions.
- [ ] `unstable_rethrow` first in every server `catch`; browser calls go through `callAction`.
- [ ] `/session-expired` route handler exists and the login guard matches the panel guard.
- [ ] Signup creates nothing before the code; code stored as HMAC; confirm is atomic.
- [ ] Login throttle counts before checking the password, for unknown emails too.
- [ ] Reset always 204, one-use token, revokes sessions on confirm.
- [ ] `/auth/admin/google` never creates; admin action re-checks the role.
- [ ] Google-only refuses without a linked Google account and a configured client.
- [ ] Logout revokes the refresh token server-side; `refresh_tokens` has a TTL.
- [ ] Both origins registered in the OAuth client; client id passed as a prop, not `NEXT_PUBLIC_`.
