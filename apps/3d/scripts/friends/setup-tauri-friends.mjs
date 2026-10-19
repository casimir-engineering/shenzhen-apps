#!/usr/bin/env node
// setup-tauri-friends.mjs — the pinned Shenzhen Friends pieces for the Tauri builds (docs/FRIENDS.md § Tauri).
//
//   1. source   friends-core-src/ = shenzhen-pdf at friends.lock's core_commit (a shallow fetch of exactly that
//               commit, detached), or SZF_FRIENDS_CORE_ROOT: a checkout detached at that commit, without changes.
//               In the Shenzhen repository (this tree at apps/3d beside apps/pdf) it is apps/pdf as it is, with
//               nothing pinned or fetched (electron/friends/lock.cjs, friendsMode).
//   2. build    Windows and Linux: the Rust helper (szfriends-helper) in release, stamped with the lock's version and
//               build number, copied to src-tauri/friends/bin/szfriends-helper-<target>[.exe], where Tauri's
//               externalBin finds it; the animal set to src-tauri/friends/animals/; the acknowledgements of what the
//               helper carries to src-tauri/friends/Acknowledgements.txt (helper-notices.mjs). A Mac embeds the
//               Objective-C helper that scripts/friends/setup-friends.sh builds from the lock's commit instead: staged
//               with its animal set as src-tauri/friends/mac/Shenzhen Friends.app (signed on its own, ad hoc unless
//               APPLE_SIGNING_IDENTITY names an identity), with the acknowledgements and an Info.plist fragment of
//               its usage descriptions and Bonjour types for the app (src-tauri/friends/mac.conf.json places them).
//   3. print    the cargo --config that points the `friends` feature at the pinned plugin; with --print-config only
//               that line, for scripts/platform-build.mjs. --print-plugin prints the plugin's directory instead, whose
//               tools/host-build.sh makes and checks src-tauri/friends/Cargo.lock (docs/FRIENDS.md § Locked builds).
//
// Usage: node scripts/friends/setup-tauri-friends.mjs [--target <rust target>] [--print-config|--print-plugin] [--check]
//   --check   change nothing; fail unless the checkout and the built helper are in place
//   --phones  Android and iOS builds: they run the core in the app, so only the checkout is needed
import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const root = path.resolve(
  path.dirname(
    new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1"),
  ),
  "../..",
);
const {
  readFriendsLock,
  friendsBuild,
  HELPER_NAME,
  HELPER_ID,
} = require("../../electron/friends/lock.cjs");
const argv = process.argv.slice(2);
const flag = (name) => argv.includes(`--${name}`);
const option = (name) => {
  const index = argv.indexOf(`--${name}`);
  return index >= 0 ? argv[index + 1] : undefined;
};
const fail = (message) => {
  console.error(`error: ${message}`);
  process.exit(1);
};
const quiet = flag("print-config") || flag("print-plugin");
const log = (message) => quiet || console.log(`==> ${message}`);

const lock = readFriendsLock(root);
const tree = lock.mode === "tree";
if (!tree && !lock.coreCommit)
  fail("friends.lock has no core_commit: this pin carries no Tauri plugin");
const git = (cwd, ...args) =>
  execFileSync("git", ["-C", cwd, ...args], { encoding: "utf8" }).trim();

// 1. The checkout.
const checkout = tree
  ? friendsBuild(root).root
  : process.env.SZF_FRIENDS_CORE_ROOT
    ? path.resolve(process.env.SZF_FRIENDS_CORE_ROOT)
    : path.join(root, "friends-core-src");
if (tree) {
  log(`building Friends from apps/pdf (${checkout})`);
} else if (!fs.existsSync(path.join(checkout, ".git"))) {
  if (flag("check") || process.env.SZF_FRIENDS_CORE_ROOT)
    fail(`${checkout} is not a checkout`);
  log(`fetching ${lock.coreCommit.slice(0, 9)} into friends-core-src/`);
  fs.mkdirSync(checkout, { recursive: true });
  git(checkout, "init", "-q");
  git(
    checkout,
    "fetch",
    "-q",
    "--depth",
    "1",
    process.env.SZF_FRIENDS_URL || lock.url,
    lock.coreCommit,
  );
  git(checkout, "checkout", "-q", "--detach", "FETCH_HEAD");
}
const head = tree ? null : git(checkout, "rev-parse", "HEAD");
if (!tree && head !== lock.coreCommit)
  fail(
    `${checkout} is at ${head}, but friends.lock pins core_commit ${lock.coreCommit}`,
  );
// A checkout on a branch looks like a working copy someone uses: its work in progress would end up in the app.
if (
  !tree &&
  spawnSync("git", ["-C", checkout, "symbolic-ref", "-q", "HEAD"]).status === 0
)
  fail(
    `${checkout} has a branch checked out; use a detached checkout of ${lock.coreCommit}`,
  );
if (
  !tree &&
  git(
    checkout,
    "status",
    "--porcelain",
    "--untracked-files=no",
    "--",
    "portable/friends",
  )
) {
  fail(`${checkout} has local changes under portable/friends`);
}
const friends = path.join(checkout, "portable/friends");
const plugin = path.join(friends, "tauri");
if (!fs.existsSync(path.join(plugin, "Cargo.toml")))
  fail(`${plugin} has no tauri-plugin-szfriends`);
const configLine = `patch.szfriends-pinned.tauri-plugin-szfriends.path=${JSON.stringify(plugin.replaceAll("\\", "/"))}`;
if (flag("print-config")) {
  console.log(configLine);
  process.exit(0);
}
if (flag("print-plugin")) {
  console.log(plugin);
  process.exit(0);
}

if (flag("phones")) {
  // The plugin builds the core and the animal set into the app; there is no helper to stage.
  log(`the phones build the plugin from ${checkout}`);
  process.exit(0);
}

// 2. The helper and the animal set, on the systems that run the Rust helper.
const target =
  option("target") ??
  spawnSync("rustc", ["-vV"], { encoding: "utf8" }).stdout.match(
    /^host: (.+)$/m,
  )?.[1] ??
  fail("no Rust toolchain");
const windows = target.includes("windows");
const helperName = windows ? "szfriends-helper.exe" : "szfriends-helper";
const binDirectory = path.join(root, "src-tauri/friends/bin");
const staged = path.join(
  binDirectory,
  windows ? `szfriends-helper-${target}.exe` : `szfriends-helper-${target}`,
);
const animals = path.join(root, "src-tauri/friends/animals");
const notices = path.join(root, "src-tauri/friends/Acknowledgements.txt");
if (target.includes("apple")) {
  stageMacHelper();
} else if (flag("check")) {
  if (!fs.existsSync(staged))
    fail(
      `${staged} is missing: run node scripts/friends/setup-tauri-friends.mjs`,
    );
  if (!fs.existsSync(path.join(animals, "manifest.json")))
    fail(`${animals} is missing`);
  if (!fs.existsSync(notices)) fail(`${notices} is missing`);
} else {
  const [year, month, day] = lock.shortVersion.split(".");
  log(
    `building szfriends-helper ${lock.shortVersion} build ${lock.buildNumber} for ${target}`,
  );
  const coreRs = path.join(friends, "core-rs");
  const targetDirectory = path.join(root, "src-tauri/target/friends-helper");
  // Cargo reads the configuration of every directory above the one it runs in, and friends-core-src/ sits in this
  // repository, whose .cargo/config.toml patches the plugin for src-tauri: run from inside the core workspace, that
  // patch is unused there and --locked refuses the lock file it would change. So cargo runs from the temporary
  // directory, given the workspace's manifest and its own configuration (a static C runtime on Windows).
  // Windows runs cargo through the shell, which takes the arguments as one line: paths with spaces are quoted.
  const argument = (value) =>
    process.platform === "win32" && /\s/.test(value) ? `"${value}"` : value;
  const built = spawnSync(
    "cargo",
    [
      "build",
      "--release",
      "--locked",
      "--manifest-path",
      argument(path.join(coreRs, "Cargo.toml")),
      "--config",
      argument(path.join(coreRs, ".cargo", "config.toml")),
      "-p",
      "szfriends-helper",
      "--bin",
      "szfriends-helper",
      "--target",
      target,
    ],
    {
      cwd: os.tmpdir(),
      stdio: "inherit",
      shell: process.platform === "win32",
      env: {
        ...process.env,
        CARGO_TARGET_DIR: targetDirectory,
        SZFRIENDS_HELPER_VERSION: `${Number(year)}.${Number(month)}.${Number(day)}`,
        SZFRIENDS_HELPER_BUILD: String(lock.buildNumber),
      },
    },
  );
  if (built.status !== 0) fail("the helper did not build");
  fs.mkdirSync(binDirectory, { recursive: true });
  fs.copyFileSync(
    path.join(targetDirectory, target, "release", helperName),
    staged,
  );
  fs.rmSync(animals, { recursive: true, force: true });
  fs.cpSync(path.join(friends, "avatars/animals"), animals, {
    recursive: true,
    filter: (source) => !source.includes(`${path.sep}pdf`),
  });
  const written = spawnSync(
    process.execPath,
    [
      path.join(root, "scripts/friends/helper-notices.mjs"),
      staged,
      friends,
      notices,
    ],
    { stdio: "inherit" },
  );
  if (written.status !== 0)
    fail("the helper's acknowledgements were not written");
  log(
    `staged ${path.relative(root, staged)}, the animal set and the acknowledgements`,
  );
}
const friendsConfig = target.includes("apple")
  ? "src-tauri/friends/mac.conf.json"
  : "src-tauri/friends/tauri.conf.json";
log(
  `build with: npm run tauri build -- --features friends --config ${friendsConfig} ` +
    `-- --config '${configLine}'`,
);
log("or: node scripts/platform-build.mjs desktop --friends");

// A Mac: the Objective-C helper the lock pins, as ShenzhenPDF, Shenzhen Files and the Electron app embed it, in
// Contents/Helpers. macOS holds the app responsible for the helper it starts, so the app's Info.plist carries the
// helper's usage descriptions and Bonjour types (ADR 0015 § 14; electron/friends/package.cjs does the same).
function stageMacHelper() {
  const mac = path.join(root, "src-tauri/friends/mac");
  const staged = path.join(mac, `${HELPER_NAME}.app`);
  const plist = (file) =>
    JSON.parse(
      execFileSync("plutil", ["-convert", "json", "-o", "-", file], {
        encoding: "utf8",
      }),
    );
  // What the helper must be: the one friends.lock pins, or in the Shenzhen repository the one apps/pdf builds now.
  const expected = tree
    ? `helper build ${lock.buildNumber} (MAC_VERSION and MAC_BUILD in apps/pdf/portable/Makefile)`
    : "the helper friends.lock pins";
  const pinned = (info) =>
    info.CFBundleIdentifier === HELPER_ID &&
    Number(info.SZFriendsBuildNumber) === lock.buildNumber;
  if (flag("check")) {
    const info = path.join(staged, "Contents/Info.plist");
    if (!fs.existsSync(info) || !pinned(plist(info)))
      fail(
        `${staged} is not ${expected}: run node scripts/friends/setup-tauri-friends.mjs`,
      );
    return;
  }
  const build = friendsBuild(root);
  if (!fs.existsSync(path.join(build.helperApp, "Contents/Info.plist")))
    fail(
      `no helper at ${build.helperApp}: run scripts/friends/setup-friends.sh first`,
    );
  const helperInfo = plist(path.join(build.helperApp, "Contents/Info.plist"));
  if (!pinned(helperInfo))
    fail(
      `${build.helperApp} is not ${expected} (it is ${helperInfo.CFBundleIdentifier} ` +
        `${helperInfo.SZFriendsBuildNumber}): run scripts/friends/setup-friends.sh`,
    );
  if (
    !fs.existsSync(
      path.join(
        build.helperApp,
        "Contents/Resources/Friends/animals/manifest.json",
      ),
    )
  )
    fail(`${build.helperApp} carries no animal set`);
  fs.rmSync(mac, { recursive: true, force: true });
  fs.mkdirSync(mac, { recursive: true });
  execFileSync("ditto", [build.helperApp, staged]);
  const identity = process.env.APPLE_SIGNING_IDENTITY;
  execFileSync(
    "codesign",
    !identity || identity === "-"
      ? ["--force", "--sign", "-", staged]
      : [
          "--force",
          "--options",
          "runtime",
          "--timestamp",
          "--sign",
          identity,
          staged,
        ],
    { stdio: "pipe" },
  );
  fs.copyFileSync(
    build.acknowledgements,
    path.join(mac, "Acknowledgements.txt"),
  );
  const keys = {};
  for (const key of [
    "NSLocalNetworkUsageDescription",
    "NSBluetoothAlwaysUsageDescription",
    "NSBonjourServices",
  ])
    if (helperInfo[key] !== undefined) keys[key] = helperInfo[key];
  const fragment = path.join(mac, "Info.plist");
  fs.writeFileSync(fragment, JSON.stringify(keys));
  execFileSync("plutil", ["-convert", "xml1", fragment]);
  log(
    `staged ${path.relative(root, staged)}, its acknowledgements and the app's Info.plist keys`,
  );
}
