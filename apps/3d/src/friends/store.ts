// The panel's view of the helper: which views it holds, their latest snapshots, and the connection status. Views
// subscribe while they are on screen and unsubscribe when they leave; subscriptions never survive a reconnect
// (PROTOCOL.md § Lifecycle), so every one is sent again whenever the connection becomes ready.
import { useEffect, useState, useSyncExternalStore } from "react";
import type { FriendsBridge, FriendsEvent } from "./bridge";
import type { FriendsStatus, Reply, Snapshot } from "./protocol";

type Intent = {
  type: "subscribe" | "open_conversation";
  fields: Record<string, unknown>;
};
type Held = {
  key: string;
  intent: Intent;
  id?: string;
  rev: number;
  data: unknown;
  filter: string;
  users: number;
  generation: number;
  /** Failed opens in a row, for the retry's backoff. */
  failures: number;
};

export const IDLE_STATUS: FriendsStatus = {
  available: false,
  enabled: true,
  attached: false,
  state: "idle",
  text: "",
  strings: null,
  capabilities: [],
  limits: null,
  badge: null,
};

export class FriendsStore {
  status: FriendsStatus;
  private held = new Map<string, Held>();
  private byId = new Map<string, Held>();
  private early = new Map<string, Snapshot>();
  private listeners = new Set<() => void>();
  private version = 0;
  private linkListeners = new Set<(payload: string) => void>();
  private pendingLink: string | undefined;
  // The conversation the person is looking at in this window (set_focus, PROTOCOL.md § Notifications), and what
  // the helper was last told on this connection; it forgets when the connection closes.
  private focusWanted: string | null = null;
  private focusSent: string | null = null;

  constructor(
    readonly bridge: FriendsBridge,
    status: FriendsStatus = IDLE_STATUS,
  ) {
    this.status = status;
  }

  get ready() {
    return this.status.state === "ready";
  }
  get strings() {
    return this.status.strings ?? {};
  }
  has(capability: string) {
    return this.status.capabilities.includes(capability);
  }

  subscribeChanges = (listener: () => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };
  snapshotVersion = () => this.version;
  private changed() {
    this.version++;
    for (const listener of this.listeners) listener();
  }

  /** Every event from the bridge passes through here. */
  handle(event: FriendsEvent) {
    switch (event.kind) {
      case "status":
        this.setStatus(event.status);
        break;
      case "badge":
        this.status = { ...this.status, badge: event.data };
        this.changed();
        break;
      case "snapshot":
        this.snapshot(event.frame);
        break;
      case "link":
        if (this.linkListeners.size)
          for (const listener of this.linkListeners) listener(event.payload);
        else this.pendingLink = event.payload;
        break;
    }
  }

  onLink(listener: (payload: string) => void) {
    this.linkListeners.add(listener);
    if (this.pendingLink) {
      const payload = this.pendingLink;
      this.pendingLink = undefined;
      listener(payload);
    }
    return () => this.linkListeners.delete(listener);
  }

  setStatus(status: FriendsStatus) {
    const wasReady = this.ready;
    this.status = status;
    if (!this.ready) {
      // Subscription ids from this connection are void; the views keep their last snapshot meanwhile.
      for (const held of this.held.values()) held.id = undefined;
      this.byId.clear();
      this.early.clear();
      this.focusSent = null;
    } else {
      if (!wasReady)
        for (const held of this.held.values()) void this.open(held);
      this.sendFocus();
    }
    this.changed();
  }

  /** The conversation this window shows while it is focused and visible, or null: sent with set_focus when it
   * changes and the helper posts notifications, and again after a reconnect. */
  setFocus(conversationId: string | null) {
    this.focusWanted = conversationId;
    this.sendFocus();
  }
  private sendFocus() {
    if (!this.ready || !this.has("notifications")) return;
    if (this.focusWanted === this.focusSent) return;
    this.focusSent = this.focusWanted;
    void this.send("set_focus", { conversation_id: this.focusWanted });
  }

  private snapshot(frame: Snapshot) {
    const held = this.byId.get(frame.subscription);
    if (!held) {
      // The first snapshot can arrive before the reply naming its subscription.
      this.early.set(frame.subscription, frame);
      if (this.early.size > 32)
        this.early.delete(this.early.keys().next().value!);
      return;
    }
    this.apply(held, frame);
  }

  private apply(held: Held, frame: Snapshot) {
    if (held.id !== frame.subscription) return;
    if (frame.rev <= held.rev && held.data !== undefined) return;
    held.rev = frame.rev;
    held.data = frame.data;
    this.changed();
  }

  private async open(held: Held) {
    if (!this.ready || held.id) return;
    const generation = ++held.generation;
    let answer: Awaited<ReturnType<FriendsBridge["send"]>>;
    try {
      answer = await this.bridge.send(held.intent.type, held.intent.fields);
    } catch {
      this.openAgain(held, generation);
      return;
    }
    const { reply, snapshot } = answer;
    if (generation !== held.generation || !this.held.has(held.key)) {
      // Released or re-opened meanwhile: drop this subscription.
      const id = reply.ok
        ? (reply.result?.subscription as string | undefined)
        : undefined;
      if (id) void this.bridge.send("unsubscribe", { subscription: id });
      return;
    }
    if (!reply.ok) {
      // Not opened (the helper was still starting, or the connection changed under it): asked again, so a view
      // never stays on "Loading…" while Friends is ready.
      this.openAgain(held, generation);
      return;
    }
    const id = reply.result?.subscription;
    if (typeof id !== "string") return;
    held.failures = 0;
    held.id = id;
    held.rev = 0;
    this.byId.set(id, held);
    const first = snapshot ?? this.early.get(id);
    this.early.delete(id);
    if (first) this.apply(held, first);
    if (held.filter)
      void this.bridge.send("set_filter", {
        subscription: id,
        query: held.filter,
      });
  }

  /** Opens `held` again after a failed open, backing off to 10 s, while it is still held and nothing newer ran. */
  private openAgain(held: Held, generation: number) {
    held.failures++;
    const delay = Math.min(10_000, 250 * 2 ** Math.min(held.failures, 6));
    setTimeout(() => {
      if (this.held.get(held.key) !== held || held.generation !== generation)
        return;
      void this.open(held);
    }, delay);
  }

  /** Holds a view while a component shows it. Returns a release function. */
  hold(key: string, intent: Intent) {
    let held = this.held.get(key);
    if (!held) {
      held = {
        key,
        intent,
        rev: 0,
        data: undefined,
        filter: "",
        users: 0,
        generation: 0,
        failures: 0,
      };
      this.held.set(key, held);
      void this.open(held);
    }
    held.users++;
    const target = held;
    return () => {
      target.users--;
      if (target.users > 0) return;
      this.held.delete(key);
      target.generation++;
      if (target.id) {
        this.byId.delete(target.id);
        void this.bridge.send("unsubscribe", { subscription: target.id });
      }
    };
  }

  data<T>(key: string): T | undefined {
    return this.held.get(key)?.data as T | undefined;
  }
  subscriptionId(key: string) {
    return this.held.get(key)?.id;
  }

  /** set_filter on a list or nearby subscription; kept and sent again after a reconnect. */
  setFilter(key: string, query: string) {
    const held = this.held.get(key);
    if (!held || held.filter === query) return;
    held.filter = query;
    if (held.id)
      void this.bridge.send("set_filter", { subscription: held.id, query });
  }

  /** One intent; resolves with its reply (never rejects: a bridge failure reads as not ready). */
  async send(
    type: string,
    fields: Record<string, unknown> = {},
  ): Promise<Reply> {
    try {
      return (await this.bridge.send(type, fields)).reply;
    } catch {
      return {
        type: "reply",
        re: null,
        ok: false,
        error: {
          code: "not_ready",
          message: null,
          retryable: true,
          details: {},
        },
      };
    }
  }

  /** Releases every view, as when the panel closes. */
  releaseAll() {
    for (const held of this.held.values()) {
      held.generation++;
      if (held.id)
        void this.bridge.send("unsubscribe", { subscription: held.id });
    }
    this.held.clear();
    this.byId.clear();
    this.early.clear();
  }
}

/** Re-renders on every change in the store. */
export function useFriendsStore(store: FriendsStore) {
  useSyncExternalStore(
    store.subscribeChanges,
    store.snapshotVersion,
    store.snapshotVersion,
  );
  return store;
}

/** Holds one view while the calling component is mounted; returns its latest data. */
export function useView<T>(
  store: FriendsStore,
  key: string | null,
  intent: Intent | null,
): T | undefined {
  useFriendsStore(store);
  const [stable] = useState(() => new Map<string, Intent>());
  if (key && intent && !stable.has(key)) stable.set(key, intent);
  useEffect(() => {
    if (!key) return;
    const value = stable.get(key) ?? intent;
    if (!value) return;
    return store.hold(key, value);
    // The intent is fixed per key: a different conversation is a different key.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [store, key]);
  return key ? store.data<T>(key) : undefined;
}
