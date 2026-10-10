---
name: frontend-dashboard-next
description: Scaffold a dynamic dashboard/admin frontend with Next.js App Router + TypeScript + Tailwind v4 + Motion, using Server Actions so backend calls and the API key stay server-side. Use when the user wants a dashboard, admin panel, authenticated app, data tables/charts, or any interactive logged-in product UI. Consumes the ui-design system; ships responsive layout with a collapsible hamburger sidebar (mobile drawer + desktop collapse) and enter/exit page transitions via AnimatePresence. Triggers whenever a dynamic/Next.js dashboard frontend is requested.
---

# Frontend Dashboard (Next.js App Router)

Scaffold a **dynamic, authenticated dashboard** with the Next.js App Router. The
defining rule: **every backend call leaves from the server** — Server Actions (or
route handlers) inject the API key and the user's auth, and return data to client
components. The browser never holds `BACKEND_URL` or `X-API-Key`.

This skill consumes the **ui-design** skill for all visual tokens and components,
and pairs with **deploy-gcp-cloudrun** for shipping.

## Verified stack (June 2026 — RE-VERIFY each build)

Versions move fast. Re-run a web search / `npm view <pkg> version` before pinning.

- **Next.js 16.2.x** (LTS 16.2.9). **Turbopack is the DEFAULT bundler** for both
  `next dev` and `next build` (stable since 16). **React Compiler** support is
  stable (opt-in via `reactCompiler: true`, not on by default). **Node 20+**. App Router.
- **React 19.2.7** + **TypeScript**.
- **Tailwind CSS v4.3** — with Next via the **`@tailwindcss/postcss`** PostCSS
  plugin + `@import "tailwindcss";` + `@theme` in `globals.css`. CSS-first,
  **no `tailwind.config.js`**.
- **Motion 12.40.0** — package `motion`, React import `motion/react`
  (NOT `framer-motion`). Animated components need `"use client"`.

## Prerequisites

- Node 20+ and npm (or pnpm).
- The **ui-design** skill available (tokens + components + manual).
- Backend reachable at `BACKEND_URL` with an `X-API-Key` and a user-auth scheme
  (JWT access/refresh or Firebase session cookie).

## Scaffold command

```bash
npx create-next-app@latest my-dashboard --typescript --app --tailwind
cd my-dashboard
npm i motion
```

`create-next-app` wires Tailwind v4 + `@tailwindcss/postcss` and Turbopack
already. Confirm `postcss.config.mjs` and `app/globals.css` match the setup below.
Use `assets/package.json.template` as the pin reference (re-verify versions).

## Tailwind v4 + PostCSS (Next)

`postcss.config.mjs`:

```js
const config = { plugins: { "@tailwindcss/postcss": {} } };
export default config;
```

`app/globals.css` — pull the FULL token block from **ui-design**
`references/tokens.md` (do not re-invent values):

```css
@import "tailwindcss";
@custom-variant dark (&:where(.dark, .dark *));

@theme {
  /* map ui-design CSS vars into Tailwind, e.g.: */
  --color-bg: var(--bg);
  --color-surface: var(--surface);
  --color-accent: var(--accent);
  /* ...rest from ui-design references/tokens.md */
}

:root { /* light tokens from ui-design */ }
html.dark { /* dark tokens from ui-design */ }
html[data-accent="orange"] { /* ... */ }
```

No `tailwind.config.js`. Theme/accent flip live via `data-accent` + `.dark` on `<html>`.

## Motion in the App Router

- **Server components by default.** Anything using Motion, hooks, or state must
  start with `"use client"`.
- **Page/route transitions need `app/template.tsx`.** `template.tsx` re-mounts on
  every navigation (unlike `layout.tsx`, which persists), which is what lets exit
  animations run. It renders a **client** `PageTransition` that wraps `children` in
  `<AnimatePresence mode="wait">` with a `motion.div` **keyed by `usePathname()`**,
  so the same node animates **enter AND exit** between routes.
- Exit animations ONLY fire when the unmounting node is inside an `AnimatePresence`.
- Also use `layout` / `layoutId` (sliding tab indicator), `whileHover` / `whileTap`
  (buttons), `whileInView` (cards on scroll).

Full recipe + code: **`references/motion-app-router.md`**.

## Folder structure

```
app/
  layout.tsx            # server: <html>, pre-paint script, fonts, providers
  template.tsx          # re-mounts per nav -> renders client PageTransition
  globals.css           # tailwind import + ui-design tokens
  (auth)/login/page.tsx # public
  (dash)/layout.tsx     # sidebar + topbar shell (server) wrapping the app
  (dash)/page.tsx       # dashboard home (server component, awaits data)
  (dash)/users/page.tsx # data table page
  api/.../route.ts      # route handlers (webhooks, streaming, OAuth callbacks)
components/
  layout/Sidebar.tsx        # "use client" collapsible sidebar (drawer + collapse)
  layout/Topbar.tsx         # "use client" hamburger toggle
  layout/PageTransition.tsx # "use client" AnimatePresence wrapper
  ui/                       # ported from ui-design references/components-react.md
lib/
  actions/                  # "use server" Server Actions (PRIMARY data path)
    users.ts
    auth.ts
  api.ts                    # server-only fetch helper: injects BACKEND_URL + X-API-Key + auth
  session.ts                # httpOnly cookie read/write (JWT or Firebase session)
.env.local                  # BACKEND_URL, API_KEY (server-only, never NEXT_PUBLIC_)
CLAUDE.md
README.md
```

## Consuming the ui-design skill

1. Inline ui-design's **no-flash pre-paint script** in `app/layout.tsx` `<head>`
   via `<script dangerouslySetInnerHTML={{ __html: ... }} />`; set
   `<html lang="es" data-accent="blue" className="dark">`. Prefer `next/font` for
   the three families (Bricolage Grotesque, Plus Jakarta Sans, JetBrains Mono).
2. Put ui-design's `@import`, `@custom-variant`, `@theme` and token blocks into
   `app/globals.css` (above).
3. Copy the React components from ui-design `references/components-react.md` into
   `components/ui/`. They use Motion/state, so they are client components.
4. Follow ui-design's responsive + hamburger rule (below) and motion patterns.

Keep tokens and component source identical to the Vite app so the look matches.

## Data flow — Server Actions (PRIMARY), then Route Handlers

**The browser never calls the backend directly and never sees the API key.**

- **Server Actions** (`"use server"`) are the primary path. A client component (or
  a `<form action={...}>`) calls an action; the action runs on the server, uses
  `lib/api.ts` to read `BACKEND_URL` and inject `X-API-Key` + the user's bearer/
  session, calls the backend, and returns plain data. Mutations call
  `revalidateTag` / `revalidatePath`.
- **Route Handlers** (`app/api/.../route.ts`) for: third-party **webhooks**,
  **streaming** responses (SSE), **OAuth callbacks**, file up/download, or any
  endpoint that must be hit by a URL (non-React clients, external services).

| Use Server Action when…                | Use Route Handler when…                     |
|----------------------------------------|---------------------------------------------|
| React UI reads/writes app data         | A URL endpoint is required                   |
| Form submit / button mutation          | Incoming webhook from a 3rd party            |
| You want `revalidateTag`/`revalidatePath` | Streaming / SSE / file download           |
| Tightly coupled to a component         | OAuth provider callback                      |

Concrete code (api key + auth injection, error handling, revalidation, route
handler alternative, cookie pattern): **`references/server-actions.md`**.

Env: `BACKEND_URL` and `API_KEY` are **server-only** — never prefix with
`NEXT_PUBLIC_`. Anything `NEXT_PUBLIC_*` is shipped to the browser.

## Auth & session handling

- Store credentials in **httpOnly, Secure, SameSite=Lax cookies** — unreadable by JS.
- **JWT scheme:** keep `access` (short TTL) + `refresh` (long TTL) cookies. Server
  Actions read the access token via `cookies()` and attach `Authorization: Bearer`.
  **The refresh token is rotated in `proxy.ts` (Next's middleware), before render —
  never inside `apiFetch`.** During render Next cannot write cookies: a refresh done
  there loses the rotated token, the next request arrives with the old one, the api
  reads it as reuse and revokes every session of the user. For an app with real
  users, build auth from the **`modulos` skill → `login` recipe**
  (`modulos/references/usuarios-login.md`): it has the proxy, the cookies, the
  session-expired route and the Google button, all production-tested.
- **Firebase scheme:** exchange the client ID token for a **session cookie**
  server-side (`createSessionCookie`), store httpOnly, verify with
  `verifySessionCookie` on each server call.
- Login/logout/refresh are Server Actions in `lib/actions/auth.ts`; protect the
  `(dash)` group by checking the session in `(dash)/layout.tsx` and redirecting.

See **`references/server-actions.md`** for the cookie read/write helpers.

## Responsive + collapsible hamburger sidebar (REQUIRED)

Per ui-design's hamburger rule, the hamburger does double duty:

- **Mobile:** opens nav as a left **drawer** (backdrop + slide-in), closes on
  backdrop/Esc/route change.
- **Desktop:** the same control **collapses** the sidebar (full ↔ icon-rail) to
  give content breathing room, and expands it back. Never let nav permanently eat
  horizontal space on desktop.
- Both transitions animate **enter AND exit** via Motion `AnimatePresence`
  (drawer) and width/`layout` animation (collapse). Persist the desktop
  collapsed state (localStorage) and the open/closed mobile state in client state.

Mobile-first Tailwind breakpoints; no horizontal overflow at any width; grids
collapse to one column on small screens.

## Mandatory docs

Create **`CLAUDE.md`** and **`README.md`** at the project root.

- `README.md`: stack + versions, setup, env vars, scripts, deploy pointer.
- `CLAUDE.md`: architecture map (data flow = Server Actions, auth model, folder
  layout, ui-design link) AND this rule, verbatim:

  > **Update this file and README.md whenever the architecture changes** (new data
  > path, auth change, new top-level route group, dependency/version bump).

## Deploy

Ship with **deploy-gcp-cloudrun**: frontend is the only public service; the
backend stays internal. The frontend's Server Actions reach the backend over the
internal network using `BACKEND_URL` + `X-API-Key` (set as Cloud Run secrets/env,
never `NEXT_PUBLIC_`).

## Build checklist

1. Re-verify versions (Next 16.2.x, React 19.2.7, Tailwind 4.3, Motion 12.40.0).
2. `npx create-next-app@latest … --typescript --app --tailwind`; `npm i motion`.
3. Wire Tailwind v4 PostCSS + ui-design tokens in `globals.css`; pre-paint script
   + fonts in `layout.tsx`.
4. Add `app/template.tsx` + client `PageTransition` (AnimatePresence enter+exit).
5. Build `lib/api.ts`, `lib/session.ts`, and Server Actions in `lib/actions/`.
6. Build the collapsible hamburger sidebar (mobile drawer + desktop collapse).
7. Port ui-design components into `components/ui/`.
8. Write `CLAUDE.md` + `README.md` with the update-docs rule.
