// Files dropped on Friends: only regular files go (the helper sends nothing else), so folders and links or special
// files are refused with the helper's own words before any intent (PROTOCOL.md § Static strings). Desktops send
// each file from its path (Electron's, or the one Tauri's system reported); phones stage the bytes of what fits.
import type { FriendsBridge } from "./bridge";
import type { Strings } from "./protocol";

export type OutgoingFile = { path: string; display_name: string };
export type DropResult =
  | { files: OutgoingFile[]; refusal: null }
  | { files: []; refusal: string | null };

/** A `#` item that could not be attached, with the sentence the composer shows in its place. */
export class AttachRefused extends Error {}

/** Whether a drag carries files at all; their kinds are known only once dropped. */
export const dragHasFiles = (transfer: DataTransfer | null) =>
  Boolean(transfer && Array.from(transfer.types ?? []).includes("Files"));

export async function filesFromDrop(
  bridge: FriendsBridge,
  strings: Strings,
  files: ArrayLike<File>,
): Promise<DropResult> {
  const list = Array.from(files);
  if (!list.length) return { files: [], refusal: null };
  const paths = await bridge.pathsForFiles(list);
  if (paths.some((path) => !path)) {
    const limit = bridge.stagedDropLimit;
    // A desktop sends files from where they are, so a drop the system names no file for (a folder, or something
    // dragged out of another app) is refused in the helper's words.
    if (!limit) {
      const folder = await someFolder(
        list.filter((_file, index) => !paths[index]),
      );
      return {
        files: [],
        refusal:
          (folder ? strings.drop_folders_refused : strings.drop_not_a_file) ??
          null,
      };
    }
    // A phone gives no paths: the files' bytes go instead, as a private copy the app keeps for sending, read only
    // when each fits.
    const large = list.find((file) => file.size > limit);
    if (large)
      return { files: [], refusal: tooLargeToStage(large.name, limit) };
    const staged = await stageFiles(bridge, list);
    if (Array.isArray(staged)) return { files: staged, refusal: null };
    return {
      files: [],
      refusal:
        (staged === "folder"
          ? strings.drop_folders_refused
          : strings.drop_not_a_file) ?? null,
    };
  }
  const kinds = await bridge.classify(paths as string[]);
  if (kinds.includes("folder"))
    return { files: [], refusal: strings.drop_folders_refused ?? null };
  if (kinds.some((kind) => kind !== "file"))
    return { files: [], refusal: strings.drop_not_a_file ?? null };
  return {
    files: list.map((file, index) => ({
      path: paths[index]!,
      display_name: file.name,
    })),
    refusal: null,
  };
}

/** "Pasted image 2026-10-28 at 14.02.05.png", as a Mac names a screenshot; numbered after the first. */
export function pastedImageName(date: Date, number = 1): string {
  const two = (value: number) => String(value).padStart(2, "0");
  const day = `${date.getFullYear()}-${two(date.getMonth() + 1)}-${two(date.getDate())}`;
  const time = `${two(date.getHours())}.${two(date.getMinutes())}.${two(date.getSeconds())}`;
  return `Pasted image ${day} at ${time}${number > 1 ? ` ${number}` : ""}.png`;
}

/** Words, unless they are only a link (a browser's Copy Image puts the picture's address beside it) or nothing. */
export function holdsWords(text: string): boolean {
  const trimmed = text.trim();
  if (!trimmed) return false;
  if (/\s/.test(trimmed)) return true;
  try {
    return !["http:", "https:", "file:"].includes(new URL(trimmed).protocol);
  } catch {
    return true;
  }
}

/** A picture as PNG bytes: PNG as it came, anything else drawn once and saved as PNG. */
async function pngBytes(file: File): Promise<Uint8Array> {
  if (file.type === "image/png")
    return new Uint8Array(await file.arrayBuffer());
  const bitmap = await createImageBitmap(file);
  const canvas = document.createElement("canvas");
  canvas.width = bitmap.width;
  canvas.height = bitmap.height;
  canvas.getContext("2d")?.drawImage(bitmap, 0, 0);
  bitmap.close();
  const blob = await new Promise<Blob | null>((done) =>
    canvas.toBlob(done, "image/png"),
  );
  if (!blob) throw new Error("Could not read the picture");
  return new Uint8Array(await blob.arrayBuffer());
}

/**
 * What a paste in the composer attaches, as a drop's result: files copied in Finder, Explorer or a file manager go
 * from where they are (desktops) or as staged copies (phones), refused in the helper's words as a drop is when one is
 * a folder or a link; a picture on the clipboard (a screenshot) is staged as a PNG named for when it was pasted.
 * Null when the paste is text: nothing but words, or a picture that came with words of its own.
 */
export async function filesFromPaste(
  bridge: FriendsBridge,
  strings: Strings,
  files: File[],
  text: string,
): Promise<DropResult | null> {
  // The system's own list first: Finder also puts a picture of each file's icon beside the files it copies.
  const copied =
    !bridge.stagedDropLimit && bridge.clipboardFiles
      ? await bridge.clipboardFiles().catch(() => [])
      : [];
  if (copied.length) return filesFromPaths(bridge, strings, copied);
  if (!files.length) return null;
  const paths = bridge.stagedDropLimit ? [] : await bridge.pathsForFiles(files);
  if (paths.length === files.length && paths.every(Boolean))
    return filesFromDrop(bridge, strings, files);
  if (files.every((file) => file.type.startsWith("image/"))) {
    if (holdsWords(text)) return null;
    const now = new Date();
    const staged: OutgoingFile[] = [];
    try {
      for (const [index, file] of files.entries()) {
        const name = pastedImageName(now, index + 1);
        staged.push({
          path: await bridge.stage(name, await pngBytes(file)),
          display_name: name,
        });
      }
    } catch {
      return { files: [], refusal: strings.drop_not_a_file ?? null };
    }
    return { files: staged, refusal: null };
  }
  // A phone stages what was pasted, as it does a drop; a desktop with no path for them refuses them.
  return filesFromDrop(bridge, strings, files);
}

/** Paths the system named, checked as a drop's files are. */
async function filesFromPaths(
  bridge: FriendsBridge,
  strings: Strings,
  paths: string[],
): Promise<DropResult> {
  const list = paths.slice(0, 100);
  const kinds = await bridge.classify(list);
  if (kinds.includes("folder"))
    return { files: [], refusal: strings.drop_folders_refused ?? null };
  if (kinds.some((kind) => kind !== "file"))
    return { files: [], refusal: strings.drop_not_a_file ?? null };
  return {
    files: list.map((path) => ({
      path,
      display_name: path.split(/[\\/]/).pop() || path,
    })),
    refusal: null,
  };
}

/** Shown on a phone when a dropped file is larger than the app can stage. */
export const tooLargeToStage = (name: string, limit: number) =>
  `${name} is too large to send from this device. Files you drop here can be up to ${Math.floor(limit / 1e6)} MB.`;

/** A dropped folder reaches the page as an empty, typeless entry that cannot be read; reading one byte tells. */
async function someFolder(files: File[]): Promise<boolean> {
  for (const file of files) {
    if (file.size > 0 || file.type) continue;
    try {
      await file.slice(0, 1).arrayBuffer();
    } catch {
      return true;
    }
  }
  return false;
}

/** Each file's bytes as a private copy the app keeps for sending (phones' drops, and `#` items without a path). */
export async function stageFiles(
  bridge: Pick<FriendsBridge, "stage">,
  files: File[],
): Promise<OutgoingFile[] | "folder" | "other"> {
  const staged: OutgoingFile[] = [];
  for (const file of files) {
    let bytes: Uint8Array;
    try {
      bytes = new Uint8Array(await file.arrayBuffer());
    } catch {
      // A dropped folder reaches the page as an empty, typeless entry that cannot be read.
      return file.size === 0 && !file.type ? "folder" : "other";
    }
    try {
      staged.push({
        path: await bridge.stage(file.name, bytes),
        display_name: file.name,
      });
    } catch {
      return "other";
    }
  }
  return staged;
}

/** send_files to one conversation with a fresh client token (one per press, PROTOCOL.md § Intents). */
export async function sendFiles(
  bridge: FriendsBridge,
  conversationId: string,
  files: OutgoingFile[],
) {
  const token = await bridge.token();
  return (
    await bridge.send("send_files", {
      conversation_id: conversationId,
      files,
      client_token: token,
    })
  ).reply;
}

/** Whether this shell has a file picker the composer's Attach files can open. */
export function canChooseFiles(bridge: FriendsBridge): boolean {
  return Boolean(bridge.chooseFiles) || (isTauri() && !bridge.stagedDropLimit);
}
const isTauri = () =>
  typeof window !== "undefined" &&
  Boolean(
    (window as unknown as { __TAURI_INTERNALS__?: unknown })
      .__TAURI_INTERNALS__,
  );

/**
 * Attach files: the system's file picker for any files, several at once, checked as a drop is (folders, links and
 * special files refused in the helper's words). Nothing chosen gives no files and no refusal.
 */
export async function chooseFiles(
  bridge: FriendsBridge,
  strings: Strings,
): Promise<DropResult> {
  if (bridge.chooseFiles) {
    const files = await bridge.chooseFiles();
    return { files: files ?? [], refusal: null };
  }
  if (!canChooseFiles(bridge)) return { files: [], refusal: null };
  const { open } = await import("@tauri-apps/plugin-dialog");
  const chosen = await open({ multiple: true, directory: false });
  const paths = (Array.isArray(chosen) ? chosen : chosen ? [chosen] : [])
    .filter((path): path is string => typeof path === "string")
    .slice(0, 100);
  if (!paths.length) return { files: [], refusal: null };
  const kinds = await bridge.classify(paths);
  if (kinds.includes("folder"))
    return { files: [], refusal: strings.drop_folders_refused ?? null };
  if (kinds.some((kind) => kind !== "file"))
    return { files: [], refusal: strings.drop_not_a_file ?? null };
  return {
    files: paths.map((path) => ({
      path,
      display_name: path.split(/[\\/]/).pop() || path,
    })),
    refusal: null,
  };
}
