// The page half of the update tests (scripts/updates/*-e2e.*): a test build of the Windows, Linux or iOS app
// (feature updates-test-api) runs it in every page it loads, from SHENZHEN_3D_UPDATES_TEST_PAGE. It uses the
// footer and the Updates dialog as a person would: opens Updates, clicks "Update to …" (once more after a refused
// download), "Restart & install", or "Download" for a deb or rpm, and reports what it sees to the app's test log
// (the `report` action of test builds), where the test reads it.
(() => {
  if (window.top !== window) return;
  const report = (text) =>
    window.__TAURI_INTERNALS__
      ?.invoke("app_updates", { action: "report", args: { text } })
      .catch(() => {});
  const seen = new Set();
  const once = (key, act) => {
    if (seen.has(key)) return;
    seen.add(key);
    act();
  };
  const button = (pattern) =>
    [...document.querySelectorAll(".updates-dialog button")].find(
      (b) => pattern.test(b.textContent.trim()) && !b.disabled,
    );
  let refusals = 0;
  const tick = () => {
    const footer = document.querySelector("[data-open-updates]");
    if (!footer) return;
    once("footer", () =>
      report(
        `footer "${footer.textContent.trim()}" version ${footer.textContent.match(/v([\d.]+)/)?.[1] ?? "?"}`,
      ),
    );
    const dialog = document.querySelector(".updates-dialog[open]");
    if (!dialog) {
      once("open", () => {
        report("opens Updates");
        footer.click();
      });
      return;
    }
    const title =
      dialog.querySelector(".updates-status h3")?.textContent.trim() ?? "";
    const message =
      dialog.querySelector(".updates-status p")?.textContent.trim() ?? "";
    const progress = dialog
      .querySelector(".updates-progress span")
      ?.textContent.trim();
    once(`dialog ${title} | ${message}`, () =>
      report(`dialog "${title}" "${message}"`),
    );
    if (progress)
      once(`progress ${progress}`, () => report(`progress ${progress}`));
    if (message === "You are up to date.")
      once("up to date", () => report("done up to date"));
    if (/didn't match/.test(message))
      once(`refused ${refusals}`, () => {
        refusals += 1;
        report(`done refused ${refusals}`);
      });
    const update = button(/^Update to /);
    if (update && refusals < 2)
      once(`update ${message}`, () => {
        report(`clicks "${update.textContent.trim()}"`);
        update.click();
      });
    const download = button(/^Download$/);
    if (download)
      once("download", () => {
        report(`clicks "Download"`);
        download.click();
      });
    const restart = button(/^Restart & install$/);
    if (restart)
      once("restart", () => {
        report(`clicks "Restart & install"`);
        restart.click();
      });
  };
  window.setInterval(tick, 400);
})();
