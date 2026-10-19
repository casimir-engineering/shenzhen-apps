/* Browser interaction study. All file/engine operations remain explicitly simulated. */
const $ = (s) => document.querySelector(s),
  phone = $("#phone"),
  tools = $("#tools");
const { families, geometry, initial, reduce, fanAvailability } = ControlWheel;
const params = new URLSearchParams(location.search),
  frame = params.get("frame") || "rest",
  flow = params.get("flow") || "fit";
let wheel = initial(),
  origin = null,
  trace = [],
  contact = null,
  feedbackTimer,
  sheetInvoker = null,
  commits = 0;
const reader = {
  page: 12,
  zoom: "Fit page",
  theme: "light",
  match: 0,
  bookmarked: false,
  query: "quiet",
  focus: false,
  large: frame === "large" || params.get("large") === "1",
};
const escape = (s) =>
  String(s).replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ],
  );
function controlCenter() {
  const a = phone.getBoundingClientRect(),
    b = tools.getBoundingClientRect();
  return {
    x: b.x + b.width / 2 - a.x,
    y: b.y + b.height / 2 - a.y,
    width: a.width,
    height: a.height,
  };
}
function updateFanAvailability() {
  const a = phone.getBoundingClientRect(),
    b = phone.querySelector("header").getBoundingClientRect();
  const center = controlCenter();
  const reason = fanAvailability({
    width: a.width,
    originY: center.y,
    contentTop: b.bottom - a.top,
    large: reader.large,
  });
  phone.dataset.fanAvailable = String(!reason);
  const note = $("#fan-unavailable");
  note.hidden = !reason;
  note.textContent = reason || "";
  $("#tools-label").textContent = reason ? "List" : "Tools";
  tools.setAttribute(
    "aria-label",
    reason
      ? "Open reader Controls list. Continuous fan gesture unavailable in this layout."
      : "Tools: touch, slide through a category, and release on a reader control",
  );
  return reason;
}
function local(e) {
  const rect = phone.getBoundingClientRect();
  return {
    x: e.clientX - rect.left - origin.x,
    y: e.clientY - rect.top - origin.y,
  };
}
function point(r, degrees) {
  const angle = (degrees * Math.PI) / 180;
  return { x: r * Math.cos(angle), y: r * Math.sin(angle) };
}
function svgPoint(r, a) {
  const p = point(r, a);
  return `${origin.x + p.x},${origin.y + p.y}`;
}
function slice(index, count, inner, outer) {
  const a = -180 + (index * 180) / count,
    b = -180 + ((index + 1) * 180) / count;
  return `M${svgPoint(outer, a)} A${outer},${outer} 0 0 1 ${svgPoint(outer, b)} L${svgPoint(inner, b)} A${inner},${inner} 0 0 0 ${svgPoint(inner, a)}Z`;
}
function disabledReason(id) {
  if (["copytext", "translate", "searchweb"].includes(id))
    return "Select text first; unavailable in this sample.";
  if (["editnote", "deletenote"].includes(id))
    return "Select an editable note first; unavailable in this sample.";
  if (["undo", "redo"].includes(id))
    return "No note edit history in this sample.";
  return id === "ocr"
    ? "OCR is a later capability; unavailable in this sample."
    : "Highlight is a later capability; unavailable in this sample.";
}
function labelLines(text) {
  const words = text.replace("…", "").split(" ");
  if (words.length === 1) return [text];
  if (words.length === 2) return words;
  return [words.slice(0, -1).join(" "), words.at(-1)];
}
function drawWheel() {
  const host = $("#wheel-overlay");
  phone.dataset.wheelPhase = wheel.phase;
  if (wheel.phase === "idle" || wheel.phase === "cancelled") {
    host.innerHTML = "";
    return;
  }
  if (wheel.phase === "parameter") {
    drawParameter();
    return;
  }
  const inventory = wheel.inventory || families;
  const children = wheel.phase === "children",
    entries = children ? inventory[wheel.category].items : inventory;
  const selected = children ? wheel.leaf : wheel.preview;
  const label = children ? inventory[wheel.category].label : "Reader controls";
  const choice =
    children && selected !== null
      ? entries[selected][1]
      : !children && selected !== null
        ? entries[selected].label
        : null;
  const content = entries
    .map((entry, i) => {
      const chosen = i === selected,
        disabled = children && entry[2] === false;
      const angle = -180 + ((i + 0.5) * 180) / entries.length,
        p = point(children ? 134 : 66, angle);
      const title = children ? entry[1] : entry.label,
        lines = labelLines(title);
      return `<path class="sector ${chosen ? "chosen" : ""} ${disabled ? "disabled" : ""}" d="${slice(i, entries.length, children ? 108 : 24, children ? 160 : 90)}"/><text class="fan-label ${chosen ? "chosen-label" : ""} ${disabled ? "disabled-label" : ""}" x="${origin.x + p.x}" y="${origin.y + p.y - (lines.length - 1) * 6}">${lines.map((line, j) => `<tspan x="${origin.x + p.x}" dy="${j ? 12 : 0}">${escape(line)}</tspan>`).join("")}</text>${chosen ? `<text class="checked" x="${origin.x + point(children ? 151 : 83, angle).x - 4}" y="${origin.y + point(children ? 151 : 83, angle).y + 4}">✓</text>` : ""}`;
    })
    .join("");
  let caption = children
    ? "Keep sliding to a control. Lift to apply."
    : "Slide through a category. Keep your finger down.";
  if (choice)
    caption = children ? `Release: ${choice}` : `${choice} · continue outward`;
  if (children && selected !== null && entries[selected][2] === false)
    caption = disabledReason(entries[selected][0]);
  const parameterLeaf =
    children &&
    selected !== null &&
    ["adjust", "page"].includes(entries[selected][0]);
  if (parameterLeaf)
    caption = `Continue outward to ${entries[selected][0] === "adjust" ? "adjust zoom" : "scrub pages"}; release here for numeric entry.`;
  const parameterGate = parameterLeaf
    ? `<path class="parameter-gate" d="${slice(selected, entries.length, 170, 174)}"/>`
    : "";
  const path = trace.length
    ? `<polyline class="trail" points="${trace.map((p) => `${origin.x + p.x},${origin.y + p.y}`).join(" ")}"/>`
    : "";
  host.innerHTML = `<svg viewBox="0 0 ${origin.width} ${origin.height}"><path class="fan-shade" d="M${origin.x - 172},${origin.y} A172,172 0 0 1 ${origin.x + 172},${origin.y}Z"/>${content}${parameterGate}<circle class="wheel-hub" cx="${origin.x}" cy="${origin.y}" r="24"/><text class="hub-label" x="${origin.x}" y="${origin.y - 3}">Cancel</text>${path}${contact ? `<circle class="contact-ring" cx="${origin.x + contact.x}" cy="${origin.y + contact.y}" r="15"/><circle class="contact" cx="${origin.x + contact.x}" cy="${origin.y + contact.y}" r="6"/>` : ""}</svg><div class="wheel-caption" style="top:${Math.max(30, origin.y - 233)}px"><strong>${escape(label)}${choice ? " / " + escape(choice) : ""}</strong><small>${escape(caption)}</small></div>`;
  phone.dataset.wheelPhase = wheel.phase;
  phone.dataset.preview = choice || "";
}
function updateReader() {
  phone.className = `phone ${reader.theme} ${reader.large ? "large" : ""} ${reader.focus ? "chrome-hidden" : ""}`;
  $("#page-status").textContent = `${reader.page} of 48`;
  $("#zoom-status").textContent = reader.zoom;
  $("#bookmark-status").textContent = reader.bookmarked
    ? "Page favorited"
    : "Place saved";
  $("#match-status").textContent = reader.query
    ? `${reader.match + 1} of 3`
    : "No search";
  $("#paper").style.width =
    reader.zoom === "Fit width"
      ? "100%"
      : "88%";
  $("#paper").style.zoom = /^\d+%$/.test(reader.zoom)
    ? String(parseFloat(reader.zoom) / 100)
    : "1";
  document.querySelectorAll("[data-match]").forEach((el, i) => {
    el.classList.toggle("current", reader.query && i === reader.match);
  });
  phone.dataset.lastAction = reader.lastAction || "";
  phone.dataset.commitCount = commits;
  updateFanAvailability();
}
function feedback(text) {
  clearTimeout(feedbackTimer);
  $("#feedback").textContent = text;
  $("#feedback").classList.add("visible");
  feedbackTimer = setTimeout(
    () => $("#feedback").classList.remove("visible"),
    2400,
  );
}
function sheet(title, body) {
  const active = document.activeElement;
  if (
    active?.isConnected &&
    active !== document.body &&
    !$("#sheet-host").contains(active)
  )
    sheetInvoker = active;
  $("#sheet-host").innerHTML =
    `<div class="sheet-scrim"><section class="sheet" role="dialog" aria-modal="true" tabindex="-1" aria-label="${escape(title)}"><div class="handle"></div><div class="sheet-head"><h2>${escape(title)}</h2><button data-close aria-label="Close reader control">×</button></div>${body}</section></div>`;
  [...phone.children]
    .filter((el) => !["sheet-host", "feedback"].includes(el.id))
    .forEach((el) => (el.inert = true));
  $("#sheet-host [data-close]").onclick = closeSheet;
  $("#sheet-host .sheet-scrim").onclick = (e) => {
    if (e.target.classList.contains("sheet-scrim")) closeSheet();
  };
  $("#sheet-host .sheet").focus({ preventScroll: true });
}
function closeSheet() {
  $("#sheet-host").innerHTML = "";
  [...phone.children].forEach((el) => (el.inert = false));
  const target = sheetInvoker?.isConnected ? sheetInvoker : tools;
  target.focus({ preventScroll: true });
}
function showList() {
  sheet(
    "Reader controls",
    `<p>${escape(updateFanAvailability() || "Every control affects this document. The continuous gesture is an alternative to these ordinary buttons.")}</p>${families.map((f) => `<details ${reader.large ? "open" : ""}><summary>${f.label}</summary>${f.items.map(([id, title, enabled]) => `<button class="action" data-command="${id}" ${enabled === false ? "disabled" : ""}><span>${title}</span>${enabled === false ? `<small>${escape(disabledReason(id))}</small>` : "<span>›</span>"}</button>`).join("")}</details>`).join("")}<div class="small-note">48 stable commands. Disabled actions stay in their positions. No document or library navigation.</div>`,
  );
  $("#sheet-host")
    .querySelectorAll("[data-command]")
    .forEach(
      (el) =>
        (el.onclick = () => {
          closeSheet();
          execute(el.dataset.command);
        }),
    );
}
function parameter(type) {
  const zoom = type === "adjust",
    title = zoom ? "Adjust zoom" : "Go to page",
    current = zoom ? parseFloat(reader.zoom) || 100 : reader.page;
  sheet(
    title,
    `<p>The gesture opens this control. Choosing a numeric value is a separate, explicit step.</p><label for="parameter-value">${zoom ? "Zoom percentage" : "Page number"}</label><input id="parameter-value" type="number" inputmode="numeric" min="${zoom ? 50 : 1}" max="${zoom ? 200 : 48}" step="${zoom ? 5 : 1}" value="${current}"><div class="page-model" id="parameter-preview">${zoom ? current + "%" : `Page ${current} of 48`}</div><button class="primary" id="parameter-apply">Apply ${zoom ? "zoom" : "page"}</button>`,
  );
  $("#parameter-value").oninput = (e) =>
    ($("#parameter-preview").textContent = zoom
      ? e.target.value + "%"
      : `Page ${e.target.value} of 48`);
  $("#parameter-apply").onclick = () => {
    const input = $("#parameter-value"),
      raw = input.valueAsNumber;
    if (!Number.isFinite(raw)) {
      feedback("Enter a number before applying.");
      input.focus({ preventScroll: true });
      return;
    }
    const value = Math.max(
      zoom ? 50 : 1,
      Math.min(
        zoom ? 200 : 48,
        Math.round(raw / (zoom ? 5 : 1)) * (zoom ? 5 : 1),
      ),
    );
    if (zoom) reader.zoom = value + "%";
    else reader.page = value;
    closeSheet();
    updateReader();
    feedback(zoom ? reader.zoom : `Page ${reader.page}`);
  };
}
function scrollReaderTo(target, center = false) {
  if (!target) return;
  const reading = $("#reading"),
    box = reading.getBoundingClientRect(),
    item = target.getBoundingClientRect();
  reading.scrollTop +=
    item.top -
    box.top -
    (center ? (reading.clientHeight - item.height) / 2 : 12);
}
function execute(id, value) {
  reader.lastAction = id;
  commits++;
  const item = families.flatMap((f) => f.items).find((x) => x[0] === id),
    label = item?.[1] || id;
  switch (id) {
    case "setzoom":
      reader.zoom = value + "%";
      feedback(`Zoom ${value}% applied`);
      break;
    case "setpage":
      reader.page = value;
      feedback(`Page ${value} applied · sample position`);
      break;
    case "width":
      reader.zoom = "Fit width";
      feedback("Fit width applied");
      break;
    case "fitpage":
      reader.zoom = "Fit page";
      feedback("Fit page applied");
      break;
    case "height":
      reader.zoom = "Fit height";
      feedback("Fit height · sample state");
      break;
    case "z100":
      reader.zoom = "100%";
      feedback("100% zoom");
      break;
    case "z150":
      reader.zoom = "150%";
      feedback("150% zoom");
      break;
    case "zoomin":
      reader.zoom = Math.min(200, (parseFloat(reader.zoom) || 100) + 25) + "%";
      feedback(`Zoom ${reader.zoom} · maximum 200%`);
      break;
    case "zoomout":
      reader.zoom = Math.max(50, (parseFloat(reader.zoom) || 100) - 25) + "%";
      feedback(`Zoom ${reader.zoom} · minimum 50%`);
      break;
    case "dark":
      reader.theme = "dark";
      feedback("Night reading applied");
      break;
    case "light":
      reader.theme = "light";
      feedback("Light reading applied");
      break;
    case "nextmatch":
      reader.match = (reader.match + 1) % 3;
      feedback(`Match ${reader.match + 1} of 3`);
      requestAnimationFrame(() =>
        scrollReaderTo(
          document.querySelector(`[data-match="${reader.match}"]`),
          true,
        ),
      );
      break;
    case "prevmatch":
      reader.match = (reader.match + 2) % 3;
      feedback(`Match ${reader.match + 1} of 3`);
      requestAnimationFrame(() =>
        scrollReaderTo(
          document.querySelector(`[data-match="${reader.match}"]`),
          true,
        ),
      );
      break;
    case "previous":
      reader.page = Math.max(1, reader.page - 1);
      feedback(`Page ${reader.page} · sample position`);
      break;
    case "next":
      reader.page = Math.min(48, reader.page + 1);
      feedback(`Page ${reader.page} · sample position`);
      break;
    case "first":
      reader.page = 1;
      feedback("Page 1 · sample position");
      break;
    case "last":
      reader.page = 48;
      feedback("Page 48 · sample position");
      break;
    case "bookmark":
      reader.bookmarked = !reader.bookmarked;
      feedback(
        reader.bookmarked
          ? "Page added to Favorites"
          : "Page removed from Favorites",
      );
      break;
    case "fullscreen":
      reader.focus = !reader.focus;
      feedback(
        reader.focus
          ? "Focus mode · Tools remains available"
          : "Reader chrome shown",
      );
      break;
    case "adjust":
    case "page":
      parameter(id);
      break;
    case "query":
      sheet(
        "Find in this document",
        `<p>The wheel reaches Find in one contact. Entering a query comes next.</p><input id="query-input" aria-label="Find sample text" placeholder="Try quiet" value="${escape(reader.query)}"><button class="primary" id="query-apply">Find sample matches</button><div id="query-message" class="small-note"></div>`,
      );
      $("#query-apply").onclick = () => {
        const q = $("#query-input").value.trim();
        if (q.toLowerCase() === "quiet") {
          reader.query = q;
          reader.match = 0;
          closeSheet();
          updateReader();
          feedback("3 sample matches");
        } else
          $("#query-message").textContent =
            "No indexed sample matches. Try “quiet”.";
      };
      break;
    case "contents":
      sheet(
        "Document contents",
        `<p>Geometry of quiet · Current document</p>${["Geometry of quiet", "Leave a little room", "Return to the ordinary"].map((title, i) => `<button class="action" data-heading="${i}">${title}<span>›</span></button>`).join("")}`,
      );
      $("#sheet-host")
        .querySelectorAll("[data-heading]")
        .forEach(
          (el) =>
            (el.onclick = () => {
              const index = Number(el.dataset.heading);
              closeSheet();
              scrollReaderTo(
                document.querySelectorAll(".paper h1,.paper h2")[index],
              );
            }),
        );
      break;
    case "info":
      sheet(
        "Document information",
        '<div class="page-model">Geometry of quiet.pdf<br>48 pages · PDF fixture<br>Current document only</div><p>Browser design prototype. No native PDF engine or device files.</p>',
      );
      break;
    case "comment":
      sheet(
        "Add a comment",
        '<p>Next choose a location in this document, then enter your comment. The wheel chooses the tool; it does not invent a selection or post a comment.</p><div class="page-model">Location not selected · Prototype only</div>',
      );
      break;
    default:
      sheet(
        label.replace("…", ""),
        `<p><strong>Prototype placeholder:</strong> ${escape(label.replace("…", ""))} was selected. The document has not been changed by this command.</p><div class="page-model">Illustrative control state. No native ${escape(label.toLowerCase().replace("…", ""))} operation runs in this prototype.</div>`,
      );
  }
  updateReader();
}

function drawParameter() {
  const p = wheel.parameter,
    y = origin.y + p.entryY,
    left = origin.x + p.left,
    right = origin.x + p.right;
  const room = p.value >= p.start ? p.right - p.entryX : p.entryX - p.left;
  const span = p.value >= p.start ? p.max - p.start : p.start - p.min;
  const knob =
    origin.x + p.entryX + (span ? ((p.value - p.start) / span) * room : 0);
  const label = p.id === "adjust" ? `${p.value}%` : `Page ${p.value} of 48`;
  $("#wheel-overlay").innerHTML =
    `<svg viewBox="0 0 ${origin.width} ${origin.height}"><rect x="12" y="${y - 61}" width="${origin.width - 24}" height="122" rx="18" class="fan-shade"/><rect class="parameter-band" x="${left}" y="${y - 44}" width="${right - left}" height="88" rx="12"/><line class="parameter-line" x1="${left}" y1="${y}" x2="${right}" y2="${y}"/><circle class="parameter-knob" cx="${knob}" cy="${y}" r="10"/><text class="parameter-number" x="${origin.width / 2}" y="${y - 30}">${label}</text><text class="parameter-help" x="${origin.width / 2}" y="${y + 39}">${p.valid ? "Preview only · release in this rail to apply" : "Outside rail · release cancels"}</text>${contact ? `<circle class="contact-ring" cx="${origin.x + contact.x}" cy="${origin.y + contact.y}" r="15"/>` : ""}<circle class="wheel-hub" cx="${origin.x}" cy="${origin.y}" r="24"/><text class="hub-label" x="${origin.x}" y="${origin.y - 3}">Cancel</text></svg>`;
  phone.dataset.preview = label;
}
