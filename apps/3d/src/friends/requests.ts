// What the rest of the app asks of the Friends button: the Cmd/Ctrl+J shortcut, the command palette's Friends
// commands and View ▸ Friends in the Mac app's menu. App.tsx imports this file in its first chunk, so it imports
// nothing of Friends; FriendsButton.tsx (loaded with Friends) carries the requests out.

/** toggle: Cmd/Ctrl+J. open: Open Friends. add_by_id: the profile page, where Add by ID is. visible: Nearby, made
 * visible. */
export type FriendsRequest = "toggle" | "open" | "add_by_id" | "visible";

// A request made before Friends has loaded (Cmd+J in the first second after launch) waits for the button, but not
// for long: Friends may turn out to be off, and a dropdown opening by itself much later would be a surprise.
const WAIT_MS = 5000;
let listener: ((request: FriendsRequest) => void) | null = null;
let waiting: { request: FriendsRequest; at: number } | null = null;

export const friendsRequests = {
  request(request: FriendsRequest) {
    if (listener) listener(request);
    else waiting = { request, at: Date.now() };
  },
  listen(next: (request: FriendsRequest) => void) {
    listener = next;
    const held = waiting;
    waiting = null;
    if (held && Date.now() - held.at < WAIT_MS) next(held.request);
    return () => {
      if (listener === next) listener = null;
    };
  },
};

const mac =
  typeof navigator !== "undefined" &&
  /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent);

/** Cmd+J on a Mac, Ctrl+J on Windows and Linux. */
export function isFriendsShortcut(event: KeyboardEvent) {
  return isPrimaryShortcut(event, "j");
}
/** Cmd+K on a Mac, Ctrl+K on Windows and Linux: the command palette. */
export function isPaletteShortcut(event: KeyboardEvent) {
  return isPrimaryShortcut(event, "k");
}
function isPrimaryShortcut(event: KeyboardEvent, letter: string) {
  const primary = mac
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

/** The shortcut as this platform writes it: "⌘J" or "Ctrl+J". */
export const shortcutLabel = (letter: string) =>
  mac ? `⌘${letter}` : `Ctrl+${letter}`;
export const friendsShortcutLabel = shortcutLabel("J");
