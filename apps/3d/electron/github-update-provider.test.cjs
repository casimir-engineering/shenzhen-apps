const { test } = require("node:test");
const assert = require("node:assert/strict");
const { createClient } = require("electron-updater/out/providerFactory");
const {
  PublicReleaseProvider,
  PrivateReleaseProvider,
} = require("./github-update-provider.cjs");

const OWNER = "fixture-primary",
  REPO = "shenzhen-3D",
  TOKEN = "fixture-connected-token";
const asset = (name, id = 1) => ({
  name,
  url: `https://api.github.com/repos/${OWNER}/${REPO}/releases/assets/${id}`,
});
const release = (tag_name, prerelease = false, extra = {}) => ({
  tag_name,
  prerelease,
  draft: false,
  assets: [asset("latest-mac.yml"), asset("Shenzhen-3D-Apple-Silicon.zip", 2)],
  ...extra,
});
function fixture(releases, allowPrerelease = true, options = {}) {
  const requests = [];
  const executor = {
    request: async (request) => {
      requests.push(request);
      if (request.path.includes("/releases?")) return JSON.stringify(releases);
      return "version: 0.1.6\nfiles:\n  - url: Shenzhen-3D-Apple-Silicon.zip\n    sha512: fixture-sha512\n";
    },
  };
  const provider = createClient(
    {
      provider: "custom",
      updateProvider: PrivateReleaseProvider,
      owner: OWNER,
      repo: REPO,
      private: true,
      token: TOKEN,
      ...options,
    },
    { allowPrerelease },
    { executor, platform: "darwin" },
  );
  return { provider, requests };
}

test("actual private provider chooses newer stable releases ahead of older previews", async () => {
  const { provider } = fixture([
    release("v0.1.6"),
    release("v0.1.5-beta.1", true),
  ]);
  assert.equal((await provider.getLatestVersionInfo({})).tag_name, "v0.1.6");
});
test("preview selection uses highest SemVer instead of release publication order", async () => {
  const { provider } = fixture([
    release("v0.1.6"),
    release("preview-0.1.7", true),
    release("v0.1.5-beta.1", true),
  ]);
  assert.equal(
    (await provider.getLatestVersionInfo({})).tag_name,
    "preview-0.1.7",
  );
  provider.updater.allowPrerelease = false;
  assert.equal((await provider.getLatestVersionInfo({})).tag_name, "v0.1.6");
});
test("stable-only excludes preview tag prefixes and semantic prereleases even when flags are wrong", async () => {
  const { provider } = fixture(
    [release("preview-9.0.0"), release("v10.0.0-beta.1"), release("v0.1.6")],
    false,
  );
  assert.equal((await provider.getLatestVersionInfo({})).tag_name, "v0.1.6");
});
test("draft, malformed and incomplete Mac releases are skipped", async () => {
  const { provider } = fixture([
    release("v9.0.0", false, { draft: true }),
    release("not-a-version"),
    release("v8.0.0", false, { assets: [asset("app.zip")] }),
    release("v7.0.0", false, { assets: [asset("latest-mac.yml")] }),
    release("v6.0.0", false, {
      assets: [asset("latest-mac.yml"), asset("web-and-notices.zip", 2)],
    }),
    release("v0.1.6"),
  ]);
  assert.equal((await provider.getLatestVersionInfo({})).tag_name, "v0.1.6");
});
test("same-version stable release wins over a preview", async () => {
  const { provider } = fixture([
    release("preview-0.1.6", true),
    release("v0.1.6"),
  ]);
  assert.equal((await provider.getLatestVersionInfo({})).tag_name, "v0.1.6");
});
test("custom factory uses only the app-connected token despite ambient GitHub credentials", async () => {
  const oldGH = process.env.GH_TOKEN,
    oldGithub = process.env.GITHUB_TOKEN;
  process.env.GH_TOKEN = "ambient-gh-fixture";
  process.env.GITHUB_TOKEN = "ambient-github-fixture";
  try {
    const { provider, requests } = fixture([release("v0.1.6")]);
    await provider.getLatestVersionInfo({});
    assert.equal(requests[0].headers.authorization, `token ${TOKEN}`);
    assert.equal(
      provider.fileExtraDownloadHeaders.authorization,
      `token ${TOKEN}`,
    );
    assert.equal(requests[0].hostname, "api.github.com");
    assert.equal(
      requests[0].path,
      `/repos/${OWNER}/${REPO}/releases?per_page=100`,
    );
    assert.equal(requests[0].redirect, "manual");
  } finally {
    if (oldGH === undefined) delete process.env.GH_TOKEN;
    else process.env.GH_TOKEN = oldGH;
    if (oldGithub === undefined) delete process.env.GITHUB_TOKEN;
    else process.env.GITHUB_TOKEN = oldGithub;
  }
});
test("maintained base provider still reads authenticated metadata and resolves private ZIP assets", async () => {
  const { provider, requests } = fixture([
    release("v0.1.6"),
    release("preview-0.1.5", true),
  ]);
  const info = await provider.getLatestVersion();
  assert.equal(info.version, "0.1.6");
  assert.equal(requests.length, 2);
  assert.equal(requests[1].headers.authorization, `token ${TOKEN}`);
  assert.equal(requests[1].path, `/repos/${OWNER}/${REPO}/releases/assets/1`);
  assert.equal(
    provider.resolveFiles(info)[0].url.href,
    asset("app.zip", 2).url,
  );
});
test("asset authentication is confined to this private repository's GitHub API", async () => {
  const hostile = [
    { name: "latest-mac.yml", url: "https://example.test/feed" },
    {
      name: "app.zip",
      url: "https://api.github.com/repos/other/private/releases/assets/3",
    },
    {
      name: "app.zip",
      url: `http://api.github.com/repos/${OWNER}/${REPO}/releases/assets/3`,
    },
  ];
  const { provider } = fixture([
    release("v9.0.0", false, { assets: hostile }),
    release("v0.1.6", false, {
      assets: [
        ...hostile,
        asset("latest-mac.yml"),
        asset("Shenzhen-3D-Apple-Silicon.zip", 2),
      ],
    }),
  ]);
  const selected = await provider.getLatestVersionInfo({});
  assert.equal(selected.tag_name, "v0.1.6");
  assert.equal(selected.assets.length, 2);
  assert.throws(
    () => fixture([], true, { owner: "bad/owner" }),
    /not configured/,
  );
});
test("selection has a bounded 100-release window and fails clearly without eligible candidates", async () => {
  const releases = Array.from({ length: 100 }, () => release("v0.1.6"));
  releases.push(release("v99.0.0"));
  const { provider, requests } = fixture(releases);
  assert.equal((await provider.getLatestVersionInfo({})).tag_name, "v0.1.6");
  assert.equal(requests.length, 1);
  await assert.rejects(
    fixture([]).provider.getLatestVersionInfo({}),
    /No compatible Mac release/,
  );
});

async function withAmbientTokens(run) {
  const oldGH = process.env.GH_TOKEN,
    oldGithub = process.env.GITHUB_TOKEN;
  process.env.GH_TOKEN = "ambient-gh-fixture";
  process.env.GITHUB_TOKEN = "ambient-github-fixture";
  try {
    await run();
  } finally {
    if (oldGH === undefined) delete process.env.GH_TOKEN;
    else process.env.GH_TOKEN = oldGH;
    if (oldGithub === undefined) delete process.env.GITHUB_TOKEN;
    else process.env.GITHUB_TOKEN = oldGithub;
  }
}
function publicFixture(releases, owner = "casimir-engineering") {
  const requests = [];
  const executor = {
    request: async (request) => {
      requests.push(request);
      if (request.path.includes("/releases?")) return JSON.stringify(releases);
      return "version: 0.1.6\nfiles:\n  - url: Shenzhen-3D-Apple-Silicon.zip\n    sha512: fixture-sha512\n";
    },
  };
  const provider = createClient(
    {
      provider: "custom",
      updateProvider: PublicReleaseProvider,
      owner,
      repo: REPO,
    },
    { allowPrerelease: true },
    { executor, platform: "darwin" },
  );
  return { provider, requests };
}
const publicAsset = (name, id = 1) => ({
  name,
  url: `https://api.github.com/repos/casimir-engineering/${REPO}/releases/assets/${id}`,
});
test("public build reads the releases API and assets without any Authorization header", async () => {
  await withAmbientTokens(async () => {
    const { provider, requests } = publicFixture([
      release("v0.1.6", false, {
        assets: [
          publicAsset("latest-mac.yml"),
          publicAsset("Shenzhen-3D-Apple-Silicon.zip", 2),
        ],
      }),
    ]);
    const info = await provider.getLatestVersion();
    assert.equal(info.version, "0.1.6");
    assert.equal(requests.length, 2);
    assert.equal(requests[0].hostname, "api.github.com");
    assert.equal(
      requests[0].path,
      `/repos/casimir-engineering/${REPO}/releases?per_page=100`,
    );
    assert.equal(
      requests[1].path,
      `/repos/casimir-engineering/${REPO}/releases/assets/1`,
    );
    for (const request of requests)
      assert.equal(
        Object.keys(request.headers).some(
          (name) => name.toLowerCase() === "authorization",
        ),
        false,
      );
    assert.deepEqual(provider.fileExtraDownloadHeaders, {
      accept: "application/octet-stream",
    });
    assert.equal(
      provider.resolveFiles(info)[0].url.href,
      publicAsset("app.zip", 2).url,
    );
  });
});
test("public provider refuses credentials and assets from other repositories", async () => {
  for (const extra of [
    { token: TOKEN },
    { private: true },
    { headers: { authorization: `token ${TOKEN}` } },
  ])
    assert.throws(
      () =>
        createClient(
          {
            provider: "custom",
            updateProvider: PublicReleaseProvider,
            owner: "casimir-engineering",
            repo: REPO,
            ...extra,
          },
          { allowPrerelease: true },
          { executor: {}, platform: "darwin" },
        ),
      /must not carry credentials/,
    );
  assert.throws(() => publicFixture([], "bad/owner"), /not configured/);
  const { provider } = publicFixture([
    release("v9.0.0", false, {
      assets: [
        asset("latest-mac.yml"),
        asset("Shenzhen-3D-Apple-Silicon.zip", 2),
      ],
    }),
  ]);
  await assert.rejects(
    provider.getLatestVersionInfo({}),
    /No compatible Mac release/,
  );
});
