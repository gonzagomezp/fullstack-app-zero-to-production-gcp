# Module: mail — transactional email

One `send_email` in the api that **never raises**, so a mail that fails cannot break the request
that triggered it. Every mail goes through one HTML shell (brand + box + button), carries a
plain-text twin, and is sent **inside** the request. Without SMTP credentials the mail is written
to the log instead (that is how the signup code is read in development). Optionally, a
**marketing** category that respects an opt-out and carries a one-click unsubscribe.

Reference: three production projects — **project A** (transport, location, templates),
**project C** (`send_email` that never raises, multi-provider) and **project B** (categories +
unsubscribe, in TypeScript: ported to Python here).

## Depends on

- Nothing for transactional-only. **`login` depends on this module**, not the other way round.
- Marketing only: `login` (the opt-out is a field on `users`) and a **public** Next app (the
  dashboard) for the unsubscribe URL, because the api is internal.
- Outbound internet from the service that sends. The reference api runs **without** VPC egress for
  this reason: its fronts use all-traffic VPC egress with no Cloud NAT and reach only `*.run.app`.

## Choices (ask, default first)

1. **Provider.** AWS SES over SMTP **(default; stdlib only, no package)** · Resend HTTP API
   (project C's preferred, project B's only one) · SES HTTP API with boto3 · any SMTP server. Only
   `_deliver` and the settings change.
2. **Marketing mails?** no, transactional only **(default — drops the token, the opt-out field,
   both endpoints, the dashboard page and the headers)** · yes.
3. **Sender and domain.** `Name <avisos@domain>` on the product's own domain **(default, as the
   reference)**. Ask the address, the display name, and whether replies are read (`reply_to`).
4. Marketing only — **token secret**: a dedicated `EMAIL_TOKEN_SECRET` **(default)** · reuse the
   JWT secret (what project B does with `AUTH_SECRET`; rotating it kills every link already mailed).
5. Marketing only — **`mailto:` in `List-Unsubscribe`**: no **(default)** · yes, only if someone
   processes that mailbox (project B adds one; nothing in its code reads it).

## Outside the code

Documented in project A (SES):

- **Identity**: SES → Identities → Domain, Easy DKIM (RSA 2048), in the **same region as the SMTP
  credentials** (SES SMTP credentials are valid for one region; identities are per region).
- **DNS**: the 3 DKIM CNAMEs SES shows (`<token>._domainkey` → `<token>.dkim.amazonses.com`) as
  DNS-only records (this is about these records, not the app's hostnames), and a recommended TXT
  `_dmarc` = `v=DMARC1; p=none;`. "Custom MAIL FROM" left unset.
- **Account**: out of the SES sandbox; the IAM user behind the SMTP credentials allowed
  `ses:SendRawEmail` on the new identity. Bounces and complaints count against the **whole AWS
  account's** reputation when it is shared with another product.
- **Secrets** (Secret Manager): `smtp-user`, `smtp-password` (`ses-smtp-*` in the reference);
  marketing adds `email-token-secret`. The deploy workflow mounts the SMTP pair **only if it has
  an enabled version** (the deployer has `secretmanager.viewer`): a placeholder would make the
  api believe mail is configured.
- **Env**: the workflow sets only the SMTP host; port and `EMAIL_FROM` are `settings.py` defaults.
- **Port 587**: per the reference, Google Cloud blocks outbound 25 and not 587.

Not documented in any of the three projects — **verify with the provider's docs**, do not guess:
SPF records; DMARC alignment and any policy stricter than `p=none`; bounce/complaint handling
(no reference has any); whether the provider DKIM-signs `List-Unsubscribe` and passes it through
untouched over SMTP; Resend's domain setup; sending quotas.

Status of the reference when read: its docs still listed "verify the domain in SES and send a
real one" as pending. The SMTP path is covered by tests against a fake server, **not by a
confirmed real delivery**.

## Data model

Transactional only: **nothing**. No collection, no send log, no queue.

Marketing adds one field to `users`:

| Field | Type | Rule |
|---|---|---|
| `marketing_opt_out_at` | datetime UTC \| None | Set on unsubscribe, **never overwritten** (it says since when). `None` on undo. |

No new index: lookups go by the unique `users.email`, stored lowercased (project A lowercases
on write and on lookup; project B stores as typed and lowercases both sides of every comparison).

```python
async def marketing_opted_out(email: str) -> bool:
    u = await db.users.find_one({"email": email.strip().lower()}, {"marketing_opt_out_at": 1})
    return bool(u and u.get("marketing_opt_out_at"))

async def opt_out_marketing(email: str) -> None:      # atomic + idempotent: keeps the first date
    await db.users.update_one({"email": email, "marketing_opt_out_at": None},   # None matches "missing" too
                              {"$set": {"marketing_opt_out_at": _now()}})

async def opt_in_marketing(email: str) -> None:
    await db.users.update_one({"email": email}, {"$set": {"marketing_opt_out_at": None}})
```

## Api

Everything lives in `functions/emails.py`, **the only module that knows the provider**.

```python
# settings.py
smtp_host: str = "email-smtp.us-east-1.amazonaws.com"   # region of the SMTP credentials
smtp_port: int = 587                                     # STARTTLS
smtp_user: str = ""          # user or password empty = dev mode: mails go to the log
smtp_password: str = ""
email_from: str = "Producto <avisos@producto.com.ar>"
email_token_secret: str = ""                             # marketing only
```

### `send_email`

```python
Category = Literal["transactional", "marketing"]

@dataclass
class SendResult:
    ok: bool
    detail: str = ""
    skipped: str | None = None            # "opted_out"

async def send_email(to: str, subject: str, body_html: str, *,
                     category: Category = "transactional", reply_to: str | None = None) -> SendResult:
    """Never raises. Await it inside the request. `body_html` is what goes inside the shell."""
    try:
        headers, footer = {}, ""
        if category == "marketing":
            if await users_repo.marketing_opted_out(to):
                return SendResult(True, "opted out", skipped="opted_out")
            headers, footer = _unsubscribe(to)             # raises without the token secret
        content = _shell(body_html, footer)
        if not (settings.smtp_user and settings.smtp_password):
            logger.info("EMAIL (dev, not sent) to=%s subject=%s\n%s", to, subject, _text(content))
            return SendResult(True, "logged")
        await run_in_threadpool(_deliver, _message(to, subject, content, headers, reply_to))
        return SendResult(True, "sent")
    except Exception as exc:
        logger.exception("email to %s (%s) failed", to, subject)
        return SendResult(False, str(exc))

def _message(to, subject, content, headers, reply_to) -> EmailMessage:
    msg = EmailMessage(policy=policy.SMTP.clone(max_line_length=998))   # see Decisions
    msg["From"] = settings.email_from          # an accented display name encodes itself
    msg["To"], msg["Subject"] = to, subject
    if reply_to: msg["Reply-To"] = reply_to
    for k, v in headers.items(): msg[k] = v
    msg.set_content(_text(content))
    msg.add_alternative(content, subtype="html")
    return msg

def _deliver(msg: EmailMessage) -> None:       # blocking: smtplib
    with smtplib.SMTP(settings.smtp_host, settings.smtp_port, timeout=20) as smtp:
        smtp.starttls(context=ssl.create_default_context())    # before login, always
        smtp.login(settings.smtp_user, settings.smtp_password)
        smtp.send_message(msg)
```

Three ways to call it — the result is for the caller that cannot go on without the mail:

| Caller | On `ok == False` |
|---|---|
| Must arrive (signup code) | 503 *"No pudimos mandarte el mail. Probá de nuevo en un rato."* |
| No oracle (password reset request) | nothing: always 204, whether the email exists or not |
| Notification after a state change | nothing: the change is already saved and stands |

Call it as `emails.send_email(...)` (module attribute), never `from .emails import send_email`:
project C imports the name and its tests have to patch it at two import sites.

### Shell, button, plain text

Inline styles only. The brand is **text**, so there is no image to host (project C uses an `<img>`
served from the dashboard's `public/`). All values come from the product's brand tokens.

```python
def _shell(body_html: str, footer_html: str = "") -> str:
    return f'<div style="{_BOX}">{_BRAND}{body_html}{footer_html}</div>'

def button(href: str, label: str) -> str:
    return f'<p><a href="{html.escape(href, quote=True)}" style="{_BUTTON}">{html.escape(label)}</a></p>'

def _text(content: str) -> str:              # links survive as "label: url"
    t = re.sub(r"<a [^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>", r"\2: \1", content, flags=re.S)
    t = re.sub(r"<br\s*/?>|</p>|</div>", "\n", t)
    t = html.unescape(re.sub(r"<[^>]+>", "", t))
    return re.sub(r"\n\s*\n+", "\n\n", "\n".join(l.strip() for l in t.splitlines())).strip()
```

Reference styles: `_BOX` white, 520 px, 32 px padding, 20 px radius, 1 px border; `_BUTTON` accent
fill, white text, 14×22 px padding, 14 px radius, weight 600; `_SMALL` 13 px muted; `_MONO` for
codes and amounts.

### Templates

One function per mail, in the same module, each `return await send_email(...)`. **`html.escape`
every value a person typed** (names, messages, reasons). What `login` needs:

- `send_signup_code(to, code)` — subject `"{code} es tu código de {App}"` (readable from the
  notification). Body: *"Este es el código para crear tu cuenta de {App}:"*, the code at 34 px
  mono with `letter-spacing:0.2em`, and small: *"Vence en {n} minutos. Si no fuiste vos, ignorá
  este mail: sin el código no se crea ninguna cuenta."*
- `send_password_reset(to, token, admin=False)` — subject *"Elegí una contraseña nueva"*. Body:
  *"Pediste cambiar tu contraseña de {App}."*, button *"Elegir contraseña nueva"* to
  `{base}/reset?token=…` (the route the `login` recipe defines; `/restablecer` in the
  reference), small: *"El link vence en {n} minutos y sirve una sola vez. Si no
  fuiste vos, ignorá este mail: tu contraseña sigue igual."* `admin=True` builds the link on the
  admin's URL: same token, landing where it was asked from.

A mail to someone who is **not** the product's user (a customer of the tenant) talks about the
tenant, not the product, and says why it arrived: *"Te llega porque dejaste este mail al pagar."*

### Marketing (only if chosen)

The difference is permission, not tone. **Transactional** answers something the user did or that
affects their account: always sent, even to someone who unsubscribed. **Marketing** is sent
because you want to: respects the opt-out and carries the link. When in doubt, marketing.

```python
def _sign(email: str) -> str:
    mac = hmac.new(settings.email_token_secret.encode(), f"unsubscribe:{email}".encode(), hashlib.sha256)
    return _b64(mac.digest())                       # _b64/_unb64: urlsafe base64 without padding

def make_unsubscribe_token(email: str) -> str:
    e = email.strip().lower()
    return f"{_b64(e.encode())}.{_sign(e)}"

def verify_unsubscribe_token(token: str) -> str | None:
    if not settings.email_token_secret:             # an empty key would sign anything for anyone
        return None
    head, _, sig = token.rpartition(".")
    try: email = _unb64(head).decode()
    except (ValueError, UnicodeDecodeError): return None
    same = hmac.compare_digest(_sign(email).encode(), sig.encode())   # bytes: str raises on non-ASCII
    return email if "@" in email and same else None

def _unsubscribe(to: str) -> tuple[dict, str]:
    if not settings.email_token_secret:
        raise RuntimeError("marketing mail without EMAIL_TOKEN_SECRET")
    t, base = make_unsubscribe_token(to), settings.dashboard_url.rstrip("/")
    headers = {"List-Unsubscribe": f"<{base}/api/unsubscribe?t={t}>",      # the endpoint, not the page
               "List-Unsubscribe-Post": "List-Unsubscribe=One-Click"}      # RFC 8058
    return headers, f'<p style="{_SMALL}">… <a href="{base}/unsubscribe?t={t}">Dar de baja estos avisos</a>. …</p>'
```

Footer copy: *"Recibís este mail porque tenés una cuenta en {App}. Dar de baja estos avisos. Los
avisos de tu cuenta y tus pagos los vas a seguir recibiendo."*

Endpoints (`routers/email.py`, API key, **no JWT**: the signature is the authorization — it can
only come from a mail sent to that inbox):

| Method + path | In | Out |
|---|---|---|
| `GET /email/unsubscribe` | query `t` | `{email}` · 400. **No side effect.** |
| `POST /email/unsubscribe` | `{t, undo?}` | `{ok, email, status: "unsubscribed" \| "subscribed"}` · 400 |

A valid token whose email has no user answers the same 200: for whoever clicked, the outcome is
the same.

## Dashboard (marketing only)

The public side, outside the session guard. Splitting it from the api is a consequence of the
internal api, **not something a reference has**: in project B everything is one Next app.

- **`app/api/unsubscribe/route.ts`** — `POST` forwards `t` and `undo=1` to the api and answers
  JSON 2xx (per project B, the mailbox provider's one-click sends no cookies and follows no
  redirects). **`GET` only redirects to `/unsubscribe?t=…` and never unsubscribes**: security
  scanners and mail-client prefetchers GET every URL in a mail.
- **`app/unsubscribe/page.tsx`** — `noindex`. Verifies the token through the api and shows the
  address. Opening the page changes nothing; the **button** does the POST. Idle: *"¿Dejamos de
  mandarte avisos?"* · *"Los mails de tu cuenta y de tus pagos los vas a seguir recibiendo: son
  parte del servicio."* · button *"Darme de baja"*. Done: *"Listo, te diste de baja"* + link
  *"Me equivoqué, volver a recibirlos"* (POST `undo=1`, same token) → *"Listo, seguís
  suscripto"*. Bad token: *"Este link no sirve"* · *"Puede estar cortado por el cliente de mail.
  Probá abrirlo desde el mail original, o escribinos y te damos de baja a mano."*

Admin: nothing.

## Limits

| Rule | Value | Where |
|---|---|---|
| SMTP timeout | 20 s (project C: 15 s) | `_deliver` |
| Connection | one per mail on 587 + STARTTLS; no pool, no retry | `_deliver` |
| Header line | 998 (the unsubscribe URL is never folded) | `_message` |
| Unsubscribe token | no expiry, no state | by design |

The resend cooldowns (signup code, reset link) live in `login`, not here. Packages: none for the
default (`smtplib`, `email`, `hmac` are stdlib; the reference image was `python:3.12.14-slim`).
Alternatives as project C declared them when read: `httpx>=0.27,<0.29` (Resend), `boto3>=1.34,<2`
(SES API) — re-verify.

## Decisions that matter

- **Sent inside the request, never in a background task.** Cloud Run is deployed with
  `--cpu-throttling`: CPU only while a request is being handled. A task left running after the
  response may never get CPU — the reference's password-reset mail used to go in the background
  and could simply not go out. Hence blocking `smtplib` in `run_in_threadpool`, **awaited**.
- **Never raises, but says whether it went out.** Approving, paying or deleting an account must
  stand even if the mail does not; the signup code is the opposite — without the mail the user is
  stuck, so that caller turns `ok == False` into a 503.
- **No credentials = log, and report success.** The flow keeps working in dev and the code is in
  the log. The app logger must be at INFO (Python shows WARNING and up by default; the reference
  hit exactly this).
- **SMTP rather than the provider's API**: the credentials already existed as SMTP
  credentials (the API would need separate IAM keys) and it adds no dependency.
- **Plain text next to the HTML, generated from it**, keeping the links: for clients without
  HTML and, per the references, because spam filters prefer it.
- **Unsubscribe token = HMAC of the lowercased email, no state, no expiry.** It must work with
  one click, months later, without a session; an expired unsubscribe link becomes a spam report.
- **The header points to the endpoint and the body carries a visible link too**: per project B,
  only some mail clients render the header.
- **If the opt-out check fails, the marketing mail is not sent.** Losing one is cheaper than
  mailing someone who asked not to be.
- **`max_line_length=998`.** With Python's default policy a long `List-Unsubscribe` URL is
  emitted as RFC 2047 encoded-words instead of the literal URL. Reproduced in a scratch script
  on Python 3.12.12, **not in any reference** (none sends this header through `smtplib`).

## Do not copy

- **Project A has no `send_email`**: its `_send` raises, and "never breaks the request" is a
  `try/except` + `run_in_threadpool` repeated at seven call sites. Put both inside `send_email`.
  Its failure paths (the 503, the swallowed notification) have **no test**.
- **Bulk inside one request**: its price-change notice mails every subscriber in a loop, one
  SMTP connection each, inside an admin request. Fine for tens; beyond that use a queue.
- **Missing credentials in production are silent**: codes and reset links go to Cloud Logging.
  Log a warning at startup when the SMTP pair is empty outside dev.
- Project C, with nothing configured, logs only `to` and `subject` and returns `False`: a code can
  never be read from its log. Its `_shell` appends *"Si no fuiste vos, podés ignorar este
  correo."* to **every** mail, payment failures and lead alerts included.
- Project C interpolates names, contacts and summaries **without escaping** in most templates; its
  sender setting is `smtp_from` although all three transports use it; and its emails module
  still says it sends through "SMTP / AWS SES" while the code prefers Resend.
- Project B's and project C's HTML→text **drop the link targets**: the text part of a link-only mail
  has no link. Use project A's `_text`.
- Project B without the secret sends the marketing mail **with no header and no footer**,
  silently. It answers *"Link inválido o vencido"* although its tokens never expire, has an
  `if (!ok)` branch identical to the success one, and `getMarketingOptOutAt` compares the email
  case-sensitively while the rest of the file lowercases. It has **no tests** for any of this.
- The opt-out lives on `users`: an address that is not a user cannot be opted out (the endpoint
  answers ok and stores nothing). If marketing goes to non-users, keep the opt-outs in their own
  collection keyed by lowercased email — not built in any reference.

## Tests

From the reference tests, with a fake `smtplib.SMTP` and nothing on the network:
1. Order is connect (host, 587) → `starttls` → `login` → send; `From` with an accented name round
   trips; the message has a text part (no `<`, link as `label: url`) and an HTML part.
2. No credentials: nothing connects and the log has `to=… subject=…`. `_text` keeps the links.
3. `conftest.py` replaces the signup-code sender with a capture (`email → last code`), so every
   other test can register.

New (no reference has them):
4. `_deliver` raising → `ok=False`, no exception; signup answers 503; the notified action stays.
5. Marketing: opted-out → `skipped="opted_out"`, nothing sent; failing opt-out check → not sent;
   the raw message contains the literal unsubscribe URL; transactional ignores the opt-out.
6. Token: round trip with mixed case and spaces; tampered, foreign, garbage and empty-secret
   tokens rejected. `GET` changes nothing; `POST` sets the date once; `undo` clears it.

## Checklist

- [ ] Provider, sender and marketing yes/no asked and recorded.
- [ ] Domain verified at the provider; DKIM + DMARC records in DNS; SPF checked in its docs.
- [ ] Secrets in Secret Manager, mounted only when they have a value; the service has egress.
- [ ] `send_email` never raises; the must-arrive caller checks `ok`.
- [ ] Every mail awaited inside the request; no background task.
- [ ] No credentials → logged, and the app logger is at INFO.
- [ ] Text part generated, links kept; user-typed values escaped.
- [ ] One real mail received in a real inbox, and its headers checked (DKIM pass).
- [ ] Marketing: fail-closed opt-out, header + visible footer link, `GET` never unsubscribes,
      undo works, raw `List-Unsubscribe` holds the literal URL.
