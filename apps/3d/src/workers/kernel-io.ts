// Shared helpers for the CAD worker: read options per quality setting and the
// list of typed arrays to move (not copy) back to the page.
import type { OcctJSReadParams, OcctJSResult } from "../../vendor/occt/occt-js";

export function readParams(quality?: string): OcctJSReadParams {
  return {
    linearUnit: "millimeter",
    linearDeflectionType: "absolute_value",
    linearDeflection:
      quality === "fine" ? 0.01 : quality === "fast" ? 0.2 : 0.05,
    angularDeflection: 0.3,
    colorMode: "source",
    readNames: true,
    rootMode: "multiple-shapes",
  };
}

/** Buffers of a kernel result that can be transferred to the page. */
export function resultTransfers(result: OcctJSResult): Transferable[] {
  const out = new Set<ArrayBuffer>();
  const add = (a?: ArrayBufferView) => {
    if (
      a &&
      a.buffer instanceof ArrayBuffer &&
      a.byteLength === a.buffer.byteLength
    )
      out.add(a.buffer);
  };
  for (const g of result.geometries ?? []) {
    add(g.positions);
    add(g.normals);
    add(g.indices);
    add(g.triangleToFaceMap);
    for (const e of g.edges) add(e.points);
  }
  return [...out];
}

export async function bytesOf(source: Blob | ArrayBuffer): Promise<Uint8Array> {
  return new Uint8Array(
    source instanceof Blob ? await source.arrayBuffer() : source,
  );
}
