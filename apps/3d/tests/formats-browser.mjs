// Actual browser integration for DOM-based XML loaders, object URLs and textures.
// Run: node tests/formats-browser.mjs
import { spawn } from 'node:child_process';
import { setTimeout as delay } from 'node:timers/promises';
import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import { chromium } from '@playwright/test';
const port = 1431, origin = `http://127.0.0.1:${port}`;
const server = spawn(process.execPath, ['node_modules/vite/bin/vite.js', '--host', '127.0.0.1', '--port', String(port)], { stdio: 'pipe' });
let browser;
try {
  let ready = false;
  for (let i = 0; i < 100; i++) { try { await fetch(origin); ready = true; break; } catch { await delay(100); } }
  assert(ready, 'Vite server became available');
  browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();
  // Keep the importer check independent of the application shell and Vite HMR.
  await page.route(origin + '/__formats-test__', route => route.fulfill({ contentType: 'text/html', body: '<!doctype html><title>Format import regression</title>' }));
  await page.goto(origin + '/__formats-test__');
  const result = await page.evaluate(async () => {
    const { importFiles, disposeDocument } = await import('/src/core/importers.ts');
    const T = await import('/node_modules/three/build/three.module.js');
    const fixture = async name => {
      const response = await fetch('/tests/fixtures/formats/' + name);
      if (!response.ok) throw new Error('Missing fixture ' + name);
      return new File([await response.arrayBuffer()], name);
    };
    const run = async names => {
      const progress = [], doc = await importFiles(await Promise.all(names.map(fixture)), 'balanced', value => progress.push(value));
      // OBJ/MTL starts TextureLoader work without awaiting it. Observe actual decoded pixels.
      for (let i = 0; i < 100; i++) {
        const maps = [...doc.geometries.values()].flatMap(g => g.materials.map(m => m.map)).filter(Boolean);
        if (maps.every(map => map.image?.width > 0)) break;
        await new Promise(resolve => setTimeout(resolve, 10));
      }
      const parts = doc.parts.map(part => {
        const data = doc.geometries.get(part.geometryId), matrix = new T.Matrix4().fromArray(part.matrix);
        const bounds = new T.Box3().setFromBufferAttribute(data.geometry.getAttribute('position')).applyMatrix4(matrix);
        return { min: bounds.min.toArray(), size: bounds.getSize(new T.Vector3()).toArray(), lines: !!data.lines, indices: data.geometry.index?.count,
          materials: data.materials.map(m => ({ opacity: m.opacity, transparent: m.transparent, color: m.color?.getHex(), texture: !!m.map, textureWidth: m.map?.image?.width || 0 })) };
      });
      const out = { unit: doc.unit, sourceUnit: doc.sourceUnit, is2D: doc.is2D, warnings: doc.warnings, parts, progress };
      disposeDocument(doc); return out;
    };
    const out = {};
    for (const names of [['panel.obj', 'panel.mtl', 'checker.png'], ['embedded.gltf'], ['panel.gltf', 'panel.bin'], ['panel.glb'], ['panel.3mf'], ['glass.wrl'], ['panel.dae'], ['drawing.svg'], ['panel.fbx']]) {
      try { out[names[0]] = await run(names); }
      catch (error) { out[names[0]] = { error: error.message }; }
    }
    return out;
  });
  await mkdir('artifacts', { recursive: true });
  await writeFile('artifacts/formats-validation.json', JSON.stringify(result, null, 2));
  for (const [name, value] of Object.entries(result)) assert(!value.error, name + ': ' + value.error);
  for (const name of ['embedded.gltf', 'panel.gltf', 'panel.glb', 'glass.wrl']) {
    assert.equal(result[name].unit, 'm', name + ' units');
    assert.equal(result[name].parts.length, 1, name + ' part count');
    assert.deepEqual(result[name].parts[0].min, [2, 3, 4], name + ' world translation');
    assert.deepEqual(result[name].parts[0].size, [1, 2, 0], name + ' world extent');
    assert(Math.abs(result[name].parts[0].materials[0].opacity - 0.4) < 1e-6, name + ' alpha');
    assert.equal(result[name].parts[0].materials[0].transparent, true, name + ' transparency');
  }
  const obj = result['panel.obj'];
  assert.equal(obj.parts[0].materials[0].textureWidth, 1, 'OBJ companion texture actually decoded');
  assert.equal(obj.parts[0].materials[0].opacity, 0.4, 'MTL d opacity');
  assert.equal(obj.warnings.length, 1, 'supplied OBJ companions are resolved');
  assert.equal(result['panel.gltf'].warnings.length, 0, 'external glTF BIN companion is resolved');
  const mf = result['panel.3mf'];
  assert.equal(mf.unit, 'in', '3MF inch metadata');
  assert.deepEqual(mf.parts[0].min, [2, 3, 4], '3MF build transform');
  assert(Math.abs(mf.parts[0].materials[0].opacity - 0.4) < 1e-6, '3MF base material alpha');
  assert.equal(mf.parts[0].materials[0].transparent, true, '3MF alpha activates transparent rendering');
  const dae = result['panel.dae'];
  assert.equal(dae.unit, 'm', 'DAE loader normalizes asset units to meters');
  assert(Math.abs(dae.parts[0].size[0] - 0.01) < 1e-6, 'DAE millimeter coordinates become meters');
  assert(Math.abs(dae.parts[0].materials[0].opacity - 0.4) < 1e-6, 'DAE transparent effect');
  const svg = result['drawing.svg'];
  assert.equal(svg.is2D, true); assert.equal(svg.unit, 'mm');
  assert.deepEqual(svg.parts[0].size, [100, 50, 0], 'SVG physical size and viewBox');
  assert(Math.abs(svg.parts[0].materials[0].opacity - 0.4) < 1e-6, 'SVG fill alpha');
  assert.equal(svg.parts.length, 2, 'SVG stroke=none creates no visible outline');
  assert.equal(result['panel.fbx'].parts[0].materials[0].opacity, 0.4, 'FBX opacity');
  console.log(JSON.stringify({ passed: true, formats: Object.keys(result), report: 'artifacts/formats-validation.json' }, null, 2));
} finally { await browser?.close(); server.kill('SIGTERM'); }
