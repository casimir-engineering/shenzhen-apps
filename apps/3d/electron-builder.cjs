const path = require("node:path");
module.exports = {
  appId: "com.shenzhen3d.performance",
  productName: "Shenzhen 3D",
  asar: true,
  npmRebuild: false,
  // Fail on missing runtime dependencies before an expensive signing pass.
  async afterPack(context) {
    const fs = require("node:fs/promises");
    const { verifyRuntimeArchive } = await import("./electron/package-mac.mjs");
    const provenance = JSON.parse(
      await fs.readFile(
        path.join(context.packager.projectDir, "build-info.json"),
        "utf8",
      ),
    );
    const { validatePackagedFeed } = require("./electron/release-channel.cjs");
    validatePackagedFeed(
      context.packager.config.publish,
      provenance.releaseOwner,
      provenance.releaseAccess,
    );
    verifyRuntimeArchive(
      path.join(
        context.appOutDir,
        `${module.exports.productName}.app`,
        "Contents",
        "Resources",
        "app.asar",
      ),
      provenance,
      JSON.parse(
        await fs.readFile(
          path.join(context.packager.projectDir, ".release-verification.json"),
          "utf8",
        ),
      ),
    );
    // Shenzhen Friends: the helper, animal set and notices staged by package-mac.mjs, signed before the app.
    const { embedFriends } = require("./electron/friends/package.cjs");
    await embedFriends(
      path.join(context.appOutDir, `${module.exports.productName}.app`),
      context.packager.projectDir,
      { identity: context.packager.config.mac?.identity },
    );
  },
  files: [
    "dist/**/*",
    "electron/**/*.cjs",
    "electron/native/*.node",
    "build-info.json",
    "package.json",
    "!.release-verification.json",
    "!**/*.test.cjs",
    "!**/*.spec.cjs",
  ],
  asarUnpack: ["electron/native/*.node"],
  // Friends links opened from their web page (docs/FRIENDS.md § Links).
  protocols: [{ name: "Shenzhen Friends link", schemes: ["shenzhen3d"] }],
  extraResources: [
    {
      from: path.join(__dirname, "node_modules/electron/dist/LICENSE"),
      to: "Electron-LICENSE.txt",
    },
    {
      from: path.join(
        __dirname,
        "node_modules/electron/dist/LICENSES.chromium.html",
      ),
      to: "Chromium-LICENSES.html",
    },
  ],
  fileAssociations: [
    {
      ext: "step",
      name: "STEP model",
      description: "STEP model",
      mimeType: "model/step",
      role: "Viewer",
      rank: "Alternate",
    },
    {
      ext: "stp",
      name: "STEP model",
      description: "STEP model",
      mimeType: "model/step",
      role: "Viewer",
      rank: "Alternate",
    },
    {
      ext: "iges",
      name: "IGES model",
      description: "IGES model",
      mimeType: "model/iges",
      role: "Viewer",
      rank: "Alternate",
    },
    {
      ext: "igs",
      name: "IGES model",
      description: "IGES model",
      mimeType: "model/iges",
      role: "Viewer",
      rank: "Alternate",
    },
    {
      ext: "brep",
      name: "Boundary representation model",
      description: "Boundary representation model",
      mimeType: "application/x-brep",
      role: "Viewer",
      rank: "Alternate",
    },
    {
      ext: "brp",
      name: "Boundary representation model",
      description: "Boundary representation model",
      mimeType: "application/x-brep",
      role: "Viewer",
      rank: "Alternate",
    },
    {
      ext: "stl",
      name: "STL mesh",
      description: "STL mesh",
      mimeType: "model/stl",
      role: "Viewer",
      rank: "Alternate",
    },
    {
      ext: "obj",
      name: "OBJ mesh",
      description: "OBJ mesh",
      mimeType: "model/obj",
      role: "Viewer",
      rank: "Alternate",
    },
    {
      ext: "glb",
      name: "Binary glTF model",
      description: "Binary glTF model",
      mimeType: "model/gltf-binary",
      role: "Viewer",
      rank: "Alternate",
    },
    {
      ext: "gltf",
      name: "glTF model",
      description: "glTF model",
      mimeType: "model/gltf+json",
      role: "Viewer",
      rank: "Alternate",
    },
    {
      ext: "3mf",
      name: "3D Manufacturing model",
      description: "3D Manufacturing model",
      mimeType: "model/3mf",
      role: "Viewer",
      rank: "Alternate",
    },
    {
      ext: "ply",
      name: "PLY mesh",
      description: "PLY mesh",
      mimeType: "application/x-ply",
      role: "Viewer",
      rank: "Alternate",
    },
    {
      ext: "off",
      name: "OFF mesh",
      description: "OFF mesh",
      mimeType: "model/x-off",
      role: "Viewer",
      rank: "Alternate",
    },
    {
      ext: "fbx",
      name: "FBX model",
      description: "FBX model",
      mimeType: "application/x-fbx",
      role: "Viewer",
      rank: "Alternate",
    },
    {
      ext: "dae",
      name: "COLLADA model",
      description: "COLLADA model",
      mimeType: "model/vnd.collada+xml",
      role: "Viewer",
      rank: "Alternate",
    },
    {
      ext: "wrl",
      name: "VRML model",
      description: "VRML model",
      mimeType: "model/vrml",
      role: "Viewer",
      rank: "Alternate",
    },
    {
      ext: "vrml",
      name: "VRML model",
      description: "VRML model",
      mimeType: "model/vrml",
      role: "Viewer",
      rank: "Alternate",
    },
    {
      ext: "dxf",
      name: "DXF drawing",
      description: "DXF drawing",
      mimeType: "image/vnd.dxf",
      role: "Viewer",
      rank: "Alternate",
    },
    {
      ext: "dwg",
      name: "DWG drawing",
      description: "DWG drawing",
      mimeType: "image/vnd.dwg",
      role: "Viewer",
      rank: "Alternate",
    },
    {
      ext: "svg",
      name: "SVG drawing",
      description: "SVG drawing",
      mimeType: "image/svg+xml",
      role: "Viewer",
      rank: "Alternate",
    },
    {
      ext: "sz3d",
      name: "Shenzhen 3D project",
      description: "Shenzhen 3D project",
      mimeType: "application/x-shenzhen3d-project",
      role: "Viewer",
      rank: "Owner",
    },
  ],
  mac: {
    target: [
      { target: "dmg", arch: ["arm64"] },
      { target: "zip", arch: ["arm64"] },
    ],
    category: "public.app-category.graphics-design",
    icon: path.join(__dirname, "src-tauri/icons/icon.icns"),
    minimumSystemVersion: "13.0",
    extendInfo: {
      CFBundleDocumentTypes: [
        {
          CFBundleTypeName: "SVG drawing",
          CFBundleTypeRole: "Viewer",
          LSHandlerRank: "Alternate",
          LSItemContentTypes: ["public.svg-image"],
        },
        {
          CFBundleTypeName: "Shenzhen 3D project",
          CFBundleTypeRole: "Viewer",
          LSHandlerRank: "Owner",
          LSItemContentTypes: ["com.shenzhen3d.project"],
        },
      ],
      UTExportedTypeDeclarations: [
        {
          UTTypeIdentifier: "com.shenzhen3d.project",
          UTTypeDescription: "Shenzhen 3D project",
          UTTypeConformsTo: ["public.zip-archive", "public.data"],
          UTTypeTagSpecification: {
            "public.filename-extension": ["sz3d"],
            "public.mime-type": "application/x-shenzhen3d-project",
          },
        },
      ],
    },
    identity: "INTUITION Robotique & Technologies (66LJ4BV7Q3)",
    hardenedRuntime: true,
    // The Friends helper is signed on its own in afterPack, never with the app's entitlements.
    signIgnore: ["Contents/Helpers/Shenzhen Friends\\.app"],
    notarize: false,
  },
  dmg: {
    sign: true,
    title: "Shenzhen 3D ${version}",
    background: path.join(__dirname, "electron/installer/background.png"),
    window: { width: 760, height: 500 },
    iconSize: 112,
    iconTextSize: 13,
    contents: [
      { x: 210, y: 280, type: "file" },
      { x: 550, y: 280, type: "link", path: "/Applications" },
    ],
  },
  // Feed metadata is generated locally; the packaging command always uses
  // --publish never and sets the owner and whether its releases are private.
  publish: {
    provider: "github",
    repo: "shenzhen-3D",
    channel: "latest",
  },
  artifactName: "Shenzhen-3D-${version}-Apple-Silicon.${ext}",
};
