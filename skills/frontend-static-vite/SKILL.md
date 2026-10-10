---
name: frontend-static-vite
description: Scaffold a fast static frontend with Vite + React + TypeScript + Tailwind v4 + Motion, with a server-side BFF so backend calls never leave the browser directly (API key stays server-side). Use when the user wants a static site, landing page, marketing site, or lightweight SPA — anything not a heavy dashboard. Consumes the ui-design system and ships responsive layout with a hamburger menu (mobile drawer + desktop collapse) and enter/exit Motion transitions. Triggers whenever a static/Vite frontend is requested.
---

# Frontend Static (Vite + React + TS + Tailwind v4 + Motion)

Scaffold a **static** SPA (Vite + React + TypeScript + Tailwind v4 + Motion) that
consumes the **`ui-design`** system, fronted by a thin **BFF** (Backend For
Frontend) so every call to the real backend originates **server-side**. The
browser only ever talks to the front's own `/api/*`; the API key and auth tokens
never reach the client.

Use this for landing pages, marketing sites, docs, lightweight SPAs — anything
that is NOT a heavy data dashboard.

## Why a BFF for a "static" site

A pure static SPA has no server: the browser would call the backend directly,
which means any API key shipped to the browser is public. To keep the contract
"**all backend calls leave from the server**", we ship a small Node server (the
BFF) that:

1. Serves the built static assets (`dist/`).
2. Exposes `/api/*` and **proxies** those to the internal backend
   (`process.env.BACKEND_URL`), injecting `X-API-Key` and the bearer token from
   **server-side env vars**.

The browser calls `fetch('/api/...')` — same origin, no secrets. The BFF (a Node
container) is the **public Cloud Run service**. The internal backend stays private.

```
Browser ──/api/*──► BFF (Node, Cloud Run) ──X-API-Key + Bearer──► Internal backend
  (no secrets)         (serves dist/ + proxies)                     (private)
```

See `references/bff-server.md` for the concrete server + client.

## Prerequisites

- **Node 20.19+ or 22.12+** (Vite 8 requirement). Check: `node -v`.
- The **`ui-design`** skill available (we copy its tokens + components).
- For deploy: the **`deploy-gcp-cloudrun`** skill (containerize the BFF).

## Verified stack (June 2026 — RE-VERIFY EACH BUILD)

Run `npm view <pkg> version` before pinning; bump and re-test.

| Package             | Version  | Notes                                        |
|---------------------|----------|----------------------------------------------|
| vite                | 8.0.16   | Rolldown bundler. Node 20.19+/22.12+.        |
| react / react-dom   | 19.2.7   |                                              |
| typescript          | 6.0.3    |                                              |
| tailwindcss         | 4.3.1    | CSS-first, no `tailwind.config.js`.          |
| @tailwindcss/vite   | 4.3.1    | First-party Vite plugin.                     |
| motion              | 12.40.0  | Import `motion/react` (NOT framer-motion).   |
| hono                | latest   | BFF server (or Express).                     |
| react-router        | latest   | Routing + animated view transitions.         |

## Step 1 — Scaffold base

```bash
npm create vite@latest <name> -- --template react-ts
cd <name>
npm install
```

## Step 2 — Install dependencies (re-verify versions first)

```bash
# UI / animation
npm install react@19.2.7 react-dom@19.2.7 motion@12.40.0 react-router

# Tailwind v4 (CSS-first, plugin)
npm install -D tailwindcss@4.3.1 @tailwindcss/vite@4.3.1

# BFF server runtime deps
npm install hono @hono/node-server
npm install -D tsx   # run TS server in dev
```

Or copy `assets/package.json.template` into `package.json` and `npm install`.

## Step 3 — Tailwind v4 setup (no config file)

Full details in `references/tailwind-motion-setup.md`. Summary:

`vite.config.ts`:
```ts
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    // dev: proxy /api to the local BFF so the browser stays same-origin
    proxy: { '/api': 'http://localhost:8787' },
  },
})
```

`src/index.css` (CSS-first — no `tailwind.config.js`):
```css
@import "tailwindcss";
@custom-variant dark (&:where([data-theme="dark"], [data-theme="dark"] *));

@theme {
  /* paste tokens from the ui-design skill: references/tokens.md */
}
```

## Step 4 — Consume the ui-design system

Do NOT reinvent styling. Pull from the `ui-design` skill:

1. Read `ui-design/references/tokens.md` → paste the `@theme` token block into
   `src/index.css`.
2. Read `ui-design/references/components-react.md` → copy the base React
   components (Button, Input, Modal, Drawer, etc.) into `src/components/ui/`.
3. Read `ui-design/references/motion-patterns.md` → reuse mount/unmount patterns.
4. The canonical visual reference is `ui-design/assets/Manual_UI.html` — match it.

Keep `data-theme` (light/dark) and `data-accent` (blue/orange/purple) on `<html>`
exactly as the ui-design system expects.

## Step 5 — API client (browser → own /api only)

`src/lib/api.ts` fetches ONLY the front's own origin. It NEVER knows backend URLs
or keys. See `references/bff-server.md`.

```ts
export async function api<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`/api${path}`, {
    ...init,
    headers: { 'Content-Type': 'application/json', ...init?.headers },
  })
  if (!res.ok) throw new Error(`API ${res.status}: ${await res.text()}`)
  return res.json() as Promise<T>
}
```

## Step 6 — BFF server

`server/index.ts` (Hono) serves `dist/` and proxies `/api/*` to the backend with
injected secrets. Full code in `references/bff-server.md`.

## Folder structure

```
<name>/
├─ src/
│  ├─ components/
│  │  ├─ ui/            # copied from ui-design (Button, Modal, Drawer…)
│  │  └─ layout/        # Header, Nav, HamburgerMenu, Footer
│  ├─ pages/            # route views (Home, About, …)
│  ├─ lib/
│  │  └─ api.ts         # calls own /api ONLY — no secrets, no backend URL
│  ├─ index.css         # @import "tailwindcss" + @theme tokens
│  ├─ App.tsx           # router + AnimatePresence view transitions
│  └─ main.tsx
├─ server/
│  └─ index.ts          # BFF: serves dist/ + proxies /api/* (Hono)
├─ vite.config.ts       # react + tailwind plugin + dev /api proxy
├─ Dockerfile           # build static + run BFF (see deploy-gcp-cloudrun)
├─ .env.example         # SERVER-ONLY secrets (no VITE_ secrets!)
├─ CLAUDE.md            # architecture + "update docs on change" rule
├─ README.md
└─ package.json
```

## Environment variables (CRITICAL)

- **Server-only secrets** live in plain env vars read by the BFF:
  `BACKEND_URL`, `BACKEND_API_KEY`, `AUTH_TOKEN`. These are read in `server/`
  only and are NEVER bundled.
- **NEVER** prefix a secret with `VITE_`. Vite inlines every `VITE_*` var into the
  client bundle — it becomes public. Use `VITE_*` only for non-secret public
  config (e.g. `VITE_APP_NAME`).
- `.env` is gitignored; ship `.env.example` documenting the server vars.

```bash
# .env.example  (server-side only — injected by the BFF)
BACKEND_URL=https://internal-backend.internal
BACKEND_API_KEY=replace-me        # never VITE_-prefixed
AUTH_TOKEN=replace-me
PORT=8787
```

## Responsive + hamburger menu (animated enter + exit)

Mobile-first. The nav collapses behind a hamburger on small screens and shows
inline on `md+`. The mobile drawer animates **in and out** via `AnimatePresence`
+ `exit`.

```tsx
import { useState } from 'react'
import { AnimatePresence, motion } from 'motion/react'

export function Nav() {
  const [open, setOpen] = useState(false)
  const links = ['Home', 'About', 'Contact']
  return (
    <header className="flex items-center justify-between p-4">
      <span className="font-bold">Logo</span>

      {/* Desktop: inline nav (md+) */}
      <nav className="hidden md:flex gap-6">
        {links.map((l) => <a key={l} href={`#${l}`}>{l}</a>)}
      </nav>

      {/* Mobile: hamburger toggles a drawer */}
      <button
        className="md:hidden"
        aria-label="Toggle menu"
        aria-expanded={open}
        onClick={() => setOpen((v) => !v)}
      >
        ☰
      </button>

      <AnimatePresence>
        {open && (
          <motion.div
            className="fixed inset-0 z-50 md:hidden"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
          >
            <div className="absolute inset-0 bg-black/40" onClick={() => setOpen(false)} />
            <motion.nav
              className="absolute right-0 top-0 h-full w-64 bg-[var(--color-surface)] p-6 flex flex-col gap-4"
              initial={{ x: '100%' }}
              animate={{ x: 0 }}
              exit={{ x: '100%' }}
              transition={{ type: 'spring', stiffness: 300, damping: 30 }}
            >
              {links.map((l) => (
                <a key={l} href={`#${l}`} onClick={() => setOpen(false)}>{l}</a>
              ))}
            </motion.nav>
          </motion.div>
        )}
      </AnimatePresence>
    </header>
  )
}
```

Animated route/view transitions go in `App.tsx` — see
`references/tailwind-motion-setup.md`.

## Mandatory docs

Every scaffold MUST include:

- **`CLAUDE.md`** — describes the architecture (static SPA + BFF, secrets server-side,
  ui-design consumption, folder layout) and states the rule:
  > **Update this file and README.md on ANY architecture change** (new route,
  > new `/api/*` proxy, env var, dependency, or change to the BFF/secret flow).
- **`README.md`** — setup, dev (`npm run dev` + `npm start` for the BFF), build,
  env vars, deploy pointer. Same "update docs on change" rule.

## Deploy

The **BFF is the deployable unit** (it serves static + holds secrets).
Containerize and deploy it with the **`deploy-gcp-cloudrun`** skill. Set the
server-only env vars (`BACKEND_URL`, `BACKEND_API_KEY`, `AUTH_TOKEN`) as Cloud Run
secrets/env, never in the client bundle.

## Build order checklist

1. `npm view` each pinned version; bump if newer.
2. Scaffold (`npm create vite`), install deps.
3. Wire Tailwind v4 plugin + `@theme` tokens from ui-design.
4. Copy ui-design components into `src/components/ui/`.
5. Build layout: Header + animated hamburger nav (drawer in/out).
6. `src/lib/api.ts` → own `/api` only.
7. `server/index.ts` BFF (proxy + serve dist).
8. `.env.example`, `CLAUDE.md`, `README.md`.
9. `Dockerfile` → hand to deploy-gcp-cloudrun.
