// Loaded first by the main script of a Shenzhen 3D test copy (tools/updater-e2e/prep-3d-fixture.mjs), never by a
// release build: the copy runs under a profile of its own, so its single-instance lock, settings and Friends never
// meet those of a Shenzhen 3D installed on the same Mac. Electron keeps the single-instance lock in the profile folder.
// A test copy that the updater reopens after installing is started by launchd without the test's --user-data-dir; with
// the installed app's profile it would hold that app's lock, and the person's own Shenzhen 3D would quit at launch.
//
// The profile is the --user-data-dir the test passes, or else "szut-profile" beside the .app, inside the test's work
// directory. A profile made here starts with Friends off, so no Friends helper starts from it either.
//
// Friends: a packaged copy keeps its Friends home under $HOME, and a Developer ID signed one ignores
// SZFRIENDS_STATE_DIR. Started with the person's home, a test copy would serve their Friends: its helper (often a newer
// build) takes over their helper.sock, and their ShenzhenPDF and Shenzhen Files stay on "Starting Friends…" long after
// the test. So a copy whose HOME is still the account's gets "home" inside its profile, and the helper it starts
// inherits it. GitHub CLI (Updates' "Use GitHub CLI") still runs with the account's home, where its login is.
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const PROFILE_BESIDE_APP = "szut-profile";

function testProfile(argv, execPath) {
  const index = argv.findIndex(
    (a) => a === "--user-data-dir" || a.startsWith("--user-data-dir="),
  );
  const given =
    index < 0
      ? undefined
      : argv[index].includes("=")
        ? argv[index].slice("--user-data-dir=".length)
        : argv[index + 1];
  if (given) return { profile: path.resolve(given), given: true };
  // <dir>/Shenzhen 3D.app/Contents/MacOS/Shenzhen 3D -> <dir>/szut-profile
  const bundle = path.resolve(execPath, "../../..");
  return {
    profile: path.join(path.dirname(bundle), PROFILE_BESIDE_APP),
    given: false,
  };
}

const real = (p) => {
  try {
    return fs.realpathSync(p);
  } catch {
    return path.resolve(p);
  }
};

/** HOME for a test copy: the one it was given unless that is the account's own, else `<profile>/home`. */
function isolateHome(profile, env = process.env, account = os.userInfo().homedir) {
  if (env.HOME && path.isAbsolute(env.HOME) && real(env.HOME) !== real(account))
    return env.HOME;
  const home = path.join(profile, "home");
  fs.mkdirSync(home, { recursive: true });
  env.HOME = home;
  env.CFFIXED_USER_HOME = home;
  return home;
}

/** GitHub CLI, run by absolute path, gets the account's home back; nothing else does. */
function cliWithAccountHome(childProcess = require("node:child_process"), account = os.userInfo().homedir) {
  const execFile = childProcess.execFile;
  childProcess.execFile = function (file, ...rest) {
    if (typeof file !== "string" || !/^\/(opt\/homebrew|usr\/local|usr)\/bin\/gh$/.test(file))
      return execFile.call(this, file, ...rest);
    const at = rest.findIndex((x) => x && typeof x === "object" && !Array.isArray(x));
    const options = at < 0 ? {} : rest[at];
    const env = { ...(options.env ?? process.env), HOME: account };
    delete env.CFFIXED_USER_HOME;
    if (at < 0) rest.splice(Array.isArray(rest[0]) ? 1 : 0, 0, { env });
    else rest[at] = { ...options, env };
    return execFile.call(this, file, ...rest);
  };
}

function isolate(app, argv = process.argv, execPath = process.execPath, env = process.env) {
  const { profile, given } = testProfile(argv, execPath);
  fs.mkdirSync(profile, { recursive: true });
  const friends = path.join(profile, "friends.json");
  if (!given && !fs.existsSync(friends))
    fs.writeFileSync(friends, JSON.stringify({ enabled: false }));
  // Before main.cjs runs: it asks for the single-instance lock as it loads, and it only moves to an older profile
  // when the current one does not exist, which this one now does.
  app.setPath("userData", profile);
  isolateHome(profile, env);
  return profile;
}

module.exports = { PROFILE_BESIDE_APP, testProfile, isolate, isolateHome, cliWithAccountHome };

if (process.versions.electron && process.type === "browser") {
  isolate(require("electron").app);
  cliWithAccountHome();
}
