// Copy Download Link for the open model (PROTOCOL.md § Links, "Copying a download link"). The header's button and
// File ▸ Copy Download Link (electron/friends/share-menu.cjs) both come here: the open model is staged as a project,
// make_download_link is sent with it, and the link goes on the clipboard once the helper answers. The helper's
// message then says until when, and while what, the link works.
import type { FriendsBridge } from "./bridge";
import type { OutgoingFile } from "./drops";
import type { FriendsStatus, Reply } from "./protocol";

// Shenzhen 3D's own words, as in ShenzhenPDF and Shenzhen Files, and the same choices as its File menu: 7 days first.
export const COPY_DOWNLOAD_LINK = "Copy Download Link";
export const EXPIRY_CHOICES = [
  { days: 7, label: "For 7 Days" },
  { days: 1, label: "For 1 Day" },
  { days: 30, label: "For 30 Days" },
] as const;
/** The open model could not be saved for the link, so nothing was shared. */
export const LINK_STAGE_FAILED =
  "Could not make a download link for this model. Try again.";
/** The link exists, but the clipboard refused it. */
export const LINK_NOT_COPIED =
  "The download link could not be copied. Try again.";

export const isExpiry = (days: unknown): days is 1 | 7 | 30 =>
  days === 1 || days === 7 || days === 30;

/** Friends runs, is on and ready, and its helper makes links: only then is Copy Download Link offered. */
export function offersLinks(status: FriendsStatus | null | undefined) {
  return Boolean(
    status?.available &&
    status.enabled &&
    status.state === "ready" &&
    status.capabilities.includes("links"),
  );
}

export type LinkOutcome = { copied: boolean; message: string | null };

/**
 * Stages the model, asks the helper for a link valid `days`, and copies it. `message` is what to tell the person:
 * the helper's words on success or refusal, the app's own when staging or the clipboard failed, null when nothing
 * needs saying (the connection line covers a helper that is not there).
 */
export async function copyDownloadLink(
  bridge: Pick<FriendsBridge, "send">,
  stage: () => Promise<OutgoingFile>,
  writeText: (text: string) => Promise<void>,
  days: number,
): Promise<LinkOutcome> {
  if (!isExpiry(days)) return { copied: false, message: null };
  let file: OutgoingFile;
  try {
    file = await stage();
  } catch {
    return { copied: false, message: LINK_STAGE_FAILED };
  }
  let reply: Reply;
  try {
    ({ reply } = await bridge.send("make_download_link", {
      file,
      expires_days: days,
    }));
  } catch {
    return { copied: false, message: null };
  }
  if (!reply.ok)
    return { copied: false, message: reply.error?.message ?? null };
  const url = reply.result?.url;
  const message = reply.result?.message;
  if (typeof url !== "string" || !url) return { copied: false, message: null };
  try {
    await writeText(url);
  } catch {
    return { copied: false, message: LINK_NOT_COPIED };
  }
  return {
    copied: true,
    message: typeof message === "string" && message ? message : null,
  };
}

// File ▸ Copy Download Link: the main process asks the focused window, and its header answers.
const requests = new Set<(days: number) => void>();
export const downloadLinkRequests = {
  request(days: number) {
    if (!isExpiry(days)) return;
    for (const listener of requests) listener(days);
  },
  listen(listener: (days: number) => void) {
    requests.add(listener);
    return () => {
      requests.delete(listener);
    };
  },
};
