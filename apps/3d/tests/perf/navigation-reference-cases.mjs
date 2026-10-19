// Independent expected behavior from the user's fixed camera-control contract.
// Modifier keys must not change a drag's action.
export const modifiers = [
  [],
  ["Shift"],
  ["Control"],
  ["Meta"],
  ["Alt"],
  ["Shift", "Control"],
  ["Shift", "Meta"],
  ["Control", "Meta"],
  ["Shift", "Control", "Meta"],
];
export const fixedBindings = [
  { button: "left", action: "pan" },
  { button: "middle", action: "pan" },
  { button: "right", action: "orbit" },
];
export const wheelCases = [
  ...[
    1, 7, 40, 53, 100, 120, 0.25, 100.5, -1, -7, -40, -53, -100, -120, -0.25,
  ].map((deltaY) => ({ deltaX: 0, deltaY, deltaMode: 0 })),
  { deltaX: 14.5, deltaY: 22.5, deltaMode: 0 },
  { deltaX: -14.5, deltaY: -22.5, deltaMode: 0 },
  { deltaX: 0, deltaY: 1, deltaMode: 1 },
  { deltaX: 0, deltaY: -3, deltaMode: 1 },
  { deltaX: 0, deltaY: 1, deltaMode: 2 },
  { deltaX: 0, deltaY: -0.25, deltaMode: 2 },
];
// Recorded Chromium CDP wheel events retain a full legacy tick even for tiny
// pixel deltas. Native precision events are tested separately in classifier units.
export const discreteWheelCases = wheelCases.map((event) => ({
  ...event,
  wheelDeltaX: event.deltaX ? -Math.sign(event.deltaX) * 120 : 0,
  wheelDeltaY: event.deltaY ? -Math.sign(event.deltaY) * 120 : 0,
}));
// Browser precision samples use non-discrete legacy deltas (the Chromium
// precision-scroll relationship), plus explicit momentum. No hardware claim is
// inferred from an arbitrary pixel amplitude alone.
export const precisionWheelCases = [
  ...[0.25, 1, 7, 53, 100, 100.5, -0.25, -7, -53, -100].map((deltaY) => ({
    deltaX: 0,
    deltaY,
    deltaMode: 0,
    wheelDeltaX: 0,
    wheelDeltaY: -3 * deltaY,
  })),
  {
    deltaX: 37.5,
    deltaY: 0,
    deltaMode: 0,
    wheelDeltaX: -112.5,
    wheelDeltaY: 0,
  },
  {
    deltaX: 14.5,
    deltaY: 22.5,
    deltaMode: 0,
    wheelDeltaX: -43.5,
    wheelDeltaY: -67.5,
  },
  {
    deltaX: -14.5,
    deltaY: -22.5,
    deltaMode: 0,
    wheelDeltaX: 43.5,
    wheelDeltaY: 67.5,
  },
  { deltaX: 0, deltaY: 120, deltaMode: 0, wheelDeltaY: -120, momentum: true },
];
