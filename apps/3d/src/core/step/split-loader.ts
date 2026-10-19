// Opens a large STEP assembly product by product: a planning worker cuts the
// file into one piece per distinct product, a small worker pool reads the
// pieces in parallel, and the results are joined into one model in which each
// repeated product is a single shared geometry. A first view is offered while
// the slowest products are still being read.
import type { StepAssembly } from "./step-assembly.ts";
import {
  assembleModel,
  type AssembledModel,
  type PartResult,
} from "./step-assemble.ts";
import {
  PartPool,
  poolBudget,
  poolSize,
  readMemoryEstimate,
} from "./part-pool";
import type { OcctJSExactOpenResult } from "../../../vendor/occt/occt-js";

export interface PlannedPart {
  pd: number;
  name: string;
  uses: number;
  size: number;
  blob: Blob;
}

export interface SplitLoadStats {
  planMs: number;
  readMs: number;
  firstViewMs?: number;
  parts: number;
  workers: number;
  recycledWorkers: number;
  peakWorkerMemoryMB: number;
}

export interface SplitResult {
  model: AssembledModel;
  parts: PlannedPart[];
  stats: SplitLoadStats;
}

export interface SplitLoadOptions {
  quality: string;
  onProgress: (message: string) => void;
  /** Receives a model of the parts read so far, while loading continues. */
  onPartial?: (model: AssembledModel) => void;
  /** Receives every product's own file as soon as the assembly is planned. */
  onPlan?: (parts: PlannedPart[]) => void;
  signal: AbortSignal;
}

type PlanReply =
  | { ok: false; reason: string; buffer: ArrayBuffer }
  | { ok: true; assembly: StepAssembly; parts: PlannedPart[]; planMs: number };

const FIRST_VIEW_MS = 900,
  PARTIAL_EVERY_MS = 3000;

function plan(buffer: ArrayBuffer, signal: AbortSignal): Promise<PlanReply> {
  const worker = new Worker(
    new URL("../../workers/step-plan.worker.ts", import.meta.url),
    { type: "module" },
  );
  return new Promise<PlanReply>((resolve, reject) => {
    const abort = () => reject(new Error("Import canceled"));
    signal.addEventListener("abort", abort, { once: true });
    worker.onmessage = ({ data }) => resolve(data);
    worker.onerror = (event) =>
      reject(new Error(event.message || "The STEP file could not be read."));
    worker.postMessage({ buffer }, [buffer]);
  }).finally(() => worker.terminate());
}

/** Returns undefined when the file must be read in one piece; `buffer` comes back in `fallback`. */
export async function loadSplitStep(
  buffer: ArrayBuffer,
  options: SplitLoadOptions,
): Promise<{ split: SplitResult } | { fallback: ArrayBuffer }> {
  const { signal, onProgress } = options;
  onProgress("Preparing assembly…");
  const planned = await plan(buffer, signal);
  if (!planned.ok) return { fallback: planned.buffer };
  const { assembly, parts } = planned;
  options.onPlan?.(parts);
  const pool = new PartPool(Math.min(poolSize(), parts.length));
  const results = new Map<number, PartResult>();
  const warnings: string[] = [];
  const started = performance.now();
  let firstViewMs: number | undefined,
    lastPartial = -Infinity,
    done = 0;
  const closePool = () => pool.close();
  signal.addEventListener("abort", closePool, { once: true });
  // Largest pieces start first so the slowest finish in time; one worker takes
  // the smallest first so the board and most parts appear early. A piece only
  // starts when the workers' combined memory stays within the budget.
  const queue = parts.slice();
  const budget = poolBudget(pool.size);
  const running = new Array<number>(pool.size).fill(0);
  let wake: (() => void) | undefined;
  const settle = () => {
    const w = wake;
    wake = undefined;
    w?.();
  };
  const fits = (lane: number, size: number) => {
    let others = 0,
      busy = false;
    for (let i = 0; i < pool.size; i++)
      if (i !== lane) {
        others += Math.max(pool.memory(i), running[i]);
        busy ||= running[i] > 0;
      }
    return !busy || others + readMemoryEstimate(size) <= budget;
  };
  const next = async (lane: number): Promise<PlannedPart | undefined> => {
    for (;;) {
      if (!queue.length || signal.aborted) return undefined;
      const order =
        lane === 0 && pool.size > 1
          ? [...queue.keys()].reverse()
          : [...queue.keys()];
      const pick = order.find((i) => fits(lane, queue[i].size));
      if (pick !== undefined) {
        const [part] = queue.splice(pick, 1);
        running[lane] = readMemoryEstimate(part.size);
        return part;
      }
      await new Promise<void>((resolve) => {
        const previous = wake;
        wake = () => {
          previous?.();
          resolve();
        };
      });
    }
  };
  const partial = () => {
    if (!options.onPartial || done === parts.length) return;
    const now = performance.now() - started;
    if (now < FIRST_VIEW_MS || now - lastPartial < PARTIAL_EVERY_MS) return;
    lastPartial = now;
    firstViewMs ??= now;
    options.onPartial(assembleModel(assembly, results));
  };
  const lane = async (index: number) => {
    for (let part = await next(index); part; part = await next(index)) {
      try {
        const result = (await pool.read(
          index,
          part.blob,
          options.quality,
        )) as OcctJSExactOpenResult;
        results.set(part.pd, { result });
      } catch (error) {
        if (signal.aborted) throw error;
        warnings.push(
          `${part.name || "A part"} could not be read and is not shown.`,
        );
        results.set(part.pd, {});
      } finally {
        running[index] = 0;
        settle();
      }
      done++;
      onProgress(`Loading parts · ${done} of ${parts.length}`);
      partial();
    }
  };
  signal.addEventListener("abort", settle, { once: true });
  const timer = setInterval(partial, 250);
  try {
    await Promise.all(Array.from({ length: pool.size }, (_, i) => lane(i)));
  } finally {
    clearInterval(timer);
    signal.removeEventListener("abort", closePool);
    pool.close();
  }
  if (signal.aborted) throw new Error("Import canceled");
  const model = assembleModel(assembly, results);
  model.warnings.push(...warnings);
  return {
    split: {
      model,
      parts,
      stats: {
        planMs: planned.planMs,
        readMs: performance.now() - started,
        firstViewMs,
        parts: parts.length,
        workers: pool.size,
        recycledWorkers: pool.recycled,
        peakWorkerMemoryMB: Math.round(pool.peakMemoryBytes / 1048576),
      },
    },
  };
}
