const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
test(
  "native provenance survives signing but rejects changed, packed or unexpected addons",
  { skip: process.platform !== "darwin" },
  async (t) => {
    const directory = await fs.mkdtemp(
      path.join(os.tmpdir(), "native-scroll-package-"),
    );
    t.after(() => fs.rm(directory, { recursive: true, force: true }));
    const { buildNativeScroll } = await import("./build-native-scroll.mjs");
    const { nativeCodeHash, stageRuntime, verifyRuntimeArchive } =
      await import("./package-mac.mjs");
    const binary = await buildNativeScroll({
      output: path.join(directory, "scroll.node"),
    });
    const original = await fs.readFile(binary),
      canonical = nativeCodeHash(original);
    execFileSync("codesign", ["--force", "--sign", "-", binary], {
      stdio: "pipe",
    });
    assert.equal(nativeCodeHash(await fs.readFile(binary)), canonical);
    const staging = path.join(directory, "stage"),
      archive = path.join(directory, "app.asar");
    const metadata = await stageRuntime(staging, require("../package.json"), {
      releaseOwner: "fixture-owner",
      nativeScroll: binary,
    });
    await fs.rm(path.join(staging, ".release-verification.json"));
    const asar = require("@electron/asar");
    await asar.createPackageWithOptions(staging, archive, {
      // @electron/asar matches the absolute source path, unlike builder's
      // project-relative asarUnpack patterns.
      unpack: "*.node",
    });
    const result = verifyRuntimeArchive(archive, metadata);
    assert.equal(result.nativeRuntimeFilesVerified, true);
    assert.equal(result.nativeRuntimeFileCount, 1);
    assert.throws(
      () =>
        verifyRuntimeArchive(archive, { ...metadata, nativeRuntimeFiles: {} }),
      /Unexpected native/,
    );
    const unpacked = path.join(
      archive + ".unpacked",
      "electron/native/scroll-source.node",
    );
    execFileSync("codesign", ["--force", "--sign", "-", unpacked], {
      stdio: "pipe",
    });
    assert.equal(
      verifyRuntimeArchive(archive, metadata).nativeRuntimeFileCount,
      1,
    );
    const changed = await fs.readFile(unpacked);
    changed[0x3000] ^= 1;
    await fs.writeFile(unpacked, changed);
    assert.throws(
      () => verifyRuntimeArchive(archive, metadata),
      /native helper.*changed/,
    );
    const packed = path.join(directory, "packed.asar");
    await asar.createPackage(staging, packed);
    assert.throws(
      () => verifyRuntimeArchive(packed, metadata),
      /native helper.*packed/,
    );
  },
);
