// App origin for standalone browser checks. PERF_BASE_URL reuses a running
// server; otherwise a private Vite dev server starts on a free loopback port,
// so a check never depends on, or collides with, a server already on 1420.
import { spawn } from "node:child_process";
import net from "node:net";
import { fileURLToPath } from "node:url";
import { setTimeout as delay } from "node:timers/promises";

const root = fileURLToPath(new URL("../..", import.meta.url));
const vite = fileURLToPath(
  new URL("../../node_modules/vite/bin/vite.js", import.meta.url),
);

export function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.unref();
    server.on("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

async function startVite(readyPath, timeout) {
  const port = await freePort(),
    origin = `http://127.0.0.1:${port}`;
  const child = spawn(
    process.execPath,
    [vite, "--host", "127.0.0.1", "--port", String(port), "--strictPort"],
    { cwd: root, stdio: ["ignore", "pipe", "pipe"] },
  );
  let output = "",
    exited = false;
  const exit = new Promise((resolve) =>
    child.once("exit", () => {
      exited = true;
      resolve();
    }),
  );
  child.stdout.on("data", (chunk) => (output += chunk));
  child.stderr.on("data", (chunk) => (output += chunk));
  const close = async () => {
    if (!exited) child.kill("SIGTERM");
    await exit;
  };
  const deadline = Date.now() + timeout;
  while (!exited && Date.now() < deadline) {
    try {
      const response = await fetch(origin + readyPath);
      if (response.ok) return { origin, port, close };
    } catch {}
    await delay(100);
  }
  const exitedEarly = exited;
  await close();
  return {
    error: output.trim() || "Vite did not become ready",
    retry: exitedEarly,
  };
}

export async function startAppServer({
  baseURL = process.env.PERF_BASE_URL,
  readyPath = "/",
  timeout = 60_000,
} = {}) {
  if (baseURL)
    return { origin: baseURL.replace(/\/+$/, ""), close: async () => {} };
  // A port taken between probing and Vite binding makes strictPort exit; retry.
  let last;
  for (let attempt = 0; attempt < 3; attempt++) {
    const started = await startVite(readyPath, timeout);
    if (!started.error) return started;
    last = started.error;
    if (!started.retry) break;
  }
  throw new Error(`Could not start the Vite dev server:\n${last}`);
}
