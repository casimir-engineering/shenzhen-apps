import { useState } from "react";
import {
  Check,
  Download,
  MessageSquarePlus,
  Pencil,
  RotateCcw,
  Trash2,
  X,
} from "lucide-react";
import type { Pick } from "../core/types";
import type { ReviewNote } from "../core/project-file";

type Scope = ReviewNote["scope"];
interface Props {
  notes: ReviewNote[];
  selected?: string;
  anchor?: Pick;
  scope: Scope;
  placing: boolean;
  enabled: boolean;
  sharing: boolean;
  onStart: (scope: Scope) => void;
  onCancel: () => void;
  onCreate: (text: string) => void;
  onSelect: (note: ReviewNote) => void;
  onUpdate: (note: ReviewNote) => void;
  onDelete: (id: string) => void;
  onShare: () => void;
}
export function ReviewPanel(props: Props) {
  const [text, setText] = useState("");
  const [editing, setEditing] = useState<string>();
  const [editText, setEditText] = useState("");
  const [showResolved, setShowResolved] = useState(false);
  const unresolved = props.notes.filter((note) => !note.resolved).length;
  const visible = props.notes.filter((note) => showResolved || !note.resolved);
  return (
    <div className="review-content">
      <div className="review-actions">
        <button
          className="button primary"
          title="Add note · N"
          disabled={!props.enabled}
          onClick={() => {
            setText("");
            props.onStart(props.scope);
          }}
        >
          <MessageSquarePlus size={15} /> Add note
        </button>
        <button
          className="icon-button"
          aria-label="Share commented project"
          title="Share commented project"
          disabled={!props.enabled || props.sharing}
          onClick={props.onShare}
        >
          <Download size={17} />
        </button>
      </div>
      {props.placing && (
        <form
          className="note-composer"
          onSubmit={(event) => {
            event.preventDefault();
            if (text.trim() && props.anchor) {
              props.onCreate(text.trim());
              setText("");
            }
          }}
        >
          <div className="note-composer-heading">
            <strong>Attach a note</strong>
            <button
              type="button"
              className="icon-button"
              aria-label="Cancel note"
              onClick={props.onCancel}
            >
              <X size={15} />
            </button>
          </div>
          <label>
            Attach to
            <select
              aria-label="Annotation target"
              value={props.scope}
              onChange={(event) => props.onStart(event.target.value as Scope)}
            >
              <option value="point">Specific point</option>
              <option value="feature">Model feature</option>
              <option value="part">Whole part</option>
            </select>
          </label>
          <div
            className={`note-anchor ${props.anchor ? "attached" : ""}`}
            role="status"
          >
            {props.anchor ? (
              <>
                <Check size={14} />
                <span>
                  {props.scope === "feature"
                    ? `${props.anchor.kind} ${props.anchor.elementId ?? ""} · `
                    : ""}
                  {props.anchor.partName}
                </span>
              </>
            ) : (
              <span>
                Pick{" "}
                {props.scope === "part"
                  ? "a part"
                  : props.scope === "feature"
                    ? "a feature"
                    : "a point"}{" "}
                on the model.
              </span>
            )}
          </div>
          <textarea
            aria-label="Annotation text"
            placeholder="Note"
            maxLength={4000}
            value={text}
            onChange={(event) => setText(event.target.value)}
            rows={4}
          />
          <button
            className="button primary"
            type="submit"
            disabled={!text.trim() || !props.anchor}
          >
            Save note
          </button>
        </form>
      )}
      {!props.notes.length && !props.placing && (
        <div className="empty-panel review-empty">
          <MessageSquarePlus size={28} />
          <p>No notes</p>
        </div>
      )}
      {!!props.notes.length && (
        <>
          <div className="review-list-heading">
            <span>
              {unresolved} open {unresolved === 1 ? "note" : "notes"}
            </span>
            <label>
              <input
                type="checkbox"
                checked={showResolved}
                onChange={(event) => setShowResolved(event.target.checked)}
              />{" "}
              Show resolved
            </label>
          </div>
          <ol className="review-list">
            {visible.map((note) => (
              <li
                key={note.id}
                className={`review-note ${props.selected === note.id ? "selected" : ""} ${note.resolved ? "resolved" : ""}`}
              >
                <button
                  className="note-location"
                  onClick={() => props.onSelect(note)}
                  aria-label={`Focus note ${props.notes.indexOf(note) + 1}`}
                >
                  <span className="note-number">
                    {props.notes.indexOf(note) + 1}
                  </span>
                  <span>
                    <strong>{note.anchor.partName}</strong>
                    <small>
                      {note.scope === "feature"
                        ? `${note.anchor.kind}${note.anchor.elementId === undefined ? "" : ` ${note.anchor.elementId}`}`
                        : note.scope === "part"
                          ? "Whole part"
                          : "Point on surface"}
                      {note.resolved ? " · Resolved" : ""}
                    </small>
                  </span>
                </button>
                {editing === note.id ? (
                  <form
                    onSubmit={(event) => {
                      event.preventDefault();
                      if (editText.trim()) {
                        props.onUpdate({
                          ...note,
                          text: editText.trim(),
                          updatedAt: new Date().toISOString(),
                        });
                        setEditing(undefined);
                      }
                    }}
                  >
                    <textarea
                      aria-label="Edit annotation text"
                      maxLength={4000}
                      rows={4}
                      value={editText}
                      onChange={(event) => setEditText(event.target.value)}
                      autoFocus
                    />
                    <div className="note-edit-actions">
                      <button
                        className="button subtle"
                        type="button"
                        onClick={() => setEditing(undefined)}
                      >
                        Cancel
                      </button>
                      <button
                        className="button primary"
                        disabled={!editText.trim()}
                      >
                        Save changes
                      </button>
                    </div>
                  </form>
                ) : (
                  <p className="note-text">{note.text}</p>
                )}
                <div className="note-actions">
                  <button
                    onClick={() =>
                      props.onUpdate({
                        ...note,
                        resolved: !note.resolved,
                        updatedAt: new Date().toISOString(),
                      })
                    }
                  >
                    {note.resolved ? (
                      <RotateCcw size={13} />
                    ) : (
                      <Check size={13} />
                    )}{" "}
                    {note.resolved ? "Reopen" : "Resolve"}
                  </button>
                  <button
                    aria-label={`Edit note ${props.notes.indexOf(note) + 1}`}
                    onClick={() => {
                      setEditing(note.id);
                      setEditText(note.text);
                    }}
                  >
                    <Pencil size={13} />
                  </button>
                  <button
                    aria-label={`Delete note ${props.notes.indexOf(note) + 1}`}
                    onClick={() => props.onDelete(note.id)}
                  >
                    <Trash2 size={13} />
                  </button>
                </div>
              </li>
            ))}
          </ol>
        </>
      )}
    </div>
  );
}
