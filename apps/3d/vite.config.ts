import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { offlinePlugin } from "./scripts/offline-plugin";
export default defineConfig({
  plugins: [react(), offlinePlugin()],
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
