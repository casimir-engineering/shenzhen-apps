#!/usr/bin/env node
// node scripts/upload-release-asset.mjs --repo=OWNER/shenzhen-3D \
//   --tag=preview-0.1.3 --file=artifacts/releases-0.1.3/Shenzhen-3D-0.1.3-Apple-Silicon.dmg
// Auth stays in gh's existing credential store/environment. No tokens are read or logged.
// Defaults to 8 MiB parts; override with --chunk-mib=1..24 when appropriate.
import fs from "node:fs/promises";
import { createReadStream } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
import { spawn } from "node:child_process";
import { setTimeout as sleep } from "node:timers/promises";
import { assertAuthorizedRepository } from "./upload-release-asset-config.mjs";
const MAX_PARTS = 64;
const MAX_PART_BYTES = 24 * 1024 * 1024;
const WORKFLOW = "assemble-release-asset.yml";
export function validateInputs({ repo, tag, name, sha256, partCount, size }) {
  assertAuthorizedRepository(repo);
  if (
    typeof tag !== "string" ||
    !/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(tag)
  )
    throw Error("Invalid release tag.");
  if (
    typeof name !== "string" ||
    !/^[A-Za-z0-9][A-Za-z0-9._-]{0,179}$/.test(name)
  )
    throw Error("Invalid asset basename.");
  if (typeof sha256 !== "string" || !/^[a-fA-F0-9]{64}$/.test(sha256))
    throw Error("Invalid SHA-256.");
  if (
    !Number.isSafeInteger(partCount) ||
    partCount < 1 ||
    partCount > MAX_PARTS
  )
    throw Error("Part count must be between 1 and 64.");
  if (
    size !== undefined &&
    (!Number.isSafeInteger(size) ||
      size < 1 ||
      size > MAX_PART_BYTES * MAX_PARTS)
  )
    throw Error("Invalid total asset size.");
  return { repo, tag, name, sha256: sha256.toLowerCase(), partCount, size };
}
export function validatePartSet(assets, { name, partCount, size }) {
  const expected = Array.from(
    { length: partCount },
    (_, i) => `${name}.part-${String(i).padStart(3, "0")}`,
  );
  const parts = assets.filter((asset) =>
    asset.name.startsWith(`${name}.part-`),
  );
  if (
    parts.length !== partCount ||
    parts.some((asset) => !expected.includes(asset.name)) ||
    new Set(parts.map((asset) => asset.name)).size !== partCount
  )
    throw Error(
      "Release does not contain exactly the expected numbered parts.",
    );
  const ordered = expected.map((name) =>
    parts.find((asset) => asset.name === name),
  );
  for (const [i, asset] of ordered.entries()) {
    if (
      asset.state !== "uploaded" ||
      !Number.isSafeInteger(asset.size) ||
      asset.size < 1 ||
      asset.size > MAX_PART_BYTES ||
      (i < ordered.length - 1 && asset.size !== ordered[0].size) ||
      asset.size > ordered[0].size
    )
      throw Error("Part state or size is invalid.");
  }
  const total = ordered.reduce((sum, asset) => sum + asset.size, 0);
  if (size !== undefined && total !== size)
    throw Error("Part sizes do not match the expected total.");
  return ordered;
}
export async function hashFile(filename) {
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(filename)) hash.update(chunk);
  return hash.digest("hex");
}
export async function assembleParts(
  filenames,
  destination,
  expectedSHA,
  expectedSize,
) {
  const output = await fs.open(destination, "wx", 0o600);
  const hash = createHash("sha256");
  let size = 0;
  try {
    for (const filename of filenames)
      for await (const chunk of createReadStream(filename)) {
        size += chunk.length;
        if (
          size > MAX_PART_BYTES * MAX_PARTS ||
          (expectedSize !== undefined && size > expectedSize)
        )
          throw Error("Assembly exceeds its size limit.");
        hash.update(chunk);
        await output.writeFile(chunk);
      }
    await output.sync();
    if (
      (expectedSize !== undefined && size !== expectedSize) ||
      hash.digest("hex") !== expectedSHA.toLowerCase()
    )
      throw Error("Assembled asset hash or size does not match.");
    return size;
  } finally {
    await output.close();
  }
}
function gh(args, input) {
  return new Promise((resolve, reject) => {
    const child = spawn("gh", args, {
      stdio: ["pipe", "pipe", "pipe"],
      shell: false,
      env: { ...process.env, GH_HOST: "github.com" },
    });
    const timeout = setTimeout(() => child.kill("SIGTERM"), 180_000);
    timeout.unref();
    let stdout = "",
      exceeded = false;
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
      if (stdout.length > 16 * 1024 * 1024) {
        exceeded = true;
        child.kill();
      }
    });
    // gh may include transport details in stderr. Never relay authentication diagnostics.
    child.stderr.resume();
    child.on("error", () => reject(Error("GitHub CLI could not be started.")));
    child.on("close", (code) => {
      clearTimeout(timeout);
      code === 0 && !exceeded
        ? resolve(stdout)
        : reject(
            Error(`GitHub CLI operation failed (exit ${code ?? "unknown"}).`),
          );
    });
    child.stdin.end(input);
  });
}
const api = async (endpoint, args = []) =>
  JSON.parse(await gh(["api", endpoint, ...args]));
async function releaseAssets(repo, tag) {
  // The release-by-tag REST endpoint excludes drafts. Listing authenticated
  // releases resolves both drafts and published releases without publishing.
  const releases = await api(`repos/${repo}/releases?per_page=100`, [
    "--paginate",
    "--slurp",
  ]);
  const matches = releases.flat().filter((release) => release.tag_name === tag);
  if (matches.length !== 1 || !Number.isSafeInteger(matches[0].id))
    throw Error("An unambiguous release for this tag could not be found.");
  const release = matches[0];
  const pages = await api(
    `repos/${repo}/releases/${release.id}/assets?per_page=100`,
    ["--paginate", "--slurp"],
  );
  return pages.flat();
}
const digest = (asset) =>
  /^sha256:[a-fA-F0-9]{64}$/.test(asset.digest || "")
    ? asset.digest.slice(7).toLowerCase()
    : undefined;
async function downloadedHash(repo, tag, asset, directory) {
  const target = path.join(directory, asset.name);
  // This can replace only an ignored temporary local file, never a release asset.
  await gh([
    "release",
    "download",
    tag,
    "--repo",
    repo,
    "--pattern",
    asset.name,
    "--dir",
    directory,
    "--clobber",
  ]);
  if ((await fs.stat(target)).size !== asset.size)
    throw Error("Downloaded asset size differs from GitHub metadata.");
  return hashFile(target);
}
async function matches(repo, tag, asset, sha, size, directory) {
  if (asset.state !== "uploaded") return false;
  if (size !== undefined && asset.size !== size) return false;
  return (
    (digest(asset) || (await downloadedHash(repo, tag, asset, directory))) ===
    sha
  );
}
async function removeStarter(repo, asset) {
  if (asset.state !== "starter" || asset.digest)
    throw Error("Existing asset is not a verified failed upload starter.");
  await gh([
    "api",
    "--method",
    "DELETE",
    `repos/${repo}/releases/assets/${asset.id}`,
  ]);
}
async function cleanParts(repo, assets, input) {
  // Exact generated names only. Never use a wildcard delete or touch final assets.
  for (let i = 0; i < input.partCount; i++) {
    const name = `${input.name}.part-${String(i).padStart(3, "0")}`;
    const asset = assets.find((asset) => asset.name === name);
    if (asset)
      await gh([
        "api",
        "--method",
        "DELETE",
        `repos/${repo}/releases/assets/${asset.id}`,
      ]);
  }
}
async function assembleRelease(input) {
  const directory = await fs.mkdtemp(
    path.join(process.env.RUNNER_TEMP || process.cwd(), "release-assembly-"),
  );
  try {
    let assets = await releaseAssets(input.repo, input.tag);
    const existing = assets.find((asset) => asset.name === input.name);
    if (existing?.state === "uploaded") {
      if (
        !(await matches(
          input.repo,
          input.tag,
          existing,
          input.sha256,
          input.size,
          directory,
        ))
      )
        throw Error(
          "Existing final asset has a different hash or size. It was not changed.",
        );
      await cleanParts(input.repo, assets, input);
      console.log(
        "Matching final asset already exists; temporary parts removed.",
      );
      return;
    }
    if (existing) await removeStarter(input.repo, existing);
    const parts = validatePartSet(assets, input);
    const filenames = [];
    for (const asset of parts) {
      const actualHash = await downloadedHash(
        input.repo,
        input.tag,
        asset,
        directory,
      );
      if (digest(asset) && actualHash !== digest(asset))
        throw Error("A downloaded part has an incorrect hash.");
      filenames.push(path.join(directory, asset.name));
    }
    const final = path.join(directory, input.name);
    const size = await assembleParts(
      filenames,
      final,
      input.sha256,
      input.size,
    );
    // Recheck immediately before publishing; a parallel successful uploader wins.
    assets = await releaseAssets(input.repo, input.tag);
    const race = assets.find((asset) => asset.name === input.name);
    if (race) {
      if (
        !(await matches(
          input.repo,
          input.tag,
          race,
          input.sha256,
          size,
          directory,
        ))
      )
        throw Error("A conflicting final asset appeared. It was not changed.");
    } else
      await uploadPart(
        input,
        final,
        input.sha256,
        size,
        directory,
        "final asset",
      );
    assets = await releaseAssets(input.repo, input.tag);
    const published = assets.find((asset) => asset.name === input.name);
    if (
      !published ||
      !(await matches(
        input.repo,
        input.tag,
        published,
        input.sha256,
        size,
        directory,
      ))
    )
      throw Error(
        "Final remote asset verification failed; temporary parts retained.",
      );
    await cleanParts(input.repo, assets, input);
    console.log(
      `Verified and published ${input.name}: ${size} bytes, SHA-256 ${input.sha256}`,
    );
  } finally {
    await fs.rm(directory, { recursive: true, force: true });
  }
}
async function uploadPart(
  input,
  filename,
  sha,
  size,
  directory,
  kind = "temporary part",
) {
  const name = path.basename(filename);
  for (let attempt = 1; attempt <= 3; attempt++) {
    let existing = (await releaseAssets(input.repo, input.tag)).find(
      (asset) => asset.name === name,
    );
    if (existing) {
      if (existing.state === "uploaded") {
        if (
          !(await matches(
            input.repo,
            input.tag,
            existing,
            sha,
            size,
            directory,
          ))
        )
          throw Error(
            `An existing ${kind} has different contents. It was not changed.`,
          );
        return;
      }
      await removeStarter(input.repo, existing);
    }
    try {
      await gh([
        "release",
        "upload",
        input.tag,
        filename,
        "--repo",
        input.repo,
      ]);
    } catch {
      /* Inspect server state before any retry. */
    }
    existing = (await releaseAssets(input.repo, input.tag)).find(
      (asset) => asset.name === name,
    );
    if (existing?.state === "uploaded") {
      if (
        !(await matches(input.repo, input.tag, existing, sha, size, directory))
      )
        throw Error(`Uploaded ${kind} verification failed.`);
      return;
    }
    if (attempt < 3) await sleep(attempt * 2000);
  }
  throw Error(`Upload failed after three inspected attempts: ${name}`);
}
async function runWorkflow(input) {
  const endpoint = `repos/${input.repo}/actions/workflows/${WORKFLOW}`;
  const title = `Assemble ${input.name} for ${input.tag} (${input.sha256})`;
  const list = () =>
    api(`${endpoint}/runs?event=workflow_dispatch&per_page=20`);
  const previous = (await list()).workflow_runs;
  let run = previous.find(
    (run) => run.display_title === title && run.status !== "completed",
  );
  if (!run) {
    await gh(
      ["api", "--method", "POST", `${endpoint}/dispatches`, "--input", "-"],
      JSON.stringify({
        ref: "main",
        inputs: {
          tag: input.tag,
          asset_name: input.name,
          sha256: input.sha256,
          part_count: String(input.partCount),
          expected_size: String(input.size),
        },
      }),
    );
    const previousIDs = new Set(previous.map((run) => run.id));
    for (let i = 0; i < 18 && !run; i++) {
      await sleep(5000);
      run = (await list()).workflow_runs.find(
        (run) => !previousIDs.has(run.id) && run.display_title === title,
      );
    }
    if (!run)
      throw Error(
        "Workflow dispatch could not be located. Temporary parts remain available for recovery.",
      );
  }
  console.log(
    `Assembly workflow: https://github.com/${input.repo}/actions/runs/${run.id}`,
  );
  const deadline = Date.now() + 15 * 60 * 1000;
  while (run.status !== "completed" && Date.now() < deadline) {
    await sleep(10_000);
    run = await api(`repos/${input.repo}/actions/runs/${run.id}`);
  }
  if (run.conclusion !== "success")
    throw Error(
      "Assembly workflow did not succeed. Temporary parts remain available for inspection.",
    );
}
async function localUpload(args) {
  const value = (name) =>
    args.find((arg) => arg.startsWith(`--${name}=`))?.slice(name.length + 3);
  const filename = path.resolve(value("file") || "");
  const name = path.basename(filename),
    repo = value("repo"),
    tag = value("tag");
  const chunkMiB = Number(value("chunk-mib") || 8);
  if (!Number.isInteger(chunkMiB) || chunkMiB < 1 || chunkMiB > 24)
    throw Error("Chunk size must be an integer from 1 to 24 MiB.");
  const chunkBytes = chunkMiB * 1024 * 1024;
  const stat = await fs.stat(filename);
  if (!stat.isFile()) throw Error("Upload input must be a regular file.");
  validateInputs({
    repo,
    tag,
    name,
    sha256: "0".repeat(64),
    partCount: Math.ceil(stat.size / chunkBytes),
    size: stat.size,
  });
  const parent = path.resolve("artifacts/release-upload-temp");
  await fs.mkdir(parent, { recursive: true });
  const directory = await fs.mkdtemp(path.join(parent, "upload-"));
  try {
    const whole = createHash("sha256"),
      file = await fs.open(filename, "r"),
      parts = [];
    try {
      for (let offset = 0, i = 0; offset < stat.size; i++) {
        const bytes = Math.min(chunkBytes, stat.size - offset),
          buffer = Buffer.allocUnsafe(bytes);
        let read = 0;
        while (read < bytes) {
          const result = await file.read(
            buffer,
            read,
            bytes - read,
            offset + read,
          );
          if (!result.bytesRead)
            throw Error("Input file changed during splitting.");
          read += result.bytesRead;
        }
        whole.update(buffer);
        const part = path.join(
          directory,
          `${name}.part-${String(i).padStart(3, "0")}`,
        );
        await fs.writeFile(part, buffer, { mode: 0o600 });
        parts.push({
          filename: part,
          size: bytes,
          sha256: createHash("sha256").update(buffer).digest("hex"),
        });
        offset += bytes;
      }
    } finally {
      await file.close();
    }
    const input = validateInputs({
      repo,
      tag,
      name,
      sha256: whole.digest("hex"),
      partCount: parts.length,
      size: stat.size,
    });
    const existing = (await releaseAssets(repo, tag)).find(
      (asset) => asset.name === name,
    );
    if (existing?.state === "uploaded") {
      if (
        !(await matches(
          repo,
          tag,
          existing,
          input.sha256,
          input.size,
          directory,
        ))
      )
        throw Error("Existing final asset differs. It was not changed.");
      console.log(`Matching final asset already uploaded: ${name}`);
      return;
    }
    if (existing) await removeStarter(repo, existing);
    console.log(
      `Uploading ${parts.length} verified parts for ${name} (${stat.size} bytes).`,
    );
    for (const [i, part] of parts.entries()) {
      await uploadPart(input, part.filename, part.sha256, part.size, directory);
      console.log(`Part ${i + 1}/${parts.length} uploaded and verified.`);
    }
    await runWorkflow(input);
    const final = (await releaseAssets(repo, tag)).find(
      (asset) => asset.name === name,
    );
    if (
      !final ||
      !(await matches(repo, tag, final, input.sha256, input.size, directory))
    )
      throw Error("Final remote hash verification failed.");
    console.log(`Remote final asset verified: SHA-256 ${input.sha256}`);
  } finally {
    await fs.rm(directory, { recursive: true, force: true });
  }
}
if (
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  try {
    if (process.argv.includes("--assemble")) {
      const parse = (value) =>
        /^\d+$/.test(value || "") ? Number(value) : NaN;
      await assembleRelease(
        validateInputs({
          repo: process.env.GH_REPO,
          tag: process.env.RELEASE_TAG,
          name: process.env.ASSET_NAME,
          sha256: process.env.EXPECTED_SHA,
          partCount: parse(process.env.PART_COUNT),
          size: process.env.EXPECTED_SIZE
            ? parse(process.env.EXPECTED_SIZE)
            : undefined,
        }),
      );
    } else await localUpload(process.argv.slice(2));
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
