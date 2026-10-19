#!/usr/bin/env node
// Checks a Mac Tauri package with Friends (platform-build.mjs desktop --friends): the Objective-C helper friends.lock
// pins in Contents/Helpers with its animal set, signed on its own and linking only system libraries; the helper's
// usage descriptions and Bonjour types in the app's Info.plist (macOS holds the app responsible for the helper it
// starts); the acknowledgements; and the app's signature around it. Starts nothing.
//
//   node scripts/friends/tauri-package-check-mac.mjs "<…>/bundle/macos/Shenzhen 3D.app"
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const root = path.resolve(
  path.dirname(new URL(import.meta.url).pathname),
  "../..",
);
const {
  readFriendsLock,
  HELPER_NAME,
  HELPER_ID,
} = require("../../electron/friends/lock.cjs");
const app = path.resolve(process.argv[2] ?? "");
const lock = readFriendsLock(root);
const plist = (file) =>
  JSON.parse(
    execFileSync("plutil", ["-convert", "json", "-o", "-", file], {
      encoding: "utf8",
    }),
  );
const problems = [];
let checks = 0;
const check = (ok, name) => {
  checks++;
  console.log(`${ok ? "ok" : "not ok"} ${checks} ${name}`);
  if (!ok) problems.push(name);
};

const helper = path.join(app, "Contents/Helpers", `${HELPER_NAME}.app`);
const executable = path.join(helper, "Contents/MacOS", HELPER_NAME);
if (!fs.existsSync(executable)) {
  console.log(`not ok 1 no helper at ${helper}`);
  process.exit(1);
}
const info = plist(path.join(helper, "Contents/Info.plist"));
const expect = {
  CFBundleIdentifier: HELPER_ID,
  CFBundleShortVersionString: lock.shortVersion,
  CFBundleVersion: String(lock.buildNumber),
  SZFriendsBuildNumber: String(lock.buildNumber),
};
check(
  Object.entries(expect).every(([key, want]) => String(info[key]) === want),
  `Contents/Helpers holds the helper ${lock.keysFrom} asks for`,
);
const animals = path.join(helper, "Contents/Resources/Friends/animals");
const manifest = JSON.parse(
  fs.readFileSync(path.join(animals, "manifest.json"), "utf8"),
);
check(
  (manifest.animals ?? []).length > 0 &&
    manifest.animals.every((animal) =>
      fs.existsSync(path.join(animals, animal.svg)),
    ),
  "the helper carries its animal set, where the plugin reads it",
);
const appInfo = plist(path.join(app, "Contents/Info.plist"));
check(
  [
    "NSLocalNetworkUsageDescription",
    "NSBluetoothAlwaysUsageDescription",
    "NSBonjourServices",
  ].every(
    (key) =>
      info[key] !== undefined &&
      JSON.stringify(appInfo[key]) === JSON.stringify(info[key]),
  ),
  "the app's Info.plist carries the helper's usage descriptions and Bonjour types",
);
check(
  fs.existsSync(
    path.join(app, "Contents/Resources/Friends/Acknowledgements.txt"),
  ),
  "the acknowledgements are in Resources/Friends",
);
const verifies = (target, deep) => {
  try {
    execFileSync(
      "codesign",
      ["--verify", "--strict", ...(deep ? ["--deep"] : []), target],
      { stdio: "pipe" },
    );
    return true;
  } catch {
    return false;
  }
};
check(verifies(helper, false), "the helper's own signature verifies");
check(verifies(app, true), "the app's signature verifies around it");
const libraries = execFileSync("otool", ["-L", executable], {
  encoding: "utf8",
})
  .split("\n")
  .slice(1)
  .map((line) => line.trim().split(" ")[0])
  .filter(Boolean);
check(
  libraries.every(
    (library) =>
      library.startsWith("/usr/lib/") || library.startsWith("/System/"),
  ),
  "the helper links only system libraries",
);
process.exit(problems.length ? 1 : 0);
