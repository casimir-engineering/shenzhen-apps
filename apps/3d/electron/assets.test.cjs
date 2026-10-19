const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { createAssetHandler, devURL } = require('./assets.cjs');
test('protocol confines decoded paths and symlinks to bundled dist', async () => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'shenzhen-electron-'));
  const root = path.join(directory, 'dist');
  await fs.mkdir(root);
  await fs.writeFile(path.join(root, 'index.html'), 'local');
  await fs.writeFile(path.join(root, 'cad.worker-example.js'), 'self.onmessage=()=>{}');
  await fs.writeFile(path.join(root, 'library.js'), 'export default 1');
  await fs.writeFile(path.join(root, 'library.wasm'), Buffer.from([0, 97, 115, 109]));
  await fs.writeFile(path.join(directory, 'secret'), 'private');
  await fs.symlink(path.join(directory, 'secret'), path.join(root, 'escape'));
  const handler = createAssetHandler(root);
  try {
    const local = await handler({ url: 'app://local/', method: 'GET' });
    assert.equal(await local.text(), 'local');
    assert.match(local.headers.get('Content-Security-Policy'), /wasm-unsafe-eval/);
    assert.equal(local.headers.get('Content-Security-Policy').includes("'unsafe-eval'"), false);
    const worker = await handler({ url: 'app://local/cad.worker-example.js', method: 'GET' });
    assert.equal(worker.headers.get('Content-Security-Policy').includes("'unsafe-eval'"), true);
    const library = await handler({ url: 'app://local/library.js', method: 'GET' });
    assert.equal(library.headers.get('Content-Security-Policy').includes("'unsafe-eval'"), false);
    assert.equal((await handler({ url: 'app://local/library.wasm', method: 'GET' })).headers.get('Content-Type'), 'application/wasm');
    for (const url of ['app://other/', 'app://local/%2e%2e%2fsecret', 'app://local/escape', 'app://user@local/', 'app://local:80/', 'file:///secret']) assert.notEqual((await handler({ url, method: 'GET' })).status, 200);
    assert.equal((await handler({ url: 'app://local/', method: 'POST' })).status, 405);
  } finally { await fs.rm(directory, { recursive: true, force: true }); }
});
test('packaged shell ignores development URLs and development accepts only fixed local surfaces', () => {
  assert.equal(devURL('https://evil.invalid/', true), undefined);
  assert.match(devURL('http://127.0.0.1:1420/tests/perf/index.html?source=current', false), /1420/);
  for (const value of ['https://evil.invalid/', 'http://127.0.0.1:1420/secret', 'http://localhost:80/', 'file:///tmp/test']) assert.throws(() => devURL(value, false));
});
test('rendering and CAD worker responses preserve the document CSP boundary', async () => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'shenzhen-worker-policy-'));
  const assets = path.join(directory, 'assets');
  await fs.mkdir(assets);
  const names = ['ray-tracing.worker-Ab12_cd.js', 'cad.worker-Kernel1.js', 'render-library.js', 'ray-tracing.worker.js', 'ray-tracing.worker-Ab12_cd.js.txt'];
  for (const name of names) await fs.writeFile(path.join(assets, name), 'export {};');
  await fs.writeFile(path.join(directory, 'index.html'), '<!doctype html>');
  const handler = createAssetHandler(directory);
  try {
    const document = await handler({ url: 'app://local/', method: 'GET' });
    const documentPolicy = document.headers.get('Content-Security-Policy');
    assert.match(documentPolicy, /worker-src 'self' blob:/); // ZIP Blob workers and bundled module workers.
    assert.match(documentPolicy, /script-src 'self' 'wasm-unsafe-eval';/);
    assert.equal(documentPolicy.includes("'unsafe-eval'"), false);
    for (const [index, name] of names.entries()) {
      const response = await handler({ url: `app://local/assets/${name}?v=1`, method: 'HEAD' });
      assert.equal(response.status, 200);
      assert.equal(await response.text(), '');
      const policy = response.headers.get('Content-Security-Policy');
      assert.equal(policy.includes("'unsafe-eval'"), index < 2, name);
      assert.match(policy, /connect-src 'self' blob: data:/);
      assert.match(policy, /object-src 'none'/);
      assert.equal(response.headers.get('X-Content-Type-Options'), 'nosniff');
    }
    assert.notEqual((await handler({ url: 'app://local/assets/%2e%2e%2f%2e%2e%2foutside.worker-Hash.js', method: 'GET' })).status, 200);
  } finally { await fs.rm(directory, { recursive: true, force: true }); }
});
