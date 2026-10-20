// The Shenzhen Friends view contract as the panel reads it: PROTOCOL.md § Schemas (shenzhen-pdf, the commit
// friends.lock pins). The helper decides and the panel renders, so these are display-ready values; every field is
// read defensively because unknown is ignored, never fatal, and fields from later minors may be absent.

export type Avatar = {
  kind: "animal" | "image" | "placeholder";
  initials: string;
  color: string;
  set?: number;
  index?: number;
  path?: string;
};
export type Route = {
  kind: "local" | "online" | "connecting" | "offline" | "none" | string;
  method:
    "lan" | "p2p_wifi" | "bluetooth" | "internet" | "relay" | string | null;
  label: string | null;
};
export type Arm = {
  label: string;
  accessibility_label: string;
  seconds: number;
};
export type Confirm = {
  title: string;
  body: string;
  confirm_label: string;
  cancel_label: string;
  destructive: boolean;
};
export type Action = {
  action: string;
  label: string;
  style: "primary" | "secondary" | "link" | "destructive" | string;
  note?: string | null;
  confirm?: Confirm | null;
  arm?: Arm | null;
  path?: string;
  settings_target?: string;
  friends_id?: string;
  identity_key?: string;
  name?: string;
  payload?: string;
  link_id?: string;
  device_id?: string;
  join_id?: string;
};
export type Segment = {
  text: string;
  url?: string;
  emphasis?: boolean;
  match?: boolean;
  mention?: number;
};
export type Back = {
  badge_count: number;
  badge_label: string;
  accessibility_label: string;
};
export type Footer = {
  avatar: Avatar;
  name: string | null;
  name_placeholder: string;
  id_label: string;
  id_note: string | null;
  friends_id: string;
  add_label: string;
};
export type Empty = { kind?: string; title: string; body: string | null };
export type RowAction = {
  action: "accept_request" | "decline_request" | "block" | string;
  icon: "accept" | "decline" | "block" | string;
  /** The word the button shows (Accept, Decline); null: the icon alone (Block). */
  title?: string | null;
  label: string;
  arm: Arm | null;
};
export type ListRow = {
  conversation_id: string;
  avatar: Avatar;
  title: string;
  subtitle: string;
  time_label: string;
  route: Route;
  unread: boolean;
  waiting: { kind: string; label: string } | null;
  blocked: boolean;
  id_confirmed: boolean;
  id_confirmed_label: string | null;
  style: "normal" | "muted" | string;
  drop_label: string | null;
  drop_refusal: string | null;
  accessibility_label: string;
  actions: RowAction[];
  mentionable?: boolean;
  kind?: "person" | "you" | string;
};
export type JoinRequest = {
  join_id: string;
  state: "waiting" | "approved" | string;
  title: string;
  subtitle: string;
  code: string | null;
  code_accessibility_label: string | null;
  code_note: string | null;
  actions: Action[];
  accessibility_label: string;
};
export type ListData = {
  query: string;
  banner: { kind: string; text: string; action: Action | null } | null;
  name_prompt: {
    title: string;
    placeholder: string;
    note: string;
    join_label?: string | null;
  } | null;
  rows: ListRow[];
  empty: Empty | null;
  footer: Footer;
  state?: "normal" | "device_removed" | string;
  removed?: { title: string; body: string; action: Action } | null;
  join_requests?: JoinRequest[];
};
export type MethodState = { method: string; state: string; label: string };
export type NearbyPerson = {
  nearby_id: string | null;
  conversation_id: string | null;
  avatar: Avatar;
  title: string;
  subtitle: string;
  status_label: string | null;
  action: Action | null;
  accessibility_label: string;
};
export type NearbyData = {
  query: string;
  visibility: {
    state: "hidden" | "visible" | "unavailable" | string;
    title: string | null;
    body: string | null;
    remaining_label: string | null;
    remaining_accessibility_label: string | null;
    deadline: string | null;
    action: Action | null;
  };
  methods: MethodState[];
  alert: { title: string; body: string; action: Action | null } | null;
  note: { text: string; action: Action | null } | null;
  status: { kind: string; label: string } | null;
  people: NearbyPerson[];
  empty: Empty | null;
  footer: Footer;
};
export type FileInfo = {
  name: string;
  kind_label: string;
  size_label: string;
  size_bytes: number;
  path: string | null;
  type_identifier: string | null;
  extension: string | null;
};
export type Thumbnail = {
  path: string;
  width: number;
  height: number;
  source: string;
};
export type Mention = {
  url: string;
  kind: "friend" | "you" | "stranger" | string;
  label: string;
  tooltip: string | null;
  conversation_id: string | null;
  card: {
    title: string;
    id_label: string;
    status_label: string | null;
    conversation_id: string | null;
    actions: Action[];
  } | null;
};
export type Item = {
  kind: "day" | "message" | "transfer" | "event" | string;
  item_id: string;
  label?: string;
  time_label?: string | null;
  direction?: "in" | "out";
  text?: string;
  text_format?: string;
  segments?: Segment[];
  status?: { state: string; label: string } | null;
  assistant_label?: string | null;
  transfer_id?: string;
  file?: FileInfo;
  meta_label?: string;
  state?: string;
  status_label?: string;
  route_note?: string | null;
  progress?: {
    fraction: number;
    determinate: boolean;
    accessibility_label: string;
  } | null;
  thumbnail?: Thumbnail | null;
  actions?: Action[];
  mentions?: Mention[];
  highlighted: boolean;
  accessibility_label: string;
};
export type Composer = {
  visible: boolean;
  enabled: boolean;
  placeholder: string;
  hint: Segment[];
  send_label: string;
  note: string | null;
  accepts_drops: boolean;
  max_text_bytes: number;
  mention_note?: string | null;
};
export type RequestCard = {
  direction: "incoming" | "outgoing" | string;
  avatar: Avatar;
  title: string;
  subtitle: string;
  code_prompt: string | null;
  comparison_code: string | null;
  comparison_code_accessibility_label: string | null;
  actions: Action[];
  footnote: string | null;
};
export type ConversationData = {
  conversation_id: string;
  header: {
    title: string;
    subtitle: string | null;
    route: Route;
    avatar: Avatar;
    details_available: boolean;
    accessibility_label: string;
  };
  back: Back;
  search_placeholder: string;
  has_earlier: boolean;
  items: Item[];
  highlight_item_id: string | null;
  request: RequestCard | null;
  composer: Composer;
};
export type DetailsData = {
  conversation_id: string;
  title: string;
  back: Back;
  avatar: Avatar;
  route: Route;
  friends_id: string | null;
  id_label: string | null;
  id_confirmed: boolean;
  id_confirmed_label: string | null;
  copy_id_accessibility_label: string | null;
  verification: {
    state: string;
    label: string;
    body: string | null;
    comparison_code: string | null;
    action: Action | null;
  };
  auto_accept: {
    available: boolean;
    enabled: boolean;
    title: string;
    body: string;
  };
  received: { label: string; count: number; action: Action | null } | null;
  key_change: { title: string; body: string; actions: Action[] } | null;
  actions: Action[];
};
export type DeviceRow = {
  device_id: string;
  name: string;
  system: string;
  last_connected: string;
  detail: string;
  this_computer: boolean;
  state: string;
  accessibility_label: string;
  rename: {
    label: string;
    placeholder: string;
    button_label: string;
    max_bytes: number;
  } | null;
  remove: Action | null;
};
export type ProfileData = {
  title: string;
  back: Back;
  name: {
    label: string;
    value: string | null;
    placeholder: string;
    max_length: number;
  };
  picture: {
    avatar: Avatar;
    choose_label: string;
    own_picture_label: string;
    animal_set: number;
    selected_index: number | null;
  };
  id: {
    label: string;
    friends_id: string;
    state: string;
    note: string;
    copy_label: string;
    qr_label: string | null;
    qr_payload: string | null;
  };
  add: {
    label: string;
    placeholder: string;
    button_label: string;
    hint: string;
  };
  links?: {
    title: string;
    friend: {
      label: string;
      url: string;
      note: string;
      copy_label: string;
      reset: Action;
    };
    downloads_label: string;
    downloads_empty: string | null;
    downloads: {
      link_id: string;
      file_name: string;
      downloads_label: string;
      expires_label: string;
      revoke: Action;
    }[];
  } | null;
  devices?: { title: string; note: string; rows: DeviceRow[] } | null;
};
export type SettingsData = {
  name: {
    label: string;
    note: string;
    value: string | null;
    placeholder: string;
  };
  id: { label: string; note: string; friends_id: string; copy_label: string };
  received: {
    label: string;
    /** With the helper capability received.folder: the folder's name ("Downloads"). */
    value?: string;
    /** "" on a computer, where no note shows. */
    note: string;
    path?: string | null;
    action: Action | null;
    /** choose_received_folder (Change…), null where the folder cannot be changed. */
    change?: Action | null;
  };
  auto_accept: {
    label: string;
    note: string;
    action_label: string;
    friends: {
      conversation_id: string;
      title: string;
      avatar: Avatar;
      enabled: boolean;
    }[];
  };
  history: {
    label: string;
    note: string;
    action_label: string;
    confirm: Confirm;
  };
  reset: {
    label: string;
    note: string;
    action_label: string;
    confirm: Confirm;
  };
};
export type JoinData = {
  state: string;
  title: string;
  message: string | null;
  friends_id: string | null;
  id_field: { placeholder: string; button: string } | null;
  code_field: {
    length: number;
    placeholder: string;
    button: string;
    enabled: boolean;
  } | null;
  error: string | null;
  actions: Action[];
};
export type BadgeData = {
  count: number;
  label: string;
  accessibility_label: string;
};
export type LinkCard = {
  kind: "friend" | "download" | string;
  title: string;
  subtitle: string | null;
  note: string | null;
  avatar: Avatar | null;
  actions: Action[];
};
export type SearchResult = {
  conversation_id: string;
  message_id: string;
  conversation_title: string;
  avatar: Avatar;
  sender_label: string;
  time_label: string;
  excerpt: Segment[];
};

export type ReplyError = {
  code: string;
  message: string | null;
  retryable: boolean;
  details: Record<string, unknown>;
};
export type Reply = {
  type: "reply";
  re: string | null;
  ok: boolean;
  result?: Record<string, unknown>;
  error?: ReplyError;
};
export type Snapshot = {
  type: "snapshot";
  subscription: string;
  view: string;
  rev: number;
  data: unknown;
};

/** welcome.strings: the static labels (PROTOCOL.md § Static strings). Views show nothing when a key is absent. */
export type Strings = Partial<Record<string, string>>;

export type FriendsStatus = {
  available: boolean;
  enabled: boolean;
  attached: boolean;
  state:
    | "idle"
    | "connecting"
    | "handshaking"
    | "ready"
    | "waiting"
    | "incompatible"
    | string;
  /** The client library's line for this state ("Starting Friends…"), "" when nothing needs saying. */
  text: string;
  strings: Strings | null;
  capabilities: string[];
  limits: Record<string, number> | null;
  badge: BadgeData | null;
};
/** The `received` view: files received here, newest first (helper capability received.folder). */
export type ReceivedData = {
  files: {
    transfer_id: string;
    path: string;
    file_name: string;
    received_at: number;
    source: "friend" | "link" | "device";
  }[];
};
