// What the renderer may ask of Friends, checked in the main process before anything reaches the helper.
//
// The renderer is the app's own page (app://local), but it renders other people's names, messages and file names,
// so the bridge treats what it sends as untrusted: only the intents the panel uses, only the fields each one takes,
// with the types PROTOCOL.md § Schemas gives them, opaque ids in their documented alphabet, and file paths that are
// absolute and plain. The helper then applies its own rules (sizes, existence, folders, friendship) and answers
// with display-ready errors; the bridge never duplicates those, it only keeps malformed input from going out.
const path = require("node:path");

const OPAQUE_ID = /^[A-Za-z0-9_-]{1,64}$/;
const MAX_FRAME_BYTES = 8 * 1024 * 1024;
const MAX_PATH_BYTES = 1024;
const MAX_TEXT_BYTES = 32768;
const MAX_SHORT_TEXT = 512;
// The views this panel subscribes to. message_status is for host surfaces outside Friends; Shenzhen 3D has none.
const VIEWS = new Set([
  "badge",
  "list",
  "nearby",
  "details",
  "profile",
  "settings",
  "join",
  // The files received here, which the app adds to its recent files.
  "received",
]);

const isObject = (value) =>
  value !== null && typeof value === "object" && !Array.isArray(value);
const byteLength = (text) => Buffer.byteLength(text, "utf8");

class FriendsFieldError extends Error {
  constructor(field) {
    super(`invalid ${field}`);
    this.field = field;
  }
}
function fail(field) {
  throw new FriendsFieldError(field);
}

function opaque(fields, key, { optional = false } = {}) {
  const value = fields[key];
  if (optional && (value === undefined || value === null)) return;
  if (typeof value !== "string" || !OPAQUE_ID.test(value)) fail(key);
}
function text(fields, key, max = MAX_SHORT_TEXT, { optional = false } = {}) {
  const value = fields[key];
  if (optional && (value === undefined || value === null)) return;
  if (
    typeof value !== "string" ||
    byteLength(value) > max ||
    value.includes("\0")
  )
    fail(key);
}
function bool(fields, key, { optional = false } = {}) {
  const value = fields[key];
  if (optional && value === undefined) return;
  if (typeof value !== "boolean") fail(key);
}

// An absolute, normalized path naming a file the person chose: dropped on Friends, staged by Shenzhen 3D itself
// (the open model as a project), or picked as their picture. Whether it exists, is a folder or is readable is the
// helper's call, with its own words.
function plainPath(value, field) {
  if (
    typeof value !== "string" ||
    !value ||
    value.includes("\0") ||
    byteLength(value) > MAX_PATH_BYTES ||
    !path.isAbsolute(value) ||
    path.normalize(value) !== value ||
    value.endsWith("/")
  )
    fail(field);
}

// PROTOCOL.md file object. Shenzhen 3D sends plain files only: their bytes at that moment are what the person
// meant, so a revision is never attached.
function fileObject(value, field) {
  if (!isObject(value)) fail(field);
  for (const key of Object.keys(value))
    if (!["path", "display_name", "revision"].includes(key))
      fail(`${field}.${key}`);
  plainPath(value.path, `${field}.path`);
  if (value.display_name !== undefined) {
    if (
      typeof value.display_name !== "string" ||
      !value.display_name ||
      byteLength(value.display_name) > 1024
    )
      fail(`${field}.display_name`);
  }
  if (value.revision !== undefined && value.revision !== null)
    fail(`${field}.revision`);
}
function fileList(fields, key, max) {
  const value = fields[key];
  if (!Array.isArray(value) || value.length < 1 || value.length > max)
    fail(key);
  value.forEach((file, index) => fileObject(file, `${key}[${index}]`));
}
function clientToken(fields) {
  const value = fields.client_token;
  if (typeof value !== "string" || !/^[\x21-\x7e]{16,64}$/.test(value))
    fail("client_token");
}

// Each intent's allowed keys and their checks. Intents not listed here never leave the main process: hello and
// disable belong to the bridge itself, and the assistant intents to hosts with an AI chat.
const INTENTS = {
  ping: {},
  activate: {},
  subscribe: {
    keys: ["view", "params"],
    check(fields) {
      if (!VIEWS.has(fields.view)) fail("view");
      if (fields.params === undefined || fields.params === null) {
        if (fields.view === "details") fail("params");
        return;
      }
      if (!isObject(fields.params)) fail("params");
      const keys = Object.keys(fields.params);
      if (fields.view === "details") {
        if (keys.length !== 1 || keys[0] !== "conversation_id") fail("params");
        opaque(fields.params, "conversation_id");
      } else if (keys.length) fail("params");
    },
  },
  unsubscribe: { keys: ["subscription"], ids: ["subscription"] },
  set_filter: {
    keys: ["subscription", "query"],
    ids: ["subscription"],
    check: (fields) => text(fields, "query", 800),
  },
  open_conversation: {
    keys: ["conversation_id", "message_id"],
    ids: ["conversation_id"],
    check: (fields) => opaque(fields, "message_id", { optional: true }),
  },
  load_earlier: { keys: ["subscription"], ids: ["subscription"] },
  send_message: {
    keys: [
      "conversation_id",
      "text",
      "client_token",
      "attachments",
      "mentions",
    ],
    ids: ["conversation_id"],
    check(fields) {
      text(fields, "text", MAX_TEXT_BYTES * 4);
      clientToken(fields);
      if (fields.attachments !== undefined) fileList(fields, "attachments", 20);
      if (fields.mentions !== undefined) {
        if (!Array.isArray(fields.mentions) || fields.mentions.length > 20)
          fail("mentions");
        fields.mentions.forEach((mention, index) => {
          if (
            !isObject(mention) ||
            Object.keys(mention).join() !== "conversation_id"
          )
            fail(`mentions[${index}]`);
          opaque(mention, "conversation_id");
        });
      }
    },
  },
  send_files: {
    keys: ["conversation_id", "files", "client_token"],
    ids: ["conversation_id"],
    check(fields) {
      fileList(fields, "files", 100);
      clientToken(fields);
    },
  },
  cancel_transfer: { keys: ["transfer_id"], ids: ["transfer_id"] },
  accept_offer: { keys: ["transfer_id"], ids: ["transfer_id"] },
  decline_offer: { keys: ["transfer_id"], ids: ["transfer_id"] },
  retry_item: { keys: ["item_id"], ids: ["item_id"] },
  cancel_message: { keys: ["message_id"], ids: ["message_id"] },
  accept_request: { keys: ["conversation_id"], ids: ["conversation_id"] },
  decline_request: { keys: ["conversation_id"], ids: ["conversation_id"] },
  cancel_request: { keys: ["conversation_id"], ids: ["conversation_id"] },
  send_request: { keys: ["nearby_id"], ids: ["nearby_id"] },
  add_by_id: {
    keys: ["friends_id"],
    check: (fields) => text(fields, "friends_id", 800),
  },
  add_from_mention: {
    keys: ["friends_id", "identity_key", "name"],
    check(fields) {
      text(fields, "friends_id", 800);
      text(fields, "identity_key", 128);
      text(fields, "name", 1024);
    },
  },
  open_link: {
    keys: ["payload"],
    check: (fields) => text(fields, "payload", 512),
  },
  add_from_link: {
    keys: ["payload"],
    check: (fields) => text(fields, "payload", 512),
  },
  receive_link: {
    keys: ["payload"],
    check: (fields) => text(fields, "payload", 512),
  },
  make_download_link: {
    keys: ["file", "expires_days"],
    check(fields) {
      fileObject(fields.file, "file");
      if (![1, 7, 30].includes(fields.expires_days)) fail("expires_days");
    },
  },
  reset_friend_link: {},
  revoke_link: { keys: ["link_id"], ids: ["link_id"] },
  join_profile: {
    keys: ["friends_id"],
    check: (fields) => text(fields, "friends_id", 800),
  },
  enter_join_code: {
    keys: ["code"],
    check: (fields) => text(fields, "code", 64),
  },
  cancel_join: {},
  approve_join: { keys: ["join_id"], ids: ["join_id"] },
  deny_join: { keys: ["join_id"], ids: ["join_id"] },
  revoke_device: { keys: ["device_id"], ids: ["device_id"] },
  rename_device: {
    keys: ["name"],
    check: (fields) => text(fields, "name", 1024),
  },
  fetch_from_device: { keys: ["transfer_id"], ids: ["transfer_id"] },
  block: { keys: ["conversation_id"], ids: ["conversation_id"] },
  unblock: { keys: ["conversation_id"], ids: ["conversation_id"] },
  // Ticking "Also delete chat history" in Remove's question adds delete_history: true.
  remove_friend: {
    keys: ["conversation_id", "delete_history"],
    ids: ["conversation_id"],
    check: (fields) => bool(fields, "delete_history", { optional: true }),
  },
  mark_verified: { keys: ["conversation_id"], ids: ["conversation_id"] },
  accept_key_change: { keys: ["conversation_id"], ids: ["conversation_id"] },
  set_name: { keys: ["name"], check: (fields) => text(fields, "name", 1024) },
  set_picture: {
    keys: ["picture"],
    check(fields) {
      const picture = fields.picture;
      if (!isObject(picture)) fail("picture");
      if (picture.kind === "animal") {
        if (
          Object.keys(picture).some(
            (key) => !["kind", "set", "index"].includes(key),
          )
        )
          fail("picture");
        if (
          !Number.isInteger(picture.set) ||
          picture.set < 0 ||
          picture.set > 1000
        )
          fail("picture.set");
        if (
          !Number.isInteger(picture.index) ||
          picture.index < 0 ||
          picture.index > 10000
        )
          fail("picture.index");
        return;
      }
      if (picture.kind !== "image") fail("picture.kind");
      if (
        Object.keys(picture).some(
          (key) => !["kind", "data_base64", "path", "crop"].includes(key),
        )
      )
        fail("picture");
      const hasData = picture.data_base64 !== undefined,
        hasPath = picture.path !== undefined;
      if (hasData === hasPath) fail("picture");
      if (
        hasData &&
        (typeof picture.data_base64 !== "string" ||
          picture.data_base64.length > 7 * 1024 * 1024 ||
          !/^[A-Za-z0-9+/]*={0,2}$/.test(picture.data_base64))
      )
        fail("picture.data_base64");
      if (hasPath) plainPath(picture.path, "picture.path");
      if (picture.crop !== undefined && picture.crop !== null) {
        const crop = picture.crop;
        if (!isObject(crop) || Object.keys(crop).sort().join() !== "side,x,y")
          fail("picture.crop");
        for (const key of ["x", "y", "side"])
          if (
            !Number.isInteger(crop[key]) ||
            crop[key] < 0 ||
            crop[key] > 1 << 20
          )
            fail(`picture.crop.${key}`);
      }
    },
  },
  set_auto_accept: {
    keys: ["conversation_id", "enabled"],
    ids: ["conversation_id"],
    check: (fields) => bool(fields, "enabled"),
  },
  // Settings ▸ Save received files to ▸ Change…: the folder the system's picker gave.
  set_received_folder: {
    keys: ["path"],
    check: (fields) => plainPath(fields.path, "path"),
  },
  dismiss_banner: {
    keys: ["kind"],
    check(fields) {
      if (fields.kind !== "id_changed" && fields.kind !== "notifications")
        fail("kind");
    },
  },
  // System notifications (PROTOCOL.md § Notifications). test_notification_response is for test harnesses, never a
  // page.
  set_focus: {
    keys: ["conversation_id"],
    check(fields) {
      if (!Object.hasOwn(fields, "conversation_id")) fail("conversation_id");
      opaque(fields, "conversation_id", { optional: true });
    },
  },
  set_notifications: {
    keys: ["enabled", "preview", "background"],
    check(fields) {
      if (!Object.keys(fields).length) fail("fields");
      for (const key of ["enabled", "preview", "background"])
        bool(fields, key, { optional: true });
    },
  },
  allow_notifications: {},
  start_visibility: {},
  stop_visibility: {},
  search_messages: {
    keys: ["query", "conversation_id", "limit"],
    check(fields) {
      text(fields, "query", 800);
      opaque(fields, "conversation_id", { optional: true });
      if (
        fields.limit !== undefined &&
        (!Number.isInteger(fields.limit) ||
          fields.limit < 1 ||
          fields.limit > 50)
      )
        fail("limit");
    },
  },
  delete_history: {
    keys: ["conversation_id"],
    check: (fields) => opaque(fields, "conversation_id", { optional: true }),
  },
  reset_friends: {
    keys: ["confirm"],
    check(fields) {
      if (fields.confirm !== "reset") fail("confirm");
    },
  },
};

/** Returns the JSON text of an intent's fields ready for the client library, or throws FriendsFieldError. */
function validateIntent(type, fields) {
  if (typeof type !== "string" || !Object.hasOwn(INTENTS, type)) fail("type");
  const rule = INTENTS[type];
  const value = fields === undefined || fields === null ? {} : fields;
  if (!isObject(value) || Object.getPrototypeOf(value) !== Object.prototype)
    fail("fields");
  for (const key of Object.keys(value))
    if (!(rule.keys ?? []).includes(key)) fail(key);
  for (const key of rule.ids ?? []) opaque(value, key);
  rule.check?.(value);
  const json = JSON.stringify(value);
  if (byteLength(json) > MAX_FRAME_BYTES - 4096) fail("fields");
  return json;
}

const INTENT_TYPES = Object.freeze(Object.keys(INTENTS));

// --- Values the main process acts on itself -------------------------------------------------------------------

// Links in a friend's message open only through the panel's link menu, and only these kinds.
function externalURL(value) {
  if (typeof value !== "string" || value.length > 4096) return null;
  try {
    const url = new URL(value);
    if (url.protocol === "mailto:") return url.href;
    if (
      (url.protocol === "http:" || url.protocol === "https:") &&
      url.hostname &&
      !url.username &&
      !url.password
    )
      return url.href;
  } catch {}
  return null;
}

// The system settings a nearby notice can open, as the AppKit views map them (SZFriendsContext.m), macOS 13 on.
const SETTINGS_URLS = {
  local_network_privacy:
    "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork",
  bluetooth_privacy:
    "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth",
  bluetooth: "x-apple.systempreferences:com.apple.BluetoothSettings",
  wifi: "x-apple.systempreferences:com.apple.wifi-settings-extension",
  // The Friends helper posts the notifications, so its own page in Notifications settings.
  notifications:
    "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.intuition.shenzhenfriends",
};
const settingsURL = (target) =>
  typeof target === "string" && Object.hasOwn(SETTINGS_URLS, target)
    ? SETTINGS_URLS[target]
    : null;

// PROTOCOL.md § Links, the app's URL: shenzhen3d://friends/link#<payload>, checked before anything is sent.
function canonicalBase64URL(text) {
  if (!/^[A-Za-z0-9_-]*$/.test(text) || text.length % 4 === 1) return null;
  const bytes = Buffer.from(text, "base64url");
  // Canonical: re-encoding gives the same text, so no unused trailing bits are set.
  return bytes.toString("base64url") === text ? bytes : null;
}
function linkPayload(urlText, scheme = "shenzhen3d") {
  if (typeof urlText !== "string" || Buffer.byteLength(urlText) > 512)
    return null;
  let url;
  try {
    url = new URL(urlText);
  } catch {
    return null;
  }
  if (
    url.protocol !== `${scheme}:` ||
    url.hostname !== "friends" ||
    url.pathname !== "/link" ||
    url.username ||
    url.password ||
    url.port ||
    url.search ||
    !url.hash
  )
    return null;
  const payload = url.hash.slice(1);
  const kind = payload.slice(0, 2);
  const bytes = canonicalBase64URL(payload.slice(2));
  if (!bytes || bytes[0] !== 0x01) return null;
  if (kind === "d.") return bytes.length === 49 ? payload : null;
  if (kind !== "f.") return null;
  // version, key (32), invite (16), ID length and ID (3 to 64 lowercase words), name length and name (0 to 160).
  let offset = 49;
  const idLength = bytes[offset++];
  if (
    idLength === undefined ||
    idLength < 3 ||
    idLength > 64 ||
    offset + idLength > bytes.length
  )
    return null;
  const id = bytes.subarray(offset, offset + idLength).toString("latin1");
  if (!/^[a-z]+(-[a-z]+)+$/.test(id)) return null;
  offset += idLength;
  const nameLength = bytes[offset++];
  if (
    nameLength === undefined ||
    nameLength > 160 ||
    offset + nameLength !== bytes.length
  )
    return null;
  const name = bytes.subarray(offset);
  const decoded = new TextDecoder("utf-8", { fatal: false }).decode(name);
  if (
    Buffer.from(decoded, "utf8").compare(name) !== 0 ||
    /[\u0000-\u001f\u007f-\u009f]/.test(decoded)
  )
    return null;
  return payload;
}

// Where a Friends URL opened in this app goes (PROTOCOL.md § Notifications, § Links): a notification's
// <scheme>://friends/conversation/<conversation_id>, <scheme>://friends for the list, or a friend or download link.
// Anything else, or a malformed id, is null.
function friendsURL(urlText, scheme = "shenzhen3d") {
  if (typeof urlText !== "string" || Buffer.byteLength(urlText) > 512)
    return null;
  let url;
  try {
    url = new URL(urlText);
  } catch {
    return null;
  }
  if (
    url.protocol !== `${scheme}:` ||
    url.hostname !== "friends" ||
    url.username ||
    url.password ||
    url.port ||
    url.search
  )
    return null;
  if (url.pathname === "/link") {
    const payload = linkPayload(urlText, scheme);
    return payload ? { kind: "link", payload } : null;
  }
  if (url.hash) return null;
  if (url.pathname === "" || url.pathname === "/")
    return { kind: "open", conversation_id: null };
  const match = /^\/conversation\/([^/]*)$/.exec(url.pathname);
  return match && OPAQUE_ID.test(match[1])
    ? { kind: "open", conversation_id: match[1] }
    : null;
}

module.exports = {
  FriendsFieldError,
  INTENT_TYPES,
  OPAQUE_ID,
  validateIntent,
  externalURL,
  settingsURL,
  linkPayload,
  friendsURL,
  plainPath(value) {
    try {
      plainPath(value, "path");
      return true;
    } catch {
      return false;
    }
  },
};
