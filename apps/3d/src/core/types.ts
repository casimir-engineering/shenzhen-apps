import type { BufferGeometry, Material } from "three";
import type {
  OcctJSGeometry,
  OcctJSExactElementKind,
  OcctJSExactOpenResult,
} from "../../vendor/occt/occt-js";
export type Vec3 = [number, number, number];
export type Unit = "mm" | "cm" | "m" | "in" | "ft" | "um";
export type SelectionMode = "point" | "feature" | "part";
export type FeatureFilter = "auto" | "face" | "edge" | "vertex";
export type ToolMode = "distance" | "angle" | "path";
export type CadResult = OcctJSExactOpenResult & {
  /** Runtime ownership only; direct kernel results have no browser worker owner. */
  exactWorkerGeneration?: number;
};
export interface GeometryData {
  id: string;
  geometry: BufferGeometry;
  materials: Material[];
  topology?: OcctJSGeometry;
  exactHandle?: number;
  lines?: boolean;
}
export interface Part {
  id: string;
  name: string;
  geometryId: string;
  matrix: number[];
  parentId: string;
  path: string[];
}
export interface TreeNode {
  id: string;
  name: string;
  children: TreeNode[];
  partIds: string[];
}
export interface ModelDocument {
  name: string;
  format: string;
  parts: Part[];
  geometries: Map<string, GeometryData>;
  roots: TreeNode[];
  unit: Unit;
  sourceUnit: string;
  warnings: string[];
  importMs: number;
  bytes: number;
  exactModelId?: number;
  exactWorkerGeneration?: number;
  is2D: boolean;
  /** An early view of a large assembly while the rest is still loading. */
  loading?: boolean;
}
export interface Pick {
  id: string;
  partId: string;
  partName: string;
  geometryId: string;
  point: Vec3;
  localPoint: Vec3;
  kind: "point" | OcctJSExactElementKind;
  elementId?: number;
  triangleIndex?: number;
  snap: string;
  exactHandle?: number;
  matrix: number[];
}
export interface FeatureProperties {
  family?: string;
  length?: number;
  perimeter?: number;
  area?: number;
  radius?: number;
  diameter?: number;
  center?: Vec3;
  exact: boolean;
}
export interface Measurement {
  id: string;
  name: string;
  kind: ToolMode;
  reference?: "minimum" | "center" | "picked";
  points: Pick[];
  distance?: number;
  delta?: Vec3;
  angle?: number;
  path?: Vec3[];
  surfaceLength?: number;
  exact: boolean;
  note?: string;
}
export interface ExactPair {
  distance?: {
    ok: boolean;
    value: number;
    pointA: Vec3;
    pointB: Vec3;
    message?: string;
  };
  angle?: { ok: boolean; value: number; message?: string };
  thickness?: { ok: boolean; value: number; message?: string };
  relation?: { ok: boolean; kind: string };
}
