// View ▸ Friends (electron/friends/view-menu.cjs): added hidden at the top of View, shown with ⌘J while Friends runs
// and is on, and never a failure at startup when the menu cannot take it.
const test = require("node:test");
const assert = require("node:assert/strict");
const {
  createViewMenu,
  ITEM_ID,
  SEPARATOR_ID,
} = require("./friends/view-menu.cjs");

class FakeMenuItem {
  constructor(options) {
    Object.assign(this, options);
  }
}
function fakeMenu(items) {
  return {
    items,
    insert(index, item) {
      // Electron's Menu.insert refuses anything but a MenuItem ("Invalid item").
      if (!(item instanceof FakeMenuItem)) throw TypeError("Invalid item");
      items.splice(index, 0, item);
    },
    getMenuItemById(id) {
      for (const item of items) {
        if (item.id === id) return item;
        const found = item.submenu?.getMenuItemById?.(id);
        if (found) return found;
      }
      return null;
    },
  };
}
function fakeElectron({ view = true } = {}) {
  const menus = [
    new FakeMenuItem({ id: "file", label: "File", submenu: fakeMenu([]) }),
  ];
  if (view)
    menus.push(
      new FakeMenuItem({
        id: "view",
        label: "View",
        submenu: fakeMenu([new FakeMenuItem({ role: "reload" })]),
      }),
    );
  const app = fakeMenu(menus);
  return {
    MenuItem: FakeMenuItem,
    Menu: {
      sets: 0,
      getApplicationMenu: () => app,
      setApplicationMenu(menu) {
        assert.equal(menu, app);
        this.sets++;
      },
    },
    app,
  };
}

test("adds View ▸ Friends ⌘J hidden, shows it while Friends is on, and toggles on click", () => {
  const { Menu, MenuItem, app } = fakeElectron();
  const toggles = [];
  const menu = createViewMenu({
    Menu,
    MenuItem,
    toggle: (owner) => toggles.push(owner),
  });
  menu.install();
  menu.install(); // once
  const view = app.getMenuItemById("view").submenu.items;
  assert.deepEqual(
    view.map((item) => item.id ?? item.role),
    [ITEM_ID, SEPARATOR_ID, "reload"],
  );
  const item = app.getMenuItemById(ITEM_ID);
  assert.equal(item.label, "Friends");
  assert.equal(item.accelerator, "CmdOrCtrl+J");
  assert.equal(item.visible, false);
  assert.equal(Menu.sets, 1);
  item.click(item, { webContents: { id: 7 } });
  assert.deepEqual(toggles, [], "a hidden item does nothing");
  menu.setShown(true);
  assert.equal(item.visible, true);
  assert.equal(item.enabled, true);
  assert.equal(app.getMenuItemById(SEPARATOR_ID).visible, true);
  item.click(item, { webContents: { id: 7 } });
  item.click(item, undefined);
  assert.deepEqual(
    toggles,
    [7, undefined],
    "the window the menu was used in, when Electron names one",
  );
  menu.setShown(false);
  assert.equal(item.visible, false);
  assert.equal(app.getMenuItemById(SEPARATOR_ID).visible, false);
});

test("a menu without View, or one that refuses the item, leaves the app without it and does not throw", () => {
  const without = fakeElectron({ view: false });
  const logged = [];
  const menu = createViewMenu({
    ...without,
    toggle() {},
    log: (...args) => logged.push(args),
  });
  assert.doesNotThrow(() => menu.install());
  assert.doesNotThrow(() => menu.setShown(true));
  assert.equal(without.app.getMenuItemById(ITEM_ID), null);

  const refusing = fakeElectron();
  refusing.app.getMenuItemById("view").submenu.insert = () => {
    throw TypeError("Invalid item");
  };
  const second = createViewMenu({
    ...refusing,
    toggle() {},
    log: (...args) => logged.push(args),
  });
  assert.doesNotThrow(() => second.install());
  assert.doesNotThrow(() => second.setShown(true));
  assert.equal(logged.length, 1);

  // No Menu at all (Friends not offered here): nothing to do.
  assert.doesNotThrow(() => createViewMenu({ toggle() {} }).install());
});
