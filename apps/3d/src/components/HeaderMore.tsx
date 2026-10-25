// The app header on a narrow window (a phone upright, a large system font): what does not fit folds away, least
// needed first, so every command stays on the screen. The document's name truncates first (CSS), and goes once it
// shows too little; then the Open file shortcut hint and the wordmark; then the buttons in HEADER_FOLDS move into the
// header's More menu; last, Open file keeps its icon only. scripts/friends/phones-header.mjs checks it on Android.
import { useEffect, useLayoutEffect, useRef, useState } from "react";
import type { ReactNode, RefObject } from "react";
import { Ellipsis } from "lucide-react";

export const HEADER_FOLDS = [
  "title",
  "shortcut",
  "wordmark",
  "help",
  "share",
  "settings",
  "close",
  "label",
] as const;
export type HeaderFold = (typeof HEADER_FOLDS)[number];

/** Narrower than this (CSS px), the document's name says too little to keep. */
const SHORTEST_TITLE = 64;

function overflows(header: HTMLElement): boolean {
  const style = getComputedStyle(header);
  const box = header.getBoundingClientRect();
  const left = box.left + parseFloat(style.paddingLeft) - 0.5;
  const right = box.right - parseFloat(style.paddingRight) + 0.5;
  for (const child of header.children) {
    const r = child.getBoundingClientRect();
    if (r.width && (r.left < left || r.right > right)) return true;
  }
  return false;
}

function titleTooShort(header: HTMLElement): boolean {
  const name = header.querySelector<HTMLElement>(".document-title > span");
  if (!name?.textContent) return false;
  return (
    name.scrollWidth > name.clientWidth &&
    name.getBoundingClientRect().width < SHORTEST_TITLE
  );
}

/** Folds the header (its `data-fold`) until everything in it fits; returns the folds applied. */
export function fitHeader(header: HTMLElement): HeaderFold[] {
  for (let count = 0; ; count++) {
    const folds = HEADER_FOLDS.slice(0, count);
    header.dataset.fold = folds.join(" ");
    const more = overflows(header) || (count === 0 && titleTooShort(header));
    if (!more || count === HEADER_FOLDS.length) return folds;
  }
}

/** Keeps the header fitted as the window, its buttons and the fonts change. */
export function useHeaderFit(
  header: RefObject<HTMLElement | null>,
): HeaderFold[] {
  const [folds, setFolds] = useState<HeaderFold[]>([]);
  useLayoutEffect(() => {
    const element = header.current;
    if (!element) return;
    let frame = 0;
    const fit = () => {
      frame = 0;
      const next = fitHeader(element);
      setFolds((old) => (old.join(" ") === next.join(" ") ? old : next));
    };
    const later = () => {
      if (!frame) frame = requestAnimationFrame(fit);
    };
    const sizes = new ResizeObserver(later);
    const watch = () => {
      sizes.disconnect();
      sizes.observe(element);
      for (const child of element.children) sizes.observe(child);
    };
    const changes = new MutationObserver(() => {
      watch();
      later();
    });
    changes.observe(element, {
      childList: true,
      subtree: true,
      characterData: true,
    });
    watch();
    fit();
    document.fonts?.addEventListener?.("loadingdone", later);
    return () => {
      cancelAnimationFrame(frame);
      sizes.disconnect();
      changes.disconnect();
      document.fonts?.removeEventListener?.("loadingdone", later);
    };
  }, [header]);
  return folds;
}

export type HeaderMoreItem = {
  id: string;
  title: string;
  icon: ReactNode;
  run(): void;
  disabled?: boolean;
};

/** The header's More button and menu: the commands folded out of the header. */
export function HeaderMore({ items }: { items: HeaderMoreItem[] }) {
  const [open, setOpen] = useState(false);
  const root = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const down = (event: PointerEvent) => {
      if (root.current && !root.current.contains(event.target as Node))
        setOpen(false);
    };
    const key = (event: KeyboardEvent) => {
      if (event.key === "Escape") setOpen(false);
    };
    window.addEventListener("pointerdown", down, true);
    window.addEventListener("keydown", key);
    return () => {
      window.removeEventListener("pointerdown", down, true);
      window.removeEventListener("keydown", key);
    };
  }, [open]);
  useEffect(() => {
    if (!items.length) setOpen(false);
  }, [items.length]);
  return (
    <div className="header-more" ref={root}>
      <button
        type="button"
        className={`icon-button ${open ? "active" : ""}`}
        title="More"
        aria-label="More"
        aria-haspopup="menu"
        aria-expanded={open}
        onClick={() => setOpen((old) => !old)}
      >
        <Ellipsis size={18} />
      </button>
      {open && items.length > 0 && (
        <div className="header-menu" role="menu" aria-label="More">
          {items.map((item) => (
            <button
              key={item.id}
              type="button"
              role="menuitem"
              disabled={item.disabled}
              onClick={() => {
                setOpen(false);
                item.run();
              }}
            >
              {item.icon}
              <span>{item.title}</span>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
