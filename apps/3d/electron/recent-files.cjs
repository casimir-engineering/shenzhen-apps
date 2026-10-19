const fs = require("node:fs/promises");
const path = require("node:path");
const { randomUUID } = require("node:crypto");
const MAX_FILES = 256,
  MAX_BYTES = 2 * 1024 ** 3,
  MAX_ENTRIES = 8;
function createRecentFileStore(directory) {
  const filename = path.join(directory, "recent-file-grants.json");
  let queue = Promise.resolve();
  const serial = (work) => {
    const result = queue.then(work);
    queue = result.catch(() => {});
    return result;
  };
  async function read() {
    try {
      const stat = await fs.stat(filename);
      if (stat.size > 1024 * 1024) throw Error();
      const data = JSON.parse(await fs.readFile(filename, "utf8"));
      if (!Array.isArray(data) || data.length > MAX_ENTRIES) throw Error();
      return data.filter(
        (e) =>
          /^[a-f0-9-]{36}$/.test(e.id) &&
          Array.isArray(e.paths) &&
          e.paths.length > 0 &&
          e.paths.length <= MAX_FILES &&
          e.paths.every((p) => typeof p === "string" && path.isAbsolute(p)),
      );
    } catch (error) {
      if (error.code === "ENOENT") return [];
      throw Error("Recent file records are unavailable.");
    }
  }
  async function write(entries) {
    await fs.mkdir(directory, { recursive: true });
    const temporary = filename + "." + randomUUID();
    try {
      await fs.writeFile(temporary, JSON.stringify(entries), {
        mode: 0o600,
        flag: "wx",
      });
      await fs.rename(temporary, filename);
    } finally {
      await fs.rm(temporary, { force: true });
    }
  }
  const metadata = ({ paths, ...entry }) => entry;
  return {
    list: () => serial(async () => (await read()).map(metadata)),
    touch: (id) =>
      serial(async () => {
        const old = await read(),
          entry = old.find((e) => e.id === id);
        if (!entry)
          throw Error(
            "This recent file is unavailable. Open it from its location again.",
          );
        entry.openedAt = Date.now();
        await write([entry, ...old.filter((e) => e.id !== id)]);
        return metadata(entry);
      }),
    remember: (paths, name, format) =>
      serial(async () => {
        if (
          !Array.isArray(paths) ||
          !paths.length ||
          paths.length > MAX_FILES ||
          paths.some(
            (p) =>
              typeof p !== "string" || !path.isAbsolute(p) || p.length > 32768,
          ) ||
          typeof name !== "string" ||
          !name.length ||
          name.length > 1024 ||
          typeof format !== "string" ||
          format.length > 64
        )
          throw Error("Invalid selected files.");
        const canonical = [],
          sizes = [];
        for (const file of paths) {
          const resolved = await fs.realpath(file),
            stat = await fs.stat(resolved);
          if (!stat.isFile()) throw Error("Recent file is unavailable.");
          canonical.push(resolved);
          sizes.push(stat.size);
        }
        const totalBytes = sizes.reduce((a, b) => a + b, 0);
        if (totalBytes > MAX_BYTES)
          throw Error("Recent file exceeds the reopening limit.");
        const old = await read(),
          matching = old.find(
            (e) => JSON.stringify(e.paths) === JSON.stringify(canonical),
          );
        const entry = {
          id: matching?.id || randomUUID(),
          name,
          format,
          openedAt: Date.now(),
          fileCount: canonical.length,
          totalBytes,
          storage: "native",
          paths: canonical,
        };
        await write(
          [entry, ...old.filter((e) => e.id !== entry.id)].slice(
            0,
            MAX_ENTRIES,
          ),
        );
        return metadata(entry);
      }),
    open: (id) =>
      serial(async () => {
        if (typeof id !== "string" || !/^[a-f0-9-]{36}$/.test(id))
          throw Error("Invalid recent file grant.");
        const entry = (await read()).find((e) => e.id === id);
        if (!entry)
          throw Error(
            "This recent file is unavailable. Open it from its location again.",
          );
        const files = [];
        let total = 0;
        try {
          for (const file of entry.paths) {
            // O_NOFOLLOW prevents replacing a granted path with a link to another file.
            const handle = await fs.open(
              file,
              require("node:fs").constants.O_RDONLY |
                (require("node:fs").constants.O_NOFOLLOW || 0),
            );
            try {
              const stat = await handle.stat();
              total += stat.size;
              if (!stat.isFile() || total > MAX_BYTES) throw Error();
              files.push({
                name: path.basename(file),
                lastModified: stat.mtimeMs,
                bytes: new Uint8Array(await handle.readFile()),
              });
            } finally {
              await handle.close();
            }
          }
        } catch {
          throw Error(
            "A recent file was moved, removed, or is no longer readable. Open it from its location again.",
          );
        }
        return files;
      }),
    remove: (id) =>
      serial(async () => write((await read()).filter((e) => e.id !== id))),
  };
}
module.exports = { createRecentFileStore };
