export interface NativeRotation {
  degrees: number;
  clientX: number;
  clientY: number;
  epochMs: number;
}
declare global {
  interface Window {
    shenzhenScroll?: {
      source(epochMs: number): "gesture" | "wheel" | null;
      subscribeRotate?(listener: (event: NativeRotation) => void): () => void;
    };
  }
}
export {};
