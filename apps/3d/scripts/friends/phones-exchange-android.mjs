// The Android half of phones-exchange.mjs: a debug APK already installed on the emulator `serial`, its Friends
// test home pushed with `run-as`, its test network joined to the Mac's through adb, its page driven through the
// WebView's DevTools.
//
// The test network is a directory of entries, `<name>.entry` (JSON with the port), one per listener, which change with
// each presence window. While the exchange runs, each side's entries are copied to the other's directory and their
// ports joined: the Mac's with `adb reverse`, the phone's with `adb forward`.
import { execFileSync } from "node:child_process";
import fs from "node:fs/promises";
import path from "node:path";

const PACKAGE = "com.shenzhen3d.viewer";
const FILES = `/data/user/0/${PACKAGE}/files`;
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export function android(serial) {
  const adb = (...args) => execFileSync("adb", ["-s", serial, ...args], { encoding: "utf8" });
  const adbBytes = (...args) => execFileSync("adb", ["-s", serial, ...args], { maxBuffer: 1 << 28 });
  const runAs = (command) => adb("shell", `run-as ${PACKAGE} sh -c '${command}'`);
  const push = async (local, remote) => {
    const temporary = `/data/local/tmp/szf-${path.basename(local)}`;
    adb("push", local, temporary);
    adb("shell", `cat ${temporary} | run-as ${PACKAGE} sh -c 'cat > ${remote}'`);
    adb("shell", `rm ${temporary}`);
  };
  let devtools = 0;
  const toPhone = new Map(); // the Mac's entries copied to the phone: name -> port
  const toMac = new Map(); // the phone's entries copied to the Mac
  let bridging = false;

  const isEntry = (name) => name.endsWith(".entry") && !name.startsWith(".");
  async function mirror(routes, work) {
    const mac = (await fs.readdir(routes)).filter(isEntry);
    for (const name of mac.filter((n) => !toPhone.has(n) && !toMac.has(n))) {
      const text = await fs.readFile(path.join(routes, name), "utf8");
      const { port } = JSON.parse(text);
      adb("reverse", `tcp:${port}`, `tcp:${port}`);
      const local = path.join(work, `.${name}.tmp`);
      await fs.writeFile(local, text);
      await push(local, `files/froutes/.${name}.tmp`);
      runAs(`mv files/froutes/.${name}.tmp files/froutes/${name}`);
      toPhone.set(name, port);
    }
    for (const name of [...toPhone.keys()].filter((n) => !mac.includes(n))) {
      runAs(`rm -f files/froutes/${name}`);
      toPhone.delete(name);
    }
    const phone = runAs("ls files/froutes").split(/\s+/).filter(isEntry);
    for (const name of phone.filter((n) => !toPhone.has(n) && !toMac.has(n))) {
      const text = runAs(`cat files/froutes/${name}`);
      const { port } = JSON.parse(text);
      adb("forward", `tcp:${port}`, `tcp:${port}`);
      await fs.writeFile(path.join(routes, `.${name}.tmp`), text);
      await fs.rename(path.join(routes, `.${name}.tmp`), path.join(routes, name));
      toMac.set(name, port);
    }
    for (const name of [...toMac.keys()].filter((n) => !phone.includes(n))) {
      await fs.rm(path.join(routes, name), { force: true });
      toMac.delete(name);
    }
  }

  const evaluate = async (expression) => {
    const targets = await (await fetch(`http://127.0.0.1:${devtools}/json`)).json();
    const target = targets.find((t) => t.type === "page") ?? targets[0];
    const socket = new WebSocket(target.webSocketDebuggerUrl);
    await new Promise((resolve, reject) => {
      socket.onopen = resolve;
      socket.onerror = reject;
    });
    const answer = new Promise((resolve) => {
      socket.onmessage = (event) => {
        const message = JSON.parse(event.data);
        if (message.id === 1) resolve(message.result);
      };
    });
    socket.send(JSON.stringify({ id: 1, method: "Runtime.evaluate",
      params: { expression, awaitPromise: true, returnByValue: true } }));
    const result = await answer;
    socket.close();
    if (result.exceptionDetails) throw Error(JSON.stringify(result.exceptionDetails));
    return result.result.value;
  };

  return {
    async install({ homePhone, routes, page, work }) {
      this.config = page;
      adb("shell", "am", "force-stop", PACKAGE);
      runAs(`rm -rf files/fhome files/froutes && mkdir -p files/fhome/keys files/froutes`);
      for (const name of await fs.readdir(homePhone)) {
        if (name.startsWith("friends.sqlite")) await push(path.join(homePhone, name), `files/fhome/${name}`);
      }
      await push(path.join(homePhone, "keys", "identity"), "files/fhome/keys/identity");
      runAs(`chmod 700 files/fhome files/fhome/keys files/froutes && chmod 600 files/fhome/keys/identity`);
      const environment = `SZFRIENDS_STATE_DIR=${FILES}/fhome\\nSZFRIENDS_TEST_LOOPBACK=${FILES}/froutes\\n`;
      runAs(`printf "${environment}" > files/friends-test.env`);
      bridging = true;
      (async () => {
        while (bridging) {
          await mirror(routes, work).catch((error) => console.error(`bridge: ${error.message}`));
          await wait(500);
        }
      })();
      adb("shell", "am", "start", "-n", `${PACKAGE}/.MainActivity`);
      let pid = "";
      for (let i = 0; i < 120 && !pid; i++) {
        await wait(500);
        const candidate = adb("shell", "pidof", PACKAGE).trim();
        if (candidate && adb("shell", "cat", "/proc/net/unix").includes(`webview_devtools_remote_${candidate}`))
          pid = candidate;
      }
      if (!pid) throw Error("the app's WebView did not start");
      devtools = 9000 + (Number(serial.replace(/\D/g, "")) % 1000);
      adb("forward", `tcp:${devtools}`, `localabstract:webview_devtools_remote_${pid}`);
      for (let i = 0; i < 120; i++) {
        const ready = await evaluate("document.readyState === 'complete' && !!window.shenzhenFriends").catch(() => 0);
        if (ready) break;
        await wait(500);
      }
      const status = await evaluate("window.shenzhenFriends.join()");
      if (!status.available) throw Error("Friends is not available in the app");
    },
    async route() {
      for (let i = 0; i < 240 && !toMac.size; i++) await wait(250);
      if (!toMac.size) throw Error("the phone wrote no route");
    },
    async run() {
      const script = await fs.readFile(new URL("./phones-exchange-page.js", import.meta.url), "utf8");
      const config = this.config;
      return evaluate(`window.__SZF_PHONE__ = ${JSON.stringify(config)};\n${script}`);
    },
    async received(name) {
      return adbBytes("exec-out", "run-as", PACKAGE, "cat", `files/fhome/received/${name}`).toString("utf8");
    },
    async screenshot(file) {
      await fs.mkdir(path.dirname(file), { recursive: true });
      await fs.writeFile(file, adbBytes("exec-out", "screencap", "-p"));
    },
    async cleanup() {
      bridging = false;
      await wait(600);
      try {
        for (const port of new Set(toMac.values())) adb("forward", "--remove", `tcp:${port}`);
        adb("forward", "--remove", `tcp:${devtools}`);
        adb("reverse", "--remove-all");
        runAs("rm -f files/friends-test.env");
      } catch {
        // The emulator went away first.
      }
    },
  };
}
