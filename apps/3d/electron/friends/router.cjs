// Routes the helper's frames to the windows that asked for them. Pure: no Electron, no sockets, so the rules below
// are unit-tested (electron/friends-router.test.cjs).
//
// - One client per app (the main process), shared by every window, as Shenzhen Files shares one per process.
// - Each intent remembers the window that sent it; its reply goes back to that window only.
// - A subscription belongs to the window whose subscribe or open_conversation created it. The helper sends the
//   first snapshot before the reply that names the subscription (PROTOCOL.md § Snapshots), so a snapshot for a
//   subscription nobody owns yet is held (the latest one only; snapshots are complete) and handed over with the
//   reply.
// - The badge is the bridge's own subscription, sent to every window, so many windows cost one subscription.
// - Subscription ids never survive a reconnect: when the connection is no longer ready, every owner is forgotten
//   and the windows subscribe again once it is.
const HOST = "host";
const MAX_HELD = 64;
const MAX_SUBSCRIPTIONS_PER_WINDOW = 12;

function connectionLost(id) {
  return {
    type: "reply",
    re: id,
    ok: false,
    error: {
      code: "connection_lost",
      message: null,
      retryable: true,
      details: {},
    },
  };
}
function notReady() {
  return {
    type: "reply",
    re: null,
    ok: false,
    error: { code: "not_ready", message: null, retryable: true, details: {} },
  };
}

class FriendsRouter {
  /** deliver(owner, event) sends an event to one window; broadcast(event) to every window that joined. */
  constructor({ deliver, broadcast, hostSnapshot }) {
    this.deliver = deliver;
    this.broadcast = broadcast;
    // The bridge's own subscriptions other than the badge (the `received` view): their snapshots go here.
    this.hostSnapshot = hostSnapshot ?? (() => {});
    this.pending = new Map(); // intent id -> {owner, type, resolve}
    this.owners = new Map(); // subscription id -> owner
    this.held = new Map(); // subscription id -> latest snapshot frame nobody owns yet
    this.welcome = null;
    this.badge = null;
  }

  /** Records an intent the client library accepted; resolves with {reply, snapshot?} once its reply arrives. */
  sent(id, owner, type, fields = {}) {
    return new Promise((resolve) =>
      this.pending.set(id, { owner, type, fields, resolve }),
    );
  }

  subscriptionCount(owner) {
    let count = 0;
    for (const value of this.owners.values()) if (value === owner) count++;
    for (const value of this.pending.values())
      if (
        value.owner === owner &&
        (value.type === "subscribe" || value.type === "open_conversation")
      )
        count++;
    return count;
  }
  mayAddSubscription(owner) {
    return this.subscriptionCount(owner) < MAX_SUBSCRIPTIONS_PER_WINDOW;
  }

  /** One frame from the helper (already parsed). */
  frame(frame) {
    if (!frame || typeof frame !== "object") return;
    switch (frame.type) {
      case "welcome":
        this.welcome = frame;
        return;
      case "reply":
        return this.reply(frame);
      case "snapshot":
        return this.snapshot(frame);
      default:
        // goodbye: the client library reports the state change that follows; unknown types are ignored.
        return;
    }
  }

  reply(frame) {
    const entry =
      typeof frame.re === "string" ? this.pending.get(frame.re) : undefined;
    if (!entry) return;
    this.pending.delete(frame.re);
    let snapshot;
    const subscription = frame.ok ? frame.result?.subscription : undefined;
    if (
      typeof subscription === "string" &&
      (entry.type === "subscribe" || entry.type === "open_conversation")
    ) {
      this.owners.set(subscription, entry.owner);
      snapshot = this.held.get(subscription);
      this.held.delete(subscription);
      if (entry.owner === HOST && snapshot?.view === "badge")
        this.badgeSnapshot(snapshot);
      else if (entry.owner === HOST && snapshot) this.hostSnapshot(snapshot);
      if (entry.owner === HOST) snapshot = undefined;
    }
    if (
      entry.type === "unsubscribe" &&
      this.owners.get(entry.fields?.subscription) === entry.owner
    ) {
      // Nothing more arrives for it; forget the owner so a later reuse of the id cannot reach the old window.
      this.owners.delete(entry.fields.subscription);
    }
    entry.resolve({ reply: frame, snapshot });
  }

  snapshot(frame) {
    const subscription = frame.subscription;
    if (typeof subscription !== "string") return;
    const owner = this.owners.get(subscription);
    if (owner === undefined) {
      if (this.held.size >= MAX_HELD && !this.held.has(subscription))
        this.held.delete(this.held.keys().next().value);
      this.held.set(subscription, frame);
      return;
    }
    if (owner === HOST) {
      if (frame.view === "badge") this.badgeSnapshot(frame);
      else this.hostSnapshot(frame);
      return;
    }
    this.deliver(owner, { kind: "snapshot", frame });
  }

  badgeSnapshot(frame) {
    this.badge = frame.data ?? null;
    this.broadcast({ kind: "badge", data: this.badge });
  }

  /** A window closed or reloaded: the subscriptions to unsubscribe for it. Its pending intents resolve as lost. */
  dropOwner(owner) {
    const subscriptions = [];
    for (const [subscription, value] of this.owners)
      if (value === owner) {
        subscriptions.push(subscription);
        this.owners.delete(subscription);
      }
    for (const [id, entry] of this.pending)
      if (entry.owner === owner) {
        this.pending.delete(id);
        entry.resolve({ reply: connectionLost(id) });
      }
    return subscriptions;
  }

  /** The connection left READY: subscriptions are void (the windows subscribe again once it is back). */
  connectionChanged(state) {
    if (state === "ready") return;
    this.owners.clear();
    this.held.clear();
    this.welcome = null;
    if (this.badge !== null) {
      this.badge = null;
      this.broadcast({ kind: "badge", data: null });
    }
  }

  /** The client was stopped: the library drops waiting intents without replies, so the bridge answers them. */
  stopped() {
    for (const [id, entry] of this.pending)
      entry.resolve({ reply: connectionLost(id) });
    this.pending.clear();
    this.connectionChanged("idle");
  }
}

module.exports = {
  FriendsRouter,
  HOST,
  MAX_SUBSCRIPTIONS_PER_WINDOW,
  notReady,
  connectionLost,
};
