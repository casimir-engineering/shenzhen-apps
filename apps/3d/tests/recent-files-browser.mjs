import { chromium, expect } from "@playwright/test";
import fs from "node:fs/promises";
const browser = await chromium.launch({ headless: true });
const context = await browser.newContext();
const page = await context.newPage();
const errors = [];
let choosers = 0;
page.on("pageerror", (error) => errors.push(error.message));
page.on("filechooser", () => choosers++);
try {
  await page.goto(process.env.RECENT_BASE_URL || "http://127.0.0.1:1420/");
  const prepared = await page.evaluate(async () => {
    const store = await import("/src/core/recent-files.ts");
    const stamp = 1234;
    const companions = [
      new File(["mtllib paint.mtl\nv 0 0 0\n"], "part.obj", {
        lastModified: stamp,
      }),
      new File(["newmtl paint\nKd 1 0 0\n"], "paint.mtl", {
        lastModified: stamp,
      }),
      new File([new Uint8Array([1, 2, 3, 4])], "paint.png", {
        lastModified: stamp,
      }),
    ];
    const companion = await store.rememberRecent(companions, "part.obj", "obj");
    const largeBytes = new Uint8Array(33 * 1024 ** 2);
    largeBytes[0] = 71;
    largeBytes[largeBytes.length - 1] = 92;
    const large = await store.rememberRecent(
      [new File([largeBytes], "large.step", { lastModified: stamp })],
      "large.step",
      "step",
    );
    const collisions = await Promise.all(
      ["first", "other"].map((content) =>
        store.rememberRecent(
          [new File([content], "same.step", { lastModified: stamp })],
          "same.step",
          "step",
        ),
      ),
    );
    return { companion, large, collisions, listed: await store.listRecent() };
  });
  expect(prepared.collisions[0].id).not.toBe(prepared.collisions[1].id);
  expect(prepared.listed.map((entry) => entry.id)).toEqual([
    prepared.collisions[1].id,
    prepared.collisions[0].id,
    prepared.large.id,
    prepared.companion.id,
  ]);
  await page.reload();
  const restored = await page.evaluate(async (entries) => {
    const store = await import("/src/core/recent-files.ts");
    const companion = await store.openRecent(entries.companion);
    const large = (await store.openRecent(entries.large))[0];
    const collisions = await Promise.all(
      entries.collisions.map(async (entry) =>
        (await store.openRecent(entry))[0].text(),
      ),
    );
    const unknown = await store
      .openRecent("00000000-0000-0000-0000-000000000000")
      .then(
        () => "unexpected success",
        (error) => error.message,
      );
    const over = new File(["not large in memory"], "oversize.step");
    Object.defineProperty(over, "size", { value: 257 * 1024 ** 2 });
    const oversize = await store.rememberRecent([over], over.name, "step").then(
      () => "unexpected success",
      (error) => error.message,
    );
    const existing = window.indexedDB;
    Object.defineProperty(window, "indexedDB", {
      configurable: true,
      value: {
        open() {
          throw new DOMException("quota", "QuotaExceededError");
        },
      },
    });
    let quota;
    try {
      await store.rememberRecent(
        [new File(["quota"], "quota.step")],
        "quota.step",
        "step",
      );
    } catch (error) {
      quota = error.message;
    } finally {
      Object.defineProperty(window, "indexedDB", {
        configurable: true,
        value: existing,
      });
    }
    return {
      listed: await store.listRecent(),
      companions: await Promise.all(
        companion.map(async (file) => ({
          name: file.name,
          size: file.size,
          modified: file.lastModified,
          bytes: [...new Uint8Array(await file.arrayBuffer())],
        })),
      ),
      large: {
        size: large.size,
        start: [...new Uint8Array(await large.slice(0, 1).arrayBuffer())],
        end: [...new Uint8Array(await large.slice(-1).arrayBuffer())],
      },
      collisions,
      unknown,
      oversize,
      quota,
    };
  }, prepared);
  expect(restored.listed).toHaveLength(4);
  expect(restored.companions.map((file) => file.name)).toEqual([
    "part.obj",
    "paint.mtl",
    "paint.png",
  ]);
  expect(restored.companions[2].bytes).toEqual([1, 2, 3, 4]);
  expect(restored.companions.every((file) => file.modified === 1234)).toBe(
    true,
  );
  expect(restored.large).toEqual({
    size: 33 * 1024 ** 2,
    start: [71],
    end: [92],
  });
  expect(restored.collisions).toEqual(["first", "other"]);
  expect(restored.unknown).toMatch(/no longer available/);
  expect(restored.oversize).toMatch(
    /too large.*Open it from its location again/,
  );
  expect(restored.quota).toMatch(/storage is unavailable or full/);
  expect(choosers).toBe(0);
  expect(errors).toEqual([]);
  const resources = await page.evaluate(() =>
    performance
      .getEntriesByType("resource")
      .map((resource) => new URL(resource.name).pathname),
  );
  expect(
    resources.some((name) =>
      /(?:model-runtime|three\.core|cad\.worker|ray-tracing)[.-]/.test(name),
    ),
  ).toBe(false);
  await fs.mkdir("artifacts/recent-files", { recursive: true });
  const report = {
    passed: true,
    checks: [
      "companions and bytes after reload",
      "33MiB source after reload",
      "same basename/size/timestamp remain distinct",
      "serialized concurrent remembers",
      "explicit unavailable error",
      "oversize/quota failures add no ghost entry",
      "no chooser",
      "no eager 3D runtime",
    ],
  };
  await fs.writeFile(
    "artifacts/recent-files/browser-report.json",
    JSON.stringify(report, null, 2) + "\n",
  );
  console.log(JSON.stringify(report));
} finally {
  await browser.close();
}
