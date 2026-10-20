// The list's Nearby tab: making yourself visible, the ways Friends looks for people, and the people it found.
import type { Action, NearbyData } from "./protocol";
import { ActionButton, AvatarView, usePanel } from "./parts";
import { Glyph } from "./glyphs";

export function NearbyPane({ data }: { data: NearbyData | undefined }) {
  const panel = usePanel();
  const strings = panel.store.strings;
  if (!data)
    return strings.loading ? (
      <p className="szf-quiet">{strings.loading}</p>
    ) : null;
  const visibility = data.visibility;
  return (
    <div className="szf-nearby">
      {/* Under a card that says nothing works, the helper sends no words and no action here. */}
      {(visibility.title || visibility.body || visibility.action) && (
        <div className={`szf-card szf-visibility ${visibility.state}`}>
          {visibility.title && <strong>{visibility.title}</strong>}
          {visibility.body && <p>{visibility.body}</p>}
          {visibility.remaining_label && (
            <p
              className="szf-countdown"
              aria-label={visibility.remaining_accessibility_label ?? undefined}
            >
              {visibility.remaining_label}
            </p>
          )}
          {visibility.action && <ActionButton action={visibility.action} />}
        </div>
      )}
      <ul className="szf-methods" role="list">
        {data.methods.map((method) => (
          <li key={method.method} className={`szf-method ${method.state}`}>
            <Glyph
              name={method.method === "bluetooth" ? "bluetooth" : "lan"}
              size={12}
            />
            <span>{method.label}</span>
          </li>
        ))}
      </ul>
      {data.alert && (
        <div className="szf-card szf-alert" role="alert">
          <strong>{data.alert.title}</strong>
          <p>{data.alert.body}</p>
          {data.alert.action && <ActionButton action={data.alert.action} />}
        </div>
      )}
      {data.note && (
        <div className="szf-quiet-line">
          <span>{data.note.text}</span>
          {data.note.action && <ActionButton action={data.note.action} />}
        </div>
      )}
      {data.people.length > 0 && (
        <div className="szf-people-header">
          <strong>{strings.people_nearby}</strong>
          {data.status && <small>{data.status.label}</small>}
        </div>
      )}
      {data.people.length ? (
        <ul className="szf-rows" role="list">
          {data.people.map((person) => (
            <li
              key={person.nearby_id ?? person.conversation_id ?? person.title}
              className="szf-row"
            >
              <button
                type="button"
                className="szf-row-main"
                aria-label={person.accessibility_label}
                disabled={!person.conversation_id}
                onClick={() =>
                  person.conversation_id &&
                  panel.openConversation(person.conversation_id)
                }
              >
                <AvatarView avatar={person.avatar} size={34} />
                <span className="szf-row-text">
                  <span className="szf-row-title">{person.title}</span>
                  <span className="szf-row-subtitle">{person.subtitle}</span>
                </span>
                {person.status_label && (
                  <span className="szf-row-meta">
                    <span className="szf-waiting">{person.status_label}</span>
                  </span>
                )}
              </button>
              {person.action && person.nearby_id && (
                <NearbyRequest
                  action={person.action}
                  nearbyId={person.nearby_id}
                />
              )}
            </li>
          ))}
        </ul>
      ) : data.empty ? (
        <div className="szf-empty">
          <strong>{data.empty.title}</strong>
          {data.empty.body && <p>{data.empty.body}</p>}
        </div>
      ) : null}
    </div>
  );
}

function NearbyRequest({
  action,
  nearbyId,
}: {
  action: Action;
  nearbyId: string;
}) {
  return <ActionButton action={action} context={{ nearby_id: nearbyId }} />;
}
