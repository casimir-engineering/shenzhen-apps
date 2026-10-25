#!/usr/bin/env node
// android-update-e2e.mjs — Android's update from GitHub Releases, end to end on an emulator, against a mock of the
// GitHub API on this computer (docs/UPDATES.md § Android). Emulators only: it clears the app and switches its
// "Install unknown apps" setting, which it refuses to do to a real phone.
//
//   node scripts/android-update-e2e.mjs --serial emulator-5554 --old <apk> --new <apk> --new-version <x.y.z>
//     [--release] [--shots <dir>] [--bad-sum]
//
// Both APKs are signed with the same key, the new one with the higher versionCode. Debug builds read
// files/update-api.txt, which points the app at the mock. --release tests release builds as people have them (a
// published APK, or one from scripts/friends/android-release.mjs): the mock then answers as https://api.github.com
// itself, with a test certificate authority trusted and api.github.com pointed at this computer on the emulator only
// (adb root; a Google APIs image, not Google Play), all undone when the run ends.
//
// The mock lists a pre-release preview-<new-version> with the new APK and its SHA256SUMS.txt, beside a newer Mac-only
// release and a newer draft, which must both be passed over. The run: the old app installed and cleared, the mock
// named; the app finds the update by itself at launch; Updates ▸ Update to <version>; the explanation, then "Install
// unknown apps" turned on; Android's own confirmation; the new version installed and running, its data kept.
// --bad-sum first serves a wrong checksum and expects the update refused.
//
// Every look at the screen also checks for the page's red error banner: the run fails if one shows at any step of the
// update or in the first seconds of the new version's first launch. --shots saves a screenshot of each step.
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import https from "node:https";
import os from "node:os";
import path from "node:path";

const PACKAGE = "com.shenzhen3d.viewer";
const argv = process.argv.slice(2);
const option = (name) => {
  const index = argv.indexOf(`--${name}`);
  return index >= 0 ? argv[index + 1] : undefined;
};
const serial = option("serial");
const oldApk = option("old");
const newApk = option("new");
const newVersion = option("new-version");
const release = argv.includes("--release");
const shots = option("shots");
if (!serial?.startsWith("emulator-") || !oldApk || !newApk || !newVersion) {
  console.error(
    "usage: android-update-e2e.mjs --serial emulator-NNNN --old <apk> --new <apk> --new-version <x.y.z> [--release] [--shots <dir>] [--bad-sum]",
  );
  process.exit(2);
}
if (shots) fs.mkdirSync(shots, { recursive: true });
const sdk =
  process.env.ANDROID_HOME ?? path.join(os.homedir(), "Library/Android/sdk");
const adb = (...args) =>
  execFileSync(path.join(sdk, "platform-tools/adb"), ["-s", serial, ...args], {
    encoding: "utf8",
    maxBuffer: 1 << 26,
  });
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const step = (text) => console.log(`==> ${text}`);
let server;
let undoRelease = () => {};
let shotIndex = 0;
/** Saves the screen as <shots>/NN-<name>.png when --shots is given. */
function shot(name) {
  if (!shots) return;
  const file = path.join(
    shots,
    `${String(++shotIndex).padStart(2, "0")}-${name}.png`,
  );
  fs.writeFileSync(
    file,
    execFileSync(
      path.join(sdk, "platform-tools/adb"),
      ["-s", serial, "exec-out", "screencap", "-p"],
      { maxBuffer: 1 << 26 },
    ),
  );
}
const fail = (text) => {
  console.error(`FAIL: ${text}`);
  try {
    shot("fail");
  } catch {
    // The screen is not essential to the report.
  }
  server?.close();
  undoRelease();
  process.exit(1);
};

// The mock GitHub API: one pre-release with the APK and its checksums, served from here.
const apkName = `shenzhen-3d-${newVersion}-android-arm64-development.apk`;
const apkBytes = fs.statSync(newApk).size;
const apkSum = await new Promise((resolve, reject) => {
  const hash = createHash("sha256");
  fs.createReadStream(newApk)
    .on("data", (chunk) => hash.update(chunk))
    .on("end", () => resolve(hash.digest("hex")))
    .on("error", reject);
});
let badSum = argv.includes("--bad-sum");
const requests = [];
// --release: a certificate authority made for this run, and api.github.com's certificate from it.
const tls = release ? makeCertificates() : undefined;
const handler = (request, response) => {
  requests.push(request.url);
  const base = release
    ? "https://api.github.com"
    : `http://10.0.2.2:${server.address().port}`;
  if (
    request.url.startsWith("/repos/casimir-engineering/shenzhen-3D/releases")
  ) {
    response.setHeader("content-type", "application/json");
    response.end(
      JSON.stringify([
        // Newer, but for the Mac only (as preview-0.2.1 was): skipped for the newest release with an APK.
        {
          tag_name: "preview-99.0.0",
          draft: false,
          prerelease: true,
          assets: [
            {
              name: "SHA256SUMS.txt",
              size: 100,
              browser_download_url: `${base}/download/mac-sums.txt`,
            },
            {
              name: "Shenzhen-3D-99.0.0-Apple-Silicon.dmg",
              size: 1,
              browser_download_url: `${base}/download/mac.dmg`,
            },
          ],
        },
        // Newer still, but a draft: never offered.
        {
          tag_name: "preview-100.0.0",
          draft: true,
          prerelease: true,
          assets: [
            {
              name: "SHA256SUMS.txt",
              size: 100,
              browser_download_url: `${base}/download/draft-sums.txt`,
            },
            {
              name: "shenzhen-3d-100.0.0-android-arm64-development.apk",
              size: 1,
              browser_download_url: `${base}/download/draft.apk`,
            },
          ],
        },
        {
          tag_name: `preview-${newVersion}`,
          draft: false,
          prerelease: true,
          assets: [
            {
              name: "SHA256SUMS.txt",
              size: 100,
              browser_download_url: `${base}/download/SHA256SUMS.txt`,
            },
            {
              name: apkName,
              size: apkBytes,
              browser_download_url: `${base}/download/${apkName}`,
            },
            {
              name: "Shenzhen-3D-mac.dmg",
              size: 1,
              browser_download_url: `${base}/download/mac.dmg`,
            },
          ],
        },
      ]),
    );
  } else if (request.url === "/download/SHA256SUMS.txt") {
    const sum = badSum ? "0".repeat(64) : apkSum;
    response.end(`${"1".repeat(64)}  README.md\n${sum}  ${apkName}\n`);
  } else if (request.url === `/download/${apkName}`) {
    response.setHeader("content-length", apkBytes);
    fs.createReadStream(newApk).pipe(response);
  } else {
    response.statusCode = 404;
    response.end();
  }
};
server = tls
  ? https.createServer({ key: tls.key, cert: tls.cert }, handler)
  : http.createServer(handler);
await new Promise((resolve) => server.listen(0, "0.0.0.0", resolve));
step(`mock GitHub API on port ${server.address().port}`);

function makeCertificates() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "szup-ca-"));
  const run = (...args) =>
    execFileSync("openssl", args, { cwd: dir, stdio: "pipe" });
  run(
    "req",
    "-x509",
    "-newkey",
    "rsa:2048",
    "-nodes",
    "-days",
    "2",
    "-subj",
    "/CN=Shenzhen 3D update test CA",
    "-keyout",
    "ca.key",
    "-out",
    "ca.pem",
  );
  run(
    "req",
    "-newkey",
    "rsa:2048",
    "-nodes",
    "-subj",
    "/CN=api.github.com",
    "-keyout",
    "server.key",
    "-out",
    "server.csr",
  );
  fs.writeFileSync(
    path.join(dir, "san.cnf"),
    "subjectAltName=DNS:api.github.com\nextendedKeyUsage=serverAuth\n",
  );
  run(
    "x509",
    "-req",
    "-in",
    "server.csr",
    "-CA",
    "ca.pem",
    "-CAkey",
    "ca.key",
    "-CAcreateserial",
    "-days",
    "2",
    "-extfile",
    "san.cnf",
    "-out",
    "server.pem",
  );
  const hash = execFileSync(
    "openssl",
    ["x509", "-subject_hash_old", "-noout", "-in", "ca.pem"],
    { cwd: dir, encoding: "utf8" },
  ).trim();
  const result = {
    dir,
    hash,
    key: fs.readFileSync(path.join(dir, "server.key")),
    cert: fs.readFileSync(path.join(dir, "server.pem")),
  };
  return result;
}

/**
 * The emulator trusts the run's authority and sends api.github.com to this computer: both bound over the system's
 * copies in the namespaces apps and the resolver read (Android 14 reads its authorities from the conscrypt APEX), so
 * nothing on the system image changes; undone when the run ends, gone after a reboot anyway.
 */
function trustMock() {
  adb("root");
  adb("wait-for-device");
  if (adb("shell", "id -u").trim() !== "0")
    fail("--release needs adb root (a Google APIs emulator image)");
  const work = "/data/local/tmp/szup-release";
  adb("shell", `mkdir -p ${work}/cacerts`);
  adb("push", path.join(tls.dir, "ca.pem"), `${work}/cacerts/${tls.hash}.0`);
  const hosts = path.join(tls.dir, "hosts");
  fs.writeFileSync(
    hosts,
    "127.0.0.1 localhost\n::1 ip6-localhost\n127.0.0.1 api.github.com\n",
  );
  adb("push", hosts, `${work}/hosts`);
  const binds = [
    [`${work}/cacerts`, "/apex/com.android.conscrypt/cacerts"],
    [`${work}/hosts`, "/system/etc/hosts"],
  ];
  const inAll = (command) =>
    `for ns in /proc/1/ns/mnt $(for p in $(pidof zygote64 zygote netd); do echo /proc/$p/ns/mnt; done); do nsenter --mount=$ns -- ${command}; done`;
  adb(
    "shell",
    [
      "set -e",
      `cp -n /apex/com.android.conscrypt/cacerts/* ${work}/cacerts/`,
      `chmod 755 ${work}/cacerts; chmod 644 ${work}/cacerts/* ${work}/hosts`,
      `chcon -R u:object_r:system_file:s0 ${work}`,
      ...binds.map(([from, to]) => inAll(`mount --bind ${from} ${to}`)),
    ].join("; "),
  );
  adb("reverse", "tcp:443", `tcp:${server.address().port}`);
  undoRelease = () => {
    undoRelease = () => {};
    try {
      adb("reverse", "--remove", "tcp:443");
      adb(
        "shell",
        binds.map(([, to]) => inAll(`umount ${to}`)).join("; ") + "; true",
      );
    } catch (error) {
      console.error(`could not undo the emulator's test trust: ${error}`);
    }
  };
  // Apps started from now on see it; the resolver may have cached the real address.
  adb("shell", "ndc resolver flushdefaultif >/dev/null 2>&1; true");
}
if (release) {
  step("release builds: the mock answers as https://api.github.com");
  trustMock();
}

/** The screen's accessibility nodes (uiautomator). */
function screen() {
  let xml;
  try {
    // A dump fails now and then while the screen animates; the caller looks again.
    adb("shell", "uiautomator dump /data/local/tmp/szup-ui.xml >/dev/null");
    xml = adb("shell", "cat /data/local/tmp/szup-ui.xml");
  } catch {
    return [];
  }
  const nodes = [...xml.matchAll(/<node [^>]*>/g)].map(([node]) => {
    const value = (name) =>
      (node.match(new RegExp(`${name}="([^"]*)"`)) ?? [])[1] ?? "";
    const b = value("bounds").match(/\d+/g)?.map(Number) ?? [0, 0, 0, 0];
    return {
      text: value("text"),
      desc: value("content-desc"),
      id: value("resource-id"),
      pkg: value("package"),
      checked: value("checked") === "true",
      x: Math.round((b[0] + b[2]) / 2),
      y: Math.round((b[1] + b[3]) / 2),
    };
  });
  checkNoError(nodes);
  return nodes;
}
/**
 * The page's red error banner (App.tsx, role="alert", with its "Dismiss error" button) must never show during the
 * update or the new version's first launch: every look at the screen checks for it.
 */
let lookingFor = "the update";
function checkNoError(nodes) {
  const app = nodes.filter((n) => n.pkg === PACKAGE);
  const banner = app.findIndex(
    (n) => n.text === "Dismiss error" || n.desc === "Dismiss error",
  );
  if (banner < 0) return;
  const said = app
    .slice(Math.max(0, banner - 1), banner)
    .map((n) => n.text)
    .filter(Boolean)
    .join(" ");
  fail(`a red error showed during ${lookingFor}: "${said}"`);
}
const label = (node) => `${node.text} ${node.desc}`;
async function find(test, ms = 20_000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const node = screen().find(test);
    if (node) return node;
    await wait(800);
  }
  return null;
}
async function tap(what, test, ms) {
  const node = await find(test, ms);
  if (!node) fail(`no ${what} on screen`);
  adb("shell", "input", "tap", String(node.x), String(node.y));
  return node;
}
const versionName = () =>
  adb("shell", "dumpsys", "package", PACKAGE).match(/versionName=(\S+)/)?.[1];

step(`installing the old app (${path.basename(oldApk)})`);
try {
  adb("uninstall", PACKAGE);
} catch {
  // Not installed.
}
adb("install", oldApk);
adb("shell", "appops", "set", PACKAGE, "REQUEST_INSTALL_PACKAGES", "default");
const before = versionName();
// Data that must survive the update: written as the app (run-as) in debug builds, as root in release builds.
const files = `/data/data/${PACKAGE}/files`;
if (release) {
  step(`old version ${before}`);
  adb("shell", "am", "start", "-W", "-n", `${PACKAGE}/.MainActivity`);
  await wait(2_000);
  adb("shell", "am", "force-stop", PACKAGE);
  const owner = adb("shell", `stat -c %u:%g /data/data/${PACKAGE}`).trim();
  adb(
    "shell",
    `mkdir -p ${files} && echo kept > ${files}/update-e2e-marker.txt && chown -R ${owner} ${files} && restorecon -R ${files}`,
  );
} else {
  step(`old version ${before}; naming the mock`);
  adb("shell", `run-as ${PACKAGE} mkdir -p files`);
  adb(
    "shell",
    `echo http://10.0.2.2:${server.address().port} | run-as ${PACKAGE} sh -c 'cat > files/update-api.txt'`,
  );
  adb(
    "shell",
    `echo kept | run-as ${PACKAGE} sh -c 'cat > files/update-e2e-marker.txt'`,
  );
}
const readMarker = () =>
  release
    ? adb("shell", `cat ${files}/update-e2e-marker.txt`).trim()
    : adb("shell", `run-as ${PACKAGE} cat files/update-e2e-marker.txt`).trim();

step("launching: the launch check finds the update");
lookingFor = "the old version's launch";
adb("shell", "am", "start", "-W", "-n", `${PACKAGE}/.MainActivity`);
const asked = Date.now() + 40_000;
while (!requests.some((url) => url.startsWith("/repos/")) && Date.now() < asked)
  await wait(500);
if (!requests.some((url) => url.startsWith("/repos/")))
  fail("the app never asked the mock API at launch");
if (requests.some((url) => /mac|draft/.test(url)))
  fail("the app fetched from a release without an APK, or a draft");
await wait(2_000);
shot("old-version");
lookingFor = "the update";
// The footer button reads "Update available"; its accessible name is "Updates".
await tap(
  "Updates in the footer",
  (n) => n.pkg === PACKAGE && n.text === "Updates",
  40_000,
);

if (badSum) {
  step("a wrong checksum: Update is refused");
  await tap(
    `Update to ${newVersion}`,
    (n) => n.pkg === PACKAGE && label(n).includes(`Update to ${newVersion}`),
    20_000,
  );
  const refused = await find(
    (n) =>
      n.pkg === PACKAGE && /didn’t match its published checksum/.test(label(n)),
    480_000,
  );
  if (!refused) fail("a wrong checksum was not refused");
  if (versionName() !== before) fail("installed despite a wrong checksum");
  step("refused; the right checksum from now on");
  badSum = false;
}

step(`Update to ${newVersion}`);
shot("updates-open");
await tap(
  `Update to ${newVersion}`,
  (n) => n.pkg === PACKAGE && label(n).includes(`Update to ${newVersion}`),
  20_000,
);
step("downloading; then the explanation of Install unknown apps");
await tap(
  "explanation's Continue",
  (n) => n.text === "Continue" || n.text === "CONTINUE",
  480_000,
);
shot("install-unknown-apps");
step("Settings: Allow from this source");
const toggle = await find(
  (n) => /Allow from this source/i.test(label(n)),
  20_000,
);
if (!toggle) fail("Settings did not show Allow from this source");
adb("shell", "input", "tap", String(toggle.x), String(toggle.y));
await wait(1_000);
adb("shell", "input", "keyevent", "KEYCODE_BACK");
step("Android's confirmation: Update");
lookingFor = "the return from Settings";
await tap(
  "installer's Update button",
  (n) =>
    /packageinstaller|permissioncontroller/.test(n.pkg) &&
    /^(Update|UPDATE|Install|INSTALL)$/.test(n.text),
  60_000,
);
shot("installer");
const end = Date.now() + 120_000;
while (versionName() === before && Date.now() < end) await wait(2_000);
const after = versionName();
if (after === before) fail(`still ${before} after the update`);
step(`installed ${after}; launching it`);
lookingFor = `${after}'s first launch`;
// The version shows before Android has finished replacing the app; a start in that moment is dropped.
await wait(5_000);
for (let tries = 0; ; tries++) {
  adb("shell", "am", "start", "-W", "-n", `${PACKAGE}/.MainActivity`);
  await wait(1_000);
  if (
    /topResumedActivity=.*com\.shenzhen3d\.viewer/.test(
      adb("shell", "dumpsys", "activity", "activities"),
    )
  )
    break;
  if (tries === 4) fail("the new version did not come to the screen");
}
// Its first seconds, looked at every second: the banner showed as the page loaded.
for (const until = Date.now() + 8_000; Date.now() < until;) {
  screen();
  await wait(1_000);
}
shot("first-launch");
const pid = adb("shell", "pidof", PACKAGE).trim();
if (!pid) fail("the new version is not running");
const marker = readMarker();
if (marker !== "kept") fail("the app's data did not survive the update");
await tap(
  "Updates in the footer",
  (n) => n.pkg === PACKAGE && n.text === "Updates",
  40_000,
);
const shown = await find(
  (n) => n.pkg === PACKAGE && label(n).includes(`Version ${newVersion}`),
  30_000,
);
shot("new-version-updates");
if (!shown)
  fail(`the running app's Updates does not say Version ${newVersion}`);
console.log(
  `PASS: ${before} → ${after}, running (pid ${pid}), data kept, no red error; requests: ${requests.join(", ")}`,
);
server.close();
undoRelease();
