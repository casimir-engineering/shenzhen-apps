import { expect } from '@playwright/test';
import fs from 'node:fs/promises';
import path from 'node:path';

async function closeInspector(page) {
  const close = page.getByRole('button', { name: 'Close measurements', exact: true });
  if (await close.isVisible()) await close.click();
}

// Sample presented pixels, then verify actual picks; the viewer intentionally
// discards the WebGL drawing buffer after presentation.
async function surfacePicks(page) {
  await closeInspector(page);
  await page.getByTitle('Top · Shift 5', { exact: true }).click();
  await page.getByRole('button', { name: 'Fit model', exact: true }).click();
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  const canvas = page.locator('.viewport-canvas > canvas').first();
  const screenshot = await canvas.screenshot();
  const locations = await canvas.evaluate(async (canvas, png) => {
    const image = new Image();
    image.src = `data:image/png;base64,${png}`;
    await image.decode();
    const sampler = document.createElement('canvas');
    sampler.width = image.width; sampler.height = image.height;
    const context = sampler.getContext('2d');
    context.drawImage(image, 0, 0);
    const pixels = context.getImageData(0, 0, image.width, image.height).data;
    const rect = canvas.getBoundingClientRect(), points = [];
    for (let y = 65; y < rect.height - 85; y += 4) for (let x = 30; x < rect.width - 48; x += 4) {
      const i = (Math.floor(y / rect.height * image.height) * image.width + Math.floor(x / rect.width * image.width)) * 4;
      if (pixels[i] > 75 && pixels[i + 1] > 75 && pixels[i + 2] > 75) points.push({ x: rect.x + x, y: rect.y + y });
    }
    if (points.length) {
      const xs = points.map(p => p.x), ys = points.map(p => p.y);
      const axis = Math.max(...xs) - Math.min(...xs) > Math.max(...ys) - Math.min(...ys) ? 'x' : 'y';
      points.sort((a, b) => a[axis] - b[axis]);
    }
    return points;
  }, screenshot.toString('base64'));
  expect(locations.length).toBeGreaterThan(10);
  const picks = [];
  for (const fraction of [.18, .8]) {
    for (let offset = 0; offset < 100; offset++) {
      const point = locations[Math.min(Math.floor(locations.length * fraction) + offset, locations.length - 1)];
      await page.mouse.move(point.x, point.y);
      await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
      if ((await page.locator('.status-main').innerText()).includes(' · ')) { picks.push(point); break; }
    }
  }
  expect(picks).toHaveLength(2);
  return picks;
}

async function chooseDownload(application, destination) {
  await application.evaluate(({ session }, target) => {
    globalThis.__smokeDownloadState = 'waiting';
    session.defaultSession.once('will-download', (_event, item) => {
      item.setSavePath(target);
      item.once('done', (_event, state) => { globalThis.__smokeDownloadState = state; });
    });
  }, destination);
}

async function completedDownload(application) {
  await expect.poll(() => application.evaluate(() => globalThis.__smokeDownloadState), { timeout: 30_000 }).toBe('completed');
}

export async function checkReviewProject(application, page, directory) {
  const locations = await surfacePicks(page);
  await page.getByTitle('Pick CAD features · E', { exact: true }).click();
  await page.getByLabel('Feature selection filter').selectOption('face');
  for (const point of locations) { await closeInspector(page); await page.mouse.click(point.x, point.y); }
  await expect(page.locator('.accuracy-tag')).toContainText('Exact CAD geometry', { timeout: 60_000 });
  const distance = await page.locator('.result-hero strong').innerText();
  await page.getByRole('button', { name: 'Save measurement', exact: true }).click();
  await page.getByRole('button', { name: /^Notes/ }).click();
  await page.getByRole('button', { name: 'Add note', exact: true }).click();
  await page.getByLabel('Annotation target').selectOption('feature');
  await closeInspector(page);
  await page.mouse.click(locations[0].x, locations[0].y);
  await expect(page.locator('.note-anchor.attached')).toContainText('face');
  await page.getByLabel('Annotation text', { exact: true }).fill('Electron project smoke: verify this CAD face.');
  await page.getByRole('button', { name: 'Save note', exact: true }).click();
  await page.evaluate(() => Object.defineProperty(navigator, 'canShare', { configurable: true, value: () => false }));
  const project = path.join(directory, 'cad-review.sz3d');
  await chooseDownload(application, project);
  await page.locator('header').getByRole('button', { name: 'Share commented project', exact: true }).click();
  await completedDownload(application);
  expect((await fs.stat(project)).size).toBeGreaterThan(1000);
  expect((await fs.readFile(project)).subarray(0, 4).toString('hex')).toBe('504b0304');
  await page.reload();
  await expect(page.locator('input[type=file]')).toHaveAttribute('accept', /\.sz3d(?:,|$)/);
  const chooser = page.waitForEvent('filechooser');
  await application.evaluate(({ Menu }) => Menu.getApplicationMenu().items.find(item => item.label === 'File').submenu.items.find(item => item.label === 'Open…').click());
  await (await chooser).setFiles(project);
  await expect(page.locator('.model-badge')).toContainText('CAD model', { timeout: 120_000 });
  await expect(page.locator('.review-note')).toHaveCount(1);
  await expect(page.locator('.review-note')).toContainText('Electron project smoke');
  await expect(page.locator('.note-location small')).toContainText('face');
  await expect(page.getByRole('alert')).toHaveCount(0);
  await page.getByRole('button', { name: 'Saved 1', exact: true }).click();
  await page.locator('.saved-measurement > button').first().click();
  await expect(page.locator('.result-hero strong')).toHaveText(distance);
  await expect(page.locator('.accuracy-tag')).toContainText('Exact CAD geometry');
  console.log('Electron CAD project download/reopen complete');
  return ['native .sz3d download and Cmd+O reopen', '.sz3d native chooser filter', 'CAD face note rebind', 'exact saved measurement restore', 'asynchronous ZIP worker'];
}

export async function checkRayTracing(application, page, directory) {
  // Use the small built-in sample so this remains a correctness smoke, not a
  // large-scene GPU performance benchmark.
  await page.reload();
  await page.getByRole('button', { name: 'Sample model', exact: true }).click();
  await expect(page.locator('.model-badge')).toContainText('4 parts');
  await application.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].setContentSize(900, 700));
  await page.getByRole('button', { name: 'Settings', exact: true }).click();
  await page.getByLabel('GPU ray tracing', { exact: true }).check();
  await page.getByLabel('Ray tracing samples', { exact: true }).selectOption('32');
  await page.getByLabel('Ray tracing resolution', { exact: true }).selectOption('0.5');
  await page.getByRole('button', { name: 'Done', exact: true }).click();
  await expect(page.locator('.ray-status-badge')).toContainText('Ray traced · 32 samples', { timeout: 180_000 });
  await expect(page.locator('.ray-tracing-overlay')).toBeVisible();
  const png = path.join(directory, 'ray-traced.png');
  await chooseDownload(application, png);
  await page.getByRole('button', { name: 'Save screenshot', exact: true }).click();
  await completedDownload(application);
  expect((await fs.stat(png)).size).toBeGreaterThan(3000);
  expect((await fs.readFile(png)).subarray(0, 8).toString('hex')).toBe('89504e470d0a1a0a');
  await page.getByRole('button', { name: 'Settings', exact: true }).click();
  await page.getByLabel('Settings render style').selectOption('hidden-line');
  await page.getByRole('button', { name: 'Done', exact: true }).click();
  await expect(page.locator('.ray-tracing-overlay')).toHaveCount(0);
  await expect(page.locator('.ray-status-badge')).toHaveCount(0);
  await expect(page.locator('.viewport-canvas > canvas').first()).toBeVisible();
  console.log('Electron WebGPU worker/PNG/style fallback complete');
  return ['WebGPU rendering worker converges', 'ray-traced native PNG export', 'hidden-line releases rendering worker'];
}
