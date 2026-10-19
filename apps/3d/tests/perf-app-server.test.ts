import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
// @ts-expect-error -- plain Node script without type declarations
import { startAppServer } from "../scripts/perf/app-server.mjs";

const HARDWARE_RAY_TRACING_CHECKS = [
  "scripts/perf/check-ray-tracing.mjs",
  "tests/ray-tracing-exposure-browser.mjs",
];

describe("browser check app server", () => {
  it("reuses PERF_BASE_URL without starting a server", async () => {
    const server = await startAppServer({
      baseURL: "http://127.0.0.1:1430/",
    });
    expect(server.origin).toBe("http://127.0.0.1:1430");
    await server.close();
  });

  it("starts a private dev server on a free port and stops it", async () => {
    const server = await startAppServer({
      baseURL: "",
      readyPath: "/tests/ray-tracing-exposure.html",
    });
    try {
      expect(server.origin).toMatch(/^http:\/\/127\.0\.0\.1:\d+$/);
      expect(server.port).not.toBe(1420);
      const page = await fetch(
        `${server.origin}/tests/ray-tracing-exposure.html`,
      );
      expect(page.ok).toBe(true);
    } finally {
      await server.close();
    }
    await expect(fetch(server.origin)).rejects.toThrow();
  }, 90_000);

  it.each(HARDWARE_RAY_TRACING_CHECKS)(
    "%s gets its origin from the shared server helper",
    (file) => {
      const source = readFileSync(file, "utf8");
      expect(source).toContain("startAppServer(");
      expect(source).not.toMatch(/(127\.0\.0\.1|localhost):\d+/);
    },
  );
});
