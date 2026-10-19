const eventLog = [];
function dispatch(e) {
  const before = wheel;
  wheel = reduce(wheel, e);
  if (e.type === "move" && before.owner === "tools") {
    contact = { x: e.x, y: e.y };
    trace.push(contact);
    if (trace.length > 70) trace.shift();
  }
  drawWheel();
  eventLog.push({
    event: e.type,
    origin: e.origin || before.owner,
    phase: wheel.phase,
    category: wheel.category,
    leaf: wheel.leaf,
    action: wheel.action,
    value: wheel.value,
    cancel: wheel.cancelReason,
  });
  if (eventLog.length > 24) eventLog.shift();
  $("#gesture-trace").textContent = eventLog
    .map((x) => JSON.stringify(x))
    .join("\n");
  $("#trace-summary").textContent =
    `Gesture trace · ${commits + (wheel.action ? 1 : 0)} committed action(s)`;
  if (wheel.phase === "cancelled" && before.phase !== "cancelled")
    feedback("Cancelled · lift to finish");
  if (wheel.action) {
    const action = wheel.action,
      value = wheel.value;
    wheel = { ...wheel, action: null };
    execute(action, value);
  }
  if (e.type === "up" && before.owner === "tools" && wheel.cancelReason)
    feedback("Cancelled · reader unchanged");
}
tools.addEventListener("pointerdown", (e) => {
  if (e.button !== 0 || e.isPrimary === false) return;
  if (updateFanAvailability()) {
    showList();
    return;
  }
  origin = controlCenter();
  contact = local(e);
  trace = [contact];
  dispatch({
    type: "down",
    origin: "tools",
    id: e.pointerId,
    ...contact,
    config: {
      left: 20 - origin.x,
      right: origin.width - 20 - origin.x,
      page: reader.page,
      zoom: parseFloat(reader.zoom) || 100,
    },
  });
  tools.setPointerCapture(e.pointerId);
});
tools.addEventListener("pointermove", (e) => {
  if (wheel.owner !== "tools" || wheel.pointer !== e.pointerId) return;
  const p = local(e);
  dispatch({ type: "move", id: e.pointerId, ...p });
});
tools.addEventListener("pointerup", (e) => {
  if (wheel.pointer !== e.pointerId) return;
  const p = local(e);
  dispatch({ type: "up", id: e.pointerId, ...p });
  if (tools.hasPointerCapture(e.pointerId))
    tools.releasePointerCapture(e.pointerId);
});
tools.addEventListener("pointercancel", () =>
  dispatch({ type: "cancel", reason: "Pointer cancelled" }),
);
tools.addEventListener("lostpointercapture", () => {
  if (wheel.owner === "tools")
    dispatch({ type: "cancel", reason: "Pointer ownership lost" });
});
// Observes additional touches; never prevents page/default/system-origin behavior.
document.addEventListener(
  "pointerdown",
  (e) => {
    if (wheel.owner === "tools" && e.pointerId !== wheel.pointer)
      dispatch({ type: "cancel", reason: "Second contact" });
  },
  true,
);
window.addEventListener("blur", () =>
  dispatch({ type: "cancel", reason: "Window interrupted" }),
);
window.addEventListener("resize", () => {
  if (wheel.owner === "tools")
    dispatch({ type: "cancel", reason: "Layout changed" });
  updateFanAvailability();
});
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") {
    if ($("#sheet-host").innerHTML) closeSheet();
    else dispatch({ type: "cancel", reason: "Escape" });
  }
  if (
    (e.key === "Enter" || e.key === " ") &&
    document.activeElement === tools
  ) {
    e.preventDefault();
    showList();
  }
  if (e.key === "Tab" && $("#sheet-host").innerHTML) {
    const list = [
        ...$("#sheet-host").querySelectorAll("button,input,summary"),
      ].filter((el) => {
        if (el.disabled || el.tabIndex < 0 || !el.getClientRects().length)
          return false;
        const style = getComputedStyle(el);
        if (style.visibility === "hidden" || style.display === "none")
          return false;
        for (
          let ancestor = el.parentElement;
          ancestor;
          ancestor = ancestor.parentElement
        ) {
          if (
            ancestor.matches("details:not([open])") &&
            !ancestor.querySelector(":scope > summary")?.contains(el)
          )
            return false;
        }
        return true;
      }),
      first = list[0],
      last = list.at(-1);
    if (!first) {
      e.preventDefault();
      return;
    }
    if (!list.includes(document.activeElement)) {
      e.preventDefault();
      (e.shiftKey ? last : first).focus();
    } else if (e.shiftKey && document.activeElement === first) {
      e.preventDefault();
      last.focus();
    } else if (!e.shiftKey && document.activeElement === last) {
      e.preventDefault();
      first.focus();
    }
  }
});
$("#list-button").onclick = showList;
$("#contents-button").onclick = () => execute("contents");
function replay() {
  origin = controlCenter();
  const unavailable = updateFanAvailability();
  if (frame === "rest") return;
  if (unavailable) {
    showList();
    return;
  }
  if (frame === "landscape") return;
  if (frame === "large") {
    showList();
    return;
  }
  if (frame === "parameter" && !["zoom", "page"].includes(flow)) {
    parameter("adjust");
    return;
  }
  if (frame === "edges") {
    $("#wheel-overlay").innerHTML =
      '<div class="edge-band left"></div><div class="edge-band right"></div><div class="edge-bottom"></div><div class="edge-note"><strong>These gestures stay yours.</strong><br>Scroll, pan, pinch and select text on the page. System-edge swipes remain outside the Tools gesture. No wheel opens from these origins.</div>';
    return;
  }
  const target =
    flow === "night"
      ? ["view", "dark"]
      : flow === "find"
        ? ["find", "nextmatch"]
        : flow === "notes"
          ? ["notes", "bookmark"]
          : flow === "document"
            ? ["document", "info"]
            : flow === "zoom"
              ? ["zoom", "adjust"]
              : flow === "page"
                ? ["navigate", "page"]
                : ["zoom", "width"];
  const ci = families.findIndex((f) => f.id === target[0]),
    li = families[ci].items.findIndex((x) => x[0] === target[1]);
  const familyAngle = -180 + (ci + 0.5) * 30,
    leafAngle = -180 + ((li + 0.5) * 180) / families[ci].items.length;
  const down = { x: 0, y: 0 };
  contact = down;
  trace = [down];
  dispatch({
    type: "down",
    origin: "tools",
    id: 1,
    config: {
      left: 20 - origin.x,
      right: origin.width - 20 - origin.x,
      page: reader.page,
      zoom: parseFloat(reader.zoom) || 100,
    },
  });
  if (frame === "down") return;
  let p = point(frame === "family" ? 72 : 94, familyAngle);
  dispatch({ type: "move", id: 1, ...p });
  if (frame === "family") return;
  // Notes/Favorite crosses the fan on an outer arc, avoiding retreat/cancel bands.
  if (flow === "notes") {
    for (let a = familyAngle; a > leafAngle; a -= 10)
      dispatch({ type: "move", id: 1, ...point(134, a) });
  }
  p = point(134, leafAngle);
  dispatch({ type: "move", id: 1, ...p });
  if (frame === "leaf") return;
  if (["zoom", "page"].includes(flow)) {
    const gate = point(172, leafAngle);
    dispatch({ type: "move", id: 1, ...gate });
    p = { x: gate.x + 45, y: gate.y };
    dispatch({ type: "move", id: 1, ...p });
    if (frame === "parameter") return;
  }
  if (frame === "cancel" || flow === "cancel") {
    dispatch({ type: "move", id: 1, x: 0, y: 0 });
    dispatch({ type: "up", id: 1, x: 0, y: 0 });
    return;
  }
  if (frame === "commit") dispatch({ type: "up", id: 1, ...p });
}
updateReader();
requestAnimationFrame(replay);

window.commandWheelStudy = {
  getTrace: () => eventLog.map((e) => ({ ...e })),
  cancelForSourceChange: () =>
    dispatch({ type: "cancel", reason: "Source changed" }),
  getReaderState: () => ({ ...reader }),
};
