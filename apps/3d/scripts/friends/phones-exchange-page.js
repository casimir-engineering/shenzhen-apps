// The phone's side of scripts/friends/phones-exchange.mjs, run in Shenzhen 3D's main window on an Android emulator
// (through the WebView's DevTools) or in the iOS simulator (a friends-smoke build's SHENZHEN_3D_SMOKE). It uses the
// panel as a person does where it can (the Friends button, the friend's row, Accept), and the bridge where typing
// into the composer would only test the keyboard: a message, then a staged file (phones give no paths). Then `#`:
// a model opened from Open file (as the system's picker hands it over) is listed among the recent files, typing
// narrows the list, and the chosen file is attached and sent with Send, from the copy the app kept of it.
// window.__SZF_PHONE__ = { conversation, peerName, message, reply, outgoingName, outgoingText, incomingName,
//                          recentName, recentText, report }
(async () => {
  const config = window.__SZF_PHONE__;
  const lines = [];
  const check = (line) => lines.push(`ok ${line}`);
  const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const until = async (probe, what, ms = 180_000) => {
    const begun = Date.now();
    while (Date.now() - begun < ms) {
      const value = await probe();
      if (value) return value;
      await wait(250);
    }
    throw Error(`timed out waiting for ${what}`);
  };
  const panel = () => document.querySelector(".szf-panel");
  const buttonWithText = (text) =>
    [...(panel()?.querySelectorAll("button") ?? [])].find((b) => b.innerText.trim() === text);
  let ok = true;
  try {
    const bridge = await until(() => window.shenzhenFriends, "the bridge");
    await until(async () => (await bridge.join()).state === "ready", "Friends ready");
    check("Friends runs in the app's own process and is ready");
    // A model opened from Open file, as the system's document picker hands one to the page.
    const input = await until(() => document.querySelector("input[type=file]"), "Open file's input");
    const picked = new DataTransfer();
    picked.items.add(new File([config.recentText], config.recentName));
    input.files = picked.files;
    input.dispatchEvent(new Event("change", { bubbles: true }));
    const stem = config.recentName.replace(/\.[^.]+$/, "");
    await until(() => document.querySelector(".status-bar")?.innerText.includes(stem), "the opened model");
    check("a model opened from Open file shows in the viewer");
    // The Kotlin and Swift halves answer Rust only: the page is refused, the key above all.
    for (const command of ["seal", "unseal", "keychainRead", "dirs", "share"]) {
      const answered = await window.__TAURI_INTERNALS__.invoke(`plugin:szfriends|${command}`, { alias: "x" }).then(
        () => true,
        () => false,
      );
      if (answered) throw Error(`the page could call ${command}`);
    }
    check("the page cannot call the platform half's commands");
    const button = await until(() => document.querySelector('[data-szfriends="button"]'), "the Friends button");
    if (!panel()) button.click();
    const row = await until(
      () => [...(panel()?.querySelectorAll(".szf-row") ?? [])].find((r) => r.innerText.includes(config.peerName)),
      "the friend's row",
    );
    check("the panel lists the friend");
    (row.querySelector(".szf-row-main") ?? row).click();
    await until(() => panel()?.querySelector(".szf-editor"), "the conversation and its composer");
    check("the friend's conversation opens from the row");

    const sent = await bridge.send("send_message", {
      conversation_id: config.conversation,
      text: config.message,
      client_token: `phones-exchange-message-${Date.now()}`,
    });
    if (sent.reply?.ok !== true) throw Error(`send_message: ${JSON.stringify(sent.reply)}`);
    const staged = await bridge.stage(config.outgoingName, new TextEncoder().encode(config.outgoingText));
    const offered = await bridge.send("send_files", {
      conversation_id: config.conversation,
      files: [{ path: staged }],
      client_token: `phones-exchange-files-${Date.now()}`,
    });
    if (offered.reply?.ok !== true) throw Error(`send_files: ${JSON.stringify(offered.reply)}`);
    check("a message and a staged file are sent");

    await until(() => panel()?.innerText.includes(config.reply), "the friend's reply in the conversation");
    check("the friend's reply shows in the conversation");
    const accept = await until(() => buttonWithText("Accept"), "Accept on the friend's file");
    accept.click();
    await until(() => buttonWithText("Share…"), "the received file's Share…");
    check("the friend's file is accepted with a tap and received, with Share…");
    await until(
      () => panel()?.innerText.includes(config.outgoingName) && !buttonWithText("Cancel"),
      "the phone's file delivered",
    );
    check("the phone's file is delivered");

    // `#` in the composer, typed as the keyboard types (insertText), with the keys a hardware keyboard sends.
    const editor = panel().querySelector(".szf-editor");
    editor.focus();
    const caret = document.createRange();
    caret.selectNodeContents(editor);
    caret.collapse(false);
    getSelection().removeAllRanges();
    getSelection().addRange(caret);
    const key = (name) =>
      editor.dispatchEvent(new KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true }));
    document.execCommand("insertText", false, "#");
    const options = () => [...(panel()?.querySelectorAll(".szf-picker [role=option]") ?? [])];
    const recentRow = await until(
      () => options().find((o) => o.innerText.includes(config.recentName)),
      "the recent file under #",
    );
    if (!/Opened just now/.test(recentRow.innerText) || !/STL/.test(recentRow.innerText))
      throw Error(`the recent file's row reads ${JSON.stringify(recentRow.innerText)}`);
    check("# lists the recent file with its kind and when it was opened");
    document.execCommand("insertText", false, "stl");
    // Earlier runs on the same device may have left copies of the same name: every row left must be it.
    await until(
      () => options().length && options().every((o) => o.innerText.includes(config.recentName)),
      "# narrowed",
    );
    check("typing after # narrows the list");
    key("Enter");
    await until(
      () => panel()?.querySelector(".szf-chip.attachment")?.innerText.includes(config.recentName),
      "the recent file's chip",
    );
    key("Enter");
    await until(
      () => [...panel().querySelectorAll(".szf-transfer")].some((t) => t.innerText.includes(config.recentName)),
      "the recent file offered",
    );
    check("choosing it and pressing Send offers it to the friend");
  } catch (error) {
    ok = false;
    lines.push(`not ok ${error?.message ?? error}`);
  }
  if (config.holdMs) await wait(config.holdMs);
  if (config.report === "smoke") {
    await window.__TAURI_INTERNALS__.invoke("smoke_report", { ok, lines });
  }
  return { ok, lines };
})();
