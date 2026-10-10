# React component ports

TypeScript + Tailwind v4 + **Motion 12** ports faithful to `assets/Manual_UI.html`.
Every animated component imports from **`motion/react`** (NOT `framer-motion`).
Tokens come from the CSS in `tokens.md`; these use the exposed Tailwind color
utilities (`bg-surface`, `text-muted`, `border-border`, …) plus raw CSS vars where
needed. All overlays/menus animate enter AND exit via `AnimatePresence`.

Put these under `src/ui/`. They are deliberately compact but real.

## Icons — always `lucide-react`

**All icons come from `lucide-react`. Never emojis, never ad-hoc inline `<svg>`,
never another icon pack.** Install `lucide-react`; import the named icon and render
it sized with a Tailwind class: `<ChevronDown className="w-5 h-5" />`. Lucide icons
inherit `currentColor` and use the same 24×24 / round-cap stroke as the manual, so
they drop into every slot below (`Trigger` icon, `Dialog` icon, `Toast` icon)
unchanged. The consts below use the exact lucide icon that matches each manual SVG.

---

## Button

```tsx
import { motion } from "motion/react";
import type { ComponentPropsWithoutRef, ReactNode } from "react";

type Variant = "primary" | "secondary" | "soft" | "outline" | "ghost" | "danger";
type Size = "sm" | "md" | "lg";

const base =
  "inline-flex items-center justify-center gap-2 font-semibold leading-none rounded-[14px] " +
  "border border-transparent select-none cursor-pointer transition-colors " +
  "focus-visible:outline-none focus-visible:shadow-[0_0_0_4px_var(--accent-ring)] " +
  "disabled:opacity-45 disabled:cursor-not-allowed";

const sizes: Record<Size, string> = {
  sm: "text-[13px] px-3.5 py-2.5",
  md: "text-[15px] px-5 py-[13px]",
  lg: "text-[17px] px-7 py-4",
};

const variants: Record<Variant, string> = {
  primary: "bg-accent text-accent-fg hover:bg-accent-hover",
  secondary: "bg-surface-2 text-text border-border hover:bg-surface-3",
  soft: "bg-[var(--accent-soft)] text-accent hover:bg-[var(--accent-soft-2)]",
  outline: "bg-transparent text-text border-border-strong hover:border-accent hover:text-accent",
  ghost: "bg-transparent text-text hover:bg-surface-2",
  danger: "bg-danger text-white hover:brightness-110",
};

export interface ButtonProps extends ComponentPropsWithoutRef<"button"> {
  variant?: Variant;
  size?: Size;
  loading?: boolean;
  iconOnly?: boolean;
  children?: ReactNode;
}

export function Button({
  variant = "primary", size = "md", loading, iconOnly,
  className = "", disabled, children, ...props
}: ButtonProps) {
  return (
    <motion.button
      whileTap={{ y: 1 }}
      transition={{ duration: 0.06 }}
      disabled={disabled || loading}
      className={`${base} ${sizes[size]} ${variants[variant]} ${iconOnly ? "!px-3.5" : ""} ${className}`}
      {...(props as any)}
    >
      {loading && (
        <span
          className="w-4 h-4 rounded-full animate-spin"
          style={{
            border: "2px solid color-mix(in srgb, currentColor 35%, transparent)",
            borderTopColor: "currentColor",
          }}
        />
      )}
      {children}
    </motion.button>
  );
}
```

---

## Input / Textarea

`.ui-field` look: 14px radius, hover `--border-strong`, focus accent ring. Error
drives a danger border + red ring + helper line.

```tsx
import type { ComponentPropsWithoutRef, ReactNode } from "react";

const field =
  "w-full bg-surface text-text rounded-[14px] px-4 py-[14px] text-[16px] leading-[1.4] " +
  "border border-border placeholder:text-faint transition-[border-color,box-shadow,background] " +
  "hover:border-border-strong focus:outline-none focus:border-accent " +
  "focus:shadow-[0_0_0_4px_var(--accent-ring)]";

const errorStyle = {
  borderColor: "var(--danger)",
  boxShadow: "0 0 0 4px color-mix(in srgb, var(--danger) 18%, transparent)",
} as const;

export function Label({ children, error }: { children: ReactNode; error?: boolean }) {
  return (
    <span
      className="block text-[13px] font-semibold mb-[9px] tracking-[0.01em]"
      style={{ color: error ? "var(--danger)" : "var(--text)" }}
    >
      {children}
    </span>
  );
}

export interface InputProps extends ComponentPropsWithoutRef<"input"> {
  label?: string; error?: string; hint?: string;
}
export function Input({ label, error, hint, className = "", ...props }: InputProps) {
  return (
    <label className="block">
      {label && <Label error={!!error}>{label}</Label>}
      <input className={`${field} ${className}`} style={error ? errorStyle : undefined} {...props} />
      {error && <span className="mt-2 block text-[13px] text-danger">{error}</span>}
      {!error && hint && <span className="mt-2 block text-[13px] text-muted">{hint}</span>}
    </label>
  );
}

export function Textarea({ label, error, hint, className = "", ...props }:
  ComponentPropsWithoutRef<"textarea"> & { label?: string; error?: string; hint?: string }) {
  return (
    <label className="block">
      {label && <Label error={!!error}>{label}</Label>}
      <textarea className={`${field} resize-y ${className}`} style={error ? errorStyle : undefined} {...props} />
      {error && <span className="mt-2 block text-[13px] text-danger">{error}</span>}
      {!error && hint && <span className="mt-2 block text-[13px] text-muted">{hint}</span>}
    </label>
  );
}
```

---

## NumberInput (es-AR `1.000.000,00`)

Formats with thousands `.` / decimal `,`, no native arrows, and exposes the REAL
numeric value via `onValueChange`.

```tsx
import { useState, useCallback } from "react";

function formatNumberString(raw: string, decimals: number): string {
  raw = String(raw).replace(/[^\d,]/g, "");
  const hasComma = raw.indexOf(",") !== -1;
  const parts = raw.split(",");
  let intPart = parts[0].replace(/^0+(?=\d)/, "");
  const decPart = parts.slice(1).join("").slice(0, decimals);
  if (intPart === "" && (hasComma || raw !== "")) intPart = "0";
  intPart = intPart.replace(/\B(?=(\d{3})+(?!\d))/g, ".");
  let out = intPart;
  if (decimals > 0 && hasComma) out += "," + decPart;
  return out;
}
export function parseLocalNumber(formatted: string): number | null {
  if (!formatted) return null;
  const n = parseFloat(String(formatted).replace(/\./g, "").replace(",", "."));
  return isNaN(n) ? null : n;
}

export interface NumberInputProps {
  decimals?: number; defaultValue?: number; placeholder?: string;
  prefix?: string; suffix?: string; label?: string; hint?: string;
  onValueChange?: (value: number | null) => void;
}
export function NumberInput({
  decimals = 2, defaultValue, placeholder = decimals > 0 ? "0,00" : "0",
  prefix, suffix, label, hint, onValueChange,
}: NumberInputProps) {
  const init = defaultValue == null ? "" :
    defaultValue.toLocaleString("es-AR", { minimumFractionDigits: decimals, maximumFractionDigits: decimals });
  const [text, setText] = useState(init);

  const onInput = useCallback((e: React.ChangeEvent<HTMLInputElement>) => {
    const f = formatNumberString(e.target.value, decimals);
    setText(f);
    onValueChange?.(parseLocalNumber(f));
  }, [decimals, onValueChange]);

  const onBlur = () => {
    if (decimals > 0 && text !== "") {
      const n = parseLocalNumber(text);
      if (n !== null) setText(n.toLocaleString("es-AR",
        { minimumFractionDigits: decimals, maximumFractionDigits: decimals }));
    }
  };

  const inner = (
    <input
      type="text" inputMode={decimals > 0 ? "decimal" : "numeric"}
      value={text} onChange={onInput} onBlur={onBlur} placeholder={placeholder}
      className="flex-1 bg-transparent border-0 outline-none px-4 py-[14px] text-[16px] font-medium tabular-nums text-text min-w-0"
    />
  );

  return (
    <label className="block">
      {label && <Label>{label}</Label>}
      <div className="flex items-center w-full bg-surface border border-border rounded-[14px] overflow-hidden
                      focus-within:border-accent focus-within:shadow-[0_0_0_4px_var(--accent-ring)] transition-[border-color,box-shadow]">
        {prefix && <span className="px-4 self-stretch flex items-center text-[16px] font-medium text-muted border-r border-border">{prefix}</span>}
        {inner}
        {suffix && <span className="px-4 self-stretch flex items-center text-[16px] font-medium text-muted border-l border-border">{suffix}</span>}
      </div>
      {hint && <span className="mt-2 block text-[13px] text-muted">{hint}</span>}
    </label>
  );
}
```

Import `Label` from the input module above. A `NumberStepper` is just two `Button`s
flanking a `data-decimals="0"` NumberInput, clamping at 0.

---

## Trigger (shared) + Popover

Select / DatePicker / TimePicker all share this trigger + animated popover.

```tsx
import { motion, AnimatePresence } from "motion/react";
import { useEffect, useRef, type ReactNode } from "react";

export function Trigger({ open, placeholder, value, icon, onClick, onKeyDown }: {
  open: boolean; placeholder?: boolean; value: ReactNode; icon: ReactNode;
  onClick: () => void; onKeyDown?: (e: React.KeyboardEvent) => void;
}) {
  return (
    <button
      type="button" onClick={onClick} onKeyDown={onKeyDown}
      className={`w-full flex items-center justify-between gap-2.5 text-left bg-surface text-text
        rounded-[14px] px-4 py-[13px] text-[16px] cursor-pointer border transition-[border-color,box-shadow]
        ${open ? "border-accent shadow-[0_0_0_4px_var(--accent-ring)]" : "border-border hover:border-border-strong"}
        ${placeholder ? "[&_[data-val]]:text-faint" : ""}`}
    >
      <span data-val>{value}</span>
      <span className="shrink-0 text-muted">{icon}</span>
    </button>
  );
}

export function Popover({ open, onClose, children, style }: {
  open: boolean; onClose: () => void; children: ReactNode; style?: React.CSSProperties;
}) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const onDoc = (e: MouseEvent) => { if (!ref.current?.contains(e.target as Node)) onClose(); };
    const onEsc = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    document.addEventListener("mousedown", onDoc);
    document.addEventListener("keydown", onEsc);
    return () => { document.removeEventListener("mousedown", onDoc); document.removeEventListener("keydown", onEsc); };
  }, [open, onClose]);
  return (
    <AnimatePresence>
      {open && (
        <motion.div
          ref={ref}
          initial={{ opacity: 0, y: 8, scale: 0.98 }}
          animate={{ opacity: 1, y: 0, scale: 1 }}
          exit={{ opacity: 0, y: 8, scale: 0.98 }}
          transition={{ duration: 0.14, ease: "easeOut" }}
          className="absolute z-30 mt-2 bg-surface border border-border rounded-2xl p-1.5 scroll-thin"
          style={{ boxShadow: "var(--shadow-lg)", ...style }}
        >
          {children}
        </motion.div>
      )}
    </AnimatePresence>
  );
}
```

The trigger icon is a `lucide-react` icon (`ChevronDown`, `Calendar`, `Clock`),
matching the manual's SVGs.

---

## Select (keyboard nav + click-outside)

```tsx
import { useState, useRef } from "react";
import { ChevronDown, Check } from "lucide-react";
import { Trigger, Popover } from "./Popover";

export function Select({ options, value: controlled, placeholder = "Seleccionar", onChange }: {
  options: string[]; value?: string; placeholder?: string; onChange?: (v: string) => void;
}) {
  const [open, setOpen] = useState(false);
  const [value, setValue] = useState(controlled ?? "");
  const [active, setActive] = useState(Math.max(0, options.indexOf(value)));
  const ref = useRef<HTMLDivElement>(null);

  const choose = (o: string) => { setValue(o); onChange?.(o); setOpen(false); };
  const onKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "ArrowDown") { e.preventDefault(); open ? setActive((i) => Math.min(options.length - 1, i + 1)) : setOpen(true); }
    else if (e.key === "ArrowUp") { e.preventDefault(); if (open) setActive((i) => Math.max(0, i - 1)); }
    else if (e.key === "Enter" || e.key === " ") { e.preventDefault(); open ? choose(options[active]) : setOpen(true); }
  };
  return (
    <div ref={ref} className="relative">
      <Trigger open={open} placeholder={!value} value={value || placeholder} icon={<ChevronDown className="w-5 h-5" />}
        onClick={() => setOpen((o) => !o)} onKeyDown={onKeyDown} />
      <Popover open={open} onClose={() => setOpen(false)} style={{ width: ref.current?.offsetWidth, maxHeight: 280, overflowY: "auto" }}>
        {options.map((o, i) => (
          <div key={o} onMouseEnter={() => setActive(i)} onClick={() => choose(o)}
            className={`px-3 py-[11px] rounded-[10px] text-[15px] cursor-pointer flex items-center justify-between gap-2
              ${i === active ? "bg-surface-2" : ""} ${o === value ? "text-accent font-semibold" : "text-text"}`}>
            <span>{o}</span>
            {o === value && <Check className="w-4 h-4" strokeWidth={2.4} />}
          </div>
        ))}
      </Popover>
    </div>
  );
}
```

---

## DatePicker (`dd/mm/aaaa`, Mon→Sun)

```tsx
import { useState, useRef } from "react";
import { Calendar, ChevronLeft, ChevronRight } from "lucide-react";
import { Trigger, Popover } from "./Popover";

const MONTHS = ["Enero","Febrero","Marzo","Abril","Mayo","Junio","Julio","Agosto","Septiembre","Octubre","Noviembre","Diciembre"];
const WD = ["L","M","M","J","V","S","D"];
const pad = (n: number) => String(n).padStart(2, "0");

export function DatePicker({ placeholder = "dd/mm/aaaa", onChange }: {
  placeholder?: string; onChange?: (iso: string) => void;
}) {
  const [open, setOpen] = useState(false);
  const [selected, setSelected] = useState<Date | null>(null);
  const [view, setView] = useState(new Date());
  const ref = useRef<HTMLDivElement>(null);
  const today = new Date();

  const fmt = (d: Date) => `${pad(d.getDate())}/${pad(d.getMonth() + 1)}/${d.getFullYear()}`;
  const pick = (d: Date) => { setSelected(d); onChange?.(fmt(d)); setOpen(false); };

  const y = view.getFullYear(), m = view.getMonth();
  const first = (new Date(y, m, 1).getDay() + 6) % 7;          // Monday-first
  const days = new Date(y, m + 1, 0).getDate();
  return (
    <div ref={ref} className="relative">
      <Trigger open={open} placeholder={!selected} value={selected ? fmt(selected) : placeholder} icon={<Calendar className="w-5 h-5" />} onClick={() => setOpen((o) => !o)} />
      <Popover open={open} onClose={() => setOpen(false)} style={{ width: 300, padding: 14 }}>
        <div className="flex items-center justify-between mb-3">
          <button type="button" onClick={() => setView(new Date(y, m - 1, 1))} className="p-2 rounded-[14px] hover:bg-surface-2"><ChevronLeft className="w-5 h-5" strokeWidth={2.2} /></button>
          <span className="font-semibold text-[15px]">{MONTHS[m]} {y}</span>
          <button type="button" onClick={() => setView(new Date(y, m + 1, 1))} className="p-2 rounded-[14px] hover:bg-surface-2"><ChevronRight className="w-5 h-5" strokeWidth={2.2} /></button>
        </div>
        <div className="grid grid-cols-7 gap-1 mb-1">
          {WD.map((d, i) => <div key={i} className="text-center font-mono text-[11px] py-1 text-faint">{d}</div>)}
        </div>
        <div className="grid grid-cols-7 gap-1">
          {Array.from({ length: first }).map((_, i) => <div key={"e" + i} />)}
          {Array.from({ length: days }).map((_, i) => {
            const d = i + 1;
            const isToday = today.getFullYear() === y && today.getMonth() === m && today.getDate() === d;
            const isSel = selected && selected.getFullYear() === y && selected.getMonth() === m && selected.getDate() === d;
            return (
              <button key={d} type="button" onClick={() => pick(new Date(y, m, d))}
                className={`h-9 rounded-[10px] text-[14px] flex items-center justify-center transition-colors
                  ${isSel ? "bg-accent text-accent-fg font-semibold"
                    : isToday ? "shadow-[inset_0_0_0_1.5px_var(--accent)] text-accent font-semibold hover:bg-surface-2"
                    : "text-text hover:bg-surface-2"}`}>
                {d}
              </button>
            );
          })}
        </div>
        <div className="flex justify-between mt-3 pt-3 border-t border-border">
          <button type="button" onClick={() => { setView(new Date()); pick(new Date()); }} className="py-1.5 px-3 text-[13px] rounded-[14px] text-accent hover:bg-surface-2">Hoy</button>
          <button type="button" onClick={() => { setSelected(null); setOpen(false); }} className="py-1.5 px-3 text-[13px] rounded-[14px] text-muted hover:bg-surface-2">Limpiar</button>
        </div>
      </Popover>
    </div>
  );
}
```

---

## TimePicker (`HH:MM`, 24h)

```tsx
import { useState, useRef, useEffect } from "react";
import { Clock } from "lucide-react";
import { Trigger, Popover } from "./Popover";

const pad2 = (n: number) => String(n).padStart(2, "0");

export function TimePicker({ value, placeholder = "--:--", onChange }: {
  value?: string; placeholder?: string; onChange?: (v: string) => void;
}) {
  const [open, setOpen] = useState(false);
  const [hh, setHh] = useState<string | null>(value ? value.split(":")[0] : null);
  const [mm, setMm] = useState<string | null>(value ? value.split(":")[1] : null);
  const ref = useRef<HTMLDivElement>(null);
  const hCol = useRef<HTMLDivElement>(null);
  const mCol = useRef<HTMLDivElement>(null);

  useEffect(() => { if (hh != null && mm != null) onChange?.(`${hh}:${mm}`); }, [hh, mm]); // eslint-disable-line
  useEffect(() => {
    if (!open) return;
    hCol.current?.querySelector("[data-on]")?.scrollIntoView({ block: "center" });
    mCol.current?.querySelector("[data-on]")?.scrollIntoView({ block: "center" });
  }, [open]);

  const opt = (on: boolean) => `py-[11px] rounded-[10px] text-[15px] cursor-pointer flex justify-center
    ${on ? "bg-[var(--accent-soft)] text-accent font-semibold" : "text-text hover:bg-surface-2"}`;

  return (
    <div ref={ref} className="relative">
      <Trigger open={open} placeholder={!(hh && mm)} value={hh && mm ? `${hh}:${mm}` : placeholder} icon={<Clock className="w-5 h-5" />} onClick={() => setOpen((o) => !o)} />
      <Popover open={open} onClose={() => setOpen(false)} style={{ width: 200, padding: 8 }}>
        <div className="flex h-[220px]">
          <div ref={hCol} className="flex-1 overflow-y-auto pr-1 scroll-thin">
            {Array.from({ length: 24 }).map((_, i) => { const v = pad2(i); const on = v === hh; return (
              <div key={v} data-on={on || undefined} onClick={() => setHh(v)} className={opt(on)}>{v}</div>); })}
          </div>
          <div className="w-px bg-border" />
          <div ref={mCol} className="flex-1 overflow-y-auto pl-1 scroll-thin">
            {Array.from({ length: 60 }).map((_, i) => { const v = pad2(i); const on = v === mm; return (
              <div key={v} data-on={on || undefined} onClick={() => setMm(v)} className={opt(on)}>{v}</div>); })}
          </div>
        </div>
      </Popover>
    </div>
  );
}
```

---

## Checkbox / Radio / Toggle

Native input + `peer sr-only`, matching the manual's `.ui-box` / `.ui-radio` /
`.ui-switch`.

```tsx
import type { ComponentPropsWithoutRef, ReactNode } from "react";

export function Checkbox({ children, className = "", ...p }: ComponentPropsWithoutRef<"input"> & { children: ReactNode }) {
  return (
    <label className={`inline-flex items-center gap-[11px] text-[16px] text-text cursor-pointer ${p.disabled ? "opacity-50 cursor-not-allowed" : ""} ${className}`}>
      <input type="checkbox" className="peer sr-only" {...p} />
      <span className="w-[22px] h-[22px] rounded-[7px] border-2 border-border-strong bg-surface relative shrink-0 transition-all
        peer-checked:bg-accent peer-checked:border-accent peer-focus-visible:shadow-[0_0_0_4px_var(--accent-ring)]
        after:content-[''] after:absolute after:left-[6px] after:top-[2px] after:w-[6px] after:h-[11px]
        after:border-r-[2.5px] after:border-b-[2.5px] after:border-accent-fg after:rotate-45 after:scale-0
        after:transition-transform peer-checked:after:scale-100" />
      <span>{children}</span>
    </label>
  );
}

export function Radio({ children, className = "", ...p }: ComponentPropsWithoutRef<"input"> & { children: ReactNode }) {
  return (
    <label className={`inline-flex items-center gap-[11px] text-[16px] text-text cursor-pointer ${className}`}>
      <input type="radio" className="peer sr-only" {...p} />
      <span className="w-[22px] h-[22px] rounded-full border-2 border-border-strong bg-surface relative shrink-0 transition-all
        peer-checked:border-accent peer-focus-visible:shadow-[0_0_0_4px_var(--accent-ring)]
        after:content-[''] after:absolute after:inset-0 after:m-auto after:w-[10px] after:h-[10px]
        after:rounded-full after:bg-accent after:scale-0 after:transition-transform peer-checked:after:scale-100" />
      <span>{children}</span>
    </label>
  );
}

export function Toggle({ children, className = "", ...p }: ComponentPropsWithoutRef<"input"> & { children?: ReactNode }) {
  return (
    <label className={`inline-flex items-center justify-between gap-3 w-full text-[16px] text-text cursor-pointer ${className}`}>
      {children && <span>{children}</span>}
      <input type="checkbox" className="peer sr-only" {...p} />
      <span className="w-[46px] h-[27px] rounded-full bg-border-strong relative shrink-0 transition-colors
        peer-checked:bg-accent peer-focus-visible:shadow-[0_0_0_4px_var(--accent-ring)]
        after:content-[''] after:absolute after:top-[3px] after:left-[3px] after:w-[21px] after:h-[21px]
        after:rounded-full after:bg-white after:shadow-[0_1px_3px_rgba(0,0,0,0.3)] after:transition-transform
        peer-checked:after:translate-x-[19px]" />
    </label>
  );
}
```

---

## Tooltip

```tsx
import type { ReactNode } from "react";

export function Tooltip({ label, place = "top", children }: {
  label: string; place?: "top" | "bottom"; children: ReactNode;
}) {
  const pos = place === "top"
    ? "bottom-[calc(100%+8px)] group-hover:-translate-y-0 group-focus-within:-translate-y-0"
    : "top-[calc(100%+8px)] group-hover:translate-y-0 group-focus-within:translate-y-0";
  return (
    <span className="group relative inline-flex">
      {children}
      <span className={`pointer-events-none absolute left-1/2 -translate-x-1/2 translate-y-1 ${pos}
        bg-text text-bg text-[13px] font-medium px-3 py-2 rounded-[10px] whitespace-nowrap opacity-0 z-50
        shadow-[var(--shadow-md)] transition-[opacity,transform] duration-150
        group-hover:opacity-100 group-focus-within:opacity-100`}>
        {label}
      </span>
    </span>
  );
}
```

---

## Tabs (sliding indicator via `layoutId`)

```tsx
import { useState, type ReactNode } from "react";
import { motion, AnimatePresence } from "motion/react";

export function Tabs({ tabs }: { tabs: { id: string; label: string; content: ReactNode }[] }) {
  const [active, setActive] = useState(tabs[0].id);
  const current = tabs.find((t) => t.id === active)!;
  return (
    <div>
      <div role="tablist" className="inline-flex p-1.5 rounded-2xl gap-1 bg-surface-2">
        {tabs.map((t) => (
          <button key={t.id} role="tab" onClick={() => setActive(t.id)}
            className={`relative px-[18px] py-2.5 rounded-[14px] font-semibold text-[15px] transition-colors
              ${active === t.id ? "text-text" : "text-muted hover:text-text"}`}>
            {active === t.id && (
              <motion.span layoutId="tab-indicator"
                className="absolute inset-0 rounded-[14px] bg-surface dark:bg-surface-3 shadow-[var(--shadow-sm)]"
                transition={{ type: "spring", stiffness: 500, damping: 40 }} />
            )}
            <span className="relative z-10">{t.label}</span>
          </button>
        ))}
      </div>
      <div className="mt-7 text-[17px] leading-relaxed text-muted">
        <AnimatePresence mode="wait">
          <motion.div key={current.id}
            initial={{ opacity: 0, y: 6 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: -6 }}
            transition={{ duration: 0.15 }}>
            {current.content}
          </motion.div>
        </AnimatePresence>
      </div>
    </div>
  );
}
```

---

## Modal / Drawer / Dialog (AnimatePresence enter + exit)

Esc + backdrop close, body scroll lock while open.

```tsx
import { useEffect, type ReactNode } from "react";
import { motion, AnimatePresence } from "motion/react";

function useOverlay(open: boolean, onClose: () => void) {
  useEffect(() => {
    if (!open) return;
    const onEsc = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    document.addEventListener("keydown", onEsc);
    document.body.style.overflow = "hidden";
    return () => { document.removeEventListener("keydown", onEsc); document.body.style.overflow = ""; };
  }, [open, onClose]);
}

function Backdrop({ onClose }: { onClose: () => void }) {
  return (
    <motion.div onClick={onClose} className="absolute inset-0 bg-black/45 backdrop-blur-[4px]"
      initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} transition={{ duration: 0.18 }} />
  );
}

export function Modal({ open, onClose, children }: { open: boolean; onClose: () => void; children: ReactNode }) {
  useOverlay(open, onClose);
  return (
    <AnimatePresence>
      {open && (
        <div className="fixed inset-0 z-50">
          <Backdrop onClose={onClose} />
          <motion.div role="dialog" aria-modal
            initial={{ opacity: 0, y: 8, scale: 0.98 }} animate={{ opacity: 1, y: 0, scale: 1 }}
            exit={{ opacity: 0, y: 8, scale: 0.98 }} transition={{ duration: 0.18, ease: "easeOut" }}
            className="absolute left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2 w-[calc(100%-48px)] max-w-[460px]
              bg-surface border border-border rounded-[24px] p-8 shadow-[var(--shadow-lg)]">
            {children}
          </motion.div>
        </div>
      )}
    </AnimatePresence>
  );
}

export function Drawer({ open, onClose, children }: { open: boolean; onClose: () => void; children: ReactNode }) {
  useOverlay(open, onClose);
  return (
    <AnimatePresence>
      {open && (
        <div className="fixed inset-0 z-50">
          <Backdrop onClose={onClose} />
          <motion.div role="dialog" aria-modal
            initial={{ x: "100%" }} animate={{ x: 0 }} exit={{ x: "100%" }}
            transition={{ duration: 0.24, ease: [0.22, 1, 0.36, 1] }}
            className="absolute right-0 top-0 h-full w-[400px] max-w-[calc(100vw-40px)] overflow-y-auto
              bg-surface border-l border-border p-7 shadow-[var(--shadow-lg)] scroll-thin">
            {children}
          </motion.div>
        </div>
      )}
    </AnimatePresence>
  );
}

// Dialog: same as Modal but max-w-[420px] with an icon slot + confirm/destructive/warning footer.
// tone "danger" = destructive action (delete, irreversible). tone "warning" = non-destructive
// caution (unsaved changes, session expiring) — same amber as the Toast "warning" variant, but
// as a blocking alertdialog instead of a passive notification.
const DIALOG_TONE = {
  accent:  { tint: "var(--accent-soft)", fg: "var(--accent)", confirmBg: null },
  warning: { tint: "color-mix(in srgb, var(--warning) 14%, transparent)", fg: "var(--warning)", confirmBg: "var(--warning)" },
  danger:  { tint: "color-mix(in srgb, var(--danger) 14%, transparent)", fg: "var(--danger)", confirmBg: null },
} as const;

export function Dialog({ open, onClose, tone = "accent", icon, title, children, onConfirm, confirmLabel = "Confirmar" }: {
  open: boolean; onClose: () => void; tone?: "accent" | "warning" | "danger"; icon?: ReactNode;
  title: string; children: ReactNode; onConfirm?: () => void; confirmLabel?: string;
}) {
  useOverlay(open, onClose);
  const { tint, fg, confirmBg } = DIALOG_TONE[tone];
  return (
    <AnimatePresence>
      {open && (
        <div className="fixed inset-0 z-50">
          <Backdrop onClose={onClose} />
          <motion.div role="alertdialog" aria-modal
            initial={{ opacity: 0, y: 8, scale: 0.98 }} animate={{ opacity: 1, y: 0, scale: 1 }}
            exit={{ opacity: 0, y: 8, scale: 0.98 }} transition={{ duration: 0.18, ease: "easeOut" }}
            className="absolute left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2 w-[calc(100%-48px)] max-w-[420px]
              bg-surface border border-border rounded-[24px] p-8 shadow-[var(--shadow-lg)]">
            {icon && <div className="w-12 h-12 rounded-2xl grid place-items-center mb-5" style={{ background: tint, color: fg }}>{icon}</div>}
            <h3 className="font-display text-[22px] font-bold tracking-[-0.01em] mb-2">{title}</h3>
            <p className="text-[16px] mb-7 text-muted">{children}</p>
            <div className="flex gap-3">
              <Button variant="secondary" className="flex-1" onClick={onClose}>Cancelar</Button>
              <Button
                variant={tone === "danger" ? "danger" : "primary"}
                className="flex-1"
                style={confirmBg ? { background: confirmBg } : undefined}
                onClick={onConfirm ?? onClose}
              >
                {confirmLabel}
              </Button>
            </div>
          </motion.div>
        </div>
      )}
    </AnimatePresence>
  );
}

// Usage (icons from lucide-react):
// import { TriangleAlert, Trash2, Info } from "lucide-react";
// <Dialog tone="warning" icon={<TriangleAlert className="w-6 h-6" />} title="Cambios sin guardar"
//   confirmLabel="Salir sin guardar" onConfirm={discard}>
//   Tenés cambios sin guardar. Si salís ahora se van a perder.
// </Dialog>
// tone="danger"  → icon={<Trash2 className="w-6 h-6" />}
// tone="accent"  → icon={<Info className="w-6 h-6" />}
```

---

## Toasts (stacked, auto-dismiss)

Context + `useToast()`. Stacked bottom-right, slide-in/out, auto-dismiss ~4.2s.

```tsx
import { createContext, useCallback, useContext, useState, type ReactNode } from "react";
import { motion, AnimatePresence } from "motion/react";
import { Check, Info, TriangleAlert, XCircle, X, type LucideIcon } from "lucide-react";

type Variant = "success" | "info" | "warning" | "error";
interface Toast { id: number; variant: Variant; title: string; desc?: string }

const COLOR: Record<Variant, string> = {
  success: "var(--success)", info: "var(--accent)", warning: "var(--warning)", error: "var(--danger)",
};
const ICON: Record<Variant, LucideIcon> = {
  success: Check, info: Info, warning: TriangleAlert, error: XCircle,
};

const ToastCtx = createContext<(t: Omit<Toast, "id">) => void>(() => {});
export const useToast = () => useContext(ToastCtx);

export function ToastProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([]);
  const remove = (id: number) => setToasts((t) => t.filter((x) => x.id !== id));
  const push = useCallback((t: Omit<Toast, "id">) => {
    const id = Date.now() + Math.random();
    setToasts((cur) => [...cur, { ...t, id }]);
    setTimeout(() => remove(id), 4200);
  }, []);
  return (
    <ToastCtx.Provider value={push}>
      {children}
      <div className="fixed bottom-6 right-6 z-[60] flex flex-col gap-3 w-[360px] max-w-[calc(100vw-48px)] pointer-events-none">
        <AnimatePresence>
          {toasts.map((t) => (
            <motion.div key={t.id} layout
              initial={{ opacity: 0, x: 40 }} animate={{ opacity: 1, x: 0 }} exit={{ opacity: 0, x: 40 }}
              transition={{ duration: 0.22, ease: [0.22, 1, 0.36, 1] }}
              className="pointer-events-auto flex items-start gap-3 p-4 bg-surface border border-border rounded-[20px]"
              style={{ boxShadow: "var(--shadow-lg)" }}>
              <span className="shrink-0 w-9 h-9 rounded-xl grid place-items-center"
                style={{ background: `color-mix(in srgb, ${COLOR[t.variant]} 14%, transparent)`, color: COLOR[t.variant] }}>
                {(() => { const Icon = ICON[t.variant]; return <Icon className="w-5 h-5" />; })()}
              </span>
              <div className="flex-1 min-w-0">
                <div className="font-semibold text-[15px]">{t.title}</div>
                {t.desc && <div className="text-[14px] mt-0.5 text-muted">{t.desc}</div>}
              </div>
              <button onClick={() => remove(t.id)} className="shrink-0 -mr-1 -mt-1 p-1.5 rounded-lg text-faint" aria-label="Cerrar">
                <X className="w-4 h-4" strokeWidth={2.2} />
              </button>
            </motion.div>
          ))}
        </AnimatePresence>
      </div>
    </ToastCtx.Provider>
  );
}
```

---

## Loaders / Skeleton

The keyframes (`spin`, `dotpulse`, `barslide`, `shimmer`) live in `tokens.md` §5.

```tsx
export const Spinner = ({ size = 36 }: { size?: number }) => (
  <span className="rounded-full animate-spin inline-block" style={{ width: size, height: size, border: "3px solid var(--surface-3)", borderTopColor: "var(--accent)" }} />
);
export const Dots = () => (
  <span className="flex gap-2">{[0, 0.15, 0.3].map((d, i) => <span key={i} className="dot" style={{ animationDelay: `${d}s` }} />)}</span>
);
export const ProgressIndeterminate = () => (
  <span className="block w-full h-2 rounded-full overflow-hidden relative bg-surface-3">
    <span className="absolute top-0 h-full w-2/5 rounded-full bg-accent" style={{ animation: "barslide 1.3s ease-in-out infinite" }} />
  </span>
);
export const Skeleton = ({ className = "" }: { className?: string }) => (
  <span className={`skeleton block rounded-full ${className}`} />
);
```

---

## Theme + accent controls

```tsx
import { useState } from "react";
const ACCENTS = ["blue", "orange", "purple"] as const;

export function useTheme() {
  const set = (theme: "light" | "dark") => {
    document.documentElement.classList.toggle("dark", theme === "dark");
    try { localStorage.setItem("ui-theme", theme); } catch {}
  };
  const setAccent = (a: (typeof ACCENTS)[number]) => {
    document.documentElement.setAttribute("data-accent", a);
    try { localStorage.setItem("ui-accent", a); } catch {}
  };
  const toggle = () => set(document.documentElement.classList.contains("dark") ? "light" : "dark");
  return { set, setAccent, toggle, ACCENTS };
}
```

---

## Responsive Nav / Sidebar with double-duty hamburger

The hamburger opens a left **drawer** on mobile AND **collapses** the sidebar on
desktop for breathing room. Both animate enter AND exit via `AnimatePresence`.

```tsx
import { useState, type ReactNode } from "react";
import { motion, AnimatePresence } from "motion/react";
import { Menu } from "lucide-react";

export function AppShell({ nav, children }: { nav: ReactNode; children: ReactNode }) {
  const [collapsed, setCollapsed] = useState(false); // desktop
  const [mobileOpen, setMobileOpen] = useState(false); // mobile drawer

  return (
    <div className="min-h-screen">
      <header className="sticky top-0 z-40 backdrop-blur-md border-b border-border"
        style={{ background: "color-mix(in srgb, var(--bg) 82%, transparent)" }}>
        <div className="mx-auto max-w-[1240px] px-6 h-[68px] flex items-center gap-3">
          <button aria-label="Menú" onClick={() => { setMobileOpen((o) => !o); setCollapsed((c) => !c); }}
            className="p-2.5 rounded-[14px] bg-surface-2 border border-border hover:bg-surface-3">
            <Menu className="w-5 h-5" />
          </button>
          <span className="font-extrabold tracking-tight text-[17px]">App</span>
        </div>
      </header>

      <div className="mx-auto max-w-[1240px] px-6 flex gap-10">
        {/* Desktop sidebar: width animates between expanded and collapsed */}
        <motion.aside className="hidden lg:block shrink-0 sticky top-[68px] self-start h-[calc(100vh-68px)] overflow-hidden scroll-thin py-10"
          animate={{ width: collapsed ? 0 : 200, opacity: collapsed ? 0 : 1 }}
          transition={{ duration: 0.25, ease: [0.22, 1, 0.36, 1] }}>
          {nav}
        </motion.aside>

        <main className="flex-1 min-w-0 py-12">{children}</main>
      </div>

      {/* Mobile drawer */}
      <AnimatePresence>
        {mobileOpen && (
          <div className="fixed inset-0 z-50 lg:hidden">
            <motion.div onClick={() => setMobileOpen(false)} className="absolute inset-0 bg-black/45 backdrop-blur-[4px]"
              initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} transition={{ duration: 0.18 }} />
            <motion.aside initial={{ x: "-100%" }} animate={{ x: 0 }} exit={{ x: "-100%" }}
              transition={{ duration: 0.24, ease: [0.22, 1, 0.36, 1] }}
              className="absolute left-0 top-0 h-full w-[260px] max-w-[80vw] bg-surface border-r border-border p-6 overflow-y-auto scroll-thin">
              {nav}
            </motion.aside>
          </div>
        )}
      </AnimatePresence>
    </div>
  );
}
```

`nav` is a `<nav>` of links styled like the manual's `.nav-link`
(`px-3 py-2 rounded-[10px] text-muted hover:bg-surface-2 hover:text-text`, active =
`bg-[var(--accent-soft)] text-accent font-semibold`).
