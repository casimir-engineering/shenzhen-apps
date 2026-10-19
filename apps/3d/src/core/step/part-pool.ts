// A few short-lived CAD workers that read products of a large assembly in
// parallel. They keep no exact geometry and are closed when loading ends, which
// returns all of their memory. A worker that grew large is replaced early.
import type { OcctJSResult } from "../../../vendor/occt/occt-js";

export interface PartRead extends OcctJSResult {
  memoryBytes?: number;
}

const MB = 1024 * 1024;
/** Replace a worker after it has grown beyond this much kernel memory. */
const RECYCLE_BYTES = 160 * MB;
/** Kernel memory of a fresh worker. */
export const FRESH_WORKER_BYTES = 32 * MB;
/** Expected kernel memory while reading a product file of `size` bytes. */
export const readMemoryEstimate = (size: number) =>
  FRESH_WORKER_BYTES + 60 * size;

/** Kernel memory all reading workers may use together. */
export function poolBudget(size: number): number {
  return size <= 2 ? 384 * MB : 640 * MB;
}

export function poolSize(): number {
  const nav = typeof navigator === "undefined" ? undefined : navigator;
  const cores = nav?.hardwareConcurrency || 2;
  const memory = (nav as { deviceMemory?: number } | undefined)?.deviceMemory;
  // Phones and tablets get less memory per page; read fewer parts at once.
  const handheld =
    typeof matchMedia === "function" && matchMedia("(pointer: coarse)").matches;
  const byMemory = handheld || (memory !== undefined && memory <= 4) ? 2 : 4;
  return Math.max(1, Math.min(byMemory, cores - 2));
}

interface Slot {
  worker: Worker;
  busy: boolean;
  memory: number;
}

export class PartPool {
  private slots: Slot[] = [];
  private serial = 0;
  private pending = new Map<
    number,
    { resolve: (r: PartRead) => void; reject: (e: Error) => void; slot: Slot }
  >();
  peakMemoryBytes = 0;
  recycled = 0;
  constructor(readonly size: number) {
    for (let i = 0; i < size; i++) this.slots.push(this.spawn());
  }
  private spawn(): Slot {
    const worker = new Worker(
      new URL("../../workers/cad.worker.ts", import.meta.url),
      { type: "module" },
    );
    const slot: Slot = { worker, busy: false, memory: FRESH_WORKER_BYTES };
    worker.onmessage = ({ data }) => {
      const request = this.pending.get(data.id);
      if (!request) return;
      this.pending.delete(data.id);
      if (data.error) request.reject(new Error(data.error));
      else request.resolve(data.result);
    };
    worker.onerror = (event) => {
      event.preventDefault?.();
      for (const [id, request] of this.pending)
        if (request.slot === slot) {
          this.pending.delete(id);
          request.reject(new Error(event.message || "CAD engine failed"));
        }
      this.replace(slot);
    };
    return slot;
  }
  private replace(slot: Slot) {
    const i = this.slots.indexOf(slot);
    if (i < 0) return;
    slot.worker.terminate();
    this.slots[i] = this.spawn();
  }
  /** Reads one product on worker `lane`. */
  async read(lane: number, source: Blob, quality: string): Promise<PartRead> {
    const slot = this.slots[lane];
    slot.busy = true;
    try {
      const result = await new Promise<PartRead>((resolve, reject) => {
        const id = ++this.serial;
        this.pending.set(id, { resolve, reject, slot });
        slot.worker.postMessage({
          id,
          action: "read",
          payload: { source, quality },
        });
      });
      const memory = result.memoryBytes ?? 0;
      slot.memory = memory;
      this.peakMemoryBytes = Math.max(this.peakMemoryBytes, memory);
      // Kernel memory never shrinks, so a worker that grew is replaced.
      if (memory > RECYCLE_BYTES && this.slots[lane] === slot) {
        this.recycled++;
        this.replace(slot);
      }
      return result;
    } finally {
      slot.busy = false;
    }
  }
  /** Kernel memory a worker holds now. */
  memory(lane: number) {
    return this.slots[lane]?.memory ?? 0;
  }
  busy(lane: number) {
    return this.slots[lane]?.busy ?? false;
  }
  close() {
    for (const slot of this.slots) slot.worker.terminate();
    for (const request of this.pending.values())
      request.reject(new Error("Import canceled"));
    this.pending.clear();
    this.slots = [];
  }
}
