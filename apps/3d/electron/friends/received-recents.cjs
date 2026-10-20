// Models received through Friends go to Shenzhen 3D's recent files, without opening them (PROTOCOL.md § Views,
// `received`). The helper lists the files received on this Mac; each is added once: the transfer ids already handled
// are kept in userData/friends-received.json, and on the very first run only files received from then on are added,
// so older history is not imported in bulk.
const fs = require("node:fs/promises");
const path = require("node:path");
const { randomUUID } = require("node:crypto");

// Enough for years of received files; the oldest ids go first, and the helper lists at most 100 at a time.
const MAX_HANDLED = 4096;

/**
 * `directory` holds the record; `formats` are the extensions 3D opens; `remember(paths, name, format)` adds a recent
 * file (recent-files.cjs's store).
 */
function createReceivedRecents({
  directory,
  formats,
  remember,
  now = Date.now,
}) {
  const file = path.join(directory, "friends-received.json");
  let queue = Promise.resolve();
  const serial = (work) => {
    const result = queue.then(work);
    queue = result.catch(() => {});
    return result;
  };

  async function read() {
    try {
      const data = JSON.parse(await fs.readFile(file, "utf8"));
      if (
        Number.isInteger(data?.since) &&
        Array.isArray(data.handled) &&
        data.handled.every((id) => typeof id === "string")
      )
        return { since: data.since, handled: data.handled };
    } catch {}
    return null;
  }
  async function write(record) {
    await fs.mkdir(directory, { recursive: true });
    const temporary = `${file}.${randomUUID()}`;
    try {
      await fs.writeFile(temporary, JSON.stringify(record), {
        mode: 0o600,
        flag: "wx",
      });
      await fs.rename(temporary, file);
    } finally {
      await fs.rm(temporary, { force: true });
    }
  }

  /** The `received` view's rows (newest first): each new model is added to recent files, oldest first. */
  function received(files) {
    return serial(async () => {
      const record = (await read()) ?? {
        since: Math.floor(now() / 1000),
        handled: [],
      };
      const handled = new Set(record.handled);
      const added = [];
      const rows = Array.isArray(files) ? [...files].reverse() : [];
      for (const row of rows) {
        const id = row?.transfer_id;
        if (typeof id !== "string" || handled.has(id)) continue;
        handled.add(id);
        if (
          !Number.isInteger(row.received_at) ||
          row.received_at < record.since
        )
          continue;
        const name = typeof row.file_name === "string" ? row.file_name : "";
        const format = path.extname(name).slice(1).toLowerCase();
        if (
          !formats.has(format) ||
          typeof row.path !== "string" ||
          !path.isAbsolute(row.path)
        )
          continue;
        try {
          await remember([row.path], name, format);
          added.push(row.path);
        } catch {
          // Moved or deleted since: nothing to add, and not tried again.
        }
      }
      await write({
        since: record.since,
        handled: [...handled].slice(-MAX_HANDLED),
      });
      return added;
    });
  }

  return { received };
}

module.exports = { createReceivedRecents };
