declare module "three-gpu-pathtracer/webgpu" {
  import type { Camera, Scene } from "three";
  import type { WebGPURenderer } from "three/webgpu";
  export class WebGPUPathTracer {
    constructor(renderer: WebGPURenderer);
    pause: boolean;
    maxSamples: number;
    maxBounces: number;
    maxTransparentBounces: number;
    frameBudget: number;
    dynamicLowRes: boolean;
    minSamples: number;
    fadeDuration: number;
    renderDelay: number;
    synchronizeRenderSize: boolean;
    setScene(scene: Scene, camera: Camera): void;
    setCamera(camera: Camera): void;
    setSize(width: number, height: number): void;
    reset(): void;
    renderSample(): void;
    getSampleCountsAsync(): Promise<{
      min: number;
      max: number;
      avg: number;
      samplesPerSecond: number;
    }>;
    dispose(): void;
  }
}
