const $ = (s) => document.querySelector(s),
  state = {
    layout: "a",
    mode: "groups",
    theme: "light",
    width: 240,
    height: 700,
    pdf: true,
  };
const modes = [
  ["chapters", "≡", "Chapters"],
  ["comments", "▤", "Comments"],
  ["search", "⌕", "Search"],
  ["history", "◷", "History"],
  ["groups", "▦", "Groups"],
];
const groupData = [
  ["General", "2 documents", "#b2b0b7", false, false],
  ["Research", "2 · Active", "#8db2d0", true, false],
  ["Travel plans", "2 · Hidden", "#78b5bd", false, true],
  ["Design references", "2 documents", "#b09bca", false, false],
  ["Project notes", "2 documents", "#d6a18c", false, false],
  ["Archive", "2 · Hidden", "#88b4a6", false, true],
];
function nav() {
  return `<nav class="mode-nav" aria-label="Sidebar mode layout reference">${modes
    .filter((m) => state.pdf || m[0] !== "comments")
    .map(
      ([id, icon, label]) =>
        `<div class="mode ${state.mode === id ? "selected" : ""}"><span class="symbol">${icon}</span><b>${label}</b></div>`,
    )
    .join("")}</nav>`;
}
function groups() {
  return `<div class="panel-head"><div class="field">⌕ &nbsp; Search groups</div></div><div class="panel-content">${groupData.map(([name, meta, color, open, hidden]) => `<div class="group-row"><span class="disclosure">${open ? "⌄" : "›"}</span><span class="dot" style="background:${color}"></span><div class="group-title"><b>${name}</b><small>${meta}</small></div><span class="visibility">${hidden ? "⊘" : "◉"}</span></div>${open ? '<div class="document-row"><span>▧</span><span>Getting started.pdf</span></div><div class="document-row current"><span>▧</span><span>Conference notes.md</span></div>' : ""}`).join("")}</div><div class="context-foot"><span>6 groups · 2 hidden</span><span title="Hidden groups stay open.">ⓘ</span></div>`;
}
function chapters() {
  return `<div class="panel-head"><div class="panel-title">Chapters<span>Expand all &nbsp; ⌄</span></div><div class="field">⌕ &nbsp; Filter chapters</div></div><div class="panel-content">${[
    ["›", "Preface", 1, false],
    ["⌄", "The art of noticing", 3, false],
    ["", "Begin with the ordinary", 4, true],
    ["", "Leave a little room", 6, true],
    ["", "An unfinished thought", 9, true],
    ["›", "Taking the longer way", 12, false],
    ["›", "A room of one’s own", 19, false],
    ["›", "A gentler kind of order", 26, false],
    ["›", "Notes & references", 32, false],
  ]
    .map(
      ([icon, title, page, sub], i) =>
        `<div class="chapter-row ${sub ? "sub" : ""} ${i === 2 ? "current" : ""}"><span>${icon}</span><span>${title}</span><small>${page}</small></div>`,
    )
    .join(
      "",
    )}</div><div class="context-foot"><span>9 chapters</span><span>Page 4 of 48</span></div>`;
}
function search() {
  return `<div class="panel-head"><div class="panel-title">Search<span>3 matches</span></div><div class="field">⌕ &nbsp; ordinary &nbsp; ×</div></div><div class="panel-content">${["Begin with the ordinary things.", "The ordinary can hold our attention.", "Return to the ordinary."].map((t, i) => `<div class="comment"><strong>Page ${i * 3 + 4}</strong>${t}</div>`).join("")}</div><div class="context-foot">Find in this document &nbsp; ⌘F</div>`;
}
function comments() {
  return `<div class="panel-head"><div class="panel-title">Comments<span>2 notes</span></div><div class="field">⌕ &nbsp; Filter comments</div></div><div class="panel-content"><div class="comment"><strong>Page 4 · Today</strong>This is the thread to follow in the next draft.</div><div class="comment"><strong>Page 8 · Yesterday</strong>Connect this to the previous example.</div></div><div class="context-foot"><span>2 comments</span><span class="small-action">Add comment</span></div>`;
}
function render() {
  const r = $("#reader");
  r.className = `reader layout-${state.layout} ${state.theme}`;
  r.style.setProperty("--sidebar", state.width + "px");
  r.style.height = state.height + "px";
  if (state.mode === "history") {
    r.innerHTML =
      '<div class="retired-history"><p class="kicker">SUPERSEDED ILLUSTRATION</p><h2>History has moved to native evidence.</h2><p>The early CSS layout hid all version rows at minimum height. It is retired and does not represent the production changes.</p><a href="index.html#history">View native History before & after ↗</a></div>';
    $("#measurement").textContent = "History: use native production evidence";
    $("#rationale").textContent =
      "The native History renders are the reference for its implemented layout.";
    return;
  }
  r.innerHTML = `<div class="windowbar"><div class="traffic"><i></i><i></i><i></i></div><span class="toolbar-icons">▥</span><span class="app-title">Conference notes.md</span><span class="toolbar-icons">‹ &nbsp; › &nbsp; ⌕ &nbsp; 100% &nbsp; ⊕ &nbsp; ⋯</span></div><div class="tabstrip"><span class="group-label">Research &nbsp; 2</span><span>Getting started.pdf</span><span class="active-tab">Conference notes.md &nbsp; ×</span><span>＋</span></div><div class="body"><aside class="sidebar">${nav()}<section class="panel">${{ groups, chapters, search, comments }[state.mode]()}</section></aside><div class="page-area"><div class="reading-tools"><span>4 / 48</span><span>Fit page</span><span>Continuous</span></div><div class="page-scroll"><article class="page"><div class="eyebrow">RESEARCH NOTES / CHAPTER 01</div><h2>The art<br>of noticing.</h2><div class="dek">Begin with the ordinary things.<br>There is more here than we think.</div><div class="rule"></div><p>There is a particular kind of attention that begins when we stop looking for something. A room, a page, a familiar street: each becomes a little less familiar when we give it time.</p><h3>Begin with the ordinary</h3><p>The work is not to make every detail visible at once. It is to make the next useful thing easy to see, and to leave everything else in its proper place.</p><p>A small amount of structure makes room for thought. Beyond that, it should be quiet.</p><div class="page-num">4</div></article></div><div class="reader-foot"><span>Conference notes.md</span><span>48 pages · Place saved</span></div></div></div>`;
  document
    .querySelectorAll("[data-layout]")
    .forEach((b) =>
      b.setAttribute("aria-pressed", b.dataset.layout === state.layout),
    );
  $("#measurement").textContent =
    `1100 × ${state.height} · Sidebar ${state.layout === "b" ? 340 : state.width}pt · Content ${state.height - 74}pt high`;
  $("#rationale").textContent = {
    a: "A keeps the reader’s width and a stable vertical mode list. Navigation gets a quiet neutral surface; a single content selection carries the accent. Compact groups and a bounded History action area recover useful content height without hiding functions.",
    b: "B makes the mode list an independent column, so content can start at the top. At 340pt this costs 120pt of page width compared with the narrow sidebar; at 220pt it would leave only104pt for content. It is not recommended as the default.",
    c: "C gives the content the top of the panel and places the same vertical modes at the bottom. It does not recover any vertical space; it moves the navigation away from its context and varies its position with window height. Not recommended.",
  }[state.layout];
}
document.querySelectorAll("[data-layout]").forEach(
  (b) =>
    (b.onclick = () => {
      state.layout = b.dataset.layout;
      render();
    }),
);
["mode", "theme", "width", "height"].forEach(
  (id) =>
    ($("#" + id).onchange = (e) => {
      state[id] = ["width", "height"].includes(id)
        ? Number(e.target.value)
        : e.target.value;
      render();
    }),
);
$("#pdf").onchange = (e) => {
  state.pdf = e.target.checked;
  if (!state.pdf && state.mode === "comments") {
    $("#mode").value = state.mode = "groups";
  }
  render();
};
const query = new URLSearchParams(location.search);
for (const key of ["layout", "mode", "theme", "width", "height"])
  if (query.has(key)) {
    state[key] = ["width", "height"].includes(key)
      ? Number(query.get(key))
      : query.get(key);
    if ($("#" + key)) $("#" + key).value = state[key];
  }
render();
