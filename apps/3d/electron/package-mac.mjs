import fs from "node:fs/promises";
import path from "node:path";
import { spawn, execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { createRequire } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const require = createRequire(import.meta.url);
const {
  PRIVATE_RELEASE_OWNER,
  assertReleaseOwner,
  assertReleaseAccess,
  assertNoGitHubToken,
  releaseAccessFor,
  validatePackagedFeed,
} = require("./release-channel.cjs");
const hash = (bytes, algorithm = "sha256", encoding = "hex") =>
  createHash(algorithm).update(bytes).digest(encoding);
/** A Developer ID signature changes Mach-O bytes without changing native code. */
export function nativeCodeHash(bytes) {
  const data = Buffer.from(bytes);
  if (data.length < 32 || data.readUInt32LE(0) !== 0xfeedfacf)
    throw Error("Expected thin 64-bit Mach-O native helper");
  const count = data.readUInt32LE(16),
    commandBytes = data.readUInt32LE(20);
  if (count > 128 || commandBytes > data.length - 32)
    throw Error("Invalid native load commands");
  let offset = 32,
    signature,
    signatureSize = 0;
  const commands = [];
  for (let i = 0; i < count; i++) {
    const command = data.readUInt32LE(offset),
      size = data.readUInt32LE(offset + 4);
    if (size < 8 || offset + size > 32 + commandBytes)
      throw Error("Invalid native load command");
    if (command === 0x1d) {
      signature = data.readUInt32LE(offset + 8);
      signatureSize += size;
    } else {
      const normalized = Buffer.from(data.subarray(offset, offset + size));
      if (
        command === 0x19 &&
        normalized.subarray(8, 24).toString().replace(/\0/g, "") ===
          "__LINKEDIT"
      ) {
        normalized.writeBigUInt64LE(0n, 32);
        normalized.writeBigUInt64LE(0n, 48);
      }
      commands.push(normalized);
    }
    offset += size;
  }
  if (
    !signature ||
    signature < offset ||
    signature > data.length ||
    signatureSize !== 16
  )
    throw Error("Expected one linked native code signature");
  const normalized = Buffer.from(data.subarray(0, signature));
  normalized.writeUInt32LE(count - 1, 16);
  normalized.writeUInt32LE(commandBytes - signatureSize, 20);
  normalized.fill(0, 32, 32 + commandBytes);
  Buffer.concat(commands).copy(normalized, 32);
  return hash(normalized);
}
const run = (command, args) =>
  new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd: root, stdio: "inherit" });
    child.on("error", reject);
    child.on("exit", (code, signal) =>
      code === 0
        ? resolve()
        : reject(new Error(`${command} exited with ${signal || code}`)),
    );
  });
async function exists(file) {
  try {
    await fs.access(file);
    return true;
  } catch {
    return false;
  }
}
async function fingerprint(directory, relative = "", result = {}) {
  for (const entry of (
    await fs.readdir(directory, { withFileTypes: true })
  ).sort((a, b) => a.name.localeCompare(b.name))) {
    const name = path.posix.join(relative, entry.name);
    if (entry.isDirectory())
      await fingerprint(path.join(directory, entry.name), name, result);
    else
      result[name] = hash(await fs.readFile(path.join(directory, entry.name)));
  }
  return result;
}
/** The staged frontend's license notices name the source repository as <owner>/shenzhen-3D, where each release's
 * source tag goes: a build for another owner names that owner's repository, as verifyOwnerIsolation requires. */
const NOTICES = ["dist/THIRD_PARTY.txt", "dist/licenses/THIRD_PARTY.txt"];
export async function pointNoticesAtOwner(staging, releaseOwner) {
  if (releaseOwner === undefined || releaseOwner === null) return;
  assertReleaseOwner(releaseOwner);
  for (const notice of NOTICES) {
    const file = path.join(staging, notice);
    if (!(await exists(file))) continue;
    const text = await fs.readFile(file, "utf8");
    const owned = text.replace(
      /(github\.com\/)[A-Za-z0-9-]+(\/shenzhen-3D)(?![A-Za-z0-9-])/gi,
      `$1${releaseOwner}$2`,
    );
    if (owned !== text) await fs.writeFile(file, owned);
  }
}
/** Stage a self-contained, lock-verified production dependency graph. */
export async function stageRuntime(
  staging,
  pkg,
  {
    releaseOwner,
    forbiddenOwners = [],
    nativeScroll,
    friendsNative,
    privateReleaseOwner = PRIVATE_RELEASE_OWNER,
  } = {},
) {
  const releaseAccess = releaseAccessFor(releaseOwner, privateReleaseOwner);
  for (const owner of forbiddenOwners) {
    assertReleaseOwner(owner);
    if (owner === releaseOwner)
      throw Error("Excluded owner cannot be the selected release owner");
  }
  await pointNoticesAtOwner(staging, releaseOwner);
  const lockBytes = await fs.readFile(path.join(root, "package-lock.json"));
  const lock = JSON.parse(lockBytes);
  const updaterVersion = pkg.dependencies?.["electron-updater"];
  if (!/^\d+\.\d+\.\d+$/.test(updaterVersion || ""))
    throw Error(
      "electron-updater must be an exactly pinned runtime dependency.",
    );
  if (
    lock.packages?.[""]?.dependencies?.["electron-updater"] !== updaterVersion
  )
    throw Error(
      "Pinned updater dependency differs from root package-lock.json.",
    );
  const dependencies = { "electron-updater": updaterVersion },
    inventory = new Map();
  const modules = path.join(root, "node_modules");
  async function dependency(name, from, optional = false) {
    // Resolve package directories like Node without executing package entry points.
    const directories =
      createRequire(path.join(from, "package.json")).resolve.paths(name) || [];
    let directory;
    for (const search of directories)
      if (await exists(path.join(search, name, "package.json"))) {
        directory = await fs.realpath(path.join(search, name));
        break;
      }
    if (!directory) {
      if (optional) return;
      throw Error(`Installed runtime dependency is missing: ${name}`);
    }
    if (!directory.startsWith(modules + path.sep))
      throw Error(
        `Runtime dependency is outside installed node_modules: ${name}`,
      );
    const key = path.relative(root, directory).split(path.sep).join("/");
    if (inventory.has(key)) return;
    const bytes = await fs.readFile(path.join(directory, "package.json")),
      metadata = JSON.parse(bytes),
      locked = lock.packages[key];
    if (!locked || locked.version !== metadata.version)
      throw Error(
        `Installed runtime dependency differs from package-lock.json: ${name}`,
      );
    if (name === "electron-updater" && metadata.version !== updaterVersion)
      throw Error(
        "Installed electron-updater differs from the pinned runtime version.",
      );
    inventory.set(key, {
      name: metadata.name,
      version: metadata.version,
      installedPath: key,
      integrity: locked.integrity,
      packageJsonSha256: hash(bytes),
    });
    for (const child of Object.keys(metadata.dependencies || {}).sort())
      await dependency(child, directory);
    for (const child of Object.keys(metadata.optionalDependencies || {}).sort())
      await dependency(child, directory, true);
  }
  await dependency("electron-updater", root);
  await fs.mkdir(staging, { recursive: true });
  await fs.writeFile(
    path.join(staging, ".release-verification.json"),
    JSON.stringify({ forbiddenOwners }) + "\n",
    { mode: 0o600 },
  );
  const production = {};
  async function copy(directory, relative = "") {
    for (const entry of (
      await fs.readdir(directory, { withFileTypes: true })
    ).sort((a, b) => a.name.localeCompare(b.name))) {
      const name = path.posix.join(relative, entry.name);
      if (entry.isDirectory()) {
        if (!["test", "tests", "__tests__"].includes(entry.name))
          await copy(path.join(directory, entry.name), name);
      } else if (
        entry.name.endsWith(".cjs") &&
        !/\.(?:test|spec)\.cjs$/.test(entry.name)
      ) {
        const source = path.join(directory, entry.name),
          target = path.join(staging, "electron", name);
        await fs.mkdir(path.dirname(target), { recursive: true });
        await fs.copyFile(source, target);
        production[path.posix.join("electron", name)] = hash(
          await fs.readFile(target),
        );
      }
    }
  }
  await copy(path.join(root, "electron"));
  const nativeRuntimeFiles = {};
  if (nativeScroll) {
    const target = path.join(staging, "electron/native/scroll-source.node");
    await fs.mkdir(path.dirname(target), { recursive: true });
    await fs.copyFile(nativeScroll, target);
    nativeRuntimeFiles["electron/native/scroll-source.node"] = nativeCodeHash(
      await fs.readFile(target),
    );
  }
  if (friendsNative) {
    // Shenzhen Friends' client addon, built from the pinned client library (docs/FRIENDS.md).
    const target = path.join(staging, "electron/native/friends-link.node");
    await fs.mkdir(path.dirname(target), { recursive: true });
    await fs.copyFile(friendsNative, target);
    nativeRuntimeFiles["electron/native/friends-link.node"] = nativeCodeHash(
      await fs.readFile(target),
    );
  }
  const manifest = {
    name: pkg.name,
    version: pkg.version,
    description: pkg.description,
    author: "INTUITION Robotique & Technologies",
    private: true,
    main: "electron/main.cjs",
    releaseOwner,
    releaseAccess,
    dependencies,
  };
  await fs.writeFile(
    path.join(staging, "package.json"),
    JSON.stringify(manifest, null, 2) + "\n",
  );
  // A matching thin lock prevents ancestor lock/workspace detection from selecting the full frontend graph.
  const packages = {
    "": { name: pkg.name, version: pkg.version, dependencies },
  };
  for (const key of [...inventory.keys()].sort())
    packages[key] = lock.packages[key];
  await fs.writeFile(
    path.join(staging, "package-lock.json"),
    JSON.stringify(
      {
        name: pkg.name,
        version: pkg.version,
        lockfileVersion: lock.lockfileVersion,
        requires: true,
        packages,
      },
      null,
      2,
    ) + "\n",
  );
  // A symlink to the root installation is insufficient: builder's npm traversal
  // can discover the graph but lose transitive package paths during ASAR copying.
  // Copy only the verified closure, keeping Node's installed nesting intact.
  const stagedModules = path.join(staging, "node_modules");
  if (await exists(stagedModules))
    throw Error("Runtime staging must start without an existing node_modules.");
  for (const key of [...inventory.keys()].sort()) {
    const source = path.join(root, key),
      target = path.join(staging, key);
    await fs.mkdir(path.dirname(target), { recursive: true });
    await fs.cp(source, target, {
      recursive: true,
      dereference: true,
      // Nested packages are copied separately only if they belong to the closure.
      filter: (file) =>
        file === source ||
        !path.relative(source, file).split(path.sep).includes("node_modules"),
    });
  }
  return {
    releaseOwner,
    releaseAccess,
    packageLockSha256: hash(lockBytes),
    runtimeFiles: production,
    nativeRuntimeFiles,
    runtimeDependencies: [...inventory.values()].sort((a, b) =>
      a.installedPath.localeCompare(b.installedPath),
    ),
  };
}
export function verifyOwnerIsolation(
  archive,
  releaseOwner,
  { forbiddenOwners = [] } = {},
) {
  assertReleaseOwner(releaseOwner);
  for (const owner of forbiddenOwners) {
    assertReleaseOwner(owner);
    if (owner === releaseOwner)
      throw Error("Excluded owner cannot be the selected release owner");
  }
  const asar = require("@electron/asar");
  let scannedFiles = 0;
  for (const filename of asar.listPackage(archive)) {
    if (asar.statFile(archive, filename.slice(1)).files) continue;
    const text = asar
      .extractFile(archive, filename.slice(1))
      .toString("utf8")
      .toLowerCase();
    scannedFiles++;
    if (forbiddenOwners.some((owner) => text.includes(owner.toLowerCase())))
      throw Error(`Foreign release owner found in packaged file: ${filename}`);
    for (const match of text.matchAll(
      /(?:github\.com|api\.github\.com\/repos)\/([a-z0-9-]+)\/shenzhen-3d/g,
    ))
      if (match[1] !== releaseOwner.toLowerCase())
        throw Error(
          `Foreign release repository URL found in packaged file: ${filename}`,
        );
  }
  return {
    ownerIsolationVerified: true,
    ownerIsolationScannedFiles: scannedFiles,
  };
}
export function verifyRuntimeArchive(
  archive,
  provenance,
  isolationPolicy = {},
) {
  const asar = require("@electron/asar"),
    semver = require("semver");
  const archiveFiles = asar.listPackage(archive);
  if (archiveFiles.includes("/.release-verification.json"))
    throw Error("Local release verification policy must not be packaged");
  // No build ships a GitHub credential: public builds need none and private
  // builds use the access each person connects in the app.
  for (const file of archiveFiles)
    if (!asar.statFile(archive, file.slice(1)).files)
      assertNoGitHubToken(
        asar.extractFile(archive, file.slice(1)).toString("latin1"),
        file,
      );
  const isolation =
    provenance.releaseOwner === undefined
      ? {}
      : verifyOwnerIsolation(archive, provenance.releaseOwner, isolationPolicy);
  if (provenance.releaseOwner !== undefined) {
    const metadata = JSON.parse(asar.extractFile(archive, "package.json"));
    if (
      assertReleaseOwner(metadata.releaseOwner) !==
      assertReleaseOwner(provenance.releaseOwner)
    )
      throw Error("Packaged release owner does not match provenance");
    if (
      (metadata.releaseAccess !== undefined ||
        provenance.releaseAccess !== undefined) &&
      assertReleaseAccess(metadata.releaseAccess) !==
        assertReleaseAccess(provenance.releaseAccess)
    )
      throw Error("Packaged release access does not match provenance");
  }
  for (const file of Object.keys(provenance.runtimeFiles))
    if (
      !archiveFiles.includes("/" + file) ||
      hash(asar.extractFile(archive, file)) !== provenance.runtimeFiles[file]
    )
      throw Error(`Packaged runtime helper is missing or changed: ${file}`);
  for (const [file, expected] of Object.entries(
    provenance.nativeRuntimeFiles || {},
  )) {
    if (
      !archiveFiles.includes("/" + file) ||
      !asar.statFile(archive, file).unpacked ||
      nativeCodeHash(asar.extractFile(archive, file)) !== expected
    )
      throw Error(
        `Packaged native helper is missing, packed or changed: ${file}`,
      );
  }
  for (const file of archiveFiles.filter((file) => file.endsWith(".node")))
    if (!Object.hasOwn(provenance.nativeRuntimeFiles || {}, file.slice(1)))
      throw Error(`Unexpected native helper is not in provenance: ${file}`);
  if (archiveFiles.some((file) => /\.(?:test|spec)\.cjs$/.test(file)))
    throw Error("Test helpers must not be packaged.");
  const packaged = new Set(),
    metadataByDirectory = new Map();
  for (const file of archiveFiles.filter((file) =>
    /^\/node_modules\/.*\/package\.json$/.test(file),
  )) {
    const metadata = JSON.parse(asar.extractFile(archive, file.slice(1)));
    packaged.add(`${metadata.name}@${metadata.version}`);
    metadataByDirectory.set(path.posix.dirname(file.slice(1)), metadata);
  }
  for (const dep of provenance.runtimeDependencies)
    if (!packaged.has(`${dep.name}@${dep.version}`))
      throw Error(
        `Packaged updater dependency is missing: ${dep.name}@${dep.version}`,
      );
  // Builder may hoist nested dependencies. Validate Node resolution inside the
  // archive rather than assuming installed paths or allowing workspace fallback.
  metadataByDirectory.set(
    "",
    JSON.parse(asar.extractFile(archive, "package.json")),
  );
  for (const [directory, metadata] of metadataByDirectory) {
    for (const [name, range] of Object.entries(metadata.dependencies || {})) {
      let current = directory,
        resolved;
      for (;;) {
        resolved = metadataByDirectory.get(
          path.posix.join(current, "node_modules", name),
        );
        if (resolved || !current) break;
        const parent = path.posix.dirname(current);
        current = parent === "." ? "" : parent;
      }
      if (!resolved || !semver.satisfies(resolved.version, range))
        throw Error(
          `Packaged runtime cannot resolve ${name}@${range} from ${directory || "app"}`,
        );
    }
  }
  return {
    ...isolation,
    nativeRuntimeFilesVerified: true,
    nativeRuntimeFileCount: Object.keys(provenance.nativeRuntimeFiles || {})
      .length,
    packagedDependencyCount: packaged.size,
    packages: [...packaged].sort(),
  };
}
async function verifyPackage(output, pkg, provenance) {
  const config = require("../electron-builder.cjs"),
    yaml = require("js-yaml");
  const resources = path.join(
    output,
    "mac-arm64",
    `${config.productName}.app`,
    "Contents",
    "Resources",
  );
  const runtime = verifyRuntimeArchive(
    path.join(resources, "app.asar"),
    provenance,
    JSON.parse(
      await fs.readFile(
        path.join(output, "staging/.release-verification.json"),
        "utf8",
      ),
    ),
  );
  const feedText = await fs.readFile(
    path.join(resources, "app-update.yml"),
    "utf8",
  );
  assertNoGitHubToken(feedText, "app-update.yml");
  validatePackagedFeed(
    yaml.load(feedText),
    assertReleaseOwner(provenance.releaseOwner),
    assertReleaseAccess(provenance.releaseAccess),
  );
  const updateText = await fs.readFile(
    path.join(output, "latest-mac.yml"),
    "utf8",
  );
  assertNoGitHubToken(updateText, "latest-mac.yml");
  const update = yaml.load(updateText);
  if (update.version !== pkg.version || !update.path?.endsWith(".zip"))
    throw Error("Mac updater metadata must reference the current ZIP version.");
  const expected = ["zip", "dmg"].map(
    (ext) => `Shenzhen-3D-${pkg.version}-Apple-Silicon.${ext}`,
  );
  const artifacts = [];
  for (const name of expected) {
    const data = await fs.readFile(path.join(output, name)),
      entry = update.files?.find((file) => file.url === name);
    if (
      !entry ||
      entry.sha512 !== hash(data, "sha512", "base64") ||
      (entry.size !== undefined && entry.size !== data.length)
    )
      throw Error(
        `Mac updater metadata does not match artifact bytes: ${name}`,
      );
    artifacts.push({
      file: name,
      size: data.length,
      sha256: hash(data),
      sha512: hash(data, "sha512", "base64"),
    });
  }
  const { checkFriendsBundle } = require("./friends/package.cjs");
  await checkFriendsBundle(
    path.join(output, "mac-arm64", `${config.productName}.app`),
    root,
  );
  const zip = artifacts.find((file) => file.file.endsWith(".zip"));
  if (update.path !== zip.file || update.sha512 !== zip.sha512)
    throw Error("Mac updater legacy ZIP fingerprint is inconsistent.");
  return {
    artifacts,
    ownerIsolationVerified: runtime.ownerIsolationVerified,
    ownerIsolationScannedFiles: runtime.ownerIsolationScannedFiles,
    packagedDependencyCount: runtime.packagedDependencyCount,
    nativeRuntimeFilesVerified: runtime.nativeRuntimeFilesVerified,
    nativeRuntimeFileCount: runtime.nativeRuntimeFileCount,
    updateMetadata: {
      file: "latest-mac.yml",
      sha256: hash(await fs.readFile(path.join(output, "latest-mac.yml"))),
    },
  };
}
/**
 * The DMG electron-builder writes is zlib-compressed (UDZO; its schema allows no LZMA). Recompressed as ULMO (LZMA,
 * macOS 10.15 and later; the app needs 13.0) the same volume is about a fifth smaller. The image is signed again with
 * the identity that signed the app, and its entry in latest-mac.yml takes the new bytes. Its blockmap is made again
 * after notarization (notarize-finalize.mjs).
 */
async function recompressDmg(output, pkg, identity) {
  const yaml = require("js-yaml");
  const dmg = path.join(output, `Shenzhen-3D-${pkg.version}-Apple-Silicon.dmg`);
  const lzma = dmg.replace(/\.dmg$/, ".ulmo.dmg");
  await run("hdiutil", ["convert", dmg, "-quiet", "-format", "ULMO", "-o", lzma]);
  await fs.rename(lzma, dmg);
  if (identity && identity !== "-")
    await run("codesign", [
      "--force",
      "--timestamp",
      "--sign",
      /^[^:]+: /.test(identity) ? identity : `Developer ID Application: ${identity}`,
      dmg,
    ]);
  else await run("codesign", ["--force", "--sign", "-", dmg]);
  const bytes = await fs.readFile(dmg);
  const feed = path.join(output, "latest-mac.yml");
  const metadata = yaml.load(await fs.readFile(feed, "utf8"));
  const entry = metadata.files?.find((file) => file.url === path.basename(dmg));
  if (!entry) throw Error("latest-mac.yml lists no DMG");
  entry.sha512 = hash(bytes, "sha512", "base64");
  entry.size = bytes.length;
  delete entry.blockMapSize;
  await fs.writeFile(feed, yaml.dump(metadata, { lineWidth: -1, noRefs: true }));
  await fs.rm(dmg + ".blockmap", { force: true });
}
async function main() {
  const releaseOwner = assertReleaseOwner(
    process.argv.find((arg) => arg.startsWith("--release-owner="))?.slice(16),
  );
  const forbiddenOwners = process.argv
    .filter((arg) => arg.startsWith("--forbid-owner="))
    .map((arg) => assertReleaseOwner(arg.slice(15)));
  // Packaging always consumes a fresh production build, including stage-only verification. A candidate of another
  // version (--version, below) shows that version in the page too.
  const pageVersion = process.argv
    .find((arg) => arg.startsWith("--version="))
    ?.slice(10);
  if (pageVersion) process.env.SHENZHEN_3D_VERSION = pageVersion;
  await run("npm", ["run", "build"]);
  const nativeScroll =
    process.platform === "darwin"
      ? await (
          await import("./build-native-scroll.mjs")
        ).buildNativeScroll({ arch: "arm64" })
      : undefined;
  // Shenzhen Friends: the pinned helper must be built (scripts/friends/setup-friends.sh), and the client addon is
  // built fresh from the same pinned sources for the app's architecture.
  execFileSync(
    path.join(root, "scripts/friends/setup-friends.sh"),
    ["--check"],
    {
      stdio: "inherit",
    },
  );
  const friendsNative = await (
    await import("./friends/build-native.mjs")
  ).buildFriendsNative({
    arch: "arm64",
    output: path.join(root, "artifacts/friends-native/arm64/friends-link.node"),
  });
  const pkg = JSON.parse(
    await fs.readFile(path.join(root, "package.json"), "utf8"),
  );
  // --version=X.Y.Z: a candidate of another version than package.json's (tools/release.sh's dry run of a throwaway
  // version). The app, its feed and its file names carry it; provenance records both.
  const committedVersion = pkg.version;
  const versionOverride = process.argv
    .find((arg) => arg.startsWith("--version="))
    ?.slice(10);
  if (versionOverride !== undefined) {
    if (!/^\d+\.\d+\.\d+$/.test(versionOverride))
      throw Error("--version must read X.Y.Z");
    pkg.version = versionOverride;
  }
  const stamp = new Date().toISOString().replaceAll(/[:.]/g, "-");
  // --output=<dir>: where the artifacts go (a new directory under artifacts/electron/), instead of a timestamped one.
  const requestedOutput = process.argv
    .find((arg) => arg.startsWith("--output="))
    ?.slice(9);
  const output = requestedOutput
      ? path.resolve(requestedOutput)
      : path.join(
          root,
          "artifacts/electron",
          `${pkg.version}-${releaseOwner}-${stamp}`,
        ),
    staging = path.join(output, "staging");
  if (
    requestedOutput &&
    (!output.startsWith(path.join(root, "artifacts/electron") + path.sep) ||
      (await exists(output)))
  )
    throw Error("--output must name a new directory under artifacts/electron");
  await fs.mkdir(staging, { recursive: true });
  await fs.cp(path.join(root, "dist"), path.join(staging, "dist"), {
    recursive: true,
  });
  const runtime = await stageRuntime(staging, pkg, {
    releaseOwner,
    forbiddenOwners,
    nativeScroll,
    friendsNative,
  });
  const friends = await require("./friends/package.cjs").stageFriends(staging, {
    repoRoot: root,
  });
  const provenance = {
    version: pkg.version,
    ...(versionOverride !== undefined && versionOverride !== committedVersion
      ? { packageJsonVersion: committedVersion }
      : {}),
    sourceCommit: execFileSync("git", ["rev-parse", "HEAD"], {
      cwd: root,
      encoding: "utf8",
    }).trim(),
    sourceDirty: Boolean(
      execFileSync("git", ["status", "--porcelain"], {
        cwd: root,
        encoding: "utf8",
      }).trim(),
    ),
    builtAt: new Date().toISOString(),
    frontendFiles: await fingerprint(path.join(staging, "dist")),
    friends,
    ...runtime,
  };
  const buildInfo = JSON.stringify(provenance, null, 2) + "\n";
  await fs.writeFile(path.join(output, "build-info.json"), buildInfo);
  await fs.writeFile(path.join(staging, "build-info.json"), buildInfo);
  if (process.argv.includes("--stage-only")) {
    console.log(`Electron staging verified: ${staging}`);
    return;
  }
  const builder = path.join(
    root,
    "node_modules/electron-builder/out/cli/cli.js",
  );
  await run(process.execPath, [
    builder,
    "--projectDir",
    staging,
    "--config",
    path.join(root, "electron-builder.cjs"),
    "--config.publish.owner",
    releaseOwner,
    // Private feeds make the app send the connected credential; public feeds
    // are read without one.
    "--config.publish.private",
    String(runtime.releaseAccess === "private"),
    "--config.directories.output",
    output,
    "--config.electronVersion",
    pkg.devDependencies.electron,
    // --ad-hoc: a local test build, signed ad hoc (the app and the Friends helper) even where the release identity
    // is in the keychain, to be signed afterwards or tried on this Mac only.
    ...(process.argv.includes("--ad-hoc") ? ["--config.mac.identity=-"] : []),
    "--mac",
    "--arm64",
    "--publish",
    "never",
  ]);
  const config = require("../electron-builder.cjs");
  await recompressDmg(
    output,
    pkg,
    process.argv.includes("--ad-hoc") ? "-" : config.mac.identity,
  );
  const verification = await verifyPackage(output, pkg, provenance);
  await fs.writeFile(
    path.join(output, "build-info.json"),
    JSON.stringify({ ...provenance, ...verification }, null, 2) + "\n",
  );
  console.log(`Electron artifacts: ${output}`);
}
if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href
)
  await main();
