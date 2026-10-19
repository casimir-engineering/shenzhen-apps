import { _electron as electron, expect } from '@playwright/test';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { checkReviewProject, checkRayTracing } from './smoke-features.mjs';

// Default: compatible with the 0.1.1 packaged checkpoint. Add --review and
// --ray-tracing for 0.1.2; --development explicitly tests the live local app.

const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'shenzhen-electron-smoke-'));
const environment = { ...process.env };
delete environment.SHENZHEN_3D_DEV_URL;
const packaged = process.argv.find(argument => argument.startsWith('--executable='))?.slice(13);
const development = process.argv.includes('--development');
const lazyStartup = process.argv.includes('--lazy-startup');
if (development && packaged) throw new Error('Development smoke cannot use a packaged executable');
if (development) environment.SHENZHEN_3D_DEV_URL = 'http://127.0.0.1:1420/';
const launchedAt = performance.now();
const application = await electron.launch({ ...(packaged ? { executablePath: packaged } : {}), args: [...(packaged ? [] : [path.resolve('electron/main.cjs')]), `--user-data-dir=${path.join(directory, 'profile')}`], env: environment });
const errors = [];
const serviceWorkerRequests = [];
const workers = [];
const checks = ['sandbox', 'context isolation', 'local protocol', 'native Cmd+O STEP import', 'worker/WASM', 'PNG after delayed native download', 'CSV export', 'no native service worker', 'remote navigation blocked', 'popups blocked', 'no application errors'];
try {
  const page = await application.firstWindow();
  page.on('pageerror', error => errors.push(error.message));
  page.on('worker', worker => workers.push(worker.url()));
  page.on('request', request => { if (new URL(request.url()).pathname === '/sw.js') serviceWorkerRequests.push(request.url()); });
  page.on('console', message => { if (message.type() === 'error') { errors.push(message.text()); console.error(message.text()); } });
  await expect(page.locator('header').getByRole('button', { name: /^Open file/ })).toBeEnabled();
  const launchToOpenReadyMs = performance.now() - launchedAt;
  const startup = await page.evaluate(() => {
    const navigation = performance.getEntriesByType('navigation')[0];
    return { initialCanvasCount: document.querySelectorAll('.viewport-canvas canvas').length, domContentLoadedMs: navigation?.domContentLoadedEventEnd, loadEventMs: navigation?.loadEventEnd, usedJSHeapBytes: performance.memory?.usedJSHeapSize, resourcePaths: performance.getEntriesByType('resource').map(entry => new URL(entry.name).pathname) };
  });
  startup.launchToOpenReadyMs = launchToOpenReadyMs;
  if (lazyStartup) {
    expect(startup.initialCanvasCount).toBe(0);
    expect(startup.resourcePaths.filter(name => /(?:model-runtime|three\.core|project-file|ray-tracing)[.-]/.test(name))).toEqual([]);
    checks.push('welcome Open ready before renderer creation');
  }
  await page.bringToFront();
  await application.evaluate(({ app, BrowserWindow }) => { app.focus({ steal: true }); BrowserWindow.getAllWindows()[0].focus(); });
  console.log(`Electron ${development ? 'development' : 'production'} app loaded`);
  const preferences = await application.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].webContents.getLastWebPreferences());
  expect(preferences.sandbox).toBe(true);
  expect(preferences.contextIsolation).toBe(true);
  expect(preferences.nodeIntegration).toBe(false);
  const runtime = await application.evaluate(({ app }) => ({ packaged: app.isPackaged, applicationVersion: app.getVersion(), versions: process.versions }));
  const applicationURL = development ? 'http://127.0.0.1:1420/' : 'app://local/';
  expect(page.url()).toBe(applicationURL);
  const documentCSP = development ? undefined : await page.evaluate(async () => (await fetch('/')).headers.get('Content-Security-Policy'));
  if (!development) {
    expect(documentCSP).toContain("worker-src 'self' blob:");
    expect(documentCSP).not.toContain("'unsafe-eval'");
  }
  expect(await page.evaluate(() => typeof window.require)).toBe('undefined');
  const measureCapability = () => page.evaluate(async () => {
    const gl = document.querySelector('canvas').getContext('webgl2');
    const debug = gl.getExtension('WEBGL_debug_renderer_info');
    const frames = [];
    for (let i = 0; i < 120; i++) frames.push(await new Promise(resolve => requestAnimationFrame(resolve)));
    const intervals = frames.slice(1).map((time, i) => time - frames[i]).sort((a, b) => a - b);
    return { renderer: debug ? gl.getParameter(debug.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER), rafFps: (frames.length - 1) * 1000 / (frames.at(-1) - frames[0]), rafP50Ms: intervals[Math.floor(intervals.length / 2)] };
  });
  const chooserWait = page.waitForEvent('filechooser', { timeout: 20_000 });
  await application.evaluate(({ Menu }) => Menu.getApplicationMenu().items.find(item => item.label === 'File').submenu.items.find(item => item.label === 'Open…').click());
  await (await chooserWait).setFiles(path.resolve('fixtures/sample-assembly.step'));
  console.log('Native Open selected STEP');
  await Promise.race([
    expect(page.locator('.model-badge')).toContainText('CAD model', { timeout: 120_000 }),
    page.getByRole('alert').waitFor({ state: 'visible', timeout: 120_000 }).then(async () => { throw new Error(await page.getByRole('alert').innerText()); }),
  ]);
  await expect(page.getByRole('alert')).toHaveCount(0);
  await expect(page.locator('.viewport-canvas > canvas').first()).toBeVisible();
  const capability = await measureCapability();
  expect(capability.renderer).not.toMatch(/SwiftShader|llvmpipe/i);
  console.log('Hardware capability after STEP import', capability);
  console.log('STEP worker/WASM import complete');
  const png = path.join(directory, 'export.png');
  // Main-process test automation supplies the chosen path, pauses longer than
  // the frontend's 5s URL lifetime, then resumes the existing DownloadItem.
  // Production exposes no renderer IPC or automatic save destination.
  await application.evaluate(({ session }, target) => {
    session.defaultSession.once('will-download', (_event, item) => {
      item.setSavePath(target);
      item.pause();
      setTimeout(() => item.resume(), 6500);
    });
  }, png);
  await page.getByRole('button', { name: 'Save screenshot', exact: true }).click();
  await expect.poll(async () => fs.stat(png).then(stat => stat.size).catch(() => 0), { timeout: 30_000 }).toBeGreaterThan(1000);
  expect((await fs.readFile(png)).subarray(0, 8).toString('hex')).toBe('89504e470d0a1a0a');
  const csv = path.join(directory, 'measurement.csv');
  await application.evaluate(({ session }, target) => { session.defaultSession.once('will-download', (_event, item) => item.setSavePath(target)); }, csv);
  await page.evaluate(() => {
    const url = URL.createObjectURL(new Blob(['name,distance\nExample,12.5\n'], { type: 'text/csv' }));
    const link = document.createElement('a');
    link.href = url;
    link.download = 'measurement.csv';
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 5000);
  });
  await expect.poll(async () => fs.readFile(csv, 'utf8').catch(() => ''), { timeout: 15_000 }).toBe('name,distance\nExample,12.5\n');
  if (process.argv.includes('--review')) checks.push(...await checkReviewProject(application, page, directory));
  if (process.argv.includes('--ray-tracing')) checks.push(...await checkRayTracing(application, page, directory));
  if (process.argv.includes('--ray-tracing')) expect(workers.some(url => /ray-tracing\.worker[.-]/.test(url))).toBe(true);
  await page.evaluate(() => { window.open('https://example.com/'); });
  expect(await application.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows().length)).toBe(1);
  await page.evaluate(() => { location.href = 'https://example.com/'; });
  expect(page.url()).toBe(applicationURL);
  if (!development) expect(serviceWorkerRequests).toEqual([]);
  expect(errors).toEqual([]);
  const report = { ...runtime, ...capability, development, startup, documentCSP, workers, checks: development ? checks.filter(check => !['local protocol', 'no native service worker'].includes(check)) : checks };
  const output = process.argv.find(argument => argument.startsWith('--report='))?.slice(9);
  if (output) {
    await fs.writeFile(output, JSON.stringify(report, null, 2));
    await page.screenshot({ path: output.replace(/\.json$/, '.png') });
  }
  console.log(JSON.stringify(report, null, 2));
} finally {
  await application.close();
  await fs.rm(directory, { recursive: true, force: true });
}
