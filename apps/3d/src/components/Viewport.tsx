import { forwardRef, useEffect, useImperativeHandle, useRef } from "react";
import type { Viewer } from "../core/viewer";
import type { Pick } from "../core/types";
import { shownFailure } from "../core/failures";
export interface ViewportHandle {
  viewer: Viewer | undefined;
}
export const Viewport = forwardRef<
  ViewportHandle,
  {
    ViewerClass?: typeof Viewer;
    onPick: (pick: Pick) => void;
    onMiss?: () => void;
    onHover: (text: string) => void;
    onReady: (viewer: Viewer) => void;
    onError: (message: string) => void;
  }
>(({ ViewerClass, onPick, onMiss, onHover, onReady, onError }, ref) => {
  const host = useRef<HTMLDivElement>(null);
  const viewer = useRef<Viewer | undefined>(undefined);
  const pick = useRef(onPick);
  pick.current = onPick;
  const miss = useRef(onMiss);
  miss.current = onMiss;
  const hover = useRef(onHover);
  hover.current = onHover;
  useImperativeHandle(
    ref,
    () => ({
      get viewer() {
        return viewer.current;
      },
    }),
    [],
  );
  useEffect(() => {
    if (!ViewerClass) return;
    try {
      const v = new ViewerClass(host.current!);
      viewer.current = v;
      v.onPick = (p) => pick.current(p);
      v.onMiss = () => miss.current?.();
      v.onHover = (t) => hover.current(t);
      onReady(v);
      return () => {
        v.dispose();
        viewer.current = undefined;
      };
    } catch (e) {
      onError(
        shownFailure(
          "3D view",
          e,
          "The 3D view couldn’t start on this device.",
        ),
      );
    }
  }, [ViewerClass]);
  return (
    <div
      ref={host}
      className="viewport-canvas"
      aria-label="3D model viewport"
      role="img"
    />
  );
});
