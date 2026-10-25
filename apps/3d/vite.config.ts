import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { readFileSync } from "node:fs";
import { offlinePlugin } from "./scripts/offline-plugin";
// The version the app shows: package.json's, the one a release sets (or SHENZHEN_3D_VERSION, which
// electron/package-mac.mjs --version sets for a candidate of another version). The page reads it from this tag
// (src/core/app-version.ts), and tools/release.sh checks the tag in every build.
const version: string =
  process.env.SHENZHEN_3D_VERSION ||
  JSON.parse(readFileSync(new URL("./package.json", import.meta.url), "utf8")).version;
const appVersion = {
  name: "shenzhen-3d-version",
  transformIndexHtml: () => [
    { tag: "meta", attrs: { name: "shenzhen-3d-version", content: version }, injectTo: "head" as const },
  ],
};
export default defineConfig({
  plugins: [react(), offlinePlugin(), appVersion],
  clearScreen: false,
  optimizeDeps: { entries: ["index.html", "tests/perf/index.html", "tests/perf/viewer-correctness.html"] },
  server: {
    port: 1420,
    strictPort: true,
    // Native build trees and benchmark outputs can contain hundreds of thousands
    // of files. They are served on demand but never need frontend hot reloads.
    watch: { ignored: ["**/artifacts/**", "**/src-tauri/target/**", "**/src-tauri/gen/**"] },
  },
  envPrefix: ["VITE_", "TAURI_ENV_*"],
  build: { target: "es2022", chunkSizeWarningLimit: 1200 },
  worker: { format: "es" },
});
