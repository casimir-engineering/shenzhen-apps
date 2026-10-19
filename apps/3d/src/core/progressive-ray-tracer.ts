import type * as T from "three";
import {
  serializeTraceScene,
  traceCamera,
  traceTransfers,
} from "./ray-tracing-scene";
import { traceResourceEstimate } from "./ray-tracing-types";
import type {
  RayTracingInput,
  RayTracingSettings,
  RayTracingState,
} from "./ray-tracing-types";
export type {
  RayTracingInput,
  RayTracingLighting,
  RayTracingSettings,
  RayTracingState,
} from "./ray-tracing-types";
/** Optional worker-owned WebGPU overlay. Construction alone creates no worker or GPU context. */
export class ProgressiveRayTracer {
  readonly available =
    typeof navigator !== "undefined" &&
    !!navigator.gpu &&
    typeof OffscreenCanvas !== "undefined" &&
    typeof HTMLCanvasElement !== "undefined" &&
    "transferControlToOffscreen" in HTMLCanvasElement.prototype;
  private worker?: Worker;
  private canvas?: HTMLCanvasElement;
  private abort?: AbortController;
  private removeExternalAbort?: () => void;
  private generation = 0;
  private moving = false;
  private prepared = false;
  private idleTimer?: number;
  private resolvePrepare?: () => void;
  private snapshots = new Map<
    number,
    { resolve: (blob: Blob) => void; reject: (error: Error) => void }
  >();
  private serial = 0;
  private settings: RayTracingSettings = { samples: 32, resolution: 0.5 };
  private disposed = false;
  constructor(
    private host: HTMLElement,
    private renderer: T.WebGLRenderer,
    private onState: (state: RayTracingState) => void = () => {},
  ) {}
  get imageVisible() {
    return this.canvas?.style.visibility === "visible";
  }
  private state(
    status: RayTracingState["status"],
    extra: Partial<RayTracingState> = {},
  ) {
    this.onState({
      status,
      samples: 0,
      target: this.settings.samples,
      progress: 0,
      ...extra,
    });
  }
  private size() {
    const canvas = this.renderer.domElement;
    return {
      width: Math.max(1, Math.floor(canvas.width * this.settings.resolution)),
      height: Math.max(1, Math.floor(canvas.height * this.settings.resolution)),
    };
  }
  async prepare(
    input: RayTracingInput,
    settings: RayTracingSettings = this.settings,
    signal?: AbortSignal,
  ): Promise<void> {
    this.cancel();
    if (this.disposed) return;
    this.settings = settings;
    if (!this.available) {
      this.state("unsupported", {
        reason:
          "GPU ray tracing requires WebGPU and worker OffscreenCanvas. Raster rendering remains available.",
      });
      return;
    }
    const generation = this.generation,
      abort = (this.abort = new AbortController());
    const cancel = () => {
      if (generation === this.generation) this.cancel();
    };
    signal?.addEventListener("abort", cancel, { once: true });
    this.removeExternalAbort = () =>
      signal?.removeEventListener("abort", cancel);
    if (signal?.aborted) {
      this.cancel();
      return;
    }
    let ownedScene: Awaited<ReturnType<typeof serializeTraceScene>> | undefined;
    let transferred = false;
    this.state("preparing");
    try {
      const scene = (ownedScene = await serializeTraceScene(
        input,
        abort.signal,
        undefined,
        (progress) => this.state("preparing", { progress: progress * 0.2 }),
      ));
      if (abort.signal.aborted || generation !== this.generation) return;
      const size = this.size();
      traceResourceEstimate(
        scene.estimatedBytes,
        size.width,
        size.height,
        scene.budget,
      );
      const canvas = (this.canvas = document.createElement("canvas"));
      canvas.setAttribute("aria-hidden", "true");
      canvas.className = "ray-tracing-overlay";
      Object.assign(canvas.style, {
        position: "absolute",
        inset: "0",
        width: "100%",
        height: "100%",
        pointerEvents: "none",
        zIndex: "1",
        visibility: "hidden",
      });
      this.host.appendChild(canvas);
      const offscreen = canvas.transferControlToOffscreen(),
        worker = (this.worker = new Worker(
          new URL("../workers/ray-tracing.worker.ts", import.meta.url),
          { type: "module" },
        ));
      const canceled = () => {
        if (generation === this.generation) this.cancel();
      };
      abort.signal.addEventListener("abort", canceled, { once: true });
      await new Promise<void>((resolve) => {
        this.resolvePrepare = resolve;
        worker.onmessage = ({ data }) => {
          if (generation !== this.generation) return;
          if (data.type === "state") {
            if (
              (data.status === "rendering" || data.status === "ready") &&
              data.samples > 0 &&
              !this.moving
            )
              canvas.style.visibility = "visible";
            if (data.status === "unsupported" || data.status === "error") {
              canvas.style.visibility = "hidden";
              this.prepared = false;
              worker.terminate();
              if (this.worker === worker) this.worker = undefined;
              this.rejectSnapshots(
                data.reason || "Ray tracing is unavailable.",
              );
              this.resolvePrepare?.();
              this.resolvePrepare = undefined;
            }
            this.onState(data);
          } else if (data.type === "prepared") {
            this.prepared = true;
            this.resolvePrepare?.();
            this.resolvePrepare = undefined;
            this.resumeAfterIdle();
          } else if (data.type === "snapshot-error") {
            const pending = this.snapshots.get(data.id);
            if (pending) {
              this.snapshots.delete(data.id);
              pending.reject(new Error(data.reason));
            }
          } else if (data.type === "snapshot") {
            const pending = this.snapshots.get(data.id);
            if (pending) {
              this.snapshots.delete(data.id);
              pending.resolve(data.blob);
            }
          } else if (data.type === "failed") {
            this.resolvePrepare?.();
            this.resolvePrepare = undefined;
          }
        };
        worker.onerror = (event) => {
          this.state("error", {
            reason:
              event.message ||
              "Ray-tracing worker failed; raster remains available.",
          });
          canvas.style.visibility = "hidden";
          this.prepared = false;
          worker.terminate();
          if (this.worker === worker) this.worker = undefined;
          this.rejectSnapshots(event.message || "Ray-tracing worker failed.");
          this.resolvePrepare?.();
          this.resolvePrepare = undefined;
        };
        worker.postMessage(
          {
            type: "init",
            scene,
            canvas: offscreen,
            settings: this.settings,
            ...size,
            paused: true,
          },
          [offscreen, ...traceTransfers(scene)],
        );
        transferred = true;
      });
    } catch (error) {
      if (!abort.signal.aborted && generation === this.generation) {
        this.cancel();
        this.state("unsupported", {
          reason: error instanceof Error ? error.message : String(error),
        });
      }
    } finally {
      if (!transferred)
        for (const texture of ownedScene?.textures ?? [])
          texture.bitmap?.close();
    }
  }
  setCamera(camera: T.Camera) {
    if (this.disposed) return;
    if (this.canvas) this.canvas.style.visibility = "hidden";
    this.worker?.postMessage({ type: "pause" });
    this.worker?.postMessage({ type: "camera", camera: traceCamera(camera) });
    this.resumeAfterIdle();
  }
  setMoving(moving: boolean) {
    this.moving = moving;
    window.clearTimeout(this.idleTimer);
    if (moving) {
      if (this.canvas) this.canvas.style.visibility = "hidden";
      this.worker?.postMessage({ type: "pause" });
    } else this.resumeAfterIdle();
  }
  private resumeAfterIdle() {
    window.clearTimeout(this.idleTimer);
    if (!this.prepared || this.moving) return;
    this.idleTimer = window.setTimeout(() => {
      if (!this.moving && this.prepared)
        this.worker?.postMessage({ type: "resume" });
    }, 180);
  }
  resize() {
    this.worker?.postMessage({ type: "pause" });
    if (this.canvas) this.canvas.style.visibility = "hidden";
    this.worker?.postMessage({
      type: "settings",
      settings: this.settings,
      ...this.size(),
    });
    this.resumeAfterIdle();
  }
  setSettings(settings: RayTracingSettings) {
    this.settings = settings;
    this.resize();
  }
  snapshot(): Promise<Blob> {
    if (!this.worker || !this.prepared || !this.imageVisible)
      return Promise.reject(
        new Error("Ray tracing has not produced an image."),
      );
    const id = ++this.serial;
    return new Promise((resolve, reject) => {
      this.snapshots.set(id, { resolve, reject });
      this.worker!.postMessage({ type: "snapshot", id });
    });
  }
  private rejectSnapshots(reason: string) {
    for (const pending of this.snapshots.values())
      pending.reject(new Error(reason));
    this.snapshots.clear();
  }
  cancel() {
    this.generation++;
    this.removeExternalAbort?.();
    this.removeExternalAbort = undefined;
    window.clearTimeout(this.idleTimer);
    const abort = this.abort;
    this.abort = undefined;
    if (abort && !abort.signal.aborted) abort.abort();
    this.worker?.terminate();
    this.worker = undefined;
    this.canvas?.remove();
    this.canvas = undefined;
    this.prepared = false;
    this.resolvePrepare?.();
    this.resolvePrepare = undefined;
    this.rejectSnapshots("Ray tracing canceled");
  }
  dispose() {
    this.disposed = true;
    this.cancel();
  }
}
