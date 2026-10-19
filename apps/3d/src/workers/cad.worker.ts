/// <reference lib="webworker" />
// Upstream ESM loader has a sibling declaration with the same factory contract.
// @ts-expect-error generated Emscripten module
import OcctFactory from "../../vendor/occt/occt-js.mjs";
import wasmUrl from "../../vendor/occt/occt-js.wasm?url";
import type {
  OcctJSModule,
  OcctJSMatrix4,
  OcctJSExactElementKind,
} from "../../vendor/occt/occt-js";
import type { Pick } from "../core/types";
import { bytesOf, readParams, resultTransfers } from "./kernel-io";
let kernel: Promise<OcctJSModule> | undefined;
const getKernel = (): Promise<OcctJSModule> =>
  (kernel ||= OcctFactory({ locateFile: () => wasmUrl }));
self.onmessage = async ({ data }) => {
  const { id, action, payload } = data;
  try {
    const k = await getKernel();
    let result: unknown;
    if (action === "open") {
      const start = performance.now();
      const r = k.OpenExactModel(
        payload.format,
        new Uint8Array(payload.buffer),
        readParams(payload.quality),
      );
      if (!r.success)
        throw new Error(r.error || "The CAD file could not be read.");
      self.postMessage(
        { id, result: r, importMs: performance.now() - start },
        resultTransfers(r),
      );
      return;
    }
    if (action === "read") {
      // One product of a large assembly: meshes and topology only.
      const r = k.ReadStepFile(await bytesOf(payload.source), readParams(payload.quality));
      if (!r.success) throw new Error(r.error || "The CAD file could not be read.");
      self.postMessage(
        { id, result: { ...r, memoryBytes: (k as unknown as { HEAPU8: Uint8Array }).HEAPU8.buffer.byteLength } },
        resultTransfers(r),
      );
      return;
    }
    if (action === "openPart") {
      // Exact geometry for one product, kept for feature queries.
      const r = k.OpenExactModel("step", await bytesOf(payload.source), readParams(payload.quality));
      if (!r.success || r.exactModelId === undefined)
        throw new Error(r.error || "The CAD file could not be read.");
      result = { exactModelId: r.exactModelId, bindings: r.exactGeometryBindings ?? [] };
    }
    if (action === "release") result = k.ReleaseExactModel(payload.modelId);
    if (action === "properties") {
      const p = payload.pick as Pick;
      const args = [
        payload.modelId,
        p.exactHandle!,
        p.kind as OcctJSExactElementKind,
        p.elementId!,
      ] as const;
      const family = k.GetExactGeometryType(...args),
        radius = k.MeasureExactRadius(...args),
        center = k.MeasureExactCenter(...args);
      const length = k.MeasureExactEdgeLength(...args),
        area = k.MeasureExactFaceArea(...args);
      result = {
        exact: true,
        ...(family.ok ? { family: family.family } : {}),
        ...(radius.ok
          ? { radius: radius.radius, diameter: radius.diameter }
          : {}),
        ...(length.ok ? { length: length.value } : {}),
        ...(area.ok ? { area: area.value } : {}),
        ...(center.ok
          ? { center: center.localCenter }
          : area.ok
            ? { center: area.localCentroid }
            : length.ok
              ? {
                  center: length.localStartPoint.map(
                    (v, i) => (v + length.localEndPoint[i]) / 2,
                  ),
                }
              : {}),
      };
    }
    if (action === "pair") {
      const a = payload.a as Pick,
        b = payload.b as Pick;
      const modelA = payload.modelId as number,
        modelB = (payload.modelIdB ?? payload.modelId) as number;
      const kindA = a.kind as OcctJSExactElementKind,
        kindB = b.kind as OcctJSExactElementKind;
      const ma = a.matrix as OcctJSMatrix4,
        mb = b.matrix as OcctJSMatrix4;
      let angle, distance, thickness, relation;
      if (modelA === modelB) {
        const args = [modelA, a.exactHandle!, kindA, a.elementId!, b.exactHandle!, kindB, b.elementId!, ma, mb] as const;
        angle = k.MeasureExactAngle(...args);
        distance = k.MeasureExactDistance(...args);
        thickness = k.MeasureExactThickness(...args);
        relation = k.ClassifyExactRelation(...args);
      } else {
        // Parts of a large assembly live in separate kernel models.
        const args = [modelA, a.exactHandle!, kindA, a.elementId!, ma, modelB, b.exactHandle!, kindB, b.elementId!, mb] as const;
        angle = k.MeasureExactAngleCrossModel(...args);
        distance = k.MeasureExactDistanceCrossModel(...args);
        thickness = k.MeasureExactThicknessCrossModel(...args);
        relation = k.ClassifyExactRelationCrossModel(...args);
      }
      if (angle.ok) angle.value = (angle.value * 180) / Math.PI;
      result = { distance, angle, thickness, relation };
    }
    self.postMessage({ id, result });
  } catch (error) {
    self.postMessage({
      id,
      error: error instanceof Error ? error.message : String(error),
    });
  }
};
