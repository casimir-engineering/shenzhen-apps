import fs from "node:fs/promises";
import path from "node:path";
import { createHash } from "node:crypto";
import { createRequire } from "node:module";
import { spawn } from "node:child_process";
import { verifyRuntimeArchive } from "./package-mac.mjs";
const root = process.cwd(),
  require = createRequire(path.join(root, "package.json"));
const arg = (name) =>
  process.argv.find((x) => x.startsWith(`--${name}=`))?.slice(name.length + 3);
for (const name of ["original", "output", "profile", "phase"])
  if (!arg(name)) throw Error(`Missing --${name}=value`);
const original = await fs.realpath(arg("original")),
  output = await fs.realpath(arg("output"));
const safeRoot = await fs.realpath(path.join(root, "artifacts/electron"));
if (
  !original.startsWith(safeRoot + path.sep) ||
  !output.startsWith(safeRoot + path.sep) ||
  original === output ||
  !path.basename(output).includes("-notarized-")
)
  throw Error(
    "Original and separate notarized output must be under artifacts/electron",
  );
const pkg = JSON.parse(
  await fs.readFile(path.join(original, "staging/package.json"), "utf8"),
);
const config = require(path.join(root, "electron-builder.cjs"));
const base = JSON.parse(
  await fs.readFile(path.join(original, "build-info.json"), "utf8"),
);
const {
  resolveArtifactReleaseOwner,
  resolveArtifactReleaseAccess,
  validatePackagedFeed,
} = require(path.join(root, "electron/release-channel.cjs"));
const releaseOwner = resolveArtifactReleaseOwner(pkg, base);
const releaseAccess = resolveArtifactReleaseAccess(pkg, base);
const isolationPolicy = JSON.parse(
  await fs
    .readFile(path.join(original, "staging/.release-verification.json"), "utf8")
    .catch((error) => {
      if (error.code === "ENOENT") return "{}";
      throw error;
    }),
);
if (base.version !== pkg.version || base.sourceDirty)
  throw Error("Expected frozen clean production provenance");
const filename = (ext) => `Shenzhen-3D-${pkg.version}-Apple-Silicon.${ext}`;
const originalApp = path.join(
  original,
  "mac-arm64",
  config.productName + ".app",
);
const app = path.join(output, "mac-arm64", config.productName + ".app");
function verifyChannel(appPath) {
  const resources = path.join(appPath, "Contents/Resources");
  // Native addons live beside ASAR and may be re-signed during packaging.
  // Validate their signature-stripped code against the frozen provenance too.
  verifyRuntimeArchive(path.join(resources, "app.asar"), base, isolationPolicy);
  const feed = require("js-yaml").load(
    require("node:fs").readFileSync(
      path.join(resources, "app-update.yml"),
      "utf8",
    ),
  );
  validatePackagedFeed(feed, releaseOwner, releaseAccess);
  if (pkg.releaseOwner !== undefined) {
    const metadata = JSON.parse(
      require("@electron/asar").extractFile(
        path.join(resources, "app.asar"),
        "package.json",
      ),
    );
    if (metadata.releaseOwner !== releaseOwner)
      throw Error("App release owner does not match provenance");
  }
}
verifyChannel(originalApp);
const sha = async (file, algorithm = "sha256", encoding = "hex") =>
  createHash(algorithm)
    .update(await fs.readFile(file))
    .digest(encoding);
const exists = async (p) => {
  try {
    await fs.access(p);
    return true;
  } catch (e) {
    if (e.code === "ENOENT") return false;
    throw e;
  }
};
const run = (command, args, log) =>
  new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: root,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "",
      stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => (stdout += chunk));
    child.stderr.on("data", (chunk) => (stderr += chunk));
    child.once("error", reject);
    child.once("close", async (code) => {
      try {
        // Never persist upload/auth diagnostics. This helper performs no submissions.
        const sanitized = (stdout + stderr).replace(
          /https?:\/\/[^\s"<>]+/g,
          "[redacted URL]",
        );
        if (log) await fs.writeFile(path.join(output, log), sanitized);
        if (code !== 0)
          reject(
            Error(
              `${command} failed (${code}); see ${log || "local command status"}`,
            ),
          );
        else resolve({ stdout, stderr });
      } catch (error) {
        reject(error);
      }
    });
  });
const verifyOriginal = async () => {
  for (const entry of base.artifacts || [])
    if ((await sha(path.join(original, entry.file))) !== entry.sha256)
      throw Error("Original frozen artifact changed: " + entry.file);
};
const accepted = async (kind, id) => {
  if (!id || !/^[a-f0-9-]{36}$/.test(id))
    throw Error(`Missing valid --${kind}-submission=id`);
  const status = JSON.parse(
    (
      await run("xcrun", [
        "notarytool",
        "info",
        id,
        "--keychain-profile",
        arg("profile"),
        "--output-format",
        "json",
      ])
    ).stdout,
  );
  await fs.writeFile(
    path.join(output, `notary-${kind}-accepted.json`),
    JSON.stringify(status, null, 2) + "\n",
  );
  if (status.status !== "Accepted")
    throw Error(
      `${kind} notarization is ${status.status}; no stapling performed`,
    );
  const log = JSON.parse(
    (
      await run("xcrun", [
        "notarytool",
        "log",
        id,
        "--keychain-profile",
        arg("profile"),
        "--output-format",
        "json",
      ])
    ).stdout,
  );
  await fs.writeFile(
    path.join(output, `notary-${kind}-log.json`),
    JSON.stringify(log, null, 2).replace(
      /https?:\/\/[^\s"<>]+/g,
      "[redacted URL]",
    ) + "\n",
  );
  return {
    id,
    status: status.status,
    log: `notary-${kind}-log.json`,
    archiveSha256: log.sha256,
  };
};
const verifyApp = async (p, label, { stapled = true } = {}) => {
  verifyChannel(p);
  await run(
    "codesign",
    ["--verify", "--deep", "--strict", p],
    label + "-codesign.txt",
  );
  if (stapled)
    await run("xcrun", ["stapler", "validate", p], label + "-stapler.txt");
  await run(
    "spctl",
    ["--assess", "--type", "execute", "--verbose=4", p],
    label + "-gatekeeper.txt",
  );
  if (
    (await sha(path.join(p, "Contents/Resources/app.asar"))) !==
    (await sha(path.join(originalApp, "Contents/Resources/app.asar")))
  )
    throw Error(label + " ASAR differs from frozen source");
};
await verifyOriginal();
if (arg("phase") === "package") {
  // --dmg-from-original: the DMG was notarized on its own (tools/release.sh), and it ships as it was submitted, holding
  // the app as signed. Apple issues a ticket for every piece of code in a submission, so the app inside staples from
  // the DMG's submission (--dmg-submission) and the ZIP needs none of its own; it is made again here from the stapled
  // app, and the feed keeps the original DMG's entry, which finalize updates once the DMG is stapled.
  const dmgFromOriginal = process.argv.includes("--dmg-from-original");
  const fromDmg = dmgFromOriginal && !arg("zip-submission");
  const notarization = fromDmg
    ? await accepted("dmg", arg("dmg-submission"))
    : await accepted("zip", arg("zip-submission"));
  if (
    notarization.archiveSha256 !==
    (await sha(path.join(original, filename(fromDmg ? "dmg" : "zip"))))
  )
    throw Error("Apple's log does not match the frozen submitted archive");
  if ((await exists(app)) || (await exists(path.join(output, filename("zip")))))
    throw Error("Refusing to replace an existing notarized output app/archive");
  await fs.mkdir(path.dirname(app), { recursive: true });
  await run("ditto", [originalApp, app]);
  await run("xcrun", ["stapler", "staple", app], "app-staple.txt");
  await verifyApp(app, "app");
  const electron = JSON.parse(
    await fs.readFile(
      path.join(root, "node_modules/electron/package.json"),
      "utf8",
    ),
  ).version;
  await run(
    process.execPath,
    [
      path.join(root, "node_modules/electron-builder/out/cli/cli.js"),
      "--projectDir",
      path.join(original, "staging"),
      "--config",
      path.join(root, "electron-builder.cjs"),
      "--config.publish.owner",
      releaseOwner,
      "--config.directories.output",
      output,
      "--config.electronVersion",
      electron,
      "--prepackaged",
      app,
      "--mac",
      ...(dmgFromOriginal ? ["zip"] : []),
      "--arm64",
      "--publish",
      "never",
    ],
    "prepackaged-builder.txt",
  );
  if (dmgFromOriginal) {
    const yaml = require("js-yaml");
    await fs.copyFile(
      path.join(original, filename("dmg")),
      path.join(output, filename("dmg")),
    );
    const metadataFile = path.join(output, "latest-mac.yml");
    const metadata = yaml.load(await fs.readFile(metadataFile, "utf8"));
    const originalMetadata = yaml.load(
      await fs.readFile(path.join(original, "latest-mac.yml"), "utf8"),
    );
    const dmgEntry = originalMetadata.files.find(
      (x) => x.url === filename("dmg"),
    );
    if (!dmgEntry) throw Error("The original feed lists no DMG");
    metadata.files = [
      ...metadata.files.filter((x) => x.url !== filename("dmg")),
      dmgEntry,
    ];
    await fs.writeFile(
      metadataFile,
      yaml.dump(metadata, { lineWidth: -1, noRefs: true }),
    );
  }
  await verifyApp(app, "app-after-package");
  await fs.writeFile(
    path.join(output, "notarization-package.json"),
    JSON.stringify(
      {
        original,
        output,
        app,
        zip: notarization,
        appTicketFrom: fromDmg ? "dmg" : "zip",
        dmgFromOriginal,
        sourceCommit: base.sourceCommit,
        releaseOwner,
        asarSha256: await sha(path.join(app, "Contents/Resources/app.asar")),
        packagedAt: new Date().toISOString(),
      },
      null,
      2,
    ) + "\n",
  );
  console.log(
    JSON.stringify({
      phase: "package",
      app,
      zip: path.join(output, filename("zip")),
      dmg: path.join(output, filename("dmg")),
      zipSubmission: notarization.id,
    }),
  );
} else if (arg("phase") === "verify-zip") {
  const verify = path.join(output, "early-zip-verification");
  await fs.mkdir(verify, { recursive: false });
  const zip = path.join(output, filename("zip"));
  await run("ditto", ["-x", "-k", zip, verify]);
  await verifyApp(
    path.join(verify, config.productName + ".app"),
    "early-embedded-zip-app",
  );
  await fs.rm(verify, { recursive: true });
  const frozen = {
    path: zip,
    size: (await fs.stat(zip)).size,
    sha256: await sha(zip),
    sha512: await sha(zip, "sha512", "base64"),
    frozen: true,
    embeddedAppTicketValidated: true,
    signatureVerified: true,
    gatekeeperAccepted: true,
  };
  await fs.writeFile(
    path.join(output, "frozen-zip.json"),
    JSON.stringify(frozen, null, 2) + "\n",
  );
  console.log(JSON.stringify(frozen));
} else if (arg("phase") === "finalize") {
  const packaged = JSON.parse(
    await fs.readFile(path.join(output, "notarization-package.json"), "utf8"),
  );
  const dmg = path.join(output, filename("dmg"));
  if (await exists(path.join(output, "build-info.json")))
    throw Error(
      "Finalized output is immutable; refusing repeated finalization",
    );
  const notarization = await accepted("dmg", arg("dmg-submission"));
  if (notarization.archiveSha256 !== (await sha(dmg)))
    throw Error("Apple DMG log does not match current pre-staple DMG");
  await run("xcrun", ["stapler", "staple", dmg], "dmg-staple.txt");
  await run("xcrun", ["stapler", "validate", dmg], "dmg-stapler.txt");
  await run("codesign", ["--verify", "--strict", dmg], "dmg-codesign.txt");
  await run(
    "spctl",
    [
      "--assess",
      "--type",
      "open",
      "--context",
      "context:primary-signature",
      "--verbose=4",
      dmg,
    ],
    "dmg-gatekeeper.txt",
  );
  await run("hdiutil", ["verify", dmg], "dmg-integrity.txt");
  const {
    buildBlockMap,
  } = require("app-builder-lib/out/targets/blockmap/blockmap");
  const yaml = require("js-yaml");
  const metadataFile = path.join(output, "latest-mac.yml");
  const metadata = yaml.load(await fs.readFile(metadataFile, "utf8"));
  const artifacts = [];
  for (const ext of ["zip", "dmg"]) {
    const name = filename(ext),
      file = path.join(output, name);
    const blockmap = await buildBlockMap(file, "gzip", file + ".blockmap");
    const entry = metadata.files.find((x) => x.url === name);
    if (!entry) throw Error("Missing metadata artifact " + name);
    entry.sha512 = blockmap.sha512;
    entry.size = (await fs.stat(file)).size;
    delete entry.blockMapSize;
    artifacts.push({
      file: name,
      size: entry.size,
      sha256: await sha(file),
      sha512: entry.sha512,
    });
  }
  metadata.path = filename("zip");
  metadata.sha512 = artifacts[0].sha512;
  await fs.writeFile(
    metadataFile,
    yaml.dump(metadata, { lineWidth: -1, noRefs: true }),
  );
  const zipVerify = path.join(output, "zip-verification");
  await fs.mkdir(zipVerify, { recursive: false });
  await run("ditto", [
    "-x",
    "-k",
    path.join(output, filename("zip")),
    zipVerify,
  ]);
  await verifyApp(
    path.join(zipVerify, config.productName + ".app"),
    "embedded-zip-app",
  );
  await fs.rm(zipVerify, { recursive: true });
  const mount = path.join(output, "dmg-verification-volume");
  await fs.mkdir(mount, { recursive: false });
  await run(
    "hdiutil",
    ["attach", "-readonly", "-nobrowse", "-mountpoint", mount, dmg],
    "dmg-attach.txt",
  );
  try {
    // An original DMG holds the app as signed, before its own ticket was stapled: the DMG's stapled ticket covers it.
    await verifyApp(path.join(mount, config.productName + ".app"), "embedded-dmg-app", {
      stapled: !packaged.dmgFromOriginal,
    });
  } finally {
    await run("hdiutil", ["detach", mount], "dmg-detach.txt");
  }
  const sidecars = [];
  for (const ext of ["zip", "dmg"]) {
    const name = filename(ext) + ".blockmap";
    sidecars.push({
      file: name,
      size: (await fs.stat(path.join(output, name))).size,
      sha256: await sha(path.join(output, name)),
    });
  }
  const final = {
    ...base,
    releaseOwner,
    artifacts,
    sidecars,
    updateMetadata: { file: "latest-mac.yml", sha256: await sha(metadataFile) },
    notarization: {
      zip: packaged.zip,
      dmg: notarization,
      appStapled: true,
      dmgStapled: true,
      dmgHoldsStapledApp: !packaged.dmgFromOriginal,
      codeSignaturesVerified: true,
      gatekeeperAccepted: true,
      embeddedZipAndDmgTicketsValidated: true,
      originalSignedArtifacts: base.artifacts,
      finalizedAt: new Date().toISOString(),
    },
  };
  await fs.writeFile(
    path.join(output, "build-info.json"),
    JSON.stringify(final, null, 2) + "\n",
  );
  await verifyOriginal();
  for (const entry of artifacts) {
    const meta = metadata.files.find((x) => x.url === entry.file);
    if (
      (await sha(path.join(output, entry.file), "sha512", "base64")) !==
        meta.sha512 ||
      meta.size !== (await fs.stat(path.join(output, entry.file))).size
    )
      throw Error("Final metadata fingerprint mismatch");
  }
  console.log(
    JSON.stringify(
      {
        phase: "finalize",
        output,
        artifacts,
        sidecars,
        updateMetadata: final.updateMetadata,
        notarization: final.notarization,
      },
      null,
      2,
    ),
  );
} else throw Error("Phase must be package, verify-zip or finalize");
