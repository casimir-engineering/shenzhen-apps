const fs = require("node:fs/promises");
const path = require("node:path");
const { randomUUID } = require("node:crypto");
const { execFile: defaultExecFile } = require("node:child_process");
const {
  isReleaseOwner,
  releaseAccessFor,
  validatePackagedFeed,
} = require("./release-channel.cjs");

const DAY = 24 * 60 * 60 * 1000;
const CLI_PATHS = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"];

/** Main-process only. Public state never contains credentials or updater errors. */
function createUpdateManager({
  app,
  safeStorage,
  dialog,
  execFile = defaultExecFile,
  createUpdater = () => new (require("electron-updater").MacUpdater)(),
  onState = () => {},
  platform = process.platform,
  fetch = globalThis.fetch,
  releaseOwner = null,
  // "public" builds read releases without credentials; "private" builds need
  // GitHub access connected in the app. Defaults to this source's setting.
  releaseAccess = isReleaseOwner(releaseOwner)
    ? releaseAccessFor(releaseOwner)
    : "private",
  readPackagedFeed = async () =>
    require("js-yaml").load(
      await fs.readFile(
        path.join(process.resourcesPath, "app-update.yml"),
        "utf8",
      ),
    ),
}) {
  const sourceConfigured =
    isReleaseOwner(releaseOwner) &&
    (releaseAccess === "public" || releaseAccess === "private");
  const publicReleases = releaseAccess === "public";
  let supported = platform === "darwin" && !!app.isPackaged && sourceConfigured;
  const settingsFile = path.join(app.getPath("userData"), "updates.json");
  const state = {
    supported,
    version: app.getVersion(),
    status: "idle",
    automatic: true,
    repository: sourceConfigured ? releaseOwner : "",
    access: publicReleases ? "public" : "private",
    prereleases: true,
    connected: false,
    message: !sourceConfigured
      ? "Update source is not configured in this build."
      : !supported
        ? "Updates are available in the installed Mac app."
        : publicReleases
          ? ""
          : "Connect GitHub to check private releases.",
  };
  let token,
    encryptedToken,
    updater,
    operation,
    timer,
    downloadCancellation,
    authAbort;
  let disposed = false,
    scheduled = false,
    automaticCheck = false;
  const listeners = [];
  const getState = () => ({ ...state });
  const publish = (changes) => {
    if (disposed) return;
    Object.assign(state, changes);
    try {
      onState(getState());
    } catch {
      /* A UI observer cannot break installation state. */
    }
  };
  const clearAvailable = () => ({
    availableVersion: undefined,
    progress: undefined,
  });
  const secureStorage = () =>
    safeStorage.isEncryptionAvailable() &&
    safeStorage.getSelectedStorageBackend?.() !== "basic_text";
  const persist = async () => {
    const data = {
      automatic: state.automatic,
      repository: state.repository,
      prereleases: state.prereleases,
      lastChecked: state.lastChecked,
      encryptedToken,
    };
    await fs.mkdir(path.dirname(settingsFile), { recursive: true });
    const temporary = `${settingsFile}.${process.pid}.${randomUUID()}.tmp`;
    try {
      const file = await fs.open(temporary, "wx", 0o600);
      try {
        await file.writeFile(JSON.stringify(data));
        await file.sync();
      } finally {
        await file.close();
      }
      await fs.rename(temporary, settingsFile);
    } finally {
      await fs.rm(temporary, { force: true }).catch(() => {});
    }
  };
  const initialized = (async () => {
    if (supported) {
      try {
        validatePackagedFeed(
          await readPackagedFeed(),
          releaseOwner,
          releaseAccess,
        );
      } catch {
        supported = false;
        publish({
          supported: false,
          status: "error",
          message:
            "Update source does not match this build. Reinstall from the original repository.",
        });
        return;
      }
    }
    try {
      const data = JSON.parse(await fs.readFile(settingsFile, "utf8"));
      if (disposed) return;
      if (typeof data.automatic === "boolean") state.automatic = data.automatic;
      const sameChannel = data.repository === releaseOwner;
      if (typeof data.prereleases === "boolean")
        state.prereleases = data.prereleases;
      if (
        sameChannel &&
        Number.isFinite(data.lastChecked) &&
        data.lastChecked >= 0
      )
        state.lastChecked = data.lastChecked;
      // Public builds never read saved GitHub access; drop any left by an
      // earlier private build of the same source without decrypting it.
      if (!sameChannel || (publicReleases && "encryptedToken" in data))
        await persist();
      if (
        sameChannel &&
        supported &&
        !publicReleases &&
        typeof data.encryptedToken === "string"
      ) {
        if (!secureStorage()) throw Error("secure storage unavailable");
        const decoded = safeStorage.decryptString(
          Buffer.from(data.encryptedToken, "base64"),
        );
        if (
          typeof decoded !== "string" ||
          !decoded.trim() ||
          /[\r\n\0]/.test(decoded)
        )
          throw Error("invalid credential");
        token = decoded;
        encryptedToken = data.encryptedToken;
        state.connected = true;
        state.message = "GitHub connected. Check for updates when ready.";
      }
      publish({});
    } catch (error) {
      if (error.code !== "ENOENT")
        publish({
          connected: false,
          status: supported && !publicReleases ? "needs-auth" : "idle",
          message:
            supported && !publicReleases
              ? "Saved GitHub access could not be unlocked. Connect GitHub again."
              : state.message,
        });
    }
  })();
  const mutable = () => {
    if (disposed) throw Error("The updater is closed.");
    if (operation || state.status === "ready")
      throw Error(
        "Finish or restart the pending update before changing update settings.",
      );
  };
  const newer = (version) => {
    const semver = require("semver");
    return (
      typeof version === "string" &&
      !!semver.valid(version) &&
      !!semver.valid(state.version) &&
      semver.gt(version, state.version)
    );
  };
  const available = (info) => {
    if (!newer(info?.version)) {
      publish({
        status: "idle",
        ...clearAvailable(),
        message: "You are up to date.",
      });
      return false;
    }
    publish({
      status: "available",
      availableVersion: info.version,
      progress: undefined,
      message: `Version ${info.version} is available.`,
    });
    return true;
  };
  const failure = async (error) => {
    if (disposed) return;
    if (operation === "install") operation = undefined;
    const unauthorized =
      !publicReleases &&
      (error?.statusCode === 401 ||
        error?.statusCode === 403 ||
        /\b(?:401\s+Unauthorized|403\s+Forbidden)\b/i.test(
          error?.message || "",
        ));
    if (unauthorized) {
      token = encryptedToken = undefined;
      publish({
        status: "needs-auth",
        connected: false,
        ...clearAvailable(),
        message:
          "GitHub access expired or does not allow this private repository. Connect GitHub again.",
      });
      await persist().catch(() => {});
    } else
      publish({
        status: automaticCheck ? "idle" : "error",
        progress: undefined,
        message:
          "The update could not be completed. Check your connection and try again.",
      });
  };
  const engine = () => {
    if (!updater) {
      updater = createUpdater();
      // Never expose library diagnostics, which may contain authentication headers.
      updater.logger = null;
      updater.autoDownload = false;
      updater.autoInstallOnAppQuit = false;
      updater.allowDowngrade = false;
      const listen = (name, listener) => {
        updater.on(name, listener);
        listeners.push([name, listener]);
      };
      listen("checking-for-update", () =>
        publish({ status: "checking", message: "Checking for updates…" }),
      );
      listen("update-available", available);
      listen("update-not-available", () =>
        publish({
          status: "idle",
          ...clearAvailable(),
          message: "You are up to date.",
        }),
      );
      listen("download-progress", (progress) => {
        if (operation !== "download") return;
        const percent = Number(progress?.percent);
        publish({
          status: "downloading",
          progress: Number.isFinite(percent)
            ? Math.max(0, Math.min(100, percent))
            : 0,
          message: "Downloading update…",
        });
      });
      listen("update-downloaded", (info) => {
        if (operation === "install") return;
        if (!newer(info?.version) || info.version !== state.availableVersion) {
          publish({
            status: "error",
            ...clearAvailable(),
            message:
              "The downloaded update has an unexpected version and will not be installed.",
          });
          return;
        }
        publish({
          status: "ready",
          progress: 100,
          message: "Update ready. Save your projects before restarting.",
        });
      });
      listen("error", (error) => {
        void failure(error);
      });
    }
    updater.allowPrerelease = state.prereleases;
    // Keep MacUpdater's native code-signature verification enabled and untouched.
    const providers = require("./github-update-provider.cjs");
    updater.setFeedURL(
      publicReleases
        ? {
            provider: "custom",
            updateProvider: providers.PublicReleaseProvider,
            owner: state.repository,
            repo: "shenzhen-3D",
          }
        : {
            provider: "custom",
            updateProvider: providers.PrivateReleaseProvider,
            owner: state.repository,
            repo: "shenzhen-3D",
            private: true,
            token,
          },
    );
    return updater;
  };
  async function checkInternal(automatic = false) {
    await initialized;
    if (disposed || operation || !supported || state.status === "ready")
      return getState();
    operation = "check";
    automaticCheck = automatic;
    try {
      state.lastChecked = Date.now();
      await persist();
      if (disposed) return getState();
      if (!publicReleases && !token) {
        publish({
          status: "needs-auth",
          connected: false,
          message: "Connect GitHub to check private releases.",
        });
        return getState();
      }
      publish({
        status: "checking",
        ...clearAvailable(),
        message: "Checking for updates…",
      });
      const result = await engine().checkForUpdates();
      if (state.status === "checking") {
        if (result?.updateInfo) available(result.updateInfo);
        else publish({ status: "idle", message: "You are up to date." });
      }
    } catch (error) {
      await failure(error);
    } finally {
      operation = undefined;
      automaticCheck = false;
    }
    return getState();
  }
  async function connectToken(candidate) {
    if (disposed || !supported || publicReleases) return getState();
    if (!secureStorage()) {
      publish({
        status: "error",
        message:
          "Secure credential storage is unavailable. GitHub access was not saved.",
      });
      return getState();
    }
    if (
      typeof candidate !== "string" ||
      !candidate.trim() ||
      candidate.length > 4096 ||
      /[\r\n\0]/.test(candidate)
    ) {
      publish({
        status: token ? "error" : "needs-auth",
        message:
          "Enter a valid GitHub token with read access to this repository.",
      });
      return getState();
    }
    candidate = candidate.trim();
    publish({
      status: "checking",
      message: "Verifying GitHub repository access…",
    });
    try {
      authAbort = new AbortController();
      const response = await fetch(
        `https://api.github.com/repos/${state.repository}/shenzhen-3D/releases?per_page=1`,
        {
          headers: {
            Authorization: `Bearer ${candidate}`,
            Accept: "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": `Shenzhen3D/${state.version}`,
          },
          redirect: "error",
          signal: AbortSignal.any([
            authAbort.signal,
            AbortSignal.timeout(15_000),
          ]),
        },
      );
      await response.body?.cancel();
      if (disposed) return getState();
      if (response.status !== 200)
        throw Error("repository access not verified");
      const encrypted = safeStorage.encryptString(candidate).toString("base64");
      const oldToken = token,
        oldEncrypted = encryptedToken;
      token = candidate;
      encryptedToken = encrypted;
      try {
        await persist();
      } catch {
        token = oldToken;
        encryptedToken = oldEncrypted;
        throw Error("credential persistence failed");
      }
      publish({
        connected: true,
        status: "idle",
        ...clearAvailable(),
        message: "GitHub connected. Check for updates when ready.",
      });
    } catch {
      publish({
        connected: !!token,
        status: token ? "error" : "needs-auth",
        message:
          "GitHub access could not be verified or saved. Use a token that can read releases from the selected private repository.",
      });
    } finally {
      authAbort = undefined;
    }
    return getState();
  }
  const arm = (delay) => {
    clearTimeout(timer);
    if (disposed || !scheduled) return;
    timer = setTimeout(async () => {
      await initialized;
      if (
        !disposed &&
        state.automatic &&
        Date.now() - (state.lastChecked || 0) >= DAY
      )
        await checkInternal(true);
      arm(
        state.automatic
          ? Math.max(60_000, DAY - (Date.now() - (state.lastChecked || 0)))
          : DAY,
      );
    }, delay);
    timer.unref?.();
  };
  return {
    getState,
    check: () => checkInternal(false),
    async download() {
      await initialized;
      if (disposed || operation || !supported) return getState();
      if (!publicReleases && !token) {
        publish({
          status: "needs-auth",
          connected: false,
          message: "Connect GitHub before downloading updates.",
        });
        return getState();
      }
      if (
        !state.availableVersion ||
        !["available", "error"].includes(state.status)
      )
        return getState();
      operation = "download";
      try {
        downloadCancellation =
          new (require("builder-util-runtime").CancellationToken)();
        publish({
          status: "downloading",
          progress: 0,
          message: "Downloading update…",
        });
        await engine().downloadUpdate(downloadCancellation);
      } catch (error) {
        await failure(error);
      } finally {
        operation = undefined;
        downloadCancellation = undefined;
      }
      return getState();
    },
    async install() {
      await initialized;
      if (disposed || operation || !supported || state.status !== "ready")
        return getState();
      operation = "install";
      let handedOff = false;
      try {
        const executable = path.resolve(app.getPath("exe"));
        if (
          executable.startsWith("/Volumes/") ||
          executable.includes("/AppTranslocation/")
        ) {
          publish({
            message:
              "Move Shenzhen 3D to Applications and launch it there before installing updates.",
          });
          return getState();
        }
        const end = executable.lastIndexOf(".app/");
        if (end < 0) throw Error("not installed as a bundle");
        await fs.access(
          path.dirname(executable.slice(0, end + 4)),
          require("node:fs").constants.W_OK,
        );
        const decision = await dialog.showMessageBox({
          type: "warning",
          buttons: ["Install and restart", "Later"],
          defaultId: 1,
          cancelId: 1,
          title: "Restart to install update?",
          message: `Install Shenzhen 3D ${state.availableVersion} and restart?`,
          detail:
            "Save or export any open projects, notes and measurements first. Unsaved work will be lost when all app windows close.",
        });
        if (decision.response === 0) {
          publish({
            status: "installing",
            message: "Preparing update and restarting…",
          });
          updater.quitAndInstall(false, true);
          handedOff = true;
        }
      } catch {
        publish({
          status: "error",
          message:
            "The update could not be installed. Check that the app is in a writable folder and try again.",
        });
      } finally {
        if (!handedOff) operation = undefined;
      }
      return getState();
    },
    async configure(changes = {}) {
      await initialized;
      mutable();
      if (
        changes.repository !== undefined &&
        !isReleaseOwner(changes.repository)
      )
        throw Error("Invalid update repository.");
      if (
        changes.repository !== undefined &&
        changes.repository !== releaseOwner
      )
        throw Error("The update repository is fixed to this build.");
      if (
        changes.automatic !== undefined &&
        typeof changes.automatic !== "boolean"
      )
        throw Error("Automatic update checks must be enabled or disabled.");
      if (
        changes.prereleases !== undefined &&
        typeof changes.prereleases !== "boolean"
      )
        throw Error("Preview releases must be enabled or disabled.");
      operation = "configure";
      try {
        Object.assign(
          state,
          ...["automatic", "prereleases"].map((key) =>
            changes[key] === undefined ? {} : { [key]: changes[key] },
          ),
        );
        await persist();
        publish({
          ...clearAvailable(),
          connected: !!token,
          status:
            supported && !publicReleases && !token ? "needs-auth" : "idle",
          message: state.message,
        });
        if (scheduled) arm(20_000);
        return getState();
      } finally {
        operation = undefined;
      }
    },
    async connect(candidate) {
      await initialized;
      mutable();
      operation = "connect";
      try {
        return await connectToken(candidate);
      } finally {
        operation = undefined;
      }
    },
    async disconnect() {
      await initialized;
      mutable();
      if (publicReleases) return getState();
      operation = "disconnect";
      try {
        token = encryptedToken = undefined;
        await persist();
        publish({
          connected: false,
          status: supported ? "needs-auth" : "idle",
          ...clearAvailable(),
          message: supported
            ? "GitHub disconnected. Connect GitHub to check private releases."
            : state.message,
        });
        return getState();
      } finally {
        operation = undefined;
      }
    },
    async useGitHubCLI() {
      await initialized;
      mutable();
      if (!supported || publicReleases) return getState();
      operation = "connect";
      try {
        let candidate;
        for (const executable of CLI_PATHS) {
          try {
            candidate = await new Promise((resolve, reject) =>
              execFile(
                executable,
                ["auth", "token", "--hostname", "github.com"],
                {
                  encoding: "utf8",
                  timeout: 15_000,
                  maxBuffer: 8192,
                  shell: false,
                },
                (error, stdout) => (error ? reject(error) : resolve(stdout)),
              ),
            );
            break;
          } catch (error) {
            if (error.code !== "ENOENT") throw error;
          }
        }
        if (!candidate) throw Error("GitHub CLI unavailable");
        return await connectToken(candidate.trim());
      } catch {
        publish({
          status: token ? "error" : "needs-auth",
          message:
            "GitHub CLI access is unavailable. Sign in to GitHub CLI or connect a read-only repository token.",
        });
        return getState();
      } finally {
        operation = undefined;
      }
    },
    schedule() {
      if (!scheduled && !disposed) {
        scheduled = true;
        arm(20_000);
      }
    },
    dispose() {
      disposed = true;
      clearTimeout(timer);
      downloadCancellation?.cancel();
      authAbort?.abort();
      token = encryptedToken = undefined;
      if (updater) {
        for (const [name, listener] of listeners)
          updater.removeListener(name, listener);
        updater.on("error", () => {});
      }
    },
  };
}
module.exports = { createUpdateManager };
