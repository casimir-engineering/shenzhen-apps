// The iOS half of phones-exchange.mjs: a `friends-smoke` debug build already installed in the simulator `udid`. The
// simulator shares the Mac's files and loopback, so the phone's test home and routes are the Mac's directories, named
// in its environment, and the page runs phones-exchange-page.js as its smoke script. The app's standard output goes
// to the simulator's log, where its report is read.
import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs/promises";
import path from "node:path";

const BUNDLE = "com.shenzhen3d.viewer";
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export function ios(udid) {
  const simctl = (...args) => execFileSync("xcrun", ["simctl", ...args], { encoding: "utf8" });
  let child;
  let output = "";
  let routes;
  let home;
  return {
    async install({ homePhone, routes: shared, page, work }) {
      routes = shared;
      // `log show --start` reads the simulator's local time.
      const now = new Date(Date.now() - 1000);
      this.started = new Date(now - now.getTimezoneOffset() * 60_000).toISOString().replace("T", " ").slice(0, 19);
      home = homePhone;
      const script = path.join(work, "phone-page.js");
      const source = await fs.readFile(new URL("./phones-exchange-page.js", import.meta.url), "utf8");
      await fs.writeFile(script, `window.__SZF_PHONE__ = ${JSON.stringify(page)};\n${source}`);
      child = spawn("xcrun", ["simctl", "launch", "--console", "--terminate-running-process", udid, BUNDLE], {
        env: {
          ...process.env,
          SIMCTL_CHILD_SZFRIENDS_STATE_DIR: homePhone,
          SIMCTL_CHILD_SZFRIENDS_TEST_LOOPBACK: shared,
          SIMCTL_CHILD_SHENZHEN_3D_SMOKE: script,
        },
        stdio: ["ignore", "pipe", "pipe"],
      });
      child.stdout.setEncoding("utf8");
      child.stdout.on("data", (text) => {
        output += text;
      });
      this.exited = new Promise((resolve) => child.on("exit", resolve));
    },
    // The simulator shares the Mac's loopback and files: both sides list their entries in the same directory.
    async route(macEntries) {
      for (let i = 0; i < 240; i++) {
        const names = await fs.readdir(routes);
        if (names.some((n) => n.endsWith(".entry") && !n.startsWith(".") && !macEntries.includes(n))) return;
        await wait(250);
      }
      throw Error(`the phone wrote no route; the app said:\n${output.slice(-3000)}`);
    },
    async run() {
      let log = "";
      for (let i = 0; i < 300 && !/SMOKE-(PASSED|FAILED)/.test(log); i++) {
        await wait(1000);
        log = simctl("spawn", udid, "log", "show", "--style", "compact", "--start", this.started,
          "--predicate", 'process == "Shenzhen 3D" AND eventMessage CONTAINS "SMOKE"');
      }
      const lines = [...log.matchAll(/SMOKE (.*)$/gm)].map((m) => m[1]);
      return { ok: log.includes("SMOKE-PASSED"), lines };
    },
    async received(name) {
      return fs.readFile(path.join(home, "received", name), "utf8");
    },
    async screenshot(file) {
      await fs.mkdir(path.dirname(file), { recursive: true });
      simctl("io", udid, "screenshot", file);
    },
    async cleanup() {
      child?.kill();
    },
  };
}
