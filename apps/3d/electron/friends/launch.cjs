// Shenzhen Friends in the main process (docs/FRIENDS.md): offered on macOS by the packaged app, which embeds the
// helper, and by a development run told which helper and which Friends home to use. Only this file loads at launch;
// the host and its modules load a second after the first paint, or when a page or a Friends link needs them.
const {
  app,
  ipcMain,
  BrowserWindow,
  Menu,
  MenuItem,
  shell,
} = require("electron");

/** `trusted` says which pages may use Friends; received files in `associatedFormats` open through `queueOpenFiles`. */
function setupFriends({ trusted, associatedFormats, queueOpenFiles }) {
  const available =
    process.platform === "darwin" &&
    (app.isPackaged ||
      Boolean(
        process.env.SHENZHEN_3D_FRIENDS_HELPER &&
        process.env.SZFRIENDS_STATE_DIR,
      ));
  let host;
  let pendingLink;
  const friends = () => {
    if (!host) {
      host = require("./host.cjs").createFriendsHost({
        app,
        BrowserWindow,
        Menu,
        MenuItem,
        shell,
        trusted,
        openFormats: associatedFormats,
        openFiles: queueOpenFiles,
      });
      if (pendingLink) host.openLink(pendingLink);
      pendingLink = undefined;
    }
    return host;
  };
  ipcMain.handle("shenzhen-friends", (event, method, value) =>
    friends().handle(event, method, value),
  );
  app.on("open-url", (event, url) => {
    if (!available || !url.startsWith("shenzhen3d:")) return;
    event.preventDefault();
    if (host) host.openLink(url);
    else pendingLink = url;
  });
  return {
    // Friends loads after the first paint has settled, never on the launch path: even requiring its modules
    // waits a second, so the main process stays free while the welcome screen finishes (docs/FRIENDS.md § Startup).
    firstPaint() {
      if (available) setTimeout(() => friends().firstPaint(), 1000).unref?.();
    },
    dispose() {
      host?.dispose();
    },
  };
}

module.exports = { setupFriends };
