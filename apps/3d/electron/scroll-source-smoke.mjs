import { _electron as electron, expect } from "@playwright/test";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { buildNativeScroll } from "./build-native-scroll.mjs";
import { nativeCodeHash, verifyRuntimeArchive } from "./package-mac.mjs";

const argument = (name) =>
  process.argv
    .find((value) => value.startsWith(name + "="))
    ?.slice(name.length + 1);
const root = process.cwd();
const packagedApp = argument("--app")
  ? path.resolve(argument("--app"))
  : undefined;
const reportPath = path.resolve(
  argument("--report") ??
    "artifacts/wheel-source-audit/native-scroll-smoke.json",
);
const directory = await fs.mkdtemp(
  path.join(os.tmpdir(), "shenzhen-scroll-source-"),
);
const report = {
  passed: false,
  scope: "addon-and-ipc",
  description:
    "Isolated Electron fixture using the production native loader, addon and preload; synthetic clock inspection and pure ring tests. No physical device or end-to-end AppKit event delivery verification.",
  packaged: !!packagedApp,
  nativeEventDeliveryVerified: false,
  physicalInputVerified: false,
  validationLimit:
    "Synthetic app-local scroll injection did not reach trusted Chromium wheel events; native event delivery is not asserted.",
  checks: [],
  verified: {},
};
let app;
try {
  if (process.platform !== "darwin")
    throw Error("Native scroll smoke requires macOS");
  let binary, runtimeBinary, loader, preload;
  if (packagedApp) {
    const resources = path.join(packagedApp, "Contents/Resources");
    const archive = path.join(resources, "app.asar");
    // build-info is normally inside ASAR, read it without executing any packaged code.
    const { createRequire } = await import("node:module");
    const asar = createRequire(import.meta.url)("@electron/asar");
    const manifest = JSON.parse(asar.extractFile(archive, "build-info.json"));
    const integrity = verifyRuntimeArchive(archive, manifest);
    report.version = manifest.version;
    report.releaseOwner = manifest.releaseOwner;
    report.sourceCommit = manifest.sourceCommit;
    expect(integrity.nativeRuntimeFileCount).toBe(1);
    binary = path.join(
      archive + ".unpacked",
      "electron/native/scroll-source.node",
    );
    // Match the loader's ASAR alias to reuse the existing native module.
    // The unpacked alias would initialize the same dylib a second time.
    runtimeBinary = path.join(archive, "electron/native/scroll-source.node");
    loader = path.join(archive, "electron/scroll-source.cjs");
    preload = path.join(archive, "electron/preload.cjs");
    execFileSync("codesign", ["--verify", "--strict", binary], {
      stdio: "pipe",
    });
    report.packagedIntegrity = integrity;
    report.checks.push({
      name: "packaged-native-provenance-and-signature",
      passed: true,
    });
  } else {
    binary = await buildNativeScroll();
    runtimeBinary = binary;
    loader = path.join(root, "electron/scroll-source.cjs");
    preload = path.join(root, "electron/preload.cjs");
  }
  report.addonCodeHash = nativeCodeHash(await fs.readFile(binary));
  const headers = [
    process.env.SHENZHEN_NODE_HEADERS,
    path.join(
      os.homedir(),
      "Library/Caches/node-gyp",
      process.versions.node,
      "include/node",
    ),
    "/opt/homebrew/include/node",
    "/usr/local/include/node",
  ].filter(Boolean);
  let include;
  for (const candidate of headers) {
    try {
      await fs.access(path.join(candidate, "node_api.h"));
      include = candidate;
      break;
    } catch {}
  }
  if (!include)
    throw Error("N-API headers unavailable for test-only clock probe");
  const probe = path.join(directory, "probe.node");
  execFileSync(
    "xcrun",
    [
      "clang++",
      "-std=c++17",
      "-fobjc-arc",
      "-fblocks",
      "-dynamiclib",
      "-undefined",
      "dynamic_lookup",
      "-DNAPI_VERSION=8",
      "-DNODE_GYP_MODULE_NAME=scroll_probe",
      "-I",
      include,
      "-framework",
      "AppKit",
      path.join(root, "electron/native/scroll-source-probe.mm"),
      "-o",
      probe,
    ],
    { stdio: "pipe" },
  );
  const unit = path.join(directory, "ring-test");
  execFileSync(
    "xcrun",
    [
      "clang++",
      "-std=c++17",
      path.join(root, "electron/native/scroll-source-core.test.cc"),
      "-o",
      unit,
    ],
    { stdio: "pipe" },
  );
  execFileSync(unit);
  report.verified.ringClassification = true;
  report.verified.windowTimestampIsolation = true;
  report.checks.push({
    name: "ring-classification-momentum-device-switch-window-and-time-isolation",
    passed: true,
  });
  const html = path.join(directory, "index.html"),
    main = path.join(directory, "main.cjs");
  await fs.writeFile(
    html,
    "<!doctype html><body>Isolated native scroll bridge fixture</body>",
  );
  await fs.writeFile(
    main,
    `const{app,BrowserWindow,ipcMain}=require('electron');
    app.whenReady().then(()=>{
      const trusted=url=>url===${JSON.stringify(new URL("file://" + html).href)};
      const query=require(${JSON.stringify(loader)}).createScrollSource({app:${packagedApp ? "{isPackaged:true}" : "app"},windows:BrowserWindow,trusted});
      global.rotationRequests=[];
      ipcMain.on('shenzhen-scroll-source',(e,t)=>{e.returnValue=e.senderFrame===e.sender.mainFrame&&trusted(e.senderFrame.url)?query(e.sender,t):null});
      ipcMain.on('shenzhen-rotate-subscribe',(e,enabled)=>{
        if(e.senderFrame===e.sender.mainFrame&&trusted(e.senderFrame.url))global.rotationRequests.push({enabled,accepted:query.subscribeRotate(e.sender,enabled)});
      });
      app.on('will-quit',()=>query.dispose());
      const w=new BrowserWindow({show:false,width:500,height:400,webPreferences:{sandbox:true,contextIsolation:true,nodeIntegration:false,preload:${JSON.stringify(preload)}}});
      w.loadFile(${JSON.stringify(html)});
    });app.on('window-all-closed',()=>app.quit());`,
  );
  app = await electron.launch({
    args: [main, `--user-data-dir=${path.join(directory, "profile")}`],
  });
  const page = await app.firstWindow();
  await page.waitForFunction(() => !!window.shenzhenScroll);
  report.nativeStatus = await app.evaluate((_electron, binary) => {
    const require = process
      .getBuiltinModule("module")
      .createRequire(process.cwd() + "/package.json");
    const native = require(binary);
    return {
      started: native.start(),
      exports: Object.getOwnPropertyNames(native).sort(),
      invalidRotationDrains: [
        native.drainRotations(),
        native.drainRotations(Buffer.alloc(0)),
        native.drainRotations(Buffer.alloc(8)),
      ],
    };
  }, runtimeBinary);
  expect(report.nativeStatus.started).toBe(true);
  expect(report.nativeStatus.exports).toEqual([
    "drainRotations",
    "source",
    "start",
  ]);
  expect(report.nativeStatus.invalidRotationDrains).toEqual([[], [], []]);
  report.verified.addonLoadAndStart = true;
  report.verified.productionExports = true;
  report.checks.push({
    name: "production-addon-load-start-and-no-test-exports",
    passed: true,
  });
  const clock = await app.evaluate((_electron, probe) => {
    const require = process
      .getBuiltinModule("module")
      .createRequire(process.cwd() + "/package.json");
    return require(probe).inspect();
  }, probe);
  expect(clock.eventTimestampSeconds).toBeGreaterThan(0);
  expect(
    Math.abs(clock.eventTimestampSeconds - clock.systemUptimeSeconds),
  ).toBeLessThan(0.02);
  expect(Math.abs(clock.eventEpochMs - clock.nowEpochMs)).toBeLessThan(20);
  report.clock = clock;
  report.checks.push({
    name: "nonzero-native-event-clock-and-epoch-conversion",
    passed: true,
  });
  const guards = await page.evaluate(() => {
    const source = window.shenzhenScroll.source;
    return {
      exports: Object.keys(window.shenzhenScroll),
      results: [
        NaN,
        Infinity,
        "bad",
        null,
        {},
        Date.now() - 3000,
        Date.now() + 3000,
        performance.timeOrigin + performance.now(),
      ].map((value) => source(value)),
    };
  });
  expect(guards.exports).toEqual(["source", "subscribeRotate"]);
  expect(guards.results).toEqual(Array(8).fill(null));
  report.verified.ipcBounds = true;
  report.checks.push({
    name: "production-preload-narrow-api-and-invalid-stale-unknown-input-bounds",
    passed: true,
  });
  await page.evaluate(() => {
    window.rotationSamples = [];
    window.stopRotationSmoke = window.shenzhenScroll.subscribeRotate((sample) =>
      window.rotationSamples.push(sample),
    );
  });
  await expect
    .poll(() => app.evaluate(() => global.rotationRequests.length))
    .toBe(1);
  await app.evaluate(({ BrowserWindow }) => {
    const contents = BrowserWindow.getAllWindows()[0].webContents;
    contents.send("shenzhen-rotate", {
      degrees: 2.5,
      clientX: 20,
      clientY: 30,
      epochMs: Date.now(),
    });
    contents.send("shenzhen-rotate", {
      degrees: NaN,
      clientX: 20,
      clientY: 30,
      epochMs: Date.now(),
    });
  });
  await expect
    .poll(() => page.evaluate(() => window.rotationSamples.length))
    .toBe(1);
  expect(await page.evaluate(() => window.rotationSamples[0].degrees)).toBe(
    2.5,
  );
  await page.evaluate(() => window.stopRotationSmoke());
  await expect
    .poll(() => app.evaluate(() => global.rotationRequests.length))
    .toBe(2);
  expect(await app.evaluate(() => global.rotationRequests)).toEqual([
    { enabled: true, accepted: true },
    { enabled: false, accepted: true },
  ]);
  report.verified.rotationSubscription = true;
  report.checks.push({
    name: "isolated-native-queue-subscription-and-validated-preload-IPC-roundtrip",
    passed: true,
  });
  report.ipcPerformance = await page.evaluate(() => {
    const times = [];
    for (let i = 0; i < 100; i++) {
      const started = performance.now();
      window.shenzhenScroll.source(performance.timeOrigin + performance.now());
      times.push(performance.now() - started);
    }
    return {
      samples: times.length,
      maxMs: Math.max(...times),
      p95Ms: times.toSorted((a, b) => a - b)[
        Math.ceil(times.length * 0.95) - 1
      ],
      averageMs: times.reduce((a, b) => a + b, 0) / times.length,
    };
  });
  expect(report.ipcPerformance.averageMs).toBeLessThan(2);
  expect(report.ipcPerformance.p95Ms).toBeLessThan(4);
  report.checks.push({
    name: "synchronous-production-bridge-latency",
    passed: true,
  });
  report.passed = true;
} catch (error) {
  report.error = error.message;
  process.exitCode = 1;
} finally {
  await app?.close();
  await fs.rm(directory, { recursive: true, force: true });
  report.cleanedIsolatedProfile = true;
  await fs.mkdir(path.dirname(reportPath), { recursive: true });
  await fs.writeFile(reportPath, JSON.stringify(report, null, 2) + "\n");
  console.log(
    JSON.stringify({
      passed: report.passed,
      checks: report.checks.length,
      nativeEventDeliveryVerified: report.nativeEventDeliveryVerified,
      report: reportPath,
      error: report.error,
    }),
  );
}
