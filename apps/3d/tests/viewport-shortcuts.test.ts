import { describe, expect, it } from "vitest";
import {
  isViewportEditableTarget,
  viewportShortcut,
  type ViewportShortcutEvent,
} from "../src/core/viewport-shortcuts";

const event = (
  changes: Partial<ViewportShortcutEvent> = {},
): ViewportShortcutEvent => ({
  key: "f",
  code: "KeyF",
  shiftKey: false,
  ctrlKey: false,
  metaKey: false,
  altKey: false,
  defaultPrevented: false,
  repeat: false,
  ...changes,
});
const element = (
  tagName: string,
  editable: string | null = null,
  parentElement?: unknown,
) => ({
  tagName,
  parentElement,
  getAttribute: () => editable,
});

describe("viewport keyboard shortcuts", () => {
  it("maps shifted physical digits regardless of the resulting keyboard-layout character", () => {
    const views = ["front", "back", "left", "right", "top", "bottom", "iso"];
    views.forEach((view, i) => {
      expect(
        viewportShortcut(
          event({ key: "!", code: `Digit${i + 1}`, shiftKey: true }),
        ),
      ).toEqual({ type: "view", view });
      expect(
        viewportShortcut(event({ key: String(i + 1), code: `Digit${i + 1}` })),
      ).toBeUndefined();
    });
    for (const code of ["Numpad1", "Digit0", "Digit8", "Digit9"])
      expect(
        viewportShortcut(event({ key: "1", code, shiftKey: true })),
      ).toBeUndefined();
  });
  it("distinguishes fit/selection, normal, comment, section and visibility commands", () => {
    for (const [key, shiftKey, action] of [
      ["f", false, { type: "fit", selected: false }],
      ["F", true, { type: "fit", selected: true }],
      ["n", false, { type: "normal" }],
      ["c", false, { type: "comment" }],
      ["X", true, { type: "section" }],
      ["y", false, { type: "hide", showAll: false }],
      ["Y", true, { type: "hide", showAll: true }],
    ] as const)
      expect(viewportShortcut(event({ key, shiftKey }))).toEqual(action);
    for (const [key, shiftKey] of [
      ["n", true],
      ["c", true],
      ["x", false],
      ["p", false],
      ["s", true],
      ["Escape", false],
    ] as const)
      expect(viewportShortcut(event({ key, shiftKey }))).toBeUndefined();
  });
  it("leaves modifiers, repeated/composing keys and already-handled events alone", () => {
    for (const guard of [
      "ctrlKey",
      "metaKey",
      "altKey",
      "repeat",
      "defaultPrevented",
      "isComposing",
    ] as const)
      for (const shortcut of [
        event(),
        event({ key: "!", code: "Digit1", shiftKey: true }),
      ])
        expect(
          viewportShortcut({ ...shortcut, [guard]: true }),
        ).toBeUndefined();
  });
  it("does not dispatch from fields, inherited editable content or text-node targets", () => {
    const editable = element("DIV", "true");
    for (const target of [
      element("INPUT"),
      element("textarea"),
      element("SELECT"),
      editable,
      element("SPAN", null, editable),
      { parentElement: editable },
      element("DIV", ""),
      element("DIV", "plaintext-only"),
      { isContentEditable: true },
    ]) {
      expect(isViewportEditableTarget(target)).toBe(true);
      expect(viewportShortcut(event({ target }))).toBeUndefined();
    }
    expect(
      isViewportEditableTarget(
        element("SPAN", null, element("DIV", "false", editable)),
      ),
    ).toBe(false);
    expect(viewportShortcut(event({ target: element("CANVAS") }))).toEqual({
      type: "fit",
      selected: false,
    });
    expect(isViewportEditableTarget(null)).toBe(false);
  });
});
