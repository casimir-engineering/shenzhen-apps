// The phone's side of scripts/friends/phones-link.mjs, in Shenzhen 3D's main window: Friends gets ready, then each
// Friends link the system opens in the app (the runner opens one when told the page waits) shows its page in the
// panel, with the link's card or the helper's words. The panel is closed between links, so each page is a new one.
// window.__SZF_LINK__ = { links: <how many>, cold: <the first one started the app>, smoke: <a friends-smoke build,
// which reports to the app> }
(async () => {
  const config = window.__SZF_LINK__;
  const lines = [];
  const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const until = async (probe, what, ms = 120_000) => {
    const begun = Date.now();
    while (Date.now() - begun < ms) {
      const value = await probe();
      if (value) return value;
      await wait(250);
    }
    throw Error(`timed out waiting for ${what}`);
  };
  const panel = () => document.querySelector(".szf-panel");
  const invoke = (command, args) =>
    window.__TAURI_INTERNALS__.invoke(command, args);
  let ok = true;
  try {
    const bridge = await until(() => window.shenzhenFriends, "the bridge");
    // The app joins once, after its first paint; joining again would start the page's events over.
    await until(
      async () => (await bridge.status()).state === "ready",
      "Friends ready",
    );
    lines.push("ok Friends is ready");
    for (let link = 1; link <= config.links; link++) {
      if (!(config.cold && link === 1)) {
        if (panel())
          document.dispatchEvent(
            new KeyboardEvent("keydown", { key: "Escape", bubbles: true }),
          );
        await until(() => !panel(), "the panel closed");
        window.__SZF_LINK_WAITING__ = link;
        if (config.smoke) await invoke("smoke_link_ready");
      }
      const page = await until(
        () => panel()?.querySelector(".szf-link-page"),
        `link ${link}'s page`,
      );
      await until(
        () =>
          page.querySelector(".szf-identity") ??
          page.querySelector('[role="status"]')?.textContent.trim(),
        `link ${link}'s card or the helper's words`,
      );
      lines.push(
        `ok link ${link} opened by the system shows its page in the panel`,
      );
    }
  } catch (error) {
    ok = false;
    lines.push(`not ok ${error?.message ?? error}`);
    lines.push(
      `the panel says: ${(panel()?.innerText ?? "(no panel)").replace(/\s+/g, " ").slice(0, 400)}`,
    );
  }
  if (config.smoke) await invoke("smoke_report", { ok, lines });
  window.__SZF_LINK_RESULT__ = { ok, lines };
})();
