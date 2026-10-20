#!/usr/bin/env node
// android-release.mjs — a release-profile Android APK with Shenzhen Friends, for measuring and trying what people
// would install: built like a release (optimised, Friends' crates built for size, the native library stripped of its
// symbols) but signed with this computer's Android debug key, so it installs on an emulator or a test phone and can
// never be mistaken for a published build. The debug flow (platform-build.mjs android --friends --debug) is unchanged.
//
//   node scripts/friends/android-release.mjs [--target aarch64|armv7|i686|x86_64 …] [--version <x.y.z>]
//     [--version-code <n>] [--out <apk>]
//
// --version builds the APK as another version than tauri.conf.json's (its versionCode follows, 0.2.2 → 2002), and
// --version-code sets the versionCode alone (Tauri derives 2000 from 0.2.0): for a test build that installs over a
// published one without being a release of its own.
//
// Needs a JDK for Gradle (JAVA_HOME), the Android SDK (ANDROID_HOME, or ~/Library/Android/sdk) with build-tools and an
// NDK, and ~/.android/debug.keystore (Android Studio and Gradle make it on the first debug build). Prints the APK's
// size and the native library's, checks the library carries no symbol table or debug sections and that the signature
// verifies.
import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../..", import.meta.url));
const argv = process.argv.slice(2);
const option = (name) => {
  const index = argv.indexOf(`--${name}`);
  return index >= 0 ? argv[index + 1] : undefined;
};
const targets = argv.flatMap((arg, i) =>
  argv[i - 1] === "--target" ? [arg] : [],
);
const version = option("version");
if (version !== undefined && !/^\d+\.\d+\.\d+$/.test(version))
  fail("--version takes x.y.z");
const versionCode = option("version-code");
if (versionCode !== undefined && !/^\d+$/.test(versionCode))
  fail("--version-code takes a whole number");
const fail = (message) => {
  console.error(`error: ${message}`);
  process.exit(1);
};

const sdk =
  process.env.ANDROID_HOME ?? path.join(os.homedir(), "Library/Android/sdk");
const latest = (directory) =>
  fs.existsSync(directory)
    ? fs
        .readdirSync(directory)
        .filter((name) => /^\d/.test(name))
        .sort((a, b) => a.localeCompare(b, undefined, { numeric: true }))
        .at(-1)
    : undefined;
const buildTools =
  latest(path.join(sdk, "build-tools")) ?? fail(`no build-tools in ${sdk}`);
const tool = (name) => path.join(sdk, "build-tools", buildTools, name);
const ndk =
  process.env.NDK_HOME ??
  path.join(
    sdk,
    "ndk",
    latest(path.join(sdk, "ndk")) ?? fail(`no NDK in ${sdk}`),
  );
const readelf = path.join(
  ndk,
  "toolchains/llvm/prebuilt",
  fs.readdirSync(path.join(ndk, "toolchains/llvm/prebuilt"))[0],
  "bin/llvm-readelf",
);
const keystore = path.join(os.homedir(), ".android/debug.keystore");
if (!fs.existsSync(keystore))
  fail(`${keystore} is missing: make one debug build first`);

// 1. The release build, the native library's symbols stripped by cargo itself.
const built = spawnSync(
  process.execPath,
  [
    path.join(root, "scripts/platform-build.mjs"),
    "android",
    "--friends",
    "--apk",
    ...targets.flatMap((target) => ["--target", target]),
    ...(version || versionCode
      ? [
          "--config",
          JSON.stringify({
            ...(version ? { version } : {}),
            ...(versionCode
              ? { bundle: { android: { versionCode: Number(versionCode) } } }
              : {}),
          }),
        ]
      : []),
  ],
  {
    cwd: root,
    stdio: "inherit",
    env: { ...process.env, CARGO_PROFILE_RELEASE_STRIP: "symbols" },
  },
);
if (built.status !== 0) fail("the release build failed");

// 2. The APK Gradle left unsigned, aligned and signed with the debug key.
const outputs = path.join(root, "src-tauri/gen/android/app/build/outputs/apk");
const unsigned = fs
  .readdirSync(outputs, { recursive: true })
  .filter((name) => name.endsWith("-release-unsigned.apk"))
  .map((name) => path.join(outputs, name))
  .sort((a, b) => fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs)[0];
if (!unsigned) fail(`no unsigned release APK under ${outputs}`);
const out = path.resolve(
  option("out") ?? unsigned.replace(/-unsigned\.apk$/, "-debugkey.apk"),
);
const work = fs.mkdtempSync(path.join(os.tmpdir(), "szf3d-release-apk-"));
try {
  const aligned = path.join(work, "aligned.apk");
  execFileSync(tool("zipalign"), ["-P", "16", "-f", "4", unsigned, aligned]);
  // The debug key's well-known passwords; this key signs nothing published.
  execFileSync(tool("apksigner"), [
    "sign",
    ...[
      "--ks",
      keystore,
      "--ks-pass",
      "pass:android",
      "--ks-key-alias",
      "androiddebugkey",
    ],
    ...["--key-pass", "pass:android", "--out", out, aligned],
  ]);
  execFileSync(tool("apksigner"), ["verify", out]);

  // 3. What it weighs, and the native libraries carry no symbols.
  const libraries = path.join(work, "lib");
  execFileSync("unzip", ["-q", "-o", out, "lib/*", "-d", work]);
  const report = [
    `${path.relative(process.cwd(), out)}: ${(fs.statSync(out).size / 1e6).toFixed(2)} MB`,
  ];
  for (const abi of fs.readdirSync(libraries)) {
    for (const name of fs.readdirSync(path.join(libraries, abi))) {
      const file = path.join(libraries, abi, name);
      const sections = execFileSync(readelf, ["-S", "-W", file], {
        encoding: "utf8",
      });
      if (/\s\.symtab\s|\s\.debug_/.test(sections))
        fail(`${abi}/${name} still carries symbols`);
      report.push(
        `  ${abi}/${name}: ${(fs.statSync(file).size / 1e6).toFixed(2)} MB, stripped`,
      );
    }
  }
  console.log(report.join("\n"));
  console.log("signed with the debug key; signature verified");
} finally {
  fs.rmSync(work, { recursive: true, force: true });
}
