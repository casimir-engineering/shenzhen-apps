import { describe, expect, it } from "vitest";
import {
  AmbientLight,
  DirectionalLight,
  MeshStandardMaterial,
  Vector3,
} from "three";
import {
  applySurfaceRenderStyle,
  DEFAULT_LIGHT_AZIMUTH,
  DEFAULT_LIGHT_ELEVATION,
  isLineOnlyStyle,
  updateViewerLighting,
} from "../src/core/render-styles";

describe("rendering styles and movable lighting", () => {
  it("uses an opaque depth-only pass while retaining original surface flags", () => {
    const material = new MeshStandardMaterial({
      transparent: true,
      opacity: 0.35,
      depthWrite: false,
    });
    material.polygonOffset = true;
    material.polygonOffsetFactor = 2;
    material.polygonOffsetUnits = 3;
    applySurfaceRenderStyle(material, "hidden-line");
    expect(material.colorWrite).toBe(false);
    expect(material.depthWrite).toBe(true);
    expect(material.transparent).toBe(false);
    expect(material.opacity).toBe(1);
    // Viewer reapplies user/material opacity before restoring the surface style.
    material.opacity = 0.35;
    material.transparent = true;
    material.depthWrite = false;
    applySurfaceRenderStyle(material, "shaded");
    expect(material.colorWrite).toBe(true);
    expect(material.opacity).toBe(0.35);
    expect(material.transparent).toBe(true);
    expect(material.depthWrite).toBe(false);
    expect(material.polygonOffsetFactor).toBe(2);
    expect(material.polygonOffsetUnits).toBe(3);
    expect(isLineOnlyStyle("wireframe")).toBe(true);
    expect(isLineOnlyStyle("hidden-line")).toBe(true);
    expect(isLineOnlyStyle("shaded-edges")).toBe(false);
  });

  it("preserves the original light direction/intensity and centers its target", () => {
    const key = new DirectionalLight();
    const ambient = new AmbientLight();
    const center = new Vector3(50, -20, 100);
    const direction = updateViewerLighting(key, ambient, center, 100, {});
    expect(
      direction.distanceTo(new Vector3(1, -2, 3).normalize()),
    ).toBeLessThan(1e-14);
    expect(key.target.position.equals(center)).toBe(true);
    expect(
      key.position.clone().sub(center).normalize().distanceTo(direction),
    ).toBeLessThan(1e-14);
    expect(key.intensity).toBe(3.2);
    expect(ambient.visible).toBe(false);
    expect(ambient.intensity).toBe(0);
    expect(DEFAULT_LIGHT_AZIMUTH).toBeCloseTo(-63.4349488);
    expect(DEFAULT_LIGHT_ELEVATION).toBeCloseTo(53.3007748);
  });

  it("moves the key in Z-up coordinates and clamps invalid light settings", () => {
    const key = new DirectionalLight(),
      ambient = new AmbientLight();
    const direction = updateViewerLighting(key, ambient, new Vector3(), 10, {
      lightAzimuth: 90,
      lightElevation: 0,
      lightIntensity: -2,
      uniformLight: true,
      uniformIntensity: 1.8,
    });
    expect(direction.distanceTo(new Vector3(0, 1, 0))).toBeLessThan(1e-14);
    expect(key.intensity).toBe(0);
    expect(ambient.intensity).toBe(1.8);
    updateViewerLighting(key, ambient, new Vector3(), 1, {
      lightElevation: 200,
      lightIntensity: Number.NaN,
      uniformLight: true,
      uniformIntensity: Number.NaN,
    });
    expect(key.position.clone().normalize().z).toBe(1);
    expect(key.intensity).toBe(3.2);
    expect(ambient.intensity).toBe(2.6);
  });
});
