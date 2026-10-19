// Reads friends.lock the way scripts/friends/friends-lock.sh does, for packaging and the Electron tests. The lock is
// parsed, never evaluated: it is data, and a stray line must be an error. electron/friends-lock.test.cjs holds the
// two readers to the same answers.
const fs = require("node:fs");
const path = require("node:path");

const HELPER_NAME = "Shenzhen Friends";
// Every app embeds the helper under this one identifier, so they share one Friends identity per Mac user.
const HELPER_ID = "com.intuition.shenzhenfriends";

function parseFriendsLock(text) {
  const values = {};
  const lines = text.split("\n");
  lines.forEach((line, index) => {
    if (!line.trim() || line.startsWith("#")) return;
    const equals = line.indexOf("=");
    if (equals < 0)
      throw Error(`friends.lock line ${index + 1} is not key=value: ${line}`);
    const key = line.slice(0, equals),
      value = line.slice(equals + 1);
    if (Object.hasOwn(values, key))
      throw Error(`friends.lock line ${index + 1} sets ${key} a second time`);
    if (!["url", "commit", "helper_build_number", "core_commit"].includes(key))
      throw Error(`friends.lock line ${index + 1}: unknown key '${key}'`);
    values[key] = value;
  });
  if (!values.url) throw Error("friends.lock has no url=");
  if (!/^[0-9a-f]{40}$/.test(values.commit ?? ""))
    throw Error(
      `friends.lock: commit must be a full 40-digit lowercase commit id, not '${values.commit ?? ""}'`,
    );
  if (
    values.core_commit !== undefined &&
    !/^[0-9a-f]{40}$/.test(values.core_commit)
  )
    throw Error(
      `friends.lock: core_commit must be a full 40-digit lowercase commit id, not '${values.core_commit}'`,
    );
  const number = values.helper_build_number ?? "";
  const match = /^(\d{2})(\d{2})(\d{2})(\d{2})$/.exec(number);
  const [year, month, day, build] = match
    ? match.slice(1).map((part) => Number(part))
    : [0, 0, 0, 0];
  if (!match || month < 1 || month > 12 || day < 1 || day > 31 || build < 1)
    throw Error(
      `friends.lock: helper_build_number must be YYMMDDBB (for example 26101101), not '${number}'`,
    );
  return {
    url: values.url,
    commit: values.commit,
    // The commit the Tauri builds' plugin and Rust helper come from; null while they have none.
    coreCommit: values.core_commit ?? null,
    buildNumber: Number(number),
    shortVersion: `${year}.${month}.${day}`,
    bundleVersion: String(build),
  };
}

// "tree" in the Shenzhen repository, where this app is apps/3d beside ShenzhenPDF in apps/pdf and Friends is built
// from apps/pdf in the same tree; "pinned" in the standalone repository, where friends.lock names the commit.
// SZF_FRIENDS_MODE chooses explicitly; SZF_FRIENDS_ROOT implies "pinned". scripts/friends/friends-lock.sh decides
// the same way.
function friendsMode(repoRoot, env = process.env) {
  const mode = env.SZF_FRIENDS_MODE;
  if (mode === "tree" || mode === "pinned") return mode;
  if (mode)
    throw Error(`SZF_FRIENDS_MODE must be tree or pinned, not '${mode}'`);
  const resolved = path.resolve(repoRoot);
  return !env.SZF_FRIENDS_ROOT &&
    path.basename(path.dirname(resolved)) === "apps" &&
    fs.existsSync(path.join(resolved, "../pdf/portable/friends"))
    ? "tree"
    : "pinned";
}

// Tree mode: the helper's version keys are ShenzhenPDF's own, MAC_VERSION and MAC_BUILD in apps/pdf's
// portable/Makefile, with no pinned commit.
function readTreeVersion(repoRoot) {
  const makefile = path.join(repoRoot, "../pdf/portable/Makefile");
  const text = fs.readFileSync(makefile, "utf8");
  const value = (name) =>
    new RegExp(`^${name} \\?= (\\S+)`, "m").exec(text)?.[1] ?? "";
  const version = value("MAC_VERSION"),
    build = value("MAC_BUILD");
  const match = /^(\d+)\.([1-9]\d?)\.([1-9]\d?)$/.exec(version);
  if (!match || !/^[1-9]\d?$/.test(build))
    throw Error(
      `cannot read MAC_VERSION (YY.M.D) and MAC_BUILD from ${makefile}`,
    );
  const [year, month, day] = match.slice(1).map(Number);
  const pad = (n) => String(n).padStart(2, "0");
  return {
    url: null,
    commit: null,
    coreCommit: null,
    buildNumber: Number(
      `${pad(year % 100)}${pad(month)}${pad(day)}${pad(build)}`,
    ),
    shortVersion: version,
    bundleVersion: build,
  };
}

function readFriendsLock(repoRoot, env = process.env) {
  if (friendsMode(repoRoot, env) === "tree")
    return {
      mode: "tree",
      keysFrom: "apps/pdf/portable/Makefile",
      ...readTreeVersion(repoRoot),
    };
  return {
    mode: "pinned",
    keysFrom: "friends.lock",
    ...parseFriendsLock(
      fs.readFileSync(path.join(repoRoot, "friends.lock"), "utf8"),
    ),
  };
}

// Where setup-friends.sh builds: apps/pdf in tree mode; otherwise SZF_FRIENDS_ROOT, or friends-src/ next to the
// repository's root.
function friendsBuild(repoRoot, env = process.env) {
  const root =
    friendsMode(repoRoot, env) === "tree"
      ? fs.realpathSync(path.join(repoRoot, "../pdf"))
      : env.SZF_FRIENDS_ROOT
        ? path.resolve(env.SZF_FRIENDS_ROOT)
        : path.join(repoRoot, "friends-src");
  return {
    root,
    helperApp: path.join(root, "portable/build/friends", `${HELPER_NAME}.app`),
    fakeHelper: path.join(
      root,
      "portable/build/friends/client-fake/szfriends-fake-helper",
    ),
    animals: path.join(root, "portable/friends/avatars/animals"),
    acknowledgements: path.join(root, "portable/friends/ACKNOWLEDGEMENTS.txt"),
  };
}

module.exports = {
  HELPER_NAME,
  HELPER_ID,
  parseFriendsLock,
  friendsMode,
  readFriendsLock,
  friendsBuild,
};
