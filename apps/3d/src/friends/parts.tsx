// Small pieces every Friends page draws: avatars, buttons with their arm or confirmation, rich text, copy buttons.
// Every string they show comes from a snapshot or welcome.strings. The route and action glyphs are in glyphs.tsx.
import { createContext, useContext, useEffect, useRef, useState } from "react";
import type { ReactNode } from "react";
import type { FriendsBridge } from "./bridge";
import type {
  Action,
  Arm,
  Avatar,
  Confirm,
  Mention,
  Reply,
  Segment,
} from "./protocol";
import { CLIENT_ACTIONS, actionIntent } from "./actions";
import type { FriendsStore } from "./store";
import { Glyph } from "./glyphs";

export type PanelContext = {
  store: FriendsStore;
  bridge: FriendsBridge;
  /** Shows a reply's failure: its display-ready message, or nothing when it has none. */
  report(reply: Reply): void;
  openConversation(conversationId: string, messageId?: string): void;
  confirm(confirm: Confirm): Promise<boolean>;
};
export const Panel = createContext<PanelContext | null>(null);
export function usePanel() {
  const value = useContext(Panel);
  if (!value) throw Error("Friends parts need the panel");
  return value;
}

// ---- Avatars ---------------------------------------------------------------------------------------------

const imageCache = new Map<string, Promise<string | null>>();
function cached(key: string, load: () => Promise<string | null>) {
  let value = imageCache.get(key);
  if (!value) {
    value = load().catch(() => null);
    imageCache.set(key, value);
    if (imageCache.size > 200)
      imageCache.delete(imageCache.keys().next().value!);
  }
  return value;
}
/** Decodes off the main thread and checks the decoded size, drawing nothing on any failure. */
async function decodedURL(
  bytes: Uint8Array,
  type: string,
  width?: number,
  height?: number,
) {
  const blob = new Blob([new Uint8Array(bytes)], { type });
  if (typeof createImageBitmap === "function") {
    const bitmap = await createImageBitmap(blob);
    const ok =
      (width === undefined || bitmap.width === width) &&
      (height === undefined || bitmap.height === height);
    bitmap.close();
    if (!ok) return null;
  }
  return URL.createObjectURL(blob);
}
export function useHelperImage(
  kind: "thumbnail" | "picture",
  path: string | undefined | null,
  width?: number,
  height?: number,
) {
  const { bridge } = usePanel();
  const [url, setURL] = useState<string | null>(null);
  useEffect(() => {
    if (!path) return setURL(null);
    let active = true;
    void cached(`${kind}:${path}:${width}x${height}`, async () => {
      const image = await bridge.image(kind, path, width, height);
      if (!image) return null;
      return decodedURL(
        image.bytes,
        image.type,
        kind === "thumbnail" ? width : image.width,
        kind === "thumbnail" ? height : image.height,
      );
    }).then((value) => active && setURL(value));
    return () => {
      active = false;
    };
  }, [bridge, kind, path, width, height]);
  return url;
}
export function useAnimal(set: number | undefined, index: number | undefined) {
  const { bridge } = usePanel();
  const [url, setURL] = useState<string | null>(null);
  useEffect(() => {
    if (set === undefined || index === undefined) return setURL(null);
    let active = true;
    void cached(`animal:${set}:${index}`, async () => {
      const animal = await bridge.animal(set, index);
      // An <img> never runs what an SVG might carry.
      return animal
        ? URL.createObjectURL(new Blob([animal.svg], { type: "image/svg+xml" }))
        : null;
    }).then((value) => active && setURL(value));
    return () => {
      active = false;
    };
  }, [bridge, set, index]);
  return url;
}

export function AvatarView({
  avatar,
  size = 32,
  muted = false,
}: {
  avatar: Avatar | null | undefined;
  size?: number;
  muted?: boolean;
}) {
  const animal = useAnimal(
    avatar?.kind === "animal" ? avatar.set : undefined,
    avatar?.kind === "animal" ? avatar.index : undefined,
  );
  const photo = useHelperImage(
    "picture",
    avatar?.kind === "image" ? avatar.path : null,
  );
  if (!avatar) return null;
  const source =
    avatar.kind === "animal" ? animal : avatar.kind === "image" ? photo : null;
  return (
    <span
      className={`szf-avatar ${muted ? "muted" : ""}`}
      style={{
        width: size,
        height: size,
        background: source ? undefined : avatar.color,
      }}
      aria-hidden="true"
    >
      {source ? (
        <img src={source} alt="" draggable={false} />
      ) : (
        <span style={{ fontSize: size * 0.38 }}>{avatar.initials}</span>
      )}
    </span>
  );
}

// ---- Buttons ---------------------------------------------------------------------------------------------

/** Arm: the first click shows the armed pill and sends nothing; a second within `seconds` acts. */
export function useArm(arm: Arm | null | undefined) {
  const [armed, setArmed] = useState(false);
  const timer = useRef<number | undefined>(undefined);
  useEffect(() => () => window.clearTimeout(timer.current), []);
  useEffect(() => {
    if (!armed) return;
    const key = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        // Escape disarms and closes nothing else.
        event.stopPropagation();
        event.preventDefault();
        setArmed(false);
      }
    };
    window.addEventListener("keydown", key, true);
    return () => window.removeEventListener("keydown", key, true);
  }, [armed]);
  return {
    armed,
    disarm: () => setArmed(false),
    /** True when the click should act now. */
    click(): boolean {
      if (!arm) return true;
      if (armed) {
        window.clearTimeout(timer.current);
        setArmed(false);
        return true;
      }
      setArmed(true);
      window.clearTimeout(timer.current);
      timer.current = window.setTimeout(
        () => setArmed(false),
        Math.max(1, arm.seconds) * 1000,
      );
      return false;
    },
  };
}

type ActionContext = Parameters<typeof actionIntent>[1];

/** Runs an action: client-side ones through the host, intents after their confirmation when they carry one. */
export function useRunAction() {
  const panel = usePanel();
  return async (action: Action, context: ActionContext = {}) => {
    if (CLIENT_ACTIONS.has(action.action)) {
      if (action.action === "open_file" && action.path)
        await panel.bridge.openFile(action.path);
      if (action.action === "show_file" && action.path)
        await panel.bridge.showFile(action.path);
      if (action.action === "open_settings" && action.settings_target)
        await panel.bridge.openSettings(action.settings_target);
      return;
    }
    const intent = actionIntent(action, context);
    if (!intent) return;
    if (action.confirm && !(await panel.confirm(action.confirm))) return;
    const reply = await panel.store.send(intent.type, intent.fields);
    panel.report(reply);
    return reply;
  };
}

export function ActionButton({
  action,
  context,
  disabled,
  onDone,
}: {
  action: Action;
  context?: ActionContext;
  disabled?: boolean;
  onDone?: (reply: Reply | undefined) => void;
}) {
  const run = useRunAction();
  const arming = useArm(action.arm);
  const [busy, setBusy] = useState(false);
  const style = arming.armed ? "destructive armed" : action.style;
  return (
    <span className="szf-action">
      <button
        type="button"
        className={`szf-button ${style}`}
        disabled={disabled || busy}
        title={arming.armed ? action.arm?.accessibility_label : undefined}
        aria-label={arming.armed ? action.arm?.accessibility_label : undefined}
        onMouseLeave={arming.disarm}
        onClick={async () => {
          if (!arming.click()) return;
          setBusy(true);
          try {
            // Not onDone?.(await run(...)): optional chaining would skip the run itself when there is no onDone.
            const reply = await run(action, context);
            onDone?.(reply);
          } finally {
            setBusy(false);
          }
        }}
      >
        {arming.armed ? action.arm?.label : action.label}
      </button>
      {action.note && <small className="szf-note">{action.note}</small>}
    </span>
  );
}

export function Actions({
  actions,
  context,
  onDone,
}: {
  actions: Action[] | undefined;
  context?: ActionContext;
  onDone?: (reply: Reply | undefined) => void;
}) {
  const known = (actions ?? []).filter(
    (action) =>
      CLIENT_ACTIONS.has(action.action) || actionIntent(action, context ?? {}),
  );
  if (!known.length) return null;
  return (
    <div className="szf-actions">
      {known.map((action, index) => (
        <ActionButton
          key={`${action.action}-${index}`}
          action={action}
          context={context}
          onDone={onDone}
        />
      ))}
    </div>
  );
}

export function CopyButton({
  value,
  label,
  accessibilityLabel,
}: {
  value: string;
  label?: string;
  accessibilityLabel?: string | null;
}) {
  const { store } = usePanel();
  const [copied, setCopied] = useState(false);
  const strings = store.strings;
  useEffect(() => {
    if (!copied) return;
    const timer = window.setTimeout(() => setCopied(false), 1500);
    return () => window.clearTimeout(timer);
  }, [copied]);
  const text = copied ? strings.copied : (label ?? strings.copy);
  return (
    <button
      type="button"
      className="szf-copy"
      title={accessibilityLabel ?? text}
      aria-label={accessibilityLabel ?? text}
      onClick={async () => {
        try {
          await navigator.clipboard.writeText(value);
          setCopied(true);
        } catch {
          /* The clipboard may be unavailable; nothing was copied, so nothing is said. */
        }
      }}
    >
      <Glyph name={copied ? "check" : "copy"} size={14} />
      {text && <span>{text}</span>}
    </button>
  );
}

/** The header of every page below the list: back arrow with its badge at the left, the title centered. */
export function PageHeader({
  back,
  backLabel,
  onBack,
  children,
}: {
  back?: {
    badge_count: number;
    badge_label: string;
    accessibility_label: string;
  } | null;
  backLabel?: string;
  onBack(): void;
  children?: ReactNode;
}) {
  return (
    <div className="szf-page-header">
      <button
        type="button"
        className="szf-back"
        onClick={onBack}
        title={backLabel}
        aria-label={back?.accessibility_label || backLabel}
      >
        <Glyph name="back" size={16} />
        {back && back.badge_count > 0 && (
          <span className="szf-badge small">{back.badge_label}</span>
        )}
      </button>
      <div className="szf-page-title">{children}</div>
      <span className="szf-back-spacer" />
    </div>
  );
}

// ---- Rich text --------------------------------------------------------------------------------------------

/** Where a link really goes, for the link menu: its host, or an email link's address. */
export function linkHost(url: string): { host: string; email: boolean } | null {
  try {
    const parsed = new URL(url);
    if (parsed.protocol === "mailto:")
      return { host: decodeURIComponent(parsed.pathname), email: true };
    if (parsed.protocol === "http:" || parsed.protocol === "https:")
      return { host: parsed.hostname, email: false };
  } catch {}
  return null;
}
/** The site a link's own words show, when they read as an address. */
export function shownHost(text: string): string | null {
  const trimmed = text.trim();
  if (
    !/^[\w.-]+\.[a-z]{2,}(?:[/:?#].*)?$/i.test(trimmed) &&
    !/^(?:https?:\/\/|mailto:)/i.test(trimmed)
  )
    return null;
  try {
    const parsed = new URL(
      /^[a-z]+:/i.test(trimmed) ? trimmed : `https://${trimmed}`,
    );
    return parsed.protocol === "mailto:"
      ? decodeURIComponent(parsed.pathname)
      : parsed.hostname;
  } catch {
    return null;
  }
}

export function RichText({
  segments,
  mentions,
  onLink,
  onMention,
}: {
  segments: Segment[] | undefined;
  mentions?: Mention[];
  onLink?: (url: string, text: string, anchor: HTMLElement) => void;
  onMention?: (mention: Mention, anchor: HTMLElement) => void;
}) {
  return (
    <>
      {(segments ?? []).map((segment, index) => {
        const mention =
          segment.mention !== undefined
            ? mentions?.[segment.mention]
            : undefined;
        if (mention) {
          const clickable =
            mention.kind === "friend" || mention.kind === "stranger";
          return (
            <button
              key={index}
              type="button"
              className={`szf-mention ${mention.kind}`}
              title={mention.tooltip ?? undefined}
              disabled={!clickable}
              onClick={(event) => onMention?.(mention, event.currentTarget)}
            >
              {segment.text}
            </button>
          );
        }
        const className = [
          segment.emphasis ? "szf-emphasis" : "",
          segment.match ? "szf-match" : "",
        ]
          .filter(Boolean)
          .join(" ");
        if (segment.url && linkHost(segment.url))
          return (
            <a
              key={index}
              href="#"
              className={`szf-link ${className}`}
              onClick={(event) => {
                event.preventDefault();
                onLink?.(segment.url!, segment.text, event.currentTarget);
              }}
            >
              {segment.text}
            </a>
          );
        return className ? (
          <span key={index} className={className}>
            {segment.text}
          </span>
        ) : (
          <span key={index}>{segment.text}</span>
        );
      })}
    </>
  );
}
