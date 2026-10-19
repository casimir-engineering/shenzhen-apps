import fs from "node:fs/promises";
import path from "node:path";
import { execFileSync, spawn } from "node:child_process";
import { createHash } from "node:crypto";
const root = process.cwd();
const arg = (name) =>
  process.argv.find((x) => x.startsWith(`--${name}=`))?.slice(name.length + 3);
const staging = path.resolve(arg("staging") || "");
const reference = path.resolve(arg("reference-app") || "");
const run = path.resolve(arg("run-dir") || "");
for (const name of ["staging", "reference-app", "run-dir"])
  if (!arg(name)) throw Error(`Missing --${name}`);
if (!run.startsWith(path.join(root, "artifacts/updater-e2e") + path.sep))
  throw Error("Fixture output must be under artifacts/updater-e2e");
const safeRoot = await fs.realpath(path.join(root, "artifacts/updater-e2e"));
const runParent = await fs.realpath(path.dirname(run));
if (runParent !== safeRoot && !runParent.startsWith(safeRoot + path.sep))
  throw Error("Fixture parent resolves outside updater-e2e");
const stagingReal = await fs.realpath(staging),
  referenceReal = await fs.realpath(reference);
if (
  !stagingReal.startsWith(path.join(root, "artifacts/electron") + path.sep) ||
  !referenceReal.startsWith(path.join(root, "artifacts/electron") + path.sep)
)
  throw Error(
    "Final staging and reference app must be immutable Electron build artifacts",
  );
await fs.mkdir(run, { recursive: false });
const fixtureStaging = path.join(run, "staging");
await fs.cp(staging, fixtureStaging, { recursive: true, dereference: true });
const pkg = JSON.parse(
  await fs.readFile(path.join(fixtureStaging, "package.json"), "utf8"),
);
if (pkg.version !== "0.1.4") throw Error("Expected final 0.1.4 staging");
pkg.version = "0.1.3";
await fs.writeFile(
  path.join(fixtureStaging, "package.json"),
  JSON.stringify(pkg, null, 2) + "\n",
);
const lock = JSON.parse(
  await fs.readFile(path.join(fixtureStaging, "package-lock.json"), "utf8"),
);
lock.version = lock.packages[""].version = "0.1.3";
await fs.writeFile(
  path.join(fixtureStaging, "package-lock.json"),
  JSON.stringify(lock, null, 2) + "\n",
);
const provenance = JSON.parse(
  await fs.readFile(path.join(fixtureStaging, "build-info.json"), "utf8"),
);
provenance.fixture = {
  purpose: "Isolated signed updater replacement test",
  updaterCodeVersion: "0.1.4",
  packageVersion: "0.1.3",
  referenceApp: reference,
};
provenance.version = "0.1.3";
await fs.writeFile(
  path.join(fixtureStaging, "build-info.json"),
  JSON.stringify(provenance, null, 2) + "\n",
);
const feed = path.join(reference, "Contents/Resources/app-update.yml");
await fs.access(feed);
const config = path.join(run, "fixture-builder.cjs");
await fs.writeFile(
  config,
  `const base=require(${JSON.stringify(path.join(root, "electron-builder.cjs"))}); module.exports={...base,extraResources:[...base.extraResources,{from:${JSON.stringify(feed)},to:'app-update.yml'}]};\n`,
);
const installed = JSON.parse(
  await fs.readFile(
    path.join(root, "node_modules/electron/package.json"),
    "utf8",
  ),
);
await new Promise((resolve, reject) => {
  const child = spawn(
    process.execPath,
    [
      path.join(root, "node_modules/electron-builder/out/cli/cli.js"),
      "--projectDir",
      fixtureStaging,
      "--config",
      config,
      "--config.directories.output",
      path.join(run, "fixture"),
      "--config.electronVersion",
      installed.version,
      "--mac",
      "--arm64",
      "--dir",
      "--publish",
      "never",
    ],
    { cwd: root, stdio: "inherit" },
  );
  child.once("error", reject);
  child.once("exit", (code) =>
    code === 0 ? resolve() : reject(Error("Fixture builder failed")),
  );
});
const app = path.join(run, "fixture/mac-arm64/Shenzhen 3D.app");
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
if (
  plist.CFBundleIdentifier !== "com.shenzhen3d.performance" ||
  plist.CFBundleShortVersionString !== "0.1.3"
)
  throw Error("Fixture identity/version mismatch");
const sha = async (file) =>
  createHash("sha256")
    .update(await fs.readFile(file))
    .digest("hex");
const evidence = {
  createdAt: new Date().toISOString(),
  referenceApp: reference,
  fixtureApp: app,
  bundleIdentifier: plist.CFBundleIdentifier,
  fixtureVersion: plist.CFBundleShortVersionString,
  referenceAsarSha256: await sha(
    path.join(reference, "Contents/Resources/app.asar"),
  ),
  fixtureAsarSha256: await sha(path.join(app, "Contents/Resources/app.asar")),
  signatureVerified: true,
  limitations: [
    "Synthetic older version of final updater code; original 0.1.3 binary had no updater",
    "Frontend remains the final 0.1.4 frontend",
    "Automatic relaunch is disabled during install; updated fixture is relaunched manually with the isolated profile",
  ],
};
await fs.writeFile(
  path.join(run, "fixture.json"),
  JSON.stringify(evidence, null, 2) + "\n",
);
console.log(
  JSON.stringify({
    fixtureApp: app,
    signatureVerified: true,
    version: "0.1.3",
  }),
);
