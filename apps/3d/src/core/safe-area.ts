// The screen edges the system keeps for itself (status bar, navigation bar or gesture handle, display cutout), as the
// CSS variables --native-inset-top/right/bottom/left, for the Android app, which draws edge to edge but whose WebView
// does not reliably report them through env(safe-area-inset-*). MainActivity.kt gives them as window.ShenzhenInsets
// and fires `shenzhen-insets` when they change (rotation, cutout side, navigation mode). styles.css takes the larger
// of these and env(), which iOS and browsers fill, as --safe-top/right/bottom/left. It also tells the activity
// whether the page is light, so the bars' icons stay readable over it. Elsewhere this does nothing.
type NativeInsets = { insets(): string; lightPage?(light: boolean): void };
declare global {
  interface Window {
    ShenzhenInsets?: NativeInsets;
  }
}

const SIDES = ["top", "right", "bottom", "left"] as const;

export function applyNativeInsets(
  root: HTMLElement,
  native: NativeInsets | undefined,
): () => void {
  if (!native) return () => {};
  const apply = () => {
    let values: Record<string, unknown> = {};
    try {
      values = JSON.parse(native.insets());
    } catch {
      return;
    }
    for (const side of SIDES) {
      const value = Number(values[side]);
      root.style.setProperty(
        `--native-inset-${side}`,
        `${Number.isFinite(value) && value > 0 ? value : 0}px`,
      );
    }
  };
  // The app's own pinch and pan move the model; the page itself never zooms. Without this the WebView keeps a zoom
  // across a rotation (about 6% on a phone turned to landscape), which pushes the right-hand controls off screen.
  const viewport = document.querySelector<HTMLMetaElement>(
    'meta[name="viewport"]',
  );
  if (viewport && !/user-scalable/.test(viewport.content))
    viewport.content += ", maximum-scale=1, user-scalable=no";
  const theme = () => native.lightPage?.(root.dataset.theme === "light");
  apply();
  theme();
  window.addEventListener("shenzhen-insets", apply);
  const observer = new MutationObserver(theme);
  observer.observe(root, { attributes: true, attributeFilter: ["data-theme"] });
  return () => {
    window.removeEventListener("shenzhen-insets", apply);
    observer.disconnect();
  };
}

if (typeof window !== "undefined" && typeof document !== "undefined")
  applyNativeInsets(document.documentElement, window.ShenzhenInsets);
