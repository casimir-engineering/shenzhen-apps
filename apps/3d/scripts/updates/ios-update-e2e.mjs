#!/usr/bin/env node
// The iPhone and iPad update test, in an iOS simulator of its own (created, booted without the Simulator app, and
// deleted at the end): a simulator test build (feature updates-test-api) against the local copy of GitHub
// (mock-github.mjs) serving the candidate release, with the page driver using the Updates dialog. It checks that
// the app finds the release's manifest.plist, offers "Update to <version>", and hands iOS the itms-services link
// for that manifest. The simulator has no installer for such links, so the install itself is not tried here: only
// a device registered for testing can do that.
//
//   node scripts/updates/ios-update-e2e.mjs --app <simulator .app> --release <dir> --tag preview-<v> --work <dir>
//     [--device "iPhone 17"] [--keep]
import { spawn, spawnSync } from "node:child_process";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const option = (name, fallback) => {
  const index = process.argv.indexOf(`--${name}`);
  return index < 0 ? fallback : process.argv[index + 1];
};
const app = path.resolve(option("app"));
const release = path.resolve(option("release"));
const tag = option("tag");
const work = path.resolve(option("work"));
const version = tag.replace(/^(preview-|v)/, "");
mkdirSync(work, { recursive: true });
let failed = false;
const ok = (text) => console.log(`ok ${text}`);
const notOk = (text) => {
  failed = true;
  console.log(`not ok ${text}`);
};
const simctl = (...args) => {
  const result = spawnSync("xcrun", ["simctl", ...args], { encoding: "utf8" });
  if (result.status !== 0)
    throw Error(`simctl ${args[0]}: ${result.stderr.trim()}`);
  return result.stdout.trim();
};
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const portFile = path.join(work, "port");
const mock = spawn(
  process.execPath,
  [
    path.join(here, "mock-github.mjs"),
    "--dir",
    release,
    "--tag",
    tag,
    "--port-file",
    portFile,
    "--log",
    path.join(work, "mock.log"),
  ],
  { stdio: "ignore" },
);
for (let i = 0; i < 100 && !existsSync(portFile); i++) await sleep(100);
const api = `http://127.0.0.1:${readFileSync(portFile, "utf8").trim()}`;
ok(`the local copy of GitHub serves ${tag} at ${api}`);

const udid = simctl(
  "create",
  `Shenzhen 3D update test ${process.pid}`,
  option("device", "iPhone 17"),
);
ok(`created simulator ${udid}`);
try {
  simctl("boot", udid);
  simctl("bootstatus", udid);
  simctl("install", udid, app);
  const bundle = JSON.parse(
    spawnSync(
      "plutil",
      ["-convert", "json", "-o", "-", path.join(app, "Info.plist")],
      { encoding: "utf8" },
    ).stdout,
  );
  ok(
    `installed ${bundle.CFBundleIdentifier} ${bundle.CFBundleShortVersionString}`,
  );
  // The page driver and the log live in the app's own container, which the app can read and write.
  const container = simctl(
    "get_app_container",
    udid,
    bundle.CFBundleIdentifier,
    "data",
  );
  const driver = path.join(container, "tmp", "drive-update.js");
  const log = path.join(container, "tmp", "updates-test.log");
  mkdirSync(path.dirname(driver), { recursive: true });
  copyFileSync(
    path.resolve(here, "../../tests/updates/drive-update.js"),
    driver,
  );
  writeFileSync(log, "");
  const launched = spawnSync(
    "xcrun",
    ["simctl", "launch", udid, bundle.CFBundleIdentifier],
    {
      encoding: "utf8",
      env: {
        ...process.env,
        SIMCTL_CHILD_SHENZHEN_3D_UPDATES_API: api,
        SIMCTL_CHILD_SHENZHEN_3D_UPDATES_TEST_PAGE: driver,
        SIMCTL_CHILD_SHENZHEN_3D_UPDATES_TEST_LOG: log,
      },
    },
  );
  if (launched.status !== 0) throw Error(launched.stderr);
  ok(`launched (${launched.stdout.trim()})`);

  const lines = () => readFileSync(log, "utf8").split("\n");
  async function waitFor(what, pattern, after = 0) {
    for (
      const begun = Date.now();
      Date.now() - begun < 120_000;
      await sleep(500)
    ) {
      const index = lines().findIndex(
        (line, i) => i >= after && pattern.test(line),
      );
      if (index >= 0) {
        ok(`${what}: ${lines()[index].replace(/^\d+ /, "").slice(0, 200)}`);
        return index;
      }
    }
    notOk(`${what}: not seen`);
    return -1;
  }
  const escaped = version.replaceAll(".", "\\.");
  let at = await waitFor("the app started", /started \S+ as Ios/);
  at = await waitFor(
    "the footer offers Updates",
    /page footer "v[\d.]+ · Updates"/,
    at,
  );
  at = await waitFor(
    `the check finds ${version}`,
    new RegExp(`page dialog "Version ${escaped} is available"`),
    at,
  );
  const available = lines()[at] ?? "";
  if (/registered for testing/.test(available))
    ok("the dialog says which iPhones and iPads can install it");
  else notOk(`the dialog says ${available}`);
  at = await waitFor(
    `the dialog offers "Update to ${version}"`,
    new RegExp(`page clicks "Update to ${escaped}"`),
    at,
  );
  at = await waitFor(
    "the app hands iOS the install link",
    /opening itms-services:\/\//,
    at,
  );
  const link = lines()[at]?.split("opening ")[1] ?? "";
  const manifest = decodeURIComponent(
    link.replace(/^itms-services:\/\/\?action=download-manifest&url=/, ""),
  );
  if (manifest === `${api}/download/${tag}/manifest.plist`)
    ok(`the link names the release's manifest.plist (${manifest})`);
  else notOk(`the link names ${manifest}`);
  const answered = await waitFor(
    "iOS takes the link",
    /iOS opened the link: true/,
    at,
  );
  if (answered >= 0) {
    // The simulator accepts the link but has no installer behind it: it never asks for the manifest.
    const asked = readFileSync(path.join(work, "mock.log"), "utf8").includes(
      "manifest.plist",
    );
    ok(
      `(the simulator ${asked ? "fetched" : "did not fetch"} the manifest; installing needs a registered device)`,
    );
  }
  await waitFor(
    "the dialog says what happened",
    /page dialog ".*" "(Tap Install|This iPhone or iPad couldn't)/,
    at,
  );
  await sleep(1500);
  spawnSync("xcrun", [
    "simctl",
    "io",
    udid,
    "screenshot",
    path.join(work, "updates-dialog.png"),
  ]);
  ok(`screenshot ${path.join(work, "updates-dialog.png")}`);
  copyFileSync(log, path.join(work, "app.log"));
} catch (error) {
  notOk(String(error?.message ?? error));
} finally {
  mock.kill();
  if (!process.argv.includes("--keep")) {
    spawnSync("xcrun", ["simctl", "shutdown", udid]);
    spawnSync("xcrun", ["simctl", "delete", udid]);
    ok("simulator deleted");
  }
}
console.log(failed ? "FAILED" : "PASSED");
process.exit(failed ? 1 : 0);
