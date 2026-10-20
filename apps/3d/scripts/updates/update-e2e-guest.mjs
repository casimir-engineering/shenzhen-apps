#!/usr/bin/env node
// The update test inside a Windows or Linux computer (scripts/updates/vm-update-e2e.sh copies it there): an
// installed test build of Shenzhen 3D (feature updates-test-api) against the local copy of GitHub
// (mock-github.mjs) serving the candidate release, with the page driver (tests/updates/drive-update.js) using the
// Updates dialog as a person would. It waits for each step in the app's test log and prints `ok …` / `not ok …`.
//
//   node update-e2e-guest.mjs --app <installed app> --release <dir> --tag preview-<v> --work <dir>
//     [--tamper <asset>]       the first download of <asset> has one byte changed: Update must refuse it, and the
//                              second Update must go through
//     [--expect install|download]
//     [--replaced <file> --sha256 <hash>]   after the update, <file> must hold these bytes (an AppImage)
//     [--timeout <seconds>]
//
// --expect install (the default): the old version finds the candidate, downloads it (refusing a changed file),
// Restart & install hands over to the installer, and the new version starts and finds itself up to date.
// --expect download (deb, rpm): the app offers Download, and opens the package's download address.
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
  chmodSync,
} from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const option = (name, fallback) => {
  const index = process.argv.indexOf(`--${name}`);
  return index < 0 ? fallback : process.argv[index + 1];
};
const app = option("app");
const release = option("release");
const tag = option("tag");
const work = option("work");
const tamper = option("tamper");
const expect = option("expect", "install");
const timeout = Number(option("timeout", "600")) * 1000;
const version = tag.replace(/^(preview-|v)/, "");
const windows = process.platform === "win32";
mkdirSync(work, { recursive: true });
const log = path.join(work, "app.log");
const portFile = path.join(work, "port");
let failed = false;
const ok = (text) => console.log(`ok ${text}`);
const notOk = (text) => {
  failed = true;
  console.log(`not ok ${text}`);
};

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
    ...(tamper ? ["--tamper-once", tamper] : []),
  ],
  { stdio: "ignore" },
);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
for (let i = 0; i < 100 && !existsSync(portFile); i++) await sleep(100);
const api = `http://127.0.0.1:${readFileSync(portFile, "utf8").trim()}`;
ok(`the local copy of GitHub serves ${tag} at ${api}`);

// deb and rpm: what the app opens goes to a file instead of a browser.
const opened = path.join(work, "opened.txt");
const stubs = path.join(work, "bin");
if (!windows) {
  mkdirSync(stubs, { recursive: true });
  writeFileSync(
    path.join(stubs, "xdg-open"),
    `#!/bin/sh\necho "$1" >> "${opened}"\n`,
  );
  chmodSync(path.join(stubs, "xdg-open"), 0o755);
}
const environment = {
  ...process.env,
  SHENZHEN_3D_UPDATES_API: api,
  SHENZHEN_3D_UPDATES_TEST_PAGE: path.resolve(
    here,
    "../../tests/updates/drive-update.js",
  ),
  SHENZHEN_3D_UPDATES_TEST_LOG: log,
  ...(windows ? {} : { PATH: `${stubs}:${process.env.PATH}` }),
};
const child = spawn(app, [], {
  env: environment,
  detached: true,
  stdio: "ignore",
});
child.unref();
ok(`started ${app}`);

// Where the update put the app: the same place, unless --installed-app says otherwise.
const installedApp = () => option("installed-app", app);
const lines = () =>
  existsSync(log) ? readFileSync(log, "utf8").split("\n") : [];
async function waitFor(
  what,
  pattern,
  after = 0,
  within = timeout,
  quiet = false,
) {
  const begun = Date.now();
  while (Date.now() - begun < within) {
    const index = lines().findIndex(
      (line, i) => i >= after && pattern.test(line),
    );
    if (index >= 0) {
      ok(what);
      return index;
    }
    await sleep(500);
  }
  if (!quiet) notOk(`${what}: not seen within ${within / 1000} s`);
  return -1;
}

let at = await waitFor("the old version started", /started \d+\.\d+\.\d+ as /);
const old = lines()[at]?.match(/started (\S+) as (\S+)/);
if (old) ok(`it is ${old[1]}, installed as ${old[2]}`);
// The page's reports and the app's own lines can reach the log in either order within a moment, so each step is
// looked for from the old version's start; only the app's own lines are taken in order.
const base = at;
const escaped = version.replaceAll(".", "\\.");
await waitFor(
  `the footer offers Updates`,
  /page footer "v[\d.]+ · Updates"/,
  base,
);
await waitFor(
  `the check finds ${version}`,
  new RegExp(`page dialog "Version ${escaped} is available"`),
  base,
);
if (expect === "download") {
  await waitFor(`the dialog offers Download`, /page clicks "Download"/, base);
  at = await waitFor(`the app opens the package's download`, /opening /, base);
  const url = lines()[at]?.split("opening ")[1] ?? "";
  if (/\/download\/[^/]+\/Shenzhen-3D-[\d.]+-Linux-\w+\.(deb|rpm)$/.test(url))
    ok(`it is ${url}`);
  else notOk(`it opened ${url}`);
  await sleep(1000);
  const handed = existsSync(opened) ? readFileSync(opened, "utf8").trim() : "";
  if (handed === url) ok("the system's opener received that address");
  else notOk(`the system's opener received "${handed}"`);
} else {
  const click = new RegExp(`page clicks "Update to ${escaped}"`);
  await waitFor(`the dialog offers "Update to ${version}"`, click, base);
  if (tamper) {
    at = await waitFor(
      "a changed download is refused",
      /download refused: /,
      base,
    );
    await waitFor(
      "the dialog says so",
      /page dialog ".*" "The download didn't match the published update/,
      base,
    );
    const second = await waitFor(
      "a second Update",
      click,
      lines().findIndex((l, i) => i > base && click.test(l)) + 1,
    );
    at = Math.max(at, second);
  }
  await waitFor(
    "the download shows its progress",
    /"progress":\d+(\.\d+)?,.*"status":"downloading"/,
    base,
  );
  await waitFor(
    "the download is checked and ready",
    /page clicks "Restart & install"/,
    base,
  );
  at = await waitFor("the installer takes over", /installing \d+ bytes/, at);
  const started = new RegExp(`started ${version.replaceAll(".", "\\.")} as `);
  let relaunched = await waitFor(
    `${version} starts after the update`,
    started,
    at,
    90_000,
    true,
  );
  if (relaunched < 0 && windows) {
    // The MSI starts the new version from Windows Installer's own process, without this test's settings, so the
    // new version reads GitHub itself and writes nothing here: it is found running instead, then started again
    // with the test's settings.
    const running = spawnSync(
      "tasklist",
      ["/fi", `imagename eq ${path.basename(app)}`, "/fo", "csv", "/nh"],
      {
        encoding: "utf8",
      },
    ).stdout;
    if (running.includes(path.basename(app))) {
      ok(
        `the installer started the new version (${path.basename(app)} runs again)`,
      );
      spawnSync("taskkill", ["/f", "/im", path.basename(app)], {
        stdio: "ignore",
      });
      await sleep(2000);
      const again = spawn(installedApp(), [], {
        env: environment,
        detached: true,
        stdio: "ignore",
      });
      again.unref();
      relaunched = await waitFor(
        `${version} starts when opened again`,
        started,
        at,
      );
    }
  }
  if (relaunched < 0) notOk(`${version} did not start after the update`);
  at = Math.max(at, relaunched);
  at = await waitFor(
    `${version} finds itself up to date`,
    /page done up to date/,
    at,
  );
  const replaced = option("replaced");
  if (replaced) {
    const hash = createHash("sha256")
      .update(readFileSync(replaced))
      .digest("hex");
    if (hash === option("sha256"))
      ok(`${replaced} now holds the release's file`);
    else notOk(`${replaced} holds ${hash}`);
  }
}
const others = [
  ...readFileSync(path.join(work, "mock.log"), "utf8").matchAll(
    /GET \/download\/([^/]+)\//g,
  ),
]
  .map((m) => m[1])
  .filter((t) => t !== tag);
if (others.length)
  notOk(`the app asked for files of ${[...new Set(others)].join(", ")}`);
else
  ok(
    "only the candidate's files were requested (drafts, Mac-only and older releases passed over)",
  );

// The app and the copy of GitHub stop; the caller uninstalls.
if (windows)
  spawnSync("taskkill", ["/f", "/im", path.basename(app)], { stdio: "ignore" });
else {
  // The app was started in a process group of its own; the version it restarted into, and their web processes,
  // are in it too.
  try {
    process.kill(-child.pid, "SIGTERM");
  } catch {}
}
mock.kill();
console.log(failed ? "FAILED" : "PASSED");
process.exit(failed ? 1 : 0);
