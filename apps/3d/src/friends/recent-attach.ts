// What `#` offers in a conversation in Shenzhen 3D: the open model as a project file, then the app's recent files,
// most recently opened first, as ShenzhenPDF offers its open and Collection documents (its SPDFMacFriendsAttachItems).
// Typing after `#` narrows the list by name or format, ignoring case and accents. Choosing a recent file attaches it
// as a dropped file is attached: on a desktop that keeps the file's path (Electron) it is sent from where it is; where
// recents are kept as copies (Tauri's Windows, Linux, Android and iOS builds, and files the browser store kept) its
// bytes are staged as a private copy for sending, so a phone's file still sends after the system's grant to the
// original (a content URI or a security-scoped URL) has lapsed. Nothing is sent until Send.
import type { RecentEntry } from "../core/recent-files";
import type { FriendsBridge } from "./bridge";
import type { AttachItem, AttachSource } from "./Composer";
import { AttachRefused, stageFiles, type OutgoingFile } from "./drops";

/** How the composer reaches a recent entry's files: its paths where the shell keeps them, else its bytes. */
export type RecentFiles = {
  paths(entry: RecentEntry): Promise<string[] | null>;
  open(entry: RecentEntry): Promise<File[]>;
};

const fold = (text: string) =>
  text
    .normalize("NFD")
    .replace(/\p{Diacritic}/gu, "")
    .toLowerCase();

export const matchesQuery = (query: string, ...texts: string[]) => {
  const wanted = fold(query.trim());
  return !wanted || texts.some((text) => fold(text).includes(wanted));
};

/** "Opened just now", "Opened 5 minutes ago", "Opened yesterday", or the day it was opened when over a week ago. */
export function openedLabel(openedAt: number, now: number): string {
  const minutes = Math.floor((now - openedAt) / 60_000);
  if (minutes < 1) return "Opened just now";
  const relative = new Intl.RelativeTimeFormat("en", { numeric: "auto" });
  if (minutes < 60) return `Opened ${relative.format(-minutes, "minute")}`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `Opened ${relative.format(-hours, "hour")}`;
  const days = Math.floor(hours / 24);
  if (days < 7) return `Opened ${relative.format(-days, "day")}`;
  const date = new Date(openedAt);
  const sameYear = date.getFullYear() === new Date(now).getFullYear();
  return `Opened ${date.toLocaleDateString("en", {
    month: "short",
    day: "numeric",
    ...(sameYear ? {} : { year: "numeric" }),
  })}`;
}

/** Said in the composer when a recent file is no longer where it was opened from. */
export const recentGone = (name: string) =>
  `${name} was moved or deleted after you opened it, so it can't be attached.`;
/** Said on a phone when a recent file is larger than the app can copy for sending. */
export const recentTooLarge = (name: string, limit: number) =>
  `${name} is too large to send from this device. Files can be up to ${Math.floor(limit / 1e6)} MB.`;

const basename = (file: string) => file.split(/[\\/]/).pop() || file;

export function recentItem(
  entry: RecentEntry,
  bridge: Pick<FriendsBridge, "classify" | "stage" | "stagedDropLimit">,
  files: RecentFiles,
  now: number,
): AttachItem {
  const count = entry.fileCount > 1 ? ` · ${entry.fileCount} files` : "";
  return {
    title: entry.name,
    detail: `${openedLabel(entry.openedAt, now)}${count}`,
    kind_label: (entry.format || "file").toUpperCase().slice(0, 4),
    async file(): Promise<OutgoingFile[]> {
      // A desktop sends files from where they are, as it sends a dropped file (phones have no paths).
      const paths = bridge.stagedDropLimit
        ? null
        : await files.paths(entry).catch(() => {
            throw new AttachRefused(recentGone(entry.name));
          });
      if (paths?.length) {
        const kinds = await bridge.classify(paths);
        if (kinds.some((kind) => kind !== "file"))
          throw new AttachRefused(recentGone(entry.name));
        return paths.map((path) => ({ path, display_name: basename(path) }));
      }
      const list = await files.open(entry).catch(() => {
        throw new AttachRefused(recentGone(entry.name));
      });
      const limit = bridge.stagedDropLimit;
      const large = limit ? list.find((file) => file.size > limit) : undefined;
      if (large && limit)
        throw new AttachRefused(recentTooLarge(large.name, limit));
      const staged = await stageFiles(bridge, list);
      if (!Array.isArray(staged))
        throw new AttachRefused(recentGone(entry.name));
      return staged;
    },
  };
}

/**
 * The `#` source for a conversation: the open model first (as a project file, with its notes and measurements),
 * then the recent files. Null when there is nothing to offer.
 */
export function attachSource({
  projectName,
  stageProject,
  recent,
  bridge,
  files,
  now = () => Date.now(),
}: {
  projectName: string | null;
  stageProject(): Promise<OutgoingFile>;
  recent: RecentEntry[];
  bridge: Pick<FriendsBridge, "classify" | "stage" | "stagedDropLimit">;
  files: RecentFiles;
  now?: () => number;
}): AttachSource | null {
  if (!projectName && !recent.length) return null;
  return {
    // Shenzhen 3D's own words for what `#` offers here (PROTOCOL.md § Principles).
    empty: "No matching files",
    items(query) {
      const items: AttachItem[] = [];
      if (projectName && matchesQuery(query, projectName))
        items.push({
          title: projectName,
          detail: "The open model, with its notes and measurements",
          kind_label: "SZ3D",
          badge: "Current",
          file: stageProject,
        });
      const time = now();
      for (const entry of recent)
        if (matchesQuery(query, entry.name, entry.format))
          items.push(recentItem(entry, bridge, files, time));
      return items;
    },
  };
}
