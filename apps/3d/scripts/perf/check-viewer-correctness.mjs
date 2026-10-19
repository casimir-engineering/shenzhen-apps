import { chromium } from '@playwright/test';

const software = process.argv.includes('--software');
const baseURL = process.env.PERF_BASE_URL || 'http://127.0.0.1:1420';
const browser = await chromium.launch({ headless: software, args: [
  '--use-gl=angle', software ? '--use-angle=swiftshader' : '--use-angle=metal',
  ...(software ? ['--enable-unsafe-swiftshader'] : []),
  '--disable-backgrounding-occluded-windows',
] });
const page = await browser.newPage({ viewport: { width: 1000, height: 700 }, deviceScaleFactor: 1 });
const errors = [];
page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
page.on('pageerror', error => errors.push(error.message));
try {
  await page.goto(`${baseURL}/tests/perf/viewer-correctness.html`);
  await page.waitForFunction(() => !!window.viewerCorrectness, { timeout: 120_000 });
  await page.bringToFront();
  const result = await page.evaluate(() => window.viewerCorrectness.run());
  if (!software && (!/Apple.*Metal|ANGLE.*Apple/i.test(result.renderer) || /SwiftShader|llvmpipe/i.test(result.renderer))) throw new Error(`Expected Apple hardware GPU, got ${result.renderer}`);
  if (errors.length) throw new Error(`Application/shader errors: ${JSON.stringify(errors)}`);
  console.log(JSON.stringify(result, null, 2));
} finally {
  await browser.close();
}
