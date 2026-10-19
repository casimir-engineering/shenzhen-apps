#!/usr/bin/env node
import fs from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import {
  validateDeltaInput,
  verifyDeltaMetadata,
  fileSHA,
  run,
  SOURCE_COMMIT,
} from "./assemble-release-zip-delta.mjs";
export async function prepareDelta({ repo, base, target, output }) {
  const metadata = JSON.parse(
    await fs.readFile(
      path.join(path.dirname(target), "build-info.json"),
      "utf8",
    ),
  );
  const targetSHA = await fileSHA(target),
    baseSHA = await fileSHA(base),
    size = (await fs.stat(target)).size,
    baseSize = (await fs.stat(base)).size;
  const input = validateDeltaInput({
    repo,
    tag: "preview-0.1.6",
    commit: SOURCE_COMMIT,
    sha256: targetSHA,
    size,
    baseSHA,
    baseSize,
    patchSHA: "0".repeat(64),
    patchSize: 1,
  });
  verifyDeltaMetadata(metadata, input);
  const directory = await fs.realpath(output),
    safe = await fs.realpath("artifacts");
  if (!directory.startsWith(safe + path.sep))
    throw Error(
      "Delta output must be an existing isolated artifacts directory",
    );
  const patch = path.join(directory, input.patchName);
  await run("zstd", [
    "-3",
    "-q",
    "--single-thread",
    `--patch-from=${base}`,
    target,
    "-o",
    patch,
  ]);
  const restored = path.join(directory, "verification.zip");
  try {
    await run("zstd", [
      "-q",
      "-d",
      `--patch-from=${base}`,
      "--long=28",
      patch,
      "-o",
      restored,
    ]);
    if (
      (await fs.stat(restored)).size !== size ||
      (await fileSHA(restored)) !== targetSHA
    )
      throw Error("Local reconstruction mismatch");
  } finally {
    await fs.rm(restored, { force: true });
  }
  const result = validateDeltaInput({
    ...input,
    patchSHA: await fileSHA(patch),
    patchSize: (await fs.stat(patch)).size,
  });
  const report = {
    releaseOwner: repo.split("/")[0],
    sourceCommit: SOURCE_COMMIT,
    patch,
    path: target,
    verified: true,
    workflowInputs: {
      tag: result.tag,
      source_commit: result.commit,
      target_sha256: result.sha256,
      target_size: String(result.size),
      base_sha256: result.baseSHA,
      base_size: String(result.baseSize),
      patch_sha256: result.patchSHA,
      patch_size: String(result.patchSize),
    },
  };
  await fs.writeFile(
    path.join(directory, "delta-inputs.json"),
    JSON.stringify(report, null, 2) + "\n",
    { flag: "wx", mode: 0o600 },
  );
  return report;
}
if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href
) {
  const arg = (name) =>
    process.argv
      .find((x) => x.startsWith(`--${name}=`))
      ?.slice(name.length + 3);
  console.log(
    JSON.stringify(
      await prepareDelta({
        repo: arg("repo"),
        base: arg("base"),
        target: arg("target"),
        output: arg("output"),
      }),
    ),
  );
}
