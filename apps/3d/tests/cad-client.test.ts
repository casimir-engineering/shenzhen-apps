import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cad } from "../src/core/cad-client";
import { disposeDocument, fromCad, importFiles } from "../src/core/importers";
import type { CadResult } from "../src/core/types";

class MockWorker {
  static all: MockWorker[] = [];
  onmessage?: (event: { data: unknown }) => void;
  onerror?: (event: { message: string }) => void;
  messages: { id: number; action: string; payload: any }[] = [];
  terminated = false;
  constructor() {
    MockWorker.all.push(this);
  }
  postMessage(message: { id: number; action: string; payload: any }) {
    this.messages.push(message);
  }
  terminate() {
    this.terminated = true;
  }
  respond(result: unknown, id = this.messages.at(-1)!.id) {
    this.onmessage?.({ data: { id, result } });
  }
}
const nativeResult = (): CadResult =>
  ({
    success: true,
    exactModelId: 1,
    geometries: [
      {
        id: "triangle",
        positions: new Float32Array([0, 0, 0, 1, 0, 0, 0, 1, 0]),
        normals: new Float32Array([0, 0, 1, 0, 0, 1, 0, 0, 1]),
        indices: new Uint32Array([0, 1, 2]),
        faces: [{ id: 1, firstIndex: 0, indexCount: 3 }],
      },
    ],
    rootNodes: [
      {
        id: "root",
        name: "Triangle",
        transform: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
        meshes: [0],
        children: [],
      },
    ],
    exactGeometryBindings: [{ geometryId: "triangle", exactShapeHandle: 1 }],
  }) as unknown as CadResult;
const turn = () => new Promise((resolve) => setTimeout(resolve, 0));
async function openDocument() {
  const pending = importFiles(
    [new File(["STEP"], "model.step")],
    "balanced",
    () => {},
  );
  await turn();
  const worker = MockWorker.all.at(-1)!;
  expect(worker.messages.at(-1)!.action).toBe("open");
  worker.respond(nativeResult());
  return { document: await pending, worker };
}
beforeEach(() => {
  cad.cancel();
  MockWorker.all = [];
  vi.stubGlobal("Worker", MockWorker);
});
afterEach(() => {
  cad.cancel();
  vi.unstubAllGlobals();
});

describe("CAD worker model ownership", () => {
  it("cancel followed by mesh import and old document cleanup does not restart CAD", async () => {
    const { document, worker } = await openDocument();
    expect(document.exactWorkerGeneration).toBeTypeOf("number");
    cad.cancel();
    disposeDocument(document);
    const mesh = await importFiles(
      [new File(["v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n"], "triangle.obj")],
      "balanced",
      () => {},
    );
    expect(mesh.parts).toHaveLength(1);
    expect(worker.terminated).toBe(true);
    expect(MockWorker.all).toHaveLength(1);
    expect(worker.messages.map((message) => message.action)).toEqual(["open"]);
    disposeDocument(mesh);
  });

  it("ignores old worker IDs after cancellation even if a new model reuses the same ID", async () => {
    const old = await openDocument();
    cad.cancel();
    const fresh = await openDocument();
    expect(old.document.exactModelId).toBe(fresh.document.exactModelId);
    expect(old.document.exactWorkerGeneration).not.toBe(
      fresh.document.exactWorkerGeneration,
    );
    disposeDocument(old.document);
    expect(fresh.worker.messages.map((message) => message.action)).toEqual([
      "open",
    ]);
    disposeDocument(fresh.document);
    expect(fresh.worker.messages.at(-1)).toMatchObject({
      action: "release",
      payload: { modelId: 1 },
    });
    fresh.worker.respond(true);
    await turn();
  });

  it("does not assign worker ownership to direct kernel imports", async () => {
    const fresh = await openDocument();
    const direct = fromCad(nativeResult(), "native.step");
    expect(direct.exactWorkerGeneration).toBeUndefined();
    disposeDocument(direct);
    expect(fresh.worker.messages.map((message) => message.action)).toEqual([
      "open",
    ]);
    cad.cancel();
    expect(await cad.release(1, fresh.document.exactWorkerGeneration)).toBe(
      false,
    );
    expect(MockWorker.all).toHaveLength(1);
  });

  it("rejects pending canceled work and ignores delayed events from a terminated worker", async () => {
    const pending = cad.open("step", new ArrayBuffer(4));
    const rejection = expect(pending).rejects.toThrow("superseded");
    const stale = MockWorker.all[0];
    cad.cancel("superseded");
    await rejection;
    const fresh = await openDocument();
    stale.onerror?.({ message: "late old-worker error" });
    expect(fresh.worker.terminated).toBe(false);
    const release = cad.release(1, fresh.document.exactWorkerGeneration);
    let released = false;
    void release.then(() => {
      released = true;
    });
    stale.respond(true, fresh.worker.messages.at(-1)!.id);
    await turn();
    expect(released).toBe(false);
    fresh.worker.respond(true);
    await release;
  });
});
