export interface RecentEntry {
  id: string;
  name: string;
  format: string;
  openedAt: number;
  fileCount: number;
  totalBytes: number;
  storage: "native" | "browser";
}
interface RecentBridge {
  list(): Promise<RecentEntry[]>;
  remember(
    files: File[],
    name: string,
    format: string,
  ): Promise<RecentEntry | null>;
  open(
    id: string,
  ): Promise<{ name: string; lastModified: number; bytes: Uint8Array }[]>;
  remove(id: string): Promise<void>;
  touch(id: string): Promise<RecentEntry>;
}
declare global {
  interface Window {
    shenzhenRecentFiles?: RecentBridge;
  }
}
const LIMIT = 256 * 1024 ** 2,
  COUNT = 8;
let remembers: Promise<unknown> = Promise.resolve();
const nativeGroups = new WeakMap<File, { id: string; files: File[] }>();
/** Preserve an OS-delivered grant when materializing its returned bytes as Files. */
export function adoptNativeFiles(files: File[], recentId: string): void {
  if (!files.length || !/^[a-f0-9-]{36}$/.test(recentId))
    throw Error("Invalid native file grant.");
  const group = { id: recentId, files: [...files] };
  for (const file of files) nativeGroups.set(file, group);
}
function database(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open("shenzhen-recent-files", 1);
    request.onupgradeneeded = () => {
      request.result.createObjectStore("entries", { keyPath: "id" });
      request.result.createObjectStore("files", { keyPath: "id" });
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () =>
      reject(Error("Recent file storage is unavailable in this browser."));
    request.onblocked = () =>
      reject(
        Error(
          "Recent file storage is busy. Close other viewer tabs and try again.",
        ),
      );
  });
}
function request<T>(value: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    value.onsuccess = () => resolve(value.result);
    value.onerror = () => reject(value.error);
  });
}
async function transaction<T>(
  mode: IDBTransactionMode,
  work: (tx: IDBTransaction) => Promise<T>,
): Promise<T> {
  const db = await database();
  try {
    const tx = db.transaction(["entries", "files"], mode);
    const done = new Promise<void>((resolve, reject) => {
      tx.oncomplete = () => resolve();
      tx.onabort = tx.onerror = () =>
        reject(tx.error || Error("Recent file storage failed."));
    });
    // Attach immediately so a rejected transaction never becomes unhandled.
    void done.catch(() => {});
    let result: T;
    try {
      result = await work(tx);
    } catch (error) {
      try {
        tx.abort();
      } catch {}
      await done.catch(() => {});
      throw error;
    }
    await done;
    return result;
  } finally {
    db.close();
  }
}
export async function listRecent(): Promise<RecentEntry[]> {
  const native = (await window.shenzhenRecentFiles?.list()) || [];
  const browser = await transaction("readonly", (tx) =>
    request<RecentEntry[]>(tx.objectStore("entries").getAll()),
  ).catch((error) => {
    if (window.shenzhenRecentFiles) return [];
    throw error;
  });
  return [...native, ...browser]
    .sort((a, b) => b.openedAt - a.openedAt)
    .slice(0, COUNT);
}
export function rememberRecent(
  files: File[],
  name: string,
  format: string,
): Promise<RecentEntry> {
  const result = remembers.then(() => remember(files, name, format));
  remembers = result.catch(() => {});
  return result;
}
async function remember(
  files: File[],
  name: string,
  format: string,
): Promise<RecentEntry> {
  if (
    !files.length ||
    files.length > 256 ||
    !name ||
    name.length > 1024 ||
    format.length > 64
  )
    throw Error("Invalid recent files.");
  const group = nativeGroups.get(files[0]);
  if (
    window.shenzhenRecentFiles &&
    group &&
    group.files.length === files.length &&
    files.every(
      (file, index) =>
        group.files[index] === file && nativeGroups.get(file) === group,
    )
  )
    return window.shenzhenRecentFiles.touch(group.id);
  const native = await window.shenzhenRecentFiles?.remember(
    files,
    name,
    format,
  );
  if (native) return native;
  const totalBytes = files.reduce((sum, file) => sum + file.size, 0);
  if (totalBytes > LIMIT)
    throw Error(
      "This file is too large for browser recent storage. Open it from its location again.",
    );
  // Distinct files sharing a basename must remain separate recent entries.
  const identity = JSON.stringify(
    await Promise.all(
      files.map(async (file) => {
        const sample = new Blob([
          file.slice(0, 65536),
          file.slice(Math.max(65536, file.size - 65536)),
        ]);
        const hash = await crypto.subtle.digest(
          "SHA-256",
          await sample.arrayBuffer(),
        );
        return [
          file.name,
          file.size,
          file.lastModified,
          [...new Uint8Array(hash)]
            .map((n) => n.toString(16).padStart(2, "0"))
            .join(""),
        ];
      }),
    ),
  );
  try {
    return await transaction("readwrite", async (tx) => {
      const entries = tx.objectStore("entries"),
        blobs = tx.objectStore("files");
      const old = await request<(RecentEntry & { identity?: string })[]>(
        entries.getAll(),
      );
      const previous = old.find(
        (e) => e.identity === identity && e.format === format,
      );
      const entry: RecentEntry & { identity: string } = {
        identity,
        id: previous?.id || crypto.randomUUID(),
        name,
        format,
        openedAt: Date.now(),
        fileCount: files.length,
        totalBytes,
        storage: "browser",
      };
      const retained = old
        .filter((e) => e.id !== entry.id)
        .sort((a, b) => b.openedAt - a.openedAt);
      let bytes = totalBytes;
      for (let i = 0; i < retained.length; i++) {
        bytes += retained[i].totalBytes;
        if (i >= COUNT - 1 || bytes > LIMIT) {
          entries.delete(retained[i].id);
          blobs.delete(retained[i].id);
        }
      }
      entries.put(entry);
      blobs.put({ id: entry.id, files });
      return entry;
    });
  } catch {
    throw Error(
      "Recent files could not be saved because browser storage is unavailable or full. The model remains open.",
    );
  }
}
export async function openRecent(entry: RecentEntry | string): Promise<File[]> {
  const id = typeof entry === "string" ? entry : entry.id;
  const nativeOpen = async () => {
    const files = (await window.shenzhenRecentFiles!.open(id)).map(
      (file) =>
        new File([file.bytes as Uint8Array<ArrayBuffer>], file.name, {
          lastModified: file.lastModified,
        }),
    );
    adoptNativeFiles(files, id);
    return files;
  };
  if (
    typeof entry !== "string" &&
    entry.storage === "native" &&
    window.shenzhenRecentFiles
  )
    return nativeOpen();
  const browser = await transaction("readonly", (tx) =>
    request<{ files: File[] } | undefined>(tx.objectStore("files").get(id)),
  ).catch((error) => {
    if (window.shenzhenRecentFiles) return undefined;
    throw error;
  });
  if (browser?.files?.length) return browser.files;
  if (window.shenzhenRecentFiles) return nativeOpen();
  throw Error(
    "This recent file is no longer available in browser storage. Open it from its location again.",
  );
}
export async function removeRecent(id: string): Promise<void> {
  await window.shenzhenRecentFiles?.remove(id);
  await transaction("readwrite", async (tx) => {
    tx.objectStore("entries").delete(id);
    tx.objectStore("files").delete(id);
  }).catch((error) => {
    if (!window.shenzhenRecentFiles) throw error;
  });
}
