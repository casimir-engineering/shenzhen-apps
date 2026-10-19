// Exact feature queries for an assembly that was read product by product.
// A product's exact geometry is read into the CAD worker the first time one of
// its features is queried, and kept until the document closes.
import type { Pick } from "../types";

export interface SplitRoute {
  /** Product key in `blobs`. */
  part: number;
  /** Geometry id inside that product's own file. */
  localGeometryId: string;
}

export interface SplitDocument {
  /** Keyed by the shape handle carried on each pick. */
  routes: Map<number, SplitRoute>;
  blobs: Map<number, Blob>;
  quality: string;
}

type Call = <T>(action: string, payload: unknown) => Promise<T>;
interface Opened {
  generation: number;
  model: Promise<{ exactModelId: number; handles: Map<string, number> }>;
}

export class SplitExact {
  private opened = new Map<number, Opened>();
  constructor(
    private doc: SplitDocument,
    private call: Call,
    private generation: () => number,
  ) {}
  private open(part: number) {
    const current = this.generation();
    let entry = this.opened.get(part);
    if (!entry || entry.generation !== current) {
      const blob = this.doc.blobs.get(part);
      if (!blob)
        return Promise.reject(new Error("This part is no longer available."));
      const model = this.call<{
        exactModelId: number;
        bindings: { geometryId: string; exactShapeHandle: number }[];
      }>("openPart", { source: blob, quality: this.doc.quality }).then((r) => ({
        exactModelId: r.exactModelId,
        handles: new Map(
          r.bindings.map((b) => [b.geometryId, b.exactShapeHandle]),
        ),
      }));
      entry = { generation: current, model };
      model.catch(() => {
        if (this.opened.get(part) === entry) this.opened.delete(part);
      });
      this.opened.set(part, entry);
    }
    return entry.model;
  }
  /** The kernel model and shape handle for a pick, reading its product if needed. */
  async resolve(pick: Pick): Promise<{ modelId: number; pick: Pick }> {
    const route =
      pick.exactHandle === undefined
        ? undefined
        : this.doc.routes.get(pick.exactHandle);
    if (!route) throw new Error("Exact geometry is unavailable for this part.");
    const { exactModelId, handles } = await this.open(route.part);
    const handle = handles.get(route.localGeometryId);
    if (handle === undefined)
      throw new Error("Exact geometry is unavailable for this part.");
    return { modelId: exactModelId, pick: { ...pick, exactHandle: handle } };
  }
  /** Kernel models opened by the current worker, for release. */
  async models(): Promise<number[]> {
    const current = this.generation();
    const live = [...this.opened.values()].filter(
      (o) => o.generation === current,
    );
    this.opened.clear();
    const settled = await Promise.allSettled(live.map((o) => o.model));
    return settled.flatMap((s) =>
      s.status === "fulfilled" ? [s.value.exactModelId] : [],
    );
  }
}
