// Decides whether a STEP file can be read product by product and, if so, cuts
// every distinct product into its own small STEP file. Runs in a worker; the
// caller drops the source bytes as soon as this returns.
import { indexStep } from "./step-index.ts";
import { readAssembly, type StepAssembly } from "./step-assembly.ts";
import { linkStep, productChunk } from "./step-chunk.ts";

export interface StepPart {
  /** Product definition entity index (key in the assembly). */
  pd: number;
  name: string;
  /** Standalone STEP bytes for this product (empty once handed to `onPart`). */
  bytes: Uint8Array;
  size: number;
  /** How many times the product appears in the assembly. */
  uses: number;
}

export interface StepPlan {
  assembly: StepAssembly;
  /** Distinct products with their own shape, largest first. */
  parts: StepPart[];
  sourceBytes: number;
  planMs: number;
}

export type StepPlanResult =
  { ok: true; plan: StepPlan } | { ok: false; reason: string };

/**
 * `onPart` receives each product's bytes as soon as they are cut and may keep
 * them elsewhere; the plan then holds sizes only, so pieces never pile up.
 */
export function planStep(
  bytes: Uint8Array,
  onPart?: (part: StepPart) => void,
): StepPlanResult {
  const started = performance.now();
  let index;
  try {
    index = indexStep(bytes);
  } catch (error) {
    return {
      ok: false,
      reason: error instanceof Error ? error.message : String(error),
    };
  }
  const read = readAssembly(index);
  if (!read.ok) return read;
  const { assembly } = read;
  const uses = new Map<number, number>();
  const count = (pd: number, times: number) => {
    const product = assembly.products.get(pd)!;
    if (!product.occurrences.length) {
      uses.set(pd, (uses.get(pd) ?? 0) + times);
      return;
    }
    for (const o of product.occurrences) count(o.child, times);
  };
  assembly.roots.forEach((pd) => count(pd, 1));
  const shaped = [...assembly.products.values()].filter(
    (p) => p.hasShape && uses.has(p.pd),
  );
  // A single part gains nothing from splitting.
  if (shaped.length < 2) return { ok: false, reason: "single part" };
  const links = linkStep(index);
  const parts = shaped.map((p) => {
    const piece = productChunk(index, links, p);
    const part: StepPart = {
      pd: p.pd,
      name: p.name,
      bytes: piece,
      size: piece.length,
      uses: uses.get(p.pd)!,
    };
    if (!onPart) return part;
    onPart(part);
    return { ...part, bytes: new Uint8Array(0) };
  });
  parts.sort((a, b) => b.size - a.size);
  return {
    ok: true,
    plan: {
      assembly,
      parts,
      sourceBytes: bytes.length,
      planMs: performance.now() - started,
    },
  };
}
