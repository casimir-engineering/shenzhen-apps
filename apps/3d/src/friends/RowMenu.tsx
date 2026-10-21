// A list row's menu (PROTOCOL.md § list, rows[].menu, client capability list.menu): right-click, the context-menu
// key or Shift+F10 on a computer, a long press on a phone. Its words come from the snapshot, as everywhere else.
import { useEffect, useLayoutEffect, useRef, useState } from "react";
import type {
  KeyboardEvent as ReactKeyboardEvent,
  PointerEvent as ReactPointerEvent,
  SyntheticEvent,
} from "react";
import { createPortal } from "react-dom";
import type { Action } from "./protocol";

export type MenuPoint = { x: number; y: number };
/** How long a finger rests on a row before its menu opens, and how far it may drift meanwhile. */
export const LONG_PRESS_MS = 500;
const LONG_PRESS_SLOP = 10;

/**
 * Long press for touch and pen: held still for LONG_PRESS_MS, it opens the menu where the finger is, and the click
 * the lift would make is swallowed so the conversation does not open behind the menu. Moving (a scroll) cancels.
 */
export function useLongPress(open: (at: MenuPoint) => void, enabled: boolean) {
  const timer = useRef<number | undefined>(undefined);
  const start = useRef<{ x: number; y: number; id: number } | null>(null);
  const swallow = useRef(false);
  const latest = useRef(open);
  latest.current = open;
  useEffect(() => () => window.clearTimeout(timer.current), []);
  const cancel = () => {
    window.clearTimeout(timer.current);
    start.current = null;
  };
  return {
    /** A long press is under way or has just opened the menu (the system's own long-press menu is then ours). */
    pressing: () => Boolean(start.current) || swallow.current,
    swallowNextClick() {
      cancel();
      swallow.current = true;
    },
    handlers: {
      onPointerDown(event: ReactPointerEvent) {
        swallow.current = false;
        cancel();
        if (!enabled || event.pointerType === "mouse" || !event.isPrimary)
          return;
        start.current = {
          x: event.clientX,
          y: event.clientY,
          id: event.pointerId,
        };
        timer.current = window.setTimeout(() => {
          const at = start.current;
          start.current = null;
          if (!at) return;
          swallow.current = true;
          latest.current({ x: at.x, y: at.y });
        }, LONG_PRESS_MS);
      },
      onPointerMove(event: ReactPointerEvent) {
        const at = start.current;
        if (
          at &&
          event.pointerId === at.id &&
          Math.hypot(event.clientX - at.x, event.clientY - at.y) >
            LONG_PRESS_SLOP
        )
          cancel();
      },
      onPointerUp: cancel,
      onPointerCancel: cancel,
      onClickCapture(event: SyntheticEvent) {
        if (!swallow.current) return;
        swallow.current = false;
        event.preventDefault();
        event.stopPropagation();
      },
    },
  };
}

/** The menu itself, drawn in the panel at `at` (kept inside it), focused on its first item. */
export function RowMenu({
  items,
  at,
  host,
  label,
  onChoose,
  onClose,
}: {
  items: Action[];
  at: MenuPoint;
  /** The panel: the menu draws inside it, so choosing an item is never a click outside Friends. */
  host: HTMLElement;
  label: string;
  onChoose(action: Action): void;
  /** `refocus`: give focus back to the row (Escape), not when the person clicked or tapped elsewhere. */
  onClose(refocus: boolean): void;
}) {
  const menu = useRef<HTMLDivElement>(null);
  const [place, setPlace] = useState<{ left: number; top: number } | null>(
    null,
  );
  const close = useRef(onClose);
  close.current = onClose;
  useLayoutEffect(() => {
    const element = menu.current;
    if (!element) return;
    const box = host.getBoundingClientRect();
    const room = (size: number, inner: number) => Math.max(4, inner - size - 4);
    setPlace({
      left: Math.max(
        4,
        Math.min(
          at.x - box.left - host.clientLeft,
          room(element.offsetWidth, host.clientWidth),
        ),
      ),
      top: Math.max(
        4,
        Math.min(
          at.y - box.top - host.clientTop,
          room(element.offsetHeight, host.clientHeight),
        ),
      ),
    });
  }, [at, host]);
  // Focus once placed (a hidden menu takes no focus), so Return or Space chooses and the arrows move.
  const placed = Boolean(place);
  useLayoutEffect(() => {
    if (placed)
      menu.current?.querySelector<HTMLElement>("[role=menuitem]")?.focus();
  }, [placed]);
  useEffect(() => {
    const key = (event: KeyboardEvent) => {
      // Escape closes the menu and nothing else; Tab leaves it, as menus do.
      if (event.key === "Escape" || event.key === "Tab") {
        event.preventDefault();
        event.stopPropagation();
        close.current(true);
      }
    };
    const down = (event: PointerEvent) => {
      if (!menu.current?.contains(event.target as Node)) close.current(false);
    };
    const away = () => close.current(false);
    window.addEventListener("keydown", key, true);
    window.addEventListener("pointerdown", down, true);
    window.addEventListener("blur", away);
    window.addEventListener("resize", away);
    // The list scrolled under it.
    host.addEventListener("scroll", away, true);
    return () => {
      window.removeEventListener("keydown", key, true);
      window.removeEventListener("pointerdown", down, true);
      window.removeEventListener("blur", away);
      window.removeEventListener("resize", away);
      host.removeEventListener("scroll", away, true);
    };
  }, [host]);
  const move = (event: ReactKeyboardEvent) => {
    const all = [
      ...(menu.current?.querySelectorAll<HTMLElement>("[role=menuitem]") ?? []),
    ];
    const index = all.indexOf(document.activeElement as HTMLElement);
    const next =
      event.key === "ArrowDown"
        ? (index + 1) % all.length
        : event.key === "ArrowUp"
          ? (index - 1 + all.length) % all.length
          : event.key === "Home"
            ? 0
            : event.key === "End"
              ? all.length - 1
              : -1;
    if (next < 0 || !all.length) return;
    event.preventDefault();
    all[next].focus();
  };
  return createPortal(
    <div
      ref={menu}
      className="szf-row-menu"
      role="menu"
      aria-label={label}
      style={{
        left: place?.left ?? 0,
        top: place?.top ?? 0,
        visibility: place ? undefined : "hidden",
      }}
      onKeyDown={move}
      onContextMenu={(event) => event.preventDefault()}
    >
      {items.map((item, index) => (
        <button
          key={`${item.action}-${index}`}
          type="button"
          role="menuitem"
          className={item.style === "destructive" ? "destructive" : ""}
          onClick={() => onChoose(item)}
        >
          {item.label}
        </button>
      ))}
    </div>,
    host,
  );
}
