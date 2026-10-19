/// <reference lib="webworker" />
// Cuts a large STEP file into one small file per distinct product. Each piece
// goes out as a Blob, so this worker can be closed straight away and the
// source bytes freed with it.
import { planStep } from "../core/step/step-plan.ts";

self.onmessage = ({ data }: MessageEvent<{ buffer: ArrayBuffer }>) => {
  const { buffer } = data;
  let result;
  const blobs = new Map<number, Blob>();
  try {
    result = planStep(new Uint8Array(buffer), (part) =>
      blobs.set(part.pd, new Blob([part.bytes as BlobPart])),
    );
  } catch (error) {
    result = {
      ok: false as const,
      reason: error instanceof Error ? error.message : String(error),
    };
  }
  if (!result.ok) {
    // Hand the bytes back for a whole-file read.
    self.postMessage({ ok: false, reason: result.reason, buffer }, [buffer]);
    return;
  }
  const { plan } = result;
  self.postMessage({
    ok: true,
    assembly: plan.assembly,
    planMs: plan.planMs,
    sourceBytes: plan.sourceBytes,
    parts: plan.parts.map((p) => ({
      pd: p.pd,
      name: p.name,
      uses: p.uses,
      size: p.size,
      blob: blobs.get(p.pd)!,
    })),
  });
};
