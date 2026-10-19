export type ViewportShortcutAction =
  | {
      type: "view";
      view: "front" | "back" | "left" | "right" | "top" | "bottom" | "iso";
    }
  | { type: "fit"; selected: boolean }
  | { type: "normal" }
  | { type: "comment" }
  | { type: "section" }
  | { type: "hide"; showAll: boolean };

/** Structural subset of KeyboardEvent, also usable without browser globals. */
export interface ViewportShortcutEvent {
  key: string;
  code: string;
  shiftKey: boolean;
  ctrlKey: boolean;
  metaKey: boolean;
  altKey: boolean;
  defaultPrevented: boolean;
  repeat: boolean;
  isComposing?: boolean;
  target?: unknown;
}

/** Include descendants and text nodes within editable content. */
export function isViewportEditableTarget(target: unknown): boolean {
  let current = target;
  let inheritsEditable = true;
  for (
    let depth = 0;
    depth < 64 && current && typeof current === "object";
    depth++
  ) {
    const element = current as {
      tagName?: string;
      isContentEditable?: boolean;
      getAttribute?: (name: string) => string | null;
      parentElement?: unknown;
    };
    if (
      ["INPUT", "TEXTAREA", "SELECT"].includes(
        element.tagName?.toUpperCase() || "",
      )
    )
      return true;
    const editable = element.getAttribute?.("contenteditable")?.toLowerCase();
    if (editable === "false") inheritsEditable = false;
    if (
      inheritsEditable &&
      (element.isContentEditable ||
        editable === "" ||
        editable === "true" ||
        editable === "plaintext-only")
    )
      return true;
    current = element.parentElement;
  }
  return false;
}

const views = [
  "front",
  "back",
  "left",
  "right",
  "top",
  "bottom",
  "iso",
] as const;

/** The caller owns document/dialog readiness, side effects and preventDefault. */
export function viewportShortcut(
  event: ViewportShortcutEvent,
): ViewportShortcutAction | undefined {
  if (
    event.defaultPrevented ||
    event.repeat ||
    event.isComposing ||
    event.ctrlKey ||
    event.metaKey ||
    event.altKey ||
    isViewportEditableTarget(event.target)
  )
    return;
  if (event.shiftKey && /^Digit[1-7]$/.test(event.code))
    return { type: "view", view: views[Number(event.code.slice(5)) - 1] };
  const key = event.key.toLowerCase();
  if (key === "f") return { type: "fit", selected: event.shiftKey };
  if (key === "y") return { type: "hide", showAll: event.shiftKey };
  if (event.shiftKey) {
    if (key === "x") return { type: "section" };
    return;
  }
  if (key === "n") return { type: "normal" };
  if (key === "c") return { type: "comment" };
}
