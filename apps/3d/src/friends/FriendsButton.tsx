// The Friends button in the app header and the Friends slot in Settings. App.tsx loads this file only once the
// bridge has said Friends runs here (status.ts), after the first paint; the dropdown and the Settings section load
// on first use (FriendsPanel.tsx).
import { lazy, Suspense, useEffect, useRef, useState } from "react";
import { friendsBridge } from "./bridge";
import type { AttachSource } from "./Composer";
import type { Outgoing } from "./ListPage";
import { stageProject } from "./staging";
import { DownloadLinkButton } from "./DownloadLinkButton";
import { filesFromDrop } from "./drops";
import { attachSource, type RecentFiles } from "./recent-attach";
import type { RecentEntry } from "../core/recent-files";
import {
  copyDownloadLink,
  downloadLinkRequests,
  offersLinks,
} from "./download-link";
import {
  pendingLink,
  pendingOpen,
  pendingShare,
  publish,
  shareWithFriend,
  useFriendsStatus,
} from "./status";
import {
  friendsRequests,
  friendsShortcutLabel,
  type FriendsRequest,
} from "./requests";
import "./button.css";

const FriendsPanel = lazy(() => import("./FriendsPanel"));
const FriendsSettingsSection = lazy(() =>
  import("./FriendsPanel").then((module) => ({
    default: module.FriendsSettings,
  })),
);

/**
 * Everything Friends puts in the header: Send to a Friend and Copy Download Link while a model is open, and the
 * Friends button. The open model, as a project file, and the recent files are what `#` offers in a conversation.
 */
export function FriendsHeader({
  projectName,
  recent = [],
  buildProject,
  onError,
  onNotice,
  onAvailable,
}: {
  projectName: string | null;
  /** The app's recent files, most recently opened first. */
  recent?: RecentEntry[];
  buildProject(): Promise<{ blob: Blob; name: string }>;
  onError(message: string): void;
  /** A short confirmation, such as the helper's words after a link was copied. */
  onNotice(message: string): void;
  /** Whether Friends runs and is on, so the app shows its Friends commands only then. */
  onAvailable?(available: boolean): void;
}) {
  const status = useFriendsStatus();
  const [busy, setBusy] = useState(false);
  const [linking, setLinking] = useState(false);
  const build = useRef(buildProject);
  build.current = buildProject;
  const bridge = friendsBridge();
  const available = Boolean(status?.available);
  const on = Boolean(bridge && status?.available && status.enabled);
  useEffect(() => onAvailable?.(on), [onAvailable, on]);
  // File ▸ Copy Download Link is enabled only for a window with a model open.
  useEffect(() => {
    if (!bridge || !available) return;
    const open = Boolean(projectName);
    void bridge.shareable(open).catch(() => {});
    return () => void bridge.shareable(false).catch(() => {});
  }, [bridge, available, projectName]);
  const copyLink = useRef<(days: number) => void>(() => {});
  copyLink.current = async (days: number) => {
    if (!bridge || !projectName || linking || !offersLinks(status)) return;
    setLinking(true);
    try {
      const { copied, message } = await copyDownloadLink(
        bridge,
        () =>
          stageProject(
            bridge,
            () => build.current(),
            () => {},
          ),
        (text) => navigator.clipboard.writeText(text),
        days,
      );
      if (message) (copied ? onNotice : onError)(message);
    } finally {
      setLinking(false);
    }
  };
  useEffect(
    () => downloadLinkRequests.listen((days) => copyLink.current(days)),
    [],
  );
  if (!bridge || !status?.available || !status.enabled) return null;
  const stage = () => stageProject(bridge, () => build.current(), onError);
  const attach: AttachSource | null = attachSource({
    projectName,
    stageProject: stage,
    recent,
    bridge,
    files: recentFiles,
  });
  return (
    <>
      {projectName && (
        <button
          type="button"
          className="icon-button"
          title="Send project to a friend"
          aria-label="Send project to a friend"
          disabled={busy}
          onClick={async () => {
            setBusy(true);
            try {
              shareWithFriend([await stage()]);
            } catch {
              /* stage() has said so. */
            } finally {
              setBusy(false);
            }
          }}
        >
          {/* lucide's "send", drawn here so this chunk shares no icon code with the app's first chunk. */}
          <svg
            width="18"
            height="18"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
            aria-hidden="true"
          >
            <path
              d={
                "M14.536 21.686a.5.5 0 0 0 .937-.024l6.5-19a.496.496 0 0 0-.635-.635l-19 6.5a.5.5 0 0 " +
                "0-.024.937l7.93 3.18a2 2 0 0 1 1.112 1.11z"
              }
            />
            <path d="m21.854 2.147-10.94 10.939" />
          </svg>
        </button>
      )}
      {projectName && offersLinks(status) && (
        <DownloadLinkButton
          busy={linking}
          onChoose={(days) => copyLink.current(days)}
        />
      )}
      <FriendsButton attach={attach} />
    </>
  );
}

// The recent-files store loads with the app's own chunk for it, only when a `#` item is chosen.
const recentFiles: RecentFiles = {
  paths: async (entry) =>
    (await import("../core/recent-files")).recentPaths(entry),
  open: async (entry) =>
    (await import("../core/recent-files")).openRecent(entry),
};

export function FriendsButton({ attach }: { attach: AttachSource | null }) {
  const status = useFriendsStatus();
  const bridge = friendsBridge();
  const [open, setOpen] = useState(false);
  const [outgoing, setOutgoing] = useState<Outgoing | null>(null);
  const [link, setLink] = useState<string | null>(null);
  const [openAt, setOpenAt] = useState<{
    conversation_id: string | null;
  } | null>(null);
  const [refusal, setRefusal] = useState<string | null>(null);
  const [dragging, setDragging] = useState(false);
  const spring = useRef<number | undefined>(undefined);
  const root = useRef<HTMLDivElement>(null);
  useEffect(
    () =>
      pendingShare.listen((value) => {
        setOutgoing(value);
        setOpen(true);
      }),
    [],
  );
  useEffect(
    () =>
      pendingLink.listen((payload) => {
        setLink(payload);
        setOpen(true);
      }),
    [],
  );
  // A notification clicked: the dropdown opens on its conversation (or the list).
  useEffect(
    () =>
      pendingOpen.listen((target) => {
        setOutgoing(null);
        setOpenAt(target);
        setOpen(true);
      }),
    [],
  );
  // Cmd/Ctrl+J, the command palette's Friends commands and View ▸ Friends (requests.ts).
  const isOpen = useRef(open);
  isOpen.current = open;
  useEffect(() => {
    const show = async (request: FriendsRequest) => {
      if (
        request === "add_by_id" ||
        request === "visible" ||
        request === "join"
      ) {
        const panel = await import("./FriendsPanel");
        panel.openNextAt(
          request === "add_by_id"
            ? "profile"
            : request === "join"
              ? "join"
              : "nearby",
        );
        // The dropdown takes the page it opens on when it opens, so an open one closes first.
        if (isOpen.current) {
          setOpen(false);
          await nextFrame();
        }
      }
      setOutgoing(null);
      setOpen(true);
      const dropdown = await until(() =>
        root.current?.querySelector<HTMLElement>('[data-szfriends="dropdown"]'),
      );
      if (!dropdown) return;
      if (request === "visible")
        void friendsBridge()
          ?.send("start_visibility")
          .catch(() => {});
      // Typing goes where the person will type: the ID field for Add by ID, else the search field. A dropdown
      // reopening on a conversation keeps its own focus.
      const field = await until(() =>
        request === "join"
          ? dropdown.querySelector<HTMLInputElement>("input")
          : request === "add_by_id"
            ? // The profile page's last field is Add by ID's (its name, when it can be changed, comes first).
              [
                ...dropdown.querySelectorAll<HTMLInputElement>(
                  "form.szf-field input",
                ),
              ].at(-1)
            : dropdown.querySelector<HTMLInputElement>('input[type="search"]'),
      );
      field?.focus();
    };
    return friendsRequests.listen((request) => {
      if (request === "toggle" && isOpen.current) {
        setOpen(false);
        setOutgoing(null);
      } else void show(request);
    });
  }, []);
  // A click in the window closes the dropdown; a drag from another app does not, so files can still arrive.
  useEffect(() => {
    if (!open) return;
    const down = (event: PointerEvent) => {
      if (root.current && !root.current.contains(event.target as Node)) {
        setOpen(false);
        setOutgoing(null);
      }
    };
    window.addEventListener("pointerdown", down, true);
    return () => window.removeEventListener("pointerdown", down, true);
  }, [open]);
  if (!bridge || !status?.available || !status.enabled) return null;
  const badge = status.badge;
  const strings = status.strings ?? {};
  const label = badge?.accessibility_label || strings.button_label;
  return (
    <div className="friends-anchor" ref={root}>
      <button
        type="button"
        className={`icon-button friends-button ${open ? "active" : ""} ${dragging ? "drop-target" : ""}`}
        // "Friends (Beta) · ⌘J": the tooltip says Friends is a beta; an older helper gives the plain name.
        title={
          strings.button_tooltip || strings.button_label
            ? `${strings.button_tooltip || strings.button_label} · ${friendsShortcutLabel}`
            : undefined
        }
        aria-label={label}
        aria-keyshortcuts={
          friendsShortcutLabel.startsWith("⌘") ? "Meta+J" : "Control+J"
        }
        aria-expanded={open}
        data-szfriends="button"
        onClick={() => {
          setOpen((old) => !old);
          setOutgoing(null);
        }}
        onDragEnter={(event) => {
          if (!Array.from(event.dataTransfer.types).includes("Files")) return;
          setDragging(true);
          // Spring-loaded: holding files over the button opens the list, so the drop can land on a row.
          window.clearTimeout(spring.current);
          spring.current = window.setTimeout(() => setOpen(true), 500);
        }}
        onDragOver={(event) => {
          if (!Array.from(event.dataTransfer.types).includes("Files")) return;
          event.preventDefault();
          event.stopPropagation();
        }}
        onDragLeave={() => {
          setDragging(false);
          window.clearTimeout(spring.current);
        }}
        onDrop={async (event) => {
          event.preventDefault();
          event.stopPropagation();
          setDragging(false);
          window.clearTimeout(spring.current);
          const list = Array.from(event.dataTransfer.files);
          const dropped = await filesFromDrop(bridge, strings, list);
          setOpen(true);
          // Released on the button: the dropdown stays open with "Send 2 files to…" and sends to the friend
          // clicked next. Anything but regular files is refused, with the helper's words.
          if (dropped.files.length)
            setOutgoing({
              files: dropped.files,
              names: dropped.files.map((file) => file.display_name),
            });
          else setRefusal(dropped.refusal);
        }}
      >
        <svg width="18" height="18" viewBox="0 0 16 16" aria-hidden="true">
          <path
            fill="currentColor"
            fillRule="evenodd"
            d={
              "M2.85 5.5A3.15 3.15 0 1 1 9.15 5.5A3.15 3.15 0 1 1 2.85 5.5ZM4.15 5.5A1.85 1.85 0 1 0 " +
              "7.85 5.5A1.85 1.85 0 1 0 4.15 5.5ZM2.15 13.5C2.15 12.43 2.562 11.626 3.232 11.059C3.907 " +
              "10.488 4.877 10.15 6 10.15C7.123 10.15 8.093 10.488 8.768 11.059C9.438 11.626 9.85 " +
              "12.43 9.85 13.5A0.65 0.65 0 0 0 11.15 13.5C11.15 12.07 10.562 10.874 9.607 10.066C8.657 " +
              "9.262 7.377 8.85 6 8.85C4.623 8.85 3.343 9.262 2.393 10.066C1.438 10.874 0.85 12.07 " +
              "0.85 13.5A0.65 0.65 0 0 0 2.15 13.5ZM8.55 5A2.65 2.65 0 1 1 13.85 5A2.65 2.65 0 1 1 " +
              "8.55 5ZM9.85 5A1.35 1.35 0 1 0 12.55 5A1.35 1.35 0 1 0 9.85 5ZM11.168 10.049C12.024 " +
              "10.092 12.706 10.406 13.181 10.9C13.655 11.394 13.95 12.095 13.95 13A0.65 0.65 0 0 0 " +
              "15.25 13C15.25 11.805 14.845 10.756 14.119 10C13.394 9.244 12.376 8.808 11.232 8.751" +
              "A0.65 0.65 0 0 0 11.168 10.049Z"
            }
          />
        </svg>
        {badge && badge.count > 0 && (
          <span className="friends-badge">{badge.label}</span>
        )}
      </button>
      {open && (
        <Suspense fallback={null}>
          <FriendsPanel
            bridge={bridge}
            status={status}
            outgoing={outgoing}
            link={link}
            openAt={openAt}
            onOpenAtDone={() => setOpenAt(null)}
            attach={attach}
            onClose={() => setOpen(false)}
            onOutgoingDone={() => setOutgoing(null)}
            onLinkDone={() => setLink(null)}
            refusal={refusal}
            onRefusalShown={() => setRefusal(null)}
          />
        </Suspense>
      )}
    </div>
  );
}

const nextFrame = () =>
  new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
/** What `find` finds within about two seconds (the dropdown loads on first use, a page on its first snapshot). */
async function until<T>(find: () => T | null | undefined) {
  for (let frame = 0; frame < 120; frame++) {
    const found = find();
    if (found) return found;
    await nextFrame();
  }
  return null;
}

/** The Friends section of Settings, loaded when Settings first opens. */
export function FriendsSettingsSlot({ visible }: { visible: boolean }) {
  const status = useFriendsStatus();
  const bridge = friendsBridge();
  if (!bridge || !status?.available || !visible) return null;
  return (
    <Suspense fallback={null}>
      <FriendsSettingsSection
        bridge={bridge}
        status={status}
        onEnabled={publish}
      />
    </Suspense>
  );
}
