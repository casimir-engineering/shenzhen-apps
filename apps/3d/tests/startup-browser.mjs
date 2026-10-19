import { chromium } from "@playwright/test";
import { createServer } from "node:http";
import {
  readFileSync,
  existsSync,
  statSync,
  readdirSync,
  mkdirSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import { gzipSync } from "node:zlib";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
const option = (name, fallback) =>
  process.argv
    .find((arg) => arg.startsWith(`--${name}=`))
    ?.slice(name.length + 3) ?? fallback;
const dist = path.resolve(option("dist", "dist")),
  label = option("label", "current"),
  port = Number(option("port", "1437")),
  repetitions = Number(option("runs", "3"));
const output = path.resolve(
  option("output", `artifacts/startup/${label}.json`),
);
const sha = (bytes) => createHash("sha256").update(bytes).digest("hex");
const mime = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".css": "text/css",
  ".json": "application/json",
  ".webmanifest": "application/manifest+json",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".wasm": "application/wasm",
  ".txt": "text/plain",
};
const files = new Map();
function collect(directory) {
  for (const name of readdirSync(directory)) {
    const full = path.join(directory, name);
    if (statSync(full).isDirectory()) collect(full);
    else {
      const relative =
          "/" + path.relative(dist, full).split(path.sep).join("/"),
        bytes = readFileSync(full),
        compressed = gzipSync(bytes, { level: 9 });
      files.set(relative, {
        bytes,
        compressed,
        hash: sha(bytes),
        mime: mime[path.extname(name)] || "application/octet-stream",
      });
    }
  }
}
if (!existsSync(path.join(dist, "index.html")))
  throw Error(`Built index.html absent: ${dist}`);
collect(dist);
const index = files.get("/index.html"),
  entries = [...files.keys()].filter((p) =>
    /\/assets\/index-[\w-]+\.js$/.test(p),
  );
let stage = { name: "setup", requests: [] };
const server = createServer((request, response) => {
  const pathname = decodeURIComponent(
      new URL(request.url, "http://localhost").pathname,
    ),
    file = files.get(pathname === "/" ? "/index.html" : pathname);
  if (!file) {
    response.writeHead(404);
    response.end("Not found");
    return;
  }
  const gzip = /gzip/.test(request.headers["accept-encoding"] || ""),
    body = gzip ? file.compressed : file.bytes;
  const record = {
    path: pathname,
    destination: request.headers["sec-fetch-dest"] || "",
    method: request.method,
    bodyBytes: body.length,
    decodedBytes: file.bytes.length,
    encoding: gzip ? "gzip" : "identity",
    startedAt: performance.now(),
    finished: false,
  };
  stage.requests.push(record);
  response.writeHead(200, {
    "Content-Type": file.mime,
    "Content-Length": body.length,
    "Cache-Control": "no-cache",
    ETag: `"${file.hash}"`,
    ...(gzip ? { "Content-Encoding": "gzip" } : {}),
  });
  response.once("finish", () => {
    record.finished = true;
    record.finishedAt = performance.now();
  });
  response.end(body);
});
await new Promise((resolve, reject) => {
  server.once("error", reject);
  server.listen(port, "127.0.0.1", resolve);
});
const begin = (name) => (stage = { name, requests: [] });
const network = (target) => {
  const requests = target.requests.map((r) => ({ ...r })),
    js = requests.filter((r) => r.path.endsWith(".js"));
  return {
    requests: requests.length,
    encodedResponseBodyBytes: requests
      .filter((r) => r.finished)
      .reduce((n, r) => n + r.bodyBytes, 0),
    requestedJavaScriptFiles: js.length,
    requestedJavaScriptEncodedBodyBytes: js.reduce(
      (n, r) => n + r.bodyBytes,
      0,
    ),
    completedJavaScriptEncodedBodyBytes: js
      .filter((r) => r.finished)
      .reduce((n, r) => n + r.bodyBytes, 0),
    javaScript: js,
    allRequests: requests,
  };
};
const inject = () => {
  window.__startup = {
    shellDomReadyMs: null,
    shellPaintedMs: null,
    sampleClickMs: null,
    sampleIntentMs: null,
    modelDomReadyMs: null,
    modelPaintedMs: null,
  };
  const mark = window.__startup;
  document.addEventListener(
    "pointerover",
    (event) => {
      const button = event.target.closest?.("button");
      if (
        button?.textContent.toLowerCase().includes("sample model") &&
        mark.sampleIntentMs === null
      )
        mark.sampleIntentMs = performance.now();
    },
    true,
  );
  document.addEventListener(
    "click",
    (event) => {
      const button = event.target.closest?.("button");
      if (button?.textContent.toLowerCase().includes("sample model"))
        mark.sampleClickMs = performance.now();
    },
    true,
  );
  const observer = new MutationObserver(() => {
    const button = [...document.querySelectorAll("button")].find((b) =>
      b.textContent.toLowerCase().includes("sample model"),
    );
    if (
      mark.shellDomReadyMs === null &&
      button?.getBoundingClientRect().width
    ) {
      mark.shellDomReadyMs = performance.now();
      requestAnimationFrame(() =>
        requestAnimationFrame(() => (mark.shellPaintedMs = performance.now())),
      );
    }
    if (
      mark.sampleClickMs !== null &&
      mark.modelDomReadyMs === null &&
      /4 parts/.test(
        document.querySelector(".model-badge")?.textContent || "",
      ) &&
      document.querySelector("canvas")
    ) {
      mark.modelDomReadyMs = performance.now();
      requestAnimationFrame(() =>
        requestAnimationFrame(() => {
          mark.modelPaintedMs = performance.now();
          observer.disconnect();
        }),
      );
    }
  });
  observer.observe(document, {
    childList: true,
    subtree: true,
    characterData: true,
    attributes: true,
  });
};
async function timing(page) {
  return page.evaluate(() => ({
    ...window.__startup,
    sampleIntentToModelPaintMs:
      window.__startup.modelPaintedMs === null
        ? null
        : window.__startup.modelPaintedMs - window.__startup.sampleIntentMs,
    sampleClickToModelDomMs:
      window.__startup.modelDomReadyMs === null
        ? null
        : window.__startup.modelDomReadyMs - window.__startup.sampleClickMs,
    sampleClickToModelPaintMs:
      window.__startup.modelPaintedMs === null
        ? null
        : window.__startup.modelPaintedMs - window.__startup.sampleClickMs,
    firstContentfulPaintMs:
      performance.getEntriesByName("first-contentful-paint")[0]?.startTime ??
      null,
    navigation: performance.getEntriesByType("navigation")[0]?.toJSON(),
    javaScriptResources: performance
      .getEntriesByType("resource")
      .filter((r) => /\.js(?:\?|$)/.test(r.name))
      .map((r) => ({
        path: new URL(r.name).pathname,
        initiator: r.initiatorType,
        startTime: r.startTime,
        responseEnd: r.responseEnd,
        transferSize: r.transferSize,
        encodedBodySize: r.encodedBodySize,
        decodedBodySize: r.decodedBodySize,
      })),
    canvasCount: document.querySelectorAll("canvas").length,
    serviceWorkerControlled: !!navigator.serviceWorker?.controller,
  }));
}
async function sample(page) {
  await page
    .getByRole("button", { name: /sample model/i })
    .click();
  await page.waitForFunction(
    () => typeof window.__startup.modelPaintedMs === "number",
  );
  const result = await timing(page);
  const renderer = await page
    .locator("canvas")
    .first()
    .evaluate((canvas) => {
      const gl = canvas.getContext("webgl2") || canvas.getContext("webgl");
      const debug = gl?.getExtension("WEBGL_debug_renderer_info");
      return debug ? gl.getParameter(debug.UNMASKED_RENDERER_WEBGL) : null;
    });
  if (
    !/Apple.*Metal|ANGLE.*Apple/.test(renderer) ||
    /SwiftShader|llvmpipe/i.test(renderer)
  )
    throw Error(`Real Apple GPU required: ${renderer}`);
  return { ...result, renderer };
}
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const runs = [];
try {
  for (let iteration = 0; iteration < repetitions; iteration++) {
    const browser = await chromium.launch({
      headless: false,
      args: [
        "--use-gl=angle",
        "--use-angle=metal",
        "--disable-backgrounding-occluded-windows",
      ],
    });
    try {
      const context = await browser.newContext({
          viewport: { width: 1440, height: 1000 },
          deviceScaleFactor: 2,
          serviceWorkers: "allow",
        }),
        page = await context.newPage(),
        errors = [];
      page.on("pageerror", (e) => errors.push(e.message));
      await page.addInitScript(inject);
      const startupStage = begin("cold-startup");
      await page.goto(`http://127.0.0.1:${port}/`);
      await page.bringToFront();
      await page.waitForFunction(
        () =>
          typeof window.__startup?.shellPaintedMs === "number" &&
          performance.getEntriesByName("first-contentful-paint").length > 0,
      );
      const cold = {
        ...(await timing(page)),
        networkBeforeInteraction: network(startupStage),
      };
      if (process.argv.includes("--expect-lazy")) {
        const decodedJs = cold.javaScriptResources.reduce(
          (n, r) => n + r.decodedBodySize,
          0,
        );
        if (
          decodedJs > 350_000 ||
          cold.networkBeforeInteraction.requestedJavaScriptEncodedBodyBytes >
            120_000
        )
          throw Error(
            "Initial JavaScript exceeded the lazy-shell regression budget.",
          );
        if (startupStage.requests.some((r) => /\.wasm(?:$|\?)/.test(r.path)))
          throw Error("WASM was requested before first interaction.");
        if (cold.canvasCount !== 0)
          throw Error("Viewer canvas was created before first interaction.");
      }
      const sampleStage = begin("cold-sample");
      cold.sample = await sample(page);
      cold.sampleNetwork = network(sampleStage);
      await page.evaluate(() =>
        Promise.race([
          navigator.serviceWorker.ready,
          new Promise((_, reject) =>
            setTimeout(
              () => reject(Error("Service worker install timed out")),
              45000,
            ),
          ),
        ]),
      );
      await page.waitForFunction(() => !!navigator.serviceWorker.controller);
      await sleep(250);
      const install = await page.evaluate(async () => ({
        sinceNavigationMs: performance.now(),
        cacheNames: await caches.keys(),
        entries: (
          await Promise.all(
            (await caches.keys()).map(async (name) =>
              (await (await caches.open(name)).keys()).map(
                (r) => new URL(r.url).pathname,
              ),
            ),
          )
        ).flat(),
      }));
      install.networkThroughInstallation = {
        coldStartup: network(startupStage),
        coldSample: network(sampleStage),
      };
      const warmStage = begin("warm-online");
      await page.reload();
      await page.waitForFunction(
        () =>
          typeof window.__startup?.shellPaintedMs === "number" &&
          performance.getEntriesByName("first-contentful-paint").length > 0,
      );
      const warm = {
        ...(await timing(page)),
        networkBeforeInteraction: network(warmStage),
      };
      warm.sample = await sample(page);
      warm.networkThroughSample = network(warmStage);
      await context.setOffline(true);
      const offlineStage = begin("warm-offline");
      await page.reload();
      await page.waitForFunction(
        () =>
          typeof window.__startup?.shellPaintedMs === "number" &&
          performance.getEntriesByName("first-contentful-paint").length > 0,
      );
      const offline = {
        ...(await timing(page)),
        networkBeforeInteraction: network(offlineStage),
      };
      offline.sample = await sample(page);
      offline.networkThroughSample = network(offlineStage);
      if (errors.length) throw Error(errors.join("\n"));
      runs.push({
        iteration: iteration + 1,
        browserVersion: browser.version(),
        cold,
        install,
        warm,
        offline,
      });
      console.log(
        JSON.stringify({
          label,
          iteration: iteration + 1,
          coldShellMs: cold.shellPaintedMs,
          coldFcpMs: cold.firstContentfulPaintMs,
          coldCriticalJsBytes: cold.javaScriptResources.reduce(
            (n, r) => n + r.encodedBodySize,
            0,
          ),
          coldAllInitialJsBytes:
            cold.networkBeforeInteraction.requestedJavaScriptEncodedBodyBytes,
          coldClickMs: cold.sample.sampleClickToModelPaintMs,
          warmShellMs: warm.shellPaintedMs,
          warmClickMs: warm.sample.sampleClickToModelPaintMs,
          offlineShellMs: offline.shellPaintedMs,
          cachedFiles: install.entries.length,
        }),
      );
      mkdirSync(path.dirname(output), { recursive: true });
      const hardware =
        process.platform === "darwin"
          ? {
              os: execFileSync("sw_vers", ["-productVersion"], {
                encoding: "utf8",
              }).trim(),
              cpu: execFileSync("sysctl", ["-n", "machdep.cpu.brand_string"], {
                encoding: "utf8",
              }).trim(),
            }
          : {};
      writeFileSync(
        output,
        JSON.stringify(
          {
            label,
            recordedAt: new Date().toISOString(),
            sourceCommit: option("source", null),
            builtIndexSha256: index.hash,
            entryFiles: entries.map((name) => ({
              path: name,
              sha256: files.get(name).hash,
              rawBytes: files.get(name).bytes.length,
              gzipBytes: files.get(name).compressed.length,
            })),
            hardware,
            viewport: { width: 1440, height: 1000, dpr: 2 },
            method:
              "Fresh headed Chromium process and empty browser context for every repetition; OS/server filesystem caches are not flushed. Local HTTP server precompresses gzip responses before timing. Shell/model painted metrics end at two animation callbacks after visible DOM markers, not physical display presentation. ResourceTiming excludes service-worker background fetches; server network logs include them. Warm/offline scenarios follow one successful sample load and complete service-worker installation.",
            runs,
          },
          null,
          2,
        ) + "\n",
      );
      const screenshot = option("screenshot", null);
      if (screenshot && iteration === repetitions - 1) {
        // Capture only after all timings and network checkpoints have been saved.
        await page.reload();
        await page.waitForFunction(
          () =>
            typeof window.__startup?.shellPaintedMs === "number" &&
            performance.getEntriesByName("first-contentful-paint").length > 0,
        );
        mkdirSync(path.dirname(path.resolve(screenshot)), { recursive: true });
        await page.screenshot({ path: path.resolve(screenshot) });
      }
    } finally {
      await browser.close();
    }
  }
} finally {
  await new Promise((resolve) => server.close(resolve));
}
