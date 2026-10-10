# Module: superadmin — admin panel base

The skeleton of the operator's panel: a separate Next.js app (`web-admin/`, its own Cloud Run
service and host) plus the `/admin/*` endpoints of the api. It gives the superadmin guard, the
shell with a menu and "sin ver" counters, a home with a few numbers, the accounts list and
detail, disable/enable an account, and "Mi cuenta". It carries no business of its own: **it is
where the other modules plug their inboxes and screens** (`sugerencias` adds "Reportes" with a
counter, `reclamos` adds "Reclamos", `suscripciones` adds plans and payments).

Reference: **project A**, variants from **project C**. Front versions
it used: Next 16.3.5, React 19.3.0, TypeScript 6.0.3, Tailwind 4.3.3, lucide-react 1.47.0,
google-auth-library 11.1.0 — re-verify.

**Business screens of the reference, not part of this module:** special plan, trial extensions,
gifted AI uploads, price freeze, plans and price adjustments, payments, MercadoPago reconcile.

## Depends on

- **`login`** — see the `login` module for the admin login screen (password or Google, the
  "solo Google" switch, the superadmin seeded from env). This panel needs four things from it:
  a `role` on the user with a `superadmin` value; `get_current_user`, which **reads the user
  from the DB on every request** and answers 401 if it is missing or disabled; the session
  cookies (`access`, `refresh`, `user`, httpOnly, **host-only**); and the renewal proxy.
- **`frontend-dashboard-next` + `ui-design`**: the server-side plumbing is the dashboard's,
  **copied, not shared** (each service is self-contained — a bug fixed in one is fixed in both).
  From the UI kit: `Button`, `Input`, `Checkbox`, bottom sheet (`Hoja`), toasts.
- **`deploy-gcp-cloudrun`**: one more public service in front of the internal api.

## Choices (ask, default first)

1. **Who administers?** one superadmin seeded from env **(default, project A)** · several
   admins with create/delete from the panel (project C, see Variants).
2. **What goes on the home?** total accounts and signups of the last 30 days **(default)**, plus
   whatever each installed module contributes (the reference adds MRR, paying/trial, cancelled
   subscriptions, its product activity and signups by `utm_source`). Ask which numbers they
   actually look at; do not fill the screen.
3. **Can the admin disable accounts?** yes **(default)** · no (read-only panel).
4. **Impersonation ("entrar como")?** no **(default)** · yes. The reference's decisions log scopes the admin to "operación
   + billing (sin impersonación…)": a screen for what was being done by hand. Neither reference has it (grepped both): choosing "yes" means designing
   it — a token minted for another user, an audit trail — not applying this recipe.
5. **Delete accounts from the admin?** no **(default: in project A deletion is the owner's own
   flow, the admin only disables)** · yes (project C: schedule / cancel / force with the name typed).
6. **Does the superadmin also own a tenant in the dashboard?** no **(default)** · yes
   (project A, same email enters both). The 409 guard below exists because of this.
7. **Operational jobs fired from the panel?** none **(default)** · yes, dry-run first (project C).

## Data model

No collection of its own. It reads and writes fields that `login` already owns:

| Collection | Field | Use |
|---|---|---|
| `users` | `role` | `"superadmin"` opens `/admin/*`. Read from the DB, **not** a JWT claim. |
| `users` | `disabled: bool` | Born `false`. The only thing "disable" writes. |
| `users` | `last_login: datetime \| None` | Written when a token pair is issued (login), not on refresh. Shown as "Último acceso". |
| `users` | `account_id`, `email`, `name`, `created` | Join account → its user. |
| `refresh_tokens` | `{_id: jti, user_id, valid, revoked}` | Disabling sets `valid: false, revoked: true` on all of the user's. |
| `accounts` | `name`, `created` | Search and order of the list. |

Indexes it relies on: `users.account_id`, `refresh_tokens.user_id`. The reference has none on
`accounts.created` (the list's sort); add it when the list grows.

## Api

| Method + path | In | Out |
|---|---|---|
| `GET /admin/metrics` | — | flat dict of numbers |
| `GET /admin/accounts` | `q?`, `page` (≥1) | `{items, total, page}`; 50 per page, newest first |
| `GET /admin/accounts/{id}` | — | `{account, user, …one key per module}`; 404 *"No existe esa cuenta."* |
| `POST /admin/accounts/{id}/disable` | `{value: bool}` | the account detail; 404 if the account has no user; **409** if `value` and the target is the superadmin |
| `GET` / `POST /admin/access` | — / `{value}` | how the admin logs in — owned by `login` |

Every row: API key + superadmin. A row of the list carries `id, name, email, disabled,
last_login, created` plus module columns; `user` in the detail is `{id, email, name, disabled,
last_login, created}` or `null`. Dump the account **excluding heavy fields** (the reference
drops the logo).

### The guard — once, at router level

```python
async def require_superadmin(user: User = Depends(get_current_user)) -> User:
    if user.role != "superadmin":
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Insufficient role")
    return user

# routers/admin.py
router = APIRouter(prefix="/admin", tags=["admin"], dependencies=[Depends(require_superadmin)])

# main.py — the API key goes on top, like on every router
app.include_router(admin.router, dependencies=[Depends(require_api_key)])
```

An endpoint that needs to know *who* (to record it) declares it again as a parameter
(`me: User = Depends(require_superadmin)`); the reference does that for its special plan
(`admin_email=yo.email`). No token → 401, wrong role → 403.

### Disable / enable

```python
async def set_disabled(account_id: str, value: bool) -> dict:
    u = await users_repo.get_by_account(account_id)
    if u is None:
        raise NotFound("La cuenta no tiene usuario.")
    if value and u.role == "superadmin":
        raise Conflict("Es tu propio negocio: deshabilitarlo te dejaría afuera del admin.")
    await users_repo.set_disabled(u.id, value)
    if value:
        await users_repo.revoke_all_refresh(u.id)
    return await account_detail(account_id)
```

It cuts everything at once: the access token may still have minutes left, but
`get_current_user` finds `disabled` on the next request and answers 401 (the fronts send that
to `/session-expired`). Login, refresh and password reset also refuse a disabled user — that
part lives in `login`. Enabling only flips the flag: the refresh tokens stay revoked, so they
log in again.

**Metrics**: one function returning a flat dict, the 30-day window computed once. A rate is
`None` when its denominator is 0, never 0. Each module adds its keys here and its tiles on the home.

## Admin app

Pages under `app/(panel)/`: `layout.tsx` (guard + first counters), `page.tsx` (home),
`accounts/`, `accounts/[id]/`, `me/` ("Mi cuenta"). Login screens sit outside the group and
belong to `login`. Reads go in `lib/data.ts` (server-only, called from Server Components); writes
are Server Actions that wrap the call (`call`), `revalidatePath` what they changed and return an
`ActionResult`; the browser invokes them through `callAction`. Root layout:
`robots: { index: false, follow: false }`.

### Layout guard

```tsx
export default async function PanelLayout({ children }: { children: React.ReactNode }) {
  const user = await getSessionUser();               // parses the httpOnly `user` cookie
  if (user?.role !== "superadmin") redirect("/login");
  return <Shell email={user.email} counts={await unseenCounts()}>{children}</Shell>;
}
```

This is UX, not security: the cookie is plain JSON. **The barrier is the api**, which checks the
role on every `/admin/*`. The login action also refuses a non-superadmin, with the same message
as a bad password (*"Credenciales inválidas."*), so the admin does not confirm which emails exist.

### Shell and counters

Sticky header (wordmark + "admin" tag, email, light/dark toggle storing `localStorage`
`"ui-theme"`, logout as a plain `<form action>`). Navigation is a horizontal scrolling strip
under the header on phones and a 200 px sticky sidebar from `lg`; no drawer.

```ts
// lib/counters.ts — server-only. Key = the menu item's href.
const SOURCES: Record<string, () => Promise<number>> = {
  // "/reports": async () => (await apiFetch<{ new: number }>("/admin/reports/new")).new,
};
/** A counter that fails is left out: the layout draws no badge, the shell keeps what it had. */
export async function unseenCounts(): Promise<Record<string, number>> {
  const out: Record<string, number> = {};
  await Promise.all(Object.entries(SOURCES).map(async ([href, read]) => {
    try { out[href] = await read(); } catch (e) { unstable_rethrow(e); }
  }));
  return out;
}
```

```tsx
// Shell.tsx ("use client")
const NAV = [
  { href: "/", label: "Métricas", icon: BarChart3 },
  { href: "/accounts", label: "Cuentas", icon: Store },
  { href: "/me", label: "Mi cuenta", icon: UserCog },
];
const active = (href: string) => (href === "/" ? path === "/" : path === href || path.startsWith(`${href}/`));

const [counts, setCounts] = useState(initial);
const first = useRef(true);
useEffect(() => {
  if (first.current) { first.current = false; return; }      // the layout brought the first ones
  let live = true;
  void callAction(() => countUnseen()).then((r) => { if (live && r.ok) setCounts((c) => ({ ...c, ...r.data })); });
  return () => { live = false; };
}, [path]);
// in BOTH navs: {label}<Counter n={counts[href] ?? 0} />
```

`Counter`: nothing when 0, `99+` above 99, `aria-label="N sin ver"`, neutral inverse pill
(`bg-text text-bg`, mono 12 px, `ml-auto`). `countUnseen` is the Server Action that wraps
`unseenCounts()`.

### Extension point — how a module plugs in

A module with an admin side touches these and nothing else:

1. **Api**: its routes under `/admin/<module>/…`, on a router that carries
   `dependencies=[Depends(require_superadmin)]` — inside `routers/admin.py` (reference) or in its
   own `routers/admin_<module>.py` with the same prefix (project C splits its admin in four routers).
   If it has an inbox: `GET /admin/<module>/new` → `{new: n}`, declared before `/{id}`.
2. **Menu**: one line in `NAV`.
3. **Counter**: one line in `SOURCES` with the same `href`.
4. **Screens**: `app/(panel)/<module>/…`; reads in `lib/data.ts`, writes in
   `lib/actions/<module>.ts`.
5. **Account detail** (optional): one key in the detail response and one `<section>` on the page.
6. **Home** (optional): its keys in `metrics()` and its tiles.
7. **Tests**: one assertion that a regular user gets 403 on its routes.

### Screens

- **Home**: title + sub *"Últimos 30 días salvo que diga otra cosa."*; tiles in
  `grid-cols-2 lg:grid-cols-4`. A tile (`Stat`) is label, value in mono bold, optional note; at
  most one is highlighted with the accent.
- **Accounts**: a plain GET `<form>` with `name="q"` (works without JS; search and page live in
  the URL). Table inside an `overflow-x-auto` card with a `min-w` so the page itself never
  overflows at 390 px. First column: name linking to the detail, and under it the email and
  *" · deshabilitada"* in danger. "← Anterior / Página N de M / Siguiente →" only when there is
  more than one page. Empty: *"No hay cuentas con ese nombre."*
- **Account detail**: back arrow, chips (`status-error` chip *"Deshabilitada"*), name as `h1`,
  one muted line (email · alta · último acceso), tiles, the modules' sections, operations.
- **Disable**: a card *"Deshabilitar"* — *"Corta todas sus sesiones y no puede volver a
  entrar."* — with a `danger` button that opens a confirm sheet *"¿Deshabilitar <nombre>?"* →
  *"Sí, deshabilitar"* / *"Cancelar"*; toast *"Cuenta deshabilitada"*. Once disabled the card
  reads *"Cuenta deshabilitada — No puede entrar."* with an `outline` *"Habilitar"* (one tap).
  The reference copy also says what is **not** touched (public links, the MercadoPago
  subscription): say it for whatever the product has.
- **Mi cuenta**: the admin's email and how they log in. Content belongs to `login`.

**Deploy**: own service and host (`admin.<domain>`), public with its own login
(`--ingress=all --no-invoker-iam-check --no-default-url`), Direct VPC egress to the internal api,
`--min-instances=0`, 512 Mi. Env: `BACKEND_URL`, `API_KEY` (secret), plus what `login` needs
(`GOOGLE_OAUTH_CLIENT_ID`). Dev port 3002.

## Variants (project C)

- **Several admins**: own collection `admin_users` and a token with `aud="admin"` (a
  `get_current_admin` dependency); `GET/POST/DELETE /admin/admins` — single role, anyone creates
  or deletes anyone, **never the last one** (409). One screen to list/create/delete them.
- **KPIs / MRR**: `/admin/metrics/overview` and `/admin/metrics/usage-trend` (zero-filled by
  month); the chart is drawn by hand (plain bars, no chart library).
- **Jobs with dry-run**: `POST /admin/jobs/*` with `dry_run: bool = True` in the body; plain
  `def` so blocking HTTP runs in the threadpool. On the health screen the "execute" button only
  appears after a dry-run that returned something, behind a confirm modal.
- **Ops events, users directory, pending signups**: read-only admin screens over those collections.
- **Account deletion from the admin**: `/orgs/{id}/deletion/schedule|cancel|force`.

## Limits

| Rule | Value | Enforced in |
|---|---|---|
| Page size | 50 | api |
| Search | case-insensitive match on the account name only | api |
| Counter | shown from 1, `99+` above 99; read in the layout, then on every `pathname` change | front |
| Metrics window | 30 days | api |
| Disable the superadmin | never (409) | api |

## Decisions that matter

- **Own app, own host, host-only cookies.** Dashboard and admin use the same cookie names; with
  a `domain` on the cookie one session would overwrite the other.
- **Router-level dependency.** A new `/admin` endpoint cannot forget the guard. Project C repeats
  `Depends(get_current_admin)` on every endpoint instead (42 times across four routers).
- **Role and `disabled` are read from the DB per request**, not from the token. That is what
  makes disabling immediate despite a 15-minute access token; the price is one user read per
  request.
- **Disable = one flag + revoke refresh tokens.** Reversible, deletes nothing, and does not
  reach into other modules (subscription, public pages).
- **The superadmin cannot be disabled**: it may own a tenant (Choice 6), so it shows up in its own
  accounts list.
- **No impersonation, no deletion from the panel** (Choices 4 and 5).
- **Counters are re-fetched on navigation** because App Router layouts do not re-render when the
  route changes, and opening an inbox item changes the count. The first effect run is skipped
  (the layout already brought that value). If a counter fails the panel still renders, without
  the badge: a menu number must not take the admin down.
- **Active item = exact match or `href + "/"`.** With a bare `startsWith`, `/cuentas` also lit
  "Mi cuenta" (`/cuenta`) in the reference.
- **Mutations return the fresh detail and the action revalidates the path**, so the page
  repaints without client state.

## Do not copy

- **One hard-coded counter.** The reference Shell takes a `newReports` prop and checks
  `href === "/reportes"` in both navs; the layout and the action are specific too. Build the
  keyed `counts` above from the start. Note it only refreshes on navigation: an action that
  changes a count without navigating will not move the badge.
- **Unescaped search**: `{"$regex": q}` with the raw text, so what the admin types is read as
  a pattern. Use `re.escape(q)`. The count filter is also written twice (repo and function).
- **N+1 in the list**: per row, one user read, two counts and a quota summary. Batch with `$in`.
- **`50` written three times** (twice in the api, once in the page). Return `per_page` or `pages`.
- **Disable assumes one user per account** (`find_one({"account_id": …})`). With several members,
  put the flag on the tenant or disable them all.
- **No trace of who disabled or when.** With more than one admin add `disabled_at`/`disabled_by`.
- **Everything in one `routers/admin.py`** (generic, business, another module's inbox and all
  their request bodies).
- **Small ones**: ids are not encoded in the actions (`/admin/cuentas/${id}/…`) although the
  reads use `encodeURIComponent`; `PUBLIC_PATHS` in `proxy.ts` is matched with a bare
  `startsWith` (the menu's bug again); the detail of a missing account falls into the generic
  error page instead of `notFound()`.
- **Stale docs in the reference**: several docs said the role is "en el JWT" (the token only has
  `sub`), listed features already removed, described auth as declared per endpoint when it was
  router-level, omitted `GOOGLE_OAUTH_CLIENT_ID`, or contradicted later decisions. Copied files
  drag dashboard leftovers (`globals.css` header and `[data-brand]` block, unused formatting
  helpers, references to screens that only exist in the dashboard): when copying the plumbing,
  prune it.
- **From project C**: the `admin`/`admin` bootstrap user; bare `startsWith` in its nav; `dry_run` in
  some jobs and `apply` in another; the whole panel client-rendered behind a provider, with the
  guard in a `useEffect`.

## Tests

Api (real DB), at least:
1. A regular user gets 403 on `/admin/accounts`; the superadmin gets 200.
2. `q` finds the account; a missing id is 404; `q` with regex characters does not 500.
3. Disable → the same access token gets 401 on its next request; login and refresh fail;
   enable → login works. (The reference asserts only the first step in the api and the login
   in the e2e.)
4. Disabling the superadmin's own account → 409.

e2e: a regular user cannot enter the admin; home; search → detail; disable through the confirm
sheet → toast → login by api fails → enable; every screen at 390 px without horizontal overflow.
The counter going down when an item is opened is tested with the module that owns the inbox.

## Checklist

- [ ] `require_superadmin` on the router, not per endpoint; API key on top.
- [ ] Role and `disabled` read from the DB in `get_current_user`.
- [ ] Disable revokes every refresh token and refuses the superadmin (409).
- [ ] Search text escaped; page size defined once; ids encoded in reads and actions.
- [ ] Layout redirects non-superadmins; login refuses them with the bad-password message.
- [ ] Cookies host-only; admin on its own host and service, `noindex`.
- [ ] `NAV` + `SOURCES` are the only places a module touches in the shell.
- [ ] Counters re-fetched on `pathname` change; a failing counter does not break the panel.
- [ ] Active menu item by exact match or `href + "/"`.
- [ ] Confirm sheet before disabling, and it says what is not touched.
- [ ] Every module's admin routes have a 403 test.
