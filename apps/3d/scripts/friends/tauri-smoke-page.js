// The page half of the Tauri Friends smoke (scripts/friends/tauri-smoke.mjs): run in the main window of a build
// made with the `friends-smoke` feature, it uses the Friends panel as a person would (clicks, typing, a dropped
// file) and reports each check to the app, which prints them and quits. The runner prepends
// `window.__SZF_SMOKE__ = {…}` with the peer's name and the files' contents.
(async () => {
  const config = window.__SZF_SMOKE__;
  const lines = [];
  let checks = 0;
  const check = (name) => lines.push(`ok ${++checks} ${name}`);
  // Passing checks go on to the second window's (src-tauri/src/smoke.rs); a failure ends the run here.
  const report = (ok) =>
    window.__TAURI_INTERNALS__.invoke("smoke_checks", { ok, lines });
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const until = async (find, what, timeout = 60_000) => {
    const started = Date.now();
    for (;;) {
      const found = find();
      if (found) return found;
      if (Date.now() - started > timeout) throw Error(`no ${what}`);
      await sleep(100);
    }
  };
  const all = (selector, root = document) =>
    Array.from(root.querySelectorAll(selector));
  const withText = (selector, text, root = document) =>
    all(selector, root).find((element) => element.textContent.includes(text));
  const panel = () => document.querySelector('[data-szfriends="dropdown"]');
  const openPanel = async (button) => {
    if (!panel()) button.click();
    return until(panel, "the Friends panel");
  };
  // React reads a controlled input's value through its own setter.
  const typeInto = (input, text) => {
    const setter = Object.getOwnPropertyDescriptor(
      HTMLInputElement.prototype,
      "value",
    ).set;
    setter.call(input, text);
    input.dispatchEvent(new Event("input", { bubbles: true }));
  };

  try {
    const bridge = await until(() => window.shenzhenFriends, "the bridge");
    const button = await until(
      () => document.querySelector('[data-szfriends="button"]'),
      "the Friends button",
    );
    let strings = null;
    await until(() => {
      void bridge.status().then((value) => {
        if (value.state === "ready" && value.strings) strings = value.strings;
      });
      return strings;
    }, "Friends ready");
    await until(
      () => button.getAttribute("aria-label") === strings.button_label,
      "the button's label from the helper",
    );
    check(
      "Friends attaches after first paint and the button reads the helper's catalog",
    );

    let list = await openPanel(button);
    if (config.mode === "request") {
      const prompt = await until(
        () => list.querySelector(".szf-name-prompt input"),
        "the name prompt",
      );
      typeInto(prompt, config.ownName);
      // What Enter does in the field: submit its form.
      prompt.form.requestSubmit();
      await until(
        () =>
          list.querySelector(".szf-footer-name")?.textContent ===
          config.ownName,
        "the name in the footer",
      );
      check("a fresh identity names itself from the list's prompt");
      withText('[role="tab"]', strings.tab_nearby, list).click();
      (
        await until(
          () => list.querySelector(".szf-visibility .szf-button"),
          "Make myself visible",
        )
      ).click();
      await until(() => list.querySelector(".szf-countdown"), "the countdown");
      withText('[role="tab"]', strings.tab_friends, list).click();
      const accept = await until(
        () =>
          withText(".szf-row", config.peerName, list)?.querySelector(
            ".szf-row-action.accept",
          ),
        "the peer's request",
        90_000,
      );
      accept.click();
      check(
        "the peer finds us nearby and Accept on its request makes us friends",
      );
    }

    const row = await until(
      () => withText(".szf-row", config.peerName, list),
      `${config.peerName} in the list`,
    );
    row.querySelector(".szf-row-main").click();
    const editor = await until(
      () => list.querySelector('.szf-editor[contenteditable="true"]'),
      "the composer",
      90_000,
    );
    editor.focus();
    document.execCommand("insertText", false, config.message);
    list.querySelector(".szf-composer-row .szf-button.primary").click();
    await until(
      () => withText(".szf-message.out", config.message, list),
      "our message in the chat",
    );
    await until(
      () => withText(".szf-message.in", config.reply, list),
      "the peer's reply",
      90_000,
    );
    check("messages go both ways");

    const offer = await until(
      () => withText(".szf-transfer.in", config.incomingName, list),
      "the peer's file offer",
      90_000,
    );
    offer.querySelector(".szf-button.primary").click();
    const open = await until(
      () =>
        all(".szf-button", offer).find(
          (element) => element.textContent.trim() === "Open",
        ),
      "Open on the received file",
      90_000,
    );
    open.click();
    await until(
      () =>
        document
          .querySelector(".document-title")
          ?.textContent.includes(config.incomingName.replace(/\.[^.]+$/, "")),
      "the received file in the viewer",
      90_000,
    );
    check("Accept, then Open shows the received file in the viewer");

    // A file dropped on the chat. A desktop sends it from its path, which the system reports beside the page's own
    // drop event; without that report nothing is staged and the helper's words say why.
    list = await openPanel(button);
    const history = await until(
      () => list.querySelector(".szf-history"),
      "the chat",
    );
    const drop = () => {
      const transfer = new DataTransfer();
      transfer.items.add(
        new File([config.outgoingText], config.outgoingName, {
          type: "application/octet-stream",
        }),
      );
      for (const type of ["dragenter", "dragover", "drop"])
        history.dispatchEvent(
          new DragEvent(type, {
            bubbles: true,
            cancelable: true,
            dataTransfer: transfer,
          }),
        );
    };
    drop();
    await until(
      () =>
        list.querySelector(".szf-refusal")?.textContent ===
        strings.drop_not_a_file,
      "the refusal of a drop the system did not report",
      30_000,
    );
    check(
      "a desktop sends no copy of a dropped file the system did not report",
    );
    // What the plugin's drop listener hears from WebView2, WebKitGTK or the drag pasteboard for a real drop.
    await window.__TAURI_INTERNALS__.invoke("smoke_native_drop", {
      path: config.outgoingPath,
    });
    drop();
    const sent = await until(
      () => withText(".szf-transfer.out", config.outgoingName, list),
      "the dropped file in the chat",
    );
    await until(
      () =>
        /Delivered/.test(sent.querySelector(".szf-status")?.textContent ?? ""),
      "the dropped file delivered",
      120_000,
    );
    check("a file dropped on the chat reaches the peer");

    // Windows and Linux: a Friends link opened while the app runs, as a browser opens it, by starting the app again
    // with the link (the runner does that once told the page is ready). Its page opens in the panel and shows the
    // link's card, or the helper's words when the helper cannot open links.
    if (config.link) {
      await window.__TAURI_INTERNALS__.invoke("smoke_link_ready");
      const linkPage = await until(
        () => panel()?.querySelector(".szf-link-page"),
        "the link's page in the panel",
        60_000,
      );
      await until(
        () =>
          linkPage.querySelector(".szf-identity") ??
          linkPage.querySelector('[role="status"]')?.textContent.trim(),
        "the link's card or the helper's words",
        60_000,
      );
      check(
        "a Friends link opened while the app runs shows its page in the panel",
      );
    }
    await report(true);
  } catch (error) {
    lines.push(`not ok ${checks + 1} ${error?.message ?? error}`);
    const text = panel()?.innerText ?? "(no panel)";
    lines.push(`the panel says: ${text.replace(/\s+/g, " ").slice(0, 600)}`);
    await report(false);
  }
})();
