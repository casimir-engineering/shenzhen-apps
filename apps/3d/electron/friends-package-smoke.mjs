// Packages Shenzhen 3D with Shenzhen Friends the way package-mac.mjs does, but ad hoc signed and as a directory
// only (never a release identity, notarization or upload), then checks the embedded pieces and runs the packaged
// app against its own embedded helper in a temporary Friends home.
//
//   scripts/friends/setup-friends.sh && npm run build && node electron/friends-package-smoke.mjs
import { _electron as electron, expect } from "@playwright/test";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { execFileSync, spawn } from "node:child_process";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const root = path.resolve(
  path.dirname(new URL(import.meta.url).pathname),
  "..",
);
const { stageRuntime } = await import("./package-mac.mjs");
const { buildFriendsNative } = await import("./friends/build-native.mjs");
const { stageFriends, checkFriendsBundle } = require("./friends/package.cjs");
const pkg = JSON.parse(
  await fs.readFile(path.join(root, "package.json"), "utf8"),
);

const directory = await fs.mkdtemp(path.join(os.tmpdir(), "szf3d-package-"));
const staging = path.join(directory, "staging"),
  output = path.join(directory, "out");
const checks = [];
const check = (name) => {
  checks.push(name);
  console.log(`ok ${checks.length} ${name}`);
};
let application;
try {
  execFileSync(
    path.join(root, "scripts/friends/setup-friends.sh"),
    ["--check"],
    { stdio: "inherit" },
  );
  await fs.mkdir(staging, { recursive: true });
  await fs.cp(path.join(root, "dist"), path.join(staging, "dist"), {
    recursive: true,
  });
  const friendsNative = await buildFriendsNative({
    arch: "arm64",
    output: path.join(directory, "friends-link.node"),
  });
  const runtime = await stageRuntime(staging, pkg, {
    releaseOwner: "fixture-owner",
    friendsNative,
  });
  const friends = await stageFriends(staging, { repoRoot: root });
  await fs.writeFile(
    path.join(staging, "build-info.json"),
    JSON.stringify({ version: pkg.version, friends, ...runtime }, null, 2) +
      "\n",
  );
  check("the runtime, the client addon and the Friends helper are staged");

  await new Promise((resolve, reject) => {
    const child = spawn(
      process.execPath,
      [
        path.join(root, "node_modules/electron-builder/out/cli/cli.js"),
        "--projectDir",
        staging,
        "--config",
        path.join(root, "electron-builder.cjs"),
        "--config.publish.owner",
        "fixture-owner",
        "--config.directories.output",
        output,
        "--config.electronVersion",
        pkg.devDependencies.electron,
        // Ad hoc only: tests never sign with a release identity.
        "--config.mac.identity=-",
        "--mac",
        "--arm64",
        "--dir",
        "--publish",
        "never",
      ],
      {
        cwd: root,
        stdio: ["ignore", "inherit", "inherit"],
        env: { ...process.env, CSC_IDENTITY_AUTO_DISCOVERY: "false" },
      },
    );
    child.once("error", reject);
    child.once("exit", (code) =>
      code === 0
        ? resolve()
        : reject(Error(`electron-builder exited with ${code}`)),
    );
  });
  const app = path.join(output, "mac-arm64", "Shenzhen 3D.app");
  await checkFriendsBundle(app, root);
  execFileSync("codesign", ["--verify", "--deep", "--strict", app], {
    stdio: "pipe",
  });
  const plist = JSON.parse(
    execFileSync(
      "plutil",
      ["-convert", "json", "-o", "-", path.join(app, "Contents/Info.plist")],
      { encoding: "utf8" },
    ),
  );
  expect(
    plist.CFBundleURLTypes?.flatMap((type) => type.CFBundleURLSchemes),
  ).toContain("shenzhen3d");
  check(
    "the app embeds the Friends helper, animal set, notices and addon, and verifies ad hoc signed",
  );

  // The packaged app in a temporary Friends home: its ad hoc signature carries no team, so the client library
  // honours SZFRIENDS_STATE_DIR, and the helper it starts is the one in its own Contents/Helpers.
  const home = path.join(directory, "home");
  const environment = { ...process.env, SZFRIENDS_STATE_DIR: home };
  delete environment.SHENZHEN_3D_DEV_URL;
  delete environment.SHENZHEN_3D_FRIENDS_HELPER;
  application = await electron.launch({
    executablePath: path.join(app, "Contents/MacOS/Shenzhen 3D"),
    args: [`--user-data-dir=${path.join(directory, "profile")}`],
    env: environment,
  });
  const page = await application.firstWindow();
  await expect(page.locator('[data-szfriends="button"]')).toBeVisible({
    timeout: 30_000,
  });
  const embedded = path.join(
    app,
    "Contents/Helpers/Shenzhen Friends.app/Contents/MacOS/Shenzhen Friends",
  );
  await expect
    .poll(() => {
      try {
        return (
          execFileSync("pgrep", ["-f", embedded], { encoding: "utf8" }).trim()
            .length > 0
        );
      } catch {
        return false;
      }
    })
    .toBe(true);
  await expect
    .poll(() =>
      fs.access(path.join(home, "helper.log")).then(
        () => true,
        () => false,
      ),
    )
    .toBe(true);
  check(
    "the packaged app starts its embedded helper after first paint, in the temporary home",
  );
} finally {
  await application?.close().catch(() => {});
  // The helper exits 10 s after its last client; wait for it before removing its home.
  for (let i = 0; i < 30; i++) {
    try {
      execFileSync("pgrep", ["-f", path.join(directory, "out")], {
        stdio: "ignore",
      });
      await new Promise((resolve) => setTimeout(resolve, 1000));
    } catch {
      break;
    }
  }
  await fs.rm(directory, { recursive: true, force: true });
}
console.log(JSON.stringify({ friendsPackage: "passed", checks }, null, 2));
