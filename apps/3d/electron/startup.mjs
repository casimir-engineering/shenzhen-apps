// Paired production-protocol welcome timings using the same Electron shell and
// fresh profiles. Frozen asset directories are read-only; no app source changes.
import { _electron as electron, expect } from '@playwright/test';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
const argument = name => process.argv.find(value => value.startsWith(`--${name}=`))?.slice(name.length + 3);
const baseline = argument('baseline'), candidate = argument('candidate');
if (!baseline || !candidate) throw Error('Usage: node electron/startup.mjs --baseline=/frozen/dist --candidate=/new/dist [--baseline-electron=/old/electron] [--candidate-electron=/new/electron] [--runs=5] [--report=output.json]');
const runs = Number(argument('runs') || 5);
if (!Number.isInteger(runs) || runs < 1 || runs > 20) throw Error('runs must be an integer from 1 through20');
const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'shenzhen-startup-'));
const environment = {...process.env};
delete environment.SHENZHEN_3D_DEV_URL;
const rows = [];
try {
  const packageMetadata = JSON.parse(await fs.readFile('package.json', 'utf8'));
  // Each variant's main-process code: this checkout's electron/ unless --baseline-electron or --candidate-electron
  // names another one (an earlier checkout's electron/), so main-process changes are measured too.
  const electronSources = {baseline: argument('baseline-electron') || 'electron', candidate: argument('candidate-electron') || 'electron'};
  const copyRuntime = async (from, to) => {
    for (const entry of await fs.readdir(from, {withFileTypes: true})) {
      if (entry.isDirectory() && !['native', 'installer'].includes(entry.name)) await copyRuntime(path.join(from, entry.name), path.join(to, entry.name));
      else if (entry.isFile() && entry.name.endsWith('.cjs') && !entry.name.endsWith('.test.cjs')) {
        await fs.mkdir(to, {recursive: true});
        await fs.copyFile(path.join(from, entry.name), path.join(to, entry.name));
      }
    }
  };
  for (const [name, dist] of [['baseline', baseline], ['candidate', candidate]]) {
    const root = path.join(directory, name);
    await copyRuntime(path.resolve(electronSources[name]), path.join(root, 'electron'));
    // main.cjs requires electron-updater; link the installed dependencies.
    await fs.symlink(path.resolve('node_modules'), path.join(root, 'node_modules'), 'dir');
    await fs.writeFile(path.join(root, 'package.json'), JSON.stringify({name: 'shenzhen-startup-probe', version: packageMetadata.version, main: 'electron/main.cjs'}));
    await fs.symlink(path.resolve(dist), path.join(root, 'dist'), 'dir');
  }
  // Alternate the order to spread filesystem/OS warmup across both variants.
  for (let run = 0; run < runs; run++) for (const variant of run % 2 ? ['candidate', 'baseline'] : ['baseline', 'candidate']) {
    const started = performance.now();
    const application = await electron.launch({args: [path.join(directory, variant, 'electron/main.cjs'), `--user-data-dir=${path.join(directory, `profile-${variant}-${run}`)}`], env: environment});
    try {
      const page = await application.firstWindow();
      const errors = [];
      page.on('pageerror', error => errors.push(error.message));
      await expect(page.locator('header').getByRole('button', {name: /^Open file/})).toBeEnabled();
      const openReadyMs = performance.now() - started;
      await page.bringToFront();
      await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
      const paintedWelcomeMs = performance.now() - started;
      const metrics = await page.evaluate(() => ({canvasCount: document.querySelectorAll('.viewport-canvas canvas').length, usedJSHeapBytes: performance.memory?.usedJSHeapSize, domContentLoadedMs: performance.getEntriesByType('navigation')[0]?.domContentLoadedEventEnd, firstContentfulPaintMs: performance.getEntriesByName('first-contentful-paint')[0]?.startTime, resourcePaths: performance.getEntriesByType('resource').map(resource => new URL(resource.name).pathname)}));
      expect(page.url()).toBe('app://local/');
      expect(errors).toEqual([]);
      if (variant === 'candidate') expect(metrics.canvasCount).toBe(0);
      rows.push({variant, run: run + 1, openReadyMs, paintedWelcomeMs, ...metrics});
      console.log(JSON.stringify({variant, run: run + 1, openReadyMs: Math.round(openReadyMs), paintedWelcomeMs: Math.round(paintedWelcomeMs), canvasCount: metrics.canvasCount}));
    } finally { await application.close(); }
  }
  const median = numbers => [...numbers].sort((a, b) => a - b)[Math.floor(numbers.length / 2)];
  const summary = Object.fromEntries(['baseline', 'candidate'].map(variant => {
    const values = rows.filter(row => row.variant === variant);
    return [variant, {runs: values.length, medianOpenReadyMs: median(values.map(row => row.openReadyMs)), medianPaintedWelcomeMs: median(values.map(row => row.paintedWelcomeMs)), medianUsedJSHeapBytes: median(values.map(row => row.usedJSHeapBytes)), initialCanvasCount: values[0].canvasCount}];
  }));
  const report = {date: new Date().toISOString(), method: 'Same production app protocol and Electron shell; fresh userData per launch; alternating paired order; Open enabled and two animation frames measured. Asset bytes and OS filesystem cache are warm across repetitions.', summary, runs: rows};
  if (argument('report')) await fs.writeFile(argument('report'), JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify(summary, null, 2));
} finally { await fs.rm(directory, {recursive: true, force: true}); }
