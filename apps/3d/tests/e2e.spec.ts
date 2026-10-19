import {test, expect, type Page, type Download} from '@playwright/test';
import {resolve} from 'node:path';
import {geometryLocations, pickAt, showInspector} from './support/e2e-helpers';

const fixture = resolve('fixtures/sample-assembly.step');
type ErrorAwarePage = Page & {applicationErrors: string[]; expectedApplicationErrors?: RegExp[]};

test.beforeEach(async ({page}) => {
  const errors: string[] = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('console', message => {if (message.type() === 'error') errors.push(message.text());});
  await page.goto('/');
  await expect(page.locator('header').getByRole('button', {name: /^Open file/})).toBeEnabled();
  await expect(page.getByRole('button', {name: 'Sample model', exact: true})).toBeEnabled();
  await expect(page.locator('.viewport-canvas canvas')).toHaveCount(0);
  (page as ErrorAwarePage).applicationErrors = errors;
});

test.afterEach(async ({page}, info) => {
  const errors = (page as ErrorAwarePage).applicationErrors || [];
  await info.attach('application-errors', {body: JSON.stringify(errors, null, 2), contentType: 'application/json'});
  const expected = (page as ErrorAwarePage).expectedApplicationErrors || [];
  expect(errors.filter(error => !expected.some(pattern => pattern.test(error))), 'No unexpected application or console errors').toEqual([]);
});

test('welcome Open works before graphics initialize and an empty chooser leaves it idle', async ({page}) => {
  const chooser = page.waitForEvent('filechooser');
  await page.locator('header').getByRole('button', {name: /^Open file/}).click();
  await (await chooser).setFiles([]);
  await expect(page.locator('.viewport-canvas canvas')).toHaveCount(0);
  await expect(page.getByRole('button', {name: 'Sample model', exact: true})).toBeEnabled();
  await expect(page.getByRole('alert')).toHaveCount(0);
  const startupResources = await page.evaluate(() => performance.getEntriesByType('resource').map(entry => new URL(entry.name).pathname));
  expect(startupResources.filter(name => /(?:model-runtime|three\.core|project-file|ray-tracing)[.-]/.test(name)), 'Welcome does not fetch geometry, ZIP or ray-tracing modules').toEqual([]);
});

test('canceled delayed import cannot overwrite a later model', async ({page}) => {
  await page.evaluate(() => {
    const original = File.prototype.arrayBuffer;
    const state = window as typeof window & {delayedReadStarted?: boolean; delayedReadFinished?: boolean; releaseDelayedRead?: () => void};
    File.prototype.arrayBuffer = async function() {
      if (this.name === 'delayed-cancel.stl') {
        state.delayedReadStarted = true;
        await new Promise<void>(resolve => { state.releaseDelayedRead = resolve; });
        const bytes = await original.call(this);
        state.delayedReadFinished = true;
        return bytes;
      }
      return original.call(this);
    };
  });
  const triangle = Buffer.from('solid test\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 1 0 0\nvertex 0 1 0\nendloop\nendfacet\nendsolid test\n');
  await page.locator('input[type=file]').setInputFiles({name: 'delayed-cancel.stl', mimeType: 'model/stl', buffer: triangle});
  await page.waitForFunction(() => (window as typeof window & {delayedReadStarted?: boolean}).delayedReadStarted);
  await page.getByRole('button', {name: 'Cancel import', exact: true}).click();
  await expect(page.getByRole('alert')).toContainText('Import canceled');
  await page.locator('input[type=file]').setInputFiles({name: 'replacement.stl', mimeType: 'model/stl', buffer: triangle});
  await expect(page.locator('header')).toContainText('replacement.stl');
  await expect(page.locator('.model-badge')).toContainText('1 part');
  await page.evaluate(async () => {
    (window as typeof window & {releaseDelayedRead?: () => void}).releaseDelayedRead!();
    await new Promise<void>(resolve => requestAnimationFrame(() => requestAnimationFrame(() => resolve())));
  });
  await page.waitForFunction(() => (window as typeof window & {delayedReadFinished?: boolean}).delayedReadFinished);
  await expect(page.locator('.model-badge')).toContainText('1 part');
  await expect(page.locator('header')).toContainText('replacement.stl');
  await expect(page.getByRole('alert')).toHaveCount(0);
  await expect(page.getByRole('button', {name: 'Cancel import', exact: true})).toHaveCount(0);
  await expect(page.locator('.viewport-canvas canvas')).toHaveCount(1);
});

test('failed lazy runtime fetch leaves Open usable and a second sample request recovers', async ({page, context}) => {
  const session = await context.newCDPSession(page);
  await session.send('Network.enable');
  await session.send('Network.setBypassServiceWorker', {bypass: true});
  await page.reload();
  (page as ErrorAwarePage).expectedApplicationErrors = [/Failed to load resource: net::ERR_FAILED/];
  await page.route(/\/(?:assets\/model-runtime-[^/]+\.js|src\/core\/model-runtime\.ts)(?:\?|$)/, route => route.abort('failed'), {times: 1});
  await page.getByRole('button', {name: 'Sample model', exact: true}).click();
  await expect(page.getByRole('alert')).toContainText(/Failed to fetch|module script|dynamically imported/i);
  await expect(page.locator('.viewport-canvas canvas')).toHaveCount(0);
  await expect(page.locator('header').getByRole('button', {name: /^Open file/})).toBeEnabled();
  // A long download error overlaps the sample action on narrow screens.
  await page.getByRole('button', {name: 'Dismiss error', exact: true}).click();
  await page.getByRole('button', {name: 'Sample model', exact: true}).click();
  await expect(page.locator('.model-badge')).toContainText('4 parts');
  await expect(page.locator('.viewport-canvas canvas')).toHaveCount(1);
  await expect(page.getByRole('alert')).toHaveCount(0);
});

test('graphics initialization failure stops the spinner and a later import retries', async ({page}) => {
  await page.evaluate(() => {
    const original = HTMLCanvasElement.prototype.getContext;
    const state = window as typeof window & {rejectTestGraphics?: boolean};
    state.rejectTestGraphics = true;
    HTMLCanvasElement.prototype.getContext = function(kind: string, options?: unknown) {
      if (state.rejectTestGraphics && /^(webgl2?|experimental-webgl)$/.test(kind)) return null;
      return original.call(this, kind, options);
    } as typeof original;
  });
  (page as ErrorAwarePage).expectedApplicationErrors = [/THREE\.WebGLRenderer: Error creating WebGL context/];
  await page.getByRole('button', {name: 'Sample model', exact: true}).click();
  await expect(page.getByRole('alert')).toContainText(/WebGL context/);
  await expect(page.getByRole('heading', {name: 'Starting 3D viewer…', exact: true})).toHaveCount(0);
  await expect(page.locator('.viewport-canvas canvas')).toHaveCount(0);
  await expect(page.locator('header').getByRole('button', {name: /^Open file/})).toBeEnabled();
  await page.evaluate(() => { (window as typeof window & {rejectTestGraphics?: boolean}).rejectTestGraphics = false; });
  await page.locator('input[type=file]').setInputFiles({name: 'graphics-retry.stl', mimeType: 'model/stl', buffer: Buffer.from('solid retry\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 1 0 0\nvertex 0 1 0\nendloop\nendfacet\nendsolid retry\n')});
  await expect(page.locator('.viewport-canvas canvas')).toHaveCount(1);
  await expect(page.locator('header')).toContainText('graphics-retry.stl');
  await expect(page.getByRole('alert')).toHaveCount(0);
});

async function downloadText(download: Download) {
  const stream = await download.createReadStream();
  expect(stream).toBeTruthy();
  const chunks: Buffer[] = [];
  for await (const chunk of stream!) chunks.push(Buffer.from(chunk));
  return Buffer.concat(chunks).toString('utf8');
}

test('STEP import, real surface picks, unit overrides, saved JSON/CSV and exact feature query', async ({page, isMobile}) => {
  await page.locator('input[type=file]').setInputFiles(fixture);
  await expect(page.locator('.model-badge')).toContainText('CAD model', {timeout: 120_000});
  await expect(page.getByRole('alert')).toHaveCount(0);
  const locations = await geometryLocations(page);
  await pickAt(page, locations[0], isMobile);
  await expect(page.locator('.point-row.filled')).toHaveCount(1);
  await pickAt(page, locations[1], isMobile);
  await expect(page.locator('.point-row.filled')).toHaveCount(2);
  const result = page.locator('.result-hero strong');
  await expect(result).toBeVisible();
  const millimeters = Number((await result.innerText()).replaceAll(',', ''));
  expect(millimeters).toBeGreaterThan(0);
  await expect(page.locator('.accuracy-tag')).toContainText(/Picked-point measurement|Exact CAD geometry/);
  await page.getByLabel('Display units', {exact: true}).selectOption('cm');
  await expect.poll(async () => Number((await result.innerText()).replaceAll(',', ''))).toBeCloseTo(millimeters / 10, 2);
  await page.getByLabel('Display units', {exact: true}).selectOption('mm');
  await page.locator('.units-details summary').click();
  await page.getByLabel('Source units', {exact: true}).selectOption('in');
  await page.getByLabel('Custom scale factor', {exact: true}).fill('2');
  await expect.poll(async () => Number((await result.innerText()).replaceAll(',', ''))).toBeCloseTo(millimeters * 50.8, 0);
  await page.getByRole('button', {name: 'Save measurement', exact: true}).click();
  await page.getByRole('button', {name: 'Saved 1', exact: true}).click();
  await expect(page.locator('.saved-measurement')).toHaveCount(1);
  const jsonWait = page.waitForEvent('download');
  await page.getByRole('button', {name: 'JSON', exact: true}).click();
  const report = JSON.parse(await downloadText(await jsonWait));
  expect(report).toMatchObject({file: 'sample-assembly.step', sourceUnit: 'in', customScale: 2, displayUnit: 'mm'});
  expect(report.measurements).toHaveLength(1);
  expect(report.measurements[0].displayDistance).toBeCloseTo(report.measurements[0].distance * 50.8, 8);
  const csvWait = page.waitForEvent('download');
  await page.getByRole('button', {name: 'CSV', exact: true}).click();
  const csv = await downloadText(await csvWait);
  expect(csv).toContain('"Distance (mm)"');
  expect(csv).toContain('"Distance 1"');
  expect(csv).toContain(String(report.measurements[0].displayDistance));
  await page.locator('.saved-measurement > button').first().click();
  await expect(page.locator('.point-row.filled')).toHaveCount(2);
  await page.getByTitle('Pick CAD features · E', {exact: true}).click();
  await expect(page.locator('.point-row.filled')).toHaveCount(0);
  await page.getByLabel('Feature selection filter').selectOption('face');
  await pickAt(page, locations[0], isMobile);
  await expect(page.locator('.feature-properties .subheading')).toContainText('Exact', {timeout: 60_000});
  await expect(page.locator('.feature-properties')).toContainText('Area');
  await expect(page.locator('.point-row small').first()).toContainText('CAD face');
  await pickAt(page, locations[1], isMobile);
  await expect(page.locator('.accuracy-tag')).toContainText('Exact CAD geometry', {timeout: 60_000});
  await expect(page.locator('.measurement-note')).toContainText('Exact minimum distance between CAD features');
  await page.getByLabel('Distance reference', {exact: true}).selectOption('center');
  await expect(page.locator('.point-row.filled')).toHaveCount(0);
  await pickAt(page, locations[0], isMobile);
  await pickAt(page, locations[1], isMobile);
  await expect(page.locator('.result-hero')).toContainText('CENTER DISTANCE', {timeout: 60_000});
  await expect(page.locator('.accuracy-tag')).toContainText('Exact CAD geometry');
  await expect(page.locator('.measurement-note')).toContainText('Distance between feature centers / centroids');
  const centerDistance = Number((await result.innerText()).replaceAll(',', ''));
  expect(Number.isFinite(centerDistance)).toBe(true);
  expect(centerDistance).toBeGreaterThan(0);
  await page.getByRole('button', {name: 'Clear measurement', exact: false}).click();
  await expect(page.locator('.point-row.filled')).toHaveCount(0);
});

test('sample assembly visibility, isolate, point angle, and saved deletion', async ({page, isMobile}) => {
  await page.getByRole('button', {name: 'Sample model', exact: true}).click();
  await expect(page.locator('.model-badge')).toContainText('4 parts');
  const openAssembly = page.getByRole('button', {name: 'Show assembly', exact: true});
  if (await openAssembly.isVisible()) await openAssembly.click();
  await page.getByLabel('Search assembly', {exact: true}).fill('Base plate');
  await expect(page.getByRole('treeitem')).toHaveCount(1);
  await page.getByRole('button', {name: 'Hide Base plate · 80 × 56 × 6', exact: true}).click();
  await expect(page.getByRole('treeitem')).toHaveClass(/muted/);
  await page.getByRole('button', {name: 'Show Base plate · 80 × 56 × 6', exact: true}).click();
  await expect(page.getByRole('treeitem')).not.toHaveClass(/muted/);
  await page.getByRole('button', {name: 'Isolate Base plate · 80 × 56 × 6', exact: true}).click();
  await page.getByLabel('Search assembly', {exact: true}).fill('');
  await expect(page.locator('.tree-row.muted')).toHaveCount(3);
  await page.getByRole('button', {name: 'Show all', exact: true}).click();
  await expect(page.locator('.tree-row.muted')).toHaveCount(0);
  const closeAssembly = page.getByRole('button', {name: 'Close assembly', exact: true});
  if (await closeAssembly.isVisible()) await closeAssembly.click();
  const locations = await geometryLocations(page);
  await showInspector(page);
  await page.getByRole('button', {name: 'Angle', exact: true}).click();
  await pickAt(page, locations[0], isMobile);
  await pickAt(page, locations[1], isMobile);
  await pickAt(page, locations[2], isMobile);
  await expect(page.locator('.point-row.filled')).toHaveCount(3);
  await expect(page.locator('.result-hero')).toContainText('ANGLE');
  const angle = Number(await page.locator('.result-hero strong').innerText());
  expect(angle).toBeGreaterThan(0);
  expect(angle).toBeLessThan(180);
  await page.getByRole('button', {name: 'Save measurement', exact: true}).click();
  await page.getByRole('button', {name: 'Saved 1', exact: true}).click();
  await page.getByRole('button', {name: 'Delete measurement', exact: true}).click();
  await expect(page.locator('.saved-measurement')).toHaveCount(0);
  await expect(page.getByText('No saved measurements', {exact: true})).toBeVisible();
});

test('desktop section, orthographic projection, display tools and PNG export', async ({page, isMobile}) => {
  test.skip(isMobile, 'These controls are hidden by the mobile responsive toolbar.');
  await page.getByRole('button', {name: 'Sample model', exact: true}).click();
  await expect(page.locator('.model-badge')).toContainText('4 parts');
  await page.getByRole('button', {name: 'Perspective', exact: true}).click();
  await expect(page.getByRole('button', {name: 'Orthographic', exact: true})).toBeVisible();
  await page.getByTitle('Top · Shift 5', {exact: true}).click();
  await page.getByRole('button', {name: 'Show edges', exact: true}).click();
  await expect(page.getByRole('button', {name: 'Show edges', exact: true})).toHaveAttribute('aria-pressed', 'true');
  await page.getByLabel('Explode assembly', {exact: true}).fill('0.25');
  await expect(page.getByLabel('Explode assembly', {exact: true})).toHaveValue('0.25');
  await page.getByRole('button', {name: 'Ground grid', exact: true}).click();
  await expect(page.getByRole('button', {name: 'Ground grid', exact: true})).toHaveAttribute('aria-pressed', 'false');
  await page.getByRole('button', {name: 'Section plane', exact: true}).click();
  await expect(page.getByLabel('Section position', {exact: true})).toBeVisible();
  await page.getByLabel('Section axis', {exact: true}).selectOption('x');
  await page.getByLabel('Section position', {exact: true}).fill('0.35');
  await expect(page.getByLabel('Section position', {exact: true})).toHaveValue('0.35');
  // Verify the instanced edge shader actually draws after explode + clipping,
  // rather than merely checking the toolbar toggle and console errors.
  await page.getByRole('button', {name: 'Show edges', exact: true}).click();
  const withoutEdges = await page.locator('canvas').screenshot();
  await page.getByRole('button', {name: 'Show edges', exact: true}).click();
  const withEdges = await page.locator('canvas').screenshot();
  const edgePixels = await page.evaluate(async ({before, after}) => {
    const readPixels = async (png: string) => {
      const image = new Image();
      image.src = `data:image/png;base64,${png}`;
      await image.decode();
      const canvas = document.createElement('canvas');
      canvas.width = image.naturalWidth;
      canvas.height = image.naturalHeight;
      const context = canvas.getContext('2d')!;
      context.drawImage(image, 0, 0);
      return context.getImageData(0, 0, canvas.width, canvas.height);
    };
    const a = await readPixels(before), b = await readPixels(after);
    let changed = 0, visible = 0;
    // Ignore controls along the canvas boundary and compare rendered content.
    for (let y = 80; y < a.height - 80; y++) for (let x = 20; x < a.width - 20; x++) {
      const i = (y * a.width + x) * 4;
      if (Math.max(Math.abs(a.data[i] - b.data[i]), Math.abs(a.data[i + 1] - b.data[i + 1]), Math.abs(a.data[i + 2] - b.data[i + 2])) > 12) changed++;
      if (b.data[i] > 75 && b.data[i + 1] > 75 && b.data[i + 2] > 75) visible++;
    }
    return {changed, visible};
  }, {before: withoutEdges.toString('base64'), after: withEdges.toString('base64')});
  expect(edgePixels.visible, 'Exploded section still renders model surfaces').toBeGreaterThan(20);
  expect(edgePixels.changed, 'Instanced edges add visible pixels to the exploded section').toBeGreaterThan(20);
  const pngWait = page.waitForEvent('download');
  await page.getByRole('button', {name: 'Save screenshot', exact: true}).click();
  const screenshot = await pngWait;
  expect(screenshot.suggestedFilename()).toMatch(/\.png$/);
  const stream = await screenshot.createReadStream();
  const chunks: Buffer[] = [];
  for await (const chunk of stream!) chunks.push(Buffer.from(chunk));
  const png = Buffer.concat(chunks);
  expect(png.subarray(0, 8).toString('hex')).toBe('89504e470d0a1a0a');
  expect(png.length).toBeGreaterThan(1000);
  await page.getByRole('button', {name: 'Close section', exact: true}).click();
  await expect(page.getByLabel('Section position', {exact: true})).toHaveCount(0);
  await page.getByRole('button', {name: 'Orthographic', exact: true}).click();
  await expect(page.getByRole('button', {name: 'Perspective', exact: true})).toBeVisible();
});

test('mobile view settings expose section, projection, opacity and assembly explode', async ({page, isMobile}) => {
  test.skip(!isMobile, 'Mobile toolbar uses the settings dialog for view controls.');
  await page.getByRole('button', {name: 'Sample model', exact: true}).click();
  await page.getByRole('button', {name: 'Settings', exact: true}).click();
  const settings = page.getByRole('dialog');
  await settings.getByRole('button', {name: 'Orthographic', exact: true}).click();
  await expect(settings.getByRole('button', {name: 'Orthographic', exact: true})).toHaveClass('active');
  await page.getByLabel('Settings opacity', {exact: true}).fill('0.5');
  await expect(page.getByLabel('Settings opacity', {exact: true})).toHaveValue('0.5');
  await page.getByLabel('Settings explode', {exact: true}).fill('0.25');
  await expect(page.getByLabel('Settings explode', {exact: true})).toHaveValue('0.25');
  await settings.getByRole('button', {name: 'Section', exact: true}).click();
  await expect(settings).not.toBeVisible();
  await expect(page.getByLabel('Section axis', {exact: true})).toBeVisible();
  await page.getByLabel('Section axis', {exact: true}).selectOption('y');
  await page.getByLabel('Section position', {exact: true}).fill('0.25');
  await page.getByRole('button', {name: 'Close section', exact: true}).click();
  await expect(page.getByLabel('Section position', {exact: true})).toHaveCount(0);
});

test('mesh circular cap reports approximate diameter and coplanar area', async ({page, isMobile}) => {
  await page.getByRole('button', {name: 'Sample model', exact: true}).click();
  await expect(page.locator('.model-badge')).toBeVisible();
  const openAssembly = page.getByRole('button', {name: 'Show assembly', exact: true});
  if (await openAssembly.isVisible()) await openAssembly.click();
  await page.getByLabel('Search assembly', {exact: true}).fill('Fastener');
  await expect(page.getByRole('treeitem')).toHaveCount(2);
  await page.getByRole('button', {name: 'Isolate Fastener · Ø10', exact: true}).first().click();
  await page.getByRole('button', {name: 'Hide assembly', exact: true}).click();
  await page.getByTitle('Pick CAD features · E', {exact: true}).click();
  await page.getByLabel('Feature selection filter').selectOption('face');
  const locations = await geometryLocations(page);
  await pickAt(page, locations[2], isMobile);
  await expect(page.getByRole('button', {name: 'Measure', exact: true}), 'A geometry tap opens Measure without activating a newly appeared sheet control').toHaveClass('selected');
  const properties = page.locator('.feature-properties');
  await expect(properties).toContainText('Approx.');
  const diameter = properties.locator('.metric').filter({hasText: 'Diameter'}).locator('strong');
  const area = properties.locator('.metric').filter({hasText: 'Area'}).locator('strong');
  await expect(diameter).toHaveText('10.000');
  // A 32-segment mesh cap has polygon area 78.036 mm² rather than πr².
  expect(Number(await area.innerText())).toBeCloseTo(78.036, 2);
});

test('production app reloads and imports STEP after the network goes offline', async ({page, context}) => {
  const response = await page.request.get('/sw.js');
  test.skip(!response.ok() || !(await response.text()).includes('shenzhen-3d-'), 'Offline precaching is generated by the production build.');
  await page.evaluate(async () => {
    await navigator.serviceWorker.ready;
    if (!navigator.serviceWorker.controller) {
      await new Promise<void>(resolve => navigator.serviceWorker.addEventListener('controllerchange', () => resolve(), {once: true}));
    }
  });
  const cached = await page.evaluate(async () => {
    const names = (await caches.keys()).filter(name => name.startsWith('shenzhen-3d-'));
    return (await Promise.all(names.map(async name => (await (await caches.open(name)).keys()).map(request => request.url)))).flat();
  });
  expect(cached.some(url => url.endsWith('/index.html'))).toBe(true);
  expect(cached.some(url => url.endsWith('.wasm'))).toBe(true);
  await context.setOffline(true);
  try {
    await page.reload({waitUntil: 'domcontentloaded'});
    await expect(page.getByRole('button', {name: 'Sample model', exact: true})).toBeVisible();
    await page.locator('input[type=file]').setInputFiles(fixture);
    await expect(page.locator('.model-badge')).toContainText('CAD model', {timeout: 120_000});
    await expect(page.locator('.model-badge')).toContainText('3,154 parts');
    await expect(page.getByRole('alert')).toHaveCount(0);
  } finally {
    await context.setOffline(false);
  }
});

test('portable review projects preserve point, feature and part notes with editable anchors', async ({page, isMobile}) => {
  await page.getByRole('button', {name: 'Sample model'}).click();
  const locations = await geometryLocations(page);
  for (const [index, scope, text] of [
    [0, 'point', 'Check clearance at this point.'],
    [1, 'feature', 'Keep this face free of coating.'],
    [2, 'part', 'Supplier approval required for this part.'],
  ] as const) {
    await showInspector(page);
    await page.getByRole('button', {name: /^Notes/}).click();
    await page.getByRole('button', {name: 'Add note', exact: true}).click();
    await page.getByLabel('Annotation target').selectOption(scope);
    await pickAt(page, locations[index], isMobile);
    await expect(page.locator('.note-anchor.attached')).toBeVisible();
    await page.getByLabel('Annotation text', {exact: true}).fill(text);
    await page.getByRole('button', {name: 'Save note', exact: true}).click();
    await expect(page.locator('.review-note')).toHaveCount(index + 1);
  }
  await expect(page.locator('.review-pin')).toHaveCount(3);
  await page.screenshot({path: `artifacts/review-${isMobile ? 'mobile' : 'desktop'}.png`});
  await page.getByRole('button', {name: 'Edit note 1', exact: true}).click();
  await page.getByLabel('Edit annotation text').fill('Revised clearance: check with the mating part.');
  await page.getByRole('button', {name: 'Save changes', exact: true}).click();
  await page.locator('.review-note').nth(1).getByRole('button', {name: 'Resolve', exact: true}).click();
  await expect(page.locator('.review-pin')).toHaveCount(2);
  await page.getByLabel('Show resolved').check();
  await expect(page.locator('.review-note.resolved')).toHaveCount(1);
  await page.getByRole('button', {name: 'Measure', exact: true}).click();
  await page.locator('.units-details summary').click();
  await page.getByLabel('Source units', {exact: true}).selectOption('cm');
  await page.getByLabel('Custom scale factor').fill('2.5');
  await page.evaluate(() => Object.defineProperty(navigator, 'canShare', {configurable: true, value: () => false}));
  const downloadPromise = page.waitForEvent('download');
  await page.locator('header').getByRole('button', {name: 'Share commented project', exact: true}).click();
  const download = await downloadPromise;
  expect(download.suggestedFilename()).toMatch(/\.sz3d$/);
  const stream = await download.createReadStream();
  const chunks: Buffer[] = [];
  for await (const chunk of stream!) chunks.push(Buffer.from(chunk));
  await page.reload();
  await page.locator('input[type=file]').setInputFiles({name: download.suggestedFilename(), mimeType: 'application/octet-stream', buffer: Buffer.concat(chunks)});
  await expect(page.locator('.review-note')).toHaveCount(2);
  await expect(page.locator('.review-note').first()).toContainText('Revised clearance');
  await expect(page.locator('.review-pin')).toHaveCount(2);
  await expect(page.getByRole('alert')).toHaveCount(0);
  await page.getByLabel('Show resolved').check();
  await expect(page.locator('.review-note')).toHaveCount(3);
  await page.getByRole('button', {name: 'Focus note 3', exact: true}).click();
  await expect(page.locator('.review-pin.selected')).toHaveCount(1);
  await page.getByRole('button', {name: 'Measure', exact: true}).click();
  await page.locator('.units-details summary').click();
  await expect(page.getByLabel('Source units', {exact: true})).toHaveValue('cm');
  await expect(page.getByLabel('Custom scale factor')).toHaveValue('2.5');
});

test('render styles and lighting are available in desktop and touch settings', async ({page}) => {
  await page.getByRole('button', {name: 'Sample model'}).click();
  await page.getByRole('button', {name: 'Settings', exact: true}).click();
  await page.getByLabel('Settings render style').selectOption('hidden-line');
  await page.getByLabel('Light direction', {exact: true}).fill('120');
  await page.getByLabel('Light elevation', {exact: true}).fill('25');
  await page.getByLabel('Uniform fill light', {exact: true}).check();
  await page.getByLabel('Uniform light intensity', {exact: true}).fill('1.5');
  await page.getByRole('button', {name: 'Done', exact: true}).click();
  await expect(page.locator('canvas').first()).toBeVisible();
  await page.getByRole('button', {name: 'Settings', exact: true}).click();
  await expect(page.getByLabel('Settings render style')).toHaveValue('hidden-line');
  await expect(page.getByLabel('Light direction', {exact: true})).toHaveValue('120');
  await expect(page.getByLabel('Uniform fill light', {exact: true})).toBeChecked();
  await page.getByLabel('Settings render style').selectOption('shaded');
  await page.getByRole('button', {name: 'Reset lighting', exact: true}).click();
  await expect(page.getByLabel('Uniform fill light', {exact: true})).not.toBeChecked();
});

test('CAD review bundle carries the original STEP and exact saved measurements', async ({page, isMobile}) => {
  await page.locator('input[type=file]').setInputFiles(fixture);
  await expect(page.locator('.model-badge')).toContainText('CAD model', {timeout: 120_000});
  const locations = await geometryLocations(page);
  await page.getByTitle('Pick CAD features · E', {exact: true}).click();
  await page.getByLabel('Feature selection filter').selectOption('face');
  await pickAt(page, locations[0], isMobile);
  await pickAt(page, locations[1], isMobile);
  await expect(page.locator('.accuracy-tag')).toContainText('Exact CAD geometry', {timeout: 60_000});
  const distance = await page.locator('.result-hero strong').innerText();
  await page.getByRole('button', {name: 'Save measurement', exact: true}).click();
  await page.getByRole('button', {name: /^Notes/}).click();
  await page.getByRole('button', {name: 'Add note', exact: true}).click();
  await page.getByLabel('Annotation target').selectOption('feature');
  await pickAt(page, locations[0], isMobile);
  await expect(page.locator('.note-anchor.attached')).toContainText('face');
  await page.getByLabel('Annotation text', {exact: true}).fill('Verify this CAD face before manufacturing.');
  await page.getByRole('button', {name: 'Save note', exact: true}).click();
  await page.evaluate(() => Object.defineProperty(navigator, 'canShare', {configurable: true, value: () => false}));
  const wait = page.waitForEvent('download');
  await page.locator('header').getByRole('button', {name: 'Share commented project', exact: true}).click();
  const download = await wait, stream = await download.createReadStream(), chunks: Buffer[] = [];
  for await (const chunk of stream!) chunks.push(Buffer.from(chunk));
  await page.reload();
  await page.locator('input[type=file]').setInputFiles({name: download.suggestedFilename(), mimeType: 'application/octet-stream', buffer: Buffer.concat(chunks)});
  await expect(page.locator('.model-badge')).toContainText('CAD model', {timeout: 120_000});
  await expect(page.locator('.review-note')).toHaveCount(1);
  await expect(page.locator('.review-note')).toContainText('Verify this CAD face');
  await expect(page.locator('.note-location small')).toContainText('face');
  await expect(page.getByRole('alert')).toHaveCount(0);
  await page.getByRole('button', {name: 'Saved 1', exact: true}).click();
  await page.locator('.saved-measurement > button').first().click();
  await expect(page.locator('.result-hero strong')).toHaveText(distance);
  await expect(page.locator('.accuracy-tag')).toContainText('Exact CAD geometry');
});

test('ray tracing reports unsupported devices and keeps the normal viewer usable', async ({page}) => {
  await page.addInitScript(() => Object.defineProperty(navigator, 'gpu', {configurable: true, value: undefined}));
  await page.reload();
  await page.getByRole('button', {name: 'Sample model'}).click();
  await page.getByRole('button', {name: 'Settings', exact: true}).click();
  await page.getByLabel('GPU ray tracing', {exact: true}).check();
  await expect(page.locator('.raytrace-controls')).toContainText('requires WebGPU', {timeout: 20_000});
  await page.getByLabel('GPU ray tracing', {exact: true}).uncheck();
  await page.getByRole('button', {name: 'Done', exact: true}).click();
  await expect(page.locator('.ray-status-badge')).toHaveCount(0);
  await page.getByRole('button', {name: 'Fit model', exact: true}).click();
  await expect(page.locator('canvas').first()).toBeVisible();
});

test('recent files return after closing a document and reopen without retaining a renderer', async ({page}) => {
  const recent = page.getByRole('region', {name:'Recent files'});
  await expect(recent).toBeVisible();
  await expect(recent.getByRole('button')).toHaveCount(0);
  const triangle = Buffer.from('solid recent\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 1 0 0\nvertex 0 1 0\nendloop\nendfacet\nendsolid recent\n');
  await page.locator('input[type=file]').setInputFiles({name:'recent-part.stl',mimeType:'model/stl',buffer:triangle});
  await expect(page.locator('.model-badge')).toContainText('1 part');
  await page.getByRole('button',{name:'Close document',exact:true}).click();
  await expect(page.locator('.viewport-canvas canvas')).toHaveCount(0);
  await expect(recent).toBeVisible();
  await recent.getByRole('button',{name:/recent-part.stl/}).click();
  await expect(page.locator('.model-badge')).toContainText('1 part');
  await page.getByRole('button',{name:'Close document',exact:true}).click();
  await page.reload();
  await expect(recent.getByRole('button',{name:/recent-part.stl/})).toBeVisible();
  await expect(page.locator('.viewport-canvas canvas')).toHaveCount(0);
  const resources = await page.evaluate(() => performance.getEntriesByType('resource').map(item=>item.name));
  expect(resources.some(name=>/(?:model-runtime|three\.core)[.-]/.test(name))).toBe(false);
  let chooserOpened = false;
  page.on('filechooser', () => { chooserOpened = true; });
  await recent.getByRole('button',{name:/recent-part.stl/}).click();
  await expect(page.locator('.model-badge')).toContainText('1 part');
  expect(chooserOpened, 'Recent file reopens after reload without a chooser').toBe(false);
  await page.locator('input[type=file]').setInputFiles({name:'second-part.stl',mimeType:'model/stl',buffer:triangle});
  await expect(page.locator('header')).toContainText('second-part.stl');
  await page.getByRole('button',{name:'Close document',exact:true}).click();
  await expect(recent.getByRole('button',{name:/second-part.stl/})).toBeVisible();
  await recent.getByRole('button',{name:/recent-part.stl/}).click();
  await expect(page.locator('header')).toContainText('recent-part.stl');
  await expect(page.locator('.model-badge')).toContainText('1 part');
  expect(chooserOpened, 'Earlier recent survives opening another model').toBe(false);
});

test('fixed view controls replace old preset and device settings after reload', async ({page,isMobile}) => {
  await page.evaluate(() => localStorage.setItem('shenzhen-preferences', JSON.stringify({navigation:'trackpad',navigationVersion:3,navigationStyle:'solidworks',reverseWheelZoom:true})));
  await page.reload();
  await page.getByRole('button', {name:'Settings',exact:true}).click();
  await expect(page.getByLabel('Input device', {exact:true})).toHaveCount(0);
  await expect(page.getByLabel('Navigation style', {exact:false})).toHaveCount(0);
  await expect(page.getByLabel('Reverse scroll zoom')).toHaveCount(0);
  await expect(page.getByLabel('Navigation detail', {exact:true})).toBeVisible();
  await page.getByRole('button', {name:'Done',exact:true}).click();
  if (!isMobile) {
    await page.getByTitle('Help & shortcuts', {exact:true}).click();
    const help = page.locator('dialog[open]');
    await expect(help).toContainText('two-finger click-drag on a trackpad) around the current view center');
    await expect(help).toContainText('right-drag or two-finger click-drag while holding');
    await expect(help).toContainText('Left-drag or middle-drag');
    await expect(help).toContainText('two-finger trackpad swipe while holding');
    await expect(help).toContainText('Two-finger trackpad swipe · mouse wheel · pinch');
    await expect(help).not.toContainText('Ctrl+middle-drag');
    await page.getByTitle('Close help', {exact:true}).click();
  }
  await expect.poll(() => page.evaluate(() => JSON.parse(localStorage.getItem('shenzhen-preferences') || '{}'))).toMatchObject({navigation:'auto',navigationVersion:4});
  const saved = await page.evaluate(() => JSON.parse(localStorage.getItem('shenzhen-preferences') || '{}'));
  expect(saved.navigationStyle).toBeUndefined();
  expect(saved.reverseWheelZoom).toBeUndefined();
});

test('viewport shortcuts switch views and do not run inside settings or editable fields', async ({page,isMobile}) => {
  test.skip(isMobile, 'Physical keyboard regression');
  await page.getByRole('button', {name:'Sample model',exact:true}).click();
  await expect(page.locator('.model-badge')).toContainText('4 parts');
  const canvas = page.locator('.viewport-canvas canvas');
  await page.getByTitle('Front · Shift 1', {exact:true}).click();
  const front = await canvas.screenshot();
  const compareFront = async () => {
    const current = await canvas.screenshot();
    return page.evaluate(async ({a,b}) => {
      const pixels = async (data:string) => {
        const image = new Image(); image.src = 'data:image/png;base64,' + data; await image.decode();
        const surface = document.createElement('canvas'); surface.width=image.width; surface.height=image.height;
        const context = surface.getContext('2d')!; context.drawImage(image,0,0);
        return context.getImageData(0,0,image.width,image.height).data;
      };
      const [before,after]=await Promise.all([pixels(a),pixels(b)]); let changed=0;
      for(let i=0;i<before.length;i+=4) if(Math.max(...[0,1,2].map(channel=>Math.abs(before[i+channel]-after[i+channel])))>20) changed++;
      return changed/(before.length/4);
    }, {a:front.toString('base64'),b:current.toString('base64')});
  };
  await page.keyboard.press('Shift+Digit5');
  const top = await canvas.screenshot();
  expect(top.equals(front)).toBe(false);
  await page.keyboard.press('Shift+Digit1');
  await expect.poll(compareFront).toBeLessThan(0.003);
  await page.getByRole('button', {name:'Settings',exact:true}).click();
  await page.keyboard.press('Shift+Digit5');
  await page.getByRole('button', {name:'Done',exact:true}).click();
  await expect.poll(compareFront).toBeLessThan(0.003);
  const search = page.getByRole('textbox', {name:'Search assembly'});
  await search.focus();
  await page.keyboard.press('Shift+Digit5');
  await search.fill('');
  await search.blur();
  await expect.poll(compareFront).toBeLessThan(0.003);
  await page.keyboard.press('n');
  await expect(page.locator('.toast')).toContainText('Select a planar face first');
});

test('a delayed recent-file read cannot replace a newer file open', async ({page}) => {
  await page.addInitScript(() => {
    const state = window as typeof window & { releaseOldRecent?: () => void };
    const entry = {id:'11111111-1111-4111-8111-111111111111',name:'older.stl',format:'stl',openedAt:1,fileCount:1,totalBytes:100,storage:'native' as const};
    window.shenzhenRecentFiles = {
      list: async () => [entry], remember: async () => null, remove: async () => {}, touch: async () => entry,
      open: async () => {
        await new Promise<void>(resolve => { state.releaseOldRecent = resolve; });
        return [{name:'older.stl',lastModified:1,bytes:new TextEncoder().encode('solid old\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 1 0 0\nvertex 0 1 0\nendloop\nendfacet\nendsolid old\n')}];
      },
    };
  });
  await page.reload();
  await page.getByRole('region',{name:'Recent files'}).getByRole('button',{name:/older.stl/}).click();
  await page.waitForFunction(() => Boolean((window as typeof window & {releaseOldRecent?:()=>void}).releaseOldRecent));
  const triangle = Buffer.from('solid new\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 2 0 0\nvertex 0 2 0\nendloop\nendfacet\nendsolid new\n');
  await page.locator('input[type=file]').setInputFiles({name:'newer.stl',mimeType:'model/stl',buffer:triangle});
  await expect(page.locator('header')).toContainText('newer.stl');
  await page.evaluate(async () => {
    (window as typeof window & {releaseOldRecent?:()=>void}).releaseOldRecent!();
    await new Promise<void>(resolve => requestAnimationFrame(() => requestAnimationFrame(() => resolve())));
  });
  await expect(page.locator('header')).toContainText('newer.stl');
  await expect(page.locator('.model-badge')).toContainText('1 part');
});

// Count rendered model pixels: brighter than the background and grid lines.
async function modelFootprint(page: Page) {
  await page.evaluate(() => new Promise<void>(resolve => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))));
  const png = (await page.locator('.viewport-canvas canvas').screenshot()).toString('base64');
  return page.evaluate(async source => {
    const image = new Image();
    image.src = `data:image/png;base64,${source}`;
    await image.decode();
    const canvas = document.createElement('canvas');
    canvas.width = image.naturalWidth;
    canvas.height = image.naturalHeight;
    const context = canvas.getContext('2d')!;
    context.drawImage(image, 0, 0);
    const pixels = context.getImageData(0, 0, canvas.width, canvas.height).data;
    let count = 0;
    for (let i = 0; i < pixels.length; i += 4) if (pixels[i] + pixels[i + 1] + pixels[i + 2] > 330) count++;
    return count;
  }, png);
}

test('assembly selection centers without zooming and stays in sync with part picks', async ({page, isMobile}) => {
  test.skip(isMobile, 'Phones show the assembly as a sheet over the viewport.');
  await page.getByRole('button', {name: 'Sample model', exact: true}).click();
  await expect(page.locator('.model-badge')).toContainText('4 parts');
  const [location] = await geometryLocations(page);
  const openAssembly = page.getByRole('button', {name: 'Show assembly', exact: true});
  if (await openAssembly.isVisible()) await openAssembly.click();
  const selected = page.locator('[role=treeitem][aria-selected=true]');
  const before = await modelFootprint(page);
  await page.getByRole('button', {name: 'Fastener · Ø10', exact: true}).first().click();
  await expect(selected).toHaveCount(1);
  await expect(selected).toContainText('Fastener');
  await page.waitForTimeout(400);
  const after = await modelFootprint(page);
  expect(after / before, 'Selecting a row keeps the zoom').toBeGreaterThan(0.75);
  expect(after / before, 'Selecting a row keeps the zoom').toBeLessThan(1.33);
  await page.keyboard.press('Shift+F');
  await page.waitForTimeout(100);
  expect(await modelFootprint(page), 'Shift+F still zooms to the selection').toBeGreaterThan(after * 1.5);
  await page.keyboard.press('Escape');
  await expect(selected).toHaveCount(0);

  await page.getByRole('button', {name: 'Fit model', exact: true}).first().click();
  await page.getByRole('button', {name: 'Part', exact: true}).click();
  await page.getByRole('button', {name: 'Collapse Precision mounting bracket', exact: true}).click();
  await expect(page.getByRole('treeitem')).toHaveCount(1);
  const framed = await modelFootprint(page);
  await page.mouse.click(location.x, location.y);
  await expect(selected).toHaveCount(1);
  await expect(selected).not.toContainText('Precision mounting bracket');
  await expect(selected).toBeInViewport();
  expect(Math.abs(await modelFootprint(page) - framed) / framed, 'Picking a part keeps the view').toBeLessThan(0.25);
  const box = (await page.locator('.viewport-canvas canvas').boundingBox())!;
  await page.mouse.click(box.x + 24, box.y + box.height - 24);
  await expect(selected).toHaveCount(0);
});
