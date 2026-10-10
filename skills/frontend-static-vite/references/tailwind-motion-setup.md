# Tailwind v4.3 + Vite + Motion setup

Verified June 2026. Re-verify versions with `npm view <pkg> version`.

## 1. Install

```bash
npm install -D tailwindcss@4.3.1 @tailwindcss/vite@4.3.1
npm install motion@12.40.0 react-router
```

Tailwind v4 is **CSS-first**: there is **no `tailwind.config.js`**. Configuration
lives in CSS via `@theme`, and content scanning is automatic.

## 2. `vite.config.ts`

```ts
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    // Keep the browser same-origin in dev: forward /api to the BFF.
    proxy: { '/api': 'http://localhost:8787' },
  },
})
```

## 3. Global CSS — `src/index.css`

```css
@import "tailwindcss";

/* Dark mode driven by data-theme on <html> (matches the ui-design system). */
@custom-variant dark (&:where([data-theme="dark"], [data-theme="dark"] *));

@theme {
  /* ---- Paste the full token block from the ui-design skill ----
     ui-design/references/tokens.md  →  colors, fonts, radii, shadows.
     Example shape (replace with the real tokens): */
  --color-bg: #faf8f5;
  --color-surface: #ffffff;
  --color-text: #1c1917;
  --color-accent: #2563eb;

  --font-display: "Bricolage Grotesque", sans-serif;
  --font-body: "Plus Jakarta Sans", sans-serif;
  --font-mono: "JetBrains Mono", monospace;

  --radius-lg: 1rem;
}

/* Dark overrides + accent switching come from the ui-design tokens too. */
:root[data-theme="dark"] {
  --color-bg: #0c0a09;
  --color-surface: #1c1917;
  --color-text: #f5f5f4;
}
```

Import it once in `src/main.tsx`:

```ts
import './index.css'
```

> Source of truth for tokens is the **`ui-design`** skill. Do not invent values —
> copy from `ui-design/references/tokens.md` and match `ui-design/assets/Manual_UI.html`.

## 4. Mobile-first responsive notes

- Tailwind is mobile-first: unprefixed utilities apply to all sizes; `sm: md: lg:`
  add styles **at and above** that breakpoint. Defaults: `sm` 40rem, `md` 48rem,
  `lg` 64rem, `xl` 80rem, `2xl` 96rem.
- Pattern for nav: `hidden md:flex` (inline nav on desktop) paired with
  `md:hidden` (hamburger on mobile).
- Use fluid spacing/typography for landing sections; tap targets ≥ 44px.
- Test the drawer, header, and hero at 360px width first, then scale up.

## 5. Motion — package & import

Package is **`motion`**; the React entry is **`motion/react`** (NOT
`framer-motion`).

```ts
import { motion, AnimatePresence } from 'motion/react'
```

## 6. Enter + exit (AnimatePresence)

Exit animations require the element to be a direct conditional child of
`<AnimatePresence>` and to have a stable `key`.

```tsx
<AnimatePresence>
  {open && (
    <motion.div
      key="panel"
      initial={{ opacity: 0, y: 8 }}
      animate={{ opacity: 1, y: 0 }}
      exit={{ opacity: 0, y: 8 }}
      transition={{ duration: 0.2 }}
    />
  )}
</AnimatePresence>
```

## 7. Animated route / view transitions

Wrap the routed outlet in `AnimatePresence mode="wait"` and key it by pathname so
the old view exits before the new one enters.

```tsx
// App.tsx
import { Routes, Route, useLocation } from 'react-router'
import { AnimatePresence, motion } from 'motion/react'
import Home from './pages/Home'
import About from './pages/About'

function Page({ children }: { children: React.ReactNode }) {
  return (
    <motion.main
      initial={{ opacity: 0, y: 12 }}
      animate={{ opacity: 1, y: 0 }}
      exit={{ opacity: 0, y: -12 }}
      transition={{ duration: 0.25, ease: 'easeOut' }}
    >
      {children}
    </motion.main>
  )
}

export default function App() {
  const location = useLocation()
  return (
    <AnimatePresence mode="wait">
      <Routes location={location} key={location.pathname}>
        <Route path="/" element={<Page><Home /></Page>} />
        <Route path="/about" element={<Page><About /></Page>} />
      </Routes>
    </AnimatePresence>
  )
}
```

`mode="wait"` ensures the exiting page finishes animating before the next mounts.

## 8. Layout & shared-element animations

Use `layout` for size/position changes and `layoutId` for shared-element
transitions (e.g. an active-tab pill or a card expanding into a detail view).

```tsx
{tabs.map((t) => (
  <button key={t} className="relative">
    {t}
    {active === t && (
      <motion.span
        layoutId="active-pill"
        className="absolute inset-0 rounded-full bg-[var(--color-accent)]/15"
        transition={{ type: 'spring', stiffness: 350, damping: 30 }}
      />
    )}
  </button>
))}
```

## 9. Hover / scroll / viewport

```tsx
// hover + tap
<motion.button whileHover={{ scale: 1.03 }} whileTap={{ scale: 0.97 }} />

// reveal on scroll into view (once)
<motion.section
  initial={{ opacity: 0, y: 24 }}
  whileInView={{ opacity: 1, y: 0 }}
  viewport={{ once: true, amount: 0.3 }}
  transition={{ duration: 0.5 }}
/>

// scroll-linked progress bar
import { motion, useScroll } from 'motion/react'
function Progress() {
  const { scrollYProgress } = useScroll()
  return <motion.div style={{ scaleX: scrollYProgress, transformOrigin: '0%' }}
    className="fixed top-0 left-0 h-1 w-full bg-[var(--color-accent)]" />
}
```

Reuse the canonical patterns in `ui-design/references/motion-patterns.md` for
consistency with the rest of the system. Respect `prefers-reduced-motion`.
