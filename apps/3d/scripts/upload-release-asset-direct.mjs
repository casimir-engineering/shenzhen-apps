#!/usr/bin/env node
// Direct fallback when release-assembly Actions are unavailable.
// node scripts/upload-release-asset-direct.mjs --repo=OWNER/shenzhen-3D \
//   --tag=preview-0.1.9 --commit=SOURCE_SHA --file=FILE --sha256=FILE_SHA \
//   [--replace-sha256=OBSOLETE_SHA] [--cleanup-part-count=17]
// Existing gh auth is sent only through curl's private stdin configuration.
// Owner-isolated previews require adjacent build-info.json matching releaseOwner/sourceCommit.
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { setTimeout as sleep } from "node:timers/promises";
import { hashFile } from "./upload-release-asset.mjs";
import { assertAuthorizedRepository } from "./upload-release-asset-config.mjs";
const OWNER_METADATA_TAGS = new Set([
  "preview-0.1.6",
  "preview-0.1.7",
  "preview-0.1.8",
  "preview-0.1.9",
]);
const TAGS = new Set([
  "preview-0.1.4",
  "preview-0.1.5",
  ...OWNER_METADATA_TAGS,
]);
const TRANSFER_TIMEOUT_SECONDS = 900;
export function validateDirectInput(input) {
  assertAuthorizedRepository(input.repo);
  // Replacement authorization is deliberately limited to the current drafts.
  if (!TAGS.has(input.tag))
    throw Error("Direct delivery is restricted to authorized preview drafts.");
  if (!/^[a-f0-9]{40}$/.test(input.commit || ""))
    throw Error("An exact source commit is required.");
  if (!/^[a-f0-9]{64}$/.test(input.sha256 || ""))
    throw Error("An expected SHA-256 is required.");
  if (
    input.replaceSHA !== undefined &&
    !/^[a-f0-9]{64}$/.test(input.replaceSHA)
  )
    throw Error("Invalid obsolete asset SHA-256.");
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,179}$/.test(input.name || ""))
    throw Error("Invalid asset basename.");
  if (
    !Number.isSafeInteger(input.size) ||
    input.size < 1 ||
    input.size > 224 * 1024 * 1024
  )
    throw Error("Asset must be between 1 byte and 224 MiB.");
  if (
    !Number.isSafeInteger(input.cleanupParts) ||
    input.cleanupParts < 0 ||
    input.cleanupParts > 64
  )
    throw Error("Cleanup part count must be between 0 and 64.");
  return input;
}
export function verifyDraft(release, input) {
  if (
    !Number.isSafeInteger(release.id) ||
    !release.draft ||
    release.tag_name !== input.tag ||
    release.target_commitish !== input.commit
  )
    throw Error(
      "Expected held draft and exact source commit; nothing was changed.",
    );
}
export async function verifyArtifactMetadata(input) {
  if (!OWNER_METADATA_TAGS.has(input.tag)) return;
  const core =
    input.name === "build-info.json" ||
    input.name === "latest-mac.yml" ||
    /\.(dmg|zip)(\.blockmap)?$/.test(input.name);
  if (!core) return;
  let metadata;
  try {
    const filename = path.join(path.dirname(input.filename), "build-info.json");
    const stat = await fs.stat(filename);
    if (!stat.isFile() || stat.size > 2 * 1024 * 1024) throw Error();
    metadata = JSON.parse(await fs.readFile(filename, "utf8"));
  } catch {
    throw Error(
      "Adjacent build-info.json is required for owner-isolated core artifacts.",
    );
  }
  if (metadata?.releaseOwner !== input.repo.split("/")[0])
    throw Error(
      "Artifact releaseOwner does not match the destination repository.",
    );
  if (metadata.sourceCommit !== input.commit)
    throw Error(
      "Artifact sourceCommit does not match the expected frozen source.",
    );
}
const digest = (asset) =>
  /^sha256:[a-f0-9]{64}$/.test(asset.digest || "")
    ? asset.digest.slice(7)
    : undefined;
export function planAsset(asset, input) {
  if (!asset) return "upload";
  if (asset.name !== input.name || !Number.isSafeInteger(asset.id))
    throw Error("Asset identity is invalid.");
  if (
    asset.state === "uploaded" &&
    asset.size === input.size &&
    digest(asset) === input.sha256
  )
    return "skip";
  if (asset.state === "starter" && !asset.digest) return "remove-starter";
  if (
    asset.state === "uploaded" &&
    input.replaceSHA &&
    digest(asset) === input.replaceSHA &&
    input.replaceSHA !== input.sha256
  )
    return "replace";
  throw Error("Existing final asset differs and remains untouched.");
}
export function curlConfig(release, input, token) {
  if (!/^[A-Za-z0-9_.-]+$/.test(token))
    throw Error("Unsupported credential format.");
  const url = new URL(release.upload_url.replace(/\{.*$/, ""));
  if (
    url.protocol !== "https:" ||
    url.host !== "uploads.github.com" ||
    url.username ||
    url.password ||
    url.search ||
    url.hash ||
    url.pathname !== `/repos/${input.repo}/releases/${release.id}/assets`
  )
    throw Error("Unexpected upload endpoint.");
  url.searchParams.set("name", input.name);
  const quote = (value) =>
    `"${value.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
  return [
    `url = ${quote(url.href)}`,
    `header = ${quote(`Authorization: Bearer ${token}`)}`,
    'header = "Accept: application/vnd.github+json"',
    'header = "X-GitHub-Api-Version: 2022-11-28"',
    'header = "Content-Type: application/octet-stream"',
    'header = "User-Agent: Shenzhen3D-release-upload"',
    'header = "Expect:"',
  ].join("\n");
}
function runCommand(command, args, input, timeoutMs = 45_000) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      shell: false,
      env: { ...process.env, GH_HOST: "github.com" },
      stdio: ["pipe", "pipe", "pipe"],
    });
    const timeout = setTimeout(() => child.kill("SIGTERM"), timeoutMs);
    timeout.unref();
    let stdout = "",
      stderr = "",
      exceeded = false;
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
      if (stdout.length > 16 * 1024 * 1024) {
        exceeded = true;
        child.kill();
      }
    });
    child.stderr.on("data", (chunk) => {
      stderr = (stderr + chunk).slice(-4096);
    });
    child.on("error", () => {
      clearTimeout(timeout);
      reject(Error("Process could not start."));
    });
    child.on("close", (code) => {
      clearTimeout(timeout);
      resolve({
        code: exceeded ? -1 : code,
        stdout,
        reset: /reset|EOF|broken pipe/i.test(stderr),
        timeout: /timed? out|timeout/i.test(stderr),
      });
    });
    child.stdin.on("error", () => {});
    child.stdin.end(input);
  });
}
export async function uploadDirect(
  input,
  { run = runCommand, log = console.log, wait = sleep } = {},
) {
  validateDirectInput(input);
  const stat = await fs.stat(input.filename);
  if (
    !stat.isFile() ||
    stat.size !== input.size ||
    (await hashFile(input.filename)) !== input.sha256
  )
    throw Error("Local file SHA-256 or size differs; nothing was changed.");
  await verifyArtifactMetadata(input);
  async function gh(args) {
    const attempts = args[0] === "api" && !args.includes("--method") ? 3 : 1;
    for (let i = 0; i < attempts; i++) {
      const result = await run("gh", args);
      if (result.code === 0) return result.stdout;
      if (i < attempts - 1) await wait((i + 1) * 1000);
    }
    throw Error("GitHub CLI operation failed.");
  }
  const releases = JSON.parse(
    await gh([
      "api",
      `repos/${input.repo}/releases?per_page=100`,
      "--paginate",
      "--slurp",
    ]),
  )
    .flat()
    .filter((release) => release.tag_name === input.tag);
  if (releases.length !== 1)
    throw Error("Draft release was not found unambiguously.");
  let release = releases[0];
  verifyDraft(release, input);
  const refreshDraft = async () => {
    release = JSON.parse(
      await gh(["api", `repos/${input.repo}/releases/${release.id}`]),
    );
    verifyDraft(release, input);
  };
  const assets = async () =>
    JSON.parse(
      await gh([
        "api",
        `repos/${input.repo}/releases/${release.id}/assets?per_page=100`,
        "--paginate",
        "--slurp",
      ]),
    ).flat();
  const find = async () =>
    (await assets()).find((asset) => asset.name === input.name);
  const remove = async (asset) => {
    await refreshDraft();
    await gh([
      "api",
      "--method",
      "DELETE",
      `repos/${input.repo}/releases/assets/${asset.id}`,
    ]);
  };
  let asset = await find();
  const initialPlan = planAsset(asset, input);
  if (initialPlan !== "skip") {
    // No disk or argv copy of the credential; no verbose curl/gh logging.
    const token = (
      await gh(["auth", "token", "--hostname", "github.com"])
    ).trim();
    const config = curlConfig(release, input, token);
    const directory = await fs.mkdtemp(
      path.join(os.tmpdir(), "shenzhen-direct-upload-"),
    );
    try {
      const response = path.join(directory, "response.json");
      await fs.writeFile(response, "", { mode: 0o600 });
      const rates = ["2M", "1M"];
      for (const [index, rate] of rates.entries()) {
        await refreshDraft();
        asset = await find();
        const plan = planAsset(asset, input);
        if (plan === "skip") break;
        if (plan !== "upload") await remove(asset);
        await refreshDraft();
        log(
          `Direct upload attempt ${index + 1}/${rates.length}: ${input.name}, limit ${rate}/s.`,
        );
        const result = await run(
          "/usr/bin/curl",
          [
            "-q",
            "--config",
            "-",
            "--http1.1",
            "--ipv4",
            "--silent",
            "--show-error",
            "--request",
            "POST",
            "--upload-file",
            input.filename,
            "--limit-rate",
            rate,
            "--connect-timeout",
            "20",
            "--max-time",
            String(TRANSFER_TIMEOUT_SECONDS),
            "--output",
            response,
            "--write-out",
            '{"http":"%{http_code}","uploaded":%{size_upload},"seconds":%{time_total}}',
          ],
          config,
          (TRANSFER_TIMEOUT_SECONDS + 5) * 1000,
        );
        let metrics = {};
        try {
          const parsed = JSON.parse(result.stdout);
          if (/^\d{3}$/.test(parsed.http)) metrics.http = parsed.http;
          for (const key of ["uploaded", "seconds"])
            if (Number.isFinite(parsed[key])) metrics[key] = parsed[key];
        } catch {}
        log(
          JSON.stringify({
            attempt: index + 1,
            rate,
            curlExit: result.code,
            reset: result.reset,
            timeout: result.timeout,
            ...metrics,
          }),
        );
        asset = await find();
        if (planAsset(asset, input) === "skip") break;
        if (index === rates.length - 1)
          throw Error("Direct upload failed after two inspected attempts.");
      }
    } finally {
      await fs.rm(directory, { recursive: true, force: true });
    }
  }
  await refreshDraft();
  asset = await find();
  if (planAsset(asset, input) !== "skip")
    throw Error("Final remote SHA-256 verification failed.");
  // Only exact numbered chunks for this final asset, and only after verification.
  const remaining = await assets();
  for (let i = 0; i < input.cleanupParts; i++) {
    const name = `${input.name}.part-${String(i).padStart(3, "0")}`;
    const part = remaining.find((asset) => asset.name === name);
    if (part) {
      if (!Number.isSafeInteger(part.id))
        throw Error("Invalid temporary asset identity.");
      await remove(part);
    }
  }
  log(
    `Verified ${input.name}: ${input.size} bytes, SHA-256 ${input.sha256}. Release remains draft.`,
  );
  return { id: asset.id, sha256: input.sha256, size: input.size };
}
export function parseDirectArgs(args) {
  const allowed = new Set([
    "repo",
    "tag",
    "commit",
    "file",
    "sha256",
    "replace-sha256",
    "cleanup-part-count",
  ]);
  const values = {};
  for (const arg of args) {
    const match = /^--([a-z0-9-]+)=(.*)$/.exec(arg);
    if (!match || !allowed.has(match[1]) || values[match[1]] !== undefined)
      throw Error("Invalid or duplicate CLI option.");
    values[match[1]] = match[2];
  }
  return values;
}
if (
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  try {
    const values = parseDirectArgs(process.argv.slice(2));
    const filename = path.resolve(values.file || "");
    const stat = await fs.stat(filename);
    if (!stat.isFile()) throw Error("Input must be a regular file.");
    const input = validateDirectInput({
      repo: values.repo,
      tag: values.tag,
      commit: values.commit,
      filename,
      name: path.basename(filename),
      size: stat.size,
      sha256: values.sha256,
      replaceSHA: values["replace-sha256"],
      cleanupParts:
        values["cleanup-part-count"] === undefined
          ? 0
          : /^\d+$/.test(values["cleanup-part-count"])
            ? Number(values["cleanup-part-count"])
            : NaN,
    });
    await uploadDirect(input);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
