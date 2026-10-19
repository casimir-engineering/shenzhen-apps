import { describe, it, expect } from "vitest";
import { createRequire } from "node:module";
import { readFile, mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { SUPPORTED } from "../src/core/formats";
const require = createRequire(import.meta.url),
  electron = require("../electron-builder.cjs");
const tauri = JSON.parse(
  await readFile(
    new URL("../src-tauri/tauri.conf.json", import.meta.url),
    "utf8",
  ),
);
const expected = [...SUPPORTED, "sz3d"].sort();
describe("native file association metadata", () => {
  it("covers each actual input format and project without standalone sidecars or exports", () => {
    const electronExt = electron.fileAssociations
      .flatMap((entry: { ext: string | string[] }) => [entry.ext].flat())
      .sort();
    const tauriExt = tauri.bundle.fileAssociations
      .flatMap((entry: { ext: string[] }) => entry.ext)
      .sort();
    expect(electronExt).toEqual(expected);
    expect(tauriExt).toEqual(expected);
    expect(new Set(electronExt).size).toBe(expected.length);
    for (const entry of [
      ...electron.fileAssociations,
      ...tauri.bundle.fileAssociations,
    ]) {
      expect(entry.role).toBe("Viewer");
      expect(entry.mimeType).toMatch(/^[a-z]+\/[a-z0-9.+-]+$/);
      expect(entry.rank).toBe(
        [entry.ext].flat().includes("sz3d") ? "Owner" : "Alternate",
      );
    }
  });
  it("declares its own project UTI and uses the existing SVG image type", () => {
    const mac = electron.mac.extendInfo,
      project = mac.UTExportedTypeDeclarations.find(
        (entry: { UTTypeIdentifier: string }) =>
          entry.UTTypeIdentifier === "com.shenzhen3d.project",
      );
    expect(project.UTTypeTagSpecification["public.filename-extension"]).toEqual(
      ["sz3d"],
    );
    expect(project.UTTypeConformsTo).toContain("public.zip-archive");
    expect(
      mac.CFBundleDocumentTypes.find(
        (entry: { LSItemContentTypes: string[] }) =>
          entry.LSItemContentTypes.includes("public.svg-image"),
      ).CFBundleTypeRole,
    ).toBe("Viewer");
    const projectAssociation = tauri.bundle.fileAssociations.find(
      (entry: { ext: string[] }) => entry.ext.includes("sz3d"),
    );
    expect(projectAssociation.exportedType.identifier).toBe(
      project.UTTypeIdentifier,
    );
    expect(
      tauri.bundle.fileAssociations.find((entry: { ext: string[] }) =>
        entry.ext.includes("svg"),
      ).contentTypes,
    ).toEqual(["public.svg-image"]);
    expect(mac.UTExportedTypeDeclarations).toHaveLength(1);
  });
  it("validates against the installed Electron and Tauri configuration schemas", async () => {
    const {
      validateConfiguration,
    } = require("app-builder-lib/out/util/config/config");
    await validateConfiguration(electron);
    const Ajv = require("ajv"),
      schema = require("@tauri-apps/cli/config.schema.json"),
      validate = new Ajv({
        strict: false,
        allErrors: true,
        unicodeRegExp: false,
      }).compile(schema);
    expect(validate(tauri), JSON.stringify(validate.errors)).toBe(true);
  });
  it("generates individual Linux MIME globs for aliases rather than comma-joined extensions", async () => {
    const {
      LinuxTargetHelper,
    } = require("app-builder-lib/out/targets/LinuxTargetHelper");
    const directory = await mkdtemp(
      path.join(os.tmpdir(), "shenzhen-mime-associations-"),
    );
    try {
      const file = await LinuxTargetHelper.prototype.computeMimeTypeFiles.call({
        packager: {
          fileAssociations: electron.fileAssociations,
          getTempFile: async () => path.join(directory, "types.xml"),
        },
      });
      const xml = await readFile(file, "utf8");
      for (const ext of expected)
        expect(xml).toContain(`glob pattern="*.${ext}"`);
      expect(xml).not.toContain("*.step,stp");
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });
});
