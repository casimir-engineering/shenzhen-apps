// What the person reads when something fails. The app's own errors (a plain Error or one of its subclasses) are
// written for them, such as an importer's "This file has no geometry". Anything else is a message from inside: the
// native side's refusals (Tauri rejects with plain strings like "Command plugin:event|listen not allowed by ACL"),
// the browser's TypeErrors and DOMExceptions. Those are logged with where they happened and replaced by the plain
// sentence the caller gives.

const INTERNAL: readonly (new (...args: never[]) => Error)[] = [
  TypeError,
  RangeError,
  SyntaxError,
  ReferenceError,
  EvalError,
  URIError,
];

/** True when the failure's own message was written for the person using the app. */
export function isForPeople(failure: unknown): failure is Error {
  if (!(failure instanceof Error)) return false;
  if (typeof DOMException !== "undefined" && failure instanceof DOMException)
    return false;
  return !INTERNAL.some((kind) => failure instanceof kind);
}

/** Logs a failure the person has nothing to do about. */
export function logFailure(where: string, failure: unknown) {
  console.error(`[Shenzhen 3D] ${where}:`, failure);
}

/** The failure's message when it was written for people; otherwise it is logged and `plain` is shown instead. */
export function shownFailure(where: string, failure: unknown, plain: string) {
  if (isForPeople(failure) && failure.message.trim()) return failure.message;
  logFailure(where, failure);
  return plain;
}
