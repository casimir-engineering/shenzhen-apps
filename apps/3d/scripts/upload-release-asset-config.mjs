import fs from "node:fs";
import path from "node:path";

// Operator-owned, ignored local file; never embedded in packaged apps.
// { "version": 1, "repositories": ["authorized-owner/shenzhen-3D"] }
// Override its path with SHENZHEN_RELEASE_UPLOAD_CONFIG when necessary.
export function validOwner(owner) {
  return (
    typeof owner === "string" &&
    /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$/.test(owner)
  );
}
export function loadAuthorizedRepositories(
  filename = process.env.SHENZHEN_RELEASE_UPLOAD_CONFIG ||
    path.resolve("artifacts/operator/release-upload.json"),
) {
  let config;
  try {
    const stat = fs.lstatSync(filename);
    if (
      !stat.isFile() ||
      stat.isSymbolicLink() ||
      (stat.mode & 0o777) !== 0o600 ||
      stat.size > 64 * 1024 ||
      (typeof process.getuid === "function" && stat.uid !== process.getuid())
    )
      throw Error();
    config = JSON.parse(fs.readFileSync(filename, "utf8"));
  } catch {
    throw Error(
      "Private release upload operator config is missing, invalid or insecure.",
    );
  }
  if (
    !config ||
    config.version !== 1 ||
    !Array.isArray(config.repositories) ||
    config.repositories.length < 1 ||
    config.repositories.length > 8 ||
    new Set(config.repositories).size !== config.repositories.length ||
    Object.keys(config).some(
      (key) => !["version", "repositories"].includes(key),
    )
  )
    throw Error("Invalid release upload operator config.");
  for (const repo of config.repositories) {
    if (typeof repo !== "string") throw Error("Invalid authorized repository.");
    const parts = repo.split("/");
    if (
      parts.length !== 2 ||
      !validOwner(parts[0]) ||
      parts[1] !== "shenzhen-3D"
    )
      throw Error("Invalid authorized repository.");
  }
  return new Set(config.repositories);
}
export function assertAuthorizedRepository(repo) {
  if (!loadAuthorizedRepositories().has(repo))
    throw Error("Repository is not authorized by the local operator config.");
}
