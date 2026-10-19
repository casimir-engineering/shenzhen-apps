/* Pure protocol evidence. No browser, native engine, or device gesture claims. */
const assert = require("node:assert/strict");
const {
  families,
  fanAvailability,
  geometry,
  initial,
  reduce,
} = require("./command-wheel-state.js");
const checks = [];
function test(name, fn) {
  fn();
  checks.push(name);
}
function p(radius, index, count) {
  const a = ((-180 + ((index + 0.5) * 180) / count) * Math.PI) / 180;
  return { x: radius * Math.cos(a), y: radius * Math.sin(a) };
}
const down = (s = initial(), origin = "tools", id = 1, config = {}) =>
  reduce(s, { type: "down", origin, id, config });
const move = (s, pos, id = 1) => reduce(s, { type: "move", id, ...pos });
const up = (s, pos, id = 1) => reduce(s, { type: "up", id, ...pos });
function route(category, leaf) {
  let s = down();
  s = move(s, p(94, category, 6));
  return move(s, p(134, leaf, 8));
}
function param(category, leaf) {
  let s = route(category, leaf);
  return move(s, p(172, leaf, 8));
}
function noAction(s) {
  assert.equal(s.action, null);
}
test("48 stable reader slots", () => {
  assert.equal(families.length, 6);
  families.forEach((f) => assert.equal(f.items.length, 8));
});
test("down reveals categories immediately", () =>
  assert.equal(down().phase, "families"));
test("down then up without movement cancels", () =>
  noAction(up(down(), p(134, 1, 8))));
test("category crossing is preview only", () => {
  const s = move(down(), p(94, 1, 6));
  assert.equal(s.category, 1);
  noAction(s);
});
test("same contact commits Fit width exactly once", () => {
  const s = route(1, 0);
  noAction(s);
  const done = up(s, p(134, 0, 8));
  assert.equal(done.action, "width");
  noAction(up(done, p(134, 0, 8)));
});
test("Night action", () =>
  assert.equal(up(route(2, 4), p(134, 4, 8)).action, "dark"));
test("Next match action", () =>
  assert.equal(up(route(3, 1), p(134, 1, 8)).action, "nextmatch"));
test("sparse event crosses category and child bands", () => {
  const s = move(down(), p(134, 2, 6));
  assert.equal(s.phase, "children");
  assert.equal(s.category, 2);
  assert.notEqual(s.leaf, null);
  noAction(s);
});
test("first outward gate intersection determines family", () => {
  let s = move(down(), { x: 0, y: -70 });
  s = move(s, { x: 134, y: -60 });
  assert.equal(s.category, 4);
  assert.equal(
    Math.floor(((Math.atan2(-60, 134) * 180) / Math.PI + 180) / 30),
    5,
  );
});
test("arc outside retreat band keeps far-left family locked", () => {
  let s = move(down(), p(94, 0, 6));
  for (let angle = -165; angle <= -15; angle += 5)
    s = move(s, {
      x: 134 * Math.cos((angle * Math.PI) / 180),
      y: 134 * Math.sin((angle * Math.PI) / 180),
    });
  s = move(s, p(134, 7, 8));
  assert.equal(s.category, 0);
  assert.equal(s.leaf, 7);
  assert.equal(up(s, p(134, 7, 8)).action, "return");
});
test("sparse inward retreat and outward relock match a dense straight segment", () => {
  const a = p(94, 0, 6),
    b = p(134, 7, 8),
    start = move(down(), a);
  const sparse = move(start, b);
  let dense = start;
  for (let i = 1; i <= 30; i++)
    dense = move(dense, {
      x: a.x + ((b.x - a.x) * i) / 30,
      y: a.y + ((b.y - a.y) * i) / 30,
    });
  assert.equal(sparse.category, 5);
  assert.equal(sparse.leaf, 7);
  assert.equal(sparse.phase, dense.phase);
  assert.equal(sparse.category, dense.category);
  assert.equal(sparse.leaf, dense.leaf);
  assert.equal(up(sparse, b).action, "info");
  assert.equal(up(dense, b).action, "info");
});
test("retreat band unlocks without recenter", () => {
  const s = move(route(1, 0), p(61, 3, 6));
  assert.equal(s.phase, "families");
  assert.equal(s.preview, 3);
  noAction(s);
});
test("hub cancel is terminal until release", () => {
  let s = move(route(1, 0), { x: 0, y: 0 });
  assert.equal(s.phase, "cancelled");
  s = move(s, p(134, 1, 8));
  assert.equal(s.phase, "cancelled");
  noAction(up(s, p(134, 1, 8)));
});
test("sparse segment through hub cancels", () => {
  let s = move(down(), { x: -80, y: -5 });
  s = move(s, { x: 80, y: -5 });
  assert.equal(s.phase, "cancelled");
});
test("outside release cancels", () =>
  noAction(up(route(1, 0), { x: 170, y: 0 })));
test("lower half release cancels", () =>
  noAction(up(route(1, 0), { x: 0, y: 130 })));
test("category-band release cancels", () =>
  noAction(up(move(down(), p(70, 1, 6)), p(70, 1, 6))));
test("disabled OCR cannot execute", () => {
  assert.equal(families[5].items[6][0], "ocr");
  const s = route(5, 6);
  assert.equal(s.leaf, 6);
  noAction(up(s, p(134, 6, 8)));
});
test("page-origin crossing Tools cannot activate", () => {
  let s = down(initial(), "page");
  s = move(s, p(134, 1, 8));
  assert.equal(s.phase, "idle");
  noAction(up(s, p(134, 1, 8)));
});
test("system-origin cannot activate", () => {
  let s = down(initial(), "system");
  s = move(s, p(134, 4, 8));
  assert.equal(s.phase, "idle");
  noAction(up(s, p(134, 4, 8)));
});
test("second touch cancels without redispatch", () => {
  const s = down(route(1, 0), "page", 2);
  assert.equal(s.phase, "idle");
  noAction(s);
  noAction(up(s, p(134, 0, 8)));
});
test("ownership/source cancellation clears pending action", () => {
  for (const reason of ["lost ownership", "source changed"]) {
    const s = reduce(route(1, 0), { type: "cancel", reason });
    assert.equal(s.phase, "idle");
    noAction(s);
  }
});
test("foreign pointer cannot commit", () =>
  noAction(up(route(1, 0), p(134, 0, 8), 9)));
test("inventory freezes at down", () => {
  const s = down();
  const old = families[1].items[0][0];
  families[1].items[0][0] = "changed";
  assert.equal(s.inventory[1].items[0][0], old);
  families[1].items[0][0] = old;
});
test("parameter entry keeps existing zoom with no jump", () => {
  const s = param(1, 3);
  assert.equal(s.phase, "parameter");
  assert.equal(s.parameter.value, 100);
  noAction(s);
});
test("continuous zoom previews then commits on same release", () => {
  let s = param(1, 3);
  const q = { x: s.parameter.entryX + 45, y: s.parameter.entryY };
  s = move(s, q);
  assert.equal(s.parameter.value, 125);
  noAction(s);
  const result = up(s, q);
  assert.equal(result.action, "setzoom");
  assert.equal(result.value, 125);
});
test("page parameter keeps existing page then commits detent", () => {
  let s = param(0, 4);
  assert.equal(s.parameter.value, 12);
  const q = { x: s.parameter.entryX + 45, y: s.parameter.entryY };
  s = move(s, q);
  const result = up(s, q);
  assert.equal(result.action, "setpage");
  assert.equal(result.value, 25);
});
test("parameter outside rail release cancels", () => {
  let s = param(1, 3);
  noAction(up(s, { x: s.parameter.entryX + 40, y: s.parameter.entryY + 45 }));
});
test("parameter hub cancellation is terminal", () => {
  let s = param(1, 3);
  s = move(s, { x: 0, y: 0 });
  assert.equal(s.phase, "cancelled");
  noAction(up(s, { x: 100, y: -160 }));
});
test("parameter cancellation never emits preview as action", () => {
  let s = param(1, 3);
  s = move(s, { x: 140, y: s.parameter.entryY });
  assert.equal(s.parameter.value, 190);
  noAction(reduce(s, { type: "cancel", reason: "system" }));
});
test("ordinary Adjust leaf release still opens editor", () =>
  assert.equal(up(route(1, 3), p(134, 3, 8)).action, "adjust"));
test("geometry fits 360dp fixed origin", () => {
  assert.equal(geometry.gate, 90);
  assert.equal(geometry.retreat, 62);
  assert.equal(geometry.hub, 24);
  assert.equal(geometry.parameterGate, 172);
  assert.equal(180 - geometry.childOuter, 20);
  assert.equal(geometry.childOuter - geometry.childInner, 52);
});
test("fan keeps full-size targets at 360 and rejects narrower views", () => {
  assert.equal(
    fanAvailability({ width: 360, originY: 730, contentTop: 100 }),
    null,
  );
  assert.match(
    fanAvailability({ width: 359, originY: 730, contentTop: 100 }),
    /too narrow/,
  );
});
test("short layout and large text honestly use the Controls list", () => {
  assert.match(
    fanAvailability({ width: 844, originY: 325, contentTop: 100 }),
    /too short/,
  );
  assert.match(
    fanAvailability({ width: 390, originY: 730, contentTop: 100, large: true }),
    /Large text/,
  );
});
console.log(
  JSON.stringify(
    {
      passed: checks.length,
      scope: "Pure reader-control gesture reducer; native touch not tested",
      checks,
    },
    null,
    2,
  ),
);
