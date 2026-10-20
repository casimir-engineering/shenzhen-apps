#!/usr/bin/env node
// What a release needs so that installed Windows, Linux and iPhone/iPad apps update to it (docs/UPDATES.md
// § Windows and Linux, § iOS; docs/RELEASING.md § Shenzhen 3D). Run on the Mac that holds the updater key, in the
// directory of the release's files, after they have their release names:
//
//   node scripts/updates/release-updates.mjs --dir <release dir> --tag preview-<version>
//       [--collect <tauri bundle dir>]... [--owner casimir-engineering] [--key <file>] [--password-file <file>]
//
//   --collect   copies the installers a Tauri build left in <dir>/{nsis,msi,appimage,deb,rpm} into the release
//               directory under their release names (Shenzhen-3D-<version>-Windows-x64-Setup.exe …), refusing a
//               file whose name says another version.
//
// Then, for the Windows Setup and MSI and the Linux AppImage: signs each with the updater key (`tauri signer sign`,
// bound to the version) and checks the signature against the public key in src-tauri/tauri.conf.json, as the app
// will; writes latest.json, whose entries name each file's GitHub download address and carry its signature; writes
// manifest.plist for the registered-devices .ipa, after checking the app inside is com.shenzhen3d.viewer at this
// version; and writes SHA256SUMS.txt for every file in the directory. The .sig files stay beside the installers and
// are not uploaded. Upload everything else.
//
//   node scripts/updates/release-updates.mjs --verify --dir <release dir> --tag preview-<version>
//
// checks a directory made this way without signing anything: every latest.json entry's file exists, its signature
// verifies for this version, and SHA256SUMS.txt matches every file.
//
// The key: ~/FriendsKeys/tauri-updater/shenzhen-3d-updater.key and its password in password.txt beside it (or
// TAURI_SIGNING_PRIVATE_KEY_PASSWORD). Without that key no installed Windows or Linux app accepts an update.
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  copyFileSync,
  existsSync,
  readFileSync,
  readdirSync,
  statSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { verifyTauriSignature } from "./signature.mjs";

const app = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const args = process.argv.slice(2);
const option = (name, fallback) => {
  const index = args.indexOf(`--${name}`);
  return index < 0 ? fallback : args[index + 1];
};
const options = (name) =>
  args.flatMap((arg, i) => (arg === `--${name}` ? [args[i + 1]] : []));
const fail = (message) => {
  console.error(`release-updates: ${message}`);
  process.exit(1);
};
const dir = option("dir");
const tag = option("tag");
if (!dir || !tag)
  fail(
    "usage: release-updates.mjs [--verify] --dir <release dir> --tag preview-<version>",
  );
const version = tag.replace(/^(preview-|v)/, "");
if (!/^\d+\.\d+\.\d+$/.test(version))
  fail(`${tag} is not preview-<x.y.z> or v<x.y.z>`);
const owner = option("owner", "casimir-engineering");
const download = (name) =>
  `https://github.com/${owner}/shenzhen-3D/releases/download/${tag}/${encodeURIComponent(name)}`;
const config = JSON.parse(
  readFileSync(path.join(app, "src-tauri/tauri.conf.json"), "utf8"),
);
// --public-key: tests only, with a key of their own.
const publicKey = option("public-key", config.plugins?.updater?.pubkey);
if (!publicKey) fail("src-tauri/tauri.conf.json has no plugins.updater.pubkey");
const identifier = config.identifier;

// The files Tauri's updater installs in place, by the key the app looks up in latest.json.
const arches = { x64: "x86_64", arm64: "aarch64" };
function updaterKey(name) {
  let m = name.match(
    new RegExp(
      `^Shenzhen-3D-${version.replaceAll(".", "\\.")}-Windows-(x64|arm64)-Setup\\.exe$`,
    ),
  );
  if (m) return `windows-${arches[m[1]]}-nsis`;
  m = name.match(
    new RegExp(
      `^Shenzhen-3D-${version.replaceAll(".", "\\.")}-Windows-(x64|arm64)\\.msi$`,
    ),
  );
  if (m) return `windows-${arches[m[1]]}-msi`;
  m = name.match(
    new RegExp(
      `^Shenzhen-3D-${version.replaceAll(".", "\\.")}-Linux-(x64|arm64)\\.AppImage$`,
    ),
  );
  if (m) return `linux-${arches[m[1]]}-appimage`;
  return undefined;
}

const sha256 = (file) =>
  createHash("sha256").update(readFileSync(file)).digest("hex");

function collect(bundles) {
  const kinds = [
    ["nsis", /_(x64|arm64)-setup\.exe$/, (a) => `Windows-${a}-Setup.exe`],
    ["msi", /_(x64|arm64)_[A-Za-z-]+\.msi$/, (a) => `Windows-${a}.msi`],
    [
      "appimage",
      /_(aarch64|amd64|x86_64)\.AppImage$/,
      (a) =>
        `Linux-${{ aarch64: "arm64", amd64: "x64", x86_64: "x64" }[a]}.AppImage`,
    ],
    [
      "deb",
      /_(arm64|amd64)\.deb$/,
      (a) => `Linux-${{ arm64: "arm64", amd64: "x64" }[a]}.deb`,
    ],
    [
      "rpm",
      /\.(aarch64|x86_64)\.rpm$/,
      (a) => `Linux-${{ aarch64: "arm64", x86_64: "x64" }[a]}.rpm`,
    ],
  ];
  for (const [sub, pattern, rename] of kinds) {
    const from = path.join(bundles, sub);
    if (!existsSync(from)) continue;
    for (const name of readdirSync(from)) {
      const m = name.match(pattern);
      if (!m) continue;
      if (!name.includes(`_${version}_`) && !name.includes(`-${version}-`))
        fail(`${path.join(from, name)} is not version ${version}`);
      const to = `Shenzhen-3D-${version}-${rename(m[1])}`;
      copyFileSync(path.join(from, name), path.join(dir, to));
      console.log(`collected ${to}`);
    }
  }
}

function ipaInfo(ipa) {
  const listing = spawnSync("unzip", ["-Z1", ipa], { encoding: "utf8" });
  const plist = listing.stdout
    .split("\n")
    .find((line) => /^Payload\/[^/]+\.app\/Info\.plist$/.test(line));
  if (!plist) fail(`${ipa} has no app Info.plist`);
  const raw = spawnSync("unzip", ["-p", ipa, plist], {
    maxBuffer: 1 << 24,
  }).stdout;
  const converted = spawnSync("plutil", ["-convert", "json", "-o", "-", "-"], {
    input: raw,
    encoding: "utf8",
  });
  if (converted.status !== 0) {
    console.warn(
      `release-updates: could not read ${plist} (plutil is macOS only); its identifier is not checked`,
    );
    return undefined;
  }
  return JSON.parse(converted.stdout);
}

function manifestPlist(ipaName) {
  const escape = (text) => text.replace(/&/g, "&amp;").replace(/</g, "&lt;");
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>items</key>
  <array>
    <dict>
      <key>assets</key>
      <array>
        <dict>
          <key>kind</key>
          <string>software-package</string>
          <key>url</key>
          <string>${escape(download(ipaName))}</string>
        </dict>
      </array>
      <key>metadata</key>
      <dict>
        <key>bundle-identifier</key>
        <string>${escape(identifier)}</string>
        <key>bundle-version</key>
        <string>${version}</string>
        <key>kind</key>
        <string>software</string>
        <key>title</key>
        <string>Shenzhen 3D</string>
      </dict>
    </dict>
  </array>
</dict>
</plist>
`;
}

function writeSums() {
  const names = readdirSync(dir)
    .filter(
      (name) =>
        name !== "SHA256SUMS.txt" &&
        !name.endsWith(".sig") &&
        statSync(path.join(dir, name)).isFile(),
    )
    .sort();
  writeFileSync(
    path.join(dir, "SHA256SUMS.txt"),
    names.map((n) => `${sha256(path.join(dir, n))}  ${n}\n`).join(""),
  );
  return names;
}

function verifyDirectory() {
  const manifest = JSON.parse(
    readFileSync(path.join(dir, "latest.json"), "utf8"),
  );
  if (manifest.version !== version)
    fail(`latest.json is for ${manifest.version}, not ${version}`);
  const sums = new Map(
    readFileSync(path.join(dir, "SHA256SUMS.txt"), "utf8")
      .trim()
      .split("\n")
      .map((line) => line.split(/\s+\*?/).reverse()),
  );
  for (const [key, entry] of Object.entries(manifest.platforms)) {
    const name = decodeURIComponent(entry.url.split("/").pop());
    if (entry.url !== download(name))
      fail(`${key}: ${entry.url} is not this release's download address`);
    if (updaterKey(name) !== key) fail(`${key} names ${name}`);
    const problem = verifyTauriSignature(
      readFileSync(path.join(dir, name)),
      entry.signature,
      publicKey,
      version,
    );
    if (problem) fail(`${name}: ${problem}`);
    console.log(`ok ${key}: ${name} is signed by the app's key for ${version}`);
  }
  for (const [name, hash] of sums) {
    if (sha256(path.join(dir, name)) !== hash)
      fail(`${name} does not match SHA256SUMS.txt`);
  }
  for (const name of readdirSync(dir)) {
    if (name !== "SHA256SUMS.txt" && !name.endsWith(".sig") && !sums.has(name))
      fail(`${name} is not in SHA256SUMS.txt`);
  }
  console.log(`ok SHA256SUMS.txt matches all ${sums.size} files`);
}

if (args.includes("--verify")) {
  verifyDirectory();
  process.exit(0);
}

for (const bundles of options("collect")) collect(bundles);

const installers = readdirSync(dir).filter((name) => updaterKey(name));
const keyFile = option(
  "key",
  path.join(os.homedir(), "FriendsKeys/tauri-updater/shenzhen-3d-updater.key"),
);
const passwordFile = option(
  "password-file",
  path.join(path.dirname(keyFile), "password.txt"),
);
const password =
  process.env.TAURI_SIGNING_PRIVATE_KEY_PASSWORD ??
  (existsSync(passwordFile) ? readFileSync(passwordFile, "utf8").trim() : "");
const platforms = {};
for (const name of installers.sort()) {
  const file = path.join(dir, name);
  if (!existsSync(keyFile))
    fail(
      `no updater key at ${keyFile}: installed apps accept only updates signed with it`,
    );
  const signed = spawnSync(
    process.execPath,
    [
      path.join(app, "node_modules/@tauri-apps/cli/tauri.js"),
      "signer",
      "sign",
      "-f",
      keyFile,
      "--app-version",
      version,
      file,
    ],
    {
      encoding: "utf8",
      env: { ...process.env, TAURI_SIGNING_PRIVATE_KEY_PASSWORD: password },
    },
  );
  if (signed.status !== 0)
    fail(`signing ${name} failed: ${signed.stderr || signed.stdout}`);
  const signature = readFileSync(`${file}.sig`, "utf8").trim();
  const problem = verifyTauriSignature(
    readFileSync(file),
    signature,
    publicKey,
    version,
  );
  if (problem)
    fail(
      `${name}: ${problem} (is the key the one whose public half is in tauri.conf.json?)`,
    );
  platforms[updaterKey(name)] = { url: download(name), signature };
  console.log(`signed ${name} for ${updaterKey(name)}`);
}
if (installers.length) {
  const manifest = {
    version,
    notes: `Shenzhen 3D ${version}`,
    pub_date: new Date().toISOString().replace(/\.\d+Z$/, "Z"),
    platforms,
  };
  writeFileSync(
    path.join(dir, "latest.json"),
    `${JSON.stringify(manifest, null, 2)}\n`,
  );
  console.log(`wrote latest.json (${Object.keys(platforms).join(", ")})`);
} else
  console.warn(
    "release-updates: no Windows Setup, MSI or Linux AppImage here; no latest.json written",
  );

const ipa = readdirSync(dir).find(
  (name) => name === `shenzhen-3d-${version}-ios-registered-devices.ipa`,
);
if (ipa) {
  const info = ipaInfo(path.join(dir, ipa));
  if (
    info &&
    (info.CFBundleIdentifier !== identifier ||
      info.CFBundleShortVersionString !== version)
  )
    fail(
      `${ipa} holds ${info.CFBundleIdentifier} ${info.CFBundleShortVersionString}, not ${identifier} ${version}`,
    );
  writeFileSync(path.join(dir, "manifest.plist"), manifestPlist(ipa));
  console.log(`wrote manifest.plist for ${ipa}`);
}
const names = writeSums();
console.log(
  `wrote SHA256SUMS.txt (${names.length} files). Upload: ${names.concat("SHA256SUMS.txt").join(", ")}`,
);
