const { test } = require("node:test");
const assert = require("node:assert/strict");
const { EventEmitter } = require("node:events");
const fs = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");
const { createUpdateManager } = require("./update-manager.cjs");
const {
  PublicReleaseProvider,
  PrivateReleaseProvider,
} = require("./github-update-provider.cjs");
const { releaseAccessFor } = require("./release-channel.cjs");

const TEST_TOKEN = "unit-test-credential-not-a-real-github-token";
const until = async (condition) => {
  for (let i = 0; i < 2000; i++) {
    if (condition()) return;
    await new Promise((resolve) => setImmediate(resolve));
  }
  assert.fail("Mock operation did not settle");
};
async function fixture(t, changes = {}) {
  const directory = await fs.mkdtemp(
    path.join(os.tmpdir(), "shenzhen-updater-test-"),
  );
  const calls = {
    creates: 0,
    checks: 0,
    downloads: 0,
    installs: [],
    auth: [],
    dialogs: [],
    encrypted: 0,
    decrypted: 0,
  };
  const states = [];
  let executable = path.join(
    directory,
    "Shenzhen 3D.app/Contents/MacOS/Shenzhen 3D",
  );
  const updater = new EventEmitter();
  updater.setFeedURL = (feed) => {
    updater.feed = feed;
  };
  updater.checkForUpdates = async () => {
    calls.checks++;
    updater.emit("checking-for-update");
    updater.emit("update-available", { version: "0.1.5" });
    return { updateInfo: { version: "0.1.5" } };
  };
  updater.downloadUpdate = async () => {
    calls.downloads++;
    updater.emit("download-progress", { percent: 42.5 });
    updater.emit("update-downloaded", { version: "0.1.5" });
    return ["mock.zip"];
  };
  updater.quitAndInstall = (...args) => calls.installs.push(args);
  const storage = {
    isEncryptionAvailable: () => true,
    getSelectedStorageBackend: () => "keychain",
    encryptString: (token) => {
      calls.encrypted++;
      return Buffer.from([...token].reverse().join(""));
    },
    decryptString: (bytes) => {
      calls.decrypted++;
      return [...bytes.toString()].reverse().join("");
    },
  };
  const app = {
    isPackaged: true,
    getVersion: () => "0.1.4",
    getPath: (name) => (name === "exe" ? executable : directory),
  };
  const options = {
    app,
    safeStorage: storage,
    platform: "darwin",
    releaseOwner: "fixture-primary",
    // Most cases exercise a build whose releases are private.
    releaseAccess: "private",
    readPackagedFeed: async () => ({
      provider: "github",
      owner: changes.releaseOwner ?? "fixture-primary",
      repo: "shenzhen-3D",
      private: (changes.releaseAccess ?? "private") === "private",
      channel: "latest",
    }),
    onState: (state) => states.push(state),
    dialog: {
      showMessageBox: async (options) => {
        calls.dialogs.push(options);
        return { response: 0 };
      },
    },
    createUpdater: () => {
      calls.creates++;
      return updater;
    },
    fetch: async (url, options) => {
      calls.auth.push({ url, options });
      return { status: 200, body: { cancel: async () => {} } };
    },
    ...changes,
  };
  if (changes.initialSettings)
    await fs.writeFile(
      path.join(directory, "updates.json"),
      JSON.stringify(changes.initialSettings),
    );
  const manager = createUpdateManager(options);
  t.after(async () => {
    manager.dispose();
    await fs.rm(directory, { recursive: true, force: true });
  });
  return {
    manager,
    updater,
    calls,
    states,
    directory,
    options,
    storage,
    setExecutable: (value) => {
      executable = value;
    },
  };
}

test("unsupported installs do not initialize or authenticate the updater", async (t) => {
  for (const changes of [
    { platform: "linux" },
    {
      app: {
        isPackaged: false,
        getVersion: () => "0.1.4",
        getPath: () => os.tmpdir(),
      },
    },
  ]) {
    const f = await fixture(t, changes);
    await f.manager.check();
    await f.manager.connect(TEST_TOKEN);
    await f.manager.useGitHubCLI();
    assert.equal(f.manager.getState().supported, false);
    assert.equal(f.calls.creates, 0);
    assert.equal(f.calls.auth.length, 0);
    assert.match(f.manager.getState().message, /installed Mac app/);
  }
});

test("missing authentication never falls back to a public GitHub feed", async (t) => {
  const f = await fixture(t);
  assert.equal((await f.manager.check()).status, "needs-auth");
  assert.equal(f.calls.creates, 0);
  assert.equal(f.manager.getState().connected, false);
});

test("verified private access is encrypted, atomically persisted and restored", async (t) => {
  const f = await fixture(t, { releaseOwner: "fixture-secondary" });
  await f.manager.configure({
    automatic: false,
    repository: "fixture-secondary",
  });
  const state = await f.manager.connect(TEST_TOKEN);
  assert.equal(state.connected, true);
  assert.equal(state.automatic, false);
  assert.equal(state.prereleases, true);
  assert.equal(
    f.calls.auth[0].url,
    "https://api.github.com/repos/fixture-secondary/shenzhen-3D/releases?per_page=1",
  );
  assert.equal(f.calls.auth[0].options.redirect, "error");
  assert.equal(
    f.calls.auth[0].options.headers.Authorization,
    `Bearer ${TEST_TOKEN}`,
  );
  const filename = path.join(f.directory, "updates.json");
  const contents = await fs.readFile(filename, "utf8");
  assert.equal(contents.includes(TEST_TOKEN), false);
  assert.equal((await fs.stat(filename)).mode & 0o777, 0o600);
  assert.equal(f.calls.encrypted, 1);
  assert.deepEqual(
    (await fs.readdir(f.directory)).filter((name) => name.endsWith(".tmp")),
    [],
  );
  const restored = createUpdateManager(f.options);
  t.after(() => restored.dispose());
  await restored.configure({});
  assert.equal(restored.getState().connected, true);
  assert.equal(restored.getState().repository, "fixture-secondary");
  assert.equal(JSON.stringify(f.states).includes(TEST_TOKEN), false);
});

test("bad access and insecure storage never persist a credential", async (t) => {
  const denied = await fixture(t, { fetch: async () => ({ status: 403 }) });
  assert.equal((await denied.manager.connect(TEST_TOKEN)).status, "needs-auth");
  await assert.rejects(
    fs.readFile(path.join(denied.directory, "updates.json")),
    { code: "ENOENT" },
  );
  const insecure = await fixture(t, {
    safeStorage: {
      isEncryptionAvailable: () => true,
      getSelectedStorageBackend: () => "basic_text",
    },
  });
  assert.equal((await insecure.manager.connect(TEST_TOKEN)).status, "error");
  assert.equal(insecure.calls.auth.length, 0);
  await assert.rejects(
    fs.readFile(path.join(insecure.directory, "updates.json")),
    { code: "ENOENT" },
  );
});

test("private MacUpdater settings preserve signature checks and require explicit installation", async (t) => {
  const f = await fixture(t);
  await f.manager.connect(TEST_TOKEN);
  await f.manager.check();
  assert.equal(f.calls.creates, 1);
  assert.deepEqual(f.updater.feed, {
    provider: "custom",
    updateProvider: PrivateReleaseProvider,
    owner: "fixture-primary",
    repo: "shenzhen-3D",
    private: true,
    token: TEST_TOKEN,
  });
  assert.equal(f.updater.logger, null);
  assert.equal(f.updater.allowDowngrade, false);
  assert.equal(f.updater.allowPrerelease, true);
  assert.equal(f.updater.autoDownload, false);
  assert.equal(f.updater.autoInstallOnAppQuit, false);
  assert.equal(Object.hasOwn(f.updater, "verifyUpdateCodeSignature"), false);
  assert.equal(f.calls.downloads, 0);
  await f.manager.download();
  assert.equal(f.manager.getState().status, "ready");
  assert.equal(f.manager.getState().progress, 100);
  assert.ok(f.states.some((state) => state.progress === 42.5));
  assert.equal(f.calls.installs.length, 0);
  await f.manager.install();
  assert.match(f.calls.dialogs[0].detail, /Save or export.*projects/);
  assert.equal(f.calls.dialogs[0].defaultId, 1);
  assert.deepEqual(f.calls.installs, [[false, true]]);
});

test("older or malformed versions are never offered or installed", async (t) => {
  for (const version of ["0.1.3", "0.1.4", "invalid"]) {
    const f = await fixture(t);
    f.updater.checkForUpdates = async () => {
      f.updater.emit("update-available", { version });
      return { updateInfo: { version } };
    };
    await f.manager.connect(TEST_TOKEN);
    await f.manager.check();
    await f.manager.download();
    await f.manager.install();
    assert.equal(f.manager.getState().status, "idle");
    assert.equal(f.calls.downloads, 0);
    assert.equal(f.calls.installs.length, 0);
  }
});

test("concurrent downloads and settings changes cannot mutate a pending update", async (t) => {
  const f = await fixture(t);
  let finish;
  f.updater.downloadUpdate = async (cancellation) => {
    f.calls.downloads++;
    assert.equal(typeof cancellation.cancel, "function");
    await new Promise((resolve) => {
      finish = resolve;
    });
    f.updater.emit("update-downloaded", { version: "0.1.5" });
  };
  await f.manager.connect(TEST_TOKEN);
  await f.manager.check();
  const pending = f.manager.download();
  await until(() => f.calls.downloads === 1);
  await f.manager.download();
  await f.manager.check();
  assert.equal(f.calls.downloads, 1);
  assert.equal(f.calls.checks, 1);
  await assert.rejects(
    f.manager.configure({ repository: "fixture-secondary" }),
    /pending update/,
  );
  await assert.rejects(f.manager.connect("replacement"), /pending update/);
  await assert.rejects(f.manager.disconnect(), /pending update/);
  f.updater.emit("download-progress", { percent: 150 });
  assert.equal(f.manager.getState().progress, 100);
  finish();
  await pending;
  await assert.rejects(
    f.manager.configure({ automatic: false }),
    /pending update/,
  );
});

test("disk-image and translocated installs are refused before any native prompt", async (t) => {
  for (const executable of [
    "/Volumes/Installer/Shenzhen 3D.app/Contents/MacOS/App",
    "/private/var/AppTranslocation/test/d/Shenzhen 3D.app/Contents/MacOS/App",
  ]) {
    const f = await fixture(t);
    f.setExecutable(executable);
    await f.manager.connect(TEST_TOKEN);
    await f.manager.check();
    await f.manager.download();
    await f.manager.install();
    assert.match(
      f.manager.getState().message,
      /Move Shenzhen 3D to Applications/,
    );
    assert.equal(f.calls.dialogs.length, 0);
    assert.equal(f.calls.installs.length, 0);
  }
});

test("Later leaves the downloaded update ready without quitting", async (t) => {
  const f = await fixture(t, {
    dialog: { showMessageBox: async () => ({ response: 1 }) },
  });
  await f.manager.connect(TEST_TOKEN);
  await f.manager.check();
  await f.manager.download();
  await f.manager.install();
  assert.equal(f.manager.getState().status, "ready");
  assert.equal(f.calls.installs.length, 0);
});

test("errors never expose tokens or raw updater diagnostics, and disconnect clears saved access", async (t) => {
  const f = await fixture(t);
  await f.manager.connect(TEST_TOKEN);
  f.updater.checkForUpdates = async () => {
    throw Error(`Authorization: Bearer ${TEST_TOKEN}`);
  };
  await f.manager.check();
  assert.equal(f.manager.getState().status, "error");
  assert.equal(JSON.stringify(f.states).includes(TEST_TOKEN), false);
  await f.manager.disconnect();
  assert.equal(f.manager.getState().connected, false);
  assert.equal(
    JSON.parse(
      await fs.readFile(path.join(f.directory, "updates.json"), "utf8"),
    ).encryptedToken,
    undefined,
  );
  await assert.rejects(
    f.manager.configure({ repository: "untrusted-owner" }),
    /fixed to this build/,
  );
});

test("expired authentication is cleared without returning its error details", async (t) => {
  const f = await fixture(t);
  await f.manager.connect(TEST_TOKEN);
  f.updater.checkForUpdates = async () => {
    const error = Error(TEST_TOKEN);
    error.statusCode = 401;
    throw error;
  };
  await f.manager.check();
  assert.equal(f.manager.getState().status, "needs-auth");
  assert.equal(f.manager.getState().connected, false);
  assert.equal(JSON.stringify(f.states).includes(TEST_TOKEN), false);
});

test("wrapped private-provider authentication failures also clear saved access", async (t) => {
  const f = await fixture(t);
  await f.manager.connect(TEST_TOKEN);
  f.updater.checkForUpdates = async () => {
    throw Error(
      `Unable to find latest version: 401 Unauthorized ${TEST_TOKEN}`,
    );
  };
  await f.manager.check();
  assert.equal(f.manager.getState().status, "needs-auth");
  assert.equal(f.manager.getState().connected, false);
  assert.equal(JSON.stringify(f.states).includes(TEST_TOKEN), false);
});

test("GitHub CLI is explicit, uses fixed absolute paths and never invokes a shell", async (t) => {
  const commands = [];
  const f = await fixture(t, {
    execFile: (file, args, options, done) => {
      commands.push({ file, args, options });
      if (commands.length === 1) {
        const error = Error("missing");
        error.code = "ENOENT";
        done(error);
      } else done(null, `${TEST_TOKEN}\n`);
    },
  });
  assert.equal(commands.length, 0);
  await f.manager.useGitHubCLI();
  assert.equal(f.manager.getState().connected, true);
  assert.deepEqual(
    commands.map((command) => command.file),
    ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"],
  );
  assert.deepEqual(commands[1].args, [
    "auth",
    "token",
    "--hostname",
    "github.com",
  ]);
  assert.equal(commands[1].options.shell, false);
});

test("installation stays guarded until a native error and never claims early signature verification", async (t) => {
  const f = await fixture(t);
  await f.manager.connect(TEST_TOKEN);
  await f.manager.check();
  await f.manager.download();
  await f.manager.install();
  assert.equal(f.manager.getState().status, "installing");
  assert.equal(f.manager.getState().message.includes("verified"), false);
  await f.manager.install();
  assert.equal(f.calls.installs.length, 1);
  assert.equal(f.calls.dialogs.length, 1);
  await assert.rejects(
    f.manager.configure({ automatic: false }),
    /pending update/,
  );
  f.updater.emit(
    "error",
    Error(`Native signature verification failed: ${TEST_TOKEN}`),
  );
  assert.equal(f.manager.getState().status, "error");
  assert.equal(JSON.stringify(f.states).includes(TEST_TOKEN), false);
  await f.manager.configure({ automatic: false });
  assert.equal(f.manager.getState().automatic, false);
});

test("disposing cancels authentication and cannot persist a late credential", async (t) => {
  let signal;
  const f = await fixture(t, {
    fetch: async (_url, options) => {
      signal = options.signal;
      return new Promise((_resolve, reject) =>
        signal.addEventListener("abort", () => reject(Error(TEST_TOKEN)), {
          once: true,
        }),
      );
    },
  });
  const pending = f.manager.connect(TEST_TOKEN);
  await until(() => !!signal);
  f.manager.dispose();
  await pending;
  assert.equal(signal.aborted, true);
  await assert.rejects(fs.readFile(path.join(f.directory, "updates.json")), {
    code: "ENOENT",
  });
  assert.equal(JSON.stringify(f.states).includes(TEST_TOKEN), false);
});

test("automatic checks wait twenty seconds, throttle daily and do not download", async (t) => {
  const f = await fixture(t);
  await f.manager.connect(TEST_TOKEN);
  t.mock.timers.enable({ apis: ["setTimeout", "Date"], now: 1_000_000_000 });
  f.manager.schedule();
  f.manager.schedule();
  t.mock.timers.tick(19_999);
  assert.equal(f.calls.checks, 0);
  t.mock.timers.tick(1);
  await until(() => f.calls.checks === 1);
  await until(() => f.manager.getState().status === "available");
  await new Promise((resolve) => setImmediate(resolve));
  t.mock.timers.tick(86_400_000 - 1);
  assert.equal(f.calls.checks, 1);
  t.mock.timers.tick(1);
  await until(() => f.calls.checks === 2);
  assert.equal(f.calls.downloads, 0);
  assert.equal(f.calls.dialogs.length, 0);
});

test("manual checks bypass the daily throttle and automatic failures remain silent", async (t) => {
  const f = await fixture(t);
  await f.manager.connect(TEST_TOKEN);
  await f.manager.check();
  await f.manager.check();
  assert.equal(f.calls.checks, 2);
  await f.manager.configure({ automatic: false });
  t.mock.timers.enable({
    apis: ["setTimeout", "Date"],
    now: Date.now() + 86_400_000,
  });
  f.manager.schedule();
  t.mock.timers.tick(20_000);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(f.calls.checks, 2);
  assert.equal(f.calls.dialogs.length, 0);
});

test("automatic network failures do not surface an error dialog or raw diagnostics", async (t) => {
  const f = await fixture(t);
  await f.manager.connect(TEST_TOKEN);
  f.updater.checkForUpdates = async () => {
    f.calls.checks++;
    throw Error(`Network request failed with Authorization ${TEST_TOKEN}`);
  };
  t.mock.timers.enable({ apis: ["setTimeout", "Date"], now: Date.now() });
  f.manager.schedule();
  t.mock.timers.tick(20_000);
  await until(() => f.calls.checks === 1);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(f.manager.getState().status, "idle");
  assert.equal(f.calls.dialogs.length, 0);
  assert.equal(JSON.stringify(f.states).includes(TEST_TOKEN), false);
});

for (const releaseOwner of ["fixture-primary", "fixture-secondary"]) {
  test(`${releaseOwner} is fixed for fresh settings, authentication and update feed`, async (t) => {
    const f = await fixture(t, { releaseOwner });
    await f.manager.configure({ automatic: false, repository: releaseOwner });
    assert.equal(f.manager.getState().repository, releaseOwner);
    await assert.rejects(
      f.manager.configure({
        repository:
          releaseOwner === "fixture-secondary"
            ? "fixture-primary"
            : "fixture-secondary",
      }),
      /fixed to this build/,
    );
    await f.manager.connect(TEST_TOKEN);
    await f.manager.check();
    assert.equal(f.updater.feed.owner, releaseOwner);
    assert.ok(
      f.calls.auth.every(({ url }) =>
        url.startsWith(
          `https://api.github.com/repos/${releaseOwner}/shenzhen-3D/`,
        ),
      ),
    );
    const saved = JSON.parse(
      await fs.readFile(path.join(f.directory, "updates.json")),
    );
    assert.equal(saved.repository, releaseOwner);
    assert.equal(saved.automatic, false);
  });
  test(`${releaseOwner} preserves same-source preferences and encrypted access`, async (t) => {
    const initialSettings = {
      repository: releaseOwner,
      automatic: false,
      prereleases: false,
      lastChecked: 1234,
      encryptedToken: Buffer.from([...TEST_TOKEN].reverse().join("")).toString(
        "base64",
      ),
    };
    const f = await fixture(t, { releaseOwner, initialSettings });
    await f.manager.configure({});
    assert.equal(f.calls.decrypted, 1);
    assert.equal(f.manager.getState().connected, true);
    assert.equal(f.manager.getState().lastChecked, 1234);
    assert.equal(f.manager.getState().prereleases, false);
    assert.equal(f.manager.getState().automatic, false);
    assert.deepEqual(
      JSON.parse(await fs.readFile(path.join(f.directory, "updates.json"))),
      initialSettings,
    );
  });
  test(`${releaseOwner} drops other-source credentials without decrypting them`, async (t) => {
    const initialSettings = {
      repository:
        releaseOwner === "fixture-secondary"
          ? "fixture-primary"
          : "fixture-secondary",
      automatic: false,
      prereleases: false,
      lastChecked: 1234,
      encryptedToken: "other-source-ciphertext",
    };
    const f = await fixture(t, { releaseOwner, initialSettings });
    await f.manager.configure({});
    assert.equal(f.calls.decrypted, 0);
    assert.equal(f.calls.auth.length, 0);
    assert.equal(f.calls.creates, 0);
    assert.equal(f.manager.getState().connected, false);
    assert.equal(f.manager.getState().lastChecked, undefined);
    assert.deepEqual(
      JSON.parse(await fs.readFile(path.join(f.directory, "updates.json"))),
      { repository: releaseOwner, automatic: false, prereleases: false },
    );
  });
}
test("wrong signed feed disables updating before credentials or networking", async (t) => {
  for (const releaseOwner of ["fixture-primary", "fixture-secondary"]) {
    const f = await fixture(t, {
      releaseOwner,
      readPackagedFeed: async () => ({
        provider: "github",
        owner:
          releaseOwner === "fixture-secondary"
            ? "fixture-primary"
            : "fixture-secondary",
        repo: "shenzhen-3D",
        private: true,
        channel: "latest",
      }),
      initialSettings: {
        repository: releaseOwner,
        encryptedToken: "must-not-decrypt",
      },
    });
    await f.manager.check();
    await f.manager.connect(TEST_TOKEN);
    await f.manager.useGitHubCLI();
    assert.equal(f.manager.getState().supported, false);
    assert.match(f.manager.getState().message, /does not match this build/);
    assert.equal(f.calls.decrypted, 0);
    assert.equal(f.calls.auth.length, 0);
    assert.equal(f.calls.creates, 0);
  }
});
test("missing authoritative build owner cannot initialize an updater", async (t) => {
  const f = await fixture(t, { releaseOwner: null });
  await f.manager.connect(TEST_TOKEN);
  await f.manager.check();
  assert.equal(f.manager.getState().supported, false);
  assert.match(f.manager.getState().message, /not configured/);
  assert.equal(f.calls.auth.length, 0);
  assert.equal(f.calls.creates, 0);
});

const PUBLIC_BUILD = {
  releaseOwner: "casimir-engineering",
  releaseAccess: "public",
};
test("public build checks and downloads without GitHub access or credentials", async (t) => {
  const commands = [];
  const f = await fixture(t, {
    ...PUBLIC_BUILD,
    execFile: (...args) => commands.push(args),
  });
  assert.equal(f.manager.getState().access, "public");
  assert.equal(f.manager.getState().message, "");
  const checked = await f.manager.check();
  assert.equal(checked.status, "available");
  assert.equal(checked.connected, false);
  assert.deepEqual(f.updater.feed, {
    provider: "custom",
    updateProvider: PublicReleaseProvider,
    owner: "casimir-engineering",
    repo: "shenzhen-3D",
  });
  await f.manager.download();
  assert.equal(f.manager.getState().status, "ready");
  await f.manager.install();
  assert.deepEqual(f.calls.installs, [[false, true]]);
  assert.equal(f.calls.auth.length, 0);
  assert.equal(commands.length, 0);
  assert.equal(f.calls.encrypted, 0);
});
test("public build has no GitHub access step", async (t) => {
  const commands = [];
  const f = await fixture(t, {
    ...PUBLIC_BUILD,
    execFile: (...args) => commands.push(args),
  });
  await f.manager.connect(TEST_TOKEN);
  await f.manager.useGitHubCLI();
  await f.manager.disconnect();
  assert.equal(f.manager.getState().connected, false);
  assert.equal(f.manager.getState().status, "idle");
  assert.equal(f.calls.auth.length, 0);
  assert.equal(f.calls.encrypted, 0);
  assert.equal(commands.length, 0);
  await f.manager.configure({ automatic: false });
  assert.equal(f.manager.getState().status, "idle");
  const saved = JSON.parse(
    await fs.readFile(path.join(f.directory, "updates.json"), "utf8"),
  );
  assert.equal("encryptedToken" in saved, false);
});
test("public build drops GitHub access saved by an earlier private build without decrypting it", async (t) => {
  const f = await fixture(t, {
    ...PUBLIC_BUILD,
    initialSettings: {
      repository: "casimir-engineering",
      automatic: false,
      prereleases: true,
      lastChecked: 1234,
      encryptedToken: "earlier-private-build-ciphertext",
    },
  });
  await f.manager.configure({});
  assert.equal(f.calls.decrypted, 0);
  assert.equal(f.manager.getState().connected, false);
  assert.equal(f.manager.getState().automatic, false);
  assert.equal(f.manager.getState().lastChecked, 1234);
  assert.deepEqual(
    JSON.parse(await fs.readFile(path.join(f.directory, "updates.json"))),
    {
      repository: "casimir-engineering",
      automatic: false,
      prereleases: true,
      lastChecked: 1234,
    },
  );
  await f.manager.check();
  assert.equal(f.updater.feed.token, undefined);
});
// UPDATES.md, "Moving a private channel to the public one": a private owner's release carries the public build,
// which then starts with the private build's profile.
test("public build installed over another owner's private build moves to its own public channel", async (t) => {
  const f = await fixture(t, {
    ...PUBLIC_BUILD,
    initialSettings: {
      repository: "fixture-private",
      automatic: true,
      prereleases: true,
      lastChecked: 1234,
      encryptedToken: "private-owner-ciphertext",
    },
  });
  const state = f.manager.getState();
  await f.manager.configure({});
  assert.equal(f.calls.decrypted, 0);
  assert.equal(state.access, "public");
  assert.equal(f.manager.getState().repository, "casimir-engineering");
  assert.equal(f.manager.getState().connected, false);
  assert.equal(f.manager.getState().status, "idle");
  // The other channel's last check does not delay this one's first check.
  assert.equal(f.manager.getState().lastChecked, undefined);
  assert.deepEqual(
    JSON.parse(await fs.readFile(path.join(f.directory, "updates.json"))),
    { repository: "casimir-engineering", automatic: true, prereleases: true },
  );
  await assert.rejects(
    f.manager.configure({ repository: "fixture-private" }),
    /fixed to this build/,
  );
  await f.manager.check();
  assert.equal(f.calls.auth.length, 0);
  assert.equal(f.updater.feed.updateProvider, PublicReleaseProvider);
  assert.equal(f.updater.feed.owner, "casimir-engineering");
  assert.equal(f.updater.feed.token, undefined);
  assert.equal(f.manager.getState().availableVersion, "0.1.5");
});
test("public build reports rate limits and denials as ordinary failures", async (t) => {
  for (const statusCode of [401, 403]) {
    const f = await fixture(t, PUBLIC_BUILD);
    f.updater.checkForUpdates = async () => {
      const error = Error(`${statusCode} Forbidden`);
      error.statusCode = statusCode;
      throw error;
    };
    await f.manager.check();
    assert.equal(f.manager.getState().status, "error");
    assert.doesNotMatch(f.manager.getState().message, /GitHub|Connect/);
  }
});
test("public build refuses a private feed and a private build refuses a public one", async (t) => {
  for (const [releaseAccess, feedPrivate] of [
    ["public", true],
    ["private", false],
  ]) {
    const f = await fixture(t, {
      releaseOwner: "casimir-engineering",
      releaseAccess,
      readPackagedFeed: async () => ({
        provider: "github",
        owner: "casimir-engineering",
        repo: "shenzhen-3D",
        private: feedPrivate,
        channel: "latest",
      }),
    });
    await f.manager.check();
    assert.equal(f.manager.getState().supported, false);
    assert.equal(f.calls.creates, 0);
  }
});
test("private-owner build still requires and sends the connected credential", async (t) => {
  const f = await fixture(t, {
    releaseOwner: "fixture-private",
    releaseAccess: "private",
  });
  assert.equal(f.manager.getState().access, "private");
  assert.equal((await f.manager.check()).status, "needs-auth");
  assert.equal(f.calls.creates, 0);
  await f.manager.connect(TEST_TOKEN);
  assert.equal(
    f.calls.auth[0].options.headers.Authorization,
    `Bearer ${TEST_TOKEN}`,
  );
  await f.manager.check();
  assert.equal(f.updater.feed.updateProvider, PrivateReleaseProvider);
  assert.equal(f.updater.feed.token, TEST_TOKEN);
  assert.equal(f.updater.feed.private, true);
});
test("access defaults to this source's setting for the build owner", async (t) => {
  for (const releaseOwner of ["casimir-engineering", "fixture-private"]) {
    const f = await fixture(t, { releaseOwner, releaseAccess: undefined });
    assert.equal(f.manager.getState().access, releaseAccessFor(releaseOwner));
  }
});
