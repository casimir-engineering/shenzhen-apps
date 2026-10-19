// The release owner whose shenzhen-3D releases are private, or null when every
// owner publishes public releases. Builds for that owner need GitHub access
// connected in the app before they can update; every other build reads
// public GitHub releases without credentials. This is the only setting that
// differs for a copy that ships from a private release repository.
const PRIVATE_RELEASE_OWNER = null;

const RELEASE_ACCESS = ["public", "private"];
function isReleaseOwner(owner) {
  return (
    typeof owner === "string" &&
    /^[a-z0-9](?:[a-z0-9-]{0,37}[a-z0-9])?$/.test(owner)
  );
}
function assertReleaseOwner(owner) {
  if (!isReleaseOwner(owner)) throw Error("Invalid release owner");
  return owner;
}
function assertReleaseAccess(access) {
  if (!RELEASE_ACCESS.includes(access)) throw Error("Invalid release access");
  return access;
}
/** Whether a build for `owner` reads public releases or needs GitHub access. */
function releaseAccessFor(owner, privateOwner = PRIVATE_RELEASE_OWNER) {
  assertReleaseOwner(owner);
  if (privateOwner !== null) assertReleaseOwner(privateOwner);
  return owner === privateOwner ? "private" : "public";
}
function resolveReleaseOwner(metadata, packaged) {
  if (!packaged && metadata?.releaseOwner === undefined) return null;
  return assertReleaseOwner(metadata?.releaseOwner);
}
/** Signed package metadata must carry the access this source assigns its owner. */
function resolveReleaseAccess(metadata, privateOwner = PRIVATE_RELEASE_OWNER) {
  const owner = assertReleaseOwner(metadata?.releaseOwner);
  if (
    assertReleaseAccess(metadata.releaseAccess) !==
    releaseAccessFor(owner, privateOwner)
  )
    throw Error("Packaged release access does not match this source");
  return metadata.releaseAccess;
}
function resolveArtifactReleaseOwner(metadata, provenance) {
  const owner = assertReleaseOwner(metadata.releaseOwner);
  if (assertReleaseOwner(provenance.releaseOwner) !== owner)
    throw Error("Staged release owner does not match provenance");
  return owner;
}
/** Artifacts built before public releases existed carry no access and were private. */
function resolveArtifactReleaseAccess(metadata, provenance) {
  const access = assertReleaseAccess(metadata.releaseAccess ?? "private");
  if (assertReleaseAccess(provenance.releaseAccess ?? "private") !== access)
    throw Error("Staged release access does not match provenance");
  return access;
}
function validatePackagedFeed(feed, owner, access = releaseAccessFor(owner)) {
  assertReleaseOwner(owner);
  assertReleaseAccess(access);
  if (
    !feed ||
    feed.provider !== "github" ||
    feed.owner !== owner ||
    feed.repo !== "shenzhen-3D" ||
    (access === "private" ? feed.private !== true : feed.private === true) ||
    feed.channel !== "latest" ||
    "token" in feed ||
    "headers" in feed ||
    "requestHeaders" in feed
  )
    throw Error("Packaged update feed does not match release owner");
  return feed;
}
// GitHub token formats: classic and OAuth/app tokens, and fine-grained PATs.
const GITHUB_TOKEN_PATTERN =
  /\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})/;
/** Release tooling never embeds a GitHub credential in shipped files. */
function assertNoGitHubToken(text, filename) {
  if (GITHUB_TOKEN_PATTERN.test(text))
    throw Error(`GitHub token found in packaged file: ${filename}`);
}
module.exports = {
  PRIVATE_RELEASE_OWNER,
  isReleaseOwner,
  assertReleaseOwner,
  assertReleaseAccess,
  releaseAccessFor,
  resolveReleaseOwner,
  resolveReleaseAccess,
  resolveArtifactReleaseOwner,
  resolveArtifactReleaseAccess,
  validatePackagedFeed,
  assertNoGitHubToken,
};
