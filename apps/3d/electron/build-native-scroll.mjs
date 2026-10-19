import fs from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import { fileURLToPath, pathToFileURL } from "node:url";
import { execFileSync } from "node:child_process";
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
export async function buildNativeScroll({
  output = path.join(
    root,
    "artifacts/native-scroll",
    process.arch,
    "scroll-source.node",
  ),
  arch = process.arch,
} = {}) {
  if (process.platform !== "darwin") return undefined;
  if (!["arm64", "x64"].includes(arch))
    throw Error("Unsupported native scroll architecture");
  const candidates = [
    process.env.SHENZHEN_NODE_HEADERS,
    path.join(
      os.homedir(),
      "Library/Caches/node-gyp",
      process.versions.node,
      "include/node",
    ),
    path.resolve(path.dirname(process.execPath), "../include/node"),
    "/opt/homebrew/include/node",
    "/usr/local/include/node",
  ].filter(Boolean);
  let headers;
  for (const candidate of candidates) {
    try {
      await fs.access(path.join(candidate, "node_api.h"));
      headers = candidate;
      break;
    } catch {}
  }
  if (!headers)
    throw Error(
      "Node N-API headers are required; set SHENZHEN_NODE_HEADERS to their include directory",
    );
  await fs.mkdir(path.dirname(output), { recursive: true });
  execFileSync(
    "xcrun",
    [
      "clang++",
      "-std=c++17",
      "-fobjc-arc",
      "-fblocks",
      "-dynamiclib",
      "-Wl,-adhoc_codesign",
      "-undefined",
      "dynamic_lookup",
      "-mmacosx-version-min=13.0",
      "-arch",
      arch === "x64" ? "x86_64" : "arm64",
      "-DNAPI_VERSION=8",
      "-DNODE_GYP_MODULE_NAME=scroll_source",
      "-I",
      headers,
      "-framework",
      "AppKit",
      path.join(root, "electron/native/scroll-source.mm"),
      "-o",
      output,
    ],
    { stdio: "pipe" },
  );
  return output;
}
if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href
)
  console.log(await buildNativeScroll());
