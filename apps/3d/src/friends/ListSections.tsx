// The list's parts around its rows: the prompt for your name, a computer asking to join, and the footer.
import { useState } from "react";
import type { Action, Footer, JoinRequest, ListData } from "./protocol";
import { ActionButton, AvatarView, CopyButton, usePanel } from "./parts";

export function NamePrompt({
  prompt,
  onJoin,
}: {
  prompt: NonNullable<ListData["name_prompt"]>;
  onJoin(): void;
}) {
  const panel = usePanel();
  const [name, setName] = useState("");
  return (
    <form
      className="szf-card szf-name-prompt"
      onSubmit={async (event) => {
        event.preventDefault();
        if (!name.trim()) return;
        const reply = await panel.store.send("set_name", { name });
        panel.report(reply);
      }}
    >
      <label>
        <strong>{prompt.title}</strong>
        <input
          value={name}
          placeholder={prompt.placeholder}
          onChange={(event) => setName(event.target.value)}
        />
      </label>
      <small>{prompt.note}</small>
      {prompt.join_label && (
        <button type="button" className="szf-button link" onClick={onJoin}>
          {prompt.join_label}
        </button>
      )}
    </form>
  );
}

export function JoinRequestRow({ request }: { request: JoinRequest }) {
  const [approving, setApproving] = useState(false);
  return (
    <div
      className="szf-card szf-join-request"
      aria-label={request.accessibility_label}
    >
      <strong>{request.title}</strong>
      <p>{request.subtitle}</p>
      {request.code && (
        <p
          className="szf-code"
          aria-label={request.code_accessibility_label ?? undefined}
        >
          {request.code}
        </p>
      )}
      {request.code_note && <small>{request.code_note}</small>}
      <div className="szf-actions">
        {request.actions.map((action: Action, index) => (
          <ActionButton
            key={`${action.action}-${index}`}
            action={action}
            // Approve stays disabled once pressed, until the snapshot shows the code.
            disabled={action.action === "approve_join" && approving}
            onDone={(reply) => {
              if (action.action === "approve_join")
                setApproving(Boolean(reply?.ok));
            }}
          />
        ))}
      </div>
    </div>
  );
}

export function FooterView({
  footer,
  removed,
  onProfile,
}: {
  footer: Footer;
  removed: boolean;
  onProfile(): void;
}) {
  const panel = usePanel();
  const strings = panel.store.strings;
  const [editing, setEditing] = useState(false);
  const [name, setName] = useState(footer.name ?? "");
  return (
    <div className="szf-footer">
      <AvatarView avatar={footer.avatar} size={30} />
      <div className="szf-footer-text">
        {editing ? (
          <form
            onSubmit={async (event) => {
              event.preventDefault();
              const reply = await panel.store.send("set_name", { name });
              panel.report(reply);
              if (reply.ok) setEditing(false);
            }}
          >
            <input
              autoFocus
              value={name}
              placeholder={footer.name_placeholder}
              aria-label={strings.edit_name}
              onChange={(event) => setName(event.target.value)}
              onBlur={() => setEditing(false)}
              onKeyDown={(event) => {
                if (event.key === "Escape") {
                  event.stopPropagation();
                  setEditing(false);
                }
              }}
            />
          </form>
        ) : (
          <button
            type="button"
            className={`szf-footer-name ${footer.name ? "" : "placeholder"}`}
            title={strings.edit_name}
            disabled={removed}
            onClick={() => {
              setName(footer.name ?? "");
              setEditing(true);
            }}
          >
            {footer.name ?? footer.name_placeholder}
          </button>
        )}
        <span className="szf-footer-id">
          <span>{footer.id_label}</span>
          <CopyButton
            value={footer.friends_id}
            label=""
            accessibilityLabel={strings.copy_your_id}
          />
        </span>
        {footer.id_note && <small>{footer.id_note}</small>}
      </div>
      {!removed && (
        <button
          type="button"
          className="szf-button secondary"
          onClick={onProfile}
        >
          {footer.add_label}
        </button>
      )}
    </div>
  );
}
