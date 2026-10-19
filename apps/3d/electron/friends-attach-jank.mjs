// Main-thread jank while Friends attaches after first paint: this checkout's app launched with a real helper (on) and
// without (off), alternating. Renderer: long tasks and long animation frames after first contentful paint, until 3 s
// after Friends is ready (on) or 4.5 s after first paint (off). Main process: event-loop lag sampled every 5 ms.
// The helper is a copy of the one built from friends.lock, in a temporary Friends home; it must exit between launches,
// so every attach spawns it. A calibration launch first checks that an 80 ms task in each process is seen.
//
//   scripts/friends/setup-friends.sh && npm run build && node electron/friends-attach-jank.mjs [--runs=10] [--report=f]
import { createRequire } from "node:module";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { _electron as electron } from "@playwright/test";
const require = createRequire(import.meta.url);
const root = path.resolve(
  path.dirname(new URL(import.meta.url).pathname),
  "..",
);
const option = (name) =>
  process.argv
    .find((arg) => arg.startsWith(`--${name}=`))
    ?.slice(name.length + 3);
const sourceHelper = require("./friends/lock.cjs").friendsBuild(root).helperApp;
const out = option("report");
const runs = Number(option("runs") || 10);
if (!Number.isInteger(runs) || runs < 1 || runs > 50)
  throw Error("runs must be an integer from 1 through 50");
const work = await fs.mkdtemp(path.join(os.tmpdir(), "szf3d-jank-"));
const helperApp = path.join(work, "helper", "Shenzhen Friends.app");
await fs.mkdir(path.dirname(helperApp));
execFileSync("ditto", [sourceHelper, helperApp]);
const helperExecutable = path.join(
  helperApp,
  "Contents/MacOS/Shenzhen Friends",
);
const home = path.join(work, "home");
await fs.mkdir(home);
const ours = () => {
  try {
    return execFileSync("pgrep", ["-f", helperExecutable], {
      encoding: "utf8",
    }).trim();
  } catch {
    return "";
  }
};
const waitHelperGone = async () => {
  for (let i = 0; i < 40 && ours(); i++)
    await new Promise((r) => setTimeout(r, 500));
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const rows = [];
try {
  // First a calibration launch: an 80 ms task in each process before the observers are read must be seen.
  const plan = [["calibrate", 0]];
  for (let run = 0; run < runs; run++)
    for (const v of run % 2 ? ["off", "on"] : ["on", "off"])
      plan.push([v, run]);
  for (const [variant, run] of plan) {
    await waitHelperGone();
    const env = { ...process.env };
    delete env.SHENZHEN_3D_DEV_URL;
    if (variant === "on")
      Object.assign(env, {
        SHENZHEN_3D_FRIENDS_HELPER: helperApp,
        SZFRIENDS_STATE_DIR: home,
      });
    else {
      delete env.SHENZHEN_3D_FRIENDS_HELPER;
      delete env.SZFRIENDS_STATE_DIR;
    }
    const app = await electron.launch({
      args: [
        path.join(root, "electron/main.cjs"),
        `--user-data-dir=${path.join(work, `profile-${variant}-${run}`)}`,
      ],
      env,
    });
    try {
      // Main-process lag sampler, installed as soon as the app answers (before the first window is shown).
      await app.evaluate(() => {
        const samples = (globalThis.__lag = []);
        let expected = performance.now() + 5;
        const tick = () => {
          const now = performance.now();
          samples.push([now, Math.max(0, now - expected)]);
          expected = now + 5;
          globalThis.__lagTimer = setTimeout(tick, 5);
        };
        globalThis.__lagTimer = setTimeout(tick, 5);
      });
      const page = await app.firstWindow();
      await page.waitForFunction(
        () => performance.getEntriesByName("first-contentful-paint").length > 0,
        null,
        { timeout: 30000 },
      );
      const mainPaint0 = await app.evaluate(() => performance.now());
      await page.evaluate(() => {
        window.__long = [];
        window.__loaf = [];
        new PerformanceObserver((l) =>
          window.__long.push(
            ...l.getEntries().map((e) => [e.startTime, e.duration]),
          ),
        ).observe({ type: "longtask", buffered: true });
        new PerformanceObserver((l) =>
          window.__loaf.push(
            ...l
              .getEntries()
              .map((e) => [e.startTime, e.duration, e.blockingDuration]),
          ),
        ).observe({ type: "long-animation-frame", buffered: true });
      });
      if (variant === "calibrate") {
        await page.evaluate(() =>
          setTimeout(() => {
            const t = performance.now();
            while (performance.now() - t < 80);
          }, 0),
        );
        await app.evaluate(() =>
          setTimeout(() => {
            const t = performance.now();
            while (performance.now() - t < 80);
          }, 0),
        );
      }
      const mainPaint = mainPaint0;
      let readyAt = null;
      if (variant === "on") {
        for (let i = 0; i < 300; i++) {
          const state = await page.evaluate(
            async () => (await window.shenzhenFriends?.status())?.state,
          );
          if (state === "ready") {
            readyAt = await page.evaluate(() => performance.now());
            break;
          }
          await sleep(25);
        }
        if (readyAt === null) throw Error("Friends never became ready");
        await page
          .locator('[data-szfriends="button"]')
          .waitFor({ timeout: 10000 });
        await sleep(3000);
      } else await sleep(variant === "calibrate" ? 500 : 4500);
      const renderer = await page.evaluate(() => ({
        fcp: performance.getEntriesByName("first-contentful-paint")[0]
          .startTime,
        long: window.__long,
        loaf: window.__loaf,
        end: performance.now(),
      }));
      const lag = await app.evaluate(() => {
        clearTimeout(globalThis.__lagTimer);
        return globalThis.__lag;
      });
      const after = (list) => list.filter((e) => e[0] >= renderer.fcp);
      const max = (list, i = 1) =>
        list.reduce((m, e) => Math.max(m, e[i] ?? 0), 0);
      const mainAfter = lag.filter(([t]) => t >= mainPaint);
      const row = {
        variant,
        run: run + 1,
        fcpMs: +renderer.fcp.toFixed(1),
        friendsReadyMs: readyAt && +readyAt.toFixed(1),
        rendererLongTasks: after(renderer.long).map((e) =>
          e.map((x) => +x.toFixed(1)),
        ),
        rendererMaxLongTaskMs: +max(after(renderer.long)).toFixed(1),
        rendererMaxLongAnimationFrameMs: +max(after(renderer.loaf)).toFixed(1),
        rendererMaxLoafBlockingMs: +max(after(renderer.loaf), 2).toFixed(1),
        mainMaxLagMs: +max(mainAfter).toFixed(1),
        mainLagOver16Ms: mainAfter
          .filter(([, l]) => l > 16)
          .map(([t, l]) => [+(t - mainPaint).toFixed(0), +l.toFixed(1)]),
      };
      if (variant === "calibrate") {
        if (
          row.rendererMaxLongTaskMs < 70 ||
          row.rendererMaxLongAnimationFrameMs < 70 ||
          row.mainMaxLagMs < 70
        )
          throw Error("calibration not seen: " + JSON.stringify(row));
        console.log("calibration seen: " + JSON.stringify(row));
        continue;
      }
      rows.push(row);
      console.log(JSON.stringify(row));
    } finally {
      await app.close();
    }
  }
} finally {
  await waitHelperGone();
  const left = ours();
  if (left) console.error(`helper still running: ${left}`);
  await fs.rm(work, { recursive: true, force: true });
}
const med = (a) => {
  const s = [...a].sort((x, y) => x - y);
  return s[Math.floor(s.length / 2)];
};
const summary = Object.fromEntries(
  ["on", "off"].map((v) => {
    const r = rows.filter((x) => x.variant === v);
    return [
      v,
      {
        runs: r.length,
        rendererMaxLongTaskMs: {
          median: med(r.map((x) => x.rendererMaxLongTaskMs)),
          max: Math.max(...r.map((x) => x.rendererMaxLongTaskMs)),
        },
        rendererMaxLongAnimationFrameMs: {
          median: med(r.map((x) => x.rendererMaxLongAnimationFrameMs)),
          max: Math.max(...r.map((x) => x.rendererMaxLongAnimationFrameMs)),
        },
        mainMaxLagMs: {
          median: med(r.map((x) => x.mainMaxLagMs)),
          max: Math.max(...r.map((x) => x.mainMaxLagMs)),
        },
        ...(v === "on"
          ? { friendsReadyMs: { median: med(r.map((x) => x.friendsReadyMs)) } }
          : {}),
      },
    ];
  }),
);
if (out)
  await fs.writeFile(
    out,
    JSON.stringify(
      { date: new Date().toISOString(), summary, runs: rows },
      null,
      2,
    ) + "\n",
  );
console.log(JSON.stringify(summary, null, 2));
