// The list's parts around its rows: the prompt for your name, the offer to use an existing profile here, a computer
// asking to join, and the footer.
import { useState } from "react";
import type {
  Action,
  Footer,
  JoinOffer,
  JoinRequest,
  ListData,
} from "./protocol";
import { ActionButton, AvatarView, CopyButton, usePanel } from "./parts";

export function NamePrompt({
  prompt,
  join,
}: {
  prompt: NonNullable<ListData["name_prompt"]>;
  /** The list's offer to use an existing profile here, drawn in this card while it shows. */
  join: JoinOffer | null;
}) {
  const panel = usePanel();
  const strings = panel.store.strings;
  const [name, setName] = useState("");
  // Why the last Save did not go through, until the person types again.
  const [refusal, setRefusal] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  return (
    <form
      className="szf-card szf-name-prompt"
      onSubmit={async (event) => {
        event.preventDefault();
        // Save is for a name: with nothing typed, say so instead of clearing it.
        if (!name.trim()) return setRefusal(strings.name_empty || null);
        setSaving(true);
        const reply = await panel.store.send("set_name", { name: name.trim() });
        setSaving(false);
        // The helper's reason shows under the field, where the name was typed.
        if (!reply.ok) setRefusal(reply.error?.message ?? null);
      }}
    >
      <label>
        <strong>{prompt.title}</strong>
        <span className="szf-name-row">
          <input
            value={name}
            placeholder={prompt.placeholder}
            disabled={saving}
            onChange={(event) => {
              setName(event.target.value);
              setRefusal(null);
            }}
          />
          {strings.save && (
            <button
              type="submit"
              className="szf-button primary"
              disabled={saving || !name.trim()}
            >
              {strings.save}
            </button>
          )}
        </span>
      </label>
      {refusal && <small className="szf-refusal">{refusal}</small>}
      <small>{prompt.note}</small>
      {/* The card shows on first run, so it also says Friends is a beta. */}
      {strings.beta_note && <small>{strings.beta_note}</small>}
      {join && (
        <span className="szf-join-offer">
          <ActionButton action={join.action} />
          <small>{join.note}</small>
        </span>
      )}
    </form>
  );
}

/** The offer to use an existing profile here, as a card of its own once a name is chosen (PROTOCOL.md § Joining). */
export function JoinOfferCard({ offer }: { offer: JoinOffer }) {
  return (
    <div className="szf-card szf-join-offer">
      <p>{offer.note}</p>
      <ActionButton action={offer.action} />
    </div>
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
