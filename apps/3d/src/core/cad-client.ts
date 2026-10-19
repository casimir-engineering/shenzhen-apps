import type { CadResult, ExactPair, FeatureProperties, Pick } from "./types";
import { SplitExact, type SplitDocument } from "./step/split-exact";

/** Document ids for assemblies read part by part; never a kernel model id. */
const SPLIT_ID_BASE = 2 ** 30;

class CadClient {
  private worker?: Worker;
  private workerGeneration = 0;
  private serial = 0;
  private pending = new Map<
    number,
    { resolve: (value: any) => void; reject: (error: Error) => void }
  >();
  private splitSerial = SPLIT_ID_BASE;
  private splits = new Map<number, SplitExact>();
  private loads = new Set<AbortController>();

  private call<T>(
    action: string,
    payload: unknown,
    transfer: Transferable[] = [],
  ): Promise<T> {
    if (!this.worker) {
      const worker = new Worker(
        new URL("../workers/cad.worker.ts", import.meta.url),
        { type: "module" },
      );
      this.worker = worker;
      this.workerGeneration++;
      worker.onmessage = ({ data }) => {
        if (this.worker !== worker) return;
        const request = this.pending.get(data.id);
        if (request) {
          this.pending.delete(data.id);
          if (data.error) request.reject(new Error(data.error));
          else request.resolve(data.result);
        }
      };
      worker.onerror = (event) => {
        if (this.worker === worker)
          this.cancel(event.message || "CAD engine failed");
      };
    }
    return new Promise((resolve, reject) => {
      const id = ++this.serial;
      this.pending.set(id, { resolve, reject });
      this.worker!.postMessage({ id, action, payload }, transfer);
    });
  }

  open(format: string, buffer: ArrayBuffer, quality = "balanced") {
    const result = this.call<CadResult>("open", { format, buffer, quality }, [
      buffer,
    ]);
    const generation = this.workerGeneration;
    return result.then((value) => ({
      ...value,
      exactWorkerGeneration: generation,
    }));
  }
  /** Signal for a part-by-part load; canceled with any other CAD work. */
  beginLoad(): AbortController {
    const controller = new AbortController();
    this.loads.add(controller);
    return controller;
  }
  endLoad(controller: AbortController) {
    this.loads.delete(controller);
  }
  /** Registers an assembly read part by part and returns its document id. */
  registerSplit(doc: SplitDocument): number {
    const id = ++this.splitSerial;
    this.splits.set(
      id,
      new SplitExact(
        doc,
        (action, payload) => this.call(action, payload),
        () => this.workerGeneration,
      ),
    );
    return id;
  }
  async properties(modelId: number, pick: Pick) {
    const split = this.splits.get(modelId);
    if (split) {
      const resolved = await split.resolve(pick);
      return this.call<FeatureProperties>("properties", {
        modelId: resolved.modelId,
        pick: resolved.pick,
      });
    }
    return this.call<FeatureProperties>("properties", { modelId, pick });
  }
  async pair(modelId: number, a: Pick, b: Pick) {
    const split = this.splits.get(modelId);
    if (split) {
      const [ra, rb] = await Promise.all([split.resolve(a), split.resolve(b)]);
      return this.call<ExactPair>("pair", {
        modelId: ra.modelId,
        modelIdB: rb.modelId,
        a: ra.pick,
        b: rb.pick,
      });
    }
    return this.call<ExactPair>("pair", { modelId, a, b });
  }
  release(modelId: number, generation?: number): Promise<unknown> {
    const split = this.splits.get(modelId);
    if (split) {
      this.splits.delete(modelId);
      return split
        .models()
        .then((ids): Promise<unknown> | boolean =>
          this.worker
            ? Promise.all(
                ids.map((id) => this.call("release", { modelId: id })),
              )
            : false,
        );
    }
    // A terminated worker already freed its native models. Never start a worker
    // for cleanup, or send an old ID into a new worker that may reuse that ID.
    if (
      !this.worker ||
      generation !== this.workerGeneration ||
      modelId > SPLIT_ID_BASE
    )
      return Promise.resolve(false);
    return this.call("release", { modelId });
  }
  cancel(reason = "Import canceled") {
    for (const load of this.loads) load.abort(new Error(reason));
    this.loads.clear();
    this.worker?.terminate();
    this.worker = undefined;
    for (const request of this.pending.values())
      request.reject(new Error(reason));
    this.pending.clear();
  }
}
export const cad = new CadClient();
