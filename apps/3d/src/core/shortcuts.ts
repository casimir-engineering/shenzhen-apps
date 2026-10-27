// Keyboard shortcuts as this platform writes them, and whether to show them at all. Every shortcut the page names (the
// header's Open file, the assembly's Find a part…, the command palette, Help & shortcuts, Friends' tooltip) comes from
// here, so a Mac and an iPad say ⌘O and Windows, Linux and Android say Ctrl+O. Nothing else writes ⌘.
//
// Phones and tablets show no shortcuts until a keyboard is plugged in or paired: the first key pressed outside a text
// field, or with Ctrl, ⌘ or Alt held, is one an on-screen keyboard cannot send, and from then on the hints show
// (useKeyHints). The native menus write their own, from Electron's and Tauri's CmdOrCtrl accelerators.
import { useSyncExternalStore } from "react";

export type KeyPlatform = "mac" | "windows" | "linux" | "ios" | "android";

type NavigatorLike = {
  platform?: string;
  userAgent?: string;
  maxTouchPoints?: number;
};

/** The platform whose keyboard conventions apply, from the browser's own description of where it runs. */
export function detectKeyPlatform(
  nav: NavigatorLike | undefined = typeof navigator !== "undefined"
    ? navigator
    : undefined,
): KeyPlatform {
  const agent = nav?.userAgent ?? "";
  const platform = nav?.platform || agent;
  if (/Android/i.test(agent)) return "android";
  if (/iPhone|iPad|iPod/.test(platform)) return "ios";
  // iPadOS asks for desktop sites as a Mac; only its screen takes touches.
  if (/Mac/.test(platform))
    return (nav?.maxTouchPoints ?? 0) > 1 ? "ios" : "mac";
  if (/Win/.test(platform)) return "windows";
  return "linux";
}

export const keyPlatform = detectKeyPlatform();

const usesCommand = (platform: KeyPlatform) =>
  platform === "mac" || platform === "ios";

/** The key held for shortcuts, as its keycap reads: "⌘" or "Ctrl". */
export const modifierLabel = (platform: KeyPlatform = keyPlatform) =>
  usesCommand(platform) ? "⌘" : "Ctrl";

/** A shortcut as this platform writes it: "⌘O" or "Ctrl+O". */
export const shortcutLabel = (
  key: string,
  platform: KeyPlatform = keyPlatform,
) => (usesCommand(platform) ? `⌘${key}` : `Ctrl+${key}`);

/** The same shortcut for aria-keyshortcuts: "Meta+J" or "Control+J". */
export const ariaShortcut = (
  key: string,
  platform: KeyPlatform = keyPlatform,
) => (usesCommand(platform) ? `Meta+${key}` : `Control+${key}`);

/** ⌘ and the letter on a Mac or iPad, Ctrl and the letter elsewhere, with no other modifier. */
export function isPrimaryShortcut(event: KeyboardEvent, letter: string) {
  const primary = usesCommand(keyPlatform)
    ? event.metaKey && !event.ctrlKey
    : event.ctrlKey && !event.metaKey;
  return (
    primary &&
    !event.altKey &&
    !event.shiftKey &&
    (event.key.toLowerCase() === letter ||
      event.code === `Key${letter.toUpperCase()}`)
  );
}

const touchFirst = keyPlatform === "ios" || keyPlatform === "android";
let keyboardSeen = false;
const listeners = new Set<() => void>();

/** Whether shortcuts are worth naming here: always on a computer, on a phone or tablet once a keyboard is used. */
export const keyHintsShown = () => !touchFirst || keyboardSeen;

const typingTarget = (target: EventTarget | null) =>
  target instanceof HTMLElement &&
  (target.isContentEditable ||
    target instanceof HTMLInputElement ||
    target instanceof HTMLTextAreaElement ||
    target instanceof HTMLSelectElement);

/** A key an on-screen keyboard does not send: one pressed outside a text field, or with a modifier held. */
export function fromHardwareKeyboard(event: KeyboardEvent) {
  if (event.isComposing || event.keyCode === 229) return false;
  if (event.key === "Unidentified" || event.key === "Process") return false;
  return (
    event.ctrlKey ||
    event.metaKey ||
    event.altKey ||
    !typingTarget(event.target)
  );
}

if (touchFirst && typeof window !== "undefined") {
  const seen = (event: KeyboardEvent) => {
    if (!fromHardwareKeyboard(event)) return;
    keyboardSeen = true;
    window.removeEventListener("keydown", seen, true);
    for (const listener of listeners) listener();
  };
  window.addEventListener("keydown", seen, true);
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};

/** keyHintsShown, re-rendering when a phone or tablet first meets a keyboard. */
export const useKeyHints = () =>
  useSyncExternalStore(subscribe, keyHintsShown, keyHintsShown);
