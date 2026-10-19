import { chromium, expect } from '@playwright/test';
import fs from 'node:fs/promises';
const browser = await chromium.launch({headless: false, args: ['--use-gl=angle', '--use-angle=metal']});
const checks = [], errors = [];
let page;
try {
  page = await browser.newPage({viewport: {width: 1440, height: 1000}, deviceScaleFactor: 1});
  page.on('pageerror', error => errors.push(error.message));
  page.on('console', message => {if (message.type() === 'error') errors.push(message.text());});
  await page.goto(process.env.E2E_BASE_URL || 'http://127.0.0.1:1424');
  await page.bringToFront();
  const hardware = await page.evaluate(async () => {
    const adapter = await navigator.gpu?.requestAdapter({powerPreference: 'high-performance'});
    return adapter ? {vendor: adapter.info.vendor, architecture: adapter.info.architecture, fallback: adapter.info.isFallbackAdapter} : null;
  });
  if (!hardware || hardware.fallback || /software|swiftshader/i.test(JSON.stringify(hardware))) throw new Error('Hardware WebGPU required');
  await page.getByRole('button', {name: 'Sample model', exact: true}).click();
  await expect(page.locator('.model-badge')).toContainText('4 parts');
  await page.getByTitle('Top · Shift 5', {exact: true}).click();
  await page.getByRole('button', {name: 'Fit model', exact: true}).click();
  const close = page.getByRole('button', {name: 'Close measurements', exact: true});
  if (await close.isVisible()) await close.click();
  const canvas = page.locator('.viewport-canvas > canvas').first();
  await page.evaluate(() => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))));
  const png = await canvas.screenshot();
  const locations = await canvas.evaluate(async (canvas, png) => {
    const image = new Image(); image.src = `data:image/png;base64,${png}`; await image.decode();
    const sampler = document.createElement('canvas'); sampler.width = image.width; sampler.height = image.height;
    const ctx = sampler.getContext('2d'); ctx.drawImage(image, 0, 0);
    const pixels = ctx.getImageData(0, 0, image.width, image.height).data, rect = canvas.getBoundingClientRect(), points = [];
    for (let y = 80; y < rect.height - 100; y += 4) for (let x = 40; x < rect.width - 60; x += 4) {
      const i = (Math.floor(y / rect.height * image.height) * image.width + Math.floor(x / rect.width * image.width)) * 4;
      if (pixels[i] > 75 && pixels[i+1] > 75 && pixels[i+2] > 75) points.push({x: rect.x + x, y: rect.y + y});
    }
    return points.sort((a,b) => a.x - b.x);
  }, png.toString('base64'));
  const picks = [];
  for (const fraction of [.2, .8]) {
    for (let i = Math.floor(locations.length * fraction); i < locations.length; i++) {
      const p = locations[i]; await page.mouse.move(p.x, p.y);
      await page.evaluate(() => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))));
      if ((await page.locator('.status-main').innerText()).includes(' · ')) {picks.push(p); break;}
    }
  }
  expect(picks).toHaveLength(2);
  for (const p of picks) {
    if (await close.isVisible()) await close.click();
    await page.mouse.click(p.x, p.y);
  }
  await expect(page.locator('.result-hero strong')).toBeVisible();
  const measured = await page.locator('.result-hero strong').innerText();
  await page.getByRole('button', {name: 'Save measurement', exact: true}).click();
  await page.getByRole('button', {name: /^Notes/}).click();
  await page.getByRole('button', {name: 'Add note', exact: true}).click();
  await page.getByLabel('Annotation text', {exact: true}).fill('Check clearance at this point.');
  await page.getByRole('button', {name: 'Save note', exact: true}).click();
  await expect(page.locator('.review-pin')).toBeVisible();
  await page.getByRole('button', {name: 'Saved 1', exact: true}).click();
  await page.locator('.saved-measurement > button').first().click();
  await page.getByRole('button', {name: 'Settings', exact: true}).click();
  await page.getByLabel('GPU ray tracing', {exact: true}).check();
  await page.getByLabel('Ray tracing samples', {exact: true}).selectOption('32');
  await page.getByRole('button', {name: 'Done', exact: true}).click();
  await expect(page.locator('.ray-status-badge')).toContainText('Ray traced · 32 samples', {timeout: 180000});
  await expect(page.locator('.ray-tracing-overlay')).toBeVisible();
  await expect(page.locator('.dimension-label')).toBeVisible();
  await expect(page.locator('.review-pin')).toBeVisible();
  await expect(page.locator('.result-hero strong')).toHaveText(measured);
  checks.push('Production WebGPU worker converges with measurement and note overlays');
  const pin = page.locator('.review-pin');
  expect(await pin.evaluate(el => {const r=el.getBoundingClientRect();return document.elementFromPoint(r.x+r.width/2,r.y+r.height/2) === el;})).toBe(true);
  checks.push('Review pin receives pointer input above both rendering canvases');
  await fs.mkdir('artifacts/perf', {recursive: true});
  await page.screenshot({path: 'artifacts/perf/app-ray-tracing.png'});
  const downloadWait = page.waitForEvent('download');
  await page.getByRole('button', {name: 'Save screenshot', exact: true}).click();
  const download = await downloadWait;
  await download.saveAs('artifacts/perf/app-ray-tracing-export.png');
  expect((await fs.stat('artifacts/perf/app-ray-tracing-export.png')).size).toBeGreaterThan(3000);
  checks.push('Traced viewport PNG export succeeds');
  await page.getByRole('button', {name: 'Settings', exact: true}).click();
  await page.getByLabel('Settings render style').selectOption('hidden-line');
  await page.getByRole('button', {name: 'Done', exact: true}).click();
  await expect(page.locator('.ray-tracing-overlay')).toHaveCount(0);
  await expect(page.locator('.ray-status-badge')).toHaveCount(0);
  await expect(page.locator('.result-hero strong')).toHaveText(measured);
  checks.push('Switching to hidden-line releases ray tracing and preserves measurements');
  expect(errors).toEqual([]);
  await fs.writeFile('artifacts/perf/app-ray-tracing.json', JSON.stringify({date: new Date().toISOString(), hardware, checks, errors}, null, 2));
  console.log(JSON.stringify({hardware, checks, errors}));
} catch (error) {
  if (page) await page.screenshot({path: 'artifacts/perf/app-ray-tracing-failure.png'}).catch(() => {});
  throw error;
} finally {await browser.close();}
