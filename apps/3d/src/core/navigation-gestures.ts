import { type CameraDrag, type NavigationStyleId } from "./navigation-style";
/** Legacy saved values are accepted but no longer change the controls. */
export type NavigationMode = "auto" | "mouse" | "trackpad";
export interface WheelSample {
  deltaX: number;
  deltaY: number;
  deltaMode: number;
  ctrlKey: boolean;
  /** Command on Mac. Held, it turns a trackpad swipe into a pan. */
  metaKey?: boolean;
  /**
   * The Control key is physically down. Browsers also report a trackpad pinch
   * as a wheel event with ctrlKey set, so ctrlKey alone cannot tell them apart.
   */
  ctrlHeld?: boolean;
  nativeSource?: "gesture" | "wheel" | null;
  wheelDeltaX?: number;
  wheelDeltaY?: number;
  devicePixelRatio?: number;
  momentum?: boolean;
}
/** "swipe-zoom" is a two-finger trackpad swipe zooming in proportion to its travel. */
export type WheelAction = "pan" | "zoom" | "swipe-zoom";
/** A swipe keeps the action it started with until it and its inertia stop. */
export const SWIPE_HOLD_MS = 120;
/** A swipe moves fewer pixels than a wheel tick, so it zooms faster per pixel. */
const SWIPE_ZOOM_GAIN = 3;
export class WheelGestureClassifier {
  private swipePanUntil = 0;
  classify(
    event: WheelSample,
    mode: NavigationMode,
    time: number,
  ): WheelAction {
    // Pinch arrives as Ctrl+wheel without the Control key being down.
    if (event.ctrlKey && !event.ctrlHeld) {
      this.swipePanUntil = 0;
      return "zoom";
    }
    const action = this.base(event, mode);
    if (action === "zoom") {
      // Mouse wheels, including with Command or Control held, are unchanged.
      this.swipePanUntil = 0;
      return "zoom";
    }
    // Command or Control decides how a swipe starts. Letting go mid-swipe must
    // not turn the remaining inertia into a zoom, so the pan continues until
    // the swipe stops; pressing the key takes effect immediately.
    if (event.metaKey || event.ctrlKey || time < this.swipePanUntil) {
      this.swipePanUntil = time + SWIPE_HOLD_MS;
      return "pan";
    }
    return "swipe-zoom";
  }
  /** "pan" here means a trackpad swipe; "zoom" a mouse wheel or pinch. */
  private base(event: WheelSample, _mode: NavigationMode): "pan" | "zoom" {
    if (event.nativeSource)
      return event.nativeSource === "gesture" ? "pan" : "zoom";
    if (event.deltaMode !== 0) return "zoom";
    if (event.momentum) return "pan";
    // Chromium retains discrete wheel ticks even when pixel deltas are tiny.
    const dpr = event.devicePixelRatio || 1;
    const ticks = [event.wheelDeltaX, event.wheelDeltaY].filter(
      (value): value is number => Number.isFinite(value) && value !== 0,
    );
    if (
      ticks.length &&
      ticks.every((value) => {
        const normalized = Math.abs(value * dpr) / 120;
        return (
          normalized >= 1 &&
          Math.abs(normalized - Math.round(normalized)) < 0.001
        );
      })
    )
      return "zoom";
    // Browsers omit native gesture phases. Precision/XY scrolling is the fallback;
    // identical DOM wheel events cannot identify hardware with certainty.
    if (
      ticks.length ||
      event.deltaX !== 0 ||
      Math.abs(event.deltaY) < 40 ||
      !Number.isInteger(event.deltaY)
    )
      return "pan";
    return "zoom";
  }
}
export interface NavigationModifiers {
  shiftKey: boolean;
  ctrlKey: boolean;
  metaKey: boolean;
  /** PointerEvent.buttons at press time; 2 means the right button is down. */
  buttons?: number;
}
/**
 * What a mouse or trackpad button drag does. Decided once, when the button goes
 * down; pressing or releasing a key mid-drag does not change it.
 *
 * Right-drag (or a two-finger trackpad click-drag) orbits. With Command or Ctrl
 * held at the start it pans instead. On a Mac, Ctrl+left-click is delivered as
 * a right click (button 2, or buttons 2 with a left button), so it lands here
 * too and pans rather than orbiting. Left and middle drags always pan.
 */
export function pointerDrag(
  _style: NavigationStyleId,
  button: number,
  modifiers: NavigationModifiers,
  is2D: boolean,
): CameraDrag {
  const rightClick =
    button === 2 || (button === 0 && (modifiers.buttons ?? 0) === 2);
  const action =
    button === 1 || (button === 0 && !rightClick)
      ? "pan"
      : rightClick
        ? modifiers.ctrlKey || modifiers.metaKey
          ? "pan"
          : "orbit"
        : "none";
  return is2D && action === "orbit" ? "pan" : action;
}
/** OrbitControls swaps rotate/pan on modified presses; undo that swap once. */
export function orbitMouseAction(
  action: CameraDrag,
  modifiers: NavigationModifiers,
): "rotate" | "pan" | "dolly" | null {
  const modified = modifiers.shiftKey || modifiers.ctrlKey || modifiers.metaKey;
  if (action === "orbit") return modified ? "pan" : "rotate";
  if (action === "pan") return modified ? "rotate" : "pan";
  return action === "zoom" ? "dolly" : null;
}
export function wheelZoomSpeed(
  speed: number,
  reverse: boolean,
  ctrlPinch: boolean,
): number {
  return reverse && !ctrlPinch ? -speed : speed;
}
/**
 * Zoom step for one swipe event, in OrbitControls dolly units. Vertical
 * movement only; the sign matches the mouse wheel.
 */
export function swipeZoomStep(
  deltaY: number,
  deltaMode: number,
  pageHeight: number,
  zoomSpeed: number,
): { out: boolean; scale: number } | null {
  if (!Number.isFinite(deltaY) || deltaY === 0) return null;
  const pixels =
    deltaMode === 1
      ? deltaY * 16
      : deltaMode === 2
        ? deltaY * pageHeight
        : deltaY;
  return {
    out: pixels > 0,
    scale: Math.pow(
      0.95,
      zoomSpeed * Math.abs(pixels) * 0.01 * SWIPE_ZOOM_GAIN,
    ),
  };
}
