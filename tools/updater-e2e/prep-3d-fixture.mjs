// prep-3d-fixture.mjs <released-app> <out-dir> [--version=X.Y.Z]: a copy of a released Shenzhen 3D app that runs
// hidden: its main loads electron/hidden-hook.cjs first (from this repository), Info.plist says LSBackgroundOnly and
// LSUIElement. The updater code and everything else in the archive are the release's own bytes. Not signed here.
// --version gives the copy another version (package.json and Info.plist), to stand for a later release of the same
// channel in update-e2e-3d.mjs --next-app.
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
const require = createRequire(path.join(process.cwd(), "package.json"));
const asar = require("@electron/asar");
const [src, out] = process.argv.slice(2).filter((a) => !a.startsWith("--"));
const version = process.argv.find((a) => a.startsWith("--version="))?.slice(10);
if (version !== undefined && !/^\d+\.\d+\.\d+$/.test(version)) throw Error("--version=X.Y.Z");
const app = path.join(out, "Shenzhen 3D.app");
fs.mkdirSync(out, { recursive: true });
execFileSync("ditto", [src, app]);
execFileSync("xattr", ["-cr", app]);
const res = path.join(app, "Contents/Resources");
const tmp = path.join(out, "asar-src");
asar.extractAll(path.join(res, "app.asar"), tmp);
fs.copyFileSync(path.join(process.cwd(), "electron/hidden-hook.cjs"), path.join(tmp, "electron/szut-hook.cjs"));
fs.writeFileSync(path.join(tmp, "electron/szut-main.cjs"),
  '// Updater test: nothing may reach the screen (electron/hidden-hook.cjs), then the release main.\n' +
  'require("./szut-hook.cjs");\nrequire("./main.cjs");\n');
const pkg = JSON.parse(fs.readFileSync(path.join(tmp, "package.json"), "utf8"));
pkg.main = "electron/szut-main.cjs";
if (version) pkg.version = version;
fs.writeFileSync(path.join(tmp, "package.json"), JSON.stringify(pkg, null, 2) + "\n");
fs.rmSync(path.join(res, "app.asar"));
fs.rmSync(path.join(res, "app.asar.unpacked"), { recursive: true, force: true });
await asar.createPackageWithOptions(tmp, path.join(res, "app.asar"), { unpack: "*.node" });
fs.rmSync(tmp, { recursive: true });
const plist = path.join(app, "Contents/Info.plist");
for (const key of ["LSBackgroundOnly", "LSUIElement"]) {
  try { execFileSync("plutil", ["-remove", key, plist], { stdio: "pipe" }); } catch {}
  execFileSync("plutil", ["-insert", key, "-bool", "YES", plist]);
}
try { execFileSync("plutil", ["-remove", "ElectronAsarIntegrity", plist], { stdio: "pipe" }); } catch {}
if (version)
  for (const key of ["CFBundleShortVersionString", "CFBundleVersion"])
    execFileSync("plutil", ["-replace", key, "-string", version, plist]);
console.log(app);
