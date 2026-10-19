import * as T from "three";
import { createInstancedEdges } from "./gpu-edges";

/**
 * Jade accents (styles.css --jade family) dark enough to stand out on pale
 * parts and bright enough to stand out on the dark background.
 */
export const SELECTION_COLORS = { dark: 0x22b884, light: 0x197655 } as const;
/** Crease outlines are skipped above this many unique source triangles. */
const OUTLINE_TRIANGLE_BUDGET = 4_000_000;

export interface HighlightEntry {
  geometry: T.BufferGeometry;
  lines: boolean;
  matrices: T.Matrix4[];
}

/**
 * Selected-part emphasis: a light tint that keeps the shading readable, a
 * solid crease outline, and a dashed outline where other parts cover it.
 * Source geometry is shared, never copied, and never disposed here.
 */
export class PartHighlight {
  readonly group = new T.Group();
  private objects: T.Object3D[] = [];

  constructor() {
    this.group.name = "Part selection";
  }

  get size() {
    return this.objects.length;
  }

  update(
    entries: HighlightEntry[],
    theme: "dark" | "light",
    clippingPlanes: T.Plane[],
  ) {
    const color = SELECTION_COLORS[theme];
    const next: T.Object3D[] = [];
    let outlined = 0;
    for (const entry of entries) {
      if (!entry.matrices.length) continue;
      if (entry.lines) {
        for (const matrix of entry.matrices) {
          const line = new T.Line(
            entry.geometry,
            new T.LineBasicMaterial({
              color,
              depthTest: false,
              toneMapped: false,
              clippingPlanes,
            }),
          );
          line.matrixAutoUpdate = false;
          line.matrix.copy(matrix);
          line.renderOrder = 10;
          line.raycast = () => {};
          next.push(line);
        }
        continue;
      }
      const mesh = new T.InstancedMesh(
        entry.geometry,
        new T.MeshBasicMaterial({
          color,
          transparent: true,
          opacity: 0.4,
          toneMapped: false,
          side: T.DoubleSide,
          depthWrite: false,
          polygonOffset: true,
          polygonOffsetFactor: -1,
          polygonOffsetUnits: -1,
          clippingPlanes,
        }),
        entry.matrices.length,
      );
      entry.matrices.forEach((matrix, i) => mesh.setMatrixAt(i, matrix));
      mesh.frustumCulled = false;
      mesh.raycast = () => {};
      mesh.renderOrder = 4;
      next.push(mesh);
      const geometry = entry.geometry;
      outlined +=
        (geometry.index?.count ?? geometry.getAttribute("position").count) / 3;
      if (outlined > OUTLINE_TRIANGLE_BUDGET) continue;
      const visible = createInstancedEdges(mesh, color, 25, {
        opacity: 1,
        depthFunc: T.LessEqualDepth,
      });
      const covered = createInstancedEdges(mesh, color, 25, {
        dashed: true,
        opacity: 0.6,
        depthFunc: T.GreaterDepth,
      });
      visible.renderOrder = covered.renderOrder = 5;
      visible.material.toneMapped = covered.material.toneMapped = false;
      next.push(visible, covered);
    }
    // Build first so shared outline geometry stays cached across refreshes.
    if (next.length) this.group.add(...next);
    this.release(this.objects);
    this.objects = next;
  }

  clear() {
    this.release(this.objects);
    this.objects = [];
  }

  private release(objects: T.Object3D[]) {
    // Outlines borrow their mesh's matrices; release them before the mesh.
    for (const object of [...objects].reverse()) {
      this.group.remove(object);
      if (object instanceof T.InstancedMesh) object.dispose();
      else if (object instanceof T.LineSegments) object.geometry.dispose();
      ((object as T.Mesh).material as T.Material).dispose();
    }
  }
}

/** Below this projected size a ring marks where the selection is. */
const MARKER_BELOW_PX = 24;
const MARKER_PX = 30;

/** A ring around selected parts that are too small on screen to see. */
export class SelectionMarker {
  readonly element = document.createElement("div");
  private corner = new T.Vector3();
  private center = new T.Vector3();

  constructor(host: HTMLElement) {
    this.element.className = "selection-marker";
    Object.assign(this.element.style, {
      position: "absolute",
      width: `${MARKER_PX}px`,
      height: `${MARKER_PX}px`,
      marginLeft: `${-MARKER_PX / 2}px`,
      marginTop: `${-MARKER_PX / 2}px`,
      borderRadius: "50%",
      boxSizing: "border-box",
      pointerEvents: "none",
      zIndex: "3",
    });
    this.element.hidden = true;
    host.appendChild(this.element);
  }

  place(
    bounds: T.Box3,
    camera: T.Camera,
    width: number,
    height: number,
    theme: "dark" | "light",
  ) {
    let show = !bounds.isEmpty();
    let minX = Infinity,
      minY = Infinity,
      maxX = -Infinity,
      maxY = -Infinity;
    for (let i = 0; show && i < 8; i++) {
      this.corner
        .set(
          i & 1 ? bounds.max.x : bounds.min.x,
          i & 2 ? bounds.max.y : bounds.min.y,
          i & 4 ? bounds.max.z : bounds.min.z,
        )
        .project(camera);
      if (!Number.isFinite(this.corner.x + this.corner.y) || this.corner.z > 1)
        show = false;
      minX = Math.min(minX, this.corner.x);
      maxX = Math.max(maxX, this.corner.x);
      minY = Math.min(minY, this.corner.y);
      maxY = Math.max(maxY, this.corner.y);
    }
    const p = bounds.getCenter(this.center).project(camera);
    show &&=
      Math.max(((maxX - minX) * width) / 2, ((maxY - minY) * height) / 2) <
        MARKER_BELOW_PX &&
      Math.abs(p.x) <= 1 &&
      Math.abs(p.y) <= 1;
    this.element.hidden = !show;
    if (!show) return;
    const color = `#${SELECTION_COLORS[theme].toString(16).padStart(6, "0")}`;
    Object.assign(this.element.style, {
      left: `${((p.x + 1) / 2) * width}px`,
      top: `${((1 - p.y) / 2) * height}px`,
      border: `2px solid ${color}`,
      boxShadow: `0 0 0 2px ${theme === "dark" ? "rgba(0,0,0,.45)" : "rgba(255,255,255,.75)"}`,
    });
  }

  dispose() {
    this.element.remove();
  }
}
