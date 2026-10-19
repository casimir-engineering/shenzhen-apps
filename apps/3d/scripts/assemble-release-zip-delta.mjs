#!/usr/bin/env node
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { createHash } from "node:crypto";
import { spawn } from "node:child_process";
import { pathToFileURL } from "node:url";
import { assertAuthorizedRepository } from "./upload-release-asset-config.mjs";
const BASE_TAG = "preview-0.1.4",
  BASE_NAME = "Shenzhen-3D-0.1.4-Apple-Silicon.zip";
export const SOURCE_COMMIT = "5a657b3647ebfeccba512a9e2cf2da7990e6435a";
const TAG = "preview-0.1.6",
  NAME = "Shenzhen-3D-0.1.6-Apple-Silicon.zip";
const hex = (value) =>
  typeof value === "string" && /^[a-f0-9]{64}$/.test(value);
export function validateDeltaInput(input) {
  assertAuthorizedRepository(input.repo);
  if (input.tag !== TAG || input.commit !== SOURCE_COMMIT)
    throw Error("Expected authorized draft and full source commit");
  if (![input.sha256, input.baseSHA, input.patchSHA].every(hex))
    throw Error("Expected exact SHA256 digests");
  for (const n of [input.size, input.baseSize, input.patchSize])
    if (!Number.isSafeInteger(n) || n < 1 || n > 224 * 1024 * 1024)
      throw Error("Invalid byte count");
  if (input.patchSize > 64 * 1024 * 1024)
    throw Error("Delta exceeds bounded upload budget");
  return {
    ...input,
    name: NAME,
    baseName: BASE_NAME,
    baseTag: BASE_TAG,
    patchName: `zip-delta-${input.sha256}.zst`,
  };
}
export function verifyDeltaRelease(release, input, base = false) {
  if (
    !Number.isSafeInteger(release.id) ||
    release.tag_name !== (base ? BASE_TAG : TAG)
  )
    throw Error("Unexpected release identity");
  if (
    base
      ? release.draft || !release.published_at
      : !release.draft || release.target_commitish !== input.commit
  )
    throw Error(
      "Expected published base and held draft at exact source commit",
    );
}
export async function findHeldDraft(api, input) {
  let matched;
  for (let page = 1; page <= 5; page++) {
    const releases = await api(`releases?per_page=100&page=${page}`);
    if (!Array.isArray(releases) || releases.length > 100)
      throw Error("Invalid release list response");
    for (const release of releases) {
      if (release.tag_name !== input.tag) continue;
      if (matched) throw Error("Release tag must match exactly one held draft");
      matched = release;
    }
    if (releases.length < 100) {
      if (!matched) throw Error("Expected held draft was not found");
      verifyDeltaRelease(matched, input);
      return matched;
    }
  }
  throw Error("Release pagination exceeds bounded verification");
}
export async function verifyFrozenTag(api, input) {
  const refs = await api(`git/matching-refs/tags/${input.tag}`);
  if (!Array.isArray(refs)) throw Error("Invalid tag reference response");
  const exact = refs.filter((ref) => ref.ref === `refs/tags/${input.tag}`);
  if (exact.length > 1) throw Error("Ambiguous release tag");
  if (!exact.length) return; // Held draft will create its frozen target on publication.
  let object = exact[0].object;
  for (let depth = 0; depth < 4; depth++) {
    if (!/^[a-f0-9]{40}$/.test(object?.sha || ""))
      throw Error("Invalid tag object");
    if (object.type === "commit") {
      if (object.sha !== input.commit)
        throw Error("Existing release tag does not point to frozen source");
      return;
    }
    if (object.type !== "tag") throw Error("Invalid release tag type");
    const tag = await api(`git/tags/${object.sha}`);
    if (tag.sha !== object.sha) throw Error("Annotated tag identity mismatch");
    object = tag.object;
  }
  throw Error("Release tag nesting exceeds bounded verification");
}
export function verifyDeltaMetadata(metadata, input) {
  const item = metadata?.artifacts?.find((a) => a.file === NAME);
  if (
    metadata?.releaseOwner !== input.repo.split("/")[0] ||
    metadata?.sourceCommit !== input.commit ||
    metadata?.sourceDirty !== false ||
    metadata?.version !== "0.1.6" ||
    metadata?.ownerIsolationVerified !== true ||
    item?.sha256 !== input.sha256 ||
    item?.size !== input.size
  )
    throw Error("Final artifact provenance mismatch");
  const n = metadata.notarization;
  if (
    n?.zip?.status !== "Accepted" ||
    n?.dmg?.status !== "Accepted" ||
    n.dmgStapled !== true ||
    n.appStapled !== true ||
    n.codeSignaturesVerified !== true ||
    n.gatekeeperAccepted !== true ||
    n.embeddedZipAndDmgTicketsValidated !== true
  )
    throw Error("Expected verified final notarized provenance");
}
export function exactAsset(asset, name, sha256, size) {
  if (
    !asset ||
    !Number.isSafeInteger(asset.id) ||
    asset.name !== name ||
    asset.state !== "uploaded" ||
    asset.size !== size ||
    asset.digest !== `sha256:${sha256}`
  )
    throw Error("Release asset identity or digest mismatch");
  return asset;
}
export function finalAssetPlan(asset, input) {
  if (!asset) return "upload";
  exactAsset(asset, NAME, input.sha256, input.size);
  return "skip";
}
export async function fileSHA(filename) {
  const { createReadStream } = await import("node:fs");
  const hash = createHash("sha256");
  for await (const bytes of createReadStream(filename)) hash.update(bytes);
  return hash.digest("hex");
}
export async function run(command, args, { stdoutFile } = {}) {
  const file = stdoutFile ? await fs.open(stdoutFile, "wx", 0o600) : undefined;
  return new Promise((resolve, reject) => {
    let output = "",
      exceeded = false,
      done = false;
    const child = spawn(command, args, {
      shell: false,
      stdio: ["ignore", file ? file.fd : "pipe", "pipe"],
      env: { ...process.env, GH_HOST: "github.com" },
    });
    const timer = setTimeout(() => child.kill("SIGTERM"), 10 * 60 * 1000);
    timer.unref();
    const finish = async (code) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      try {
        const size = file ? (await file.stat()).size : output.length;
        if (file) await file.close();
        if (code !== 0 || exceeded || size > 224 * 1024 * 1024)
          throw Error(
            "Release command failed; credentials and private diagnostics suppressed",
          );
        resolve(output);
      } catch (error) {
        reject(error);
      }
    };
    child.stdout?.on("data", (bytes) => {
      output += bytes;
      if (output.length > 2 * 1024 * 1024) {
        exceeded = true;
        child.kill();
      }
    });
    child.stderr.resume();
    child.once("error", () => finish(-1));
    child.once("close", finish);
  });
}
export async function assembleDelta(raw, dependencies = {}) {
  const input = validateDeltaInput(raw),
    execute = dependencies.run || run;
  const api = async (endpoint, args = []) =>
    JSON.parse(
      await execute("gh", ["api", `repos/${input.repo}/${endpoint}`, ...args]),
    );
  if ((await api("")).private !== true)
    throw Error("Expected a private repository");
  const release = await findHeldDraft(api, input);
  verifyDeltaRelease(release, input);
  await verifyFrozenTag(api, input);
  const find = (release, name) => {
    const assets = release.assets.filter((a) => a.name === name);
    if (assets.length > 1) throw Error("Duplicate asset names");
    return assets[0];
  };
  const directory = await fs.mkdtemp(
    path.join(os.tmpdir(), "shenzhen-zip-delta-"),
  );
  const download = async (asset, filename) =>
    execute(
      "gh",
      [
        "api",
        `repos/${input.repo}/releases/assets/${asset.id}`,
        "-H",
        "Accept: application/octet-stream",
      ],
      { stdoutFile: filename },
    );
  try {
    const metadataAsset = find(release, "build-info.json");
    if (
      !metadataAsset ||
      metadataAsset.state !== "uploaded" ||
      metadataAsset.size < 1 ||
      metadataAsset.size > 2 * 1024 * 1024 ||
      !hex((metadataAsset.digest || "").replace(/^sha256:/, ""))
    )
      throw Error("Missing final provenance asset");
    const metadataFile = path.join(directory, "build-info.json");
    await download(metadataAsset, metadataFile);
    if ((await fileSHA(metadataFile)) !== metadataAsset.digest.slice(7))
      throw Error("Provenance asset digest mismatch");
    verifyDeltaMetadata(
      JSON.parse(await fs.readFile(metadataFile, "utf8")),
      input,
    );
    let action = finalAssetPlan(find(release, NAME), input);
    if (action === "upload") {
      const patch = exactAsset(
        find(release, input.patchName),
        input.patchName,
        input.patchSHA,
        input.patchSize,
      );
      const baseRelease = await api(`releases/tags/${BASE_TAG}`);
      verifyDeltaRelease(baseRelease, input, true);
      const base = exactAsset(
        find(baseRelease, BASE_NAME),
        BASE_NAME,
        input.baseSHA,
        input.baseSize,
      );
      const baseFile = path.join(directory, "base.zip"),
        patchFile = path.join(directory, "delta.zst"),
        target = path.join(directory, NAME);
      await download(base, baseFile);
      await download(patch, patchFile);
      if (
        (await fileSHA(baseFile)) !== input.baseSHA ||
        (await fileSHA(patchFile)) !== input.patchSHA
      )
        throw Error("Downloaded base or delta digest mismatch");
      await execute("zstd", [
        "-q",
        "-d",
        `--patch-from=${baseFile}`,
        "--long=28",
        patchFile,
        "-o",
        target,
      ]);
      if (
        (await fs.stat(target)).size !== input.size ||
        (await fileSHA(target)) !== input.sha256
      )
        throw Error("Reconstructed ZIP digest or size mismatch");
      // Recheck the held draft and absence immediately before a non-clobbering upload.
      const latest = await api(`releases/${release.id}`);
      verifyDeltaRelease(latest, input);
      await verifyFrozenTag(api, input);
      action = finalAssetPlan(find(latest, NAME), input);
      if (action === "upload")
        await execute("gh", [
          "release",
          "upload",
          TAG,
          target,
          "--repo",
          input.repo,
        ]);
    }
    const verified = await api(`releases/${release.id}`);
    verifyDeltaRelease(verified, input);
    await verifyFrozenTag(api, input);
    exactAsset(find(verified, NAME), NAME, input.sha256, input.size);
    // Delete only the specific, hash-verified patch after the final ZIP is verified.
    const currentPatch = find(verified, input.patchName);
    if (currentPatch) {
      exactAsset(
        currentPatch,
        input.patchName,
        input.patchSHA,
        input.patchSize,
      );
      await execute("gh", [
        "api",
        "--method",
        "DELETE",
        `repos/${input.repo}/releases/assets/${currentPatch.id}`,
      ]);
    }
    return {
      releaseOwner: input.repo.split("/")[0],
      sourceCommit: input.commit,
      asset: NAME,
      sha256: input.sha256,
      size: input.size,
      verified: true,
      patchRemoved: true,
      published: false,
    };
  } finally {
    await fs.rm(directory, { recursive: true, force: true });
  }
}
if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href
) {
  const e = process.env;
  const result = await assembleDelta({
    repo: e.GH_REPO,
    tag: e.RELEASE_TAG,
    commit: e.SOURCE_COMMIT,
    sha256: e.TARGET_SHA,
    size: Number(e.TARGET_SIZE),
    baseSHA: e.BASE_SHA,
    baseSize: Number(e.BASE_SIZE),
    patchSHA: e.PATCH_SHA,
    patchSize: Number(e.PATCH_SIZE),
  });
  console.log(JSON.stringify(result));
}
