import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as T from "three";
import { ProgressiveRayTracer } from "../src/core/progressive-ray-tracer";
class FakeCanvas {
  width = 256;
  height = 192;
  style: Record<string, string> = {};
  className = "";
  removed = false;
  setAttribute() {}
  transferControlToOffscreen() {
    return {};
  }
  remove() {
    this.removed = true;
  }
}
class FakeWorker {
  static instances: FakeWorker[] = [];
  onmessage?: (event: { data: any }) => void;
  onerror?: (event: { message: string }) => void;
  terminated = false;
  commands: any[] = [];
  constructor() {
    FakeWorker.instances.push(this);
  }
  postMessage(data: any) {
    this.commands.push(data);
    if (data.type === "init")
      queueMicrotask(() => this.onmessage?.({ data: { type: "prepared" } }));
  }
  terminate() {
    this.terminated = true;
  }
  emit(data: any) {
    this.onmessage?.({ data });
  }
}
function fixture() {
  const canvases: FakeCanvas[] = [],
    states: any[] = [];
  const host = {
    appendChild(canvas: FakeCanvas) {
      canvases.push(canvas);
    },
  } as unknown as HTMLElement;
  const renderer = {
    domElement: new FakeCanvas(),
  } as unknown as T.WebGLRenderer;
  const tracer = new ProgressiveRayTracer(host, renderer, (state) =>
    states.push(state),
  );
  const input = {
    sources: [new T.Mesh(new T.BoxGeometry(), new T.MeshStandardMaterial())],
    camera: new T.PerspectiveCamera(),
  };
  return { tracer, input, canvases, states };
}
beforeEach(() => {
  FakeWorker.instances = [];
  vi.stubGlobal("navigator", { gpu: {} });
  vi.stubGlobal("OffscreenCanvas", class {});
  vi.stubGlobal("HTMLCanvasElement", FakeCanvas);
  vi.stubGlobal("document", { createElement: () => new FakeCanvas() });
  vi.stubGlobal("window", {
    setTimeout: (...args: Parameters<typeof setTimeout>) => setTimeout(...args),
    clearTimeout: (...args: Parameters<typeof clearTimeout>) =>
      clearTimeout(...args),
  });
  vi.stubGlobal("Worker", FakeWorker);
});
afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});
describe("optional ray-tracing lifecycle", () => {
  it("creates no worker or GPU context until enabled and reports unavailable APIs explicitly", async () => {
    const { tracer } = fixture();
    expect(FakeWorker.instances).toHaveLength(0);
    tracer.dispose();
    vi.stubGlobal("navigator", {});
    const f = fixture();
    await f.tracer.prepare(f.input);
    expect(f.states.at(-1).status).toBe("unsupported");
    expect(FakeWorker.instances).toHaveLength(0);
    f.tracer.dispose();
  });
  it("retains external cancellation after prepare resolves and releases the overlay and pending export", async () => {
    const f = fixture(),
      controller = new AbortController();
    await f.tracer.prepare(
      f.input,
      { samples: 32, resolution: 0.5 },
      controller.signal,
    );
    const worker = FakeWorker.instances[0];
    worker.emit({
      type: "state",
      status: "rendering",
      samples: 1,
      target: 32,
      progress: 1 / 32,
    });
    const snapshot = f.tracer.snapshot();
    const rejected = expect(snapshot).rejects.toThrow(/canceled/);
    controller.abort();
    await rejected;
    expect(worker.terminated).toBe(true);
    expect(f.canvases[0].removed).toBe(true);
    f.tracer.dispose();
  });
  it("hides stale images during navigation and resumes only after idle", async () => {
    vi.useFakeTimers();
    const f = fixture();
    const pending = f.tracer.prepare(f.input);
    await vi.runAllTimersAsync();
    await pending;
    const worker = FakeWorker.instances[0];
    worker.emit({
      type: "state",
      status: "rendering",
      samples: 1,
      target: 32,
      progress: 1 / 32,
    });
    expect(f.canvases[0].style.visibility).toBe("visible");
    f.tracer.setMoving(true);
    expect(f.canvases[0].style.visibility).toBe("hidden");
    f.tracer.setMoving(false);
    const before = worker.commands.filter((c) => c.type === "resume").length;
    await vi.advanceTimersByTimeAsync(179);
    expect(worker.commands.filter((c) => c.type === "resume")).toHaveLength(
      before,
    );
    await vi.advanceTimersByTimeAsync(1);
    expect(worker.commands.filter((c) => c.type === "resume")).toHaveLength(
      before + 1,
    );
    f.tracer.dispose();
    vi.useRealTimers();
  });
  it("rejects pending exports and hides the overlay on a GPU error", async () => {
    const f = fixture();
    await f.tracer.prepare(f.input);
    FakeWorker.instances[0].emit({
      type: "state",
      status: "rendering",
      samples: 1,
      target: 32,
      progress: 1 / 32,
    });
    const snapshot = f.tracer.snapshot(),
      rejected = expect(snapshot).rejects.toThrow(/device/);
    FakeWorker.instances[0].emit({
      type: "state",
      status: "error",
      reason: "GPU device lost",
      samples: 0,
      target: 32,
      progress: 0,
    });
    await rejected;
    expect(f.canvases[0].style.visibility).toBe("hidden");
    await expect(f.tracer.snapshot()).rejects.toThrow(/not produced/);
    f.tracer.dispose();
  });
  it("rejects excessive output resolution without creating a worker and refuses an unrendered export", async () => {
    const f = fixture();
    await expect(f.tracer.snapshot()).rejects.toThrow(/not produced/);
    const renderer = {
      domElement: { width: 10000, height: 10000 },
    } as unknown as T.WebGLRenderer;
    const states: any[] = [],
      tracer = new ProgressiveRayTracer(
        { appendChild() {} } as unknown as HTMLElement,
        renderer,
        (s) => states.push(s),
      );
    await tracer.prepare(f.input, { samples: 32, resolution: 1 });
    expect(states.at(-1).reason).toMatch(/pixel budget/);
    expect(FakeWorker.instances).toHaveLength(0);
    tracer.dispose();
    f.tracer.dispose();
  });
});
