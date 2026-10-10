# Motion 12 patterns

**Motion 12.40.0.** Package `motion`. React import is **`motion/react`** (NOT
`framer-motion` — that name is legacy). The golden rule for this design system:
**animate mount AND unmount.** A component that only animates on enter and then
disappears instantly feels broken. Always wrap conditionally-rendered UI in
`AnimatePresence` and give it an `exit`.

```tsx
import { motion, AnimatePresence } from "motion/react";
```

---

## 1. AnimatePresence + exit (the core pattern)

`AnimatePresence` keeps an element in the DOM long enough to run its `exit`
animation when it is removed. Without it, React unmounts immediately and `exit`
never runs.

```tsx
<AnimatePresence>
  {open && (
    <motion.div
      initial={{ opacity: 0, y: 8, scale: 0.98 }}  // mount
      animate={{ opacity: 1, y: 0, scale: 1 }}      // resting
      exit={{ opacity: 0, y: 8, scale: 0.98 }}      // UNMOUNT — do not omit
      transition={{ duration: 0.18, ease: "easeOut" }}
    >
      …
    </motion.div>
  )}
</AnimatePresence>
```

- The conditional (`open && …`) must be a **direct child** of `AnimatePresence`.
- Give list items / swapped children a **stable `key`** so Motion can tell what
  entered vs. exited.
- This is exactly how the Modal, Drawer, Dialog, Select/Date/Time popovers and
  Toasts in `components-react.md` work — each pairs `initial`/`animate` with `exit`.

The canonical entrance is the manual's `pop-in`
(`opacity 0 → 1`, `translateY 8px → 0`, `scale .98 → 1`, ~0.16–0.18s ease-out); the
drawer uses `x: "100%" → 0` over 0.24s with `ease: [0.22, 1, 0.36, 1]`. Mirror those
values so React matches the HTML.

---

## 2. `mode="wait"` for swapping one element for another

When one thing replaces another (tab panels, routed pages, wizard steps), use
`mode="wait"` so the outgoing element finishes its `exit` before the incoming one
animates in. Key by the thing that changes.

```tsx
<AnimatePresence mode="wait">
  <motion.div
    key={activeTab}
    initial={{ opacity: 0, y: 6 }}
    animate={{ opacity: 1, y: 0 }}
    exit={{ opacity: 0, y: -6 }}
    transition={{ duration: 0.15 }}
  >
    {panel}
  </motion.div>
</AnimatePresence>
```

Other modes: `"sync"` (default, enter+exit overlap) and `"popLayout"` (exiting
element is popped out of layout flow — good for animated lists/toasts that should
reflow as items leave).

---

## 3. `layout` and `layoutId` (shared-element / FLIP)

`layout` smoothly animates an element when its size or position changes.
`layoutId` animates a "shared" element between two locations — Motion crossfades and
slides between the old and new position.

- **Tabs sliding indicator:** render one `<motion.span layoutId="tab-indicator">`
  only inside the active tab. As `active` changes, Motion slides the pill to the new
  tab automatically (see `Tabs` in `components-react.md`).
- **Reordering / dismissing lists** (e.g. stacked toasts): add `layout` so the
  remaining items glide into place as one leaves.

```tsx
{active === id && (
  <motion.span layoutId="tab-indicator"
    className="absolute inset-0 rounded-[14px] bg-surface shadow-[var(--shadow-sm)]"
    transition={{ type: "spring", stiffness: 500, damping: 40 }} />
)}
```

---

## 4. Gestures: `whileHover`, `whileTap`, `whileInView`

- `whileTap={{ y: 1 }}` reproduces the manual's button `:active` nudge.
- `whileHover` for subtle lift on cards (`{ y: -2 }`).
- `whileInView` animates content as it scrolls into the viewport — use
  `viewport={{ once: true }}` so it doesn't replay on every scroll.

```tsx
<motion.section
  initial={{ opacity: 0, y: 16 }}
  whileInView={{ opacity: 1, y: 0 }}
  viewport={{ once: true, margin: "-80px" }}
  transition={{ duration: 0.4, ease: "easeOut" }}
>
  …
</motion.section>
```

Respect reduced motion: wrap the app in `<MotionConfig reducedMotion="user">` so
animations soften when the OS requests it.

---

## 5. Next.js App Router page transitions

App Router unmounts the old route before mounting the new one, so a plain
`AnimatePresence` in `layout.tsx` won't see the exit. Use `template.tsx` (a fresh
instance per navigation) plus a client wrapper keyed by `usePathname()`.

`app/template.tsx`:

```tsx
import { PageTransition } from "@/ui/PageTransition";
export default function Template({ children }: { children: React.ReactNode }) {
  return <PageTransition>{children}</PageTransition>;
}
```

`ui/PageTransition.tsx`:

```tsx
"use client";
import { usePathname } from "next/navigation";
import { motion, AnimatePresence } from "motion/react";

export function PageTransition({ children }: { children: React.ReactNode }) {
  const pathname = usePathname();
  return (
    <AnimatePresence mode="wait">
      <motion.div
        key={pathname}
        initial={{ opacity: 0, y: 8 }}
        animate={{ opacity: 1, y: 0 }}
        exit={{ opacity: 0, y: -8 }}
        transition={{ duration: 0.2, ease: "easeOut" }}
      >
        {children}
      </motion.div>
    </AnimatePresence>
  );
}
```

Any component using Motion hooks/state must be a client component (`"use client"`).

---

## 6. Vite route transitions

With React Router, render one `AnimatePresence mode="wait"` around `<Routes>`,
keyed by `location.pathname`, and pass `location` to `<Routes>` so the outgoing
route stays mounted through its exit.

```tsx
"use no memo";
import { useLocation, Routes, Route } from "react-router-dom";
import { AnimatePresence, motion } from "motion/react";

export function AnimatedRoutes() {
  const location = useLocation();
  return (
    <AnimatePresence mode="wait">
      <motion.div key={location.pathname}
        initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: -8 }}
        transition={{ duration: 0.2, ease: "easeOut" }}>
        <Routes location={location}>
          <Route path="/" element={<Home />} />
          {/* … */}
        </Routes>
      </motion.div>
    </AnimatePresence>
  );
}
```

---

## Checklist

- Every conditionally-rendered overlay/menu/list has `exit`, inside `AnimatePresence`.
- Swaps (tabs, routes, steps) use `mode="wait"` + a stable `key`.
- Shared moving elements use `layoutId`; reflowing lists use `layout`.
- Durations/easings match the manual (`~0.16–0.24s`, ease-out / `[0.22,1,0.36,1]`).
- Import from `motion/react`, never `framer-motion`.
