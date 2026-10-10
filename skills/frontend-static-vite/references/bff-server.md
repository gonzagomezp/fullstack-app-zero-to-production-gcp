# BFF server (Hono) + browser API client

The BFF (Backend For Frontend) is a small Node server that does two jobs:

1. **Serves the built static assets** (`dist/`) produced by `vite build`.
2. **Proxies `/api/*`** to the internal backend, injecting `X-API-Key` and the
   bearer token from **server-side env vars**.

This is what makes "all backend calls leave from the server" true for an
otherwise-static SPA. The browser only ever calls the front's own origin.

```
Browser ──fetch('/api/users')──► BFF ──GET BACKEND_URL/users──► Internal backend
            (same origin)         │     headers:
            no secrets            │       X-API-Key: <BACKEND_API_KEY>
                                  │       Authorization: Bearer <AUTH_TOKEN>
                                  └─ also serves dist/index.html + assets
```

## Why secrets stay server-side

- Anything in the **client bundle is public** — view-source, devtools, the network
  tab. A leaked `X-API-Key` can be replayed by anyone.
- Vite **inlines every `VITE_*` env var** into the bundle at build time. So a
  secret named `VITE_API_KEY` ships to every visitor. **Never** prefix secrets
  with `VITE_`.
- The BFF reads `process.env.BACKEND_API_KEY` etc. **at runtime, on the server**.
  These values exist only in the container's environment (Cloud Run secrets), never
  in JS sent to the browser.
- Same-origin `/api/*` also avoids CORS and lets you add rate-limiting, caching,
  and request shaping in one place.

## `server/index.ts` (Hono)

```ts
import { serve } from '@hono/node-server'
import { serveStatic } from '@hono/node-server/serve-static'
import { Hono } from 'hono'

const app = new Hono()

const BACKEND_URL = process.env.BACKEND_URL
const BACKEND_API_KEY = process.env.BACKEND_API_KEY
const AUTH_TOKEN = process.env.AUTH_TOKEN
const PORT = Number(process.env.PORT ?? 8787)

if (!BACKEND_URL) throw new Error('BACKEND_URL is required')

// --- Proxy: every /api/* call is forwarded to the internal backend ---
app.all('/api/*', async (c) => {
  const url = new URL(c.req.url)
  const target = `${BACKEND_URL}${url.pathname.replace(/^\/api/, '')}${url.search}`

  // Inject secrets server-side. The browser never sees these.
  const headers = new Headers()
  const incoming = c.req.header('content-type')
  if (incoming) headers.set('content-type', incoming)
  if (BACKEND_API_KEY) headers.set('X-API-Key', BACKEND_API_KEY)
  if (AUTH_TOKEN) headers.set('Authorization', `Bearer ${AUTH_TOKEN}`)

  const method = c.req.method
  const body =
    method === 'GET' || method === 'HEAD' ? undefined : await c.req.arrayBuffer()

  const upstream = await fetch(target, { method, headers, body })

  // Stream the upstream response back, stripping hop-by-hop headers.
  const resHeaders = new Headers(upstream.headers)
  resHeaders.delete('transfer-encoding')
  return new Response(upstream.body, {
    status: upstream.status,
    headers: resHeaders,
  })
})

// --- Static assets (built SPA) ---
app.use('/*', serveStatic({ root: './dist' }))

// --- SPA fallback: any unmatched route serves index.html ---
app.get('*', serveStatic({ path: './dist/index.html' }))

serve({ fetch: app.fetch, port: PORT }, (info) => {
  console.log(`BFF listening on http://localhost:${info.port}`)
})
```

Run it with `tsx` in dev and `node` (after a TS build) or `tsx` in prod:

```jsonc
// package.json scripts
"dev": "vite",                       // front dev server (proxies /api → BFF)
"dev:server": "tsx watch server/index.ts",
"build": "vite build",
"preview": "vite preview",
"start": "tsx server/index.ts"       // prod: serve dist/ + proxy /api
```

In dev, run both `npm run dev` and `npm run dev:server`. The Vite dev proxy
(`vite.config.ts`) forwards `/api` to `http://localhost:8787` so the browser stays
same-origin in dev too.

## Express alternative

If you prefer Express:

```ts
import express from 'express'
const app = express()
const { BACKEND_URL, BACKEND_API_KEY, AUTH_TOKEN } = process.env
const PORT = Number(process.env.PORT ?? 8787)

app.use('/api', express.raw({ type: '*/*' }), async (req, res) => {
  const target = `${BACKEND_URL}${req.url}`
  const headers: Record<string, string> = {}
  if (req.headers['content-type']) headers['content-type'] = req.headers['content-type'] as string
  if (BACKEND_API_KEY) headers['X-API-Key'] = BACKEND_API_KEY
  if (AUTH_TOKEN) headers['Authorization'] = `Bearer ${AUTH_TOKEN}`
  const upstream = await fetch(target, {
    method: req.method,
    headers,
    body: ['GET', 'HEAD'].includes(req.method) ? undefined : req.body,
  })
  res.status(upstream.status)
  upstream.headers.forEach((v, k) => { if (k !== 'transfer-encoding') res.setHeader(k, v) })
  res.send(Buffer.from(await upstream.arrayBuffer()))
})

app.use(express.static('dist'))
app.get('*', (_req, res) => res.sendFile(process.cwd() + '/dist/index.html'))
app.listen(PORT, () => console.log(`BFF on :${PORT}`))
```

## Browser API client — `src/lib/api.ts`

The client knows **nothing** about the backend. No URL, no key. It only calls the
front's own `/api/*`.

```ts
const BASE = '/api'

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${BASE}${path}`, {
    ...init,
    headers: { 'Content-Type': 'application/json', ...init?.headers },
  })
  if (!res.ok) {
    const detail = await res.text().catch(() => '')
    throw new Error(`API ${res.status} ${res.statusText}: ${detail}`)
  }
  // Tolerate empty 204 responses.
  const text = await res.text()
  return (text ? JSON.parse(text) : undefined) as T
}

export const api = {
  get: <T>(p: string) => request<T>(p),
  post: <T>(p: string, body?: unknown) =>
    request<T>(p, { method: 'POST', body: body ? JSON.stringify(body) : undefined }),
  put: <T>(p: string, body?: unknown) =>
    request<T>(p, { method: 'PUT', body: body ? JSON.stringify(body) : undefined }),
  del: <T>(p: string) => request<T>(p, { method: 'DELETE' }),
}

// Usage:  const users = await api.get<User[]>('/users')
```

## Checklist

- [ ] No `VITE_`-prefixed secret anywhere.
- [ ] `BACKEND_URL`, `BACKEND_API_KEY`, `AUTH_TOKEN` read only in `server/`.
- [ ] Browser code imports `api` from `src/lib/api.ts`; never `fetch`es backend.
- [ ] Dev: Vite proxy `/api → localhost:8787`; both dev servers running.
- [ ] Prod: `npm start` serves `dist/` and proxies `/api`. This container is the
      public Cloud Run service (see `deploy-gcp-cloudrun`).
