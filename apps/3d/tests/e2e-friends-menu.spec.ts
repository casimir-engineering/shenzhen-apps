// A Friends list row's menu in the real app (Chromium, headless): right-click on a computer, a long press on a
// phone, then Remove and its confirmation. The bridge is a stand-in that answers with the pinned PROTOCOL fixtures
// (tests/fixtures/friends) plus each row's `menu`, as a helper does for a client that declared list.menu.
import {test, expect, type Page} from '@playwright/test';
import {readFileSync} from 'node:fs';
import {resolve} from 'node:path';

const fixtures = resolve('tests/fixtures/friends');
const read = (file: string) => JSON.parse(readFileSync(resolve(fixtures, file), 'utf8'));
const welcome = read('frames/welcome.json');
const list = read('snapshots/list.json');
const nearby = read('snapshots/nearby-visible-bluetooth-off.json');

// The confirmation the helper sends with Remove (PROTOCOL.md § list, rows[].menu), for a friend with history.
const removeAction = (first: string) => ({
  action: 'remove_friend',
  label: 'Remove',
  style: 'destructive',
  note: null,
  arm: null,
  confirm: {
    title: `Remove ${first}?`,
    body: `${first} leaves your list and isn’t told. Anything still waiting to go to ${first} won’t be sent. Your chat history with ${first} is kept unless you also delete it.`,
    confirm_label: 'Remove',
    cancel_label: 'Cancel',
    destructive: true,
    option: {label: 'Also delete chat history', field: 'delete_history'},
  },
});
const frame = {
  ...list,
  data: {
    ...list.data,
    rows: list.data.rows.map((row: {title: string}) => ({...row, menu: [removeAction(row.title.split(/\s/)[0])]})),
  },
};

type Sent = {type: string; fields?: Record<string, unknown>};

/** The stand-in bridge: answers subscribe(list) with `frame`; remove_friend replies after `delay` ms, refused when
 * `refuse`, and otherwise sends the list again without that row. */
async function install(page: Page, options: {delay: number; refuse?: boolean; frame?: unknown; nearby?: unknown}) {
  await page.addInitScript(
    ({welcome, frame, nearbyFrame, delay, refuse}) => {
      const status = {
        available: true,
        enabled: true,
        attached: true,
        state: 'ready',
        text: '',
        strings: welcome.strings,
        capabilities: welcome.capabilities,
        limits: welcome.limits,
        badge: null,
      };
      const listeners = new Set<(event: unknown) => void>();
      const sent: Sent[] = [];
      (window as unknown as {__sent: Sent[]}).__sent = sent;
      let next = 0;
      let current = frame;
      let listSubscription = '';
      const reply = (result: unknown, ok = true) => ({
        type: 'reply',
        re: String(++next),
        ok,
        ...(ok
          ? {result}
          : {error: {code: 'not_found', message: 'That person isn’t on your list any more.', retryable: false, details: {}}}),
      });
      const wait = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));
      (window as unknown as {shenzhenFriends: unknown}).shenzhenFriends = {
        join: async () => status,
        status: async () => status,
        subscribe(listener: (event: unknown) => void) {
          listeners.add(listener);
          return () => listeners.delete(listener);
        },
        async send(type: string, fields?: Record<string, unknown>) {
          sent.push({type, fields});
          if (type === 'subscribe' && fields?.view === 'list') {
            listSubscription = `s_list_${next}`;
            return {reply: reply({subscription: listSubscription}), snapshot: {...current, subscription: listSubscription}};
          }
          if (type === 'subscribe' && fields?.view === 'nearby' && nearbyFrame) {
            const subscription = `s_nearby_${next}`;
            return {reply: reply({subscription}), snapshot: {...nearbyFrame, subscription}};
          }
          if (type === 'subscribe' || type === 'open_conversation') return {reply: reply({subscription: `s_${next}`})};
          if (type === 'remove_friend') {
            await wait(delay);
            if (refuse) return {reply: reply(null, false)};
            current = {
              ...current,
              rev: current.rev + 1,
              data: {
                ...current.data,
                rows: current.data.rows.filter((row: {conversation_id: string}) => row.conversation_id !== fields?.conversation_id),
              },
            };
            for (const listener of listeners)
              listener({kind: 'snapshot', frame: {...current, subscription: listSubscription}});
            return {reply: reply({})};
          }
          return {reply: reply({})};
        },
        setEnabled: async () => status,
        image: async () => null,
        animal: async () => null,
        animals: async () => null,
        pathsForFiles: () => [],
        classify: async () => [],
        stage: async () => '',
        token: async () => '',
        openFile: async () => false,
        showFile: async () => false,
        openSettings: async () => false,
        openURL: async () => false,
        shareable: async () => {},
      };
    },
    {
      welcome,
      frame: options.frame ?? frame,
      nearbyFrame: options.nearby ?? null,
      delay: options.delay,
      refuse: options.refuse ?? false,
    },
  );
  const errors: string[] = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto('/');
  await page.locator('[data-szfriends="button"]').click();
  await expect(page.locator('.szf-panel .szf-row').first()).toBeVisible();
  return errors;
}
const sent = (page: Page) => page.evaluate(() => (window as unknown as {__sent: Sent[]}).__sent);
const row = (page: Page, name: string) => page.locator('.szf-row', {hasText: name});

test('right-click a row, Remove, confirm with the history option: the row goes at once and the intent is sent', async ({page, isMobile}) => {
  test.skip(isMobile, 'computers only');
  const errors = await install(page, {delay: 1500});
  await row(page, 'Mei Lin').click({button: 'right'});
  const menu = page.getByRole('menu', {name: 'Mei Lin'});
  await expect(menu).toBeVisible();
  await expect(menu.getByRole('menuitem')).toHaveText(['Remove']);
  await expect(menu.getByRole('menuitem', {name: 'Remove'})).toBeFocused();
  await menu.getByRole('menuitem', {name: 'Remove'}).click();
  await expect(menu).toHaveCount(0);
  const dialog = page.getByRole('alertdialog', {name: 'Remove Mei?'});
  await expect(dialog).toBeVisible();
  const option = dialog.getByRole('checkbox', {name: 'Also delete chat history'});
  await expect(option).not.toBeChecked();
  await option.check();
  await dialog.getByRole('button', {name: 'Remove'}).click();
  // Gone at once, while the helper has not answered yet.
  await expect(row(page, 'Mei Lin')).toHaveCount(0, {timeout: 500});
  expect((await sent(page)).filter(intent => intent.type === 'remove_friend')).toEqual([
    {type: 'remove_friend', fields: {conversation_id: 'c_mei', delete_history: true}},
  ]);
  // Focus moves to the next row, so Delete can go on from there.
  await expect(row(page, 'Kenji Sato').locator('.szf-row-main')).toBeFocused();
  await page.waitForTimeout(1800);
  await expect(row(page, 'Mei Lin')).toHaveCount(0);
  await expect(row(page, 'Kenji Sato')).toBeVisible();
  expect(errors).toEqual([]);
});

test('the keyboard: Shift+F10 opens the menu, Escape closes only it, Delete asks first and Cancel keeps the row', async ({page, isMobile}) => {
  test.skip(isMobile, 'computers only');
  await install(page, {delay: 0});
  const kenji = row(page, 'Kenji Sato').locator('.szf-row-main');
  await kenji.focus();
  await page.keyboard.press('Shift+F10');
  const menu = page.getByRole('menu', {name: 'Kenji Sato'});
  await expect(menu).toBeVisible();
  await expect(kenji).toHaveAttribute('aria-expanded', 'true');
  await page.keyboard.press('Escape');
  await expect(menu).toHaveCount(0);
  await expect(page.locator('.szf-panel')).toBeVisible();
  await expect(kenji).toBeFocused();
  await page.keyboard.press('Delete');
  const dialog = page.getByRole('alertdialog', {name: 'Remove Kenji?'});
  await expect(dialog).toBeVisible();
  await dialog.getByRole('button', {name: 'Cancel'}).click();
  await expect(row(page, 'Kenji Sato')).toBeVisible();
  await expect(kenji).toBeFocused();
  // Backspace, the Mac's delete key, does the same; this time without the option.
  await page.keyboard.press('Backspace');
  await dialog.getByRole('button', {name: 'Remove'}).click();
  await expect(row(page, 'Kenji Sato')).toHaveCount(0);
  expect((await sent(page)).filter(intent => intent.type === 'remove_friend')).toEqual([
    {type: 'remove_friend', fields: {conversation_id: 'c_kenji'}},
  ]);
});

test('when the helper refuses, the row comes back and says why', async ({page, isMobile}) => {
  test.skip(isMobile, 'computers only');
  await install(page, {delay: 300, refuse: true});
  await row(page, 'Daniel Ortiz').click({button: 'right'});
  await page.getByRole('menuitem', {name: 'Remove'}).click();
  await page.getByRole('alertdialog').getByRole('button', {name: 'Remove'}).click();
  await expect(row(page, 'Daniel Ortiz')).toHaveCount(0);
  await expect(row(page, 'Daniel Ortiz')).toBeVisible();
  await expect(page.locator('.szf-notice')).toHaveText('That person isn’t on your list any more.');
});

/** A finger held on the element's middle for `ms`, through the touch events a phone sends. */
async function longPress(page: Page, selector: string, ms: number) {
  const box = (await page.locator(selector).boundingBox())!;
  const point = {x: box.x + box.width / 2, y: box.y + box.height / 2};
  const cdp = await page.context().newCDPSession(page);
  await cdp.send('Input.dispatchTouchEvent', {type: 'touchStart', touchPoints: [point]});
  await page.waitForTimeout(ms);
  await cdp.send('Input.dispatchTouchEvent', {type: 'touchEnd', touchPoints: []});
}

test('a long press on a phone opens the menu without opening the chat; Remove, confirm: the row goes', async ({page, hasTouch}) => {
  test.skip(!hasTouch, 'phones only');
  const errors = await install(page, {delay: 800});
  // A tap still opens the conversation.
  await row(page, 'Jonas Berg').locator('.szf-row-main').tap();
  await expect(page.locator('.szf-list-page')).toHaveCount(0);
  await page.locator('.szf-back').tap();
  await expect(row(page, 'Priya Raman')).toBeVisible();
  const opened = (await sent(page)).filter(intent => intent.type === 'open_conversation').length;

  // A short press is a tap, never the menu.
  await longPress(page, '.szf-row[data-conversation-id="c_priya"] .szf-row-main', 150);
  await expect(page.getByRole('menu')).toHaveCount(0);
  await page.locator('.szf-back').tap();

  await longPress(page, '.szf-row[data-conversation-id="c_priya"] .szf-row-main', 700);
  const menu = page.getByRole('menu', {name: 'Priya Raman'});
  await expect(menu).toBeVisible();
  await expect(page.locator('.szf-list-page')).toBeVisible();
  expect((await sent(page)).filter(intent => intent.type === 'open_conversation').length).toBe(opened + 1);
  // Nothing is selected and no system menu is offered for the row.
  expect(await page.evaluate(() => getSelection()?.toString() ?? '')).toBe('');
  await menu.getByRole('menuitem', {name: 'Remove'}).tap();
  const dialog = page.getByRole('alertdialog', {name: 'Remove Priya?'});
  await expect(dialog.getByRole('checkbox')).not.toBeChecked();
  await dialog.getByRole('button', {name: 'Remove'}).tap();
  await expect(row(page, 'Priya Raman')).toHaveCount(0, {timeout: 500});
  expect((await sent(page)).filter(intent => intent.type === 'remove_friend')).toEqual([
    {type: 'remove_friend', fields: {conversation_id: 'c_priya'}},
  ]);
  await page.waitForTimeout(1000);
  await expect(row(page, 'Priya Raman')).toHaveCount(0);
  expect(errors).toEqual([]);
});

// How people nearby were found (client capability nearby.found), on computers and phones alike.
const found = (methods: string[], label: string) => ({methods, label});
const LAN = found(['lan'], 'Local network');
const BLUETOOTH = found(['bluetooth'], 'Bluetooth');
const BOTH = found(['lan', 'bluetooth'], 'Local network and Bluetooth');
const nearbyFound = {
  ...nearby,
  data: {
    ...nearby.data,
    people: nearby.data.people.map((person: {title: string}) => ({
      ...person,
      found: {'Kenji Sato': LAN, 'Lena Weber': BLUETOOTH, 'Tomás Rivera': BOTH}[person.title] ?? null,
    })),
  },
};
const listFound = {
  ...frame,
  data: {
    ...frame.data,
    rows: frame.data.rows.map((row: {conversation_id: string; route: unknown}) => ({
      ...row,
      // Daniel nearby over Bluetooth, so the list draws that route icon to compare with.
      route: row.conversation_id === 'c_daniel' ? {kind: 'local', method: 'bluetooth', label: 'Nearby, over Bluetooth'} : row.route,
      found: {c_mei: LAN, c_kenji: BOTH, c_daniel: BLUETOOTH}[row.conversation_id] ?? null,
    })),
  },
};

test('rows say how each person nearby was found, with the route icon of each method', async ({page}) => {
  const errors = await install(page, {delay: 0, frame: listFound, nearby: nearbyFound});
  const shown = (scope: ReturnType<Page['locator']>) =>
    scope.locator('.szf-found').evaluateAll(lines =>
      lines.map(line => ({
        text: (line as HTMLElement).innerText.trim(),
        icons: [...line.querySelectorAll('svg path')].map(path => path.getAttribute('d')),
      })),
    );
  // The route icons the list already draws: Mei's route is the local network, Daniel's Bluetooth.
  const routeIcon = (name: string) => row(page, name).locator('.szf-route svg path').getAttribute('d');
  const lan = await routeIcon('Mei Lin');
  const bluetooth = await routeIcon('Daniel Ortiz');
  expect(lan).not.toEqual(bluetooth);

  expect(await shown(row(page, 'Mei Lin'))).toEqual([{text: 'Local network', icons: [lan]}]);
  expect(await shown(row(page, 'Kenji Sato'))).toEqual([{text: 'Local network and Bluetooth', icons: [lan, bluetooth]}]);
  expect(await shown(row(page, 'Daniel Ortiz'))).toEqual([{text: 'Bluetooth', icons: [bluetooth]}]);
  // Friends not nearby say nothing about it.
  await expect(row(page, 'Priya Raman').locator('.szf-found')).toHaveCount(0);
  await expect(row(page, 'Mei Lin').locator('.szf-row-subtitle')).toBeVisible();

  await page.getByRole('tab', {name: 'Nearby'}).click();
  const person = (name: string) => page.locator('.szf-nearby .szf-row', {hasText: name});
  await expect(person('Lena Weber')).toBeVisible();
  expect(await shown(person('Kenji Sato'))).toEqual([{text: 'Local network', icons: [lan]}]);
  expect(await shown(person('Lena Weber'))).toEqual([{text: 'Bluetooth', icons: [bluetooth]}]);
  expect(await shown(person('Tomás Rivera'))).toEqual([{text: 'Local network and Bluetooth', icons: [lan, bluetooth]}]);
  await expect(person('coral')).toBeVisible();
  await expect(person('coral').locator('.szf-found')).toHaveCount(0);
  // The words fit the row: nothing spills past the panel.
  const overflow = await page.locator('.szf-nearby .szf-found').evaluateAll(lines =>
    lines.some(line => {
      const box = line.getBoundingClientRect();
      const panel = line.closest('.szf-panel')!.getBoundingClientRect();
      return box.right > panel.right || box.left < panel.left;
    }),
  );
  expect(overflow).toBe(false);
  expect(errors).toEqual([]);
});
