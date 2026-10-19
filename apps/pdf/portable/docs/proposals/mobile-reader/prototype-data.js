/* Deterministic browser design prototype. Document surfaces and storage are fixtures. */
const $ = (s) => document.querySelector(s),
  app = $("#app");
const paths = {
  back: "m14 5-7 7 7 7",
  chevron: "m9 5 7 7-7 7",
  search: "M21 21l-5-5 M18 10a8 8 0 1 1-16 0 8 8 0 0 1 16 0",
  more: "M5 12h.01 M12 12h.01 M19 12h.01",
  close: "m6 6 12 12 M6 18 18 6",
  groups: "M3 7h7l2-3h9v15H3z",
  collection: "M4 5h16v15H4z M2 2h20 M8 9h8 M8 13h6",
  book: "M3 4c4-1 6 0 9 2 3-2 5-3 9-2v15c-4-1-6 0-9 2-3-2-5-3-9-2z M12 6v15",
  contents: "M8 5h13 M8 12h13 M8 19h13 M3 5h.01 M3 12h.01 M3 19h.01",
  wheel:
    "M12 3v3 M12 18v3 M3 12h3 M18 12h3 M5.6 5.6l2.1 2.1 M16.3 16.3l2.1 2.1 M5.6 18.4l2.1-2.1 M16.3 7.7l2.1-2.1 M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0",
  history: "M3 5v6h6 M3.5 10a9 9 0 1 1 1.5 8 M12 7v5l3 2",
  plus: "M12 4v16 M4 12h16",
  check: "m5 12 4 4 10-10",
  shield: "m12 2 9 4v6c0 5-9 10-9 10S3 17 3 12V6z M8 12l3 3 5-6",
  file: "M6 2h8l5 5v15H6z M14 2v6h5 M9 13h7 M9 17h5",
  storage: "M3 5h18v15H3z M3 10h18 M6 15h.01 M10 15h8",
  arrow: "M5 12h14 m-6-6 6 6-6 6",
  download: "M12 3v12 m-5-5 5 5 5-5 M4 17v4h16v-4",
  link: "m9 15 6-6 M14 5l2-2a4 4 0 0 1 6 6l-4 4 M10 19l-2 2a4 4 0 0 1-6-6l4-4",
  sun: "M12 2v2 M12 20v2 M2 12h2 M20 12h2 M5 5l2 2 M17 17l2 2 M5 19l2-2 M17 7l2-2 M16 12a4 4 0 1 1-8 0 4 4 0 0 1 8 0",
  signal: "M3 18v-3 M8 18v-7 M13 18V7 M18 18V3",
  wifi: "M2 8c6-5 14-5 20 0 M6 12c4-3 8-3 12 0 M10 16c1-1 3-1 4 0 M12 20h.01",
  pin: "m8 2 8 0-1 7 4 4v2H5v-2l4-4z M12 15v7",
  heart: "M12 20 3 11a5 5 0 0 1 9-6 5 5 0 0 1 9 6z",
  eye: "M1 12s4-7 11-7 11 7 11 7-4 7-11 7S1 12 1 12 M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0",
};
const icon = (n) =>
  `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="${paths[n] || paths.file}"/></svg>`;
const btn = (a, label, i, cls = "icon-btn") =>
  `<button class="${cls}" data-action="${a}" aria-label="${label}">${icon(i)}</button>`;
const docs = [
  {
    id: 0,
    title: "A room for thought",
    ext: "PDF",
    position: "12 of 48",
    meta: "Original · On this device",
    short: ["A room for", "thought"],
    group: "Design & space",
    thumb: "A room for thought",
    snippet:
      "Light gives a room its <mark>quiet</mark> rhythm. Space leaves room for thought.",
  },
  {
    id: 1,
    title: "The art of noticing",
    ext: "EPUB",
    position: "Chapter 3 · 42%",
    meta: "Imported copy · Saved",
    short: ["The art of", "noticing"],
    group: "Design & space",
    thumb: "The art of noticing",
    snippet:
      "The practice of paying attention to the ordinary things around us.",
  },
  {
    id: 2,
    title: "Studio field notes",
    ext: "MD",
    position: "Materials · 28%",
    meta: "Original · On this device",
    short: ["Studio field", "notes"],
    group: "Design & space",
    thumb: "# field notes",
    snippet:
      "A place to gather observations on light, materials and everyday life.",
  },
  {
    id: 3,
    title: "Soft architecture",
    ext: "PDF",
    position: "7 of 36",
    meta: "Original · On this device",
    short: ["Soft", "architecture"],
    group: "Design & space",
    thumb: "Soft architecture",
    snippet: "A softer threshold between work, rest and the rooms we inhabit.",
  },
  {
    id: 4,
    title: "Objects & atmosphere",
    ext: "PDF",
    position: "3 of 24",
    meta: "Original · On this device",
    short: ["Objects &", "atmosphere"],
    group: "Design & space",
    thumb: "Objects & atmosphere",
    snippet:
      "Small objects can shape a <mark>quiet</mark> corner of a larger room.",
  },
  {
    id: 5,
    title: "A place to begin",
    ext: "EPUB",
    position: "Chapter 1 · 8%",
    meta: "Imported copy · Saved",
    short: ["A place", "to begin"],
    group: "Design & space",
    thumb: "A place to begin",
    snippet: "Making space for something new, one small decision at a time.",
  },
  {
    id: 6,
    title: "Ways of walking",
    ext: "EPUB",
    position: "Chapter 2 · 19%",
    meta: "Imported copy · Saved",
    short: ["Ways of", "walking"],
    group: "Weekend reading",
    thumb: "Ways of walking",
    snippet:
      "Following the familiar streets until they become unfamiliar again.",
  },
];
const groups = [
  {
    name: "Design & space",
    count: 6,
    sub: "A room for thought · 12 of 48",
    color: "",
  },
  {
    name: "Weekend reading",
    count: 1,
    sub: "Ways of walking · Chapter 2",
    color: "ochre",
  },
  {
    name: "Research",
    count: 0,
    sub: "A fresh place for your next idea",
    color: "blue",
  },
  {
    name: "General",
    count: 0,
    sub: "Documents opened from other apps",
    color: "rose",
  },
];
const scene = new URLSearchParams(location.search).get("scene") || "reader";
const state = {
  screen: "reader",
  doc: 0,
  sheet: null,
  older: false,
  missing: false,
  large: new URLSearchParams(location.search).get("large") === "1",
  dark: false,
  kept: true,
  collection: true,
  cleaned: false,
  group: 0,
  query: "",
  filter: "All",
  slots: [0, 1, 2, 3, 4, 5],
  consented: false,
  hidden: false,
  chrome: true,
};
if (["groups", "collection", "history", "storage", "documents"].includes(scene))
  state.screen = scene;
if (
  [
    "wheel",
    "consent",
    "switcher",
    "missing",
    "find",
    "contents",
    "more",
  ].includes(scene)
)
  state.sheet = scene;
if (scene === "epub") state.doc = 1;
if (scene === "markdown") state.doc = 2;
if (scene === "older") {
  state.older = true;
}
if (scene === "missing") state.missing = true;
if (scene === "large") {
  state.large = true;
  state.screen = "groups";
}
if (state.large && state.sheet === "wheel") state.sheet = "switcher";
let gesture = null,
  hover = -1,
  toastTimer,
  queryTimer,
  returnFocus = null;
const d = () => docs[state.doc];
function thumb(doc) {
  return `<span class="thumb ${doc.ext === "EPUB" ? "book" : doc.ext === "MD" ? "md" : ""}" aria-hidden="true"><strong>${doc.thumb}</strong></span>`;
}
function status() {
  return `<div class="status"><span>9:41</span><div class="status-right">${icon("signal")}${icon("wifi")}<i class="battery"></i></div></div><div class="preview-label">DESIGN PROTOTYPE</div>`;
}
function header(title, sub, action = "back", right = "more") {
  return `<header class="top">${btn(action, action === "groups" ? "Organizer" : "Back", action === "groups" ? "groups" : "back")}<div class="top-title"><strong>${title}</strong>${sub ? `<small>${sub}</small>` : ""}</div>${btn(right, right === "storage" ? "Storage" : "More options", right === "storage" ? "storage" : "more")}</header>`;
}
function nav(active) {
  return `<nav class="nav" aria-label="Organizer"><button data-action="groups" class="${active === "groups" ? "active" : ""}"><span class="icon-wrap">${icon("groups")}</span>Groups</button><button data-action="reader"><span class="icon-wrap">${icon("book")}</span>Reader</button><button data-action="collection" class="${active === "collection" ? "active" : ""}"><span class="icon-wrap">${icon("collection")}</span>Collection</button></nav>`;
}
const home = () => '<div class="homebar" aria-hidden="true"></div>';
