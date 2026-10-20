// View ▸ Friends in the app's menu, with its shortcut (⌘J): opens or closes the focused window's Friends dropdown.
// Shown only while Friends runs and is on, like the button.
//
// main.cjs builds the View menu at launch without it; host.cjs adds the item when Friends loads, after the first
// paint. The page handles ⌘J itself (src/App.tsx), also while the dropdown's search field has focus, and marks the key
// handled, so the menu does not run it a second time; choosing the item with the mouse sends the same request.
//
// A menu that cannot take the item (no View menu, a changed Electron) leaves the app without it, never fails Friends:
// the shortcut and the button work without the menu.
const ITEM_ID = "friends-toggle";
const SEPARATOR_ID = `${ITEM_ID}-separator`;
// Friends is a beta: the menu says so, as the button's tooltip and Settings do.
const LABEL = "Friends (Beta)";
const ACCELERATOR = "CmdOrCtrl+J";

/**
 * Menu, MenuItem: Electron's. toggle(owner): ask the window the menu was used in (its webContents id, or undefined
 * when Electron names none) to open or close its dropdown.
 */
function createViewMenu({ Menu, MenuItem, toggle, log = console.error }) {
  let shown = false;
  let item = null;
  let separator = null;

  function refresh() {
    if (item) item.visible = item.enabled = shown;
    if (separator) separator.visible = shown;
  }

  /** Adds the hidden item and a separator at the top of View, once. */
  function install() {
    if (item || !Menu || !MenuItem) return;
    try {
      const menu = Menu.getApplicationMenu();
      const view = menu?.getMenuItemById("view")?.submenu;
      if (!view || typeof view.insert !== "function") return;
      item = menu.getMenuItemById(ITEM_ID);
      separator = menu.getMenuItemById(SEPARATOR_ID);
      if (!item) {
        item = new MenuItem({
          id: ITEM_ID,
          label: LABEL,
          accelerator: ACCELERATOR,
          visible: false,
          enabled: false,
          click: (_item, window) => shown && toggle(window?.webContents?.id),
        });
        separator = new MenuItem({
          id: SEPARATOR_ID,
          type: "separator",
          visible: false,
        });
        view.insert(0, separator);
        view.insert(0, item);
        // macOS shows a changed menu once it is set again.
        Menu.setApplicationMenu(menu);
        item = menu.getMenuItemById(ITEM_ID) ?? item;
        separator = menu.getMenuItemById(SEPARATOR_ID) ?? separator;
      }
      refresh();
    } catch (error) {
      item = separator = null;
      log("Friends: View ▸ Friends was not added:", error);
    }
  }

  return {
    install,
    /** Whether Friends runs and is on. */
    setShown(value) {
      shown = Boolean(value);
      refresh();
    },
  };
}

module.exports = { createViewMenu, ITEM_ID, SEPARATOR_ID, ACCELERATOR };
