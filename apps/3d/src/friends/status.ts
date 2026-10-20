// Friends' status for the header: whether it runs and is on, its badge, and the requests to send files to a friend
// or to show a link's card, shared by the header's pieces and Settings.
import { useEffect, useState } from "react";
import { friendsBridge, type FriendsEvent } from "./bridge";
import type { FriendsStatus } from "./protocol";
import type { Outgoing } from "./ListPage";
import type { OutgoingFile } from "./drops";
import { downloadLinkRequests } from "./download-link";
import { friendsRequests } from "./requests";

// Joins at an idle moment: this file loads a second after the first paint already (App.tsx), as the main process
// loads Friends no sooner (docs/FRIENDS.md § Startup).
function afterFirstPaint(callback: () => void) {
  let cancelled = false;
  const run = () => !cancelled && callback();
  if (typeof window.requestIdleCallback === "function")
    window.requestIdleCallback(run, { timeout: 1500 });
  else setTimeout(run, 0);
  return () => {
    cancelled = true;
  };
}

let statusCache: FriendsStatus | null = null;
const statusListeners = new Set<(status: FriendsStatus) => void>();
let joined = false;
export function publish(status: FriendsStatus) {
  statusCache = status;
  for (const listener of statusListeners) listener(status);
}
export function useFriendsStatus() {
  const [status, setStatus] = useState<FriendsStatus | null>(statusCache);
  useEffect(() => {
    const bridge = friendsBridge();
    if (!bridge) return;
    statusListeners.add(setStatus);
    let stop = () => {};
    if (!joined) {
      joined = true;
      stop = afterFirstPaint(() => {
        bridge.subscribe((event: FriendsEvent) => {
          if (event.kind === "status") publish(event.status);
          else if (event.kind === "badge" && statusCache)
            publish({ ...statusCache, badge: event.data });
          else if (event.kind === "link") pendingLink.request(event.payload);
          else if (event.kind === "copy_download_link")
            downloadLinkRequests.request(event.days);
          else if (event.kind === "toggle") friendsRequests.request("toggle");
        });
        void bridge.join().then(publish, () => {});
      });
    }
    return () => {
      stop();
      statusListeners.delete(setStatus);
    };
  }, []);
  return status;
}

/** Requests from the rest of the app: send files to a friend chosen next, or show a Friends link's card. */
function channel<T>() {
  let listener: ((value: T) => void) | null = null;
  let waiting: T | null = null;
  return {
    request(value: T) {
      if (listener) listener(value);
      else waiting = value;
    },
    listen(next: (value: T) => void) {
      listener = next;
      if (waiting !== null) {
        const value = waiting;
        waiting = null;
        next(value);
      }
      return () => {
        if (listener === next) listener = null;
      };
    },
  };
}
export const pendingShare = channel<Outgoing>();
export const pendingLink = channel<string>();

/** Whether Friends runs in this build and is on: the app shows its Friends commands only then. */
export function useFriendsAvailable() {
  const status = useFriendsStatus();
  return Boolean(status?.available && status.enabled);
}
/** Opens Friends to choose who receives these files ("Send Gearbox.sz3d to…"). */
export function shareWithFriend(files: OutgoingFile[]) {
  pendingShare.request({
    files,
    names: files.map((file) => file.display_name),
  });
}
