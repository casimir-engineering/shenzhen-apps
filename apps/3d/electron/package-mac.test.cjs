const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const path = require("node:path");
const os = require("node:os");
const asar = require("@electron/asar");
const RELEASE_OWNERS = ["fixture-primary", "fixture-secondary"];
// Stage the first as a public build and the second as the private owner's.
const PRIVATE_OWNER = "fixture-secondary";
const access = (owner) => (owner === PRIVATE_OWNER ? "private" : "public");

for (const releaseOwner of RELEASE_OWNERS) {
  test(`runtime staging and actual ASAR retain ${releaseOwner} with all production dependencies`, async (t) => {
    const temp = await fs.mkdtemp(
      path.join(os.tmpdir(), "shenzhen-package-channel-"),
    );
    t.after(() => fs.rm(temp, { recursive: true, force: true }));
    const staging = path.join(temp, "staging");
    const pkg = require("../package.json");
    const { stageRuntime, verifyRuntimeArchive, verifyOwnerIsolation } =
      await import("./package-mac.mjs");
    const forbiddenOwners = RELEASE_OWNERS.filter(
      (owner) => owner !== releaseOwner,
    );
    const metadata = await stageRuntime(staging, pkg, {
      releaseOwner,
      forbiddenOwners,
      privateReleaseOwner: PRIVATE_OWNER,
    });
    assert.equal(metadata.releaseOwner, releaseOwner);
    assert.equal(metadata.releaseAccess, access(releaseOwner));
    const staged = JSON.parse(
      await fs.readFile(path.join(staging, "package.json")),
    );
    assert.equal(staged.releaseOwner, releaseOwner);
    assert.equal(staged.releaseAccess, access(releaseOwner));
    assert.equal(metadata.runtimeDependencies.length, 16);
    assert.ok(
      Object.hasOwn(metadata.runtimeFiles, "electron/release-channel.cjs"),
    );
    assert.ok(
      Object.keys(metadata.runtimeFiles).every(
        (file) => !file.endsWith(".test.cjs"),
      ),
    );
    const archive = path.join(temp, "app.asar");
    const policyPath = path.join(staging, ".release-verification.json");
    const policyBytes = await fs.readFile(policyPath);
    await fs.rm(policyPath);
    await asar.createPackage(staging, archive);
    await fs.writeFile(policyPath, policyBytes, { mode: 0o600 });
    assert.ok(
      !asar.listPackage(archive).includes("/.release-verification.json"),
    );
    assert.equal(
      verifyOwnerIsolation(archive, releaseOwner, { forbiddenOwners })
        .ownerIsolationVerified,
      true,
    );
    assert.equal(
      verifyRuntimeArchive(archive, metadata).packagedDependencyCount,
      16,
    );
    assert.throws(
      () =>
        verifyRuntimeArchive(archive, {
          ...metadata,
          releaseOwner: RELEASE_OWNERS.find((x) => x !== releaseOwner),
        }),
      /does not match provenance/,
    );
    assert.throws(
      () =>
        verifyRuntimeArchive(archive, {
          ...metadata,
          releaseAccess:
            access(releaseOwner) === "private" ? "public" : "private",
        }),
      /access does not match provenance/,
    );
    const config = require("../electron-builder.cjs");
    await fs.writeFile(
      path.join(staging, "build-info.json"),
      JSON.stringify(metadata),
    );
    const appOutDir = path.join(temp, "out");
    const resources = path.join(
      appOutDir,
      "Shenzhen 3D.app/Contents/Resources",
    );
    await fs.mkdir(resources, { recursive: true });
    await fs.copyFile(archive, path.join(resources, "app.asar"));
    const isPrivate = access(releaseOwner) === "private";
    const context = {
      appOutDir,
      packager: {
        projectDir: staging,
        config: {
          publish: {
            ...config.publish,
            owner: releaseOwner,
            private: isPrivate,
          },
        },
      },
    };
    await config.afterPack(context);
    context.packager.config.publish.private = !isPrivate;
    await assert.rejects(
      config.afterPack(context),
      /does not match release owner/,
    );
    context.packager.config.publish.private = isPrivate;
    context.packager.config.publish.owner = RELEASE_OWNERS.find(
      (x) => x !== releaseOwner,
    );
    await assert.rejects(
      config.afterPack(context),
      /does not match release owner/,
    );
  });
}

test("archive isolation rejects foreign text and repository URLs, including frontend assets", async (t) => {
  const temp = await fs.mkdtemp(
    path.join(os.tmpdir(), "shenzhen-owner-isolation-"),
  );
  t.after(() => fs.rm(temp, { recursive: true, force: true }));
  const source = path.join(temp, "source"),
    asset = path.join(source, "frontend.js");
  await fs.mkdir(source);
  const { verifyOwnerIsolation } = await import("./package-mac.mjs");
  for (const [index, text] of [
    'const source="fixture-secondary";',
    'const url="https://github.com/another-source/shenzhen-3D";',
  ].entries()) {
    await fs.writeFile(asset, text);
    const archive = path.join(temp, `bad-${index}.asar`);
    await asar.createPackage(source, archive);
    assert.throws(
      () =>
        verifyOwnerIsolation(archive, "fixture-primary", {
          forbiddenOwners: ["fixture-secondary"],
        }),
      /Foreign release/,
    );
  }
  await fs.writeFile(
    asset,
    'const url="https://github.com/fixture-primary/shenzhen-3D";',
  );
  const good = path.join(temp, "good.asar");
  await asar.createPackage(source, good);
  assert.deepEqual(verifyOwnerIsolation(good, "fixture-primary"), {
    ownerIsolationVerified: true,
    ownerIsolationScannedFiles: 1,
  });
});

test("staged license notices name the release owner's source repository", async (t) => {
  const temp = await fs.mkdtemp(path.join(os.tmpdir(), "shenzhen-notices-"));
  t.after(() => fs.rm(temp, { recursive: true, force: true }));
  const staging = path.join(temp, "staging");
  const notice =
    "The complete source code of Shenzhen 3D is at\n" +
    "https://github.com/casimir-engineering/shenzhen-3D and in the\n" +
    "shenzhen-apps repository at https://github.com/casimir-engineering/shenzhen-apps.\n";
  await fs.mkdir(path.join(staging, "dist/licenses"), { recursive: true });
  await fs.writeFile(path.join(staging, "dist/THIRD_PARTY.txt"), notice);
  await fs.writeFile(
    path.join(staging, "dist/licenses/THIRD_PARTY.txt"),
    notice,
  );
  const { stageRuntime, verifyOwnerIsolation } =
    await import("./package-mac.mjs");
  await stageRuntime(staging, require("../package.json"), {
    releaseOwner: "fixture-primary",
  });
  for (const file of [
    "dist/THIRD_PARTY.txt",
    "dist/licenses/THIRD_PARTY.txt",
  ]) {
    const text = await fs.readFile(path.join(staging, file), "utf8");
    assert.match(text, /github\.com\/fixture-primary\/shenzhen-3D and/);
    assert.match(text, /github\.com\/casimir-engineering\/shenzhen-apps\./);
  }
  await fs.rm(path.join(staging, ".release-verification.json"));
  const archive = path.join(temp, "app.asar");
  await asar.createPackage(staging, archive);
  assert.equal(
    verifyOwnerIsolation(archive, "fixture-primary").ownerIsolationVerified,
    true,
  );
});

test("local exclusion policy is rejected even without an owner scan", async (t) => {
  const temp = await fs.mkdtemp(
    path.join(os.tmpdir(), "shenzhen-private-policy-"),
  );
  t.after(() => fs.rm(temp, { recursive: true, force: true }));
  const source = path.join(temp, "source");
  await fs.mkdir(source);
  await fs.writeFile(path.join(source, ".release-verification.json"), "{}");
  const archive = path.join(temp, "bad.asar");
  await asar.createPackage(source, archive);
  const { verifyRuntimeArchive } = await import("./package-mac.mjs");
  assert.throws(
    () =>
      verifyRuntimeArchive(archive, {
        runtimeFiles: {},
        runtimeDependencies: [],
      }),
    /must not be packaged/,
  );
});

test("release tooling refuses to package a GitHub token into a public build", async (t) => {
  const temp = await fs.mkdtemp(path.join(os.tmpdir(), "shenzhen-token-"));
  t.after(() => fs.rm(temp, { recursive: true, force: true }));
  const source = path.join(temp, "source");
  await fs.mkdir(path.join(source, "dist"), { recursive: true });
  await fs.writeFile(
    path.join(source, "package.json"),
    JSON.stringify({
      releaseOwner: "casimir-engineering",
      releaseAccess: "public",
    }),
  );
  const { verifyRuntimeArchive } = await import("./package-mac.mjs");
  const provenance = {
    releaseOwner: "casimir-engineering",
    releaseAccess: "public",
    runtimeFiles: {},
    runtimeDependencies: [],
  };
  // Built at runtime so no credential-shaped literal sits in the source.
  const fake = "ghp_" + "Z9".repeat(18);
  await fs.writeFile(
    path.join(source, "dist/app.js"),
    `fetch(u,{headers:{authorization:"token ${fake}"}})`,
  );
  const bad = path.join(temp, "bad.asar");
  await asar.createPackage(source, bad);
  assert.throws(
    () => verifyRuntimeArchive(bad, provenance),
    /GitHub token found in packaged file: \/dist\/app\.js/,
  );
  await fs.writeFile(path.join(source, "dist/app.js"), "fetch(u)");
  const good = path.join(temp, "good.asar");
  await asar.createPackage(source, good);
  assert.equal(
    verifyRuntimeArchive(good, provenance).packagedDependencyCount,
    0,
  );
});
