// scripts/updates/release-updates.mjs on a release directory of small stand-in installers, with a key made for the
// test: what it collects and names, the signatures latest.json carries, SHA256SUMS.txt, and --verify refusing a
// changed installer, a signature for another version and a key that is not the app's.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { verifyTauriSignature } from "./signature.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const app = path.resolve(here, "../..");
const cli = path.join(app, "node_modules/@tauri-apps/cli/tauri.js");
const tool = path.join(here, "release-updates.mjs");
const run = (...args) =>
  spawnSync(process.execPath, [tool, ...args], {
    encoding: "utf8",
    env: { ...process.env, TAURI_SIGNING_PRIVATE_KEY_PASSWORD: "" },
  });

test("a release directory gets signed installers, latest.json and SHA256SUMS.txt", (t) => {
  const work = mkdtempSync(path.join(os.tmpdir(), "release-updates-"));
  t.after(() => rmSync(work, { recursive: true, force: true }));
  const key = path.join(work, "test.key");
  assert.equal(
    spawnSync(process.execPath, [
      cli,
      "signer",
      "generate",
      "--ci",
      "-w",
      key,
      "-p",
      "",
    ]).status,
    0,
  );
  const publicKey = readFileSync(`${key}.pub`, "utf8").trim();
  const bundles = path.join(work, "bundle");
  const release = path.join(work, "release");
  for (const sub of ["nsis", "msi", "appimage", "deb"])
    mkdirSync(path.join(bundles, sub), { recursive: true });
  mkdirSync(release);
  writeFileSync(
    path.join(bundles, "nsis", "Shenzhen 3D_0.2.9_x64-setup.exe"),
    "MZ setup bytes",
  );
  writeFileSync(
    path.join(bundles, "msi", "Shenzhen 3D_0.2.9_x64_en-US.msi"),
    "msi bytes",
  );
  writeFileSync(
    path.join(bundles, "appimage", "Shenzhen 3D_0.2.9_aarch64.AppImage"),
    "appimage bytes",
  );
  writeFileSync(
    path.join(bundles, "deb", "Shenzhen 3D_0.2.9_arm64.deb"),
    "deb bytes",
  );
  writeFileSync(path.join(release, "README.md"), "notes");

  const made = run(
    "--dir",
    release,
    "--tag",
    "preview-0.2.9",
    "--collect",
    bundles,
    "--key",
    key,
    "--public-key",
    publicKey,
  );
  assert.equal(made.status, 0, made.stderr);
  const manifest = JSON.parse(
    readFileSync(path.join(release, "latest.json"), "utf8"),
  );
  assert.equal(manifest.version, "0.2.9");
  assert.deepEqual(Object.keys(manifest.platforms).sort(), [
    "linux-aarch64-appimage",
    "windows-x86_64-msi",
    "windows-x86_64-nsis",
  ]);
  assert.equal(
    manifest.platforms["windows-x86_64-nsis"].url,
    "https://github.com/casimir-engineering/shenzhen-3D/releases/download/preview-0.2.9/Shenzhen-3D-0.2.9-Windows-x64-Setup.exe",
  );
  const setup = readFileSync(
    path.join(release, "Shenzhen-3D-0.2.9-Windows-x64-Setup.exe"),
  );
  assert.equal(
    verifyTauriSignature(
      setup,
      manifest.platforms["windows-x86_64-nsis"].signature,
      publicKey,
      "0.2.9",
    ),
    undefined,
  );
  // The deb is collected and summed, but is not something the app installs in place.
  const sums = readFileSync(path.join(release, "SHA256SUMS.txt"), "utf8");
  assert.match(sums, /  Shenzhen-3D-0\.2\.9-Linux-arm64\.deb\n/);
  assert.match(sums, /  latest\.json\n/);
  assert.doesNotMatch(sums, /\.sig\n/);

  assert.equal(
    run(
      "--verify",
      "--dir",
      release,
      "--tag",
      "preview-0.2.9",
      "--public-key",
      publicKey,
    ).status,
    0,
  );
  // The app's own key did not sign these: verifying against tauri.conf.json's key fails.
  assert.notEqual(
    run("--verify", "--dir", release, "--tag", "preview-0.2.9").status,
    0,
  );
  // Signed for 0.2.9, never good for another version.
  assert.match(
    verifyTauriSignature(
      setup,
      manifest.platforms["windows-x86_64-nsis"].signature,
      publicKey,
      "0.3.0",
    ),
    /version/,
  );
  // One byte of an installer changed.
  const changed = Buffer.from(setup);
  changed[0] ^= 1;
  writeFileSync(
    path.join(release, "Shenzhen-3D-0.2.9-Windows-x64-Setup.exe"),
    changed,
  );
  const refused = run(
    "--verify",
    "--dir",
    release,
    "--tag",
    "preview-0.2.9",
    "--public-key",
    publicKey,
  );
  assert.notEqual(refused.status, 0);
  assert.match(refused.stderr, /does not match its signature/);
});

test("installers of another version are refused when collected", (t) => {
  const work = mkdtempSync(path.join(os.tmpdir(), "release-updates-"));
  t.after(() => rmSync(work, { recursive: true, force: true }));
  mkdirSync(path.join(work, "bundle", "nsis"), { recursive: true });
  mkdirSync(path.join(work, "release"));
  writeFileSync(
    path.join(work, "bundle", "nsis", "Shenzhen 3D_0.2.8_x64-setup.exe"),
    "old",
  );
  const result = run(
    "--dir",
    path.join(work, "release"),
    "--tag",
    "preview-0.2.9",
    "--collect",
    path.join(work, "bundle"),
  );
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /is not version 0\.2\.9/);
});
