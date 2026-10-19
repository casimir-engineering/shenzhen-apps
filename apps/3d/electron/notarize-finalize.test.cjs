const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const path = require("node:path");
const { spawnSync, execFileSync } = require("node:child_process");
const asar = require("@electron/asar");

test(
  "notarization preflight validates unpacked native code before any Apple operation",
  {
    skip: process.platform !== "darwin",
  },
  async (t) => {
    const root = path.resolve(__dirname, "..");
    const parent = path.join(root, "artifacts/electron");
    await fs.mkdir(parent, { recursive: true });
    const temp = await fs.mkdtemp(path.join(parent, "notary-native-test-"));
    t.after(() => fs.rm(temp, { recursive: true, force: true }));
    const { nativeCodeHash } = await import("./package-mac.mjs");
    const thin = path.join(temp, "native.node");
    const architecture = execFileSync("lipo", ["-archs", "/usr/bin/true"], {
      encoding: "utf8",
    })
      .trim()
      .split(/\s+/)[0];
    execFileSync("lipo", [
      "/usr/bin/true",
      "-thin",
      architecture,
      "-output",
      thin,
    ]);
    const native = await fs.readFile(thin);
    const expected = nativeCodeHash(native);
    for (const variant of ["valid", "missing", "packed", "changed"]) {
      const original = path.join(temp, variant);
      const source = path.join(original, "source");
      const staging = path.join(original, "staging");
      const resources = path.join(
        original,
        "mac-arm64/Shenzhen 3D.app/Contents/Resources",
      );
      const output = path.join(temp, `${variant}-notarized-output`);
      for (const directory of [source, staging, resources, output])
        await fs.mkdir(directory, { recursive: true });
      const pkg = { version: "0.1.8", releaseOwner: "fixture-primary" };
      await fs.writeFile(
        path.join(source, "package.json"),
        JSON.stringify(pkg),
      );
      await fs.writeFile(
        path.join(staging, "package.json"),
        JSON.stringify(pkg),
      );
      if (variant !== "missing") {
        await fs.mkdir(path.join(source, "electron/native"), {
          recursive: true,
        });
        await fs.writeFile(
          path.join(source, "electron/native/scroll-source.node"),
          native,
        );
      }
      await asar.createPackageWithOptions(
        source,
        path.join(resources, "app.asar"),
        variant === "packed" ? {} : { unpack: "*.node" },
      );
      await fs.writeFile(
        path.join(resources, "app-update.yml"),
        "provider: github\nowner: fixture-primary\nrepo: shenzhen-3D\nprivate: true\nchannel: latest\n",
      );
      await fs.writeFile(
        path.join(original, "build-info.json"),
        JSON.stringify({
          ...pkg,
          sourceDirty: false,
          artifacts: [],
          runtimeFiles: {},
          runtimeDependencies: [],
          nativeRuntimeFiles: {
            "electron/native/scroll-source.node":
              variant === "changed" ? "0".repeat(64) : expected,
          },
        }),
      );
      const result = spawnSync(
        process.execPath,
        [
          path.join(root, "electron/notarize-finalize.mjs"),
          `--original=${original}`,
          `--output=${output}`,
          "--profile=unused-test-profile",
          "--phase=preflight-test-only",
        ],
        { cwd: root, encoding: "utf8" },
      );
      assert.equal(result.status, 1);
      if (variant === "valid")
        assert.match(
          result.stderr,
          /Phase must be package, verify-zip or finalize/,
        );
      else
        assert.match(
          result.stderr,
          /Packaged native helper is missing, packed or changed/,
        );
      assert.deepEqual(
        await fs.readdir(output),
        [],
        "Preflight never contacts Apple or writes submission evidence",
      );
    }
  },
);
