// Standalone browser integration check: node tests/drawing-browser.mjs
import { spawn } from 'node:child_process';
import { setTimeout as delay } from 'node:timers/promises';
import assert from 'node:assert/strict';
import { chromium } from '@playwright/test';
const port = 1429;
const origin = `http://127.0.0.1:${port}`;
const server = spawn(process.execPath, ['node_modules/vite/bin/vite.js', '--host', '127.0.0.1', '--port', String(port)], { stdio: 'pipe' });
let browser;
try {
  let ready = false;
  for (let i = 0; i < 100; i++) { try { await fetch(origin); ready = true; break; } catch { await delay(100); } }
  assert(ready, 'Vite server became available');
  browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();
  await page.route(origin + '/__drawing_test__.html', route => route.fulfill({ contentType: 'text/html', body: '<!doctype html><title>Drawing integration test</title>' }));
  await page.goto(origin + '/__drawing_test__.html');
  const result = await page.evaluate(async () => {
    const { importDrawing, drawingFromDatabase } = await import('/src/core/drawing.ts');
    const load = async name => { const response = await fetch('/tests/fixtures/drawing/' + name); if (!response.ok) throw new Error(name + ' missing'); return importDrawing(await response.arrayBuffer(), name, name.endsWith('.dwg') ? 'dwg' : 'dxf'); };
    const dxf = await load('engineering.dxf'); const dwg = await load('arc-2000.dwg'); const polyline = await load('polyline-2000.dwg');
    const text = drawingFromDatabase({ entities: [{ type: 'TEXT', text: 'Ø 25 mm', textHeight: 2, startPoint: { x: 10, y: 20 } }, { type: 'MTEXT', text: 'Hello\\PWorld', height: 2, position: { x: 1, y: 2 }, attachmentPoint: 1 }] }, 'text.dxf', 'dxf');
    return { dxfParts: dxf.parts.length, dwgParts: dwg.parts.length, polylineParts: polyline.parts.length, textParts: text.parts.length, annotations: [...text.geometries.values()].map(g => ({ text: g.geometry.userData.text, textured: Boolean(g.materials[0].map), finite: [...g.geometry.attributes.position.array].every(Number.isFinite) })), dwgProperties: [...dwg.geometries.values()][0].geometry.userData.drawing };
  });
  assert.equal(result.dxfParts, 6); assert.equal(result.dwgParts, 1); assert.equal(result.polylineParts, 1); assert.equal(result.textParts, 2);
  assert(result.annotations.every(a => a.textured && a.finite)); assert(result.dwgProperties.radius > 0); assert.equal(result.dwgProperties.exact, true);
  console.log(JSON.stringify({ passed: true, ...result }, null, 2));
} finally { await browser?.close(); server.kill('SIGTERM'); }
