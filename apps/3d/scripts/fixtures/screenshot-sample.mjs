#!/usr/bin/env node
// Renders docs/images/sample-assembly.png: the app with the generated sample
// assembly open and a point measurement between two of its parts.
//
//   npm run build && npx vite preview --port 4173 &
//   node scripts/fixtures/screenshot-sample.mjs http://127.0.0.1:4173 [output.png]
//
// It drives a headless Chromium (software WebGL) through the normal file input
// and picks points the same way the browser tests do: bright rendered pixels,
// confirmed by the hover status before clicking.
import path from 'node:path';
import {chromium} from '@playwright/test';

const base = process.argv[2] || 'http://127.0.0.1:4173';
const out = process.argv[3] || 'docs/images/sample-assembly.png';
const browser = await chromium.launch({args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader']});
try {
  const page = await browser.newPage({viewport: {width: 1600, height: 1040}, deviceScaleFactor: 1, colorScheme: 'dark'});
  await page.goto(base);
  await page.locator('header').getByRole('button', {name: /^Open file/}).waitFor();
  await page.locator('input[type=file]').setInputFiles(path.resolve('fixtures/sample-assembly.step'));
  await page.locator('.model-badge').filter({hasText: 'CAD model'}).waitFor({timeout: 120_000});
  const frame = () => page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  await page.getByTitle('Top · Shift 5', {exact: true}).click();
  await page.getByRole('button', {name: 'Fit model', exact: true}).click();
  await frame();
  const png = await page.locator('canvas').screenshot();
  const bright = await page.locator('canvas').evaluate(async (canvas, data) => {
    const image = new Image();
    image.src = `data:image/png;base64,${data}`;
    await image.decode();
    const sampler = document.createElement('canvas');
    sampler.width = image.naturalWidth;
    sampler.height = image.naturalHeight;
    const context = sampler.getContext('2d');
    context.drawImage(image, 0, 0);
    const pixels = context.getImageData(0, 0, sampler.width, sampler.height).data;
    const rect = canvas.getBoundingClientRect(), points = [];
    for (let y = 65; y < rect.height - 85; y += 2) for (let x = 30; x < rect.width - 48; x += 2) {
      const px = Math.floor(x / rect.width * sampler.width), py = Math.floor(y / rect.height * sampler.height);
      const i = (py * sampler.width + px) * 4;
      if (pixels[i] > 150 && pixels[i + 1] > 150 && pixels[i + 2] > 150) points.push({x: rect.x + x, y: rect.y + y});
    }
    return points;
  }, png.toString('base64'));
  if (bright.length < 10) throw new Error('the model did not render');
  bright.sort((a, b) => a.x - b.x);
  for (const fraction of [0.3, 0.62]) {
    const start = Math.floor(bright.length * fraction);
    let picked = false;
    for (let offset = 0; offset < 200 && !picked; offset++) {
      const p = bright[Math.min(start + offset, bright.length - 1)];
      await page.mouse.move(p.x, p.y);
      await frame();
      if ((await page.locator('.status-main').textContent())?.includes(' · ')) {
        await page.mouse.click(p.x, p.y);
        picked = true;
      }
    }
    if (!picked) throw new Error('no pickable point found');
  }
  await page.locator('.result-hero strong').waitFor();
  await page.mouse.move(1, 1);
  await frame();
  await page.screenshot({path: out});
  console.log(`${out}: ${await page.locator('.result-hero strong').innerText()} mm measurement`);
} finally {
  await browser.close();
}
