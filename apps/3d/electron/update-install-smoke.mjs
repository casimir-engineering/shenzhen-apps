import fs from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { createRequire } from "node:module";
import { _electron as electron, expect } from "@playwright/test";
import { validOwner } from "../scripts/upload-release-asset-config.mjs";
const root = process.cwd();
const option = (name) =>
  process.argv.find((x) => x.startsWith(`--${name}=`))?.slice(name.length + 3);
const owner = option("owner");
if (!validOwner(owner))
  throw Error("An explicit valid --owner=repository-owner is required");
if (
  process.argv.includes("--check-mirror") ||
  option("check-owner") !== undefined
)
  throw Error("Use a separate isolated fixture for each explicit update owner");
for (const name of ["fixture", "reference-app", "zip", "output"])
  if (!option(name)) throw Error(`Missing --${name}=absolute-path`);
const fixture = await fs.realpath(option("fixture")),
  reference = await fs.realpath(option("reference-app")),
  zip = await fs.realpath(option("zip"));
const safeRoot = await fs.realpath(path.join(root, "artifacts/updater-e2e"));
const inside = (parent, child) => child.startsWith(parent + path.sep);
if (
  !inside(safeRoot, fixture) ||
  !fixture.endsWith("/fixture/mac-arm64/Shenzhen 3D.app") ||
  fixture === reference
)
  throw Error("Only an isolated updater-e2e fixture bundle may be replaced");
const output = path.resolve(option("output"));
if (!inside(safeRoot, output) || inside(fixture, output))
  throw Error("Output must be a separate updater-e2e artifacts directory");
const outputParent = await fs.realpath(path.dirname(output));
if (outputParent !== safeRoot && !inside(safeRoot, outputParent))
  throw Error("Output parent resolves outside updater-e2e");
const running = execFileSync("ps", ["-axo", "command"], { encoding: "utf8" })
  .split("\n")
  .filter((line) => line.includes(".app/Contents/MacOS/Shenzhen 3D"));
if (running.length)
  throw Error(
    "Close other Shenzhen 3D apps before the isolated native updater test",
  );
await fs.mkdir(output, { recursive: false });
const profile = path.join(output, "profile"),
  jsCache = path.join(output, "updater-cache");
await fs.mkdir(profile);
await fs.mkdir(jsCache);
const id = "com.shenzhen3d.performance",
  job = id + ".ShipIt",
  domain = `gui/${process.getuid()}/${job}`;
const library = path.join(os.homedir(), "Library");
const cacheLinks = [id, job].map((name) => ({
  link: path.join(library, "Caches", name),
  target: path.join(output, "native-cache", name),
}));
const exists = async (p) => {
  try {
    await fs.lstat(p);
    return true;
  } catch (e) {
    if (e.code === "ENOENT") return false;
    throw e;
  }
};
const command = (file, args) => {
  try {
    return {
      ok: true,
      stdout: execFileSync(file, args, {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
      }),
    };
  } catch {
    return { ok: false, stdout: "" };
  }
};
const plist = (app) =>
  JSON.parse(
    execFileSync(
      "plutil",
      ["-convert", "json", "-o", "-", path.join(app, "Contents/Info.plist")],
      { encoding: "utf8" },
    ),
  );
const sha = async (file, algorithm = "sha256", encoding = "hex") =>
  createHash(algorithm)
    .update(await fs.readFile(file))
    .digest(encoding);
const shipItPreferences = async () => [
  ...(await fs.readdir(path.join(library, "Preferences")))
    .filter((x) => x === job + ".plist")
    .map((x) => path.join(library, "Preferences", x)),
  ...(await fs.readdir(path.join(library, "Preferences/ByHost")))
    .filter((x) => x.startsWith(job + "."))
    .map((x) => path.join(library, "Preferences/ByHost", x)),
];
for (const { link } of cacheLinks)
  if (await exists(link))
    throw Error("Existing native updater cache prevents isolated test");
if (command("launchctl", ["print", domain]).ok)
  throw Error("Existing ShipIt service prevents isolated test");
if ((await shipItPreferences()).length)
  throw Error("Existing ShipIt preferences prevent isolated test");
for (const app of [fixture, reference]) {
  execFileSync("codesign", ["--verify", "--deep", "--strict", app], {
    stdio: "pipe",
  });
  if (plist(app).CFBundleIdentifier !== id)
    throw Error("Unexpected bundle identity");
}
const sourceVersion = plist(fixture).CFBundleShortVersionString,
  targetVersion = plist(reference).CFBundleShortVersionString;
const fixtureProvenance = JSON.parse(
  createRequire(import.meta.url)("@electron/asar").extractFile(
    path.join(fixture, "Contents/Resources/app.asar"),
    "build-info.json",
  ),
);
const referenceProvenance = JSON.parse(
  createRequire(import.meta.url)("@electron/asar").extractFile(
    path.join(reference, "Contents/Resources/app.asar"),
    "build-info.json",
  ),
);
if (
  (referenceProvenance.releaseOwner !== undefined ||
    targetVersion === "0.1.6") &&
  referenceProvenance.releaseOwner !== owner
)
  throw Error(
    "Reference app releaseOwner differs from the requested update owner",
  );
if (fixtureProvenance.releaseOwner !== undefined) {
  if (fixtureProvenance.releaseOwner !== owner)
    throw Error("Fixed-origin fixture cannot switch to another update owner");
}
const syntheticFixture = !!fixtureProvenance.fixture;
if (
  !/^\d+\.\d+\.\d+$/.test(sourceVersion) ||
  !/^\d+\.\d+\.\d+$/.test(targetVersion) ||
  sourceVersion === targetVersion
)
  throw Error("Fixture/reference versions must be distinct release versions");
const evidence = {
  startedAt: new Date().toISOString(),
  fixture,
  reference,
  zip,
  profile,
  sourceVersion,
  targetVersion,
  releaseOwner: owner,
  referenceReleaseOwner: referenceProvenance.releaseOwner,
  fixtureKind: syntheticFixture
    ? "synthetic-version-override"
    : "released-app-copy",
  fixtureSourceCommit: fixtureProvenance.sourceCommit,
  checks: [],
  limitations: [
    ...(syntheticFixture
      ? ["Same final updater code with a synthetic older package version"]
      : []),
    "Install dialog response is programmatically confirmed; native dialog rendering is not tested",
    "Real Squirrel signed replacement followed by manual launch with temporary profile; automatic relaunch is disabled to preserve isolation",
  ],
};
const record = async (check, data = {}) => {
  evidence.checks.push({ check, at: new Date().toISOString(), ...data });
  await fs.writeFile(
    path.join(output, "result.json"),
    JSON.stringify(evidence, null, 2) + "\n",
  );
  console.log(check);
};
execFileSync("xcrun", ["stapler", "validate", reference], { stdio: "pipe" });
const referenceHash = await sha(
  path.join(reference, "Contents/Resources/app.asar"),
);
const zipHash = await sha(zip, "sha512", "base64");
let application,
  installStarted = false,
  installed = false;
const environment = { ...process.env };
for (const key of [
  "SHENZHEN_3D_DEV_URL",
  "ELECTRON_RUN_AS_NODE",
  "GH_TOKEN",
  "GITHUB_TOKEN",
])
  delete environment[key];
const launch = () =>
  electron.launch({
    executablePath: path.join(fixture, "Contents/MacOS/Shenzhen 3D"),
    args: [`--user-data-dir=${profile}`],
    env: environment,
    timeout: 30_000,
  });
try {
  for (const { link, target } of cacheLinks) {
    await fs.mkdir(target, { recursive: true });
    await fs.symlink(target, link, "dir");
  }
  application = await launch();
  let page = await application.firstWindow();
  await page.bringToFront();
  await application.evaluate(({ app, BrowserWindow }) => {
    app.focus({ steal: true });
    BrowserWindow.getAllWindows()[0].focus();
  });
  await expect(
    page.getByRole("button", { name: "Updates", exact: true }),
  ).toBeVisible();
  const runtime = await application.evaluate(({ app }) => ({
    packaged: app.isPackaged,
    version: app.getVersion(),
    profile: app.getPath("userData"),
    appPath: app.getAppPath(),
  }));
  expect(runtime.packaged).toBe(true);
  expect(runtime.version).toBe(sourceVersion);
  expect(runtime.profile).toBe(profile);
  await record("Signed older fixture launched with isolated profile", {
    runtime,
  });
  // Test-process overrides only: retain genuine download, signature verification,
  // native installer, and app IPC. Avoid a relaunch that drops user-data-dir.
  await application.evaluate(({ app, dialog }, cache) => {
    const req = process
      .getBuiltinModule("module")
      .createRequire(app.getAppPath() + "/package.json");
    const { ElectronAppAdapter } = req(
      "electron-updater/out/ElectronAppAdapter",
    );
    Object.defineProperty(ElectronAppAdapter.prototype, "baseCachePath", {
      get: () => cache,
      configurable: true,
    });
    const { MacUpdater } = req("electron-updater");
    const original = MacUpdater.prototype.quitAndInstall;
    MacUpdater.prototype.quitAndInstall = function (...args) {
      this.autoRunAppAfterInstall = false;
      return original.apply(this, args);
    };
    globalThis.__updaterInstallDialog = undefined;
    dialog.showMessageBox = async (options) => {
      if (
        options.title !== "Restart to install update?" ||
        options.buttons?.[0] !== "Install and restart" ||
        options.defaultId !== 1
      )
        throw Error("Unexpected install confirmation");
      globalThis.__updaterInstallDialog = {
        title: options.title,
        buttons: options.buttons,
        defaultId: options.defaultId,
        message: options.message,
      };
      return { response: 0, checkboxChecked: false };
    };
  }, jsCache);
  await page.evaluate(
    ({ owner, fixedOrigin }) =>
      window.shenzhenUpdates.configure({
        automatic: false,
        ...(fixedOrigin ? {} : { repository: owner }),
        prereleases: true,
      }),
    { owner, fixedOrigin: fixtureProvenance.releaseOwner !== undefined },
  );
  const connection = await page.evaluate(() =>
    window.shenzhenUpdates.useGitHubCLI(),
  );
  expect(connection.connected).toBe(true);
  expect(connection.repository).toBe(owner);
  const settingsFile = path.join(profile, "updates.json");
  const saved = JSON.parse(await fs.readFile(settingsFile, "utf8"));
  expect(typeof saved.encryptedToken).toBe("string");
  expect(saved.encryptedToken.length).toBeGreaterThan(20);
  expect((await fs.stat(settingsFile)).mode & 0o777).toBe(0o600);
  expect(Object.keys(saved)).not.toContain("token");
  await record(
    "Existing GitHub CLI authorization encrypted only in temporary profile",
    { settingsMode: "0600" },
  );
  const available = await page.evaluate(() => window.shenzhenUpdates.check());
  expect(available.status).toBe("available");
  expect(available.repository).toBe(owner);
  expect(available.availableVersion).toBe(targetVersion);
  await record(`Private GitHub ${owner} feed offered exactly ${targetVersion}`);
  const downloading = page.evaluate(() => window.shenzhenUpdates.download());
  const downloaded = await downloading;
  expect(downloaded.status).toBe("ready");
  expect(downloaded.repository).toBe(owner);
  const zips = [];
  async function scan(dir) {
    for (const entry of await fs.readdir(dir, { withFileTypes: true })) {
      const p = path.join(dir, entry.name);
      if (entry.isDirectory()) await scan(p);
      else if (entry.name.endsWith(".zip")) zips.push(p);
    }
  }
  await scan(jsCache);
  let matched;
  for (const p of zips)
    if ((await sha(p, "sha512", "base64")) === zipHash) matched = p;
  expect(matched).toBeTruthy();
  await record("Downloaded GitHub ZIP matches frozen local artifact SHA-512", {
    zipSha512: zipHash,
  });
  installStarted = true;
  const closed = application.waitForEvent("close", { timeout: 180_000 });
  await page.evaluate(() => window.shenzhenUpdates.install()).catch(() => {});
  await closed;
  application = undefined;
  const deadline = Date.now() + 180_000;
  while (Date.now() < deadline) {
    try {
      if (
        plist(fixture).CFBundleShortVersionString === targetVersion &&
        (await sha(path.join(fixture, "Contents/Resources/app.asar"))) ===
          referenceHash
      ) {
        installed = true;
        break;
      }
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
  expect(installed).toBe(true);
  execFileSync("codesign", ["--verify", "--deep", "--strict", fixture], {
    stdio: "pipe",
  });
  execFileSync("xcrun", ["stapler", "validate", fixture], { stdio: "pipe" });
  execFileSync("spctl", ["--assess", "--type", "execute", fixture], {
    stdio: "pipe",
  });
  await record(
    `Native Squirrel replaced only isolated fixture with signed and notarized ${targetVersion}`,
    {
      asarSha256: referenceHash,
      stapledTicketValidated: true,
      gatekeeperAccepted: true,
    },
  );
  application = await launch();
  page = await application.firstWindow();
  await expect(
    page.getByRole("button", { name: "Updates", exact: true }),
  ).toBeVisible();
  const updated = await application.evaluate(({ app }) => ({
    packaged: app.isPackaged,
    version: app.getVersion(),
    profile: app.getPath("userData"),
  }));
  expect(updated).toEqual({ packaged: true, version: targetVersion, profile });
  const installedUpdateState = await page.evaluate(() =>
    window.shenzhenUpdates.getState(),
  );
  expect(installedUpdateState.repository).toBe(owner);
  await page.evaluate(() => window.shenzhenUpdates.disconnect());
  await record(
    `Replaced ${targetVersion} app relaunched manually with same isolated profile`,
    { runtime: updated, updateRepository: installedUpdateState.repository },
  );
  evidence.success = true;
} catch {
  evidence.success = false;
  evidence.failedAfter = evidence.checks.at(-1)?.check || "preflight";
  throw Error(
    `Updater install smoke failed after: ${evidence.failedAfter}. See redacted result.json and owned native logs.`,
  );
} finally {
  if (application && (!installStarted || installed))
    await application.close().catch(() => {});
  await fs.rm(path.join(profile, "updates.json"), { force: true });
  if (!installStarted || installed) {
    const service = command("launchctl", ["print", domain]);
    if (service.ok && service.stdout.includes(fixture))
      command("launchctl", ["bootout", domain]);
    for (const { link, target } of cacheLinks)
      if (
        (await exists(link)) &&
        (await fs.lstat(link)).isSymbolicLink() &&
        (await fs.readlink(link)) === target
      )
        await fs.unlink(link);
    if ((await shipItPreferences()).length) {
      command("defaults", ["-currentHost", "delete", job]);
      command("defaults", ["delete", job]);
      for (const preference of await shipItPreferences()) {
        const contents = JSON.parse(
          execFileSync("plutil", ["-convert", "json", "-o", "-", preference], {
            encoding: "utf8",
          }),
        );
        if (Object.keys(contents).length === 0) await fs.unlink(preference);
      }
    }
    evidence.cleanupVerified = {
      nativeCacheLinksAbsent: !(
        await Promise.all(cacheLinks.map(({ link }) => exists(link)))
      ).some(Boolean),
      shipItJobAbsent: !command("launchctl", ["print", domain]).ok,
      shipItPreferencesAbsent: (await shipItPreferences()).length === 0,
      credentialFileAbsent: !(await exists(path.join(profile, "updates.json"))),
    };
    evidence.cleanup = Object.values(evidence.cleanupVerified).every(Boolean)
      ? "Owned native cache links, ShipIt job and empty new preference file removed; isolated credential file removed"
      : "Some owned native state remains; inspect cleanupVerified before another test";
  } else
    evidence.cleanup =
      "Install may still be in progress; native cache links retained for investigation; isolated credential file removed";
  evidence.finishedAt = new Date().toISOString();
  await fs.writeFile(
    path.join(output, "result.json"),
    JSON.stringify(evidence, null, 2) + "\n",
  );
}
