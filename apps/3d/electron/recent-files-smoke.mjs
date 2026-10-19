import { _electron as electron, expect } from "@playwright/test";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
const directory = await fs.mkdtemp(
  path.join(os.tmpdir(), "shenzhen-recent-native-"),
);
const profile = path.join(directory, "profile");
const model = path.join(directory, "part.obj"),
  companion = path.join(directory, "paint.mtl"),
  coldModel = path.join(directory, "cold.stl"),
  warmModel = path.join(directory, "warm.stl");
await fs.writeFile(
  model,
  "mtllib paint.mtl\nv 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n",
);
await fs.writeFile(companion, "newmtl paint\nKd 1 0 0\n");
const triangle =
  "solid part\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 1 0 0\nvertex 0 1 0\nendloop\nendfacet\nendsolid part\n";
await fs.writeFile(coldModel, triangle);
await fs.writeFile(warmModel, triangle);
const env = { ...process.env };
delete env.SHENZHEN_3D_DEV_URL;
let application;
const packaged = process.argv
  .find((arg) => arg.startsWith("--executable="))
  ?.slice(13);
const errors = [];
let choosers = 0;
const launch = async (files = []) => {
  application = await electron.launch({
    ...(packaged ? { executablePath: packaged } : {}),
    args: [
      ...(packaged ? [] : [path.resolve("electron/main.cjs")]),
      ...files,
      `--user-data-dir=${profile}`,
    ],
    env,
  });
  const page = await application.firstWindow();
  page.on("pageerror", (error) => errors.push(error.message));
  page.on("filechooser", () => choosers++);
  await application.evaluate(({ BrowserWindow }) =>
    BrowserWindow.getAllWindows().forEach((window) => window.hide()),
  );
  await page.waitForFunction(() =>
    Boolean(window.shenzhenRecentFiles && window.shenzhenFiles),
  );
  return page;
};
try {
  let page = await launch([coldModel]);
  await expect(page.locator("header")).toContainText("cold.stl", {
    timeout: 30000,
  });
  await expect(page.locator(".model-badge")).toContainText("1 part");
  await page.locator("input[type=file]").setInputFiles([model, companion]);
  await expect(page.locator("header")).toContainText("part.obj");
  await expect(page.locator(".model-badge")).toContainText("1 part");
  await expect
    .poll(async () =>
      page.evaluate(
        async () =>
          (await window.shenzhenRecentFiles.list()).find(
            (entry) => entry.name === "part.obj",
          )?.fileCount,
      ),
    )
    .toBe(2);
  const entry = await page.evaluate(async () =>
    (await window.shenzhenRecentFiles.list()).find(
      (entry) => entry.name === "part.obj",
    ),
  );
  expect(entry.storage).toBe("native");
  expect(entry.fileCount).toBe(2);
  const fake = await page.evaluate(async () =>
    window.shenzhenRecentFiles.remember(
      [new File(["fake"], "fake.step")],
      "fake.step",
      "step",
    ),
  );
  expect(fake).toBeNull();
  await application.close();
  application = undefined;
  page = await launch();
  await expect(
    page
      .getByRole("region", { name: "Recent files" })
      .getByRole("button", { name: /part.obj/ }),
  ).toBeVisible();
  expect(await page.locator("canvas").count()).toBe(0);
  const startupResources = await page.evaluate(() =>
    performance.getEntriesByType("resource").map((resource) => resource.name),
  );
  expect(
    startupResources.some((name) =>
      /(?:model-runtime|three\.core|cad\.worker)[.-]/.test(name),
    ),
  ).toBe(false);
  await page
    .getByRole("region", { name: "Recent files" })
    .getByRole("button", { name: /part.obj/ })
    .click();
  await expect(page.locator("header")).toContainText("part.obj");
  await expect(page.locator(".model-badge")).toContainText("1 part");
  const reopened = await page.evaluate(
    async (id) =>
      (await window.shenzhenRecentFiles.open(id)).map((file) => ({
        name: file.name,
        text: new TextDecoder().decode(file.bytes),
      })),
    entry.id,
  );
  expect(reopened.map((file) => file.name)).toEqual(["part.obj", "paint.mtl"]);
  expect(reopened[1].text).toContain("Kd 1 0 0");
  await expect
    .poll(async () =>
      page.evaluate(
        async () =>
          (await window.shenzhenRecentFiles.list()).filter(
            (item) => item.name === "part.obj",
          ).length,
      ),
    )
    .toBe(1);
  const browserCopies = await page.evaluate(
    () =>
      new Promise((resolve, reject) => {
        const request = indexedDB.open("shenzhen-recent-files", 1);
        request.onerror = () => reject(request.error);
        request.onsuccess = () => {
          const db = request.result,
            query = db.transaction("entries").objectStore("entries").count();
          query.onsuccess = () => {
            resolve(query.result);
            db.close();
          };
        };
      }),
  );
  expect(browserCopies).toBe(0);
  await application.evaluate(
    ({ app }, file) => app.emit("open-file", { preventDefault() {} }, file),
    warmModel,
  );
  await expect(page.locator("header")).toContainText("warm.stl");
  await expect(page.locator(".model-badge")).toContainText("1 part");
  await page
    .getByRole("button", { name: "Close document", exact: true })
    .click();
  await expect(page.locator("canvas")).toHaveCount(0);
  await fs.rm(companion);
  await page
    .getByRole("region", { name: "Recent files" })
    .getByRole("button", { name: /part.obj/ })
    .click();
  await expect(page.getByRole("alert")).toContainText("moved, removed");
  expect(choosers).toBe(0);
  expect(errors).toEqual([]);
  const report = {
    passed: true,
    checks: [
      "App imports cold argv file",
      "App file input persists native grant and companions",
      "no synthetic File path",
      "isolated profile restart with lazy welcome",
      "recent UI reopens model without chooser",
      "companion bytes survive restart",
      "native reopen creates no browser duplicate",
      "App imports warm macOS open-file event",
      "missing companion shows actionable UI error without chooser",
    ],
  };
  const output =
    process.argv.find((arg) => arg.startsWith("--report="))?.slice(9) ||
    "artifacts/recent-files/native-ui-report.json";
  await fs.mkdir(path.dirname(output), { recursive: true });
  await fs.writeFile(output, JSON.stringify(report, null, 2) + "\n");
  console.log(JSON.stringify(report));
} finally {
  await application?.close();
  await fs.rm(directory, { recursive: true, force: true });
}
