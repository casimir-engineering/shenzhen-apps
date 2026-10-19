export type NavigationStyleId =
  "onshape" | "solidworks" | "creo" | "rhino" | "fusion" | "blender";
export type CameraDrag = "orbit" | "pan" | "zoom" | "none";
export interface NavigationStyle {
  id: NavigationStyleId;
  label: string;
  summary: string;
  drag(
    button: "middle" | "right",
    modifiers: { shift: boolean; ctrl: boolean },
  ): CameraDrag;
}
export const NAVIGATION_STYLES: readonly NavigationStyle[] = [
  {
    id: "onshape",
    label: "Onshape",
    summary: "Right-drag orbits; middle-drag or Shift/Ctrl+right-drag pans",
    drag: (button, { shift, ctrl }) =>
      button === "middle" || shift || ctrl ? "pan" : "orbit",
  },
  {
    id: "solidworks",
    label: "SolidWorks",
    summary:
      "Middle-drag orbits; Ctrl+middle-drag pans; Shift+middle-drag zooms",
    drag: (button, { shift, ctrl }) =>
      button === "right" ? "none" : ctrl ? "pan" : shift ? "zoom" : "orbit",
  },
  {
    id: "creo",
    label: "Creo / NX",
    summary:
      "Middle-drag orbits; Shift+middle-drag pans; Ctrl+middle-drag zooms",
    drag: (button, { shift, ctrl }) =>
      button === "right" ? "none" : shift ? "pan" : ctrl ? "zoom" : "orbit",
  },
  {
    id: "rhino",
    label: "Rhino",
    summary:
      "Right-drag orbits; Shift+right-drag pans; Ctrl+right-drag zooms; middle-drag pans",
    drag: (button, { shift, ctrl }) =>
      button === "middle" || shift ? "pan" : ctrl ? "zoom" : "orbit",
  },
  {
    id: "fusion",
    label: "Fusion 360 / Inventor",
    summary: "Middle-drag pans; Shift+middle-drag orbits",
    drag: (button, { shift }) =>
      button === "right" ? "none" : shift ? "orbit" : "pan",
  },
  {
    id: "blender",
    label: "Blender",
    summary:
      "Middle-drag orbits; Shift+middle-drag pans; Ctrl+middle-drag zooms",
    drag: (button, { shift, ctrl }) =>
      button === "right" ? "none" : shift ? "pan" : ctrl ? "zoom" : "orbit",
  },
];
export const DEFAULT_NAVIGATION_STYLE: NavigationStyleId = "onshape";
const styles = new Map<unknown, NavigationStyle>(
  NAVIGATION_STYLES.map((style) => [style.id, style]),
);
export function isNavigationStyle(value: unknown): value is NavigationStyleId {
  return styles.has(value);
}
export function navigationStyle(id: NavigationStyleId): NavigationStyle {
  return styles.get(id) ?? NAVIGATION_STYLES[0];
}
export function navigationGestures(
  style: NavigationStyle,
  reverseWheelZoom: boolean,
): Record<"orbit" | "pan" | "zoom", string[]> {
  const result: Record<"orbit" | "pan" | "zoom", string[]> = {
    orbit: [],
    pan: [],
    zoom: [],
  };
  for (const button of ["right", "middle"] as const) {
    for (const [prefix, modifiers] of [
      ["", { shift: false, ctrl: false }],
      ["Shift+", { shift: true, ctrl: false }],
      ["Ctrl+", { shift: false, ctrl: true }],
    ] as const) {
      const drag = style.drag(button, modifiers);
      if (
        drag === "none" ||
        (prefix && drag === style.drag(button, { shift: false, ctrl: false }))
      )
        continue;
      result[drag].push(
        `${prefix}${prefix ? button : button[0].toUpperCase() + button.slice(1)}-drag`,
      );
    }
  }
  result.orbit.push("Drag on the model");
  result.zoom.unshift(reverseWheelZoom ? "Scroll (reversed)" : "Scroll");
  return result;
}
