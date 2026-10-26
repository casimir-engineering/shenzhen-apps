// The end of a Friends conversation in the real app (Chromium, headless): Mei's messages arriving below a history
// scrolled up leave it where it is and a pill counts them ("New message ↓", "3 new messages ↓"); the pill scrolls to
// the first of them and goes; sending from the top takes the history to its end. The bridge is a stand-in answering
// with the pinned PROTOCOL fixtures, plus the two pill strings a helper at this shenzhen-pdf commit sends.
import {test, expect, type Page} from '@playwright/test';
import {readFileSync} from 'node:fs';
import {resolve} from 'node:path';

const fixtures = resolve('tests/fixtures/friends');
const read = (file: string) => JSON.parse(readFileSync(resolve(fixtures, file), 'utf8'));
const welcome = read('frames/welcome.json');
const strings = {...welcome.strings, new_message: 'New message ↓', new_messages: '{count} new messages ↓'};
const list = read('snapshots/list.json');
const mei = read('snapshots/conversation-mei.json');
const template = mei.data.items[3];
const said = (id: string, direction: string, text: string) => ({
  ...template,
  item_id: id,
  direction,
  text,
  segments: [{text}],
  accessibility_label: text,
});
const older = Array.from({length: 24}, (_, i) =>
  said(`m_old_${i}`, 'in', `Older message ${i}, long enough to wrap onto a second line of the panel.`));
const items = (...extra: unknown[]) => [mei.data.items[0], ...older, ...mei.data.items.slice(1), ...extra];

async function install(page: Page) {
  await page.addInitScript(
    ({status, list, conversation}) => {
      const listeners = new Set<(event: unknown) => void>();
      let next = 0;
      let subscription = '';
      const reply = (result: unknown) => ({type: 'reply', re: String(++next), ok: true, result});
      (window as unknown as {pushConversation: (data: unknown) => void}).pushConversation = data => {
        conversation = {...conversation, rev: conversation.rev + 1, data};
        for (const listener of listeners) listener({kind: 'snapshot', frame: {...conversation, subscription}});
      };
      (window as unknown as {shenzhenFriends: unknown}).shenzhenFriends = {
        join: async () => status,
        status: async () => status,
        subscribe(listener: (event: unknown) => void) {
          listeners.add(listener);
          return () => listeners.delete(listener);
        },
        async send(type: string, fields?: Record<string, unknown>) {
          if (type === 'subscribe' && fields?.view === 'list')
            return {reply: reply({subscription: 's_list'}), snapshot: {...list, subscription: 's_list'}};
          if (type === 'open_conversation') {
            subscription = `s_conv_${next}`;
            return {reply: reply({subscription}), snapshot: {...conversation, subscription}};
          }
          if (type === 'subscribe') return {reply: reply({subscription: `s_${next}`})};
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
      status: {available: true, enabled: true, attached: true, state: 'ready', text: '', strings,
               capabilities: welcome.capabilities, limits: welcome.limits, badge: null},
      list,
      conversation: {...mei, data: {...mei.data, items: items()}},
    },
  );
}

const history = (page: Page) => page.locator('.szf-history');
const push = (page: Page, ...extra: unknown[]) =>
  page.evaluate(data => (window as unknown as {pushConversation: (d: unknown) => void}).pushConversation(data),
                {...mei.data, items: items(...extra)});
const scrollTop = (page: Page) => history(page).evaluate(element => element.scrollTop);
/** Scrolls the history to its top the way a person does, with the wheel, and waits until the page has seen it. */
async function readFromTop(page: Page) {
  await history(page).hover();
  await page.mouse.wheel(0, -20000);
  await expect.poll(() => scrollTop(page)).toBeLessThan(4);
  await page.waitForTimeout(200);
}
const atEnd = (page: Page) =>
  history(page).evaluate(element => element.scrollHeight - element.scrollTop - element.clientHeight < 4);

test('new messages below a conversation scrolled up: the pill counts them and takes the person there; sending goes to the end', async ({page, isMobile}, info) => {
  await install(page);
  await page.goto('/');
  await page.locator('[data-szfriends="button"]').click();
  await page.locator('.szf-row', {hasText: 'Mei Lin'}).click();
  await expect(history(page)).toBeVisible();
  await expect.poll(() => atEnd(page)).toBe(true);
  const pill = page.locator('.szf-new-messages');
  await expect(pill).toHaveCount(0);

  await readFromTop(page);
  await push(page, said('m_new_1', 'in', 'First new message from Mei.'));
  await expect(pill).toHaveText('New message ↓');
  expect(await scrollTop(page)).toBeLessThan(4);
  await push(page, said('m_new_1', 'in', 'First new message from Mei.'), said('m_new_2', 'in', 'Second.'),
             said('m_new_3', 'in', 'Third.'));
  await expect(pill).toHaveText('3 new messages ↓');
  await page.screenshot({path: info.outputPath(`friends-new-messages-${isMobile ? 'phone' : 'computer'}.png`)});

  await pill.click();
  const first = page.locator('[data-item="m_new_1"]');
  await expect(first).toBeInViewport();
  await expect(pill).toHaveCount(0);

  await readFromTop(page);
  await push(page, said('m_new_1', 'in', 'First new message from Mei.'), said('m_new_2', 'in', 'Second.'),
             said('m_new_3', 'in', 'Third.'), said('m_sent', 'out', 'A reply sent from the top of the conversation.'));
  await expect.poll(() => atEnd(page)).toBe(true);
  await expect(pill).toHaveCount(0);
});
