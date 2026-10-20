// The screen edges the system keeps for itself (status bar, navigation bar or gesture handle, display cutout), as
// the CSS variables --safe-top/right/bottom/left that styles.css lays the app out with. Browsers and iOS fill them
// from env(safe-area-inset-*). The Android app draws edge to edge, but its WebView does not report the insets
// reliably, so MainActivity.kt gives its own in CSS pixels, as window.ShenzhenInsets.insets(), and says when they
// change (rotation, cutout side, navigation mode) with a `shenzhen-insets` event. It also takes lightPage(), so the
// bars' icons stay readable over the light theme. Elsewhere this does nothing.
type Insets = Partial<Record<(typeof SIDES)[number], unknown>>;
type AndroidInsets = { insets(): string; lightPage?(light: boolean): void };
declare global {
  interface Window {
    ShenzhenInsets?: AndroidInsets;
  }
}

const SIDES = ["top", "right", "bottom", "left"] as const;

export function setInsets(root: HTMLElement, insets: Insets | undefined) {
  if (!insets) return;
  for (const side of SIDES) {
    const value = Number(insets[side]);
    root.style.setProperty(
      `--safe-${side}`,
      `${Number.isFinite(value) && value > 0 ? value : 0}px`,
    );
  }
}

export function followNativeInsets(
  root: HTMLElement,
  host: Window,
): () => void {
  const android = host.ShenzhenInsets;
  if (!android) return () => {};
  const apply = () => {
    try {
      setInsets(root, JSON.parse(android.insets()));
    } catch {
      /* Keep the last insets. */
    }
  };
  host.addEventListener("shenzhen-insets", apply);
  apply();
  // The app's own pinch and pan move the model; the page itself never zooms. Without this the WebView keeps a
  // zoom across a rotation (about 6% on a phone turned to landscape), pushing the right-hand controls off screen.
  const viewport = root.ownerDocument.querySelector<HTMLMetaElement>(
    'meta[name="viewport"]',
  );
  if (viewport && !/user-scalable/.test(viewport.content))
    viewport.content += ", maximum-scale=1, user-scalable=no";
  const theme = () => android.lightPage?.(root.dataset.theme === "light");
  theme();
  const observer = new MutationObserver(theme);
  observer.observe(root, { attributes: true, attributeFilter: ["data-theme"] });
  return () => {
    host.removeEventListener("shenzhen-insets", apply);
    observer.disconnect();
  };
}

if (typeof window !== "undefined" && typeof document !== "undefined")
  followNativeInsets(document.documentElement, window);
