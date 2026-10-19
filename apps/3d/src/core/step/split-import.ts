// Turns a part-by-part STEP load into viewer documents: early views while
// parts are still arriving, then the complete model. All views share built
// geometry and one exact-query registration.
import { cad } from "../cad-client";
import { fromCad } from "../importers";
import type { CadResult, GeometryData, ModelDocument } from "../types";
import type { AssembledModel } from "./step-assemble.ts";
import type { SplitRoute } from "./split-exact";
import { loadSplitStep, type SplitLoadStats } from "./split-loader";

export interface SplitStepOptions {
  name: string;
  quality: string;
  onProgress: (message: string) => void;
  onPartial?: (doc: ModelDocument) => void;
}

/** Last part-by-part load, for diagnostics and benchmarks. */
export let lastSplitStats: SplitLoadStats | undefined;

export async function importSplitStep(
  buffer: ArrayBuffer,
  options: SplitStepOptions,
): Promise<ModelDocument | { fallback: ArrayBuffer }> {
  const controller = cad.beginLoad();
  const routes = new Map<number, SplitRoute>(),
    blobs = new Map<number, Blob>(),
    handles = new Map<string, number>();
  const docId = cad.registerSplit({ routes, blobs, quality: options.quality });
  const shared = new WeakMap<object, GeometryData>();
  // Exact queries find their product through the shape handle on each pick.
  const handleOf = (part: number, localId: string) => {
    const key = part + "/" + localId;
    let handle = handles.get(key);
    if (handle === undefined) {
      handle = handles.size + 1;
      handles.set(key, handle);
      routes.set(handle, { part, localGeometryId: localId });
    }
    return handle;
  };
  const toDocument = (model: AssembledModel, loading: boolean) => {
    const result = {
      success: true,
      sourceFormat: "step",
      sourceUnit: model.sourceUnit,
      unitScaleToMeters: model.unitScaleToMeters,
      rootNodes: model.rootNodes,
      geometries: model.geometries,
      warnings: model.warnings,
      stats: model.stats,
      exactModelId: docId,
      exactGeometryBindings: model.geometries.map((g, i) => ({
        geometryId: g.id,
        exactShapeHandle: handleOf(
          model.origins[i].part,
          model.origins[i].localId,
        ),
      })),
    } as CadResult;
    const doc = fromCad(result, options.name, shared);
    if (loading) doc.loading = true;
    return doc;
  };
  try {
    const outcome = await loadSplitStep(buffer, {
      quality: options.quality,
      onProgress: options.onProgress,
      signal: controller.signal,
      onPlan: (parts) => parts.forEach((p) => blobs.set(p.pd, p.blob)),
      onPartial: options.onPartial
        ? (model) => {
            if (model.geometries.length)
              options.onPartial!(toDocument(model, true));
          }
        : undefined,
    });
    if ("fallback" in outcome) {
      void cad.release(docId);
      return outcome;
    }
    lastSplitStats = outcome.split.stats;
    // Read by the load benchmark (scripts/perf); not used by the interface.
    (globalThis as { __szLoadStats?: SplitLoadStats }).__szLoadStats =
      lastSplitStats;
    return toDocument(outcome.split.model, false);
  } catch (error) {
    void cad.release(docId);
    throw error;
  } finally {
    cad.endLoad(controller);
  }
}
