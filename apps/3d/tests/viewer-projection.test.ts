import { describe, expect, it, vi } from "vitest";
import * as T from "three";
import { Viewer } from "../src/core/viewer";

describe("projection changes after drawing imports", () => {
  it("preserves useful perspective depth precision and camera pose after an orthographic fit", () => {
    const camera = new T.OrthographicCamera(
      -300,
      300,
      200,
      -200,
      0.00001,
      22720,
    );
    camera.up.set(0, 0, 1);
    camera.position.set(750, -505, 525);
    const target = new T.Vector3(226, 19.575, 0.5375);
    camera.lookAt(target);
    const previous = {
      position: camera.position.clone(),
      quaternion: camera.quaternion.clone(),
      up: camera.up.clone(),
    };
    const oldControls = { target, dispose: vi.fn() };
    const newControls = { target: new T.Vector3(), update: vi.fn() };
    const viewer = Object.assign(Object.create(Viewer.prototype) as Viewer, {
      camera,
      controls: oldControls,
      radius: 227.2,
      host: { clientWidth: 1200, clientHeight: 800 },
      makeControls: vi.fn(() => newControls),
      invalidate: vi.fn(),
    });
    viewer.setProjection(false);
    const perspective = viewer.camera as T.PerspectiveCamera;
    const distance = previous.position.distanceTo(target);
    expect(perspective.isPerspectiveCamera).toBe(true);
    expect(perspective.near).toBeCloseTo(distance / 10000, 12);
    expect(perspective.far).toBeCloseTo(distance * 100, 8);
    expect(perspective.far / perspective.near).toBeCloseTo(1_000_000, 5);
    expect(perspective.position.equals(previous.position)).toBe(true);
    expect(perspective.quaternion.equals(previous.quaternion)).toBe(true);
    expect(perspective.up.equals(previous.up)).toBe(true);
    expect(newControls.target.equals(target)).toBe(true);
    expect(oldControls.dispose).toHaveBeenCalledOnce();
    expect(newControls.update).toHaveBeenCalledOnce();
  });
});
