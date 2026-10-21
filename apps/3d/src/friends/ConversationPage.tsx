// One friend's history and composer, or the request card while a request is pending (PROTOCOL.md § Views,
// conversation). Held only while on screen: leaving the page unsubscribes, so the helper stops marking it read.
import { useEffect, useLayoutEffect, useRef, useState } from "react";
import type { ConversationData, Mention, SearchResult } from "./protocol";
import { Actions, AvatarView, PageHeader, RichText, usePanel } from "./parts";
import { RouteIcon } from "./glyphs";
import { useView } from "./store";
import { ComposerView } from "./Composer";
import type { AttachSource } from "./Composer";
import { dragHasFiles, filesFromDrop, sendFiles } from "./drops";
import { ItemView, LinkMenu } from "./ConversationItems";

export function ConversationPage({
  conversationId,
  messageId,
  attach,
  onBack,
  onDetails,
}: {
  conversationId: string;
  messageId?: string;
  attach: AttachSource | null;
  onBack(): void;
  onDetails(): void;
}) {
  const panel = usePanel();
  const { store, bridge } = panel;
  const strings = store.strings;
  const key = `conversation:${conversationId}:${messageId ?? ""}`;
  const data = useView<ConversationData>(store, key, {
    type: "open_conversation",
    fields: messageId
      ? { conversation_id: conversationId, message_id: messageId }
      : { conversation_id: conversationId },
  });
  const scroller = useRef<HTMLDivElement>(null);
  const atBottom = useRef(true);
  const [searching, setSearching] = useState(false);
  const [menu, setMenu] = useState<{ url: string; text: string } | null>(null);
  const [card, setCard] = useState<Mention | null>(null);
  const [dragging, setDragging] = useState(false);
  const [refusal, setRefusal] = useState<string | null>(null);

  useLayoutEffect(() => {
    const element = scroller.current;
    if (!element || !data) return;
    if (data.highlight_item_id) {
      element
        .querySelector(`[data-item="${CSS.escape(data.highlight_item_id)}"]`)
        ?.scrollIntoView({ block: "center" });
      return;
    }
    if (atBottom.current) element.scrollTop = element.scrollHeight;
  }, [data]);
  // The last messages stay in sight when the history gets shorter: the keyboard coming up, the composer growing.
  const hasHistory = Boolean(data && !data.request);
  useEffect(() => {
    const element = scroller.current;
    if (!element || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(() => {
      if (atBottom.current) element.scrollTop = element.scrollHeight;
    });
    observer.observe(element);
    return () => observer.disconnect();
  }, [hasHistory]);

  if (!data)
    return (
      <div className="szf-page">
        <PageHeader onBack={onBack} backLabel={strings.back} />
        {strings.loading && <p className="szf-quiet">{strings.loading}</p>}
      </div>
    );
  const header = data.header;
  return (
    <div className="szf-page szf-conversation">
      <PageHeader back={data.back} backLabel={strings.back} onBack={onBack}>
        <button
          type="button"
          className="szf-header-button"
          disabled={!header.details_available}
          aria-label={header.accessibility_label}
          onClick={onDetails}
        >
          <strong>{header.title}</strong>
          {header.subtitle && (
            <span
              className="szf-header-subtitle"
              title={header.route.label ?? undefined}
            >
              <RouteIcon route={header.route} size={11} />
              {header.subtitle}
            </span>
          )}
        </button>
      </PageHeader>
      {data.request ? (
        <RequestCardView data={data} />
      ) : (
        <>
          <div className="szf-conversation-search">
            {searching ? (
              <ConversationSearch
                conversationId={conversationId}
                placeholder={data.search_placeholder}
                onClose={() => setSearching(false)}
                onOpen={(result) => {
                  setSearching(false);
                  panel.openConversation(
                    result.conversation_id,
                    result.message_id,
                  );
                }}
              />
            ) : (
              <button
                type="button"
                className="szf-search-button"
                onClick={() => setSearching(true)}
              >
                {data.search_placeholder}
              </button>
            )}
          </div>
          <div
            ref={scroller}
            className={`szf-history ${dragging ? "drop-target" : ""}`}
            onScroll={(event) => {
              const element = event.currentTarget;
              atBottom.current =
                element.scrollHeight -
                  element.scrollTop -
                  element.clientHeight <
                40;
            }}
            onDragOver={(event) => {
              if (
                !data.composer.accepts_drops ||
                !dragHasFiles(event.dataTransfer)
              )
                return;
              event.preventDefault();
              setDragging(true);
            }}
            onDragLeave={() => setDragging(false)}
            onDrop={async (event) => {
              if (
                !data.composer.accepts_drops ||
                !dragHasFiles(event.dataTransfer)
              )
                return;
              event.preventDefault();
              event.stopPropagation();
              setDragging(false);
              // On the message list, dropped files go at once, one offer each.
              const dropped = await filesFromDrop(
                bridge,
                strings,
                event.dataTransfer.files,
              );
              setRefusal(dropped.refusal);
              if (dropped.files.length)
                panel.report(
                  await sendFiles(bridge, conversationId, dropped.files),
                );
            }}
          >
            {data.has_earlier && strings.load_earlier && (
              <button
                type="button"
                className="szf-button link szf-earlier"
                onClick={() => {
                  const subscription = store.subscriptionId(key);
                  if (subscription)
                    void store.send("load_earlier", { subscription });
                }}
              >
                {strings.load_earlier}
              </button>
            )}
            {data.items.map((item) => (
              <ItemView
                key={item.item_id}
                item={item}
                onLink={(url, text) => setMenu({ url, text })}
                onMention={(mention) => {
                  if (mention.kind === "friend" && mention.conversation_id)
                    panel.openConversation(mention.conversation_id);
                  else if (mention.kind === "stranger" && mention.card)
                    setCard(mention);
                }}
              />
            ))}
            {refusal && <p className="szf-refusal">{refusal}</p>}
          </div>
          {menu && (
            <LinkMenu
              url={menu.url}
              text={menu.text}
              onClose={() => setMenu(null)}
            />
          )}
          {card?.card && (
            <div
              className="szf-popover"
              role="dialog"
              aria-label={card.card.title}
            >
              <strong>{card.card.title}</strong>
              <span>{card.card.id_label}</span>
              {card.card.status_label && (
                <small>{card.card.status_label}</small>
              )}
              <Actions
                actions={card.card.actions}
                context={{
                  conversation_id: card.card.conversation_id ?? undefined,
                }}
                onDone={(reply) => reply?.ok && setCard(null)}
              />
              {strings.cancel && (
                <button
                  type="button"
                  className="szf-button link"
                  onClick={() => setCard(null)}
                >
                  {strings.cancel}
                </button>
              )}
            </div>
          )}
          <ComposerView
            conversationId={conversationId}
            composer={data.composer}
            attach={attach}
          />
        </>
      )}
    </div>
  );
}

function RequestCardView({ data }: { data: ConversationData }) {
  const request = data.request!;
  return (
    <div className="szf-request">
      <AvatarView avatar={request.avatar} size={56} />
      <strong>{request.title}</strong>
      <p>{request.subtitle}</p>
      {request.code_prompt && (
        <p className="szf-quiet">{request.code_prompt}</p>
      )}
      {request.comparison_code && (
        <p
          className="szf-code"
          aria-label={request.comparison_code_accessibility_label ?? undefined}
        >
          {request.comparison_code}
        </p>
      )}
      <Actions
        actions={request.actions}
        context={{ conversation_id: data.conversation_id }}
      />
      {request.footnote && <small>{request.footnote}</small>}
    </div>
  );
}

function ConversationSearch({
  conversationId,
  placeholder,
  onClose,
  onOpen,
}: {
  conversationId: string;
  placeholder: string;
  onClose(): void;
  onOpen(result: SearchResult): void;
}) {
  const { store } = usePanel();
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<{
    results: SearchResult[];
    empty: string | null;
  }>({ results: [], empty: null });
  useEffect(() => {
    if (!query.trim()) return setResults({ results: [], empty: null });
    let active = true;
    const timer = window.setTimeout(async () => {
      const reply = await store.send("search_messages", {
        query,
        conversation_id: conversationId,
      });
      if (!active || !reply.ok) return;
      setResults({
        results: (reply.result?.results as SearchResult[]) ?? [],
        empty: (reply.result?.empty_label as string | null) ?? null,
      });
    }, 150);
    return () => {
      active = false;
      window.clearTimeout(timer);
    };
  }, [store, query, conversationId]);
  return (
    <div className="szf-conversation-search-open">
      <input
        type="search"
        autoFocus
        value={query}
        placeholder={placeholder}
        aria-label={placeholder}
        onChange={(event) => setQuery(event.target.value)}
        onKeyDown={(event) => {
          if (event.key === "Escape") {
            event.stopPropagation();
            onClose();
          }
        }}
      />
      {(results.results.length > 0 || results.empty) && (
        <ul className="szf-search-results" role="list">
          {results.results.map((result) => (
            <li key={result.message_id}>
              <button type="button" onClick={() => onOpen(result)}>
                <small>
                  {result.sender_label} · {result.time_label}
                </small>
                <span>
                  <RichText segments={result.excerpt} />
                </span>
              </button>
            </li>
          ))}
          {!results.results.length && results.empty && (
            <li className="szf-quiet">{results.empty}</li>
          )}
        </ul>
      )}
    </div>
  );
}
