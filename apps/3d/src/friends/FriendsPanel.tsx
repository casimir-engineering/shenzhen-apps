// The Friends dropdown and the Friends part of Settings: the lazily loaded half of Friends. FriendsButton.tsx (in
// the app's first chunk) loads this file only when the person opens Friends or Settings, so none of it is on the
// launch path.
import { useEffect, useMemo, useRef, useState } from "react";
import { friendsRequests } from "./requests";
import type { FriendsBridge } from "./bridge";
import type {
  Confirm,
  FriendsStatus,
  NotificationSettings,
  Reply,
  SettingsData,
} from "./protocol";
import {
  ActionButton,
  AvatarView,
  CopyButton,
  Panel,
  usePanel,
  type ConfirmAnswer,
  type PanelContext,
} from "./parts";
import { shownOption } from "./actions";
import { FriendsStore, useFriendsStore, useView } from "./store";
import { ListPage, type Outgoing } from "./ListPage";
import { ConversationPage } from "./ConversationPage";
import { DetailsPage, JoinPage, LinkPage } from "./MorePages";
import { ProfilePage } from "./ProfilePage";
import type { AttachSource } from "./Composer";
import "./friends.css";
import "./friends-chat.css";
import "./friends-pages.css";

let shared: FriendsStore | undefined;
/** One store per page: the button's status seeds it, and it follows the bridge's events from then on. */
export function friendsStore(bridge: FriendsBridge, status: FriendsStatus) {
  if (!shared) {
    shared = new FriendsStore(bridge, status);
    bridge.subscribe((event) => shared!.handle(event));
  }
  return shared;
}

type Page =
  | { kind: "list" }
  | { kind: "conversation"; id: string; messageId?: string }
  | { kind: "details"; id: string }
  | { kind: "profile" }
  | { kind: "join" }
  | { kind: "link"; payload: string };
// Reopening returns to the view the person left (brief § Interface).
let remembered: { stack: Page[]; tab: "friends" | "nearby" } = {
  stack: [{ kind: "list" }],
  tab: "friends",
};
/** Where the dropdown opens next: the profile page (Add by ID), the list's Nearby tab or the join view
 * (requests.ts). */
export function openNextAt(place: "profile" | "nearby" | "join") {
  remembered =
    place === "nearby"
      ? { stack: [{ kind: "list" }], tab: "nearby" }
      : { stack: [{ kind: "list" }, { kind: place }], tab: remembered.tab };
}

/** Whether this window is visible and has the keyboard focus (PROTOCOL.md § Notifications, Focus): `onChange`
 * now and on every change. Returns a function that stops watching. */
export function watchWindowFocus(
  onChange: (focused: boolean) => void,
  doc: Pick<Document, "visibilityState" | "hasFocus"> & EventTarget = document,
  win: EventTarget = window,
) {
  const update = () =>
    onChange(doc.visibilityState === "visible" && doc.hasFocus());
  update();
  doc.addEventListener("visibilitychange", update);
  win.addEventListener("focus", update);
  win.addEventListener("blur", update);
  return () => {
    doc.removeEventListener("visibilitychange", update);
    win.removeEventListener("focus", update);
    win.removeEventListener("blur", update);
  };
}
function useWindowFocused() {
  const [focused, setFocused] = useState(false);
  useEffect(() => watchWindowFocus(setFocused), []);
  return focused;
}
/** What a notification's conversation opens: the list, and that conversation over it (the list alone for null). */
export function stackFor(openAt: { conversation_id: string | null }): Page[] {
  const id = openAt.conversation_id;
  return id
    ? [{ kind: "list" }, { kind: "conversation", id }]
    : [{ kind: "list" }];
}

function useConfirm() {
  const [pending, setPending] = useState<{
    confirm: Confirm;
    resolve(value: ConfirmAnswer): void;
  } | null>(null);
  // The confirmation's checkbox ("Also delete chat history"), unticked each time it opens.
  const [ticked, setTicked] = useState(false);
  const ask = (confirm: Confirm) =>
    new Promise<ConfirmAnswer>((resolve) => {
      setTicked(false);
      setPending({ confirm, resolve });
    });
  const option = shownOption(pending?.confirm);
  const view = pending ? (
    <div
      className="szf-confirm"
      role="alertdialog"
      aria-label={pending.confirm.title}
    >
      <div className="szf-confirm-box">
        <strong>{pending.confirm.title}</strong>
        <p>{pending.confirm.body}</p>
        {option && (
          <label className="szf-confirm-option">
            <input
              type="checkbox"
              checked={ticked}
              onChange={(event) => setTicked(event.target.checked)}
            />
            <span>{option.label}</span>
          </label>
        )}
        <div className="szf-actions">
          <button
            type="button"
            className="szf-button secondary"
            onClick={() => {
              pending.resolve(false);
              setPending(null);
            }}
          >
            {pending.confirm.cancel_label}
          </button>
          <button
            type="button"
            autoFocus
            className={`szf-button ${pending.confirm.destructive ? "destructive" : "primary"}`}
            onClick={() => {
              pending.resolve({ option: Boolean(option) && ticked });
              setPending(null);
            }}
          >
            {pending.confirm.confirm_label}
          </button>
        </div>
      </div>
    </div>
  ) : null;
  return { ask, view, open: Boolean(pending) };
}

function usePanelContext(
  store: FriendsStore,
  openConversation: (id: string, messageId?: string) => void,
  confirm: (confirm: Confirm) => Promise<ConfirmAnswer>,
  openJoin: () => void,
) {
  const [notice, setNotice] = useState<string | null>(null);
  useEffect(() => {
    if (!notice) return;
    const timer = window.setTimeout(() => setNotice(null), 6000);
    return () => window.clearTimeout(timer);
  }, [notice]);
  const context = useMemo<PanelContext>(
    () => ({
      store,
      bridge: store.bridge,
      // Only the helper's display-ready words; a failure without words says nothing, and the connection line
      // covers not_ready and connection_lost.
      report: (reply: Reply) => {
        if (!reply.ok && reply.error?.message) setNotice(reply.error.message);
      },
      openConversation,
      confirm,
      openJoin,
    }),
    [store, openConversation, confirm, openJoin],
  );
  return {
    context,
    notice,
    clearNotice: () => setNotice(null),
    showNotice: setNotice,
  };
}

export default function FriendsPanel({
  bridge,
  status,
  outgoing,
  link,
  openAt = null,
  onOpenAtDone,
  attach,
  onClose,
  onOutgoingDone,
  onLinkDone,
  refusal = null,
  onRefusalShown,
}: {
  bridge: FriendsBridge;
  status: FriendsStatus;
  outgoing: Outgoing | null;
  link: string | null;
  /** A notification's conversation to show (null: the list). */
  openAt?: { conversation_id: string | null } | null;
  onOpenAtDone?(): void;
  attach: AttachSource | null;
  onClose(): void;
  onOutgoingDone(): void;
  onLinkDone(): void;
  /** Why files dropped on the Friends button were not taken (a folder, a link). */
  refusal?: string | null;
  onRefusalShown?(): void;
}) {
  const store = useFriendsStore(friendsStore(bridge, status));
  const [stack, setStack] = useState<Page[]>(remembered.stack);
  const [tab, setTab] = useState(remembered.tab);
  const confirm = useConfirm();
  const push = (page: Page) => setStack((old) => [...old, page]);
  const pop = () =>
    setStack((old) => (old.length > 1 ? old.slice(0, -1) : old));
  const openConversation = useMemo(
    () => (id: string, messageId?: string) =>
      setStack((old) => {
        const base = old.filter((page) => page.kind === "list");
        return [
          ...(base.length ? base : [{ kind: "list" as const }]),
          { kind: "conversation", id, messageId },
        ];
      }),
    [],
  );
  const openJoin = useMemo(
    () => () => setStack([{ kind: "list" }, { kind: "join" }]),
    [],
  );
  const { context, notice, clearNotice, showNotice } = usePanelContext(
    store,
    openConversation,
    confirm.ask,
    openJoin,
  );
  useEffect(() => {
    if (!refusal) return;
    showNotice(refusal);
    onRefusalShown?.();
  }, [refusal, onRefusalShown, showNotice]);

  useEffect(() => {
    remembered = { stack, tab };
  }, [stack, tab]);
  // The person opened Friends: Nearby may start now (and may ask for permission the first time, never at launch).
  useEffect(() => {
    if (store.ready) void store.send("activate");
  }, [store, store.ready]);
  useEffect(() => {
    if (link) {
      setStack([{ kind: "list" }, { kind: "link", payload: link }]);
      onLinkDone();
    }
  }, [link, onLinkDone]);
  useEffect(() => {
    if (!openAt) return;
    setTab("friends");
    setStack(stackFor(openAt));
    onOpenAtDone?.();
  }, [openAt, onOpenAtDone]);
  useEffect(() => {
    if (outgoing) setStack([{ kind: "list" }]);
  }, [outgoing]);
  useEffect(() => {
    const key = (event: KeyboardEvent) => {
      if (confirm.open) return;
      // Escape closes; it never navigates back. Cmd+[ goes back one level.
      if (event.key === "Escape") {
        event.preventDefault();
        if (outgoing) onOutgoingDone();
        else onClose();
      } else if (event.key === "[" && (event.metaKey || event.ctrlKey)) {
        event.preventDefault();
        pop();
      }
    };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, [onClose, onOutgoingDone, outgoing, confirm.open]);

  const page = stack[stack.length - 1];
  // The conversation the person is looking at, while this window is in front: no notification for it.
  const focused = useWindowFocused();
  const looking = focused && page.kind === "conversation" ? page.id : null;
  useEffect(() => store.setFocus(looking), [store, looking]);
  useEffect(() => () => store.setFocus(null), [store]);
  const notReady = !store.ready && store.status.text;
  return (
    <Panel.Provider value={context}>
      <div
        className="szf-panel"
        data-szfriends="dropdown"
        role="dialog"
        aria-label={store.strings.button_label}
        // Files dragged over Friends belong to Friends' own targets, never to the viewer's "Drop to open".
        onDragOver={(event) => event.stopPropagation()}
        onDrop={(event) => {
          event.preventDefault();
          event.stopPropagation();
        }}
      >
        {notReady ? (
          <div className="szf-connection" role="status">
            {store.status.text}
          </div>
        ) : null}
        {notice && (
          <button
            type="button"
            className="szf-notice"
            role="status"
            onClick={clearNotice}
          >
            {notice}
          </button>
        )}
        {page.kind === "list" && (
          <ListPage
            tab={tab}
            onTab={setTab}
            outgoing={outgoing}
            onCancelOutgoing={onOutgoingDone}
            onSent={(id) => {
              onOutgoingDone();
              openConversation(id);
            }}
            onProfile={() => push({ kind: "profile" })}
          />
        )}
        {page.kind === "conversation" && (
          <ConversationPage
            key={`${page.id}:${page.messageId ?? ""}`}
            conversationId={page.id}
            messageId={page.messageId}
            attach={attach}
            onBack={pop}
            onDetails={() => push({ kind: "details", id: page.id })}
          />
        )}
        {page.kind === "details" && (
          <DetailsPage conversationId={page.id} onBack={pop} />
        )}
        {page.kind === "profile" && <ProfilePage onBack={pop} />}
        {page.kind === "join" && <JoinPage onBack={pop} />}
        {page.kind === "link" && (
          <LinkPage
            payload={page.payload}
            onBack={pop}
            onOpened={(id) => openConversation(id)}
          />
        )}
        {confirm.view}
      </div>
    </Panel.Provider>
  );
}

/** The Friends part of the app's Settings. The switch and the disclosure are Shenzhen 3D's own words, because they
 * show while Friends is off and no helper runs; everything under them comes from the helper. */
export function FriendsSettings({
  bridge,
  status,
  onEnabled,
}: {
  bridge: FriendsBridge;
  status: FriendsStatus;
  onEnabled(status: FriendsStatus): void;
}) {
  const store = useFriendsStore(friendsStore(bridge, status));
  const confirm = useConfirm();
  const section = useRef<HTMLElement>(null);
  // The join view is in the dropdown: Settings closes, and the dropdown opens on it.
  const openJoin = useMemo(
    () => () => {
      section.current?.closest("dialog")?.close();
      friendsRequests.request("join");
    },
    [],
  );
  const { context, notice } = usePanelContext(
    store,
    () => {},
    confirm.ask,
    openJoin,
  );
  const enabled = store.status.enabled;
  return (
    <Panel.Provider value={context}>
      <section className="szf-settings" data-szfriends="settings" ref={section}>
        <label className="szf-switch">
          <input
            type="checkbox"
            checked={enabled}
            onChange={async (event) => {
              const next = await bridge.setEnabled(event.target.checked);
              store.setStatus(next);
              onEnabled(next);
            }}
          />
          <span>
            <strong>
              Enable Shenzhen Friends <span className="szf-beta">Beta</span>
            </strong>
            <small>
              Shenzhen 3D connects to the Friends server whenever it is open and
              Friends is on. The server sees your network address, your Friends
              ID and when Shenzhen 3D is open. It never sees your name, messages
              or files. Friends is in beta, so things may still change.
            </small>
          </span>
        </label>
        {enabled && store.ready && <SettingsBody />}
        {enabled && !store.ready && store.status.text && (
          <small>{store.status.text}</small>
        )}
        {notice && <small className="szf-refusal">{notice}</small>}
        {confirm.view}
      </section>
    </Panel.Provider>
  );
}

export function SettingsBody() {
  const panel = usePanel();
  const { store } = panel;
  const data = useView<SettingsData>(store, "settings", {
    type: "subscribe",
    fields: { view: "settings" },
  });
  const [name, setName] = useState<string | null>(null);
  const [changing, setChanging] = useState(false);
  if (!data) return null;
  return (
    <div className="szf-form">
      <form
        className="szf-field"
        onSubmit={async (event) => {
          event.preventDefault();
          if (name === null) return;
          const reply = await store.send("set_name", { name });
          panel.report(reply);
          if (reply.ok) setName(null);
        }}
      >
        <label>
          <span>{data.name.label}</span>
          <input
            value={name ?? data.name.value ?? ""}
            placeholder={data.name.placeholder}
            onChange={(event) => setName(event.target.value)}
            onBlur={(event) => event.currentTarget.form?.requestSubmit()}
          />
        </label>
        <small>{data.name.note}</small>
      </form>
      <div className="szf-field">
        <span>{data.id.label}</span>
        <span className="szf-line">
          <strong className="szf-id">{data.id.friends_id}</strong>
          <CopyButton value={data.id.friends_id} label={data.id.copy_label} />
        </span>
        <small>{data.id.note}</small>
      </div>
      <div className="szf-field">
        <span>{data.received.label}</span>
        {data.received.value && (
          <strong
            className="szf-folder"
            title={data.received.path ?? undefined}
          >
            {data.received.value}
          </strong>
        )}
        {data.received.note && <small>{data.received.note}</small>}
        {(data.received.action || data.received.change) && (
          <span className="szf-inline">
            {data.received.change && (
              <ActionButton
                action={{
                  ...data.received.change,
                  path: data.received.path ?? undefined,
                }}
              />
            )}
            {data.received.action && (
              <ActionButton action={data.received.action} />
            )}
          </span>
        )}
      </div>
      <div className="szf-field">
        <span>{data.auto_accept.label}</span>
        <small>{data.auto_accept.note}</small>
        {/* Without friends there is no switch to show: the note says where to turn it on. */}
        {data.auto_accept.friends.length > 0 && (
          <button
            type="button"
            className="szf-button secondary"
            aria-expanded={changing}
            onClick={() => setChanging((old) => !old)}
          >
            {data.auto_accept.action_label}
          </button>
        )}
        {changing &&
          data.auto_accept.friends.map((friend) => (
            <label key={friend.conversation_id} className="szf-switch compact">
              <input
                type="checkbox"
                checked={friend.enabled}
                onChange={async (event) =>
                  panel.report(
                    await store.send("set_auto_accept", {
                      conversation_id: friend.conversation_id,
                      enabled: event.target.checked,
                    }),
                  )
                }
              />
              <AvatarView avatar={friend.avatar} size={20} />
              <span>{friend.title}</span>
            </label>
          ))}
      </div>
      {data.notifications && (
        <NotificationSettingsField notifications={data.notifications} />
      )}
      {data.join && (
        <div className="szf-field">
          <span>{data.join.label}</span>
          <small>{data.join.note}</small>
          <ActionButton action={data.join.action} />
        </div>
      )}
      <div className="szf-field">
        <span>{data.history.label}</span>
        <small>{data.history.note}</small>
        <ActionButton
          action={{
            action: "delete_history",
            label: data.history.action_label,
            style: "destructive",
            confirm: data.history.confirm,
          }}
        />
      </div>
      <div className="szf-field">
        <span>{data.reset.label}</span>
        <small>{data.reset.note}</small>
        <ActionButton
          action={{
            action: "reset_friends",
            label: data.reset.action_label,
            style: "destructive",
            confirm: data.reset.confirm,
          }}
        />
      </div>
    </div>
  );
}

type NotificationField = "enabled" | "preview" | "background";
/** Settings' Notifications switches the helper sent, in order, each with its note (the iPhone has no background). */
export function notificationSwitches(notifications: NotificationSettings) {
  const all: [NotificationField, NotificationSettings["background"]][] = [
    ["enabled", { note: "", ...notifications.enabled }],
    ["preview", notifications.preview],
    ["background", notifications.background],
  ];
  return all.flatMap(([field, item]) =>
    item && typeof item.value === "boolean" && item.label
      ? [
          {
            field,
            label: item.label,
            note: item.note || null,
            value: item.value,
          },
        ]
      : [],
  );
}
/** One switch turned: set_notifications with that field alone. */
export async function setNotification(
  panel: PanelContext,
  field: NotificationField,
  value: boolean,
) {
  const reply = await panel.store.send("set_notifications", { [field]: value });
  panel.report(reply);
  return reply;
}

/** Settings' Notifications: this device's switches, each sent alone with set_notifications, and the permission's
 * note with its one action. Only what the helper sends shows. */
function NotificationSettingsField({
  notifications,
}: {
  notifications: NotificationSettings;
}) {
  const panel = usePanel();
  return (
    <div className="szf-field" data-szfriends="notifications">
      {notifications.label && <span>{notifications.label}</span>}
      {notificationSwitches(notifications).map(
        ({ field, label, note, value }) => (
          <label key={field} className="szf-switch">
            <input
              type="checkbox"
              name={field}
              checked={value}
              onChange={(event) =>
                void setNotification(panel, field, event.target.checked)
              }
            />
            <span>
              {label}
              {note && <small>{note}</small>}
            </span>
          </label>
        ),
      )}
      {notifications.note && <small>{notifications.note}</small>}
      {notifications.action && <ActionButton action={notifications.action} />}
    </div>
  );
}
