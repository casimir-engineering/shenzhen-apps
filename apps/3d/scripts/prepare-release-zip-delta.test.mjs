import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { prepareDelta } from "./prepare-release-zip-delta.mjs";
import { SOURCE_COMMIT, fileSHA } from "./assemble-release-zip-delta.mjs";
let available = true;
try {
  execFileSync("zstd", ["--version"], { stdio: "ignore" });
} catch {
  available = false;
}
test(
  "local preparation reconstructs exact bytes and leaves base/target untouched",
  { skip: !available },
  async (t) => {
    const root = path.resolve("artifacts");
    await fs.mkdir(root, { recursive: true });
    const directory = await fs.mkdtemp(path.join(root, "zip-delta-unit-"));
    t.after(() => fs.rm(directory, { recursive: true, force: true }));
    const config = path.join(directory, "config.json");
    await fs.writeFile(
      config,
      JSON.stringify({
        version: 1,
        repositories: ["fixture-owner/shenzhen-3D"],
      }),
      { mode: 0o600 },
    );
    const prior = process.env.SHENZHEN_RELEASE_UPLOAD_CONFIG;
    process.env.SHENZHEN_RELEASE_UPLOAD_CONFIG = config;
    t.after(() => {
      if (prior === undefined)
        delete process.env.SHENZHEN_RELEASE_UPLOAD_CONFIG;
      else process.env.SHENZHEN_RELEASE_UPLOAD_CONFIG = prior;
    });
    const base = path.join(directory, "base.zip"),
      target = path.join(directory, "target.zip"),
      output = path.join(directory, "patch");
    await fs.mkdir(output);
    await fs.writeFile(base, Buffer.alloc(100000, 97));
    await fs.writeFile(
      target,
      Buffer.concat([
        Buffer.alloc(100000, 97),
        Buffer.from("changed immutable ZIP fixture"),
      ]),
    );
    const baseSHA = await fileSHA(base),
      targetSHA = await fileSHA(target),
      size = (await fs.stat(target)).size;
    const metadata = {
      releaseOwner: "fixture-owner",
      sourceCommit: SOURCE_COMMIT,
      sourceDirty: false,
      version: "0.1.6",
      ownerIsolationVerified: true,
      artifacts: [
        {
          file: "Shenzhen-3D-0.1.6-Apple-Silicon.zip",
          sha256: targetSHA,
          size,
        },
      ],
      notarization: {
        zip: { status: "Accepted" },
        dmg: { status: "Accepted" },
        appStapled: true,
        dmgStapled: true,
        codeSignaturesVerified: true,
        gatekeeperAccepted: true,
        embeddedZipAndDmgTicketsValidated: true,
      },
    };
    await fs.writeFile(
      path.join(directory, "build-info.json"),
      JSON.stringify(metadata),
    );
    const report = await prepareDelta({
      repo: "fixture-owner/shenzhen-3D",
      base,
      target,
      output,
    });
    assert.equal(report.verified, true);
    assert.equal(report.workflowInputs.target_sha256, targetSHA);
    assert.ok(Number(report.workflowInputs.patch_size) < size);
    assert.equal(await fileSHA(base), baseSHA);
    assert.equal(await fileSHA(target), targetSHA);
    assert.equal(
      (await fs.stat(path.join(output, "delta-inputs.json"))).mode & 0o777,
      0o600,
    );
    metadata.releaseOwner = "foreign-owner";
    await fs.writeFile(
      path.join(directory, "build-info.json"),
      JSON.stringify(metadata),
    );
    await assert.rejects(
      prepareDelta({ repo: "fixture-owner/shenzhen-3D", base, target, output }),
      /provenance mismatch/,
    );
  },
);
