import {expect, type Page} from '@playwright/test';

export async function closeInspector(page: Page) {
  const close = page.getByRole('button', {name: 'Close measurements', exact: true});
  if (await close.isVisible()) await close.click();
}

export async function showInspector(page: Page) {
  await expect(page.locator('.model-badge')).toBeVisible();
  const open = page.getByRole('button', {name: 'Show measurements', exact: true});
  if (await open.isVisible()) await open.click();
  await expect(page.locator('.inspector')).toBeVisible();
}

// Sample actual rendered pixels, then verify a raycast through the UI hover status.
// This avoids assumptions about STEP placement, camera fit, tessellation or viewport size.
export async function geometryLocations(page: Page) {
  await closeInspector(page);
  await page.getByTitle('Top · Shift 5', {exact: true}).click();
  await page.getByRole('button', {name: 'Fit model', exact: true}).click();
  await page.evaluate(() => new Promise<void>(resolve => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))));
  // Capture the composited canvas: its WebGL drawing buffer is discarded after
  // presenting a frame when preserveDrawingBuffer is false.
  const screenshot = await page.locator('canvas').screenshot();
  const locations = await page.locator('canvas').evaluate(async (canvas, png) => {
    const image = new Image();
    image.src = `data:image/png;base64,${png}`;
    await image.decode();
    const width = image.naturalWidth, height = image.naturalHeight;
    const sampler = document.createElement('canvas');
    sampler.width = width;
    sampler.height = height;
    const context = sampler.getContext('2d')!;
    context.drawImage(image, 0, 0);
    const pixels = context.getImageData(0, 0, width, height).data;
    const rect = canvas.getBoundingClientRect();
    const points: {x: number; y: number}[] = [];
    // Bright model surfaces are well above both the graphite background and grid.
    for (let y = 65; y < rect.height - 85; y += 3) for (let x = 30; x < rect.width - 48; x += 3) {
      const px = Math.floor(x / rect.width * width), py = Math.floor(y / rect.height * height);
      const i = (py * width + px) * 4;
      if (pixels[i] > 75 && pixels[i + 1] > 75 && pixels[i + 2] > 75) points.push({x: rect.x + x, y: rect.y + y});
    }
    return points;
  }, screenshot.toString('base64'));
  expect(locations.length, 'Model has visible rendered surfaces').toBeGreaterThan(10);
  const picks: {x: number; y: number}[] = [];
  // Pick separated regions along the longest screen axis, not neighbouring triangles.
  const xs = locations.map(p => p.x), ys = locations.map(p => p.y);
  const axis = Math.max(...xs) - Math.min(...xs) > Math.max(...ys) - Math.min(...ys) ? 'x' : 'y';
  locations.sort((a, b) => a[axis] - b[axis]);
  for (const fraction of [0.18, 0.8, 0.5]) {
    const middle = Math.floor(locations.length * fraction);
    for (let offset = 0; offset < 100; offset++) {
      const p = locations[Math.min(middle + offset, locations.length - 1)];
      await page.mouse.move(p.x, p.y);
      // Hover picking runs once per animation frame; let its status commit.
      await page.evaluate(() => new Promise<void>(resolve => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))));
      if ((await page.locator('.status-main').textContent())?.includes(' · ')) {picks.push(p); break;}
    }
  }
  expect(picks, 'Rendered locations raycast to model geometry').toHaveLength(3);
  return picks;
}

export async function pickAt(page: Page, location: {x: number; y: number}, mobile: boolean) {
  await closeInspector(page);
  if (mobile) await page.touchscreen.tap(location.x, location.y);
  else await page.mouse.click(location.x, location.y);
}

