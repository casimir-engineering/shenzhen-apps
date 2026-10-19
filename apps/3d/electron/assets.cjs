const fs = require('node:fs/promises');
const path = require('node:path');

const CSP = "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' blob: data:; font-src 'self' data:; connect-src 'self' blob: data:; worker-src 'self' blob:; object-src 'none'; base-uri 'none'; frame-src 'none'; form-action 'none'";
const mime = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.json': 'application/json', '.wasm': 'application/wasm', '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.woff2': 'font/woff2', '.txt': 'text/plain; charset=utf-8' };

function devURL(value, packaged) {
  if (packaged || !value) return undefined;
  const url = new URL(value);
  if (url.protocol !== 'http:' || !['127.0.0.1', 'localhost'].includes(url.hostname) || url.port !== '1420' || url.username || url.password || !['/', '/tests/perf/index.html', '/tests/perf/viewer-correctness.html'].includes(url.pathname)) throw new Error('Development URL must be the local app or benchmark on port 1420');
  return url.href;
}

function createAssetHandler(root) {
  const headers = { 'Content-Security-Policy': CSP, 'X-Content-Type-Options': 'nosniff', 'Cache-Control': 'no-store' };
  return async request => {
    try {
      const url = new URL(request.url);
      if (url.protocol !== 'app:' || url.hostname !== 'local' || url.port || url.username || url.password) return new Response(null, { status: 403, headers });
      if (!['GET', 'HEAD'].includes(request.method)) return new Response(null, { status: 405, headers });
      const pathname = decodeURIComponent(url.pathname);
      if (pathname.includes('\\') || pathname.includes('\0') || pathname.split('/').includes('..')) return new Response(null, { status: 403, headers });
      const base = await fs.realpath(root);
      const file = await fs.realpath(path.resolve(base, `.${pathname === '/' ? '/index.html' : pathname}`));
      if (!file.startsWith(`${base}${path.sep}`)) return new Response(null, { status: 403, headers });
      if (!(await fs.stat(file)).isFile()) return new Response(null, { status: 404, headers });
      const content = request.method === 'HEAD' ? null : await fs.readFile(file);
      // Emscripten's CAD bindings create JS wrappers with Function inside their
      // isolated worker. Keep eval disabled in the document renderer.
      const worker = /\.worker-[\w-]+\.js$/.test(path.basename(file));
      const policy = worker ? CSP.replace("'wasm-unsafe-eval'", "'wasm-unsafe-eval' 'unsafe-eval'") : CSP;
      return new Response(content, { headers: { ...headers, 'Content-Security-Policy': policy, 'Content-Type': mime[path.extname(file).toLowerCase()] ?? 'application/octet-stream' } });
    } catch { return new Response(null, { status: 404, headers }); }
  };
}

module.exports = { createAssetHandler, devURL, CSP };
