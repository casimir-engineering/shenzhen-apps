// The on-screen keyboard (src/core/keyboard.ts): Android says how tall it is (the WebView already ends at its top, so
// nothing is covered); iOS and browsers shrink only the visual viewport, so what it covers is measured. Either way
// the root says a keyboard is up, and a browser's toolbar coming and going is not taken for one.
// phones-keyboard.mjs checks the same on an emulator with the system's keyboard.
import { describe, expect, it } from "vitest";
import { followKeyboard } from "../src/core/keyboard";

function page({
  android,
  height = 900,
}: {
  android?: { keyboard: number };
  height?: number;
}) {
  const style = new Map<string, string>();
  const dataset: Record<string, string> = {};
  const listeners = new Map<string, () => void>();
  const viewListeners = new Map<string, () => void>();
  const events: string[] = [];
  const view = { height, offsetTop: 0 } as {
    height: number;
    offsetTop: number;
    addEventListener?: unknown;
    removeEventListener?: unknown;
  };
  view.addEventListener = (type: string, listener: () => void) =>
    viewListeners.set(type, listener);
  view.removeEventListener = (type: string) => viewListeners.delete(type);
  let native = android;
  const host = {
    ShenzhenInsets: android
      ? { insets: () => JSON.stringify({ top: 24, bottom: 0, ...native }) }
      : undefined,
    visualViewport: view,
    innerHeight: height,
    addEventListener: (type: string, listener: () => void) =>
      listeners.set(type, listener),
    removeEventListener: (type: string) => listeners.delete(type),
    dispatchEvent: (event: Event) => events.push(event.type),
    requestAnimationFrame: () => 0,
    cancelAnimationFrame: () => {},
  } as unknown as Window;
  const root = {
    style: {
      setProperty: (name: string, value: string) => style.set(name, value),
    },
    dataset,
    clientHeight: height,
    ownerDocument: {
      addEventListener: () => {},
      removeEventListener: () => {},
      activeElement: null,
      defaultView: host,
    },
  } as unknown as HTMLElement;
  const stop = followKeyboard(root, host);
  return {
    stop,
    style,
    dataset,
    events,
    listeners,
    android(keyboard: number) {
      native = { keyboard };
      listeners.get("shenzhen-insets")?.();
    },
    viewport(visible: number, offsetTop = 0) {
      view.height = visible;
      view.offsetTop = offsetTop;
      viewListeners.get("resize")?.();
    },
  };
}

describe("the on-screen keyboard", () => {
  it("on Android, follows the height the activity gives, covering nothing", () => {
    const p = page({ android: { keyboard: 0 } });
    expect(p.dataset.keyboard).toBeUndefined();
    expect(p.style.get("--keyboard-inset")).toBe("0px");
    p.android(312.38);
    expect(p.dataset.keyboard).toBe("open");
    expect(p.style.get("--keyboard-inset")).toBe("0px");
    expect(p.events).toContain("shenzhen-keyboard");
    p.android(0);
    expect(p.dataset.keyboard).toBeUndefined();
  });

  it("on iOS and in browsers, measures what the keyboard covers of the page", () => {
    const p = page({});
    p.viewport(560);
    expect(p.dataset.keyboard).toBe("open");
    expect(p.style.get("--keyboard-inset")).toBe("340px");
    // Panned up to show the field: the keyboard still starts where the visible part ends.
    p.viewport(560, 120);
    expect(p.style.get("--keyboard-inset")).toBe("220px");
    p.viewport(900);
    expect(p.dataset.keyboard).toBeUndefined();
    expect(p.style.get("--keyboard-inset")).toBe("0px");
  });

  it("does not take a browser's toolbar for a keyboard", () => {
    const p = page({});
    p.viewport(844);
    expect(p.dataset.keyboard).toBeUndefined();
    expect(p.style.get("--keyboard-inset")).toBe("0px");
  });

  it("stops listening when asked", () => {
    const p = page({ android: { keyboard: 0 } });
    p.stop();
    expect(p.listeners.size).toBe(0);
  });
});
