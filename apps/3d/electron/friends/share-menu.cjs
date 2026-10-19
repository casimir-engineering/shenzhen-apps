// Copy Download Link in the app's File menu (PROTOCOL.md § Links, "Copying a download link"), as ShenzhenPDF has it
// in File ▸ Share and Shenzhen Files in a file's menu: the expiry choice of 7, 1 or 30 days, shown while Friends
// offers links and enabled while the focused window has a model open.
//
// main.cjs builds the File menu at launch without it; host.cjs adds the item when Friends loads, after the first
// paint, so none of this is on the launch path. Choosing an expiry asks the focused window to stage its model and
// send make_download_link (src/friends/FriendsButton.tsx), the same path as the header's Copy Download Link.
const ITEM_ID = "friends-copy-download-link";
// Shenzhen 3D's own words, as in the other apps: a menu is there while no helper runs. 7 days first.
const LABEL = "Copy Download Link";
const EXPIRY_CHOICES = [
  { days: 7, label: "For 7 Days" },
  { days: 1, label: "For 1 Day" },
  { days: 30, label: "For 30 Days" },
];

/**
 * Menu: Electron's Menu. focusedId(): the focused window's webContents id, if any. choose(owner, days): ask that
 * window for a download link.
 */
function createShareMenu({ Menu, focusedId, choose }) {
  const shareable = new Set(); // webContents ids whose page has a model open
  let offers = false;
  let item = null;

  function refresh() {
    if (!item) return;
    item.visible = offers;
    item.enabled = offers && shareable.has(focusedId());
  }

  /** Adds the hidden item after File ▸ Open…, once. */
  function install() {
    if (item || !Menu) return;
    const menu = Menu.getApplicationMenu();
    const file = menu?.getMenuItemById("file")?.submenu;
    if (!file) return;
    item = menu.getMenuItemById(ITEM_ID);
    if (!item) {
      const [created] = Menu.buildFromTemplate([
        {
          id: ITEM_ID,
          label: LABEL,
          visible: false,
          enabled: false,
          submenu: EXPIRY_CHOICES.map(({ days, label }) => ({
            label,
            click: () => {
              const owner = focusedId();
              if (offers && shareable.has(owner)) choose(owner, days);
            },
          })),
        },
      ]).items;
      const open = file.items.findIndex((entry) => entry.id === "open");
      file.insert(open < 0 ? file.items.length : open + 1, created);
      // macOS shows a changed menu once it is set again.
      Menu.setApplicationMenu(menu);
      item = menu.getMenuItemById(ITEM_ID) ?? created;
    }
    refresh();
  }

  return {
    install,
    refresh,
    /** Whether Friends is ready and its helper announces `links`. */
    setOffers(value) {
      offers = Boolean(value);
      refresh();
    },
    /** A window says whether it has a model open. */
    setShareable(owner, value) {
      if (value) shareable.add(owner);
      else shareable.delete(owner);
      refresh();
    },
    forget(owner) {
      shareable.delete(owner);
      refresh();
    },
  };
}

module.exports = { createShareMenu, EXPIRY_CHOICES, ITEM_ID };
