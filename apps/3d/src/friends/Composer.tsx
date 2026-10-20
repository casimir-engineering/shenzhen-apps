// The conversation's composer: text, `@` mention chips (one U+FFFC each in the sent text, PROTOCOL.md § Mentions),
// `#` attachment chips from the host's items, and dropped files. Return sends; Shift+Return breaks the line; Escape
// closes the innermost picker first. Drafts and their chips survive leaving the conversation and closing the panel.
import { useEffect, useRef, useState } from "react";
import type { Composer as ComposerData, ListData, ListRow } from "./protocol";
import { utf8Length } from "./actions";
import { AvatarView, RichText, usePanel } from "./parts";
import { useView } from "./store";
import {
  AttachRefused,
  dragHasFiles,
  filesFromDrop,
  type OutgoingFile,
} from "./drops";

export type AttachItem = {
  title: string;
  detail: string;
  kind_label: string;
  /** Prepares the file, or the files a model is made of; nothing is sent until Send. A refusal says why not. */
  file(): Promise<OutgoingFile | OutgoingFile[]>;
};
export type AttachSource = {
  /** The host's words for what `#` searches (PROTOCOL.md § Principles: the host's own placeholder). */
  placeholder: string;
  items(query: string): AttachItem[];
};

type Part = { text: string } | { mention: string; label: string };
type Draft = { parts: Part[]; attachments: OutgoingFile[]; token?: string };
const drafts = new Map<string, Draft>();
const OBJECT_REPLACEMENT = "￼";

function readParts(root: HTMLElement): Part[] {
  const parts: Part[] = [];
  const walk = (node: Node) => {
    if (node.nodeType === Node.TEXT_NODE) {
      parts.push({ text: node.textContent ?? "" });
      return;
    }
    if (!(node instanceof HTMLElement)) return;
    if (node.dataset.mention) {
      parts.push({
        mention: node.dataset.mention,
        label: node.textContent ?? "",
      });
      return;
    }
    if (node.tagName === "BR") {
      parts.push({ text: "\n" });
      return;
    }
    const block =
      node !== root && (node.tagName === "DIV" || node.tagName === "P");
    if (block && parts.length) parts.push({ text: "\n" });
    node.childNodes.forEach(walk);
  };
  root.childNodes.forEach(walk);
  return parts;
}
function writeParts(root: HTMLElement, parts: Part[]) {
  root.replaceChildren(
    ...parts.map((part) =>
      "mention" in part
        ? chip(part.mention, part.label)
        : document.createTextNode(part.text),
    ),
  );
}
function chip(conversationId: string, label: string) {
  const element = document.createElement("span");
  element.className = "szf-chip mention";
  element.contentEditable = "false";
  element.dataset.mention = conversationId;
  element.textContent = label;
  return element;
}
/** The text to send and the friends its chips name, in order: one U+FFFC per chip. */
export function serializeParts(parts: Part[]) {
  let text = "";
  const mentions: { conversation_id: string }[] = [];
  for (const part of parts) {
    if ("mention" in part) {
      // A chip stands for exactly one U+FFFC; one the person typed stays as typed only without mentions.
      text += OBJECT_REPLACEMENT;
      mentions.push({ conversation_id: part.mention });
    } else text += part.text;
  }
  return { text, mentions };
}

/** The word being typed right before the caret when it starts with `@` or `#`, with its range. */
function trigger(): { kind: "@" | "#"; query: string; range: Range } | null {
  const selection = window.getSelection();
  if (!selection?.rangeCount || !selection.isCollapsed) return null;
  const range = selection.getRangeAt(0);
  const node = range.startContainer;
  if (node.nodeType !== Node.TEXT_NODE) return null;
  const before = (node.textContent ?? "").slice(0, range.startOffset);
  const match = /(^|\s)([@#])([^\s@#]{0,40})$/.exec(before);
  if (!match) return null;
  const start = range.startOffset - match[2].length - match[3].length;
  const word = document.createRange();
  word.setStart(node, start);
  word.setEnd(node, range.startOffset);
  return { kind: match[2] as "@" | "#", query: match[3], range: word };
}

export function ComposerView({
  conversationId,
  composer,
  attach,
}: {
  conversationId: string;
  composer: ComposerData;
  attach: AttachSource | null;
}) {
  const panel = usePanel();
  const { store, bridge } = panel;
  const strings = store.strings;
  const editor = useRef<HTMLDivElement>(null);
  const draft = drafts.get(conversationId) ?? { parts: [], attachments: [] };
  const [attachments, setAttachments] = useState<OutgoingFile[]>(
    draft.attachments,
  );
  const [bytes, setBytes] = useState(0);
  const [picker, setPicker] = useState<{
    kind: "@" | "#";
    query: string;
    range: Range;
  } | null>(null);
  const [selected, setSelected] = useState(0);
  const [sending, setSending] = useState(false);
  const [dragging, setDragging] = useState(false);
  const [refusal, setRefusal] = useState<string | null>(null);
  const mentionsOn =
    store.has("mentions") && composer.mention_note !== undefined;
  const mentionKey =
    picker?.kind === "@" ? `mention-picker:${conversationId}` : null;
  const people = useView<ListData>(
    store,
    mentionKey,
    mentionKey ? { type: "subscribe", fields: { view: "list" } } : null,
  );
  useEffect(() => {
    if (mentionKey) store.setFilter(mentionKey, picker?.query ?? "");
  }, [store, mentionKey, picker?.query]);
  const candidates: ListRow[] =
    picker?.kind === "@"
      ? (people?.rows ?? []).filter((row) => row.mentionable)
      : [];
  const items =
    picker?.kind === "#" && attach ? attach.items(picker.query) : [];
  const count = picker?.kind === "@" ? candidates.length : items.length;

  const save = (token?: string) => {
    const root = editor.current;
    if (!root) return;
    const parts = readParts(root);
    const entry = drafts.get(conversationId);
    drafts.set(conversationId, {
      parts,
      attachments,
      token: token ?? entry?.token,
    });
    setBytes(utf8Length(serializeParts(parts).text));
  };
  useEffect(() => {
    const root = editor.current;
    if (!root) return;
    writeParts(root, drafts.get(conversationId)?.parts ?? []);
    setAttachments(drafts.get(conversationId)?.attachments ?? []);
    setBytes(
      utf8Length(serializeParts(drafts.get(conversationId)?.parts ?? []).text),
    );
  }, [conversationId]);
  useEffect(() => {
    const entry = drafts.get(conversationId);
    drafts.set(conversationId, {
      parts: entry?.parts ?? [],
      attachments,
      token: undefined,
    });
  }, [conversationId, attachments]);

  const replaceTrigger = (node: Node | null) => {
    if (!picker) return;
    const range = picker.range;
    range.deleteContents();
    if (node) {
      range.insertNode(node);
      const space = document.createTextNode(" ");
      node.parentNode?.insertBefore(space, node.nextSibling);
      const selection = window.getSelection();
      const caret = document.createRange();
      caret.setStart(space, 1);
      selection?.removeAllRanges();
      selection?.addRange(caret);
    }
    setPicker(null);
    // A changed draft is a new press of Send: its token goes.
    save(undefined);
    const entry = drafts.get(conversationId);
    if (entry) entry.token = undefined;
  };
  const choose = async (index: number) => {
    if (picker?.kind === "@") {
      const row = candidates[index];
      if (row) replaceTrigger(chip(row.conversation_id, `@${row.title}`));
    } else if (picker?.kind === "#") {
      const item = items[index];
      if (!item) return;
      replaceTrigger(null);
      setRefusal(null);
      try {
        const prepared = await item.file();
        const files = Array.isArray(prepared) ? prepared : [prepared];
        setAttachments((old) => [
          ...old.filter((entry) => !files.some((f) => f.path === entry.path)),
          ...files,
        ]);
      } catch (failure) {
        // Nothing was attached. A refusal says why; otherwise the host has said so itself.
        if (failure instanceof AttachRefused) setRefusal(failure.message);
      }
    }
  };

  const send = async () => {
    const root = editor.current;
    if (!root || sending || !composer.enabled) return;
    const parts = readParts(root);
    const { text, mentions } = serializeParts(parts);
    if (!text.trim() && !attachments.length) return;
    if (utf8Length(text) > composer.max_text_bytes) return;
    const entry = drafts.get(conversationId) ?? { parts, attachments };
    // One token per press of Send, kept for retrying that same press after a lost connection.
    entry.token ??= await bridge.token();
    drafts.set(conversationId, { ...entry, parts });
    setSending(true);
    try {
      const fields: Record<string, unknown> = {
        conversation_id: conversationId,
        text,
        client_token: entry.token,
      };
      if (attachments.length) fields.attachments = attachments;
      if (mentions.length) fields.mentions = mentions;
      const reply = await store.send("send_message", fields);
      panel.report(reply);
      if (reply.ok) {
        drafts.delete(conversationId);
        writeParts(root, []);
        setAttachments([]);
        setBytes(0);
      }
    } finally {
      setSending(false);
    }
  };

  if (!composer.visible) return null;
  const over = bytes > composer.max_text_bytes;
  return (
    <div
      className={`szf-composer ${dragging ? "drop-target" : ""}`}
      onDragOver={(event) => {
        if (!composer.accepts_drops || !dragHasFiles(event.dataTransfer))
          return;
        event.preventDefault();
        event.stopPropagation();
        setDragging(true);
      }}
      onDragLeave={() => setDragging(false)}
      onDrop={async (event) => {
        if (!composer.accepts_drops || !dragHasFiles(event.dataTransfer))
          return;
        event.preventDefault();
        event.stopPropagation();
        setDragging(false);
        // On the composer, dropped files become chips; Send sends them with the message.
        const dropped = await filesFromDrop(
          bridge,
          strings,
          event.dataTransfer.files,
        );
        setRefusal(dropped.refusal);
        if (dropped.files.length)
          setAttachments((old) => [
            ...old,
            ...dropped.files.filter(
              (file) => !old.some((entry) => entry.path === file.path),
            ),
          ]);
      }}
    >
      {picker && count > 0 && (
        <div className="szf-picker" role="listbox">
          {picker.kind === "@"
            ? candidates.map((row, index) => (
                <button
                  key={row.conversation_id}
                  type="button"
                  role="option"
                  aria-selected={index === selected}
                  className={index === selected ? "selected" : ""}
                  onMouseDown={(event) => event.preventDefault()}
                  onClick={() => void choose(index)}
                >
                  <AvatarView avatar={row.avatar} size={20} />
                  <span>{row.title}</span>
                </button>
              ))
            : items.map((item, index) => (
                <button
                  key={`${item.title}-${index}`}
                  type="button"
                  role="option"
                  aria-selected={index === selected}
                  className={index === selected ? "selected" : ""}
                  onMouseDown={(event) => event.preventDefault()}
                  onClick={() => void choose(index)}
                >
                  <span className="szf-file-icon small">{item.kind_label}</span>
                  <span>
                    {item.title}
                    <small>{item.detail}</small>
                  </span>
                </button>
              ))}
          <small className="szf-picker-note">
            {picker.kind === "@"
              ? composer.mention_note
              : [strings.attach_note, strings.attach_keys]
                  .filter(Boolean)
                  .join(" · ")}
          </small>
        </div>
      )}
      {picker?.kind === "#" && attach && (
        <small className="szf-picker-hint">{attach.placeholder}</small>
      )}
      {attachments.length > 0 && (
        <div className="szf-attachments">
          {attachments.map((file) => (
            <span key={file.path} className="szf-chip attachment">
              {file.display_name}
              {strings.cancel && (
                <button
                  type="button"
                  aria-label={strings.cancel}
                  title={strings.cancel}
                  onClick={() =>
                    setAttachments((old) =>
                      old.filter((entry) => entry.path !== file.path),
                    )
                  }
                >
                  ×
                </button>
              )}
            </span>
          ))}
        </div>
      )}
      <div className="szf-composer-row">
        <div
          ref={editor}
          className={`szf-editor ${composer.enabled ? "" : "disabled"}`}
          contentEditable={composer.enabled ? "true" : "false"}
          role="textbox"
          aria-multiline="true"
          aria-label={composer.placeholder}
          data-placeholder={composer.placeholder}
          suppressContentEditableWarning
          onInput={() => {
            save(undefined);
            const entry = drafts.get(conversationId);
            if (entry) entry.token = undefined;
            const found = trigger();
            const wanted =
              found &&
              ((found.kind === "@" && mentionsOn) ||
                (found.kind === "#" && attach))
                ? found
                : null;
            setPicker(wanted);
            setSelected(0);
          }}
          onPaste={(event) => {
            // Only plain text: a pasted chip or markup from elsewhere must not become a mention.
            event.preventDefault();
            document.execCommand(
              "insertText",
              false,
              event.clipboardData.getData("text/plain"),
            );
          }}
          onKeyDown={(event) => {
            if (picker && count > 0) {
              if (event.key === "ArrowDown" || event.key === "ArrowUp") {
                event.preventDefault();
                setSelected(
                  (value) =>
                    (value + (event.key === "ArrowDown" ? 1 : count - 1)) %
                    count,
                );
                return;
              }
              if (event.key === "Enter" || event.key === "Tab") {
                event.preventDefault();
                void choose(selected);
                return;
              }
            }
            if (picker && event.key === "Escape") {
              // Escape closes the innermost picker first, then the panel.
              event.preventDefault();
              event.stopPropagation();
              setPicker(null);
              return;
            }
            if (
              event.key === "Enter" &&
              !event.shiftKey &&
              !event.nativeEvent.isComposing
            ) {
              event.preventDefault();
              void send();
            } else if (event.key === "Enter" && event.shiftKey) {
              event.preventDefault();
              document.execCommand("insertText", false, "\n");
            }
          }}
        />
        <button
          type="button"
          className="szf-button primary"
          disabled={!composer.enabled || sending || over}
          onClick={() => void send()}
        >
          {composer.send_label}
        </button>
      </div>
      {refusal && <small className="szf-refusal">{refusal}</small>}
      {composer.note && (
        <small className="szf-composer-note">{composer.note}</small>
      )}
      {composer.hint.length > 0 && composer.enabled && (
        <small className="szf-hint">
          <RichText segments={composer.hint} />
        </small>
      )}
    </div>
  );
}
