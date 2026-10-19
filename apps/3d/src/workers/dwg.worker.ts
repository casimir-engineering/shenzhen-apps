/// <reference lib="webworker" />
import { LibreDwg, Dwg_File_Type } from "@mlightcad/libredwg-web";
self.onmessage = async ({ data }) => {
  try {
    const dwg = await LibreDwg.create(data.wasmPath);
    const ptr = dwg.dwg_read_data(data.buffer, Dwg_File_Type.DWG);
    if (!ptr)
      throw new Error(
        "DWG parser could not read this version or damaged file.",
      );
    try {
      self.postMessage({ result: dwg.convert(ptr) });
    } finally {
      dwg.dwg_free(ptr);
    }
  } catch (e) {
    self.postMessage({ error: e instanceof Error ? e.message : String(e) });
  }
};
