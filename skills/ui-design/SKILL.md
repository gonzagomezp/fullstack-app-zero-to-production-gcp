---
name: ui-design
description: Reusable visual design system (CSS tokens, typography, accent theming, base components) derived from a canonical Manual_UI.html. Use when building or restyling ANY frontend UI — buttons, inputs, selects, date/time pickers, modals, drawers, toasts, tabs, loaders — or when the user asks for a consistent look, light/dark theme, switchable accent colors, or a shared component library across Vite and Next.js apps. Auto-applies whenever a frontend needs a design system, even if not named explicitly.
---

# UI Design System

A warm, professional design system: large typography, soft corners, custom-built
controls. Light and dark themes with a single switchable accent (blue / orange /
purple). Everything is driven by CSS variables, so theme and accent flip live with
no rebuild.

**Canonical source of truth: `assets/Manual_UI.html`.** That file is the rendered
reference for every color, size, radius, animation and interaction. When something
here is ambiguous, open the manual and match it pixel-for-pixel. On any visual
change, edit the manual FIRST, then re-derive tokens and components (see
`scripts/extract-tokens.md`).

## Where things live

- `assets/Manual_UI.html` — canonical rendered manual (read it first).
- `references/tokens.md` — complete token block + Tailwind v4 `@theme` setup.
- `references/components-react.md` — TypeScript + Tailwind + Motion React ports.
- `references/motion-patterns.md` — Motion 12 animation patterns (mount AND unmount).

## Verified stack (June 2026 — RE-VERIFY EACH BUILD)

Versions move fast. Before pinning, search the internet / run `npm view <pkg> version`
for the newest, least-vulnerable releases of Tailwind, Motion and React; bump and
re-test, and record the chosen version + reason in the consuming service's docs.
As of June 2026:

- **Tailwind CSS v4.3** — CSS-first `@theme`, plugin `@tailwindcss/vite`, dark via
  `@custom-variant`. No `tailwind.config.js`.
- **Motion 12.40.0** — package `motion`, React import is `motion/react`
  (NOT `framer-motion`). Use `AnimatePresence` + `exit`, `layout` / `layoutId`.
- **React 19.2.7 + TypeScript.**
- **lucide-react** — the ONLY icon source (see "Icons" below). `npm i lucide-react`.
- Fonts: **Bricolage Grotesque** (display), **Plus Jakarta Sans** (body),
  **JetBrains Mono** (data / labels).

## Design philosophy

- **Warm neutrals + one accent.** The grays are warm (stone-tinted) in light and
  near-black neutrals in dark. Exactly one accent color is active at a time, chosen
  via `data-accent` on `<html>` (`blue` default, `orange`, `purple`). Soft, ring and
  hover accent shades derive from `--accent` with `color-mix`, so all three accents
  work in both themes with no extra rules.
- **One primary action per view.** Button hierarchy goes primary → secondary →
  soft → outline → ghost, with danger reserved for destructive actions.
- **Large, confident type.** Display headings use Bricolage with tight tracking
  (`-0.03em`) and `clamp()` sizes; body is Plus Jakarta Sans; mono is reserved for
  data, labels and the es-AR number format `1.000.000,00`.
- **Soft corners, quiet shadows.** Fields/buttons 14px, cards 20px, modals 24px.

## Token set

Defined for light in `:root` and overridden for dark in `html.dark`. Full values in
`references/tokens.md`.

- Neutrals: `--bg`, `--surface`, `--surface-2`, `--surface-3`, `--border`,
  `--border-strong`, `--text`, `--muted`, `--faint`.
- Accent: `--accent`, `--accent-fg`, `--accent-hover`, plus derived
  `--accent-soft` (14%), `--accent-soft-2` (22%), `--accent-ring` (32%).
- Semantic: `--success` `#16a34a`, `--warning` `#d97706`, `--danger` `#dc2626`.
- Shadows: `--shadow-sm`, `--shadow-md`, `--shadow-lg` (softer in light, deeper in dark).
- Accents: blue `#3b82f6` (hover `#2f76ec`), orange `#f97316` (hover `#ea670b`),
  purple `#a855f7` (hover `#9b46ec`).

### No-flash pre-paint script

Inline this in `<head>` **before any CSS/paint** so the stored theme/accent apply
before first paint (Vite: `index.html`; Next: inline `<script>` in `app/layout.tsx`
`<head>`). It reads `localStorage` keys `ui-theme` and `ui-accent`:

```html
<script>
  (function () {
    try {
      var t = localStorage.getItem('ui-theme');
      var a = localStorage.getItem('ui-accent');
      if (t === 'light') document.documentElement.classList.remove('dark');
      if (t === 'dark') document.documentElement.classList.add('dark');
      if (a) document.documentElement.setAttribute('data-accent', a);
    } catch (e) {}
  })();
</script>
```

Default `<html>`: `<html lang="es" data-accent="blue" class="dark">`.

## Radii & shadows

- Fields, buttons, triggers, select/picker triggers: **14px**.
- Cards: **20px**. Modals / dialogs / drawers content: **24px**.
- Scale: `12px` (sm) · `16px` (md) · `24px` (lg) · `999px` (full).
- Popovers (select/date/time, toast): `16px`, `--shadow-lg`.

## Typography scale

- Display 800 / `clamp(40px,6vw,72px)` / tracking `-0.03em`, line-height ~0.95.
- Section title 800 / `clamp(30px,4vw,44px)` / `-0.03em`.
- Subtitle 600 / 24px. Body 400 / 16–19px, relaxed leading.
- Mono 13px for data/labels/captions; uppercase mono 11px for eyebrows.
- Inputs/buttons: 16px field text, 15px button label (600).

## Component inventory (matches the manual)

- **Buttons** — variants `primary`, `secondary`, `soft`, `outline`, `ghost`,
  `danger`; sizes small / medium / large; icon-only; loading (spinner replaces
  affordance, button stays sized); `:active` nudges down 1px; focus ring uses
  `--accent-ring`; disabled `opacity .45`.
- **Inputs / Textarea** — `.ui-field`, hover `--border-strong`, focus accent border
  + 4px `--accent-ring`; error state uses `--danger` border + red ring + helper text;
  prefix/suffix wrappers (e.g. `https://`, `$`, `%`).
- **Number input** — es-AR format `1.000.000,00` (no native arrows), thousands `.`
  and decimal `,`; exposes the real JS numeric value; integer and decimal modes;
  optional custom stepper.
- **Select** — custom dropdown, keyboard nav (↑/↓/Enter/Esc), selected check mark,
  click-outside close, placeholder state.
- **Date picker** — custom calendar, Monday→Sunday week, month nav, today ring,
  "Hoy" / "Limpiar"; returns `dd/mm/aaaa`.
- **Time picker** — 24h, scrollable HH and MM columns, autoscroll to selection;
  returns `HH:MM`.
- **Checkbox / Radio / Toggle** — built on native inputs (`peer sr-only`) for
  accessibility and keyboard focus; accent fill + focus ring.
- **Loaders / Skeleton** — spinner, pulsing dots, indeterminate bar, shimmer skeleton.
- **Tooltips** — hover/focus, top and bottom placement, inverted surface.
- **Tabs** — pill group with sliding active indicator (`layoutId` in React).
- **Modals / Drawers / Dialogs** — blurred backdrop, Esc + backdrop close, body
  scroll lock; modal centered, drawer right-side slide, dialog with icon + three
  tones: `accent` (info/confirm), `warning` (amber, non-destructive caution —
  unsaved changes, session expiring), `danger` (red, destructive/irreversible).
  Warning and danger share the alert-triangle icon; only the tint and confirm
  button color change.
- **Toasts** — stacked bottom-right, auto-dismiss (~4.2s), four semantic variants
  (success / info / warning / error), manual close.

## Icons

**Every icon is a `lucide-react` component. No emojis, no inline hand-written
`<svg>`, no other icon pack (no Heroicons, react-icons, Font Awesome, etc.).**

- Import named: `import { ChevronDown, Calendar, TriangleAlert } from "lucide-react";`
  and size with Tailwind: `<ChevronDown className="w-5 h-5" />`. Adjust weight with
  `strokeWidth={2.2}` when matching the manual's heavier strokes.
- Lucide is 24×24, `currentColor`, round-capped — identical geometry to the manual's
  SVGs — so icons inherit theme/accent color automatically via `currentColor` and
  drop into the `Trigger`, `Dialog` and `Toast` icon slots unchanged.
- Canonical mappings used by the React ports: chevron `ChevronDown` /
  `ChevronLeft` / `ChevronRight`, check `Check`, calendar `Calendar`, clock `Clock`,
  close `X`, hamburger `Menu`; toast/dialog semantics: success `Check`, info `Info`,
  warning `TriangleAlert`, error `XCircle`, destructive `Trash2`.
- The manual (`assets/Manual_UI.html`) still ships literal SVGs because it is a
  dependency-free single file; when porting to React/Next, swap each for its lucide
  equivalent above rather than copying the raw SVG.

## Scrollbar

- **Global page scrollbar** — thin, rounded, theme-aware; thumb is `--border-strong`
  (hover `--faint`), inset from the edge via a `--bg`-colored border so it reads as
  padded rather than edge-to-edge. Styled on `html` (Firefox `scrollbar-width` /
  `scrollbar-color` + WebKit `::-webkit-scrollbar-*`) so it applies to the whole
  page automatically — no per-app config beyond copying the CSS block.
- **Panel scrollbar** — `.scroll-thin` (8px, no inset) for drawers, popovers, date/time
  picker columns; already applied where those components scroll internally.
- Both derive purely from CSS vars, so they flip correctly with `html.dark` and stay
  correct across all three accents with zero extra rules.

## Responsive + hamburger rule

- **Mobile-first Tailwind breakpoints.** No horizontal overflow at any width;
  content max width `1240px`, `px-6` gutters. Grids collapse to one column on small
  screens (`sm:grid-cols-2`, etc.).
- **Hamburger does double duty.** On **mobile** it opens the nav as a left **drawer**
  (overlay + slide-in). On **desktop** the same control **collapses the sidebar/nav**
  to give the content breathing room (and expands it back). Both transitions animate
  **enter AND exit** via Motion `AnimatePresence` (see `references/motion-patterns.md`).
  Never leave nav permanently eating horizontal space on desktop.

## Consuming from frontend apps

**frontend-static-vite**
1. Put the pre-paint script inline in `index.html` `<head>`, before the CSS link.
2. Add Google Fonts links (`references/tokens.md` §2). Install `@tailwindcss/vite`
   and wire it in `vite.config.ts`. Install `lucide-react` for all icons.
3. In `src/index.css`: `@import "tailwindcss";`, the `@custom-variant dark`, the
   `@theme` block and the `:root` / `html.dark` / `html[data-accent]` token blocks
   from `references/tokens.md`, plus its §5 global scrollbar rules (`html`,
   `html::-webkit-scrollbar-*`) so the whole page gets the themed scrollbar.
4. Copy the React components from `references/components-react.md` into `src/ui/`.
   Route transitions via a single `AnimatePresence` keyed by location.

**frontend-dashboard-next** (App Router)
1. Inline the pre-paint script in `app/layout.tsx` `<head>` via
   `<script dangerouslySetInnerHTML>`; set `<html lang="es" data-accent="blue"
   className="dark">`. Prefer `next/font` for the three families.
2. `app/globals.css` gets the same `@import`, `@custom-variant`, `@theme`, token
   blocks and §5 global scrollbar rules.
3. Components are client components (`"use client"`) since they use Motion/state.
   Page transitions go through `app/template.tsx` with a client `AnimatePresence`
   keyed by `usePathname()` (see `references/motion-patterns.md`).
4. Install `lucide-react` for all icons.

Keep both apps importing the SAME token CSS and the SAME component source so the look
stays identical. The manual remains the single source of truth for both.
