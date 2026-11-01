// A packaged Shenzhen 3D started by a test (smoke.mjs and recent-files-smoke.mjs with --executable=). A packaged app
// offers Friends and keeps its Friends home under $HOME; a Developer ID signed one ignores SZFRIENDS_STATE_DIR. With the
// person's home its helper would serve their Friends, take over their helper.sock and outlive the test. So the test
// gives it a home of its own, and ends whatever still runs from the .app (the Friends helper included) by the PIDs
// tools/updater-e2e/sweep.py finds by exact path, never by name.
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const SWEEP = fileURLToPath(new URL("../../../tools/updater-e2e/sweep.py", import.meta.url));

/** `environment` with HOME (and CFFIXED_USER_HOME) in `directory`/home. */
export function packagedEnvironment(environment, directory) {
  const home = path.join(directory, "home");
  fs.mkdirSync(home, { recursive: true });
  return { ...environment, HOME: home, CFFIXED_USER_HOME: home };
}

/** Ends what still runs from the .app of `executable` after a grace period; true when something was left. */
export function endPackaged(executable) {
  const bundle = path.resolve(executable, "../../..");
  const r = spawnSync("python3", ["-I", SWEEP, "--grace=15", "--kill", bundle], { encoding: "utf8" });
  if (r.status !== 0) console.error(`${r.stdout ?? ""}${r.stderr ?? ""}${r.error ?? ""}`.trim());
  return r.status !== 0;
}
