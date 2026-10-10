# Motion in the Next.js App Router

Package is **`motion`**; React import is **`motion/react`** (NOT `framer-motion`).
Version pinned 12.40.0 — re-verify.

## The `"use client"` boundary

- Next.js App Router renders **server components by default**.
- Any component using Motion, hooks (`useState`, `usePathname`), or browser APIs
  must start with `"use client"`.
- Keep the boundary low: `layout.tsx` / `template.tsx` / `page.tsx` stay server
  components and render small client islands (`PageTransition`, `Sidebar`, etc.).

## Page/route transitions — `template.tsx` + AnimatePresence

Why `template.tsx` and not `layout.tsx`: **`layout.tsx` persists** across
navigations within its segment, so its children never unmount and exit animations
never run. **`template.tsx` re-mounts on every navigation**, giving you a fresh
subtree to animate in and out.

**Rule:** exit animations only fire when the unmounting node is wrapped in
`<AnimatePresence>`. Use `mode="wait"` so the outgoing page finishes exiting before
the incoming page enters. Key the `motion.div` by `usePathname()` so Motion treats
each route as a distinct node.

```tsx
// app/template.tsx  (server component — just renders the client wrapper)
import { PageTransition } from "@/components/layout/PageTransition";
export default function Template({ children }: { children: React.ReactNode }) {
  return <PageTransition>{children}</PageTransition>;
}
```

```tsx
// components/layout/PageTransition.tsx
"use client";
import { AnimatePresence, motion } from "motion/react";
import { usePathname } from "next/navigation";

export function PageTransition({ children }: { children: React.ReactNode }) {
  const pathname = usePathname();
  return (
    <AnimatePresence mode="wait" initial={false}>
      <motion.div
        key={pathname}                       // distinct node per route -> exit fires
        initial={{ opacity: 0, y: 8 }}
        animate={{ opacity: 1, y: 0 }}
        exit={{ opacity: 0, y: -8 }}
        transition={{ duration: 0.22, ease: [0.22, 1, 0.36, 1] }}
      >
        {children}
      </motion.div>
    </AnimatePresence>
  );
}
```

Notes:
- `initial={false}` skips the enter animation on first paint (no flash on load).
- Keep durations short (~0.2s) so navigation still feels instant.
- Respect reduced motion: gate the transition with `useReducedMotion()` and fall
  back to opacity-only or no movement.

## Collapsible sidebar — drawer (mobile) + collapse (desktop)

The hamburger does double duty (ui-design rule). On mobile it opens a left
**drawer** via `AnimatePresence` (so it animates **enter AND exit**); on desktop
the same control **collapses** the rail by animating its width.

```tsx
"use client";
import { AnimatePresence, motion } from "motion/react";
import { useState } from "react";

export function Sidebar() {
  const [open, setOpen] = useState(false);       // mobile drawer
  const [collapsed, setCollapsed] = useState(false); // desktop rail

  return (
    <>
      {/* Desktop: width-animated collapsible rail (hidden on mobile) */}
      <motion.aside
        className="hidden md:block shrink-0 overflow-hidden border-r border-[--color-border]"
        animate={{ width: collapsed ? 72 : 256 }}
        transition={{ type: "spring", stiffness: 260, damping: 30 }}
      >
        <NavItems collapsed={collapsed} />
      </motion.aside>

      {/* Mobile: drawer with enter + exit */}
      <AnimatePresence>
        {open && (
          <>
            <motion.div
              className="fixed inset-0 z-40 bg-black/50 md:hidden"
              initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }}
              onClick={() => setOpen(false)}
            />
            <motion.aside
              className="fixed inset-y-0 left-0 z-50 w-72 bg-[--color-surface] md:hidden"
              initial={{ x: "-100%" }} animate={{ x: 0 }} exit={{ x: "-100%" }}
              transition={{ type: "spring", stiffness: 300, damping: 32 }}
            >
              <NavItems collapsed={false} />
            </motion.aside>
          </>
        )}
      </AnimatePresence>
    </>
  );
}
```

The Topbar hamburger toggles `setOpen` below `md` and `setCollapsed` at `md+`.
Close the mobile drawer on route change (`useEffect` on `usePathname`) and on Esc.
Persist `collapsed` to `localStorage`. Never let the desktop nav permanently eat
horizontal space.

## Layout animations

- **`layoutId`** — shared-element transitions; the sliding active-tab indicator
  (one `motion.div` with `layoutId="tab"` rendered under the active tab).
- **`layout`** — auto-animate size/position changes (list reorder, drawer width).
- **`whileHover` / `whileTap`** — button affordances.
- **`whileInView`** — reveal dashboard cards as they scroll into view
  (`viewport={{ once: true }}`).

All of the above require `"use client"` on the component that renders them.

See ui-design `references/motion-patterns.md` for the canonical mount/unmount and
component-level animation values; keep them identical across the Vite and Next apps.
