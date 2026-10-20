import { useEffect, useRef, useState } from "react";
import {
  ArrowDownToLine,
  Check,
  KeyRound,
  LoaderCircle,
  RefreshCw,
  X,
} from "lucide-react";
import type { UpdateState } from "../core/updates";

export default function UpdatesDialog({ onClose }: { onClose: () => void }) {
  const modal = useRef<HTMLDialogElement>(null);
  const [state, setState] = useState<UpdateState>();
  const [token, setToken] = useState("");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState("");
  const api = window.shenzhenUpdates!;
  useEffect(() => {
    modal.current?.showModal();
    const unsubscribe = api.subscribe(setState);
    void api
      .getState()
      .then(setState)
      .catch(() =>
        setError(
          "Updates are temporarily unavailable. Close this panel and try again.",
        ),
      );
    return unsubscribe;
  }, [api]);
  async function run(action: () => Promise<UpdateState>) {
    setPending(true);
    setError("");
    try {
      setState(await action());
    } catch {
      setError("That action couldn't be completed. Please try again.");
    } finally {
      setPending(false);
    }
  }
  const busy =
    pending ||
    state?.status === "checking" ||
    state?.status === "downloading" ||
    state?.status === "installing";
  const locked = busy || state?.status === "ready";
  const title =
    state?.status === "installing"
      ? "Installing update"
      : state?.status === "ready"
        ? "Update downloaded"
        : state?.status === "available"
          ? `Version ${state.availableVersion} is available`
          : state?.status === "downloading"
            ? "Downloading update"
            : state?.status === "checking"
              ? "Checking GitHub Releases"
              : state?.status === "needs-auth"
                ? "GitHub access required"
                : state?.status === "error"
                  ? "Update unavailable"
                  : `Version ${state?.version || "…"}`;
  return (
    <dialog
      ref={modal}
      className="dialog updates-dialog"
      onCancel={onClose}
      onClose={onClose}
      aria-labelledby="updates-heading"
    >
      <div className="dialog-heading">
        <div>
          <h2 id="updates-heading">Updates</h2>
        </div>
        <button
          className="icon-button"
          aria-label="Close updates"
          onClick={onClose}
        >
          <X size={20} />
        </button>
      </div>
      <div className="updates-status" aria-live="polite">
        <div className="updates-mark">
          {busy ? (
            <LoaderCircle className="spin" size={24} />
          ) : state?.status === "ready" ? (
            <Check size={24} />
          ) : (
            <ArrowDownToLine size={24} />
          )}
        </div>
        <div>
          <h3>{title}</h3>
          {state?.message && <p>{state.message}</p>}
        </div>
      </div>
      {state?.status === "downloading" && (
        <div className="updates-progress">
          <progress
            aria-label="Update download"
            value={state.progress || 0}
            max={100}
          />
          <span>{Math.round(state.progress || 0)}%</span>
        </div>
      )}
      {error && (
        <p role="alert" className="updates-error">
          {error}
        </p>
      )}
      {state && (
        <>
          <div className="updates-actions">
            {state.status === "available" ? (
              <button
                className="button primary"
                disabled={busy}
                onClick={() => void run(() => api.download())}
              >
                <ArrowDownToLine size={16} />{" "}
                {!state.platform
                  ? "Download update"
                  : state.downloadOnly
                    ? "Download"
                    : `Update to ${state.availableVersion}`}
              </button>
            ) : state.status === "ready" ? (
              <button
                className="button primary"
                disabled={pending}
                onClick={() => void run(() => api.install())}
              >
                <RefreshCw size={16} /> Restart & install
              </button>
            ) : (
              <button
                className="button primary"
                disabled={busy || !state.supported}
                onClick={() => void run(() => api.check())}
              >
                <RefreshCw size={16} />{" "}
                {state.status === "checking"
                  ? "Checking…"
                  : "Check for updates"}
              </button>
            )}
            <span className="muted">
              {state.lastChecked
                ? `Last checked ${new Date(state.lastChecked).toLocaleString()}`
                : ""}
            </span>
          </div>
          <div className="updates-preferences">
            <label className="updates-toggle">
              <span>
                <strong>Check daily</strong>
              </span>
              <input
                type="checkbox"
                checked={state.automatic}
                disabled={locked || !state.supported}
                onChange={(e) =>
                  void run(() => api.configure({ automatic: e.target.checked }))
                }
              />
            </label>
            {!state.platform && (
              <label className="updates-toggle">
                <span>
                  <strong>Include preview releases</strong>
                </span>
                <input
                  type="checkbox"
                  checked={state.prereleases}
                  disabled={locked || !state.supported}
                  onChange={(e) =>
                    void run(() =>
                      api.configure({ prereleases: e.target.checked }),
                    )
                  }
                />
              </label>
            )}
          </div>
          {state.access === "private" && (
            <details className="updates-connection" open={!state.connected}>
              <summary>
                <KeyRound size={16} /> GitHub access{" "}
                <span>{state.connected ? "Connected" : "Not connected"}</span>
              </summary>
              <label>
                Release repository
                <input readOnly value={`${state.repository} / shenzhen-3D`} />
              </label>
              {state.connected ? (
                <p className="updates-auth-row">
                  <button
                    className="button"
                    disabled={locked}
                    onClick={() => void run(() => api.disconnect())}
                  >
                    Disconnect
                  </button>
                </p>
              ) : (
                <>
                  <p className="muted">
                    Requires access to this private repository.
                  </p>
                  <button
                    className="button"
                    disabled={locked || !state.supported}
                    onClick={() => void run(() => api.useGitHubCLI())}
                  >
                    <KeyRound size={15} /> Use GitHub CLI login
                  </button>
                  <form
                    onSubmit={(event) => {
                      event.preventDefault();
                      const value = token;
                      setToken("");
                      void run(() => api.connect(value));
                    }}
                  >
                    <label htmlFor="update-token">
                      Access token
                      <input
                        id="update-token"
                        type="password"
                        autoComplete="off"
                        spellCheck={false}
                        value={token}
                        placeholder="GitHub access token"
                        disabled={locked}
                        onChange={(event) => setToken(event.target.value)}
                      />
                    </label>
                    <small>
                      Requires Contents: read permission for this repository.
                    </small>
                    <button
                      className="button"
                      type="submit"
                      disabled={locked || !token.trim() || !state.supported}
                    >
                      Connect
                    </button>
                  </form>
                </>
              )}
            </details>
          )}
        </>
      )}
      <div className="dialog-footer">
        <button className="button" onClick={onClose}>
          Done
        </button>
      </div>
    </dialog>
  );
}
