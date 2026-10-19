import { createHash } from "node:crypto";
import { readdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import type { Plugin } from "vite";

export function offlineWorkerSource(cache: string, assets: readonly string[]) {
  // Browser demand requests retain priority over this complete offline copy.
  // Keep install pending until all assets exist; never activate a partial version.
  return `const CACHE=${JSON.stringify(cache)};
const ASSETS=${JSON.stringify(assets)};
async function precache() {
  const cache = await caches.open(CACHE);
  const controller = new AbortController();
  let next = 0;
  const copy = async () => {
    while (next < ASSETS.length && !controller.signal.aborted) {
      const asset = ASSETS[next++];
      const response = await fetch(new Request(asset, {priority:'low', signal:controller.signal}));
      if (!response.ok) throw new Error('Offline asset unavailable: ' + asset);
      await cache.put(asset, response);
    }
  };
  const jobs = Array.from({length:Math.min(2, ASSETS.length)}, copy);
  try {
    await Promise.all(jobs);
  } catch (error) {
    controller.abort();
    await Promise.allSettled(jobs);
    await caches.delete(CACHE);
    throw error;
  }
}
self.addEventListener('install', event => event.waitUntil(precache()));
self.addEventListener('activate', event => event.waitUntil(
  caches.keys().then(keys => Promise.all(keys.filter(key => key.startsWith('shenzhen-3d-') && key !== CACHE).map(key => caches.delete(key))))
    .then(() => self.clients.claim())
));
self.addEventListener('fetch', event => {
  if (event.request.method !== 'GET' || new URL(event.request.url).origin !== location.origin) return;
  const match = () => caches.open(CACHE).then(cache => cache.match(event.request.mode === 'navigate' ? './index.html' : event.request, {ignoreVary:true}));
  event.respondWith(event.request.mode === 'navigate'
    ? fetch(event.request).catch(match)
    : match().then(hit => hit || fetch(event.request)));
});
`;
}

export function offlineCacheName(
  files: readonly { path: string; content: Uint8Array }[],
) {
  const hash = createHash("sha256");
  // Policy changes also create a distinct cache: a failed new install must not
  // remove the active worker's cache even when frontend assets are unchanged.
  hash.update(
    offlineWorkerSource(
      "VERSION",
      files.map((file) => "./" + file.path).sort(),
    ),
  );
  for (const file of [...files].sort((a, b) =>
    a.path < b.path ? -1 : a.path > b.path ? 1 : 0,
  )) {
    hash.update(JSON.stringify([file.path, file.content.byteLength]));
    hash.update(file.content);
  }
  return "shenzhen-3d-" + hash.digest("hex").slice(0, 12);
}

export function offlinePlugin(): Plugin {
  return {
    name: "shenzhen-offline",
    apply: "build",
    async closeBundle() {
      const root = "dist";
      const list = async (path: string): Promise<string[]> => {
        const entries = await readdir(join(root, path), {
          withFileTypes: true,
        });
        return (
          await Promise.all(
            entries.map((e) =>
              e.isDirectory()
                ? list(join(path, e.name))
                : Promise.resolve([join(path, e.name)]),
            ),
          )
        ).flat();
      };
      const files = (await list(""))
        .filter((f) => f !== "sw.js" && !f.endsWith(".map"))
        .map((file) => file.replaceAll("\\", "/"))
        .sort();
      const inputs = [];
      for (const path of files)
        inputs.push({ path, content: await readFile(join(root, path)) });
      const cache = offlineCacheName(inputs);
      // Bundled same-origin assets are identical across Origin/encoding variants.
      // Module requests carry Origin; precache requests may not (Vary: Origin).
      const source = offlineWorkerSource(
        cache,
        files.map((file) => "./" + file),
      );
      await writeFile(join(root, "sw.js"), source);
    },
  };
}
