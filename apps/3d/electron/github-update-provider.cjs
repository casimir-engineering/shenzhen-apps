const {
  PrivateGitHubProvider,
} = require("electron-updater/out/providers/PrivateGitHubProvider");
const semver = require("semver");

const { isReleaseOwner } = require("./release-channel.cjs");
const REPOSITORY = "shenzhen-3D";
const MAC_ZIP =
  /^Shenzhen-3D-(?:.*-)?(?:Apple-Silicon|arm64|x64|universal)\.zip$/i;

function releaseVersion(tag) {
  if (typeof tag !== "string") return null;
  return semver.valid(tag.replace(/^preview-/, "").replace(/^v/, ""));
}

const validToken = (token) =>
  typeof token === "string" &&
  !!token.trim() &&
  token.length <= 4096 &&
  !/[\r\n\0]/.test(token);

/**
 * Reads this owner's shenzhen-3D releases through the GitHub releases API and
 * keeps the library's asset download and native Mac install path. Subclasses
 * decide whether requests carry the credential connected in the app.
 */
class ReleaseProvider extends PrivateGitHubProvider {
  constructor(options, updater, runtimeOptions, token) {
    if (!isReleaseOwner(options.owner) || options.repo !== REPOSITORY)
      throw new Error("Update source is not configured.");
    super(
      { owner: options.owner, repo: REPOSITORY, private: token !== undefined },
      updater,
      token,
      runtimeOptions,
    );
  }

  validAsset(asset) {
    if (
      !asset ||
      typeof asset.name !== "string" ||
      typeof asset.url !== "string"
    )
      return false;
    try {
      const url = new URL(asset.url);
      const prefix =
        `/repos/${this.options.owner}/${REPOSITORY}/releases/assets/`.toLowerCase();
      return (
        url.protocol === "https:" &&
        url.hostname === "api.github.com" &&
        !url.port &&
        !url.username &&
        !url.password &&
        !url.search &&
        !url.hash &&
        url.pathname.toLowerCase().startsWith(prefix) &&
        /^\d+$/.test(url.pathname.slice(prefix.length))
      );
    } catch {
      return false;
    }
  }

  async getLatestVersionInfo(cancellationToken) {
    // Bound work and API traffic to the 100 most recently published releases.
    // Historical releases beyond this window are intentionally not update candidates.
    const url = new URL(
      `https://api.github.com/repos/${this.options.owner}/${REPOSITORY}/releases?per_page=100`,
    );
    const releases = JSON.parse(
      await this.httpRequest(
        url,
        this.configureHeaders("application/vnd.github+json"),
        cancellationToken,
      ),
    );
    if (!Array.isArray(releases))
      throw new Error("Release list is unavailable.");
    let selected, selectedVersion, selectedPreview;
    for (const release of releases.slice(0, 100)) {
      if (!release || release.draft) continue;
      const version = releaseVersion(release.tag_name);
      if (!version) continue;
      const preview =
        !!release.prerelease ||
        release.tag_name.startsWith("preview-") ||
        semver.prerelease(version) !== null;
      if (preview && !this.updater.allowPrerelease) continue;
      const assets = Array.isArray(release.assets)
        ? release.assets.filter((asset) => this.validAsset(asset))
        : [];
      if (
        !assets.some((asset) => asset.name === "latest-mac.yml") ||
        !assets.some((asset) => MAC_ZIP.test(asset.name))
      )
        continue;
      if (
        !selected ||
        semver.gt(version, selectedVersion) ||
        (semver.eq(version, selectedVersion) && selectedPreview && !preview)
      ) {
        selected = { ...release, assets };
        selectedVersion = version;
        selectedPreview = preview;
      }
    }
    if (!selected) throw new Error("No compatible Mac release is available.");
    return selected;
  }
}

/** Public releases: requests never carry a credential, ambient or connected. */
class PublicReleaseProvider extends ReleaseProvider {
  constructor(options, updater, runtimeOptions) {
    if ("token" in options || "headers" in options || options.private)
      throw new Error("Public update source must not carry credentials.");
    super(options, updater, runtimeOptions, undefined);
  }

  configureHeaders(accept) {
    return { accept };
  }
}

/** Private releases: only the credential connected in this app is sent. */
class PrivateReleaseProvider extends ReleaseProvider {
  constructor(options, updater, runtimeOptions) {
    if (!validToken(options.token))
      throw new Error("Private update access is not configured.");
    // Custom provider construction bypasses the GitHub factory's GH_TOKEN /
    // GITHUB_TOKEN precedence. Only the credential connected in this app is used.
    super(options, updater, runtimeOptions, options.token);
  }
}

module.exports = { PublicReleaseProvider, PrivateReleaseProvider };
