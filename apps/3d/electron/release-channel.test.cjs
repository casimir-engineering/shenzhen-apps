const { test } = require("node:test");
const assert = require("node:assert/strict");
const RELEASE_OWNERS = ["fixture-primary", "fixture-secondary"];
const {
  PRIVATE_RELEASE_OWNER,
  isReleaseOwner,
  releaseAccessFor,
  resolveReleaseOwner,
  resolveReleaseAccess,
  resolveArtifactReleaseOwner,
  resolveArtifactReleaseAccess,
  validatePackagedFeed,
  assertNoGitHubToken,
} = require("./release-channel.cjs");

test("packaged release source requires explicit valid signed metadata", () => {
  for (const owner of RELEASE_OWNERS)
    assert.equal(resolveReleaseOwner({ releaseOwner: owner }, true), owner);
  for (const metadata of [
    {},
    null,
    { releaseOwner: "bad/owner" },
    { releaseOwner: "../fixture-secondary" },
  ])
    assert.throws(
      () => resolveReleaseOwner(metadata, true),
      /Invalid release owner/,
    );
  assert.equal(resolveReleaseOwner({}, false), null);
});
test("feed validation binds owner and private repository without credentials", () => {
  for (const owner of RELEASE_OWNERS) {
    const feed = {
      provider: "github",
      owner,
      repo: "shenzhen-3D",
      private: true,
      channel: "latest",
    };
    assert.equal(validatePackagedFeed(feed, owner, "private"), feed);
    for (const change of [
      { owner: RELEASE_OWNERS.find((x) => x !== owner) },
      { repo: "other" },
      { provider: "generic" },
      { private: false },
      { channel: "beta" },
      { token: "forbidden" },
      { headers: {} },
      { requestHeaders: {} },
    ])
      assert.throws(
        () => validatePackagedFeed({ ...feed, ...change }, owner, "private"),
        /does not match/,
      );
  }
});
test("public feeds carry no private flag or credentials", () => {
  const owner = "casimir-engineering";
  const feed = {
    provider: "github",
    owner,
    repo: "shenzhen-3D",
    private: false,
    channel: "latest",
  };
  assert.equal(validatePackagedFeed(feed, owner, "public"), feed);
  const { private: _omitted, ...withoutFlag } = feed;
  assert.equal(validatePackagedFeed(withoutFlag, owner, "public"), withoutFlag);
  for (const change of [
    { private: true },
    { token: "forbidden" },
    { headers: {} },
    { requestHeaders: {} },
  ])
    assert.throws(
      () => validatePackagedFeed({ ...feed, ...change }, owner, "public"),
      /does not match/,
    );
  assert.throws(
    () => validatePackagedFeed(feed, owner, "anonymous"),
    /Invalid release access/,
  );
});
test("only the configured private owner needs GitHub access", () => {
  assert.ok(
    PRIVATE_RELEASE_OWNER === null || isReleaseOwner(PRIVATE_RELEASE_OWNER),
  );
  assert.equal(releaseAccessFor("casimir-engineering", null), "public");
  assert.equal(
    releaseAccessFor("casimir-engineering", "fixture-private"),
    "public",
  );
  assert.equal(
    releaseAccessFor("fixture-private", "fixture-private"),
    "private",
  );
  for (const owner of RELEASE_OWNERS)
    assert.equal(
      releaseAccessFor(owner),
      owner === PRIVATE_RELEASE_OWNER ? "private" : "public",
    );
  assert.throws(() => releaseAccessFor("bad/owner", null), /Invalid/);
  assert.throws(
    () => releaseAccessFor("casimir-engineering", "bad/owner"),
    /Invalid/,
  );
});
test("signed metadata must carry the access its source assigns the owner", () => {
  assert.equal(
    resolveReleaseAccess(
      { releaseOwner: "casimir-engineering", releaseAccess: "public" },
      null,
    ),
    "public",
  );
  assert.equal(
    resolveReleaseAccess(
      { releaseOwner: "fixture-private", releaseAccess: "private" },
      "fixture-private",
    ),
    "private",
  );
  for (const [metadata, privateOwner] of [
    [{ releaseOwner: "casimir-engineering", releaseAccess: "private" }, null],
    [
      { releaseOwner: "fixture-private", releaseAccess: "public" },
      "fixture-private",
    ],
    [{ releaseOwner: "casimir-engineering" }, null],
  ])
    assert.throws(() => resolveReleaseAccess(metadata, privateOwner));
  assert.equal(resolveArtifactReleaseAccess({}, {}), "private");
  assert.equal(
    resolveArtifactReleaseAccess(
      { releaseAccess: "public" },
      { releaseAccess: "public" },
    ),
    "public",
  );
  assert.throws(
    () => resolveArtifactReleaseAccess({ releaseAccess: "public" }, {}),
    /does not match provenance/,
  );
});
test("GitHub tokens are refused in shipped text", () => {
  // Built at runtime so no credential-shaped literal sits in the source.
  const fakes = [
    "ghp_" + "A1".repeat(18),
    "gho_" + "b2".repeat(18),
    "github_pat_" + "C3_".repeat(20),
  ];
  for (const fake of fakes)
    assert.throws(
      () => assertNoGitHubToken(`const token = "${fake}";`, "app.js"),
      /GitHub token found in packaged file: app\.js/,
    );
  assertNoGitHubToken("ghp_short and github_pat_ mentions", "notes.txt");
});

test("notarization retains selected origin and refuses missing modern provenance", () => {
  for (const owner of RELEASE_OWNERS)
    assert.equal(
      resolveArtifactReleaseOwner(
        { version: "0.1.6", releaseOwner: owner },
        { releaseOwner: owner },
      ),
      owner,
    );
  assert.throws(
    () => resolveArtifactReleaseOwner({ version: "0.1.4" }, {}),
    /Invalid release owner/,
  );
  assert.throws(
    () => resolveArtifactReleaseOwner({ version: "0.1.6" }, {}),
    /Invalid release owner/,
  );
  assert.throws(
    () =>
      resolveArtifactReleaseOwner(
        { version: "0.1.6", releaseOwner: "fixture-secondary" },
        { releaseOwner: "fixture-primary" },
      ),
    /does not match provenance/,
  );
  assert.throws(
    () =>
      resolveArtifactReleaseOwner(
        { version: "0.1.6", releaseOwner: "fixture-secondary" },
        {},
      ),
    /Invalid release owner/,
  );
});

test("owner validation accepts repository-neutral names and rejects paths/control characters", () => {
  for (const owner of ["fixture-primary", "team7", "a"])
    assert.equal(isReleaseOwner(owner), true);
  for (const owner of [
    "",
    null,
    "-team",
    "team-",
    "team/name",
    "a".repeat(40),
    "team\nname",
    "https://example.test",
  ])
    assert.equal(isReleaseOwner(owner), false);
});
