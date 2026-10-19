// Local dependency inventory, not a legal clearance or complete source bundle.
import { readFile, readdir, mkdir, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { resolve } from "node:path";
const lock = JSON.parse(await readFile("package-lock.json", "utf8"));
const dependencies = [];
for (const [path, entry] of Object.entries(lock.packages || {})) {
  if (!path || entry.dev) continue;
  let pkg;
  try {
    pkg = JSON.parse(await readFile(resolve(path, "package.json"), "utf8"));
  } catch {
    dependencies.push({
      path,
      version: entry.version,
      missingInstalledPackage: true,
    });
    continue;
  }
  const names = await readdir(path);
  dependencies.push({
    name: pkg.name,
    version: pkg.version,
    license: pkg.license || entry.license || "UNKNOWN",
    path,
    repository:
      typeof pkg.repository === "string" ? pkg.repository : pkg.repository?.url,
    licenseFiles: names
      .filter((name) =>
        /^(license|licence|copying|notice)([._-]|$)/i.test(name),
      )
      .map((name) => `${path}/${name}`),
  });
}
const vendor = {
  name: "occt-js exact CAD kernel",
  revision: (await readFile("vendor/occt/REVISION", "utf8")).trim(),
  license: "LGPL-2.1 (bridge); LGPL-2.1 with additional exception (OCCT)",
  files: [],
};
for (const name of await readdir("vendor/occt")) {
  const bytes = await readFile(`vendor/occt/${name}`);
  vendor.files.push({
    path: `vendor/occt/${name}`,
    bytes: bytes.length,
    sha256: createHash("sha256").update(bytes).digest("hex"),
  });
}
let packagedNotices;
try {
  packagedNotices = JSON.parse(
    await readFile("public/licenses/npm-inventory.json", "utf8"),
  );
} catch {
  /* Run prepare:assets to generate the shipping notice inventory. */
}
const report = {
  generatedAt: new Date().toISOString(),
  scope:
    "Installed production npm packages and pinned CAD vendor files. Rust, Android and Apple SDK dependency licenses require separate inventories.",
  dependencies,
  vendor,
  packagedNotices,
  review: {
    copyleft: dependencies.filter((d) => /GPL/.test(d.license)),
    missingLicenseFiles: dependencies
      .filter((d) => !d.licenseFiles?.length)
      .map((d) => d.name || d.path),
    knownReleaseGaps: [
      ...(!packagedNotices
        ? [
            "Run npm run prepare:assets to generate public/licenses and THIRD_PARTY.txt.",
          ]
        : []),
      "The notice/source-information bundle does not itself deliver or verify all matching source/build inputs; LibreDWG npm publishes no gitHead and source/WASM correspondence needs verification.",
      "Recipients of private preview binaries need access to the matching product/dependency source and applicable build/replacement material; product UNLICENSED metadata is not a third-party distribution license.",
      "Native Rust/platform dependency attribution and app-specific distribution terms require a separate inventory for each actual native package.",
    ],
  },
};
await mkdir("artifacts", { recursive: true });
await writeFile(
  "artifacts/third-party-inventory.json",
  JSON.stringify(report, null, 2) + "\n",
);
console.log(
  JSON.stringify(
    {
      report: "artifacts/third-party-inventory.json",
      productionPackages: dependencies.length,
      copyleft: report.review.copyleft.map(
        (d) => `${d.name}@${d.version}: ${d.license}`,
      ),
      knownReleaseGaps: report.review.knownReleaseGaps,
    },
    null,
    2,
  ),
);
