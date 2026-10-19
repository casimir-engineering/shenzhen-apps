// Joins separately read products back into one model with the same tree, node
// numbering and geometry order the kernel produces for a whole-file read.
// Repeated products share one geometry, so every repeat is an instance.
import type {
  OcctJSExactGeometryBinding,
  OcctJSExactOpenResult,
  OcctJSGeometry,
  OcctJSNode,
} from "../../../vendor/occt/occt-js";
import { multiply, type StepAssembly } from "./step-assembly.ts";

export interface PartResult {
  /** Kernel result for the product's own file, or undefined if it had no shape. */
  result?: OcctJSExactOpenResult;
}

export interface AssembledBinding extends OcctJSExactGeometryBinding {
  exactModelId: number;
}

export interface GeometryOrigin {
  /** Product key the geometry was read from. */
  part: number;
  /** Geometry id inside that product's own file. */
  localId: string;
}

export interface AssembledModel {
  rootNodes: OcctJSNode[];
  geometries: OcctJSGeometry[];
  /** Where each geometry came from, parallel to `geometries`. */
  origins: GeometryOrigin[];
  exactGeometryBindings: AssembledBinding[];
  /** Every kernel model that must be released with this document. */
  exactModelIds: number[];
  stats: {
    nodeCount: number;
    partCount: number;
    geometryCount: number;
    triangleCount: number;
    reusedInstanceCount: number;
    rootCount: number;
    materialCount: number;
  };
  warnings: unknown[];
  sourceUnit?: string;
  unitScaleToMeters?: number;
}

const IDENTITY = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
// The kernel reports placements in single precision; matching it keeps saved
// review projects bound to the same parts whichever way the file was read.
const single = (m: number[]) => m.map(Math.fround);

export function assembleModel(
  assembly: StepAssembly,
  parts: Map<number, PartResult>,
): AssembledModel {
  let nodeSerial = 0;
  const geometries: OcctJSGeometry[] = [];
  const origins: GeometryOrigin[] = [];
  const bindings: AssembledBinding[] = [];
  // Per part result: local geometry index -> global geometry index.
  const remap = new Map<OcctJSExactOpenResult, Map<number, number>>();
  let instances = 0,
    partCount = 0;
  const geometryIndex = (
    pd: number,
    result: OcctJSExactOpenResult,
    local: number,
  ) => {
    let map = remap.get(result);
    if (!map) remap.set(result, (map = new Map()));
    let global = map.get(local);
    if (global === undefined) {
      const g = result.geometries![local];
      const binding = result.exactGeometryBindings?.find(
        (b) => b.geometryId === g.id,
      );
      global = geometries.length;
      const id = "geo_" + global;
      geometries.push({ ...g, id });
      origins.push({ part: pd, localId: g.id });
      if (binding && result.exactModelId !== undefined)
        bindings.push({
          geometryId: id,
          exactShapeHandle: binding.exactShapeHandle,
          exactModelId: result.exactModelId,
        });
      map.set(local, global);
    } else instances++;
    return global;
  };
  const copyNode = (
    pd: number,
    node: OcctJSNode,
    result: OcctJSExactOpenResult,
    transform?: number[],
  ): OcctJSNode => {
    const id = "node_" + nodeSerial++;
    const meshes = node.meshes.map((m) => geometryIndex(pd, result, m));
    if (meshes.length) partCount++;
    return {
      id,
      name: node.name,
      isAssembly: node.isAssembly,
      transform: transform ?? node.transform,
      meshes,
      children: node.children.map((c) => copyNode(pd, c, result)),
    };
  };
  const visit = (pd: number, transform: number[]): OcctJSNode[] => {
    const product = assembly.products.get(pd)!;
    if (!product.occurrences.length) {
      const result = parts.get(pd)?.result;
      if (!result?.rootNodes?.length)
        // The kernel keeps shapeless parts as empty leaves.
        return [
          {
            id: "node_" + nodeSerial++,
            name: product.name,
            isAssembly: false,
            transform,
            meshes: [],
            children: [],
          },
        ];
      // A product read on its own has one root; several roots are kept as siblings.
      return result.rootNodes.map((root) =>
        copyNode(pd, root, result, single(multiply(transform, root.transform))),
      );
    }
    const node: OcctJSNode = {
      id: "node_" + nodeSerial++,
      name: product.name,
      isAssembly: true,
      transform,
      meshes: [],
      children: [],
    };
    for (const o of product.occurrences)
      node.children.push(...visit(o.child, single(o.matrix)));
    return [node];
  };
  // Several top-level products sit under one synthetic root, as in a whole-file
  // read; it takes a node number but keeps a fixed id.
  const wrap = assembly.roots.length > 1;
  if (wrap) nodeSerial++;
  const top = assembly.roots.flatMap((pd) => visit(pd, IDENTITY));
  const rootNodes: OcctJSNode[] = wrap
    ? [
        {
          id: "__root__",
          name: "Root",
          isAssembly: true,
          transform: IDENTITY,
          meshes: [],
          children: top,
        },
      ]
    : top;
  const first = [...parts.values()].find((p) => p.result)?.result;
  const warnings = [...parts.values()].flatMap((p) => p.result?.warnings ?? []);
  return {
    rootNodes,
    geometries,
    origins,
    exactGeometryBindings: bindings,
    exactModelIds: [...parts.values()].flatMap((p) =>
      p.result?.exactModelId !== undefined ? [p.result.exactModelId] : [],
    ),
    stats: {
      rootCount: rootNodes.length,
      nodeCount: nodeSerial,
      partCount,
      geometryCount: geometries.length,
      triangleCount: geometries.reduce((s, g) => s + g.indices.length / 3, 0),
      reusedInstanceCount: instances,
      materialCount: 0,
    },
    warnings,
    sourceUnit: first?.sourceUnit,
    unitScaleToMeters: first?.unitScaleToMeters,
  };
}
