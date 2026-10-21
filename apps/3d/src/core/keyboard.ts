// The on-screen keyboard, so a field being typed in stays in sight above it, on every phone and tablet.
//
// Android: MainActivity.kt makes the WebView end where the keyboard begins and gives the keyboard's height as
// `keyboard` in window.ShenzhenInsets.insets(); the page's own viewport has already shrunk. iOS (WKWebView) and
// mobile browsers keep the layout viewport and shrink only the visual one, so what the keyboard covers is measured
// from window.visualViewport. Either way the root gets:
//   --keyboard-inset   how much of the page's bottom the keyboard covers (0 on Android, where nothing is covered),
//   data-keyboard      while a keyboard is up, for layouts that need the room (styles.css, friends-pages.css),
// and a `shenzhen-keyboard` event says when either changes. The focused field, or the caret in it, is then scrolled
// into view, smoothly, in whichever of its scrolling boxes hides it.
type AndroidInsets = { insets(): string };

/** A browser's toolbar coming and going moves the visual viewport by less than this; a keyboard by more. */
const KEYBOARD_MIN = 80;
/** Room kept between the caret or field and the keyboard's edge. */
const MARGIN = 12;

const editable = (element: Element | null): element is HTMLElement =>
  element instanceof HTMLElement &&
  (element.isContentEditable ||
    element instanceof HTMLTextAreaElement ||
    (element instanceof HTMLInputElement &&
      !/^(button|checkbox|color|file|hidden|image|radio|range|reset|submit)$/.test(
        element.type,
      )));

/** The part of the layout viewport that can be seen: above the keyboard, below what iOS panned away. */
function visibleBand(host: Window) {
  const view = host.visualViewport;
  return view
    ? { top: view.offsetTop, bottom: view.offsetTop + view.height }
    : { top: 0, bottom: host.innerHeight };
}

/** The caret's box in a field with a selection the page can read (a contenteditable); the field's own otherwise. */
function caretBox(element: HTMLElement): DOMRect {
  const own = element.getBoundingClientRect();
  if (!element.isContentEditable) return own;
  const selection = element.ownerDocument.getSelection();
  if (!selection?.rangeCount) return own;
  const range = selection.getRangeAt(0);
  if (!element.contains(range.endContainer)) return own;
  const rects = range.getClientRects();
  const caret = rects.length
    ? rects[rects.length - 1]
    : range.getBoundingClientRect();
  return caret.height ? caret : own;
}

/** Scrolls each scrolling box around the focused field just enough to show it, or its caret, above the keyboard. */
export function revealFocused(doc: Document, smooth = true) {
  const host = doc.defaultView;
  const focused = doc.activeElement;
  if (!host || !editable(focused)) return;
  const band = visibleBand(host);
  let box = caretBox(focused);
  let top = box.top - MARGIN;
  let bottom = box.bottom + MARGIN;
  for (
    let node: HTMLElement | null = focused;
    node && node !== doc.body && node !== doc.documentElement;
    node = node.parentElement
  ) {
    const style = host.getComputedStyle(node);
    if (!/(auto|scroll)/.test(style.overflowY)) continue;
    if (node.scrollHeight <= node.clientHeight) continue;
    box = node.getBoundingClientRect();
    const visibleTop = Math.max(box.top, band.top);
    const visibleBottom = Math.min(box.bottom, band.bottom);
    if (visibleBottom - visibleTop < bottom - top) {
      // Taller than what can be seen: its top first.
      bottom = top + (visibleBottom - visibleTop);
    }
    let delta = 0;
    if (bottom > visibleBottom) delta = bottom - visibleBottom;
    else if (top < visibleTop) delta = top - visibleTop;
    const room =
      delta > 0
        ? node.scrollHeight - node.clientHeight - node.scrollTop
        : -node.scrollTop;
    delta = delta > 0 ? Math.min(delta, room) : Math.max(delta, room);
    if (Math.abs(delta) < 1) continue;
    node.scrollBy({ top: delta, behavior: smooth ? "smooth" : "auto" });
    top -= delta;
    bottom -= delta;
  }
}

export function followKeyboard(root: HTMLElement, host: Window): () => void {
  const doc = root.ownerDocument;
  const android = (host as Window & { ShenzhenInsets?: AndroidInsets })
    .ShenzhenInsets;
  let native = 0;
  let covered = -1;
  let open = false;
  let reveal = 0;
  const later = () => {
    host.cancelAnimationFrame(reveal);
    // After the layout that made room: the next frame, once styles and the new viewport have applied.
    reveal = host.requestAnimationFrame(() => {
      reveal = host.requestAnimationFrame(() => revealFocused(doc));
    });
  };
  const update = () => {
    if (android) {
      try {
        const value = Number(JSON.parse(android.insets()).keyboard);
        native = Number.isFinite(value) && value > 0 ? value : 0;
      } catch {
        /* Keep the last value. */
      }
    }
    const view = host.visualViewport;
    const gap = view ? root.clientHeight - view.offsetTop - view.height : 0;
    const nextCovered = gap > KEYBOARD_MIN ? Math.round(gap) : 0;
    const nextOpen = native > 0 || nextCovered > 0;
    if (nextCovered === covered && nextOpen === open) return;
    covered = nextCovered;
    open = nextOpen;
    root.style.setProperty("--keyboard-inset", `${covered}px`);
    if (open) root.dataset.keyboard = "open";
    else delete root.dataset.keyboard;
    host.dispatchEvent(new Event("shenzhen-keyboard"));
    if (open) later();
  };
  const focused = () => {
    if (open) later();
  };
  const view = host.visualViewport;
  host.addEventListener("shenzhen-insets", update);
  host.addEventListener("resize", update);
  view?.addEventListener("resize", update);
  view?.addEventListener("scroll", update);
  doc.addEventListener("focusin", focused);
  update();
  return () => {
    host.removeEventListener("shenzhen-insets", update);
    host.removeEventListener("resize", update);
    view?.removeEventListener("resize", update);
    view?.removeEventListener("scroll", update);
    doc.removeEventListener("focusin", focused);
    host.cancelAnimationFrame(reveal);
  };
}

if (typeof window !== "undefined" && typeof document !== "undefined")
  followKeyboard(document.documentElement, window);
