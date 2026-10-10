# Server Actions data flow (and Route Handler alternative)

**Golden rule:** the browser never calls the backend directly and never holds
`BACKEND_URL` or `API_KEY`. All backend traffic leaves from the server, with the
API key and the user's auth injected there.

`.env.local` (server-only — NEVER prefix `NEXT_PUBLIC_`):

```bash
BACKEND_URL=https://backend.internal
API_KEY=sk_live_xxx
# JWT scheme:
JWT_REFRESH_PATH=/auth/refresh
# Firebase scheme: FIREBASE_* service-account vars
```

---

## 1. Server-only fetch helper — `lib/api.ts`

Injects `X-API-Key` + the user's bearer/session on every call. The `server-only`
import makes the build fail if this is ever imported into a client bundle.

```ts
import "server-only";
import { cookies } from "next/headers";

const BASE = process.env.BACKEND_URL!;
const API_KEY = process.env.API_KEY!;

export class ApiError extends Error {
  constructor(public status: number, message: string, public body?: unknown) {
    super(message);
  }
}

type Opts = RequestInit & { tags?: string[] };

export async function apiFetch<T>(path: string, opts: Opts = {}): Promise<T> {
  const jar = await cookies();
  const access = jar.get("access")?.value; // JWT scheme; Firebase: "session"

  const res = await fetch(`${BASE}${path}`, {
    ...opts,
    headers: {
      "Content-Type": "application/json",
      "X-API-Key": API_KEY,
      ...(access ? { Authorization: `Bearer ${access}` } : {}),
      ...opts.headers,
    },
    // opt into the data cache + tag-based revalidation for GETs:
    next: opts.tags ? { tags: opts.tags } : undefined,
    cache: opts.cache,
  });

  if (!res.ok) {
    let body: unknown;
    try { body = await res.json(); } catch { body = await res.text(); }
    throw new ApiError(res.status, `Backend ${res.status} for ${path}`, body);
  }
  return res.status === 204 ? (undefined as T) : ((await res.json()) as T);
}
```

---

## 2. Read Server Action — `lib/actions/users.ts`

```ts
"use server";
import { apiFetch } from "@/lib/api";

export type User = { id: string; name: string; email: string };

export async function getUsers(): Promise<User[]> {
  // tagged so a mutation can revalidate exactly this data
  return apiFetch<User[]>("/users", { method: "GET", tags: ["users"] });
}
```

A **server** component can `await getUsers()` directly:

```tsx
// app/(dash)/users/page.tsx  (server component)
import { getUsers } from "@/lib/actions/users";
export default async function UsersPage() {
  const users = await getUsers();
  return <UsersTable users={users} />; // pass plain data to the client table
}
```

---

## 3. Mutation Server Action with error handling + revalidation

```ts
"use server";
import { revalidateTag } from "next/cache";
import { apiFetch, ApiError } from "@/lib/api";

export type ActionResult<T = void> =
  | { ok: true; data: T }
  | { ok: false; error: string };

export async function createUser(
  _prev: ActionResult<{ id: string }> | undefined,
  formData: FormData,
): Promise<ActionResult<{ id: string }>> {
  const name = String(formData.get("name") ?? "").trim();
  const email = String(formData.get("email") ?? "").trim();
  if (!name || !email) return { ok: false, error: "Name and email are required." };

  try {
    const created = await apiFetch<{ id: string }>("/users", {
      method: "POST",
      body: JSON.stringify({ name, email }),
    });
    revalidateTag("users");          // or revalidatePath("/users")
    return { ok: true, data: created };
  } catch (e) {
    if (e instanceof ApiError) {
      if (e.status === 409) return { ok: false, error: "That email already exists." };
      if (e.status === 401) return { ok: false, error: "Session expired. Log in again." };
    }
    return { ok: false, error: "Could not create user. Try again." };
  }
}
```

Wire it from a client form with `useActionState`:

```tsx
"use client";
import { useActionState } from "react";
import { createUser } from "@/lib/actions/users";

export function NewUserForm() {
  const [state, action, pending] = useActionState(createUser, undefined);
  return (
    <form action={action}>
      <input name="name" />
      <input name="email" />
      {state && !state.ok && <p className="text-[--color-danger]">{state.error}</p>}
      <button disabled={pending}>{pending ? "Saving…" : "Create"}</button>
    </form>
  );
}
```

`revalidateTag("users")` vs `revalidatePath("/users")`: use the **tag** to refresh
every place that read tagged data regardless of route; use the **path** to refresh
one specific route's cache.

---

## 4. Auth cookie pattern — `lib/session.ts` + `lib/actions/auth.ts`

httpOnly cookies are unreadable by browser JS — the token never touches the client.

```ts
// lib/session.ts
import "server-only";
import { cookies } from "next/headers";

const COMMON = { httpOnly: true, secure: true, sameSite: "lax" as const, path: "/" };

export async function setTokens(access: string, refresh: string) {
  const jar = await cookies();
  jar.set("access", access, { ...COMMON, maxAge: 60 * 15 });        // 15 min
  jar.set("refresh", refresh, { ...COMMON, maxAge: 60 * 60 * 24 * 30 }); // 30 d
}
export async function clearTokens() {
  const jar = await cookies();
  jar.delete("access");
  jar.delete("refresh");
}
export async function getAccess() {
  return (await cookies()).get("access")?.value ?? null;
}
```

```ts
// lib/actions/auth.ts
"use server";
import { redirect } from "next/navigation";
import { setTokens, clearTokens } from "@/lib/session";

export async function login(_p: unknown, fd: FormData) {
  const res = await fetch(`${process.env.BACKEND_URL}/auth/login`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-API-Key": process.env.API_KEY! },
    body: JSON.stringify({ email: fd.get("email"), password: fd.get("password") }),
  });
  if (!res.ok) return { ok: false as const, error: "Invalid credentials." };
  const { access, refresh } = await res.json();
  await setTokens(access, refresh);
  redirect("/");
}

export async function logout() {
  await clearTokens();
  redirect("/login");
}
```

**Renewing the session — NOT in `apiFetch`.** Do not refresh on a 401 inside
`apiFetch`: it runs during render, where Next cannot write cookies, so the rotated
refresh token is lost; the next request sends the old one, the api treats it as
reuse and revokes all of the user's sessions (a guaranteed failure ~15 min after
login). Renew in `proxy.ts` (what `middleware.ts` became in Next 16 — check the name
for the Next version in use) **before** render: if the access token has under 60 s
left, exchange the refresh token there and write the new cookies on both the request
and the response. A 401 that still reaches `apiFetch` means the session died →
`redirect("/session-expired")`, a route handler that clears the cookies and sends to
`/login`. The full, production-tested version (de-duplicated exchanges, "rejected" vs
"no answer", cookie options shared with the proxy) is the **`login` recipe of the
`modulos` skill**: `modulos/references/usuarios-login.md`. The `login`/`logout`
actions above are the minimal sketch; that recipe replaces them.

**Firebase variant:** instead of `access`/`refresh`, exchange the client ID token
for a session cookie server-side via `getAuth().createSessionCookie(idToken, …)`,
store it as the httpOnly `session` cookie, and `verifySessionCookie` it inside
`apiFetch`/route handlers.

Protect the dashboard group in `app/(dash)/layout.tsx`:

```tsx
import { redirect } from "next/navigation";
import { getAccess } from "@/lib/session";
export default async function DashLayout({ children }: { children: React.ReactNode }) {
  if (!(await getAccess())) redirect("/login");
  return <Shell>{children}</Shell>;
}
```

---

## 5. Route Handler alternative — `app/api/.../route.ts`

Use a Route Handler when you need a real URL endpoint: **webhooks**, **streaming/
SSE**, **OAuth callbacks**, file up/download, or non-React clients. Same rule — the
API key stays server-side.

```ts
// app/api/webhooks/stripe/route.ts
import { NextRequest, NextResponse } from "next/server";

export async function POST(req: NextRequest) {
  const sig = req.headers.get("stripe-signature");
  const raw = await req.text();
  // verify signature with a server-only secret, then forward internally:
  const res = await fetch(`${process.env.BACKEND_URL}/webhooks/stripe`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-API-Key": process.env.API_KEY! },
    body: raw,
  });
  return NextResponse.json({ received: res.ok }, { status: res.ok ? 200 : 502 });
}
```

### When to use which

| Server Action                              | Route Handler                          |
|--------------------------------------------|----------------------------------------|
| React UI reads/writes app data             | A URL endpoint is required             |
| Form submit / button mutation              | Incoming 3rd-party webhook             |
| Want `revalidateTag` / `revalidatePath`    | Streaming / SSE / file download        |
| Coupled to a component                     | OAuth provider callback                |
