import {
  mkdir,
  copyFile,
  cp,
  readFile,
  readdir,
  rm,
  writeFile,
} from "node:fs/promises";
import { createHash } from "node:crypto";
await mkdir("public/wasm", { recursive: true });
await copyFile(
  "node_modules/@mlightcad/libredwg-web/wasm/libredwg-web.wasm",
  "public/wasm/libredwg-web.wasm",
);
await mkdir("public/draco", { recursive: true });
for (const name of [
  "draco_wasm_wrapper.js",
  "draco_decoder.wasm",
  "draco_decoder.js",
])
  await copyFile(
    "node_modules/three/examples/jsm/libs/draco/gltf/" + name,
    "public/draco/" + name,
  );

// Tauri embeds these notices through frontendDist. This directory is generated.
await rm("public/licenses", { recursive: true, force: true });
await cp("licenses", "public/licenses", { recursive: true });
await copyFile("licenses/THIRD_PARTY.txt", "public/THIRD_PARTY.txt");
await copyFile(
  "vendor/occt/LICENSE",
  "public/licenses/vendor-occt-LICENSE.txt",
);
const lock = JSON.parse(await readFile("package-lock.json", "utf8"));
const dependencies = [];
for (const [path, entry] of Object.entries(lock.packages || {}).sort(
  ([a], [b]) => a.localeCompare(b, "en"),
)) {
  if (!path || entry.dev) continue;
  const pkg = JSON.parse(await readFile(path + "/package.json", "utf8"));
  const directory =
    "npm/" +
    pkg.name.replaceAll("@", "").replaceAll("/", "__") +
    "@" +
    pkg.version;
  const files = (await readdir(path, { withFileTypes: true }))
    .filter(
      (file) =>
        file.isFile() &&
        /^(license|licence|copying|notice)([._-]|$)/i.test(file.name),
    )
    .map((file) => file.name)
    .sort();
  await mkdir("public/licenses/" + directory, { recursive: true });
  for (const name of files)
    await copyFile(
      path + "/" + name,
      "public/licenses/" + directory + "/" + name,
    );
  dependencies.push({
    name: pkg.name,
    version: pkg.version,
    license: pkg.license || entry.license || "UNKNOWN",
    repository:
      typeof pkg.repository === "string" ? pkg.repository : pkg.repository?.url,
    artifact: entry.resolved,
    integrity: entry.integrity,
    licenseFiles: files.map((name) => directory + "/" + name),
    supplementalLicenseFiles:
      pkg.name === "@mlightcad/libredwg-web"
        ? ["GPL-3.0.txt", "LibreDWG-AUTHORS.txt"]
        : pkg.name.startsWith("@tauri-apps/plugin-")
          ? [
              "Tauri-plugins-LICENSE-MIT.txt",
              "Tauri-plugins-LICENSE-APACHE-2.0.txt",
            ]
          : pkg.name === "@tx-code/occt-js"
            ? ["LGPL-2.1.txt", "OCCT-LGPL-EXCEPTION.txt"]
            : [],
  });
}
const artifacts = [];
for (const path of [
  "vendor/occt/occt-js.wasm",
  "vendor/occt/occt-js.mjs",
  "vendor/occt/occt-js.cjs",
  "public/wasm/libredwg-web.wasm",
  "public/draco/draco_wasm_wrapper.js",
  "public/draco/draco_decoder.wasm",
  "public/draco/draco_decoder.js",
  "node_modules/three/examples/jsm/libs/meshopt_decoder.module.js",
  "node_modules/three/examples/jsm/libs/meshopt_simplifier.module.js",
]) {
  const bytes = await readFile(path);
  artifacts.push({
    path,
    bytes: bytes.length,
    sha256: createHash("sha256").update(bytes).digest("hex"),
  });
}
await writeFile(
  "public/licenses/npm-inventory.json",
  JSON.stringify(
    {
      scope:
        "Frontend npm and vendored/decoder assets; native Rust/platform dependencies need their own inventory.",
      occtBridgeRevision: (
        await readFile("vendor/occt/REVISION", "utf8")
      ).trim(),
      dependencies,
      artifacts,
    },
    null,
    2,
  ) + "\n",
);
