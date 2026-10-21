// The Android app's own insets become the --safe-* variables styles.css lays the app out with, and follow each
// `shenzhen-insets` event; the page stops zooming there and tells the activity when the theme is light. Browsers and
// iOS, which have no such bridge, keep env().
import { describe, expect, it, vi } from "vitest";

vi.stubGlobal(
  "MutationObserver",
  class {
    constructor(public callback: () => void) {}
    observe() {}
    disconnect() {}
  },
);
const { followNativeInsets } = await import("../src/core/safe-area");

function page(insets: string | null) {
  const style = new Map<string, string>();
  const meta = {
    content: "width=device-width, initial-scale=1.0, viewport-fit=cover",
  };
  const listeners = new Map<string, () => void>();
  const light: boolean[] = [];
  const root = {
    style: {
      setProperty: (name: string, value: string) => style.set(name, value),
    },
    dataset: { theme: "light" },
    ownerDocument: { querySelector: () => meta },
  } as unknown as HTMLElement;
  let current = insets;
  const host = {
    ShenzhenInsets:
      insets === null
        ? undefined
        : {
            insets: () => current!,
            lightPage: (value: boolean) => light.push(value),
          },
    addEventListener: (type: string, listener: () => void) =>
      listeners.set(type, listener),
    removeEventListener: (type: string) => listeners.delete(type),
  } as unknown as Window;
  return {
    stop: followNativeInsets(root, host),
    style,
    meta,
    light,
    change(next: string) {
      current = next;
      listeners.get("shenzhen-insets")?.();
    },
  };
}

describe("safe area on the phone apps", () => {
  it("takes the Android activity's insets and follows them as the phone turns", () => {
    const app = page('{"top":45.33,"right":0,"bottom":24,"left":0}');
    expect(Object.fromEntries(app.style)).toEqual({
      "--safe-top": "45.33px",
      "--safe-right": "0px",
      "--safe-bottom": "24px",
      "--safe-left": "0px",
    });
    app.change('{"top":24,"right":0,"bottom":24,"left":45.33}');
    expect(app.style.get("--safe-top")).toBe("24px");
    expect(app.style.get("--safe-left")).toBe("45.33px");
    app.change("not json");
    expect(app.style.get("--safe-left")).toBe("45.33px");
    expect(app.meta.content).toMatch(/maximum-scale=1, user-scalable=no$/);
    expect(app.light).toEqual([true]);
  });

  it("leaves browsers and iOS on env()", () => {
    const app = page(null);
    expect(app.style.size).toBe(0);
    expect(app.meta.content).not.toMatch(/user-scalable/);
  });
});
