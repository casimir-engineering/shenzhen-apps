import test, { after } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import { createHash } from "node:crypto";
import {
  validateDirectInput,
  verifyDraft,
  planAsset,
  curlConfig,
  uploadDirect,
  parseDirectArgs,
  verifyArtifactMetadata,
} from "./upload-release-asset-direct.mjs";

const operatorDirectory = await fs.mkdtemp(
  path.join(os.tmpdir(), "upload-operator-test-"),
);
const originalOperatorConfig = process.env.SHENZHEN_RELEASE_UPLOAD_CONFIG;
process.env.SHENZHEN_RELEASE_UPLOAD_CONFIG = path.join(
  operatorDirectory,
  "operator.json",
);
await fs.writeFile(
  process.env.SHENZHEN_RELEASE_UPLOAD_CONFIG,
  JSON.stringify({
    version: 1,
    repositories: [
      "fixture-source/shenzhen-3D",
      "fixture-alternate/shenzhen-3D",
    ],
  }),
  { mode: 0o600 },
);
after(async () => {
  if (originalOperatorConfig === undefined)
    delete process.env.SHENZHEN_RELEASE_UPLOAD_CONFIG;
  else process.env.SHENZHEN_RELEASE_UPLOAD_CONFIG = originalOperatorConfig;
  await fs.rm(operatorDirectory, { recursive: true, force: true });
});

for (const tag of [
  "preview-0.1.6",
  "preview-0.1.7",
  "preview-0.1.8",
  "preview-0.1.9",
])
  test(`${tag} binary, feed, blockmap and provenance require matching adjacent owner/source metadata`, async () => {
    const directory = await fs.mkdtemp(
      path.join(os.tmpdir(), "variant-metadata-test-"),
    );
    try {
      for (const name of [
        "app.dmg",
        "app.zip",
        "app.dmg.blockmap",
        "app.zip.blockmap",
        "latest-mac.yml",
        "build-info.json",
      ]) {
        const value = {
          ...input,
          tag,
          name,
          filename: path.join(directory, name),
        };
        await fs.rm(path.join(directory, "build-info.json"), { force: true });
        await assert.rejects(
          verifyArtifactMetadata(value),
          /Adjacent build-info/,
        );
        for (const owner of ["fixture-alternate", "fixture-source"]) {
          const own = { ...value, repo: `${owner}/shenzhen-3D` };
          await fs.writeFile(
            path.join(directory, "build-info.json"),
            JSON.stringify({ releaseOwner: owner, sourceCommit: input.commit }),
          );
          await verifyArtifactMetadata(own);
          const other =
            owner === "fixture-alternate"
              ? "fixture-source"
              : "fixture-alternate";
          await assert.rejects(
            verifyArtifactMetadata({ ...own, repo: `${other}/shenzhen-3D` }),
            /releaseOwner/,
          );
          await assert.rejects(
            verifyArtifactMetadata({ ...own, commit: "c".repeat(40) }),
            /sourceCommit/,
          );
        }
        await fs.writeFile(path.join(directory, "build-info.json"), "{}");
        await assert.rejects(verifyArtifactMetadata(value), /releaseOwner/);
        await fs.writeFile(path.join(directory, "build-info.json"), "not json");
        await assert.rejects(
          verifyArtifactMetadata(value),
          /Adjacent build-info/,
        );
      }
    } finally {
      await fs.rm(directory, { recursive: true, force: true });
    }
  });
test("older release schemas and current preview evidence do not require owner metadata", async () => {
  for (const tag of ["preview-0.1.4", "preview-0.1.5"])
    await verifyArtifactMetadata({
      ...input,
      tag,
      filename: "/missing-folder/app.dmg",
    });
  for (const tag of [
    "preview-0.1.6",
    "preview-0.1.7",
    "preview-0.1.8",
    "preview-0.1.9",
  ])
    await verifyArtifactMetadata({
      ...input,
      tag,
      name: "runtime-report.json",
      filename: "/missing-folder/runtime-report.json",
    });
});

test("CLI accepts SHA-256 options and rejects unknown or duplicate options", () => {
  assert.deepEqual(
    parseDirectArgs([
      "--sha256=abc",
      "--replace-sha256=def",
      "--cleanup-part-count=11",
    ]),
    { sha256: "abc", "replace-sha256": "def", "cleanup-part-count": "11" },
  );
  assert.throws(() => parseDirectArgs(["--sha256=abc", "--sha256=def"]));
  assert.throws(() => parseDirectArgs(["--unknown=value"]));
});

const input = {
  repo: "fixture-alternate/shenzhen-3D",
  tag: "preview-0.1.4",
  commit: "a".repeat(40),
  filename: "/tmp/app.dmg",
  name: "app.dmg",
  size: 1,
  sha256: createHash("sha256").update("x").digest("hex"),
  cleanupParts: 0,
};
const release = {
  id: 12,
  draft: true,
  tag_name: input.tag,
  target_commitish: input.commit,
  upload_url:
    "https://uploads.github.com/repos/fixture-alternate/shenzhen-3D/releases/12/assets{?name,label}",
};
const matching = {
  id: 20,
  name: input.name,
  size: input.size,
  state: "uploaded",
  digest: `sha256:${input.sha256}`,
};
const oldSHA = "b".repeat(64);

test("delivery is limited to authorized repositories and the exact preview drafts", () => {
  assert.equal(validateDirectInput(input), input);
  for (const patch of [
    { repo: "other/repo" },
    { tag: "preview-0.1.3" },
    { tag: "preview-0.1.10" },
    { tag: "v0.1.5" },
    { tag: "v0.1.6" },
    { tag: "v0.1.7" },
    { tag: "v0.1.8" },
    { tag: "v0.1.9" },
    { name: "../app.dmg" },
    { sha256: "invalid" },
    { commit: "main" },
    { size: 0 },
    { size: 225 * 1024 * 1024 },
    { cleanupParts: 65 },
    { cleanupParts: -1 },
  ])
    assert.throws(() => validateDirectInput({ ...input, ...patch }));
});
for (const tag of [
  "preview-0.1.5",
  "preview-0.1.6",
  "preview-0.1.7",
  "preview-0.1.8",
  "preview-0.1.9",
])
  test(`${tag} support preserves exact draft, source and repository guards`, () => {
    const next = { ...input, tag };
    for (const repo of [
      "fixture-alternate/shenzhen-3D",
      "fixture-source/shenzhen-3D",
    ])
      assert.equal(validateDirectInput({ ...next, repo }).tag, tag);
    const nextRelease = { ...release, tag_name: next.tag };
    verifyDraft(nextRelease, next);
    assert.throws(() => verifyDraft(release, next));
    assert.throws(() => verifyDraft({ ...nextRelease, draft: false }, next));
    assert.throws(() =>
      verifyDraft({ ...nextRelease, target_commitish: "c".repeat(40) }, next),
    );
  });
test("published releases and source changes are rejected", () => {
  verifyDraft(release, input);
  for (const patch of [
    { draft: false },
    { target_commitish: "c".repeat(40) },
    { tag_name: "preview-0.1.3" },
  ])
    assert.throws(() => verifyDraft({ ...release, ...patch }, input));
});
test("replacement requires the exact obsolete digest and asset identity", () => {
  assert.equal(planAsset(matching, input), "skip");
  assert.equal(planAsset(undefined, input), "upload");
  const old = { ...matching, digest: `sha256:${oldSHA}` };
  assert.throws(() => planAsset(old, input));
  assert.throws(() => planAsset(old, { ...input, replaceSHA: "c".repeat(64) }));
  assert.equal(planAsset(old, { ...input, replaceSHA: oldSHA }), "replace");
  assert.throws(() =>
    planAsset({ ...old, name: "other.dmg" }, { ...input, replaceSHA: oldSHA }),
  );
  assert.equal(
    planAsset({ ...matching, state: "starter", digest: null }, input),
    "remove-starter",
  );
  assert.throws(() => planAsset({ ...matching, state: "starter" }, input));
});
test("credentials are restricted to a validated upload endpoint and config", () => {
  const config = curlConfig(release, input, "fake_token");
  assert.match(config, /Authorization: Bearer fake_token/);
  assert.match(config, /header = "Expect:"/);
  assert.throws(() => curlConfig(release, input, "fake\nheader"));
  for (const upload_url of [
    "http://uploads.github.com/repos/fixture-alternate/shenzhen-3D/releases/12/assets",
    "https://uploads.github.com.evil.test/repos/fixture-alternate/shenzhen-3D/releases/12/assets",
    "https://uploads.github.com/repos/other/repo/releases/12/assets",
  ])
    assert.throws(() =>
      curlConfig({ ...release, upload_url }, input, "fake_token"),
    );
});

async function fixture(runTest, options = {}) {
  const directory = await fs.mkdtemp(
    path.join(os.tmpdir(), "direct-upload-test-"),
  );
  try {
    const filename = path.join(directory, "app.dmg");
    await fs.writeFile(filename, "x");
    if (options.metadata !== undefined)
      await fs.writeFile(
        path.join(directory, "build-info.json"),
        JSON.stringify(options.metadata),
      );
    const value = { ...input, filename, ...options.input };
    let assets = options.assets ? structuredClone(options.assets) : [];
    const calls = [],
      logs = [],
      deleted = [];
    let curls = 0;
    const run = async (command, args, stdin, timeout) => {
      calls.push({ command, args, stdin, timeout });
      if (command === "gh") {
        if (args[0] === "auth")
          return { code: 0, stdout: "fake_token_never_log\n" };
        if (args.includes("DELETE")) {
          const id = Number(args.at(-1).split("/").at(-1));
          deleted.push(id);
          assets = assets.filter((asset) => asset.id !== id);
          return { code: 0, stdout: "" };
        }
        const endpoint = args[1];
        if (endpoint.includes("/assets?"))
          return { code: 0, stdout: JSON.stringify([assets]) };
        if (endpoint.includes("/releases?"))
          return {
            code: 0,
            stdout: JSON.stringify([[{ ...release, ...options.release }]]),
          };
        return {
          code: 0,
          stdout: JSON.stringify({ ...release, ...options.refresh }),
        };
      }
      assert.equal(command, "/usr/bin/curl");
      curls++;
      assert.ok(!args.join(" ").includes("fake_token"));
      assert.match(stdin, /Authorization: Bearer fake_token_never_log/);
      if ((options.failFirst && curls === 1) || options.failAll) {
        assets.push({
          id: 30 + curls,
          name: value.name,
          state: "starter",
          digest: null,
        });
        return {
          code: 56,
          stdout: '{"http":"000","uploaded":123,"seconds":1}',
          reset: true,
        };
      }
      assets.push({
        ...matching,
        id: 99,
        digest: `sha256:${options.badHash || value.sha256}`,
      });
      return { code: 0, stdout: '{"http":"201","uploaded":1,"seconds":0.1}' };
    };
    await runTest({
      value,
      run,
      calls,
      logs,
      deleted,
      curlCount: () => curls,
      options: { run, log: (line) => logs.push(line), wait: async () => {} },
    });
    assert.ok(!logs.join(" ").includes("fake_token"));
  } finally {
    await fs.rm(directory, { recursive: true, force: true });
  }
}
for (const tag of [
  "preview-0.1.6",
  "preview-0.1.7",
  "preview-0.1.8",
  "preview-0.1.9",
])
  for (const metadata of [
    undefined,
    {},
    { releaseOwner: "fixture-source", sourceCommit: input.commit },
    { releaseOwner: "fixture-alternate", sourceCommit: "c".repeat(40) },
  ])
    test(`${tag} invalid provenance blocks GitHub access (${metadata === undefined ? "missing" : JSON.stringify(metadata)})`, async () => {
      await fixture(
        async ({ value, options, calls }) => {
          await assert.rejects(
            uploadDirect(value, options),
            /build-info|releaseOwner|sourceCommit/,
          );
          assert.deepEqual(calls, []);
        },
        { input: { tag }, metadata },
      );
    });
test("matching final skips credentials and curl", async () => {
  await fixture(
    async ({ value, options, calls }) => {
      await uploadDirect(value, options);
      assert.ok(
        !calls.some(
          (call) => call.command === "/usr/bin/curl" || call.args[0] === "auth",
        ),
      );
    },
    { assets: [matching] },
  );
});
test("explicit replacement deletes only old final, then exact chunks after verification", async () => {
  await fixture(
    async ({ value, options, deleted, calls }) => {
      await uploadDirect(value, options);
      assert.deepEqual(deleted, [20, 40]);
      const curl = calls.find((call) => call.command === "/usr/bin/curl");
      assert.equal(curl.args[curl.args.indexOf("--limit-rate") + 1], "2M");
      assert.equal(curl.args[curl.args.indexOf("--max-time") + 1], "900");
      assert.equal(curl.timeout, 905_000);
      assert.ok(
        calls.findIndex((call) => call.args.at(-1)?.endsWith("/40")) >
          calls.indexOf(curl),
      );
    },
    {
      input: { replaceSHA: oldSHA, cleanupParts: 1 },
      assets: [
        { ...matching, digest: `sha256:${oldSHA}` },
        { id: 40, name: "app.dmg.part-000" },
        { id: 41, name: "other.dmg.part-000" },
        { id: 42, name: "app.dmg.part-001" },
      ],
    },
  );
});
test("failed first upload inspects starter and retries once at 1 MiB/s", async () => {
  await fixture(
    async ({ value, options, calls, deleted, curlCount }) => {
      await uploadDirect(value, options);
      assert.equal(curlCount(), 2);
      assert.deepEqual(deleted, [31]);
      const curls = calls.filter((call) => call.command === "/usr/bin/curl");
      assert.equal(
        curls[1].args[curls[1].args.indexOf("--limit-rate") + 1],
        "1M",
      );
    },
    { failFirst: true },
  );
});
test("bounded failure leaves chunks untouched", async () => {
  await fixture(
    async ({ value, options, deleted, curlCount }) => {
      await assert.rejects(
        uploadDirect(value, options),
        /two inspected attempts/,
      );
      assert.equal(curlCount(), 2);
      assert.deepEqual(deleted, [31]);
    },
    {
      failAll: true,
      input: { cleanupParts: 1 },
      assets: [{ id: 40, name: "app.dmg.part-000" }],
    },
  );
});
test("incorrect remote hash cannot trigger chunk cleanup", async () => {
  await fixture(
    async ({ value, options, deleted }) => {
      await assert.rejects(uploadDirect(value, options), /remains untouched/);
      assert.deepEqual(deleted, []);
    },
    {
      badHash: oldSHA,
      input: { cleanupParts: 1 },
      assets: [{ id: 40, name: "app.dmg.part-000" }],
    },
  );
});
test("publication during operation blocks deletion", async () => {
  await fixture(
    async ({ value, options, deleted, curlCount }) => {
      await assert.rejects(uploadDirect(value, options), /held draft/);
      assert.deepEqual(deleted, []);
      assert.equal(curlCount(), 0);
    },
    {
      input: { replaceSHA: oldSHA },
      assets: [{ ...matching, digest: `sha256:${oldSHA}` }],
      refresh: { draft: false },
    },
  );
});
test("local hash mismatch is rejected before credential access or deletion", async () => {
  await fixture(
    async ({ value, options, calls }) => {
      await assert.rejects(uploadDirect(value, options), /Local file SHA-256/);
      assert.deepEqual(calls, []);
    },
    { input: { sha256: oldSHA } },
  );
});
