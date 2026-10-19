import { Vector3 } from "three";

export const GLIDE_MS = 240;

/** Ease-out cubic progress for t in [0, 1]. */
export function glideProgress(t: number) {
  const clamped = Math.min(Math.max(t, 0), 1);
  return 1 - (1 - clamped) ** 3;
}

/**
 * Pans by a fixed world offset over a short ease-out. Steps are applied as
 * increments, so orbiting or zooming during the glide still composes with it.
 */
export class CameraGlide {
  private frame = 0;
  private applied = 0;
  private started = 0;
  private offset = new Vector3();
  private step = new Vector3();

  constructor(
    private readonly move: (delta: Vector3) => void,
    private readonly now = () => performance.now(),
    private readonly schedule = (callback: () => void) =>
      requestAnimationFrame(callback),
    private readonly unschedule = (id: number) => cancelAnimationFrame(id),
  ) {}

  get active() {
    return this.frame !== 0;
  }

  start(offset: Vector3, duration = GLIDE_MS) {
    this.cancel();
    if (offset.lengthSq() === 0) return;
    if (duration <= 0) {
      this.move(this.step.copy(offset));
      return;
    }
    this.offset.copy(offset);
    this.applied = 0;
    this.started = this.now();
    const tick = () => {
      const progress = glideProgress((this.now() - this.started) / duration);
      this.frame = progress < 1 ? this.schedule(tick) : 0;
      this.move(
        this.step.copy(this.offset).multiplyScalar(progress - this.applied),
      );
      this.applied = progress;
    };
    this.frame = this.schedule(tick);
  }

  cancel() {
    if (this.frame) this.unschedule(this.frame);
    this.frame = 0;
  }
}
