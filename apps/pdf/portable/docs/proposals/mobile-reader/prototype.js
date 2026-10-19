function render() {
  app.className = `app ${state.large ? "large" : ""} ${state.dark ? "dark" : ""}`;
  app.innerHTML =
    status() +
    (
      { reader, groups: groupScreen, documents, collection, history, storage }[
        state.screen
      ] || reader
    )() +
    home() +
    (state.sheet
      ? `<div class="sheet-scrim ${state.sheet === "wheel" ? "wheel-scrim" : ""}" id="scrim">${sheetBody()}</div>`
      : "");
  bind();
  renderReadingEnhancements();
  scaleLargeText();
  if (state.sheet) [...app.children].filter(el => el.id !== "scrim").forEach(el => el.inert = true);
  if (state.sheet && state.sheet !== "wheel" && !gesture) {
    requestAnimationFrame(() =>
      $('#scrim [role="dialog"]')?.focus({ preventScroll: true }),
    );
  }
}
function escapeHtml(s) {
  return s.replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ],
  );
}
function toast(message) {
  clearTimeout(toastTimer);
  $("#toast").textContent = message;
  $("#toast").classList.add("visible");
  toastTimer = setTimeout(() => $("#toast").classList.remove("visible"), 3200);
}
function closeSheet() {
  state.renaming = false;
  state.sheet = null;
  render();
  requestAnimationFrame(() =>
    (app.querySelector(`[data-action="${returnFocus || "switcher"}"]`) || $("#switch-control") || app.querySelector("button"))?.focus({ preventScroll: true }),
  );
}
function openDoc(id) {
  state.doc = Number(id);
  state.searchActive = false;
  state.staleMatch = false;
  state.unverified = false;
  state.sheet = null;
  state.screen = "reader";
  state.older = false;
  hover = -1;
  render();
}
function act(action) {
  const [name, value] = action.split(":");
  if (handleReadingAction(name, value)) return;
  if (
    [
      "reader",
      "groups",
      "collection",
      "history",
      "storage",
      "documents",
    ].includes(name)
  ) {
    if (name === "history" && state.sheet === "docmenu") state.doc = state.menuDoc;
    state.screen = name;
    state.sheet = null;
    state.query = "";
    render();
    return;
  }
  switch (name) {
    case "back":
      state.screen = "groups";
      state.sheet = null;
      break;
    case "close":
      closeSheet();
      return;
    case "doc":
      openDoc(value);
      return;
    case "sample":
      if (state.screen === "documents") {
        docs[Number(value)].group = groups[state.group].name;
        recount();
      }
      openDoc(value);
      return;
    case "group":
      state.group = Number(value);
      state.screen = "documents";
      state.query = "";
      break;
    case "filter":
      state.filter = value;
      break;
    case "older":
      state.older = true;
      state.revisionDate = value === "12" ? "12 Sep 2026" : "18 Sep 2026";
      state.screen = "reader";
      state.sheet = null;
      break;
    case "latest":
      state.older = false;
      state.screen = "reader";
      state.sheet = null;
      break;
    case "keep":
      state.kept = !state.kept;
      toast(
        state.kept
          ? "This version is protected from cleanup."
          : "Keep removed. The version remains saved.",
      );
      break;
    case "consent-on":
      state.collection = true;
      state.consented = true;
      state.sheet = null;
      toast("Sample Collection enabled.");
      break;
    case "consent-off":
      state.collection = false;
      state.consented = true;
      state.sheet = null;
      toast("New capture is off. Existing history stays available.");
      break;
    case "applycleanup":
      state.cleaned = true;
      state.sheet = null;
      toast("Sample cleanup complete · 62 MiB reclaimed.");
      break;
    case "togglecollection":
      state.collection = !state.collection;
      toast(
        state.collection
          ? "New captures enabled in this preview."
          : "New captures stopped; existing history kept.",
      );
      break;
    case "limitpick":
      state.sheet = "cleanup";
      toast(
        `Previewing ${value.replace(" · current", "")} limit; sample values only.`,
      );
      break;
    case "dark":
      state.dark = !state.dark;
      break;
    case "large":
      state.large = !state.large;
      break;
    case "creategroup": {
      const name = $("#new-name").value.trim();
      if (!name) {
        toast("Give your group a name first.");
        return;
      }
      if (state.renaming) {
        const old = groups[state.group].name;
        groups[state.group].name = name;
        docs.filter(x => x.group === old).forEach(x => x.group = name);
        state.renaming = false;
      } else groups.push({
        name,
        count: 0,
        sub: "A fresh place for your next idea",
        color: "blue",
      });
      state.sheet = null;
      state.screen = "groups";
      toast("Group saved.");
      break;
    }
    case "groupmenu":
      state.sheet = "groupmenu";
      break;
    case "docmenu":
      state.menuDoc = Number(value);
      state.sheet = "docmenu";
      break;
    case "move":
      docs[state.menuDoc ?? state.doc].group = groups[Number(value)].name;
      recount();
      state.sheet = null;
      toast("Document moved. Its saved position stays with it.");
      break;
    case "pin":
      if (!state.slots.includes(state.menuDoc ?? state.doc)) state.slots[5] = state.menuDoc ?? state.doc;
      state.sheet = null;
      toast("Pinned to a stable wheel slot.");
      break;
    case "renamegroup":
      state.renaming = true;
      state.sheet = "newgroup";
      break;
    case "recolorgroup":
      groups[state.group].color =
        groups[state.group].color === "ochre" ? "blue" : "ochre";
      state.sheet = null;
      toast("Group color changed.");
      break;
    case "deletegroup": {
      let g = groups[state.group];
      if (g.name === "General") {
        toast("General is the default destination in this preview.");
        return;
      }
      docs
        .filter((x) => x.group === g.name)
        .forEach((x) => (x.group = "General"));
      groups.splice(state.group, 1);
      recount();
      state.screen = "groups";
      state.sheet = null;
      toast("Documents moved to General. No files or history deleted.");
      break;
    }
    case "chapter":
      state.sheet = null;
      toast(
        `Sample chapter ${Number(value) + 1} selected. Native navigation is simulated.`,
      );
      break;
    case "found":
      state.sheet = null;
      toast("Sample match: “Light moves across the floor.”");
      break;
    case "missing":
      state.missing = true;
      state.sheet = "missing";
      break;
    case "relink":
      state.missing = false;
      state.sheet = null;
      toast("Sample original reconnected. History preserved.");
      break;
    case "nomatch":
      toast("Different content. History was not reconnected.");
      break;
    case "exportdone":
      state.sheet = null;
      toast("Simulated save complete. No file was written.");
      break;
    default:
      state.sheet = name === "wheel" && state.large ? "switcher" : name;
  }
  render();
}
function recount() {
  groups.forEach((g) => {
    g.count = docs.filter((x) => x.group === g.name).length;
    g.sub = g.count
      ? `${g.count} documents · places saved`
      : "A fresh place for your next idea";
  });
}
function bind() {
  bindGlobalSearch();
  app.querySelectorAll("[data-action]").forEach((el) =>
    el.addEventListener("click", (e) => {
      if (el.id === "switch-control" && el.dataset.suppress === "true") {
        e.preventDefault();
        el.dataset.suppress = "false";
        return;
      }
      if (!state.sheet) returnFocus = el.dataset.action;
      act(el.dataset.action);
    }),
  );
  $("#group-search")?.addEventListener("input", (e) => {
    state.query = e.target.value;
    $("#group-results").innerHTML = groupRows();
    scaleLargeText();
    $("#group-results")
      .querySelectorAll("[data-action]")
      .forEach((el) => (el.onclick = () => { if (!state.sheet) returnFocus = el.dataset.action; act(el.dataset.action); }));
  });
  $("#collection-search")?.addEventListener("input", (e) => {
    state.query = e.target.value;
    $("#collection-results").innerHTML = collectionRows();
    $("#collection-count").textContent = collectionCount();
    scaleLargeText();
    $("#collection-results")
      .querySelectorAll("[data-action]")
      .forEach((el) => (el.onclick = () => { if (!state.sheet) returnFocus = el.dataset.action; act(el.dataset.action); }));
  });
  bindFind();
  $("#scrim")?.addEventListener("click", (e) => {
    if (e.target.id === "scrim") closeSheet();
  });
  const trigger = $("#switch-control");
  trigger?.addEventListener("pointerdown", startHold);
  const w = $("#wheel");
  w?.addEventListener("pointerdown", (e) => {
    if (gesture) return;
    gesture = { id: e.pointerId, held: true, armed: true, source: w };
    w.setPointerCapture(e.pointerId);
    track(e);
  });
}
function startHold(e) {
  if (e.button !== 0 || state.large) return;
  const source = e.currentTarget;
  gesture = {
    id: e.pointerId,
    x: e.clientX,
    y: e.clientY,
    held: false,
    armed: false,
    source,
    timer: setTimeout(() => {
      if (!gesture) return;
      gesture.held = true;
      source.dataset.suppress = "true";
      state.sheet = "wheel";
      const scrim = document.createElement("div");
      scrim.className = "sheet-scrim wheel-scrim";
      scrim.id = "scrim";
      scrim.innerHTML = wheel();
      app.append(scrim);
      scrim
        .querySelectorAll("[data-action]")
        .forEach((el) => (el.onclick = () => { if (!state.sheet) returnFocus = el.dataset.action; act(el.dataset.action); }));
    }, 220),
  };
  source.setPointerCapture(e.pointerId);
}
function track(e) {
  if (!gesture || gesture.id !== e.pointerId) return;
  if (!gesture.held) {
    if (Math.hypot(e.clientX - gesture.x, e.clientY - gesture.y) > 12) {
      clearTimeout(gesture.timer);
      gesture = null;
    }
    return;
  }
  const w = $("#wheel");
  if (!w) return;
  const r = w.getBoundingClientRect(),
    x = ((e.clientX - r.left - r.width / 2) * 310) / r.width,
    y = ((e.clientY - r.top - r.height / 2) * 310) / r.height,
    dist = Math.hypot(x, y);
  if (dist < 62) {
    gesture.armed = true;
    highlight(-1);
    return;
  }
  if (!gesture.armed || dist > 145) {
    highlight(-1);
    return;
  }
  let deg = ((Math.atan2(y, x) * 180) / Math.PI + 120 + 360) % 360,
    slot = Math.floor(deg / 60);
  if (hover >= 0 && slot !== hover) {
    let center = hover * 60 + 30,
      delta = Math.abs(((deg - center + 540) % 360) - 180);
    if (delta < 38) slot = hover;
  }
  highlight(slot);
}
function highlight(i) {
  if (i >= 0 && state.slots[i] === state.doc) i = -1;
  hover = i;
  app.querySelectorAll(".sector-group").forEach((g, j) => {
    g.classList.toggle("selected", i === j);
    g.querySelector("path").classList.toggle("selected", i === j);
  });
  const doc = i >= 0 ? docs[state.slots[i]] : d();
  if ($("#wheel-title")) $("#wheel-title").textContent = doc.title;
  if ($("#wheel-full-title")) $("#wheel-full-title").textContent = doc.title;
  if ($("#wheel-caption"))
    $("#wheel-caption").textContent =
      i < 0
        ? "Center to cancel"
        : doc.id === state.doc
          ? "Already reading"
          : `${doc.ext} · Release to read`;
}
document.addEventListener("pointermove", track);
document.addEventListener("pointerup", (e) => {
  if (!gesture || e.pointerId !== gesture.id) return;
  const g = gesture;
  clearTimeout(g.timer);
  gesture = null;
  if (!g.held) return;
  const selected = hover;
  hover = -1;
  if (selected >= 0 && state.slots[selected] !== state.doc)
    openDoc(state.slots[selected]);
  else closeSheet();
});
document.addEventListener("pointercancel", () => {
  if (!gesture) return;
  clearTimeout(gesture.timer);
  gesture = null;
  hover = -1;
  if (state.sheet === "wheel") closeSheet();
});
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") {
    e.preventDefault();
    if (gesture) {
      clearTimeout(gesture.timer);
      gesture = null;
    }
    state.sheet ? closeSheet() : act("groups");
  }
  if (e.key === "Tab" && state.sheet) {
    const focusable = [...$("#scrim").querySelectorAll("button,input")].filter(
        (el) => !el.disabled,
      ),
      first = focusable[0],
      last = focusable.at(-1);
    if (e.shiftKey && document.activeElement === first) {
      e.preventDefault();
      last?.focus();
    } else if (!e.shiftKey && document.activeElement === last) {
      e.preventDefault();
      first?.focus();
    }
  }
});
window.addEventListener("message", (e) => {
  if (e.origin !== location.origin || !e.data?.scene) return;
  location.search = `scene=${encodeURIComponent(e.data.scene)}`;
});
initReadingFixtures();
render();
