// Files the panel shows but the sandboxed renderer cannot read: previews and photos from the helper's state
// directory, and the animal set. Every rule here is PROTOCOL.md's (§ Shared objects, Avatar; § Thumbnails):
// a path is judged by the path alone, the file is opened without following a link and without blocking, and only a
// small regular file whose header declares the expected kind and size is returned. Decoding happens in the
// renderer, which checks the decoded size again, so nothing here decodes what a friend sent. Also: the version keys
// of a helper bundle, and the received files a snapshot offers to open.
const fs = require("node:fs");
const fsp = require("node:fs/promises");
const path = require("node:path");

const MAX_IMAGE_BYTES = 256 * 1024;
const MAX_SVG_BYTES = 64 * 1024;

function pngSize(bytes) {
  const signature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  if (
    bytes.length < 24 ||
    signature.some((byte, index) => bytes[index] !== byte)
  )
    return null;
  if (bytes.toString("latin1", 12, 16) !== "IHDR") return null;
  return {
    type: "image/png",
    width: bytes.readUInt32BE(16),
    height: bytes.readUInt32BE(20),
  };
}

function jpegSize(bytes) {
  if (bytes.length < 4 || bytes[0] !== 0xff || bytes[1] !== 0xd8) return null;
  let offset = 2;
  while (offset + 9 < bytes.length) {
    if (bytes[offset] !== 0xff) return null;
    const marker = bytes[offset + 1];
    if (marker === 0xff) {
      offset++;
      continue;
    }
    const length = bytes.readUInt16BE(offset + 2);
    if (length < 2) return null;
    // Start of frame, any kind but the DHT, JPG and DAC markers that share the range.
    if (
      marker >= 0xc0 &&
      marker <= 0xcf &&
      ![0xc4, 0xc8, 0xcc].includes(marker)
    )
      return {
        type: "image/jpeg",
        height: bytes.readUInt16BE(offset + 5),
        width: bytes.readUInt16BE(offset + 7),
      };
    offset += 2 + length;
  }
  return null;
}

/** The directory names a helper path may sit in, raw and canonical (/var is /private/var). */
function stateDirectories(stateDir) {
  const names = new Set([path.resolve(stateDir)]);
  try {
    names.add(fs.realpathSync(stateDir));
  } catch {}
  return [...names];
}

/** Whether `file` names an entry directly inside <state dir>/<folder>/: no subfolder, no . or .., no doubled slash. */
function directlyInside(file, stateDir, folder) {
  if (
    typeof file !== "string" ||
    file.includes("\0") ||
    file.includes("//") ||
    !path.isAbsolute(file)
  )
    return false;
  const name = path.basename(file);
  if (
    !name ||
    name === "." ||
    name === ".." ||
    file !== path.join(path.dirname(file), name)
  )
    return false;
  return stateDirectories(stateDir).some(
    (directory) => path.dirname(file) === path.join(directory, folder),
  );
}

async function readSmallRegularFile(file, max) {
  // O_NOFOLLOW: a planted link is never followed. O_NONBLOCK: a FIFO in its place cannot block the open.
  const handle = await fsp.open(
    file,
    fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK,
  );
  try {
    const stat = await handle.stat();
    if (!stat.isFile() || stat.size > max) return null;
    const bytes = Buffer.alloc(stat.size);
    const { bytesRead } = await handle.read(bytes, 0, stat.size, 0);
    return bytesRead === stat.size ? bytes : null;
  } finally {
    await handle.close();
  }
}

/**
 * A preview (kind "thumbnail") or a friend's photo (kind "picture") from the helper's state directory, as
 * {type, width, height, bytes}, or null when it fails any check. A thumbnail must be a PNG of exactly the size its
 * snapshot declared; a picture a JPEG or PNG of 1 to 1024 pixels a side.
 */
async function readHelperImage(stateDir, kind, file, expected = {}) {
  const folder =
    kind === "thumbnail"
      ? "thumbnails"
      : kind === "picture"
        ? "pictures"
        : null;
  if (!folder || !stateDir || !directlyInside(file, stateDir, folder))
    return null;
  let bytes;
  try {
    bytes = await readSmallRegularFile(file, MAX_IMAGE_BYTES);
  } catch {
    return null;
  }
  if (!bytes) return null;
  const size =
    kind === "thumbnail" ? pngSize(bytes) : (pngSize(bytes) ?? jpegSize(bytes));
  if (!size) return null;
  if (kind === "thumbnail") {
    if (size.width !== expected.width || size.height !== expected.height)
      return null;
    if (
      size.width < 1 ||
      size.height < 1 ||
      size.width > 192 ||
      size.height > 192
    )
      return null;
  } else if (
    size.width < 1 ||
    size.height < 1 ||
    size.width > 1024 ||
    size.height > 1024
  )
    return null;
  return { ...size, bytes: new Uint8Array(bytes) };
}

/** The bundled animal set: manifest entries by index, read once. */
function createAnimalSet(directory) {
  let manifest;
  async function load() {
    manifest ??= fsp
      .readFile(path.join(directory, "manifest.json"), "utf8")
      .then((text) => JSON.parse(text))
      .catch(() => null);
    return manifest;
  }
  return {
    directory,
    /** {svg, color, name} for one animal of the bundled set, or null (an index newer than the set). */
    async animal(set, index) {
      const data = await load();
      if (!data || data.set !== set || !Number.isInteger(index)) return null;
      const entry = data.animals?.find((animal) => animal.index === index);
      if (
        !entry ||
        typeof entry.svg !== "string" ||
        !/^svg\/[A-Za-z0-9._-]+\.svg$/.test(entry.svg)
      )
        return null;
      try {
        const bytes = await readSmallRegularFile(
          path.join(directory, entry.svg),
          MAX_SVG_BYTES,
        );
        return bytes
          ? {
              svg: bytes.toString("utf8"),
              color: String(entry.color ?? ""),
              name: String(entry.name ?? ""),
            }
          : null;
      } catch {
        return null;
      }
    },
    /** The set's number and every animal's index and name, for the profile's picker. */
    async list() {
      const data = await load();
      if (!data) return null;
      return {
        set: data.set,
        animals: (data.animals ?? []).map((animal) => ({
          index: animal.index,
          name: String(animal.name ?? ""),
          color: String(animal.color ?? ""),
        })),
      };
    },
  };
}

/** What a dropped path is, for refusing folders and links while the person still holds the drag. */
async function classifyPath(file) {
  try {
    const stat = await fsp.lstat(file);
    if (stat.isFile()) return "file";
    if (stat.isDirectory()) return "folder";
    return "other";
  } catch {
    return "missing";
  }
}

/** Every path a snapshot offers to open: its `open_file` actions (PROTOCOL.md § Shared objects, Action). */
function openablePaths(value, found = [], depth = 0) {
  if (!value || typeof value !== "object" || depth > 32) return found;
  if (Array.isArray(value)) {
    for (const entry of value) openablePaths(entry, found, depth + 1);
    return found;
  }
  if (value.action === "open_file" && typeof value.path === "string")
    found.push(value.path);
  for (const entry of Object.values(value))
    if (entry && typeof entry === "object")
      openablePaths(entry, found, depth + 1);
  return found;
}

/** CFBundleShortVersionString and CFBundleVersion from a helper bundle's XML Info.plist. */
function readHelperInfo(helperApp) {
  try {
    const plist = fs.readFileSync(
      path.join(helperApp, "Contents/Info.plist"),
      "utf8",
    );
    const value = (key) =>
      new RegExp(`<key>${key}</key>\\s*<string>([^<]*)</string>`).exec(
        plist,
      )?.[1];
    const build = Number(value("CFBundleVersion"));
    return {
      version: value("CFBundleShortVersionString") || "0",
      // Missing or malformed: 0, which never wins a handover.
      buildNumber: Number.isSafeInteger(build) && build > 0 ? build : 0,
    };
  } catch {
    return { version: "0", buildNumber: 0 };
  }
}

module.exports = {
  readHelperInfo,
  openablePaths,
  readHelperImage,
  createAnimalSet,
  classifyPath,
  directlyInside,
  pngSize,
  jpegSize,
};
