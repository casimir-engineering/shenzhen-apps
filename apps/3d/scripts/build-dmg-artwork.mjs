// Render the editable vector artwork into native 1x/2x Finder backgrounds.
// electron-builder combines these into a multi-resolution TIFF automatically.
import { chromium } from '@playwright/test';
import { readFile } from 'node:fs/promises';
const artwork = await readFile(new URL('../electron/installer/background.svg', import.meta.url), 'utf8');
const browser = await chromium.launch({ headless: true });
try {
  for (const scale of [1, 2]) {
    const context = await browser.newContext({ viewport: { width: 760, height: 500 }, deviceScaleFactor: scale });
    const page = await context.newPage();
    await page.setContent(`<html><body style="margin:0">${artwork}</body></html>`);
    await page.evaluate(() => document.fonts.ready);
    await page.screenshot({ path: new URL(`../electron/installer/background${scale === 2 ? '@2x' : ''}.png`, import.meta.url).pathname });
    await context.close();
  }
} finally { await browser.close(); }
