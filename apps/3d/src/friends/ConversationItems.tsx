// What a conversation's history shows: messages, cut short when long, and transfers with their previews, and the
// menu for a link in a friend's message.
import { useEffect, useState } from "react";
import type { Item, Mention } from "./protocol";
import { fill } from "./actions";
import { Actions, RichText, linkHost, shownHost, usePanel } from "./parts";

// A message longer than this shows cut short with Show all, so a conversation stays quick to open.
const SHORT_TEXT = 3000;

export function ItemView({
  item,
  onLink,
  onMention,
}: {
  item: Item;
  onLink(url: string, text: string): void;
  onMention(mention: Mention): void;
}) {
  const { store } = usePanel();
  const [all, setAll] = useState(false);
  if (item.kind === "day")
    return (
      <div
        className="szf-day"
        data-item={item.item_id}
        role="heading"
        aria-level={3}
        aria-label={item.accessibility_label}
      >
        {item.label}
      </div>
    );
  if (item.kind === "event")
    return (
      <div
        className="szf-event"
        data-item={item.item_id}
        aria-label={item.accessibility_label}
      >
        <span>{item.text}</span>
        {item.time_label && <small>{item.time_label}</small>}
      </div>
    );
  if (item.kind === "transfer") return <TransferView item={item} />;
  if (item.kind !== "message") return null;
  const segments = item.segments ?? [{ text: item.text ?? "" }];
  const long =
    !all && (item.text?.length ?? 0) > SHORT_TEXT && store.strings.show_all;
  const shown = long ? cut(segments, SHORT_TEXT) : segments;
  return (
    <div
      className={`szf-message ${item.direction} ${item.highlighted ? "highlighted" : ""}`}
      data-item={item.item_id}
      aria-label={item.accessibility_label}
    >
      <div className="szf-bubble">
        <RichText
          segments={shown}
          mentions={item.mentions}
          onLink={(url, text) => onLink(url, text)}
          onMention={(mention) => onMention(mention)}
        />
        {long && (
          <button
            type="button"
            className="szf-button link"
            onClick={() => setAll(true)}
          >
            {store.strings.show_all}
          </button>
        )}
      </div>
      <div className="szf-meta">
        {item.time_label && <span>{item.time_label}</span>}
        {item.status && (
          <span className={`szf-status ${item.status.state}`}>
            {item.status.label}
          </span>
        )}
        {item.assistant_label && <span>{item.assistant_label}</span>}
      </div>
      <Actions actions={item.actions} context={{ item_id: item.item_id }} />
    </div>
  );
}
function cut(segments: { text: string }[], limit: number) {
  const out = [];
  let left = limit;
  for (const segment of segments) {
    if (left <= 0) break;
    out.push(
      segment.text.length > left
        ? { ...segment, text: segment.text.slice(0, left) + "…" }
        : segment,
    );
    left -= segment.text.length;
  }
  return out;
}

function TransferView({ item }: { item: Item }) {
  return (
    <div
      className={`szf-transfer ${item.direction} ${item.highlighted ? "highlighted" : ""}`}
      data-item={item.item_id}
      aria-label={item.accessibility_label}
    >
      <div className="szf-transfer-body">
        <Preview item={item} />
        <div className="szf-transfer-text">
          <strong>{item.file?.name}</strong>
          <small>{item.meta_label}</small>
          <span className="szf-status">{item.status_label}</span>
          {item.route_note && <small>{item.route_note}</small>}
          {item.assistant_label && <small>{item.assistant_label}</small>}
        </div>
      </div>
      {item.progress && (
        <progress
          className="szf-progress"
          aria-label={item.progress.accessibility_label}
          value={item.progress.determinate ? item.progress.fraction : undefined}
          max={1}
        />
      )}
      <Actions
        actions={item.actions}
        context={{ transfer_id: item.transfer_id, item_id: item.item_id }}
      />
      {item.time_label && <small className="szf-meta">{item.time_label}</small>}
    </div>
  );
}

/** The sender's picture or one made here, at most 64 points and never more than one point per pixel. */
function Preview({ item }: { item: Item }) {
  const thumbnail = item.thumbnail;
  const panel = usePanel();
  const [url, setURL] = useState<string | null>(null);
  useEffect(() => {
    if (!thumbnail) return setURL(null);
    let active = true;
    void panel.bridge
      .image("thumbnail", thumbnail.path, thumbnail.width, thumbnail.height)
      .then(async (image) => {
        if (!image || !active) return;
        const blob = new Blob([new Uint8Array(image.bytes)], {
          type: image.type,
        });
        const bitmap = await createImageBitmap(blob);
        const ok =
          bitmap.width === thumbnail.width &&
          bitmap.height === thumbnail.height;
        bitmap.close();
        if (ok && active) setURL(URL.createObjectURL(blob));
      })
      .catch(() => {});
    return () => {
      active = false;
    };
  }, [panel.bridge, thumbnail]);
  useEffect(() => () => void (url && URL.revokeObjectURL(url)), [url]);
  if (thumbnail && url) {
    const scale = Math.min(1, 64 / Math.max(thumbnail.width, thumbnail.height));
    return (
      <img
        className="szf-thumbnail"
        src={url}
        alt=""
        width={Math.round(thumbnail.width * scale)}
        height={Math.round(thumbnail.height * scale)}
        draggable={false}
      />
    );
  }
  // No preview: the type's icon, drawn here from the file's extension.
  return (
    <span className="szf-file-icon">
      {(item.file?.extension ?? "").slice(0, 4).toUpperCase()}
    </span>
  );
}

/** A link in a friend's message: its real destination first, then Open (PROTOCOL.md § Static strings). */
export function LinkMenu({
  url,
  text,
  onClose,
}: {
  url: string;
  text: string;
  onClose(): void;
}) {
  const { store, bridge } = usePanel();
  const strings = store.strings;
  const real = linkHost(url);
  const shown = shownHost(text);
  if (!real) return null;
  const elsewhere = shown && shown.toLowerCase() !== real.host.toLowerCase();
  return (
    <div className="szf-popover" role="dialog">
      {elsewhere && (
        <strong>
          {fill(strings.link_elsewhere, { host: real.host, shown })}
        </strong>
      )}
      <span className="szf-url">{url}</span>
      <div className="szf-actions">
        <button
          type="button"
          className="szf-button primary"
          onClick={() => {
            void bridge.openURL(url);
            onClose();
          }}
        >
          {real.email ? strings.link_open_email : strings.link_open}
        </button>
        {strings.cancel && (
          <button type="button" className="szf-button link" onClick={onClose}>
            {strings.cancel}
          </button>
        )}
      </div>
    </div>
  );
}
