# Module: sugerencias — floating feedback button

A round floating button in the logged-in dashboard. The user taps it, picks **"Algo anda mal"**
or **"Tengo una idea"**, writes a few lines and optionally attaches photos — including a
screenshot of what they are looking at, taken in one tap with no browser permission. It lands in
an inbox in the admin, with an unread counter in the menu, where the superadmin marks it
resolved and leaves an internal note.

Reference: a production project. Versions below are the ones it used at the time of writing.

## Depends on

- **`login`**: a JWT-authenticated user and a tenant resolved from the JWT.
- **`superadmin`**: the admin app, its superadmin guard and its menu (the inbox is one more item).
- A private file store (GCS bucket in prod, local disk in dev). The minimum is described below;
  if the app has no storage yet, this module adds it.
- From `ui-design`: a bottom-sheet/modal (`Hoja`/`Sheet`), `Button`, `Textarea`, toasts.

## Choices (ask, default first)

1. **Photos?** yes, up to 5 **(default)** · text only (drops storage, Pillow, snapdom and the
   body-size change; the module becomes much smaller).
2. **Where is the button hidden?** nowhere **(default)** · on full-screen flows where it covers
   a fixed action bar (the reference hides it inside its editor).
3. **Who can send when the plan/trial is over?** everyone with an account **(default — that is
   exactly when they may need to tell you something)** · only active accounts.
4. **Tell the user when it is resolved?** no **(default; the inbox is internal)** · yes, by
   mail (that is the "close-the-loop" candidate module, needs `mail`).

## Data model

Collection `reports`.

| Field | Type | Rule |
|---|---|---|
| `_id` | str UUID4 | Generated in the function, **before** saving photos: it also names the storage folder. |
| `account_id` | str | From the JWT's tenant. Never from the request. |
| `user_id`, `email` | str | From the JWT's user. `email` is a snapshot. |
| `account_name` | str | Snapshot of the tenant's name, so the inbox needs no join. |
| `kind` | `"problem"` \| `"suggestion"` | |
| `text` | str | Stripped, 3–4000 chars. |
| `screen` | str | `location.pathname + search`, truncated to 300. |
| `browser` | str | `navigator.userAgent`, truncated to 400. |
| `viewport` | str | `"390×844 @3x"`, truncated to 40. |
| `photos` | list of `{ref, content_type, bytes}` | `ref` is the storage reference. Up to 5. |
| `status` | `"new"` \| `"seen"` \| `"resolved"` | Born `"new"`. |
| `note` | str | Internal admin note, ≤ 2000. Born `""`. |
| `created`, `updated` | datetime UTC | |
| `seen_at` | datetime, optional | Set the first time it is opened. |
| `resolved_at` | datetime \| None | Set on `resolved`; **any other status change clears it**. |

Indexes:
- `(status ASC, created DESC)` — inbox and the unread counter.
- `(account_id ASC, created DESC)` — daily cap and account purge.

Storage path: `reports/<account_id>/<report_id>/<i><ext>`.

**The storage `ref` never leaves the api.** Outward, `photos` becomes
`[{n, content_type, bytes}]` and each photo is fetched by number:

```python
def public(r: dict) -> dict:
    return {**{k: v for k, v in r.items() if k != "photos"},
            "photos": [{"n": i, "content_type": f["content_type"], "bytes": f["bytes"]}
                       for i, f in enumerate(r.get("photos") or [])]}
```

## Api

All routers carry the API key. Domain errors come out as `{"detail", "code"}`; the front shows
`detail` as is, so **write the messages for the end user**.

| Method + path | Auth | In | Out |
|---|---|---|---|
| `POST /reports` | JWT + tenant | multipart: `kind`, `text` required; `screen`, `browser`, `viewport` (default `""`); `photos` (files, repeatable) | 201 `{id, created}` |
| `GET /admin/reports` | superadmin | query `status?`, `kind?`, `page` (≥1) | `{items, total, page, new}`; 50 per page, newest first |
| `GET /admin/reports/new` | superadmin | — | `{new}` (menu counter) |
| `GET /admin/reports/{id}` | superadmin | — | the report. **Side effect: marks it seen.** |
| `PATCH /admin/reports/{id}` | superadmin | `{status?, note?}` | the report. 422 if nothing to change |
| `GET /admin/reports/{id}/photos/{n}` | superadmin | — | bytes, `Cache-Control: private, max-age=3600` |

Declare `/admin/reports/new` **before** `/admin/reports/{id}` or FastAPI routes "new" as an id.

The user has **no GET**: they do not see their reports nor their status.

### Create — router

Read at most `MAX_PHOTO + 1` bytes of the first `MAX_PHOTOS + 1` files: memory stays bounded
and the function can still tell "too many" and "too big" apart.

```python
@router.post("", status_code=201)
async def create(
    kind: str = Form(...), text: str = Form(...),
    screen: str = Form(""), browser: str = Form(""), viewport: str = Form(""),
    photos: list[UploadFile] = File(default=[]),
    account: Account = Depends(get_account),          # NOT get_active_account: see Choices 3
    user: User = Depends(get_current_user),
):
    data = [await f.read(reports.MAX_PHOTO + 1) for f in photos[: reports.MAX_PHOTOS + 1]]
    return await reports.create(account, user, kind=kind, text=text, screen=screen,
                                browser=browser, viewport=viewport, photos=data)
```

`kind` is a plain `str`, not a `Literal`: the 422 then carries the function's own message
instead of Pydantic's.

### Create — function (order matters)

```python
KINDS = ("problem", "suggestion")
STATUSES = ("new", "seen", "resolved")
MAX_TEXT, MAX_PHOTOS, MAX_PHOTO = 4000, 5, 8 * 1024 * 1024
MAX_PER_DAY, PER_PAGE = 20, 50

async def create(account, user, *, kind, text, screen, browser, viewport, photos: list[bytes]) -> dict:
    text = (text or "").strip()
    if kind not in KINDS:
        raise Invalid("Elegí si es un problema o una sugerencia.")
    if len(text) < 3:
        raise Invalid("Contanos un poco más.")
    if len(text) > MAX_TEXT:
        raise Invalid(f"El texto pasa de {MAX_TEXT} caracteres.")
    photos = [p for p in photos if p]
    if len(photos) > MAX_PHOTOS:
        raise Invalid(f"Hasta {MAX_PHOTOS} fotos por reporte.")
    if await reports_repo.count_since(account.id, _now() - timedelta(days=1)) >= MAX_PER_DAY:
        raise Conflict("Ya mandaste muchos reportes hoy. Probá mañana.")

    # Validate EVERY photo before saving the first one: no half-saved reports.
    ready: list[tuple[bytes, str, str]] = []
    for data in photos:
        if len(data) > MAX_PHOTO:
            raise Invalid("Una foto pesa más de 8 MB.")
        kind_of = file_type(data)                       # by magic bytes, not by what the browser says
        if kind_of is None or kind_of[0] == "application/pdf":
            raise Invalid("Las fotos tienen que ser JPG, PNG, WEBP o HEIC.")
        content_type, ext = kind_of
        if content_type == "image/heic":
            try:
                data = await run_in_threadpool(heic_to_jpg, data)
            except (UnidentifiedImageError, OSError, ValueError):
                raise Invalid("No pudimos leer una de las fotos. Probá con una captura de pantalla.")
            content_type, ext = "image/jpeg", ".jpg"
        ready.append((data, content_type, ext))

    report_id = str(uuid.uuid4())
    saved = []
    for i, (data, content_type, ext) in enumerate(ready):
        ref = await storage.save(f"reports/{account.id}/{report_id}/{i}{ext}", data, content_type)
        saved.append({"ref": ref, "content_type": content_type, "bytes": len(data)})
    now = _now()
    r = await reports_repo.create({
        "id": report_id, "account_id": account.id, "user_id": user.id, "email": user.email,
        "account_name": account.name, "kind": kind, "text": text, "screen": (screen or "")[:300],
        "browser": (browser or "")[:400], "viewport": (viewport or "")[:40], "photos": saved,
        "status": "new", "note": "", "created": now, "updated": now,
    })
    return {"id": r["id"], "created": r["created"]}
```

### Image helpers (put them in their own `functions/images.py`)

In the reference they live inside the payments module for historical reasons; a new app gets a
dedicated module.

```python
_HEIF_BRANDS = {b"heic", b"heix", b"hevc", b"hevx", b"heim", b"heis", b"mif1", b"msf1"}

def file_type(data: bytes) -> tuple[str, str] | None:
    if data[4:8] == b"ftyp" and data[8:12] in _HEIF_BRANDS: return "image/heic", ".heic"
    if data[:3] == b"\xff\xd8\xff":                          return "image/jpeg", ".jpg"
    if data[:8] == b"\x89PNG\r\n\x1a\n":                     return "image/png", ".png"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":        return "image/webp", ".webp"
    if data[:5] == b"%PDF-":                                 return "application/pdf", ".pdf"
    return None

def heic_to_jpg(data: bytes) -> bytes:
    """Chrome and Android do not render HEIC. Applies camera rotation, drops EXIF (may hold location)."""
    with Image.open(io.BytesIO(data)) as im:
        rgb = ImageOps.exif_transpose(im).convert("RGB")
    out = io.BytesIO(); rgb.save(out, "JPEG", quality=85)
    return out.getvalue()
```

Needs `pillow`, `pillow-heif` (call `pillow_heif.register_heif_opener()` once at import) and
`python-multipart`. Reference versions (re-verify): pillow 12.3.0, pillow-heif 1.7.0,
python-multipart 0.0.32, google-cloud-storage 3.14.1 — re-verify.

### Storage (minimum)

Three functions; a reference is `gs://bucket/path` in prod or `local:path` in dev. The bucket is
**private** — nothing is served straight from GCS.

```python
async def save(path: str, data: bytes, content_type: str) -> str   # returns the ref
async def read(ref: str) -> bytes
async def delete_prefix(prefix: str) -> None                        # for the account purge
```

Settings: `gcs_bucket` (empty = local) and `local_storage_dir`. GCS calls are blocking: wrap
them in `run_in_threadpool`.

### Admin operations

```python
async def mark_seen(report_id):      # atomic: only from "new" — a resolved one never goes back to seen
    await db.reports.update_one({"_id": report_id, "status": "new"},
                                {"$set": {"status": "seen", "seen_at": now, "updated": now}})

async def update(report_id, status, note):
    fields = {}
    if status is not None:
        if status not in STATUSES: raise Invalid("Estado inválido.")
        fields["status"] = status
        fields["resolved_at"] = _now() if status == "resolved" else None
    if note is not None:
        fields["note"] = note.strip()
    if not fields: raise Invalid("No hay nada para cambiar.")
    ...
```

Transitions: `new → seen` is automatic on open. `→ resolved` and `resolved → seen` ("Reabrir")
go through PATCH. There is no reply to the user, assignment, priority, deletion or search.

### Hook into account deletion

If the app deletes/purges tenants, add `reports` to the list of collections purged **and**
`reports/<account_id>/` to the storage prefixes deleted. Easy to forget; a test should cover it.

## Dashboard

### Server Action

Re-checks the caps, builds a **new** `FormData` with only the known fields (never forwards the
browser's as is) and calls the api. With `FormData`, `apiFetch` must **not** set `Content-Type`.

```ts
"use server";
const MAX_PHOTOS = 5, MAX_PHOTO = 8 * 1024 * 1024;

export async function sendReport(formData: FormData): Promise<ActionResult<{ id: string }>> {
  const photos = formData.getAll("photos").filter((f): f is File => f instanceof File && f.size > 0);
  if (photos.length > MAX_PHOTOS) return { ok: false, error: `Hasta ${MAX_PHOTOS} fotos por reporte.` };
  if (photos.some((f) => f.size > MAX_PHOTO)) return { ok: false, error: "Una foto pesa más de 8 MB." };
  const body = new FormData();
  for (const k of ["kind", "text", "screen", "browser", "viewport"]) body.set(k, String(formData.get(k) ?? ""));
  photos.forEach((f) => body.append("photos", f));
  return call(() => apiFetch<{ id: string }>("/reports", { method: "POST", body }));
}
```

**Raise the Server Action body limit** in `next.config.ts` or Next cuts uploads at 1 MB:
`experimental.serverActions.bodySizeLimit: "12mb"` and
`experimental.proxyClientMaxBodySize: "12mb"`. The admin does not need it.

### Screenshot and compression (`lib/capture.ts`, client-only)

**The page draws itself** with `@zumer/snapdom` (MIT; 3.1.0 in the reference). Why not the
system capture: `getDisplayMedia` does not exist in any mobile browser, and the dashboard is
used mostly on phones. No permission dialog. Loaded with a dynamic `import()` so it costs
nothing until used.

```ts
export async function captureScreen(): Promise<File> {
  const { snapdom } = await import("@zumer/snapdom");
  const blob = await snapdom.toBlob(document.body, {
    clip: "viewport", format: "jpg", quality: 0.85,
    backgroundColor: getComputedStyle(document.body).backgroundColor || "#ffffff",
    dpr: Math.min(window.devicePixelRatio || 1, 2),
    excludeMode: "remove",
  });
  return new File([blob], `pantalla-${Date.now()}.jpg`, { type: "image/jpeg" });
}
```

Everything that must not appear in the screenshot — the button, the sheet and the dialog —
carries **`data-capture="exclude"`**.

`compress(file)`: `createImageBitmap(file, {imageOrientation: "from-image"})`, longest side
2000 px, **white background** (a transparent PNG would turn black as JPG), JPG 0.85. If the
browser cannot open it (HEIC in Chrome) or the result is not smaller, send the original — the
api converts it.

### The component

Build it from the points below; the parts that are easy to get wrong:

- **Button**: 52 px round, bottom-right, `z-[35]`, **no solid fill** (surface + border + accent
  icon) — the only solid fill on a screen is the accent. `aria-label` and `title`.
- **It floats above fixed bottom bars on its own.** `useBottomBarHeight()` measures every
  `.safe-footer` (the convention for a fixed bar glued to the bottom) and lifts the button
  `height + 12 px`. Re-measure on `MutationObserver` + `resize`, and **again 450 ms later**:
  bars enter with the page animation and, with a `transform` on an ancestor, `fixed` is not
  glued to the viewport until the animation ends.
- **Main content needs `pb-24`** so the button never covers the last row.
- **Sheet**: two radio cards (`role="radiogroup"`), a textarea whose label and placeholder
  change with the kind, photo thumbnails with an X, "Capturar pantalla" and "Subir fotos"
  (`accept="image/*,.heic,.heif"`, `multiple`), and **Ctrl+V** of an image on desktop.
- Say what is collected: *"Con el reporte nos llega en qué pantalla estás y desde qué navegador."*
- **No-photo dialog**: tapping "Enviar" with no photo opens an `alertdialog` "¿Lo mandás sin
  foto?" with **"Capturar pantalla y enviar"** (primary), "Elegir una foto" and "Enviar sin
  foto". This one dialog is what makes most reports arrive with a screenshot.
- **Layers**: button `z-[35]`, sheet `z-50`, dialog `z-[55]`. The dialog listens to Esc **in
  the capture phase with `stopPropagation`**, or Esc closes the sheet behind it too.
- Previews are object URLs: revoke them on remove, on send and on unmount.
- Total weight cap of **10 MB in the browser** (the 12 MB action limit minus headroom), with a
  message that says what to do: *"Las fotos pesan mucho juntas: sacá alguna y probá de nuevo."*
- Context sent: `location.pathname + location.search`, `navigator.userAgent`,
  `` `${innerWidth}×${innerHeight} @${devicePixelRatio}x` ``.
- Call the action through the browser-side wrapper (`callAction`) so "no signal" and "stale
  deploy" come back as an error instead of a spinner that never ends.
- On success: toast *"¡Gracias! Lo recibimos"*, reset, close. On failure: the api's message
  stays inline in the sheet.

Mount it in the shell of the logged-in area only — never on public pages, login or onboarding.

## Admin

- **Menu**: item "Reportes" with a counter of unread (`99+` cap). The layout fetches it once
  (if the api fails it is `0`, never breaks the panel); the client shell **re-fetches on every
  `pathname` change**, because App Router layouts do not re-render on navigation and opening a
  report changes the count.
- **Inbox** `/reports`: status chips (Todos / Sin ver / Vistos / Resueltos) and kind chips, both
  as links with query string; cards with kind, status, relative date, text clamped to 2 lines,
  account name, email, photo count. Unread cards get the accent border. Pagination.
- **Detail** `/reports/[id]`: full text, photo grid (each opens in a new tab), screen /
  viewport / browser, and a link to the account.
- **Photos**: `<img src="/reports/<id>/photos/<n>">` hits a **route handler** in the admin that
  validates `id` (`/^[0-9a-f-]{36}$/`) and `n` (`/^\d{1,2}$/`), fetches the raw response from
  the api with the session, and answers with `Cache-Control: private, max-age=3600`,
  `X-Content-Type-Options: nosniff`, `Content-Disposition: inline`.
- **Manage**: "Marcar resuelto" sends `{status: "resolved", note}`; "Reabrir" sends
  `{status: "seen"}`; "Guardar nota" sends `{note}` and is enabled only if it changed. The
  action calls `revalidatePath("/reports", "layout")`.

## Limits

| Rule | Value | Enforced in |
|---|---|---|
| Text | 3–4000 chars after strip | api; front (`maxLength`, inline error) |
| Photos per report | 5 | api; action; front |
| Weight per photo | 8 MB | api; action |
| Total weight | 10 MB | front only |
| Server Action body | 12 MB | `next.config.ts` |
| Formats | JPG, PNG, WEBP, HEIC by bytes; PDF rejected | api |
| Daily cap | 20 per account, rolling 24 h | api (409) |
| Context | screen 300, browser 400, viewport 40 (truncated, not rejected) | api |
| Internal note | 2000 | api; front |
| Admin page size | 50 | api |

## Decisions that matter

- **No mail, only a counter.** The inbox is checked from the admin. A mail per report trains
  you to ignore them.
- **Accept reports from accounts whose plan ended** — that is when they most want to say
  something.
- **Daily cap per account** exists so a bug in a front cannot fill the storage, not to punish
  users. It counts reports in any status and is checked before touching the photos.
- **Opening marks as seen**, atomically and only from `new`.
- **The screenshot is offered, never automatic.** The user sees it as a thumbnail before it is
  sent and can remove it.
- **The api decides the file type by bytes**; the browser's MIME type is ignored.
- **`email` and `account_name` are snapshots**: the inbox shows who they were when they wrote.

## Do not copy

- **Orphan photos**: the reference saves photos and then inserts the document, with no cleanup
  if the insert fails. In a new app, wrap the insert in `try/except` and `delete_prefix` the
  report's folder on failure.
- **Page size written twice**: the admin page hard-codes `50` to compute the page count. Return
  `per_page` (or `pages`) from the api instead.
- **Metadata**: HEIC conversion drops EXIF, but JPG/PNG/WEBP are stored as they arrive (with
  location if the phone put it there). If that matters for the product, re-encode everything.
- The `GET` that marks as seen has a side effect. It is deliberate (one request instead of
  two), but do not prefetch that route: set `prefetch={false}` on the inbox links.
- The reference e2e still expects the button inside the editor, where it
  was later hidden. Write the new app's e2e from the flow, not from that file.
- Screenshot with snapdom was **not verified on iPhone Safari** in the reference (still an open
  item there). Test it there; "Elegir una foto" is the fallback either way.

## Tests

Api (real DB), at least:
1. Create with photos (one HEIC) → admin lists it → detail marks seen → resolve → reopen → photo
   bytes come back with their content type.
2. Validation: bad kind, short/long text, 6 photos, photo > 8 MB, a PDF, the 21st of the day
   (409).
3. An account with its plan ended can still send; purging the account deletes its reports and
   its storage folder.

e2e at 390 px: send with a captured screenshot, send without photo through the dialog, and the
admin counter going down when the report is opened.

## Checklist

- [ ] `reports` collection + the two indexes created at startup.
- [ ] Create validates all photos before saving any; tenant and user from the JWT.
- [ ] Storage private; `ref` never in a response; photos served by number.
- [ ] `/admin/reports/new` declared before `/admin/reports/{id}`.
- [ ] Server Action body limit raised to 12 MB in the dashboard.
- [ ] Button has no solid fill, lifts above `.safe-footer` bars, and is excluded from the capture.
- [ ] Esc on the no-photo dialog does not close the sheet behind.
- [ ] Admin counter re-fetched on navigation; photo route validates `id` and `n`.
- [ ] Reports and their storage folder removed when the tenant is purged.
- [ ] Insert failure cleans up the saved photos.
