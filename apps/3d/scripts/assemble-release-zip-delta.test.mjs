import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { createHash } from "node:crypto";
import {
  SOURCE_COMMIT,
  validateDeltaInput,
  verifyDeltaMetadata,
  verifyDeltaRelease,
  finalAssetPlan,
  assembleDelta,
  verifyFrozenTag,
  findHeldDraft,
} from "./assemble-release-zip-delta.mjs";
const hash = (b) => createHash("sha256").update(b).digest("hex"),
  repo = "fixture-owner/shenzhen-3D",
  name = "Shenzhen-3D-0.1.6-Apple-Silicon.zip";
async function fixture(t, changes = {}) {
  const directory = await fs.mkdtemp(
    path.join(os.tmpdir(), "zip-delta-tests-"),
  );
  const config = path.join(directory, "config.json");
  await fs.writeFile(
    config,
    JSON.stringify({ version: 1, repositories: [repo] }),
    { mode: 0o600 },
  );
  const prior = process.env.SHENZHEN_RELEASE_UPLOAD_CONFIG;
  process.env.SHENZHEN_RELEASE_UPLOAD_CONFIG = config;
  t.after(async () => {
    if (prior === undefined) delete process.env.SHENZHEN_RELEASE_UPLOAD_CONFIG;
    else process.env.SHENZHEN_RELEASE_UPLOAD_CONFIG = prior;
    await fs.rm(directory, { recursive: true, force: true });
  });
  const target = Buffer.from("exact frozen target bytes"),
    base = Buffer.from("published same-repository base"),
    patch = Buffer.from("fixture patch");
  const input = validateDeltaInput({
    repo,
    tag: "preview-0.1.6",
    commit: SOURCE_COMMIT,
    sha256: hash(target),
    size: target.length,
    baseSHA: hash(base),
    baseSize: base.length,
    patchSHA: hash(patch),
    patchSize: patch.length,
  });
  const metadata = {
    releaseOwner: "fixture-owner",
    sourceCommit: SOURCE_COMMIT,
    sourceDirty: false,
    version: "0.1.6",
    ownerIsolationVerified: true,
    artifacts: [{ file: name, sha256: input.sha256, size: input.size }],
    notarization: {
      zip: { status: "Accepted" },
      dmg: { status: "Accepted" },
      appStapled: true,
      dmgStapled: true,
      codeSignaturesVerified: true,
      gatekeeperAccepted: true,
      embeddedZipAndDmgTicketsValidated: true,
    },
    ...changes.metadata,
  };
  const metadataBytes = Buffer.from(JSON.stringify(metadata));
  const asset = (id, n, b) => ({
    id,
    name: n,
    size: b.length,
    digest: "sha256:" + hash(b),
    state: "uploaded",
  });
  const release = {
    id: 1,
    draft: true,
    tag_name: "preview-0.1.6",
    target_commitish: SOURCE_COMMIT,
    assets: [
      asset(10, input.patchName, patch),
      asset(11, "build-info.json", metadataBytes),
    ],
    ...changes.release,
  };
  const baseRelease = {
    id: 2,
    draft: false,
    published_at: "2026-01-01",
    tag_name: "preview-0.1.4",
    assets: [asset(12, input.baseName, base)],
  };
  const calls = [];
  const run = async (command, args, options = {}) => {
    calls.push([command, ...args]);
    if (command === "zstd") {
      await fs.writeFile(
        args.at(-1),
        changes.wrongReconstruction ? Buffer.from("wrong") : target,
      );
      return "";
    }
    if (args[0] === "release") {
      release.assets.push(asset(13, name, target));
      return "";
    }
    if (args.includes("DELETE")) {
      release.assets = release.assets.filter((a) => a.id !== 10);
      return "";
    }
    const endpoint = args[1];
    if (options.stdoutFile) {
      const id = Number(endpoint.split("/").at(-1));
      await fs.writeFile(
        options.stdoutFile,
        { 10: patch, 11: metadataBytes, 12: base }[id],
      );
      return "";
    }
    if (endpoint.endsWith("/releases/tags/preview-0.1.4"))
      return JSON.stringify(baseRelease);
    if (endpoint.endsWith("/releases?per_page=100&page=1"))
      return JSON.stringify([release]);
    if (endpoint.endsWith("/releases/1")) return JSON.stringify(release);
    if (endpoint === `repos/${repo}/`) return JSON.stringify({ private: true });
    if (endpoint.includes("/git/matching-refs/tags/"))
      return JSON.stringify(changes.refs || []);
    if (endpoint.includes("/git/tags/"))
      return JSON.stringify(changes.tag || {});
    throw Error("Unexpected API request");
  };
  return { input, metadata, release, baseRelease, run, calls };
}
test("strict repository, release, source, digest and byte guards reject before API mutation", async (t) => {
  const f = await fixture(t);
  for (const change of [
    { repo: "foreign/shenzhen-3D" },
    { tag: "preview-0.1.5" },
    { commit: "a".repeat(40) },
    { patchSize: 65 * 1024 * 1024 },
    { sha256: "../bad" },
    { size: 0 },
  ])
    assert.throws(() => validateDeltaInput({ ...f.input, ...change }));
  assert.throws(() =>
    verifyDeltaRelease({ ...f.release, draft: false }, f.input),
  );
  assert.throws(() =>
    verifyDeltaRelease({ ...f.baseRelease, draft: true }, f.input, true),
  );
});
test("final provenance must bind repository owner, source and actual notarized ZIP", async (t) => {
  const f = await fixture(t);
  for (const change of [
    { releaseOwner: "foreign" },
    { sourceDirty: true },
    { sourceCommit: "a".repeat(40) },
    { ownerIsolationVerified: false },
    { artifacts: [] },
    { notarization: { zip: { status: "Accepted" } } },
  ])
    assert.throws(() =>
      verifyDeltaMetadata({ ...f.metadata, ...change }, f.input),
    );
});
test("same-repository assembly verifies bytes before upload, then removes only exact patch", async (t) => {
  const f = await fixture(t);
  const result = await assembleDelta(f.input, { run: f.run });
  assert.equal(result.verified, true);
  assert.equal(result.published, false);
  assert.equal(f.calls.filter((a) => a.includes("DELETE")).length, 1);
  assert.ok(
    f.calls
      .find((a) => a.includes("DELETE"))
      .at(-1)
      .endsWith("/assets/10"),
  );
  assert.equal(f.calls.filter((a) => a[1] === "release").length, 1);
  assert.ok(f.calls.every((a) => !a.includes("--clobber")));
});
test("wrong reconstructed bytes never upload or delete assets", async (t) => {
  const f = await fixture(t, { wrongReconstruction: true });
  await assert.rejects(assembleDelta(f.input, { run: f.run }), /Reconstructed/);
  assert.ok(f.calls.every((a) => !a.includes("DELETE") && a[1] !== "release"));
});
test("mismatched existing final asset remains untouched", async (t) => {
  const f = await fixture(t);
  f.release.assets.push({
    id: 13,
    name,
    size: f.input.size,
    digest: "sha256:" + "f".repeat(64),
    state: "uploaded",
  });
  assert.throws(() => finalAssetPlan(f.release.assets.at(-1), f.input));
  await assert.rejects(
    assembleDelta(f.input, { run: f.run }),
    /identity or digest/,
  );
  assert.ok(f.calls.every((a) => !a.includes("DELETE") && a[1] !== "release"));
});
test("already verified final ZIP skips reconstruction and upload, cleanup stays hash bound", async (t) => {
  const f = await fixture(t);
  f.release.assets.push({
    id: 13,
    name,
    size: f.input.size,
    digest: "sha256:" + f.input.sha256,
    state: "uploaded",
  });
  await assembleDelta(f.input, { run: f.run });
  assert.ok(f.calls.every((a) => a[0] !== "zstd" && a[1] !== "release"));
});
test("wrong draft provenance or patch digest prevents cleanup", async (t) => {
  const f = await fixture(t, { metadata: { releaseOwner: "foreign" } });
  await assert.rejects(
    assembleDelta(f.input, { run: f.run }),
    /provenance mismatch/,
  );
  assert.ok(f.calls.every((a) => !a.includes("DELETE") && a[1] !== "release"));
});
test("wrong patch digest prevents reconstruction or cleanup", async (t) => {
  const f = await fixture(t);
  f.release.assets[0].digest = "sha256:" + "0".repeat(64);
  await assert.rejects(
    assembleDelta(f.input, { run: f.run }),
    /identity or digest/,
  );
});

test("existing tags are resolved and annotated tags must peel to frozen source", async (t) => {
  const f = await fixture(t),
    ref = {
      ref: "refs/tags/preview-0.1.6",
      object: { type: "commit", sha: "b".repeat(40) },
    };
  await assert.rejects(
    verifyFrozenTag(async () => [ref], f.input),
    /does not point/,
  );
  await verifyFrozenTag(async () => [], f.input);
  ref.object = { type: "tag", sha: "c".repeat(40) };
  await verifyFrozenTag(
    async (endpoint) =>
      endpoint.startsWith("git/matching")
        ? [ref]
        : {
            sha: "c".repeat(40),
            object: { type: "commit", sha: SOURCE_COMMIT },
          },
    f.input,
  );
  await assert.rejects(
    verifyFrozenTag(
      async (endpoint) =>
        endpoint.startsWith("git/matching")
          ? [ref]
          : {
              sha: "c".repeat(40),
              object: { type: "commit", sha: "b".repeat(40) },
            },
      f.input,
    ),
    /does not point/,
  );
});
test("completed rerun succeeds after its patch has already been deleted", async (t) => {
  const f = await fixture(t);
  f.release.assets = f.release.assets.filter((a) => a.id !== 10);
  f.release.assets.push({
    id: 13,
    name,
    size: f.input.size,
    digest: "sha256:" + f.input.sha256,
    state: "uploaded",
  });
  const result = await assembleDelta(f.input, { run: f.run });
  assert.equal(result.verified, true);
  assert.ok(
    f.calls.every(
      (a) => a[0] !== "zstd" && a[1] !== "release" && !a.includes("DELETE"),
    ),
  );
});

test("held draft lookup uses bounded lists instead of the published-tag endpoint", async (t) => {
  const f = await fixture(t),
    calls = [];
  const draft = await findHeldDraft(async (endpoint) => {
    calls.push(endpoint);
    return endpoint.endsWith("page=1")
      ? Array.from({ length: 100 }, (_, i) => ({ tag_name: `unrelated-${i}` }))
      : [f.release];
  }, f.input);
  assert.equal(draft.id, f.release.id);
  assert.equal(calls.length, 2);
  assert.ok(
    calls.every((endpoint) =>
      endpoint.startsWith("releases?per_page=100&page="),
    ),
  );
  await assembleDelta(f.input, { run: f.run });
  assert.ok(
    f.calls.every(
      (call) =>
        !call.some((arg) => arg.includes?.("releases/tags/preview-0.1.6")),
    ),
  );
});
test("held draft lookup refuses duplicate matches, missing matches and unbounded pages", async (t) => {
  const f = await fixture(t);
  await assert.rejects(
    findHeldDraft(async () => [f.release, { ...f.release, id: 99 }], f.input),
    /exactly one/,
  );
  await assert.rejects(
    findHeldDraft(async () => [], f.input),
    /not found/,
  );
  let calls = 0;
  await assert.rejects(
    findHeldDraft(async () => {
      calls++;
      return Array.from({ length: 100 }, () => ({ tag_name: "other" }));
    }, f.input),
    /pagination exceeds/,
  );
  assert.equal(calls, 5);
});
