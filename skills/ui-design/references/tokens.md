# Design Tokens — derived verbatim from `assets/Manual_UI.html`

Source of truth: `assets/Manual_UI.html`. If a value here ever disagrees with that file, the HTML wins. Re-derive on any visual change.

Stack target: **Tailwind CSS v4.3** (CSS-first config via `@theme`, plugin `@tailwindcss/vite`, no `tailwind.config.js`). Dark mode via `@custom-variant`. Re-verify versions on each build (Tailwind v4.3 / React 19.2.7 / Motion 12.40.0 as of June 2026).

---

## 1. Anti-flash pre-paint script

Put this **inline in `<head>` BEFORE any CSS/paint** (Vite `index.html`; Next.js: in `app/layout.tsx` via a `<script dangerouslySetInnerHTML>` placed in `<head>`, or a tiny inline script before `<body>` children). It reads `localStorage` keys `ui-theme` and `ui-accent` so there is no flash.

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

Default markup on `<html>`: `<html lang="es" data-accent="blue" class="dark">` (dark + blue is the canonical default).

---

## 2. Fonts

Load via Google Fonts (Vite) or `next/font` (Next). Bricolage Grotesque = display/titles, Plus Jakarta Sans = body, JetBrains Mono = data/labels.

```html
<link rel="preconnect" href="https://fonts.googleapis.com" />
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
<link href="https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:opsz,wght@12..96,400;12..96,600;12..96,700;12..96,800&family=Plus+Jakarta+Sans:wght@400;500;600;700;800&family=JetBrains+Mono:wght@400;500;700&display=swap" rel="stylesheet" />
```

---

## 3. Tailwind v4 entry + `@theme`

`src/index.css` (Vite) or `app/globals.css` (Next):

```css
@import "tailwindcss";

/* Dark mode driven by html.dark (set by the pre-paint script) */
@custom-variant dark (&:where(.dark, .dark *));

@theme {
  --font-sans: "Plus Jakarta Sans", system-ui, sans-serif;
  --font-display: "Bricolage Grotesque", "Plus Jakarta Sans", sans-serif;
  --font-mono: "JetBrains Mono", ui-monospace, monospace;

  /* expose semantic colors to Tailwind utilities (bg-bg, text-muted, ...) */
  --color-bg: var(--bg);
  --color-surface: var(--surface);
  --color-surface-2: var(--surface-2);
  --color-surface-3: var(--surface-3);
  --color-border: var(--border);
  --color-border-strong: var(--border-strong);
  --color-text: var(--text);
  --color-muted: var(--muted);
  --color-faint: var(--faint);
  --color-accent: var(--accent);
  --color-accent-fg: var(--accent-fg);
  --color-accent-hover: var(--accent-hover);
  --color-success: var(--success);
  --color-warning: var(--warning);
  --color-danger: var(--danger);

  /* radii scale */
  --radius-field: 14px;   /* inputs, buttons, triggers */
  --radius-card: 20px;    /* cards */
  --radius-sm: 12px;
  --radius-md: 16px;
  --radius-lg: 24px;      /* modals/dialogs */
}
```

---

## 4. Theme + accent token block (paste into the same CSS, after `@theme`)

```css
:root {
  --bg: #fafaf9;
  --surface: #ffffff;
  --surface-2: #f5f5f4;
  --surface-3: #ebebe9;
  --border: #e7e5e4;
  --border-strong: #d6d3d1;
  --text: #1c1917;
  --muted: #78716c;
  --faint: #a8a29e;

  --accent: #3b82f6;
  --accent-fg: #ffffff;
  --accent-hover: #2f76ec;

  --success: #16a34a;
  --warning: #d97706;
  --danger: #dc2626;

  --accent-soft:   color-mix(in srgb, var(--accent) 14%, transparent);
  --accent-soft-2: color-mix(in srgb, var(--accent) 22%, transparent);
  --accent-ring:   color-mix(in srgb, var(--accent) 32%, transparent);

  --shadow-sm: 0 1px 2px rgba(28, 25, 23, 0.06);
  --shadow-md: 0 6px 20px -6px rgba(28, 25, 23, 0.14);
  --shadow-lg: 0 24px 60px -18px rgba(28, 25, 23, 0.30);
}

html.dark {
  --bg: #0e0e10;
  --surface: #161618;
  --surface-2: #1d1d20;
  --surface-3: #27272b;
  --border: #2a2a2f;
  --border-strong: #3a3a40;
  --text: #f4f4f5;
  --muted: #a1a1aa;
  --faint: #71717a;

  --accent-fg: #ffffff;

  --shadow-sm: 0 1px 2px rgba(0, 0, 0, 0.4);
  --shadow-md: 0 8px 28px -8px rgba(0, 0, 0, 0.55);
  --shadow-lg: 0 30px 70px -20px rgba(0, 0, 0, 0.7);
}

/* Three switchable accents via data-accent on <html> */
html[data-accent='blue']   { --accent: #3b82f6; --accent-hover: #2f76ec; }
html[data-accent='orange'] { --accent: #f97316; --accent-hover: #ea670b; }
html[data-accent='purple'] { --accent: #a855f7; --accent-hover: #9b46ec; }

* { -webkit-font-smoothing: antialiased; }
body { background: var(--bg); color: var(--text); }
::selection { background: var(--accent-soft-2); }
```

`--accent-soft`, `--accent-soft-2`, `--accent-ring` and `--accent-hover` recompute automatically whenever `--accent` changes, so all three accents work in both themes with no extra rules.

---

## 5. Scrollbar + keyframes + base component classes

These optional `.ui-*` helper classes mirror the manual exactly. The React ports in `components-react.md` use Tailwind utilities instead, but keep these for plain-HTML / quick prototypes and for the loaders/skeleton which rely on the keyframes.

```css
/* Thin scrollbar for panels/popovers */
.scroll-thin::-webkit-scrollbar { width: 8px; }
.scroll-thin::-webkit-scrollbar-thumb { background: var(--border-strong); border-radius: 999px; }
.scroll-thin::-webkit-scrollbar-track { background: transparent; }

/* Global page scrollbar — theme-aware via CSS vars, no extra rules per theme/accent */
html { scrollbar-width: thin; scrollbar-color: var(--border-strong) transparent; } /* Firefox */
html::-webkit-scrollbar { width: 12px; height: 12px; }
html::-webkit-scrollbar-track { background: transparent; }
html::-webkit-scrollbar-corner { background: transparent; }
html::-webkit-scrollbar-thumb {
  background-color: var(--border-strong);
  border-radius: 999px;
  border: 3px solid var(--bg);       /* creates the inset/padded look, matches page bg */
  background-clip: padding-box;
}
html::-webkit-scrollbar-thumb:hover { background-color: var(--faint); }

/* Keyframes */
@keyframes spin { to { transform: rotate(360deg); } }
@keyframes dotpulse { 0%, 80%, 100% { transform: scale(0.5); opacity: 0.4; } 40% { transform: scale(1); opacity: 1; } }
@keyframes barslide { 0% { left: -40%; } 100% { left: 100%; } }
@keyframes shimmer { 100% { transform: translateX(100%); } }
@keyframes pop-in { from { opacity: 0; transform: translateY(8px) scale(0.98); } to { opacity: 1; transform: translateY(0) scale(1); } }
@keyframes toast-in { from { opacity: 0; transform: translateX(40px); } to { opacity: 1; transform: translateX(0); } }
@keyframes drawer-in { from { transform: translateX(100%); } to { transform: translateX(0); } }

.anim-spin { animation: spin 0.7s linear infinite; }
.dot { width: 10px; height: 10px; border-radius: 999px; background: var(--accent); animation: dotpulse 1.2s ease-in-out infinite; }
.skeleton { position: relative; overflow: hidden; background: var(--surface-3); }
.skeleton::after { content: ''; position: absolute; inset: 0; transform: translateX(-100%); background: linear-gradient(90deg, transparent, color-mix(in srgb, var(--text) 8%, transparent), transparent); animation: shimmer 1.4s infinite; }
.pop-in { animation: pop-in 0.16s ease-out; }

/* Inputs base */
.ui-field {
  width: 100%; background: var(--surface); border: 1px solid var(--border); color: var(--text);
  border-radius: 14px; padding: 14px 16px; font-size: 16px; line-height: 1.4;
  transition: border-color .15s, box-shadow .15s, background .15s;
}
.ui-field::placeholder { color: var(--faint); }
.ui-field:hover { border-color: var(--border-strong); }
.ui-field:focus { outline: none; border-color: var(--accent); box-shadow: 0 0 0 4px var(--accent-ring); }

/* Button base + variants */
.ui-btn {
  display: inline-flex; align-items: center; justify-content: center; gap: 8px;
  font-weight: 600; font-size: 15px; line-height: 1;
  padding: 13px 20px; border-radius: 14px; cursor: pointer;
  border: 1px solid transparent; user-select: none;
  transition: transform .06s, background .15s, border-color .15s, box-shadow .15s, color .15s;
}
.ui-btn:active { transform: translateY(1px); }
.ui-btn:focus-visible { outline: none; box-shadow: 0 0 0 4px var(--accent-ring); }
.ui-btn:disabled { opacity: .45; cursor: not-allowed; }
.btn-primary   { background: var(--accent); color: var(--accent-fg); }
.btn-primary:hover:not(:disabled)   { background: var(--accent-hover); }
.btn-secondary { background: var(--surface-2); color: var(--text); border-color: var(--border); }
.btn-secondary:hover:not(:disabled) { background: var(--surface-3); }
.btn-soft   { background: var(--accent-soft); color: var(--accent); }
.btn-soft:hover:not(:disabled)   { background: var(--accent-soft-2); }
.btn-ghost  { background: transparent; color: var(--text); }
.btn-ghost:hover:not(:disabled)  { background: var(--surface-2); }
.btn-outline{ background: transparent; color: var(--text); border-color: var(--border-strong); }
.btn-outline:hover:not(:disabled){ border-color: var(--accent); color: var(--accent); }
.btn-danger { background: var(--danger); color: #fff; }
.btn-danger:hover:not(:disabled) { filter: brightness(1.08); }

.card { background: var(--surface); border: 1px solid var(--border); border-radius: 20px; }
.ui-label { display: block; font-size: 13px; font-weight: 600; margin-bottom: 9px; color: var(--text); letter-spacing: .01em; }
```

---

## 6. Token reference table

| Token | Light | Dark | Use |
|---|---|---|---|
| `--bg` | #fafaf9 | #0e0e10 | page background |
| `--surface` | #ffffff | #161618 | cards, inputs, popovers |
| `--surface-2` | #f5f5f4 | #1d1d20 | secondary fills, hovers |
| `--surface-3` | #ebebe9 | #27272b | tertiary / skeleton base |
| `--border` | #e7e5e4 | #2a2a2f | default borders |
| `--border-strong` | #d6d3d1 | #3a3a40 | hover borders, controls |
| `--text` | #1c1917 | #f4f4f5 | primary text |
| `--muted` | #78716c | #a1a1aa | secondary text |
| `--faint` | #a8a29e | #71717a | placeholders, captions |
| `--accent` | per `data-accent` | same | brand action color |
| `--accent-fg` | #ffffff | #ffffff | text on accent |
| `--success` | #16a34a | (inherits) | positive |
| `--warning` | #d97706 | (inherits) | caution |
| `--danger` | #dc2626 | (inherits) | destructive |

Accents: blue `#3b82f6` (hover `#2f76ec`), orange `#f97316` (hover `#ea670b`), purple `#a855f7` (hover `#9b46ec`).

Radii: fields/buttons **14px**, cards **20px**, modals/dialogs **24px**; scale 12 / 16 / 24 / full(999px).
