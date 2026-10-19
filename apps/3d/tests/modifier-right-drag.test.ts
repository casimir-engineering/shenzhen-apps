import { describe, expect, it } from "vitest";
import { PerspectiveCamera, MOUSE, Vector3 } from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { orbitMouseAction, pointerDrag } from "../src/core/navigation-gestures";

const none = { shiftKey: false, ctrlKey: false, metaKey: false };
const drag = (
  button: number,
  extra: Partial<typeof none> & { buttons?: number } = {},
  is2D = false,
) => pointerDrag("onshape", button, { ...none, ...extra }, is2D);

describe("right-drag and two-finger click-drag", () => {
  it("orbits without a modifier, and with Shift or Alt", () => {
    expect(drag(2)).toBe("orbit");
    expect(drag(2, { shiftKey: true })).toBe("orbit");
    expect(drag(2, { buttons: 2 })).toBe("orbit");
  });
  it("pans with Command or Ctrl held", () => {
    expect(drag(2, { metaKey: true })).toBe("pan");
    expect(drag(2, { ctrlKey: true })).toBe("pan");
    expect(drag(2, { ctrlKey: true, metaKey: true, shiftKey: true })).toBe(
      "pan",
    );
  });
  it("pans for a Mac Ctrl+left-click, whether reported as button 2 or as buttons 2", () => {
    expect(drag(2, { ctrlKey: true, buttons: 2 })).toBe("pan");
    expect(drag(0, { ctrlKey: true, buttons: 1 })).toBe("pan");
    expect(drag(0, { ctrlKey: true, buttons: 2 })).toBe("pan");
  });
  it("leaves left, middle and 2D drags as they were", () => {
    expect(drag(0)).toBe("pan");
    expect(drag(1, { metaKey: true })).toBe("pan");
    expect(drag(2, {}, true)).toBe("pan");
    expect(drag(3)).toBe("none");
  });
});

describe("modifier right-drag through OrbitControls", () => {
  class Doc extends EventTarget {}
  class Canvas extends EventTarget {
    ownerDocument = new Doc();
    style = {};
    clientWidth = 600;
    clientHeight = 400;
    getRootNode() {
      return this.ownerDocument;
    }
    setPointerCapture() {}
    releasePointerCapture() {}
    getBoundingClientRect() {
      return { left: 0, top: 0, width: 600, height: 400 };
    }
  }
  const run = (
    mods: Partial<typeof none> & { buttons?: number },
    changeAfterDown?: Partial<typeof none>,
  ) => {
    const el = new Canvas();
    const camera = new PerspectiveCamera(45, 1.5, 0.01, 1000);
    camera.position.set(4, -7, 6);
    camera.up.set(0, 0, 1);
    const controls = new OrbitControls(camera, el as unknown as HTMLElement);
    controls.update();
    const m = { ...none, ...mods };
    const mapped = orbitMouseAction(pointerDrag("onshape", 2, m, false), m);
    controls.mouseButtons.RIGHT =
      mapped === "rotate" ? MOUSE.ROTATE : mapped === "pan" ? MOUSE.PAN : null;
    const ev = (type: string, x: number, y: number, extra = {}) =>
      Object.assign(new Event(type, { cancelable: true }), {
        pointerId: 1,
        pointerType: "mouse",
        button: 2,
        clientX: x,
        clientY: y,
        pageX: x,
        pageY: y,
        ...m,
        ...extra,
      });
    const before = controls.target.clone();
    const dir = camera.position.clone().sub(before).normalize();
    el.dispatchEvent(ev("pointerdown", 300, 200));
    const menu = ev("contextmenu", 300, 200);
    el.dispatchEvent(menu);
    el.ownerDocument.dispatchEvent(
      ev("pointermove", 330, 220, changeAfterDown ?? {}),
    );
    const after = camera.position.clone().sub(controls.target).normalize();
    const result = {
      targetMoved: controls.target.distanceTo(before) > 1e-3,
      rotated: after.distanceTo(dir) > 1e-3,
      menuSuppressed: menu.defaultPrevented,
    };
    controls.dispose();
    return result;
  };
  it("plain right-drag orbits and keeps the view center", () => {
    expect(run({})).toMatchObject({ targetMoved: false, rotated: true });
  });
  it("Command or Ctrl right-drag pans without rotating, and opens no context menu", () => {
    for (const mods of [{ metaKey: true }, { ctrlKey: true }])
      expect(run(mods)).toEqual({
        targetMoved: true,
        rotated: false,
        menuSuppressed: true,
      });
  });
  it("a Mac Ctrl+left-click drag pans and opens no context menu", () => {
    expect(run({ ctrlKey: true, buttons: 2 })).toEqual({
      targetMoved: true,
      rotated: false,
      menuSuppressed: true,
    });
  });
  it("pressing or releasing the key after the drag starts does not change it", () => {
    expect(run({ metaKey: true }, { metaKey: false })).toMatchObject({
      targetMoved: true,
      rotated: false,
    });
    expect(run({}, { metaKey: true, ctrlKey: true })).toMatchObject({
      targetMoved: false,
      rotated: true,
    });
  });
});
