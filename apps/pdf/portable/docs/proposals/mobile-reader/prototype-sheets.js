function wheel() {
  return `<div class="wheel-panel" role="dialog" tabindex="-1" aria-modal="true" aria-label="Document wheel"><div class="eyebrow">DESIGN & SPACE</div><h2>Within easy reach.</h2><p class="muted">Slide to a document. Release to return to reading.</p><div class="wheel" id="wheel"><svg viewBox="0 0 310 310" aria-hidden="true">${state.slots.map((id, i) => sector(i, docs[id])).join("")}</svg><div class="wheel-center">${icon("wheel")}<strong id="wheel-title">${d().title}</strong><small id="wheel-caption">Center to cancel</small></div></div><p class="wheel-full-title" id="wheel-full-title">${d().title}</p><p class="wheel-note">Six steady places. Nothing moves under your thumb.</p><div class="wheel-actions"><button data-action="close">Cancel</button><button data-action="switcher">List & all groups</button></div></div>`;
}
function sector(i, doc) {
  const a = ((i * 60 - 120) * Math.PI) / 180,
    b = (((i + 1) * 60 - 120) * Math.PI) / 180,
    mid = (a + b) / 2;
  const p = (r, t) => `${155 + r * Math.cos(t)},${155 + r * Math.sin(t)}`;
  const path = `M${p(145, a)} A145,145 0 0 1 ${p(145, b)} L${p(60, b)} A60,60 0 0 0 ${p(60, a)}Z`;
  return `<g class="sector-group ${doc.id === state.doc ? "current" : ""}" data-sector="${i}"><path class="sector ${doc.id === state.doc ? "current" : ""}" d="${path}"/><text text-anchor="middle" x="${155 + 101 * Math.cos(mid)}" y="${153 + 101 * Math.sin(mid)}">${doc.short.map((s, n) => `<tspan x="${155 + 101 * Math.cos(mid)}" dy="${n ? 12 : 0}">${s}</tspan>`).join("")}</text><text class="slot-format" text-anchor="middle" x="${155 + 101 * Math.cos(mid)}" y="${179 + 101 * Math.sin(mid)}">${doc.id === state.doc ? "READING" : doc.ext}</text><text class="wheel-check" text-anchor="middle" x="${155 + 130 * Math.cos(mid)}" y="${160 + 130 * Math.sin(mid)}">✓</text></g>`;
}
function sheetBody() {
  switch (state.sheet) {
    case "wheel":
      return wheel();
    case "switcher":
      return sheet(
        "Switch document",
        `<p class="lead">${d().group} · Your place is saved</p><div class="switch-list">${docs
          .filter((x) => x.group === d().group)
          .map(
            (doc) =>
              `<button class="switch-item ${doc.id === state.doc ? "current" : ""}" data-action="doc:${doc.id}">${thumb(doc)}<span class="grow"><strong>${doc.title}</strong><small>${doc.ext} · ${doc.position}</small></span>${doc.id === state.doc ? '<span class="pill">Reading</span>' : icon("chevron")}</button>`,
          )
          .join(
            "",
          )}</div><button class="secondary" data-action="groups">${icon("groups")}All groups</button>`,
      );
    case "consent":
      return `<section class="sheet consent" role="dialog" tabindex="-1" aria-modal="true" aria-label="Keep local copies and history"><div class="handle"></div><div class="consent-symbol">${icon("collection")}</div><h2>A copy kept.<br>A way back.</h2><p class="lead">Keep local copies and history of documents you open? Originals stay in place. Copies stay on this device.</p><div class="consent-detail">${icon("history")}<div>Return to earlier versions<small>Only changed blocks need more space.</small></div></div><div class="consent-detail">${icon("shield")}<div>Keep reading if an original disappears<small>Local recovery, not a cloud backup.</small></div></div><div class="budget-line"><span>Collection limit <strong>1 GiB</strong></span><button data-action="limit">Change</button></div><button class="primary" data-action="consent-on">Keep copies</button><button class="secondary" data-action="consent-off">Not now</button><p class="caption">You can change this any time in Collection.</p></section>`;
    case "recovery":
      return recoverySheet();
    case "missing":
      return sheet(
        "Your copy is safe.",
        `<div class="consent-symbol">${icon("link")}</div><p class="lead">The original is no longer available. You’re reading your saved copy of <strong>${d().title}</strong>.</p><div class="info-box">Saved ${state.older ? state.revisionDate || "18 Sep 2026" : "24 Sep 2026"} · Read-only<br>Find the original to reconnect its history, or save a separate copy.</div><button class="primary" data-action="locate">${icon("link")}Find original</button><button class="secondary" data-action="export:${state.unverified ? "captured-24" : state.older ? (state.revisionDate || "18").split(" ")[0] : "24"}">${icon("download")}Save a copy</button><button class="text-button" style="width:100%;margin-top:8px" data-action="close">Keep reading</button>`,
      );
    case "more":
      return sheet(
        "Reader options",
        `<div class="menu-list">${[
          ["history", "history", "History"],
          ["appearance", "sun", "Reading appearance"],
          ["export", "download", "Save a copy"],
          ["missing", "link", "Original unavailable · preview"],
          ["consent", "collection", "Collection choice · preview"],
          ["info", "file", "Document information"],
        ]
          .map(
            (x) =>
              `<button data-action="${x[0]}">${icon(x[1])}${x[2]}</button>`,
          )
          .join("")}</div>`,
      );
    case "contents":
      return sheet(
        "Contents",
        `<p class="lead">${d().title} · ${d().ext}</p><div class="menu-list">${contentsItems().map((s, i) => `<button data-action="chapter:${i}"><span class="pill">${i + 1}</span>${s}</button>`).join("")}</div>`,
      );
    case "globalsearch":
      return sheet("Search everything", `<div class="field">${icon("search")}<input id="global-query" aria-label="Search everything" placeholder="Titles, groups, text…" value=""></div><div id="global-results">${globalResults()}</div>`);
    case "find":
      return sheet(
        "Find in this document",
        `<div class="field">${icon("search")}<input id="find-query" aria-label="Find sample text" placeholder="Try “light”" value=""></div><div id="find-results"><p class="caption">Search the sample passage in ${d().title}.</p></div>`,
      );
    case "cleanup":
      return sheet(
        "A little more room.",
        `<p class="lead">Review what this sample cleanup would remove.</p><div class="stat"><span>Disposable previews & cache</span><strong>36 MiB</strong></div><div class="stat"><span>Unkept older versions<small>4 revisions across 2 documents</small></span><strong>26 MiB</strong></div><div class="stat"><span>Total to reclaim</span><strong>62 MiB</strong></div><div class="info-box">${icon("shield")}Kept versions, active reader data and the only copy of missing originals stay safe. Shared blocks are counted once.</div><button class="primary" data-action="applycleanup">Clean up sample data</button><button class="secondary" data-action="close">Cancel</button>`,
      );
    case "limit":
      return sheet(
        "Collection limit",
        `<p class="lead">This prototype uses a 1 GiB sample limit.</p><div class="menu-list">${["256 MiB", "1 GiB · current", "5 GiB", "Unlimited"].map((x) => `<button data-action="limitpick:${x}">${icon("storage")}${x}</button>`).join("")}</div><p class="caption">Changing a limit previews cleanup before applying it.</p>`,
      );
    case "appearance":
      return sheet(
        "Reading appearance",
        `<div class="menu-list"><button data-action="dark">${icon("sun")}${state.dark ? "Use light theme" : "Use dark theme"}</button><button data-action="large">${icon("eye")}${state.large ? "Use standard text" : "Use larger text"}</button></div><p class="lead">Large text uses the document list in place of the wheel.</p>`,
      );
    case "newgroup":
      return sheet(
        "Make a little space.",
        `<p class="lead">A group keeps related reading close together.</p><label for="new-name">Group name</label><input id="new-name" placeholder="e.g. A new project" maxlength="48"><button class="primary" style="margin-top:20px" data-action="creategroup">Save group</button>`,
      );
    case "groupmenu":
      return sheet(
        groups[state.group].name,
        `<div class="menu-list"><button data-action="renamegroup">${icon("file")}Rename group</button><button data-action="recolorgroup">${icon("sun")}Change group color</button><button data-action="deletegroup">${icon("groups")}Move documents to General & remove group</button></div>`,
      );
    case "docmenu":
      return sheet(
        docs[state.menuDoc ?? state.doc].title,
        `<div class="menu-list"><button data-action="history">${icon("history")}History</button><button data-action="moveto">${icon("groups")}Move to another group</button><button data-action="pin">${icon("pin")}Pin to wheel</button></div>`,
      );
    case "moveto":
      return sheet(
        "Move document",
        `<p class="lead">Only group membership changes. Your document and saved history stay in place.</p><div class="menu-list">${groups.map((g, i) => `<button data-action="move:${i}">${icon("groups")}${g.name}</button>`).join("")}</div>`,
      );
    case "open":
      return sheet(
        "Open a sample",
        `<p class="lead">This design prototype uses sample content. It does not access files on your device.</p><div class="switch-list">${docs
          .slice(0, 3)
          .map(
            (doc) =>
              `<button class="switch-item" data-action="sample:${doc.id}">${thumb(doc)}<span><strong>${doc.title}</strong><small>${doc.ext} sample</small></span></button>`,
          )
          .join("")}</div>`,
      );
    case "locate":
      return sheet(
        "Find original",
        `<p class="lead">The real app will open the system file picker and verify the selected file by content hash.</p><div class="info-box">Prototype outcome: one matching original found. No files were searched.</div><button class="primary" data-action="relink">Simulate matching original</button><button class="secondary" data-action="nomatch">Simulate a different file</button>`,
      );
    case "export":
      return sheet(
        "Save a separate copy",
        `<p class="lead">The real app will ask where to save a byte-identical copy. It will never overwrite an original automatically.</p><div class="info-box">${exportTargetDescription()}</div><button class="primary" data-action="exportdone">Simulate save completed</button><p class="caption">No file is created by this prototype.</p>`,
      );
    default:
      return sheet(
        "About this preview",
        `<p class="lead">Interactive design prototype. Reading surfaces, documents, history and storage figures are illustrative fixtures.</p><div class="info-box">No native document engine, device file access or real storage operations run here.</div><button class="primary" data-action="close">Got it</button>`,
      );
  }
}
function sheet(title, body) {
  return `<section class="sheet" role="dialog" tabindex="-1" aria-modal="true" aria-label="${title}"><div class="handle"></div><div class="sheet-head"><h2>${title}</h2>${btn("close", "Close dialog", "close")}</div>${body}</section>`;
}
