import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import {
  loadAuthorizedRepositories,
  validOwner,
} from "./upload-release-asset-config.mjs";
import { validateInputs } from "./upload-release-asset.mjs";
import { validateDirectInput } from "./upload-release-asset-direct.mjs";

test("both upload validators fail closed without private operator authorization", async () => {
  const directory = await fs.mkdtemp(
    path.join(os.tmpdir(), "operator-config-test-"),
  );
  const filename = path.join(directory, "config.json"),
    previous = process.env.SHENZHEN_RELEASE_UPLOAD_CONFIG;
  process.env.SHENZHEN_RELEASE_UPLOAD_CONFIG = filename;
  const base = {
    repo: "fixture-source/shenzhen-3D",
    tag: "preview-0.1.6",
    name: "app.dmg",
    sha256: "a".repeat(64),
    size: 1,
  };
  const direct = { ...base, commit: "b".repeat(40), cleanupParts: 0 };
  try {
    for (const validate of [
      () => validateInputs({ ...base, partCount: 1 }),
      () => validateDirectInput(direct),
    ])
      assert.throws(validate, /operator config/);
    await fs.writeFile(
      filename,
      JSON.stringify({ version: 1, repositories: [base.repo] }),
      { mode: 0o600 },
    );
    assert.equal(validateInputs({ ...base, partCount: 1 }).repo, base.repo);
    assert.equal(validateDirectInput(direct), direct);
    assert.throws(
      () =>
        validateDirectInput({
          ...direct,
          repo: "fixture-alternate/shenzhen-3D",
        }),
      /not authorized/,
    );
    assert.throws(
      () =>
        validateInputs({
          ...base,
          repo: "fixture-alternate/shenzhen-3D",
          partCount: 1,
        }),
      /not authorized/,
    );
    await fs.chmod(filename, 0o644);
    assert.throws(() => loadAuthorizedRepositories(filename), /insecure/);
    await fs.chmod(filename, 0o600);
    const symlink = path.join(directory, "link.json");
    await fs.symlink(filename, symlink);
    assert.throws(() => loadAuthorizedRepositories(symlink), /insecure/);
    for (const config of [
      { version: 1, repositories: [] },
      { version: 1, repositories: [base.repo, base.repo] },
      { version: 1, repositories: ["../shenzhen-3D"] },
      { version: 1, repositories: ["fixture-source/other-project"] },
      { version: 1, repositories: [base.repo], unexpected: true },
    ]) {
      await fs.writeFile(filename, JSON.stringify(config));
      assert.throws(() => loadAuthorizedRepositories(filename));
    }
    await fs.writeFile(filename, "invalid json");
    assert.throws(() => loadAuthorizedRepositories(filename));
  } finally {
    if (previous === undefined)
      delete process.env.SHENZHEN_RELEASE_UPLOAD_CONFIG;
    else process.env.SHENZHEN_RELEASE_UPLOAD_CONFIG = previous;
    await fs.rm(directory, { recursive: true, force: true });
  }
});
test("generic owner validation rejects traversal, whitespace and URL inputs", () => {
  assert.equal(validOwner("fixture-source"), true);
  for (const value of [
    undefined,
    "",
    "../owner",
    "owner/name",
    "https://example.com",
    "owner\nheader",
    "-owner",
    "owner-",
    "x".repeat(40),
  ])
    assert.equal(validOwner(value), false);
});
