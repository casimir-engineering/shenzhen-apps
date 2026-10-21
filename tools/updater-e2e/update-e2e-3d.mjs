// update-e2e-3d.mjs: a released Shenzhen 3D (0.1.9) updates itself to the new release served by a local copy of
// GitHub, hidden, then the installed new version starts and checks its own feed. Run from apps/3d (Playwright).
//
//   node update-e2e-3d.mjs --owner=O --fixture=APP --artifacts=DIR --shape=RELEASES_JSON --notes=MD --work=DIR
//                          --expect-access=public|private [--expect-owner=O2] [--relaunch-app=HIDDEN_COPY_OF_NEW_APP]
//                          [--next-app=SIGNED_NEWER_APP] [--live]
//
// --expect-owner: the owner the new build reads from, when the release moves a private channel to the public one
// (UPDATES.md, "Moving a private channel to the public one"): O's release carries O2's public build. The relaunched
// new version then reads O2's releases, which list the new release and, with --next-app (a newer, Developer ID
// signed copy, prep-3d-fixture.mjs --version), that newer one, which it must then install too.
// --live: no local copy of GitHub; the released app reads the real releases (published already) and connects with
// GitHub CLI's login, as a person would. --artifacts is then the published Mac assets, for the hash checks.
//
// The fixture is the released app with electron/hidden-hook.cjs loaded first and LSBackgroundOnly (prep-3d-fixture
// .mjs), signed again with the same Developer ID, so Squirrel's designated-requirement check is the release's. Test
// overrides, all in the main process: the updater's network session goes through a local proxy to the local GitHub
// copy and trusts its certificate; global fetch (the GitHub access check) goes to the same copy; safeStorage is an
// in-memory stand-in (no keychain); the install dialog answers Install; the app does not reopen itself after
// installing (Squirrel replaces the bundle at quit). Everything else, provider choice, release selection, version
// check, download, SHA-512 check and native install, is the release's own code.
//
// The fixture, the relaunch copy and --next-app are test copies (prep-3d-fixture.mjs): each runs under a profile of its
// own (electron/test-identity.cjs), so an installed Shenzhen 3D keeps its single-instance lock. Whatever still runs from
// the work directory or the relaunch copy when the run ends, however it was started, is ended by its exact executable
// path (sweep.py) and fails the run; so does the installed release, which is not a test copy, if Squirrel reopens it.
import fs from "node:fs";
import fsp from "node:fs/promises";
import http from "node:http";
import https from "node:https";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { createHash } from "node:crypto";
import { execFileSync, spawnSync } from "node:child_process";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const require = createRequire(path.join(process.cwd(), "package.json"));
const asar = require("@electron/asar");
const { _electron: electron } = require("@playwright/test");
const opt = (name) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3);
const owner = opt("owner"), fixtureSrc = opt("fixture"), artifacts = opt("artifacts"), work = opt("work");
const expectAccess = opt("expect-access"), shape = opt("shape"), notes = opt("notes");
const relaunchPrepared = opt("relaunch-app");
const expectOwner = opt("expect-owner") ?? owner, nextApp = opt("next-app"), live = process.argv.includes("--live");
if (nextApp && (!relaunchPrepared || expectOwner === owner || live)) throw Error("--next-app needs --relaunch-app and another --expect-owner, not --live");
if (!owner || !fixtureSrc || !artifacts || !work || !expectAccess || !shape || !notes) throw Error("missing options");
const FAKE_TOKEN = "ghp_" + "x".repeat(36);
const id = "com.shenzhen3d.performance", job = id + ".ShipIt";

const result = { owner, checks: [], requests: [] };
const save = () => fs.writeFileSync(path.join(work, "result.json"), JSON.stringify(result, null, 2) + "\n");
const check = (name, ok, detail) => {
  result.checks.push({ check: name, ok: Boolean(ok), detail });
  save();
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${detail === undefined ? "" : " " + JSON.stringify(detail).slice(0, 400)}`);
  return ok;
};
const sha = (file, alg = "sha256", enc = "hex") => createHash(alg).update(fs.readFileSync(file)).digest(enc);
const plist = (app) => JSON.parse(execFileSync("plutil", ["-convert", "json", "-o", "-", path.join(app, "Contents/Info.plist")], { encoding: "utf8" }));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

fs.mkdirSync(work, { recursive: false });
// ---- Nothing this run starts outlives it ----------------------------------------------------------------------------
// By exact executable path under the work directory and the relaunch copy, never by name: a copy the updater reopened
// has launchd as its parent and none of the test's arguments.
const owned = [work, relaunchPrepared].filter(Boolean);
const SWEEP = path.join(path.dirname(fileURLToPath(import.meta.url)), "sweep.py");
const sweep = (paths, { grace = 0, kill = true } = {}) => {
  const r = spawnSync("python3", ["-I", SWEEP, `--grace=${grace}`, ...(kill ? ["--kill"] : []), ...paths], { encoding: "utf8" });
  return { left: r.status !== 0, output: `${r.stdout ?? ""}${r.stderr ?? ""}${r.error ? String(r.error) : ""}`.trim() };
};
let swept = false;
process.on("exit", () => { if (!swept) sweep(owned); });
for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"])
  process.on(signal, () => { if (!swept) sweep(owned); swept = true; process.exit(1); });
// ---- Nothing this run starts may put a dialog on the person's screen -------------------------------------------------
// The copies keep the released bundle identifier (Squirrel checks the update against the app's designated requirement)
// and register with LaunchServices when they run. Left there, an unnotarized, modified copy (the fixture, the relaunch
// copy) can be picked for anything that opens Shenzhen 3D, and Gatekeeper shows "is damaged and can't be opened" on the
// person's screen. So each copy is unregistered as soon as it has stopped (nodialogs.py), and the unified log must show
// no Gatekeeper prompt (syspolicyd, CoreServicesUIAgent) during the run.
const NODIALOGS = path.join(path.dirname(fileURLToPath(import.meta.url)), "nodialogs.py");
const startedAt = Date.now() / 1000;
const forget = () => {
  const r = spawnSync("python3", ["-I", NODIALOGS, "unregister", ...owned], { encoding: "utf8" });
  return { left: r.status !== 0, output: `${r.stdout ?? ""}${r.stderr ?? ""}${r.error ? String(r.error) : ""}`.trim() };
};
const gatekeeperPrompts = () => {
  const r = spawnSync("python3", ["-I", NODIALOGS, "prompts", String(startedAt), String(Date.now() / 1000)], { encoding: "utf8" });
  return { found: r.status !== 0, output: `${r.stdout ?? ""}${r.stderr ?? ""}`.trim() };
};
spawnSync("python3", ["-I", NODIALOGS, "stale"], { encoding: "utf8" }); // copies of earlier runs
const already = sweep(owned, { kill: false });
if (already.left) throw Error(`something already runs from this run's copies:\n${already.output}`);
const install = path.join(work, "install"), profile = path.join(work, "profile"), cache = path.join(work, "updater-cache");
for (const d of [install, profile, cache]) fs.mkdirSync(d);
// A certificate for the local GitHub copy, trusted only by the updater's session in this run.
const TLS = path.join(work, "tls");
fs.mkdirSync(TLS);
execFileSync("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", path.join(TLS, "key.pem"),
  "-out", path.join(TLS, "cert.pem"), "-days", "2", "-subj", "/CN=api.github.com", "-addext",
  "subjectAltName=DNS:api.github.com,DNS:github.com,DNS:release-assets.githubusercontent.com,DNS:objects.githubusercontent.com"],
  { stdio: "pipe" });
const app = path.join(install, "Shenzhen 3D.app");
execFileSync("ditto", [fixtureSrc, app]);
const oldVersion = plist(app).CFBundleShortVersionString;

// ---- The new release as GitHub lists it --------------------------------------------------------------------------
const files = fs.readdirSync(artifacts).filter((f) =>
  /^(latest-mac\.yml|build-info\.json|Shenzhen-3D-.*\.(zip|dmg)(\.blockmap)?)$/.test(f));
const yml = fs.readFileSync(path.join(artifacts, "latest-mac.yml"), "utf8");
const newVersion = /^version: (.+)$/m.exec(yml)[1].trim();
const tag = `preview-${newVersion}`;
const releases = JSON.parse(fs.readFileSync(shape, "utf8")).filter((r) => !r.draft);
const template = releases.find((r) => r.tag_name === "preview-0.1.9") ?? releases[0];
let assetId = 880000, releaseId = 770000;
const assetFiles = new Map();
// A release of `version` on `releaseOwner`'s repository whose assets are `paths` (name -> file).
const makeRelease = (releaseOwner, version, paths, body) => {
  const releaseTag = `preview-${version}`;
  const releaseAssets = [...paths].map(([name, file]) => {
    const assetUrl = `https://api.github.com/repos/${releaseOwner}/shenzhen-3D/releases/assets/${++assetId}`;
    assetFiles.set(String(assetId), file);
    return { ...template.assets[0], id: assetId, name, url: assetUrl, size: fs.statSync(file).size,
      digest: "sha256:" + sha(file), browser_download_url: `https://github.com/${releaseOwner}/shenzhen-3D/releases/download/${releaseTag}/${name}`,
      state: "uploaded", download_count: 0 };
  });
  return { ...template, id: ++releaseId, tag_name: releaseTag, name: `Shenzhen 3D ${version}`, draft: false,
    prerelease: true, body, assets: releaseAssets, created_at: new Date().toISOString(), published_at: new Date().toISOString() };
};
const newRelease = makeRelease(owner, newVersion, files.map((f) => [f, path.join(artifacts, f)]), fs.readFileSync(notes, "utf8"));
// What each owner's repository lists. The new build's own channel, when it is another owner's, lists the same
// build as its release, and the newer one (--next-app) above it.
const listings = new Map([[owner, [newRelease, ...releases]]]);
let nextRelease, nextVersion, nextZip;
if (nextApp) {
  // The newer build as electron-builder publishes it: a ZIP of "Shenzhen 3D.app" and latest-mac.yml naming it.
  nextVersion = plist(nextApp).CFBundleShortVersionString;
  const nextDir = path.join(work, "next-release"), stage = path.join(work, "next-stage");
  fs.mkdirSync(nextDir);
  fs.mkdirSync(stage);
  execFileSync("ditto", [nextApp, path.join(stage, "Shenzhen 3D.app")]);
  const zipName = `Shenzhen-3D-${nextVersion}-Apple-Silicon.zip`;
  nextZip = path.join(nextDir, zipName);
  execFileSync("ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", path.join(stage, "Shenzhen 3D.app"), nextZip]);
  const zipSha = sha(nextZip, "sha512", "base64"), size = fs.statSync(nextZip).size;
  fs.writeFileSync(path.join(nextDir, "latest-mac.yml"), `version: ${nextVersion}\nfiles:\n  - url: ${zipName}\n    sha512: ${zipSha}\n` +
    `    size: ${size}\npath: ${zipName}\nsha512: ${zipSha}\nreleaseDate: '${new Date().toISOString()}'\n`);
  nextRelease = makeRelease(expectOwner, nextVersion, [["latest-mac.yml", path.join(nextDir, "latest-mac.yml")], [zipName, nextZip]], "");
}

// ---- The local GitHub: HTTPS (via the proxy) and plain HTTP (global fetch) ---------------------------------------
function handle(req, res, scheme) {
  const url = new URL(req.url, `${scheme}://${req.headers.host}`);
  const auth = req.headers.authorization;
  result.requests.push({ host: req.headers.host, path: url.pathname + url.search, accept: req.headers.accept,
    authorization: auth ? auth.split(" ")[0] + " (present)" : null });
  save();
  const host = req.headers.host.replace(/:\d+$/, "");
  const m = /^\/repos\/([^/]+)\/shenzhen-3D\/releases(?:\/assets\/(\d+))?$/.exec(url.pathname);
  if ((host === "api.github.com" || host.startsWith("127.0.0.1")) && m && listings.has(m[1])) {
    if (!m[2]) {
      const per = Number(url.searchParams.get("per_page") || 30);
      res.writeHead(200, { "content-type": "application/json; charset=utf-8" });
      return res.end(JSON.stringify(listings.get(m[1]).slice(0, per)));
    }
    if (assetFiles.has(m[2])) {
      res.writeHead(302, { location: `https://release-assets.githubusercontent.com/github-production-release-asset/1/${m[2]}?sp=r&sv=2018-11-09` });
      return res.end();
    }
  }
  const asset = host === "release-assets.githubusercontent.com" &&
    /^\/github-production-release-asset\/1\/(\d+)$/.exec(url.pathname);
  if (asset && assetFiles.has(asset[1])) {
    const file = assetFiles.get(asset[1]);
    res.writeHead(200, { "content-type": "application/octet-stream", "content-length": fs.statSync(file).size });
    return fs.createReadStream(file).pipe(res);
  }
  res.writeHead(404, { "content-type": "application/json" });
  res.end(JSON.stringify({ message: "Not Found" }));
}
const tlsServer = https.createServer({ key: fs.readFileSync(path.join(TLS, "key.pem")), cert: fs.readFileSync(path.join(TLS, "cert.pem")) },
  (req, res) => handle(req, res, "https"));
const plainServer = http.createServer((req, res) => handle(req, res, "http"));
const proxy = http.createServer((req, res) => { res.writeHead(405); res.end(); });
proxy.on("connect", (req, socket, head) => {
  result.requests.push({ connect: req.url });
  const upstream = net.connect(tlsServer.address().port, "127.0.0.1", () => {
    socket.write("HTTP/1.1 200 Connection Established\r\n\r\n");
    upstream.write(head);
    upstream.pipe(socket);
    socket.pipe(upstream);
  });
  upstream.on("error", () => socket.destroy());
  socket.on("error", () => upstream.destroy());
});
if (!live) await Promise.all([tlsServer, plainServer, proxy].map((s) => new Promise((r) => s.listen(0, "127.0.0.1", r))));
const ports = live ? null : { tls: tlsServer.address().port, plain: plainServer.address().port, proxy: proxy.address().port };

// ---- Squirrel's native state, kept in the work directory --------------------------------------------------------
// The test copies run with CFFIXED_USER_HOME in the work directory, so Squirrel's caches and ShipIt state (and the
// app's own native caches and defaults) are there, apart from any Shenzhen 3D the person is running. ShipIt itself
// runs as a launchd job named after the bundle identifier, and its preferences are the real user's.
const library = path.join(os.homedir(), "Library");
const home = path.join(work, "home");
const nativeCaches = [id, job].map((name) => path.join(home, "Library/Caches", name));
const shipItPrefs = () => [
  ...fs.readdirSync(path.join(library, "Preferences")).filter((x) => x === job + ".plist").map((x) => path.join(library, "Preferences", x)),
  ...fs.readdirSync(path.join(library, "Preferences/ByHost")).filter((x) => x.startsWith(job + ".")).map((x) => path.join(library, "Preferences/ByHost", x)),
];
const shipItJob = () => { try { return execFileSync("launchctl", ["print", `gui/${process.getuid()}/${job}`], { encoding: "utf8", stdio: "pipe" }); } catch { return null; } };
const launchctlHas = () => shipItJob() !== null;
const shipItRunning = () => /^\tstate = running$/m.test(shipItJob() ?? "");
// Ours when its program is the ShipIt of a copy in the work directory or of the relaunch copy.
const real = (p) => { try { return fs.realpathSync(p); } catch { return p; } };
const shipItOurs = () => {
  const program = real(/^\tprogram = (.*)$/m.exec(shipItJob() ?? "")?.[1] ?? "");
  return [work, relaunchPrepared].some((dir) => dir && program.startsWith(real(dir) + path.sep));
};
// A finished job of another copy (registrations stay after ShipIt exits) is replaced by Squirrel and harmless; a
// running one is an install in progress.
if (shipItRunning()) throw Error("a ShipIt job is running");
if (launchctlHas()) result.earlierShipItJob = /^\tprogram = (.*)$/m.exec(shipItJob())?.[1];
// Preferences ShipIt left empty after another copy's install are kept as they are; any with contents stop the run.
const prefKeys = (p) => Object.keys(JSON.parse(execFileSync("plutil", ["-convert", "json", "-o", "-", p], { encoding: "utf8" })));
const prefsBefore = new Set(shipItPrefs());
if ([...prefsBefore].some((p) => prefKeys(p).length)) throw Error("ShipIt preferences already exist");

const env = { ...process.env };
for (const k of ["GH_TOKEN", "GITHUB_TOKEN", "SHENZHEN_3D_DEV_URL", "ELECTRON_RUN_AS_NODE", "NODE_OPTIONS"]) delete env[k];
env.CFFIXED_USER_HOME = home;
const launch = (target) => electron.launch({ executablePath: path.join(target, "Contents/MacOS/Shenzhen 3D"),
  args: [`--user-data-dir=${profile}`, "--use-mock-keychain"], env, timeout: 60_000 });

async function overrides(application) {
  await application.evaluate(async ({ app, dialog, session, safeStorage }, { ports, cache }) => {
    const req = process.getBuiltinModule("module").createRequire(app.getAppPath() + "/package.json");
    // GitHub access check (global fetch) -> the local copy over plain HTTP.
    const realFetch = globalThis.fetch;
    if (ports) globalThis.fetch = (input, init) => {
      const url = new URL(typeof input === "string" || input instanceof URL ? input : input.url);
      if (url.hostname === "api.github.com") { url.protocol = "http:"; url.host = `127.0.0.1:${ports.plain}`; }
      return realFetch(url, init);
    };
    // No keychain: an in-memory, reversible stand-in.
    safeStorage.isEncryptionAvailable = () => true;
    safeStorage.encryptString = (s) => Buffer.from("szut:" + s, "utf8");
    safeStorage.decryptString = (b) => { const s = Buffer.from(b).toString("utf8"); if (!s.startsWith("szut:")) throw Error("not ours"); return s.slice(5); };
    // The updater's own session: through the proxy to the local copy, whose certificate it trusts.
    if (ports) {
      const updaterSession = session.fromPartition("electron-updater", { cache: false });
      await updaterSession.setProxy({ proxyRules: `http://127.0.0.1:${ports.proxy}` });
      const hosts = ["api.github.com", "release-assets.githubusercontent.com", "github.com", "objects.githubusercontent.com"];
      updaterSession.setCertificateVerifyProc((r, cb) => cb(hosts.includes(r.hostname) ? 0 : -2));
    }
    const { ElectronAppAdapter } = req("electron-updater/out/ElectronAppAdapter");
    Object.defineProperty(ElectronAppAdapter.prototype, "baseCachePath", { get: () => cache, configurable: true });
    const { MacUpdater } = req("electron-updater");
    const original = MacUpdater.prototype.quitAndInstall;
    MacUpdater.prototype.quitAndInstall = function (...args) { this.autoRunAppAfterInstall = false; return original.apply(this, args); };
    globalThis.__szutDialogs = [];
    dialog.showMessageBox = async (...args) => {
      const options = args[args.length - 1];
      globalThis.__szutDialogs.push({ title: options.title, message: options.message, buttons: options.buttons });
      return { response: options.title === "Restart to install update?" ? 0 : options.cancelId ?? 0, checkboxChecked: false };
    };
  }, { ports, cache });
}
const anyVisible = (application) => application.evaluate(({ BaseWindow }) => BaseWindow.getAllWindows().some((w) => w.isVisible()));

let application, installed = false, installStarted = false;
const shipItIdle = async () => { for (let i = 0; i < 60 && shipItRunning(); i++) await sleep(1000); return !shipItRunning(); };
// Waits until the bundle at `target` is `version` with the archive of the app in `zipFile`.
async function replacedBy(target, version, zipFile, into) {
  fs.mkdirSync(into);
  execFileSync("ditto", ["-x", "-k", zipFile, into]);
  const unpacked = fs.readdirSync(into).find((n) => n.endsWith(".app"));
  const want = sha(path.join(into, unpacked, "Contents/Resources/app.asar"));
  for (const deadline = Date.now() + 180_000; Date.now() < deadline; await sleep(1000)) {
    try {
      if (plist(target).CFBundleShortVersionString === version && sha(path.join(target, "Contents/Resources/app.asar")) === want) return true;
    } catch {}
  }
  return false;
}
try {
  for (const dir of nativeCaches) fs.mkdirSync(dir, { recursive: true });
  // ---- 1. the released app finds, downloads and installs the new release ----
  application = await launch(app);
  const page = await application.firstWindow();
  await overrides(application);
  check("the released app runs hidden", !(await anyVisible(application)), { version: await application.evaluate(({ app }) => app.getVersion()) });
  const initial = await page.evaluate(() => window.shenzhenUpdates.getState());
  check(`released ${oldVersion} reads updates from ${owner}`, initial.repository === owner && initial.supported, initial);
  await page.evaluate(() => window.shenzhenUpdates.configure({ automatic: false, prereleases: true }));
  if (initial.status === "needs-auth" || /Connect GitHub/.test(initial.message || "")) {
    // Live: the GitHub CLI login, as a person would connect; the credential never passes through this script.
    const connected = live ? await page.evaluate(() => window.shenzhenUpdates.useGitHubCLI())
      : await page.evaluate((t) => window.shenzhenUpdates.connect(t), FAKE_TOKEN);
    check("it needs GitHub access connected first (by design); connecting succeeds", connected.connected, connected);
  }
  const available = await page.evaluate(() => window.shenzhenUpdates.check());
  check(`it offers ${newVersion}`, available.status === "available" && available.availableVersion === newVersion, available);
  const apiRequests = result.requests.filter((r) => r.path?.startsWith(`/repos/${owner}/shenzhen-3D/releases`));
  if (!live) check("its release-list requests", apiRequests.length > 0, apiRequests.slice(0, 6));
  const ready = await page.evaluate(() => window.shenzhenUpdates.download());
  check("it downloads the update", ready.status === "ready", ready);
  const zip = files.find((f) => f.endsWith(".zip"));
  const zipHash = sha(path.join(artifacts, zip), "sha512", "base64");
  const downloaded = [];
  const scan = (d) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) { const p = path.join(d, e.name); if (e.isDirectory()) scan(p); else if (p.endsWith(".zip")) downloaded.push(p); } };
  scan(cache);
  check("the downloaded ZIP is the release's (SHA-512)", downloaded.some((p) => sha(p, "sha512", "base64") === zipHash), downloaded);
  const assetReqs = result.requests.filter((r) => r.host?.startsWith("release-assets"));
  if (!live) check("assets came through GitHub's redirect", assetReqs.length > 0, assetReqs.map((r) => r.path));
  installStarted = true;
  const closed = application.waitForEvent("close", { timeout: 180_000 });
  await page.evaluate(() => window.shenzhenUpdates.install()).catch(() => {});
  await closed;
  application = undefined;
  forget();
  installed = await replacedBy(app, newVersion, path.join(artifacts, zip), path.join(work, "new-app"));
  check(`Squirrel replaced the app with ${newVersion}`, installed);
  // The installed bundle is now the release itself, without a test identity: reopened, it would take the profile and
  // single-instance lock of the Shenzhen 3D installed on this Mac. Squirrel must not reopen it.
  await shipItIdle();
  await sleep(3000);
  const reopened = sweep([app]);
  forget(); // LaunchServices registers the installed bundle a few seconds after Squirrel moves it into place
  check("the installed release was not reopened", !reopened.left, reopened.output || undefined);
  const verify = (args) => { try { execFileSync(args[0], args.slice(1), { stdio: "pipe" }); return true; } catch { return false; } };
  check("codesign --verify --deep --strict", verify(["codesign", "--verify", "--deep", "--strict", app]));
  check("stapled notarization ticket", verify(["xcrun", "stapler", "validate", app]));
  check("Gatekeeper accepts it", verify(["spctl", "--assess", "--type", "execute", app]));
  const pkg = JSON.parse(asar.extractFile(path.join(app, "Contents/Resources/app.asar"), "package.json").toString());
  const feed = fs.readFileSync(path.join(app, "Contents/Resources/app-update.yml"), "utf8");
  check(`the new build reads ${expectOwner}'s releases, ${expectAccess}`, pkg.releaseOwner === expectOwner && pkg.releaseAccess === expectAccess &&
    feed.includes(`owner: ${expectOwner}`) && feed.includes(`private: ${expectAccess === "private"}`), { releaseOwner: pkg.releaseOwner, releaseAccess: pkg.releaseAccess, feed });
  // ---- 2. the new version starts (a hidden copy) and checks its own feed ----
  if (relaunchPrepared) {
    fs.writeFileSync(path.join(profile, "friends.json"), JSON.stringify({ enabled: false })); // no helper in the test
    const saved = JSON.parse(fs.readFileSync(path.join(profile, "updates.json"), "utf8"));
    check("the released app had saved its GitHub access (encrypted)", typeof saved.encryptedToken === "string" || expectAccess === "public", Object.keys(saved));
    const before = result.requests.length;
    if (expectOwner !== owner) {
      // The new build's own channel: the same build as its release, and the newer one above it.
      const own = makeRelease(expectOwner, newVersion, files.map((f) => [f, path.join(artifacts, f)]), "");
      listings.set(expectOwner, nextRelease ? [nextRelease, own] : [own]);
    }
    application = await launch(relaunchPrepared);
    const p2 = await application.firstWindow();
    await overrides(application);
    const state = await p2.evaluate(() => window.shenzhenUpdates.getState());
    check(`the new version runs (${newVersion}) for ${expectOwner}, ${expectAccess}`, state.version === newVersion && state.repository === expectOwner && state.access === expectAccess, state);
    const after = await p2.evaluate(() => window.shenzhenUpdates.check());
    const reqs = result.requests.slice(before).filter((r) => r.path?.includes("/releases"));
    if (expectAccess === "public") {
      const kept = JSON.parse(fs.readFileSync(path.join(profile, "updates.json"), "utf8"));
      check("public: the saved GitHub access from the old build is dropped", !("encryptedToken" in kept), Object.keys(kept));
      if (!live) check(`public: it reads only ${expectOwner}'s releases, without any credential`,
        reqs.length > 0 && reqs.every((r) => !r.authorization && r.path.startsWith(`/repos/${expectOwner}/shenzhen-3D/`)), reqs);
      if (!nextRelease)
        check("public: it finds itself current", after.status === "idle" && !after.availableVersion && after.connected === false, after);
      else {
        check(`public: it offers ${nextVersion} from ${expectOwner}`, after.status === "available" && after.availableVersion === nextVersion, after);
        const ready2 = await p2.evaluate(() => window.shenzhenUpdates.download());
        check(`public: it downloads ${nextVersion}`, ready2.status === "ready", ready2);
        check("ShipIt from the first install has finished", await shipItIdle());
        const closed2 = application.waitForEvent("close", { timeout: 180_000 });
        await p2.evaluate(() => window.shenzhenUpdates.install()).catch(() => {});
        await closed2;
        application = undefined;
        forget();
        const replaced = await replacedBy(relaunchPrepared, nextVersion, nextZip, path.join(work, "next-unpacked"));
        check(`Squirrel replaced the new version with ${nextVersion}`, replaced);
        check("codesign --verify --deep --strict (next)", verify(["codesign", "--verify", "--deep", "--strict", relaunchPrepared]));
        const nextPkg = JSON.parse(asar.extractFile(path.join(relaunchPrepared, "Contents/Resources/app.asar"), "package.json").toString());
        check(`the next build reads ${expectOwner}'s releases, public`, nextPkg.releaseOwner === expectOwner && nextPkg.releaseAccess === "public" && nextPkg.version === nextVersion,
          { releaseOwner: nextPkg.releaseOwner, releaseAccess: nextPkg.releaseAccess, version: nextPkg.version });
      }
    } else {
      // Saved access is decrypted while the first state is read; the check waits for it.
      check("private: it keeps the connected access and checks with it", after.connected && after.status !== "error" && reqs.length > 0 && reqs.every((r) => r.authorization), { after, reqs });
    }
    await application?.close();
    application = undefined;
    forget();
  }
  result.success = result.checks.every((c) => c.ok);
} catch (error) {
  check("no error", false, String(error?.stack || error));
  result.success = false;
} finally {
  if (application && (!installStarted || installed)) await application.close().catch(() => {});
  // The stand-in safeStorage keeps the connected credential readable; never leave it in the work directory.
  try {
    const saved = path.join(profile, "updates.json");
    const data = JSON.parse(fs.readFileSync(saved, "utf8"));
    if ("encryptedToken" in data) { delete data.encryptedToken; fs.writeFileSync(saved, JSON.stringify(data)); }
  } catch {}
  for (const s of [tlsServer, plainServer, proxy]) if (s.listening) s.close();
  if (!installStarted || installed) {
    await shipItIdle(); // ShipIt finishing after the install
    if (launchctlHas() && shipItOurs()) { try { execFileSync("launchctl", ["bootout", `gui/${process.getuid()}/${job}`], { stdio: "pipe" }); } catch {} }
    // An empty one that was not there before the run is ShipIt's from this run.
    for (const p of shipItPrefs()) {
      const keys = prefKeys(p);
      if (keys.length === 0 && !prefsBefore.has(p)) fs.unlinkSync(p);
      else if (keys.length) result.shipItPrefsLeft = (result.shipItPrefsLeft || []).concat([{ p, keys }]);
    }
  }
  const left = sweep(owned, { grace: 15 });
  swept = true;
  if (left.left) {
    check("nothing this run started is still running", false, left.output);
    result.success = false;
  }
  const registered = forget();
  if (!check("no test copy stays registered with LaunchServices", !registered.left, registered.output || undefined)) result.success = false;
  const prompts = gatekeeperPrompts();
  if (!check("the unified log shows no Gatekeeper prompt (syspolicyd, CoreServicesUIAgent) during the run", !prompts.found,
    prompts.output ? prompts.output.split("\n").slice(0, 5) : undefined)) result.success = false;
  result.cleanup = { shipItJob: launchctlHas() && shipItOurs(), shipItPrefs: shipItPrefs().filter((p) => !prefsBefore.has(p)),
    leftRunning: left.left ? left.output : null };
  save();
  process.exit(result.success ? 0 : 1);
}
