# fullstack-app · zero to production on GCP

**[Español](#español) · [English](#english)**

---

## Español

Las skills de [Claude Code](https://claude.com/claude-code) con las que construyo apps enteras **de cero a
producción**: frontend, API, base de datos, login, módulos y deploy en Google Cloud Run. La IA no improvisa:
sigue estas reglas.

Salen de proyectos reales en producción. Las comparto para que puedas llevar tu app a producción con buenas
prácticas.

### Qué hay adentro

| Skill | Para qué sirve |
|---|---|
| `fullstack-app` | **La que orquesta todo.** Te hace las preguntas de cada build (qué frontend, qué login, qué base, webhooks, qué módulos, cómo se despliega) y coordina al resto para armar un monorepo listo para desplegar. |
| `ui-design` | Sistema de diseño reutilizable: tokens CSS, tipografía, colores de acento, tema claro/oscuro y componentes base. |
| `frontend-static-vite` | Front estático con Vite + React + TypeScript + Tailwind v4 + Motion, con un BFF del lado del servidor para que la API key nunca llegue al navegador. Landings, sitios, SPAs livianas. |
| `frontend-dashboard-next` | Dashboard o panel de administración con Next.js (App Router) + Server Actions: las llamadas al backend y la API key quedan en el servidor. |
| `api-fastapi` | Backend FastAPI modular (routers / functions / models / db), API key en todos los endpoints y auth con JWT o Firebase. Firestore, Postgres o MongoDB. |
| `deploy-gcp-cloudrun` | Dockerfiles seguros (multietapa, sin root, sin secretos adentro) y deploy a Cloud Run: con Terraform (por defecto) o con gcloud + GitHub Actions. Backend interno, solo se exponen los fronts. |
| `modulos` | Catálogo de módulos probados en producción para enchufar: login (contraseña o Google), botón de sugerencias, bot de reclamos, mail transaccional, panel de superadmin y suscripciones con MercadoPago. |
| `e2e-testing` | Cómo armar tests end-to-end con la app de verdad contra un backend real y una base descartable (Playwright, webhooks de pagos, control del reloj, CI). |

### Cómo instalarlas

Necesitás [Claude Code](https://docs.claude.com/en/docs/claude-code/overview) instalado.

```bash
git clone https://github.com/gonzagomezp/fullstack-app-zero-to-production-gcp.git
mkdir -p ~/.claude/skills
cp -r fullstack-app-zero-to-production-gcp/skills/* ~/.claude/skills/
```

Si solo las querés en un proyecto, copialas a `.claude/skills/` dentro de ese proyecto.

### Cómo se usan

Abrí Claude Code y escribí `/fullstack-app` (o pedile "armame una app de punta a punta"). Te va a hacer las
preguntas del build y va a ir usando las otras skills. Cada una también se puede usar sola: `/api-fastapi`,
`/deploy-gcp-cloudrun`, `/modulos`, etc.

Antes de desplegar, revisá lo que se genera: vas a necesitar tu propio proyecto de GCP, tus dominios y tus
secretos. Las skills usan las versiones LTS del momento; verificá las actuales cuando las uses.

### Quién soy

Gonzalo Gómez Pizarro, ingeniero en sistemas. Muestro cómo construyo apps de cero a producción en Instagram:
[@gonzagomezp_software](https://www.instagram.com/gonzagomezp_software/).

Licencia [MIT](LICENSE).

---

## English

The [Claude Code](https://claude.com/claude-code) skills I use to build complete apps **from zero to
production**: frontend, API, database, auth, feature modules and deploy on Google Cloud Run. The AI doesn't
improvise: it follows these rules.

They come from real projects running in production. I'm sharing them so you can take your app to production
with good practices.

### What's inside

| Skill | What it does |
|---|---|
| `fullstack-app` | **The orchestrator.** Asks the per-build questions (which frontend, which auth, which database, webhooks, which modules, how to deploy) and coordinates the others into a deploy-ready monorepo. |
| `ui-design` | Reusable design system: CSS tokens, typography, accent colors, light/dark theme and base components. |
| `frontend-static-vite` | Static frontend with Vite + React + TypeScript + Tailwind v4 + Motion, with a server-side BFF so the API key never reaches the browser. Landing pages, sites, light SPAs. |
| `frontend-dashboard-next` | Dashboard / admin panel with Next.js (App Router) + Server Actions: backend calls and the API key stay on the server. |
| `api-fastapi` | Modular FastAPI backend (routers / functions / models / db), API key on every endpoint and JWT or Firebase auth. Firestore, Postgres or MongoDB. |
| `deploy-gcp-cloudrun` | Secure Dockerfiles (multistage, non-root, no baked secrets) and deploy to Cloud Run: Terraform (default) or gcloud + GitHub Actions. Internal backend, only the frontends are public. |
| `modulos` | Catalog of production-tested modules to plug in: login (password or Google), feedback button, complaints bot, transactional email, superadmin panel and MercadoPago subscriptions. |
| `e2e-testing` | How to build end-to-end tests that run the real app against a real backend and a disposable database (Playwright, payment webhooks, clock control, CI). |

Some skill names and parts of the text are in Spanish (`modulos`, `sugerencias`, `reclamos`…): they were
written for Argentine products.

### Install

You need [Claude Code](https://docs.claude.com/en/docs/claude-code/overview).

```bash
git clone https://github.com/gonzagomezp/fullstack-app-zero-to-production-gcp.git
mkdir -p ~/.claude/skills
cp -r fullstack-app-zero-to-production-gcp/skills/* ~/.claude/skills/
```

To use them in a single project only, copy them to that project's `.claude/skills/` instead.

### Use

Open Claude Code and type `/fullstack-app` (or ask "build me an app end to end"). It asks the build questions
and calls the other skills as it goes. Each skill also works on its own: `/api-fastapi`,
`/deploy-gcp-cloudrun`, `/modulos`, etc.

Review what gets generated before deploying: you'll need your own GCP project, domains and secrets. The skills
pin the LTS versions of their time; check the current ones when you use them.

### About me

Gonzalo Gómez Pizarro, systems engineer. I show how I build apps from zero to production on Instagram:
[@gonzagomezp_software](https://www.instagram.com/gonzagomezp_software/).

[MIT](LICENSE) license.
