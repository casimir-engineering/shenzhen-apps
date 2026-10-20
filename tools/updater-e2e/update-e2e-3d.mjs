// update-e2e-3d.mjs: a released Shenzhen 3D (0.1.9) updates itself to the new release served by a local copy of
// GitHub, hidden, then the installed new version starts and checks its own feed. Run from apps/3d (Playwright).
//
//   node update-e2e-3d.mjs --owner=O --fixture=APP --artifacts=DIR --shape=RELEASES_JSON --notes=MD --work=DIR
//                          --expect-access=public|private [--relaunch-app=HIDDEN_COPY_OF_NEW_APP]
//
// The fixture is the released app with electron/hidden-hook.cjs loaded first and LSBackgroundOnly (prep-3d-fixture
// .mjs), signed again with the same Developer ID, so Squirrel's designated-requirement check is the release's. Test
// overrides, all in the main process: the updater's network session goes through a local proxy to the local GitHub
// copy and trusts its certificate; global fetch (the GitHub access check) goes to the same copy; safeStorage is an
// in-memory stand-in (no keychain); the install dialog answers Install; the app does not reopen itself after
// installing (Squirrel replaces the bundle at quit). Everything else, provider choice, release selection, version
// check, download, SHA-512 check and native install, is the release's own code.
import fs from "node:fs";
import fsp from "node:fs/promises";
import http from "node:http";
import https from "node:https";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";

const require = createRequire(path.join(process.cwd(), "package.json"));
const asar = require("@electron/asar");
const { _electron: electron } = require("@playwright/test");
const opt = (name) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3);
const owner = opt("owner"), fixtureSrc = opt("fixture"), artifacts = opt("artifacts"), work = opt("work");
const expectAccess = opt("expect-access"), shape = opt("shape"), notes = opt("notes");
const relaunchPrepared = opt("relaunch-app");
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
let assetId = 880000;
const assetFiles = new Map();
const assets = files.map((name) => {
  const file = path.join(artifacts, name);
  const assetUrl = `https://api.github.com/repos/${owner}/shenzhen-3D/releases/assets/${++assetId}`;
  assetFiles.set(String(assetId), file);
  return { ...template.assets[0], id: assetId, name, url: assetUrl, size: fs.statSync(file).size,
    digest: "sha256:" + sha(file), browser_download_url: `https://github.com/${owner}/shenzhen-3D/releases/download/${tag}/${name}`,
    state: "uploaded", download_count: 0 };
});
const newRelease = { ...template, id: 770001, tag_name: tag, name: `Shenzhen 3D ${newVersion}`, draft: false,
  prerelease: true, body: fs.readFileSync(notes, "utf8"), assets, created_at: new Date().toISOString(),
  published_at: new Date().toISOString() };
let listing = [newRelease, ...releases];

// ---- The local GitHub: HTTPS (via the proxy) and plain HTTP (global fetch) ---------------------------------------
function handle(req, res, scheme) {
  const url = new URL(req.url, `${scheme}://${req.headers.host}`);
  const auth = req.headers.authorization;
  result.requests.push({ host: req.headers.host, path: url.pathname + url.search, accept: req.headers.accept,
    authorization: auth ? auth.split(" ")[0] + " (present)" : null });
  save();
  const host = req.headers.host.replace(/:\d+$/, "");
  const m = /^\/repos\/([^/]+)\/shenzhen-3D\/releases(?:\/assets\/(\d+))?$/.exec(url.pathname);
  if ((host === "api.github.com" || host.startsWith("127.0.0.1")) && m && m[1] === owner) {
    if (!m[2]) {
      const per = Number(url.searchParams.get("per_page") || 30);
      res.writeHead(200, { "content-type": "application/json; charset=utf-8" });
      return res.end(JSON.stringify(listing.slice(0, per)));
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
await Promise.all([tlsServer, plainServer, proxy].map((s) => new Promise((r) => s.listen(0, "127.0.0.1", r))));
const ports = { tls: tlsServer.address().port, plain: plainServer.address().port, proxy: proxy.address().port };

// ---- Squirrel's native state, kept in the work directory --------------------------------------------------------
const library = path.join(os.homedir(), "Library");
const cacheLinks = [id, job].map((name) => ({ link: path.join(library, "Caches", name), target: path.join(work, "native-cache", name) }));
const exists = (p) => { try { fs.lstatSync(p); return true; } catch { return false; } };
const shipItPrefs = () => [
  ...fs.readdirSync(path.join(library, "Preferences")).filter((x) => x === job + ".plist").map((x) => path.join(library, "Preferences", x)),
  ...fs.readdirSync(path.join(library, "Preferences/ByHost")).filter((x) => x.startsWith(job + ".")).map((x) => path.join(library, "Preferences/ByHost", x)),
];
const launchctlHas = () => { try { execFileSync("launchctl", ["print", `gui/${process.getuid()}/${job}`], { stdio: "pipe" }); return true; } catch { return false; } };
for (const { link } of cacheLinks) if (exists(link)) throw Error("existing native updater cache: " + link);
if (launchctlHas()) throw Error("a ShipIt job already exists");
if (shipItPrefs().length) throw Error("ShipIt preferences already exist");

const env = { ...process.env };
for (const k of ["GH_TOKEN", "GITHUB_TOKEN", "SHENZHEN_3D_DEV_URL", "ELECTRON_RUN_AS_NODE", "NODE_OPTIONS"]) delete env[k];
const launch = (target) => electron.launch({ executablePath: path.join(target, "Contents/MacOS/Shenzhen 3D"),
  args: [`--user-data-dir=${profile}`, "--use-mock-keychain"], env, timeout: 60_000 });

async function overrides(application) {
  await application.evaluate(async ({ app, dialog, session, safeStorage }, { ports, cache }) => {
    const req = process.getBuiltinModule("module").createRequire(app.getAppPath() + "/package.json");
    // GitHub access check (global fetch) -> the local copy over plain HTTP.
    const realFetch = globalThis.fetch;
    globalThis.fetch = (input, init) => {
      const url = new URL(typeof input === "string" || input instanceof URL ? input : input.url);
      if (url.hostname === "api.github.com") { url.protocol = "http:"; url.host = `127.0.0.1:${ports.plain}`; }
      return realFetch(url, init);
    };
    // No keychain: an in-memory, reversible stand-in.
    safeStorage.isEncryptionAvailable = () => true;
    safeStorage.encryptString = (s) => Buffer.from("szut:" + s, "utf8");
    safeStorage.decryptString = (b) => { const s = Buffer.from(b).toString("utf8"); if (!s.startsWith("szut:")) throw Error("not ours"); return s.slice(5); };
    // The updater's own session: through the proxy to the local copy, whose certificate it trusts.
    const updaterSession = session.fromPartition("electron-updater", { cache: false });
    await updaterSession.setProxy({ proxyRules: `http://127.0.0.1:${ports.proxy}` });
    const hosts = ["api.github.com", "release-assets.githubusercontent.com", "github.com", "objects.githubusercontent.com"];
    updaterSession.setCertificateVerifyProc((r, cb) => cb(hosts.includes(r.hostname) ? 0 : -2));
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
try {
  for (const { link, target } of cacheLinks) { fs.mkdirSync(target, { recursive: true }); fs.symlinkSync(target, link, "dir"); }
  // ---- 1. the released app finds, downloads and installs the new release ----
  application = await launch(app);
  const page = await application.firstWindow();
  await overrides(application);
  check("the released app runs hidden", !(await anyVisible(application)), { version: await application.evaluate(({ app }) => app.getVersion()) });
  const initial = await page.evaluate(() => window.shenzhenUpdates.getState());
  check(`released ${oldVersion} reads updates from ${owner}`, initial.repository === owner && initial.supported, initial);
  await page.evaluate(() => window.shenzhenUpdates.configure({ automatic: false, prereleases: true }));
  if (initial.status === "needs-auth" || /Connect GitHub/.test(initial.message || "")) {
    const connected = await page.evaluate((t) => window.shenzhenUpdates.connect(t), FAKE_TOKEN);
    check("it needs GitHub access connected first (by design); connecting succeeds", connected.connected, connected);
  }
  const available = await page.evaluate(() => window.shenzhenUpdates.check());
  check(`it offers ${newVersion}`, available.status === "available" && available.availableVersion === newVersion, available);
  const apiRequests = result.requests.filter((r) => r.path?.startsWith(`/repos/${owner}/shenzhen-3D/releases`));
  check("its release-list requests", apiRequests.length > 0, apiRequests.slice(0, 6));
  const ready = await page.evaluate(() => window.shenzhenUpdates.download());
  check("it downloads the update", ready.status === "ready", ready);
  const zip = files.find((f) => f.endsWith(".zip"));
  const zipHash = sha(path.join(artifacts, zip), "sha512", "base64");
  const downloaded = [];
  const scan = (d) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) { const p = path.join(d, e.name); if (e.isDirectory()) scan(p); else if (p.endsWith(".zip")) downloaded.push(p); } };
  scan(cache);
  check("the downloaded ZIP is the release's (SHA-512)", downloaded.some((p) => sha(p, "sha512", "base64") === zipHash), downloaded);
  const assetReqs = result.requests.filter((r) => r.host?.startsWith("release-assets"));
  check("assets came through GitHub's redirect", assetReqs.length > 0, assetReqs.map((r) => r.path));
  installStarted = true;
  const closed = application.waitForEvent("close", { timeout: 180_000 });
  await page.evaluate(() => window.shenzhenUpdates.install()).catch(() => {});
  await closed;
  application = undefined;
  const newApp = path.join(work, "new-app");
  fs.mkdirSync(newApp);
  execFileSync("ditto", ["-x", "-k", path.join(artifacts, zip), newApp]);
  const wantAsar = sha(path.join(newApp, "Shenzhen 3D.app/Contents/Resources/app.asar"));
  const deadline = Date.now() + 180_000;
  while (Date.now() < deadline) {
    try {
      if (plist(app).CFBundleShortVersionString === newVersion && sha(path.join(app, "Contents/Resources/app.asar")) === wantAsar) { installed = true; break; }
    } catch {}
    await sleep(1000);
  }
  check(`Squirrel replaced the app with ${newVersion}`, installed);
  const verify = (args) => { try { execFileSync(args[0], args.slice(1), { stdio: "pipe" }); return true; } catch { return false; } };
  check("codesign --verify --deep --strict", verify(["codesign", "--verify", "--deep", "--strict", app]));
  check("stapled notarization ticket", verify(["xcrun", "stapler", "validate", app]));
  check("Gatekeeper accepts it", verify(["spctl", "--assess", "--type", "execute", app]));
  const pkg = JSON.parse(asar.extractFile(path.join(app, "Contents/Resources/app.asar"), "package.json").toString());
  const feed = fs.readFileSync(path.join(app, "Contents/Resources/app-update.yml"), "utf8");
  check(`the new build reads ${owner}'s releases, ${expectAccess}`, pkg.releaseOwner === owner && pkg.releaseAccess === expectAccess &&
    feed.includes(`owner: ${owner}`) && feed.includes(`private: ${expectAccess === "private"}`), { releaseOwner: pkg.releaseOwner, releaseAccess: pkg.releaseAccess, feed });
  // ---- 2. the new version starts (a hidden copy) and checks its own feed ----
  if (relaunchPrepared) {
    fs.writeFileSync(path.join(profile, "friends.json"), JSON.stringify({ enabled: false })); // no helper in the test
    const saved = JSON.parse(fs.readFileSync(path.join(profile, "updates.json"), "utf8"));
    check("the released app had saved its GitHub access (encrypted)", typeof saved.encryptedToken === "string" || expectAccess === "public", Object.keys(saved));
    const before = result.requests.length;
    listing = [newRelease, ...releases];
    application = await launch(relaunchPrepared);
    const p2 = await application.firstWindow();
    await overrides(application);
    const state = await p2.evaluate(() => window.shenzhenUpdates.getState());
    check(`the new version runs (${newVersion}) for ${owner}, ${expectAccess}`, state.version === newVersion && state.repository === owner && state.access === expectAccess, state);
    const after = await p2.evaluate(() => window.shenzhenUpdates.check());
    const reqs = result.requests.slice(before).filter((r) => r.path?.includes("/releases"));
    if (expectAccess === "public") {
      check("public: it checks without any credential and finds itself current", after.status !== "error" && reqs.length > 0 && reqs.every((r) => !r.authorization), { after, reqs });
      const kept = JSON.parse(fs.readFileSync(path.join(profile, "updates.json"), "utf8"));
      check("public: the saved GitHub access from the old build is dropped", !("encryptedToken" in kept), Object.keys(kept));
    } else {
      // Saved access is decrypted while the first state is read; the check waits for it.
      check("private: it keeps the connected access and checks with it", after.connected && after.status !== "error" && reqs.length > 0 && reqs.every((r) => r.authorization), { after, reqs });
    }
    await application.close();
    application = undefined;
  }
  result.success = result.checks.every((c) => c.ok);
} catch (error) {
  check("no error", false, String(error?.stack || error));
  result.success = false;
} finally {
  if (application && (!installStarted || installed)) await application.close().catch(() => {});
  for (const s of [tlsServer, plainServer, proxy]) s.close();
  if (!installStarted || installed) {
    for (let i = 0; i < 30 && launchctlHas(); i++) await sleep(1000); // ShipIt finishing after the install
    if (launchctlHas()) { try { execFileSync("launchctl", ["bootout", `gui/${process.getuid()}/${job}`], { stdio: "pipe" }); } catch {} }
    for (const { link, target } of cacheLinks) if (exists(link) && fs.lstatSync(link).isSymbolicLink() && fs.readlinkSync(link) === target) fs.unlinkSync(link);
    // None existed before the run (checked above): an empty one is ShipIt's from this run.
    for (const p of shipItPrefs()) {
      const contents = JSON.parse(execFileSync("plutil", ["-convert", "json", "-o", "-", p], { encoding: "utf8" }));
      if (Object.keys(contents).length === 0) fs.unlinkSync(p);
      else result.shipItPrefsLeft = (result.shipItPrefsLeft || []).concat([{ p, keys: Object.keys(contents) }]);
    }
  }
  result.cleanup = { cacheLinks: cacheLinks.map(({ link }) => exists(link)), shipItJob: launchctlHas(), shipItPrefs: shipItPrefs() };
  save();
  process.exit(result.success ? 0 : 1);
}
