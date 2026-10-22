// A friend's details, joining an existing profile, and a Friends link's card. The profile is in ProfilePage.tsx.
import { useEffect, useState } from "react";
import type {
  Action,
  DetailsData,
  JoinData,
  LinkCard,
  Reply,
} from "./protocol";
import {
  ActionButton,
  Actions,
  AvatarView,
  CopyButton,
  PageHeader,
  usePanel,
} from "./parts";
import { Glyph, RouteIcon } from "./glyphs";
import { useView } from "./store";

/** Whether an action pressed on a friend's details leaves them: Remove took the person off the list, so their
 * details and chat have nobody to show, and the panel goes back to the list. */
export function leavesDetails(action: Action, reply: Reply | undefined) {
  return action.action === "remove_friend" && reply?.ok === true;
}

export function DetailsPage({
  conversationId,
  onBack,
  onRemoved,
}: {
  conversationId: string;
  onBack(): void;
  /** The person was removed from here: back to the list. */
  onRemoved?(): void;
}) {
  const panel = usePanel();
  const { store } = panel;
  const data = useView<DetailsData>(store, `details:${conversationId}`, {
    type: "subscribe",
    fields: { view: "details", params: { conversation_id: conversationId } },
  });
  if (!data)
    return (
      <div className="szf-page">
        <PageHeader onBack={onBack} backLabel={store.strings.back} />
      </div>
    );
  const context = { conversation_id: data.conversation_id };
  return (
    <div className="szf-page szf-details">
      <PageHeader
        back={data.back}
        backLabel={store.strings.back}
        onBack={onBack}
      >
        <strong>{data.title}</strong>
      </PageHeader>
      <div className="szf-scroll szf-form">
        <div className="szf-identity">
          <AvatarView avatar={data.avatar} size={56} />
          <strong>{data.title}</strong>
          <span
            className="szf-header-subtitle"
            title={data.route.label ?? undefined}
          >
            <RouteIcon route={data.route} size={11} />
            {data.route.label}
          </span>
        </div>
        {data.id_label && data.friends_id && (
          <div className="szf-line">
            <span>{data.id_label}</span>
            <CopyButton
              value={data.friends_id}
              accessibilityLabel={data.copy_id_accessibility_label}
            />
          </div>
        )}
        {data.id_confirmed && data.id_confirmed_label && (
          <small className="szf-confirmed-line">
            <Glyph name="verified" size={12} /> {data.id_confirmed_label}
          </small>
        )}
        {data.key_change && (
          <section className="szf-card szf-alert">
            <strong>{data.key_change.title}</strong>
            <p>{data.key_change.body}</p>
            <Actions actions={data.key_change.actions} context={context} />
          </section>
        )}
        <section className="szf-section">
          <strong>{data.verification.label}</strong>
          {data.verification.body && <p>{data.verification.body}</p>}
          {data.verification.comparison_code && (
            <p className="szf-code">{data.verification.comparison_code}</p>
          )}
          {data.verification.action && (
            <ActionButton action={data.verification.action} context={context} />
          )}
        </section>
        {data.auto_accept.available && (
          <label className="szf-switch">
            <input
              type="checkbox"
              checked={data.auto_accept.enabled}
              onChange={async (event) =>
                panel.report(
                  await store.send("set_auto_accept", {
                    conversation_id: data.conversation_id,
                    enabled: event.target.checked,
                  }),
                )
              }
            />
            <span>
              <strong>{data.auto_accept.title}</strong>
              <small>{data.auto_accept.body}</small>
            </span>
          </label>
        )}
        {data.received && (
          <section className="szf-line">
            <span>{data.received.label}</span>
            {data.received.action && (
              <ActionButton action={data.received.action} context={context} />
            )}
          </section>
        )}
        <Actions
          actions={data.actions}
          context={context}
          onDone={(reply, action) => {
            if (leavesDetails(action, reply)) onRemoved?.();
          }}
        />
      </div>
    </div>
  );
}

export function JoinPage({ onBack }: { onBack(): void }) {
  const panel = usePanel();
  const { store } = panel;
  const data = useView<JoinData>(store, "join", {
    type: "subscribe",
    fields: { view: "join" },
  });
  const [id, setID] = useState("");
  const [code, setCode] = useState("");
  if (!data)
    return (
      <div className="szf-page">
        <PageHeader onBack={onBack} backLabel={store.strings.back} />
      </div>
    );
  return (
    <div className="szf-page szf-join">
      <PageHeader onBack={onBack} backLabel={store.strings.back}>
        <strong>{data.title}</strong>
      </PageHeader>
      <div className="szf-scroll szf-form">
        {data.message && <p>{data.message}</p>}
        {data.route?.label && (
          <p className="szf-join-route" title={data.route.label}>
            <RouteIcon route={data.route} size={11} /> {data.route.label}
          </p>
        )}
        {data.id_field && (
          <form
            className="szf-inline"
            onSubmit={async (event) => {
              event.preventDefault();
              panel.report(
                await store.send("join_profile", { friends_id: id.trim() }),
              );
            }}
          >
            <input
              value={id}
              placeholder={data.id_field.placeholder}
              onChange={(event) => setID(event.target.value)}
            />
            <button type="submit" className="szf-button primary">
              {data.id_field.button}
            </button>
          </form>
        )}
        {data.code_field && (
          <form
            className="szf-inline"
            onSubmit={async (event) => {
              event.preventDefault();
              const reply = await store.send("enter_join_code", { code });
              panel.report(reply);
              if (reply.ok) setCode("");
            }}
          >
            <input
              value={code}
              inputMode="numeric"
              placeholder={data.code_field.placeholder}
              disabled={!data.code_field.enabled}
              onChange={(event) => setCode(event.target.value)}
            />
            <button
              type="submit"
              className="szf-button primary"
              disabled={!data.code_field.enabled}
            >
              {data.code_field.button}
            </button>
          </form>
        )}
        {data.error && <p className="szf-refusal">{data.error}</p>}
        <Actions actions={data.actions} />
      </div>
    </div>
  );
}

/** A Friends link opened in this app: the helper's card, whose buttons are the only way the link acts. */
export function LinkPage({
  payload,
  onBack,
  onOpened,
}: {
  payload: string;
  onBack(): void;
  onOpened(conversationId: string): void;
}) {
  const panel = usePanel();
  const { store } = panel;
  const [card, setCard] = useState<LinkCard | null>(null);
  // A failed open_link's message, or what the card's action did ("Request sent…").
  const [notice, setNotice] = useState<string | null>(null);
  // Friends that announces no links (the phone builds, which reach friends only nearby) cannot open one: the app
  // says so rather than asking and showing Loading… forever, since that refusal carries no words (PROTOCOL.md).
  const unopenable = !store.has("links");
  useEffect(() => {
    if (unopenable) return;
    let active = true;
    void store.send("open_link", { payload }).then((reply: Reply) => {
      if (!active) return;
      if (reply.ok) setCard((reply.result?.card as LinkCard) ?? null);
      else setNotice(reply.error?.message ?? null);
    });
    return () => {
      active = false;
    };
  }, [store, payload, unopenable]);
  return (
    <div className="szf-page szf-link-page">
      <PageHeader onBack={onBack} backLabel={store.strings.back}>
        {card && <strong>{card.title}</strong>}
      </PageHeader>
      <div className="szf-scroll szf-form">
        {unopenable && (
          <p role="status">
            Shenzhen 3D can’t open Friends links on this device yet. Open the
            link on a computer.
          </p>
        )}
        {!unopenable && !card && !notice && store.strings.loading && (
          <p className="szf-quiet">{store.strings.loading}</p>
        )}
        {notice && <p role="status">{notice}</p>}
        {card && (
          <div className="szf-identity">
            {card.avatar && <AvatarView avatar={card.avatar} size={56} />}
            <strong>{card.title}</strong>
            {card.subtitle && <span>{card.subtitle}</span>}
            {card.note && <small>{card.note}</small>}
            <Actions
              actions={card.actions}
              onDone={(reply) => {
                if (!reply?.ok) return;
                setNotice(
                  (reply.result?.message as string | undefined) ?? null,
                );
                const id = reply.result?.conversation_id as string | undefined;
                if (id) onOpened(id);
              }}
            />
          </div>
        )}
      </div>
    </div>
  );
}
