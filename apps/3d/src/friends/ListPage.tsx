// The list view: search, Friends and Nearby tabs, the rows sorted by the helper, and the footer (brief § Interface).
import { useEffect, useRef, useState } from "react";
import type { KeyboardEvent as ReactKeyboardEvent } from "react";
import type {
  Action,
  ListData,
  ListRow,
  NearbyData,
  RowAction,
} from "./protocol";
import { actionIntent, CLIENT_ACTIONS, dropLabel } from "./actions";
import {
  ActionButton,
  AvatarView,
  useArm,
  usePanel,
  useRunAction,
} from "./parts";
import { RowMenu, useLongPress, type MenuPoint } from "./RowMenu";
import { FoundLine, Glyph, RouteIcon } from "./glyphs";
import { useView } from "./store";
import {
  dragHasFiles,
  filesFromDrop,
  sendFiles,
  type OutgoingFile,
} from "./drops";
import { FooterView, JoinRequestRow, NamePrompt } from "./ListSections";
import { NearbyPane } from "./NearbyPane";

export type Outgoing = { files: OutgoingFile[]; names: (string | null)[] };

export function ListPage({
  tab,
  onTab,
  outgoing,
  onCancelOutgoing,
  onSent,
  onProfile,
  onJoin,
}: {
  tab: "friends" | "nearby";
  onTab(tab: "friends" | "nearby"): void;
  /** Files waiting for a friend to be chosen ("Send 2 files to…"), from a drop on the button or Share. */
  outgoing: Outgoing | null;
  onCancelOutgoing(): void;
  onSent(conversationId: string): void;
  onProfile(): void;
  onJoin(): void;
}) {
  const panel = usePanel();
  const { store } = panel;
  const strings = store.strings;
  const list = useView<ListData>(store, "list", {
    type: "subscribe",
    fields: { view: "list" },
  });
  const removed = list?.state === "device_removed";
  const showNearby = tab === "nearby" && !removed && !outgoing;
  const nearby = useView<NearbyData>(
    store,
    showNearby ? "nearby" : null,
    showNearby ? { type: "subscribe", fields: { view: "nearby" } } : null,
  );
  const [query, setQuery] = useState("");
  useEffect(() => {
    store.setFilter("list", query);
    if (showNearby) store.setFilter("nearby", query);
  }, [store, query, showNearby]);

  const choose = async (row: ListRow) => {
    if (!outgoing) return panel.openConversation(row.conversation_id);
    if (!row.drop_label) return;
    const reply = await sendFiles(
      panel.bridge,
      row.conversation_id,
      outgoing.files,
    );
    panel.report(reply);
    if (reply.ok) onSent(row.conversation_id);
  };
  const footer = showNearby ? nearby?.footer : list?.footer;

  return (
    <div className="szf-list-page">
      {outgoing ? (
        <div className="szf-outgoing" role="status">
          <span>{dropLabel(strings, outgoing.names)}</span>
          {strings.cancel && (
            <button
              type="button"
              className="szf-button link"
              onClick={onCancelOutgoing}
            >
              {strings.cancel}
            </button>
          )}
        </div>
      ) : null}
      {/* Friends is a beta: the title and its tag say so. An older helper sends neither, and neither shows. */}
      {strings.button_label && (
        <div className="szf-list-title">
          <strong>{strings.button_label}</strong>
          {strings.beta && (
            <span className="szf-beta" data-szfriends="beta">
              {strings.beta}
            </span>
          )}
        </div>
      )}
      <div className="szf-search">
        <input
          type="search"
          value={query}
          placeholder={strings.search_placeholder}
          aria-label={strings.search_placeholder}
          onChange={(event) => setQuery(event.target.value)}
        />
      </div>
      {!removed && !outgoing && (strings.tab_friends || strings.tab_nearby) && (
        <div className="szf-tabs" role="tablist">
          {(["friends", "nearby"] as const).map((name) => (
            <button
              key={name}
              type="button"
              role="tab"
              aria-selected={tab === name}
              className={tab === name ? "active" : ""}
              onClick={() => onTab(name)}
            >
              {name === "friends" ? strings.tab_friends : strings.tab_nearby}
            </button>
          ))}
        </div>
      )}
      <div className="szf-scroll">
        {showNearby ? (
          <NearbyPane data={nearby} />
        ) : (
          <FriendsRows
            list={list}
            outgoing={Boolean(outgoing)}
            onChoose={choose}
            onJoin={onJoin}
          />
        )}
      </div>
      {footer && !outgoing && (
        <FooterView footer={footer} removed={removed} onProfile={onProfile} />
      )}
    </div>
  );
}

function FriendsRows({
  list,
  outgoing,
  onChoose,
  onJoin,
}: {
  list: ListData | undefined;
  outgoing: boolean;
  onChoose(row: ListRow): void;
  onJoin(): void;
}) {
  const { store } = usePanel();
  const run = useRunAction();
  // Rows taken off the list here, shown again if the helper refuses; the next snapshot no longer has them.
  const [hidden, setHidden] = useState<ReadonlySet<string>>(new Set());
  const [menu, setMenu] = useState<{
    row: ListRow;
    at: MenuPoint;
    host: HTMLElement;
    from: HTMLElement;
  } | null>(null);
  const rows = list?.rows;
  useEffect(() => {
    if (!rows) return;
    setHidden((old) => {
      const present = new Set(rows.map((row) => row.conversation_id));
      const kept = [...old].filter((id) => present.has(id));
      return kept.length === old.size ? old : new Set(kept);
    });
  }, [rows]);
  const visible = (rows ?? []).filter(
    (row) => !hidden.has(row.conversation_id),
  );
  const items = (row: ListRow) =>
    outgoing
      ? []
      : (row.menu ?? []).filter(
          (action) =>
            CLIENT_ACTIONS.has(action.action) ||
            actionIntent(action, { conversation_id: row.conversation_id }),
        );
  const openMenu = (row: ListRow, at: MenuPoint, from: HTMLElement) => {
    const host = from.closest<HTMLElement>(".szf-panel") ?? document.body;
    if (!items(row).length) return;
    setMenu((old) =>
      old?.row.conversation_id === row.conversation_id
        ? old
        : { row, at, host, from },
    );
  };
  const choose = async (row: ListRow, action: Action, from: HTMLElement) => {
    const id = row.conversation_id;
    const leaves = action.action === "remove_friend";
    // Where focus goes once the row is gone: the next row, else the one before.
    const index = visible.findIndex((r) => r.conversation_id === id);
    const neighbour = visible[index + 1] ?? visible[index - 1];
    let sent = false;
    const reply = await run(action, { conversation_id: id }, () => {
      sent = true;
      if (!leaves) return;
      setHidden((old) => new Set(old).add(id));
      window.requestAnimationFrame(() =>
        document
          .querySelector<HTMLElement>(
            `[data-conversation-id="${CSS.escape(neighbour?.conversation_id ?? "")}"] .szf-row-main`,
          )
          ?.focus(),
      );
    });
    if (leaves && reply && !reply.ok)
      setHidden((old) => {
        const back = new Set(old);
        back.delete(id);
        return back;
      });
    if (!sent && from.isConnected) from.focus();
  };
  if (!list)
    return store.strings.loading ? (
      <p className="szf-quiet">{store.strings.loading}</p>
    ) : null;
  return (
    <>
      {list.banner && (
        <div className={`szf-banner ${list.banner.kind}`}>
          <p>{list.banner.text}</p>
          {list.banner.action && (
            <ActionButton
              action={list.banner.action}
              context={{ kind: list.banner.kind }}
            />
          )}
        </div>
      )}
      {list.removed && (
        <div className="szf-card">
          <strong>{list.removed.title}</strong>
          <p>{list.removed.body}</p>
          <ActionButton action={list.removed.action} />
        </div>
      )}
      {list.name_prompt && (
        <NamePrompt prompt={list.name_prompt} onJoin={onJoin} />
      )}
      {(list.join_requests ?? []).map((request) => (
        <JoinRequestRow key={request.join_id} request={request} />
      ))}
      {visible.length ? (
        <ul className="szf-rows" role="list">
          {visible.map((row) => (
            <Row
              key={row.conversation_id}
              row={row}
              picking={outgoing}
              hasMenu={items(row).length > 0}
              menuOpen={menu?.row.conversation_id === row.conversation_id}
              onChoose={onChoose}
              onMenu={(at, from) => openMenu(row, at, from)}
              onDelete={(from) => {
                const first = items(row)[0];
                if (first) void choose(row, first, from);
              }}
            />
          ))}
        </ul>
      ) : !list.rows.length && list.empty ? (
        <div className="szf-empty">
          <strong>{list.empty.title}</strong>
          {list.empty.body && <p>{list.empty.body}</p>}
        </div>
      ) : null}
      {menu && (
        <RowMenu
          items={items(menu.row)}
          at={menu.at}
          host={menu.host}
          label={menu.row.title}
          onChoose={(action) => {
            setMenu(null);
            void choose(menu.row, action, menu.from);
          }}
          onClose={(refocus) => {
            setMenu(null);
            if (refocus && menu.from.isConnected) menu.from.focus();
          }}
        />
      )}
    </>
  );
}

function RowActionButton({
  action,
  conversationId,
}: {
  action: RowAction;
  conversationId: string;
}) {
  const panel = usePanel();
  const arming = useArm(action.arm);
  const icon =
    action.icon === "accept"
      ? "check"
      : action.icon === "decline"
        ? "close"
        : action.icon === "block"
          ? "block"
          : null;
  if (
    !icon ||
    !["accept_request", "decline_request", "block"].includes(action.action)
  )
    return null;
  return (
    <button
      type="button"
      className={`szf-row-action ${action.icon} ${arming.armed ? "armed" : ""} ${
        !arming.armed && action.title ? "worded" : ""
      }`}
      title={arming.armed ? action.arm?.accessibility_label : action.label}
      aria-label={arming.armed ? action.arm?.accessibility_label : action.label}
      onMouseLeave={arming.disarm}
      onClick={async (event) => {
        event.stopPropagation();
        if (!arming.click()) return;
        panel.report(
          await panel.store.send(action.action, {
            conversation_id: conversationId,
          }),
        );
      }}
    >
      {arming.armed ? (
        action.arm?.label
      ) : action.title ? (
        action.title
      ) : (
        <Glyph name={icon} size={14} />
      )}
    </button>
  );
}

function Row({
  row,
  picking,
  hasMenu,
  menuOpen,
  onChoose,
  onMenu,
  onDelete,
}: {
  row: ListRow;
  picking: boolean;
  hasMenu: boolean;
  menuOpen: boolean;
  onChoose(row: ListRow): void;
  onMenu(at: MenuPoint, from: HTMLElement): void;
  /** Delete or Backspace on the focused row: the menu's first item (Remove), with its confirmation. */
  onDelete(from: HTMLElement): void;
}) {
  const panel = usePanel();
  const main = useRef<HTMLButtonElement>(null);
  // Under the finger the menu would be hidden: it opens just below the row, where the finger was across.
  const press = useLongPress((at) => {
    if (!main.current) return;
    const box = main.current.getBoundingClientRect();
    onMenu({ x: at.x, y: box.bottom + 2 }, main.current);
  }, hasMenu);
  // From the keyboard the menu opens under the row's name.
  const atRow = (): MenuPoint => {
    const box = main.current!.getBoundingClientRect();
    return { x: box.left + 48, y: box.top + box.height * 0.75 };
  };
  const keys = (event: ReactKeyboardEvent) => {
    if (!hasMenu || !main.current) return;
    if (
      event.key === "ContextMenu" ||
      (event.key === "F10" && event.shiftKey)
    ) {
      event.preventDefault();
      onMenu(atRow(), main.current);
    } else if (
      (event.key === "Delete" || event.key === "Backspace") &&
      !event.metaKey &&
      !event.ctrlKey &&
      !event.altKey
    ) {
      event.preventDefault();
      onDelete(main.current);
    }
  };
  const [dragging, setDragging] = useState(false);
  const [refusal, setRefusal] = useState<string | null>(null);
  const depth = useRef(0);
  const subtitle = dragging
    ? (row.drop_label ?? row.drop_refusal ?? row.subtitle)
    : (refusal ?? row.subtitle);
  return (
    <li
      data-conversation-id={row.conversation_id}
      {...(hasMenu ? press.handlers : {})}
      onContextMenu={(event) => {
        if (!hasMenu || !main.current) return;
        event.preventDefault();
        // A long press on Android also asks for the system's menu: it opens ours, once.
        if (press.pressing()) press.swallowNextClick();
        // From the keyboard (the menu key) the event comes without a pointer position inside the row.
        const box = main.current.getBoundingClientRect();
        const inside =
          event.clientY >= box.top &&
          event.clientY <= box.bottom &&
          event.clientX >= box.left &&
          event.clientX <= box.right;
        onMenu(
          inside ? { x: event.clientX, y: event.clientY } : atRow(),
          main.current,
        );
      }}
      className={[
        "szf-row",
        hasMenu ? "has-menu" : "",
        menuOpen ? "menu-open" : "",
        row.style === "muted" ? "muted" : "",
        row.waiting ? "waiting" : "",
        dragging ? (row.drop_label ? "drop-target" : "drop-refused") : "",
        picking && !row.drop_label ? "unavailable" : "",
      ].join(" ")}
      onDragEnter={(event) => {
        if (!dragHasFiles(event.dataTransfer)) return;
        depth.current++;
        setDragging(true);
      }}
      onDragOver={(event) => {
        if (!dragHasFiles(event.dataTransfer)) return;
        event.preventDefault();
        event.stopPropagation();
        event.dataTransfer.dropEffect = row.drop_label ? "copy" : "none";
      }}
      onDragLeave={() => {
        depth.current = Math.max(0, depth.current - 1);
        if (!depth.current) setDragging(false);
      }}
      onDrop={async (event) => {
        event.preventDefault();
        event.stopPropagation();
        depth.current = 0;
        setDragging(false);
        if (!row.drop_label) return;
        const dropped = await filesFromDrop(
          panel.bridge,
          panel.store.strings,
          event.dataTransfer.files,
        );
        if (dropped.refusal) {
          setRefusal(dropped.refusal);
          window.setTimeout(() => setRefusal(null), 4000);
          return;
        }
        if (dropped.files.length)
          panel.report(
            await sendFiles(panel.bridge, row.conversation_id, dropped.files),
          );
      }}
    >
      <button
        ref={main}
        type="button"
        className="szf-row-main"
        aria-label={row.accessibility_label}
        aria-haspopup={hasMenu ? "menu" : undefined}
        aria-expanded={hasMenu ? menuOpen : undefined}
        onKeyDown={keys}
        disabled={picking && !row.drop_label}
        onClick={() => onChoose(row)}
      >
        <span className="szf-row-avatar">
          <AvatarView
            avatar={row.avatar}
            size={34}
            muted={row.style === "muted"}
          />
          {row.unread && <span className="szf-unread" aria-hidden="true" />}
        </span>
        <span className="szf-row-text">
          <span className="szf-row-title">
            <span>{row.title}</span>
            {row.id_confirmed && row.id_confirmed_label && (
              <span
                className="szf-confirmed"
                title={row.id_confirmed_label}
                role="img"
                aria-label={row.id_confirmed_label}
              >
                <Glyph name="verified" size={12} />
              </span>
            )}
          </span>
          <span
            className={`szf-row-subtitle ${row.waiting || refusal ? "emphasis" : ""}`}
          >
            {subtitle}
          </span>
          <FoundLine found={row.found} />
        </span>
        {!row.actions.length && (
          <span className="szf-row-meta">
            <span className="szf-time">{row.time_label}</span>
            {row.waiting ? (
              <span className="szf-waiting">{row.waiting.label}</span>
            ) : (
              <RouteIcon route={row.route} />
            )}
          </span>
        )}
      </button>
      {row.actions.length > 0 && !picking && (
        <span className="szf-row-actions">
          {row.actions.map((action) => (
            <RowActionButton
              key={action.action}
              action={action}
              conversationId={row.conversation_id}
            />
          ))}
        </span>
      )}
    </li>
  );
}
