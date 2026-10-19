/* Pure command-wheel protocol; coordinates are CSS pixels in this browser fixture. */
(function (root) {
  const families = [
    {
      id: "navigate",
      label: "Navigate",
      icon: "↗",
      items: [
        ["previous", "Previous page"],
        ["next", "Next page"],
        ["first", "First page"],
        ["last", "Last page"],
        ["page", "Page scrub…"],
        ["contents", "Contents…"],
        ["bookmarks", "Favorites…"],
        ["return", "Return location"],
      ],
    },
    {
      id: "zoom",
      label: "Zoom",
      icon: "⌕",
      items: [
        ["width", "Fit width"],
        ["fitpage", "Fit page"],
        ["height", "Fit height"],
        ["adjust", "Adjust…"],
        ["zoomin", "Zoom in"],
        ["zoomout", "Zoom out"],
        ["z150", "150%"],
        ["z100", "100%"],
      ],
    },
    {
      id: "view",
      label: "View",
      icon: "▣",
      items: [
        ["continuous", "Continuous"],
        ["single", "Paged"],
        ["rotateleft", "Rotate left"],
        ["rotateright", "Rotate right"],
        ["dark", "Night"],
        ["light", "Light"],
        ["fullscreen", "Focus"],
        ["awake", "Keep awake"],
      ],
    },
    {
      id: "find",
      label: "Find",
      icon: "⌕",
      items: [
        ["query", "Search…"],
        ["nextmatch", "Next match"],
        ["prevmatch", "Previous match"],
        ["regex", "Regex"],
        ["matchcase", "Match case"],
        ["copytext", "Copy selection", false],
        ["translate", "Translate…", false],
        ["searchweb", "Search web…", false],
      ],
    },
    {
      id: "notes",
      label: "Notes",
      icon: "✎",
      items: [
        ["bookmark", "Favorite page"],
        ["comment", "Add comment…"],
        ["annotations", "Comments…"],
        ["editnote", "Edit note…", false],
        ["deletenote", "Delete note", false],
        ["undo", "Undo note", false],
        ["redo", "Redo note", false],
        ["highlight", "Highlight…", false],
      ],
    },
    {
      id: "document",
      label: "Document",
      icon: "▤",
      items: [
        ["history", "History…"],
        ["save", "Save copy…"],
        ["share", "Share…"],
        ["print", "Print…"],
        ["copyimage", "Copy image…"],
        ["copypage", "Copy PDF page…"],
        ["ocr", "OCR", false],
        ["info", "Information…"],
      ],
    },
  ];
  const geometry = {
    hub: 24,
    gate: 90,
    retreat: 62,
    childInner: 108,
    childOuter: 160,
    parameterGate: 172,
  };
  function initial() {
    return {
      phase: "idle",
      owner: null,
      pointer: null,
      category: null,
      preview: null,
      leaf: null,
      action: null,
      value: null,
      cancelReason: null,
      previous: { x: 0, y: 0 },
      leftHub: false,
      moved: false,
    };
  }
  function angleIndex(x, y, n) {
    if (y > 0) return null;
    let a = (Math.atan2(y, x) * 180) / Math.PI;
    if (a === 180) a = -180;
    return Math.min(n - 1, Math.max(0, Math.floor(((a + 180) / 180) * n)));
  }
  function crossing(a, b, r, direction = 1) {
    const dx = b.x - a.x,
      dy = b.y - a.y,
      A = dx * dx + dy * dy;
    if (A === 0) return null;
    const B = 2 * (a.x * dx + a.y * dy),
      C = a.x * a.x + a.y * a.y - r * r,
      D = B * B - 4 * A * C;
    if (D < 0) return null;
    for (const t of [
      (-B - Math.sqrt(D)) / (2 * A),
      (-B + Math.sqrt(D)) / (2 * A),
    ]) {
      if (t >= -1e-9 && t <= 1 + 1e-9) {
        const u = Math.max(0, Math.min(1, t));
        const p = { x: a.x + u * dx, y: a.y + u * dy };
        if ((p.x * dx + p.y * dy) * direction > 0) return p;
      }
    }
    return null;
  }
  function crossesHub(a, b) {
    const dx = b.x - a.x,
      dy = b.y - a.y,
      n = dx * dx + dy * dy,
      t = n ? Math.max(0, Math.min(1, -(a.x * dx + a.y * dy) / n)) : 0;
    return Math.hypot(a.x + t * dx, a.y + t * dy) < geometry.hub;
  }
  function parameterValue(p, x) {
    const delta = x - p.entryX;
    const room = delta >= 0 ? p.right - p.entryX : p.entryX - p.left;
    const span = delta >= 0 ? p.max - p.start : p.start - p.min;
    const raw = p.start + (room > 0 ? (delta / room) * span : 0);
    return Math.max(p.min, Math.min(p.max, Math.round(raw / p.step) * p.step));
  }
  function move(s, x, y) {
    if (s.owner !== "tools" || s.phase === "idle" || s.phase === "cancelled")
      return s;
    const now = { x, y },
      previous = s.previous,
      r = Math.hypot(x, y);
    if (s.leftHub && crossesHub(previous, now))
      return {
        ...s,
        phase: "cancelled",
        leaf: null,
        previous: now,
        cancelReason: "Returned to cancel hub",
      };
    let out = {
      ...s,
      previous: now,
      moved: true,
      leftHub: s.leftHub || r >= geometry.hub,
    };
    if (s.phase === "parameter")
      return {
        ...out,
        parameter: {
          ...s.parameter,
          value: parameterValue(s.parameter, x),
          valid:
            Math.abs(y - s.parameter.entryY) <= 44 &&
            x >= s.parameter.left &&
            x <= s.parameter.right,
        },
      };
    const retreat =
      s.phase === "children"
        ? crossing(previous, now, geometry.retreat, -1)
        : null;
    if (retreat)
      out = { ...out, phase: "families", category: null, leaf: null };
    if (out.phase === "families") {
      const gate = crossing(retreat || previous, now, geometry.gate);
      const category = gate
        ? angleIndex(gate.x, gate.y, s.inventory.length)
        : null;
      if (category === null)
        return {
          ...out,
          preview:
            r >= geometry.hub ? angleIndex(x, y, s.inventory.length) : null,
          leaf: null,
        };
      out = {
        ...out,
        phase: "children",
        category,
        preview: category,
        leaf: null,
      };
    }
    const items = out.inventory[out.category].items;
    const parameterGate = crossing(previous, now, geometry.parameterGate);
    const parameterLeaf = parameterGate
      ? angleIndex(parameterGate.x, parameterGate.y, items.length)
      : null;
    const command = parameterLeaf !== null ? items[parameterLeaf][0] : null;
    if (command === "adjust" || command === "page") {
      const zoom = command === "adjust",
        parameter = {
          id: command,
          entryX: parameterGate.x,
          entryY: parameterGate.y,
          left: out.config.left,
          right: out.config.right,
          start: zoom ? out.config.zoom : out.config.page,
          min: zoom ? 50 : 1,
          max: zoom ? 200 : 48,
          step: zoom ? 5 : 1,
        };
      parameter.value = parameterValue(parameter, x);
      parameter.valid =
        Math.abs(y - parameter.entryY) <= 44 &&
        x >= parameter.left &&
        x <= parameter.right;
      return { ...out, phase: "parameter", leaf: parameterLeaf, parameter };
    }
    const leaf =
      r >= geometry.childInner && r <= geometry.childOuter
        ? angleIndex(x, y, items.length)
        : null;
    return {
      ...out,
      leaf,
    };
  }
  function reduce(state, e) {
    const s = { ...state, action: null, value: null };
    if (e.type === "down") {
      if (s.owner === "tools")
        return { ...initial(), cancelReason: "Second contact" };
      if (e.origin !== "tools")
        return { ...initial(), owner: e.origin, pointer: e.id };
      return {
        ...initial(),
        phase: "families",
        owner: "tools",
        pointer: e.id,
        previous: { x: e.x || 0, y: e.y || 0 },
        inventory: families.map((f) => ({
          ...f,
          items: f.items.map((i) => [...i]),
        })),
        config: { left: -160, right: 160, zoom: 100, page: 12, ...e.config },
      };
    }
    if (e.type === "cancel")
      return { ...initial(), cancelReason: e.reason || "Cancelled" };
    if (e.id !== s.pointer) return s;
    if (e.type === "move") return move(s, e.x, e.y);
    if (e.type === "up") {
      if (!s.moved)
        return {
          ...initial(),
          cancelReason: s.owner === "tools" ? "No slide" : "Non-tools origin",
        };
      const end = move(s, e.x, e.y);
      if (
        end.owner === "tools" &&
        end.phase === "parameter" &&
        end.parameter.valid
      )
        return {
          ...initial(),
          action: end.parameter.id === "adjust" ? "setzoom" : "setpage",
          value: end.parameter.value,
        };
      if (
        end.owner === "tools" &&
        end.phase === "children" &&
        end.leaf !== null &&
        end.inventory[end.category].items[end.leaf][2] !== false
      )
        return {
          ...initial(),
          action: end.inventory[end.category].items[end.leaf][0],
        };
      return {
        ...initial(),
        cancelReason: end.cancelReason || "Released without a command",
      };
    }
    return s;
  }
  function fanAvailability({ width, originY, contentTop, large = false }) {
    if (large)
      return "Large text uses the Controls list. The continuous fan gesture is unavailable.";
    if (width < 360)
      return "This view is too narrow for the fan’s full-size targets. Use the Controls list; the continuous gesture is unavailable.";
    if (originY - contentTop < 245)
      return "This view is too short for the fan and its instructions. Use the Controls list; the continuous gesture is unavailable.";
    return null;
  }
  const api = {
    families,
    fanAvailability,
    geometry,
    initial,
    reduce,
    angleIndex,
    crossing,
    parameterValue,
  };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.ControlWheel = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
