# Keeping tokens & components in sync

All tokens (`references/tokens.md`) and React component ports
(`references/components-react.md`) are **sourced from `assets/Manual_UI.html`**.
That HTML is the single source of truth — it is the rendered, canonical reference
for every color, size, radius, animation and interaction.

## Rule on any visual change

1. **Edit `assets/Manual_UI.html` first.** Change the value/markup there and confirm
   it looks right in the browser.
2. **Re-derive `references/tokens.md`** — copy the affected values verbatim from the
   manual's `<style>` blocks (the `:root` / `html.dark` / `html[data-accent]` token
   blocks, `.ui-*` helper classes, keyframes).
3. **Re-derive `references/components-react.md`** so the React ports match the new
   look (same radii, paddings, durations, easings, behavior).
4. **Keep `SKILL.md` in sync** if the component inventory, token names or philosophy
   changed.

Never edit a token in `tokens.md` or a value in `components-react.md` without first
making the same change in the manual. If a value here ever disagrees with the HTML,
**the HTML wins** — re-derive from it.

## What to copy from the manual

- Token blocks: `:root`, `html.dark`, `html[data-accent='…']`.
- Base classes: `.ui-field`, `.ui-btn` + `.btn-*`, `.card`, `.ui-label`,
  `.ui-check` / `.ui-box` / `.ui-radio` / `.ui-switch`, `.ui-trigger` / `.ui-pop` /
  `.ui-option`, `.nav-link`, tooltip and overlay classes.
- Keyframes: `spin`, `dotpulse`, `barslide`, `shimmer`, `pop-in`, `toast-in`,
  `drawer-in`.
- Behavior to mirror in React: es-AR number formatting (`formatNumberString` /
  `parseLocalNumber`), select keyboard nav, date picker Monday-first calendar, time
  picker columns, overlay Esc/backdrop/scroll-lock, toast auto-dismiss timing.
