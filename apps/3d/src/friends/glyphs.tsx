// The route and action glyphs Friends pages draw: the AppKit views' paths (mac/SZFriendsIcons.m), as the GTK
// views draw them.
import type { Found, Route } from "./protocol";

type GlyphName =
  | "people"
  | "check"
  | "close"
  | "block"
  | "lan"
  | "p2p_wifi"
  | "bluetooth"
  | "internet"
  | "relay"
  | "offline"
  | "copy"
  | "back"
  | "verified";

const arc = (cx: number, cy: number, r: number, from: number, to: number) => {
  const a = (from * Math.PI) / 180,
    b = (to * Math.PI) / 180;
  const large = Math.abs(to - from) > 180 ? 1 : 0,
    sweep = to > from ? 1 : 0;
  const start = `${cx + r * Math.cos(a)} ${cy + r * Math.sin(a)}`;
  const end = `${cx + r * Math.cos(b)} ${cy + r * Math.sin(b)}`;
  return `M${start}A${r} ${r} 0 ${large} ${sweep} ${end}`;
};
const GLYPHS: Record<
  GlyphName,
  {
    box: number;
    width: number;
    d: string;
    dots?: [number, number, number][];
    fill?: boolean;
  }
> = {
  people: {
    box: 16,
    width: 0,
    fill: true,
    d:
      "M2.85 5.5A3.15 3.15 0 1 1 9.15 5.5A3.15 3.15 0 1 1 2.85 5.5ZM4.15 5.5A1.85 1.85 0 1 0 " +
      "7.85 5.5A1.85 1.85 0 1 0 4.15 5.5ZM2.15 13.5C2.15 12.43 2.562 11.626 3.232 11.059C3.907 " +
      "10.488 4.877 10.15 6 10.15C7.123 10.15 8.093 10.488 8.768 11.059C9.438 11.626 9.85 " +
      "12.43 9.85 13.5A0.65 0.65 0 0 0 11.15 13.5C11.15 12.07 10.562 10.874 9.607 10.066C8.657 " +
      "9.262 7.377 8.85 6 8.85C4.623 8.85 3.343 9.262 2.393 10.066C1.438 10.874 0.85 12.07 " +
      "0.85 13.5A0.65 0.65 0 0 0 2.15 13.5ZM8.55 5A2.65 2.65 0 1 1 13.85 5A2.65 2.65 0 1 1 " +
      "8.55 5ZM9.85 5A1.35 1.35 0 1 0 12.55 5A1.35 1.35 0 1 0 9.85 5ZM11.168 10.049C12.024 " +
      "10.092 12.706 10.406 13.181 10.9C13.655 11.394 13.95 12.095 13.95 13A0.65 0.65 0 0 0 " +
      "15.25 13C15.25 11.805 14.845 10.756 14.119 10C13.394 9.244 12.376 8.808 11.232 8.751" +
      "A0.65 0.65 0 0 0 11.168 10.049Z",
  },
  check: { box: 16, width: 1.8, d: "M3 8.5L6.5 12L13 4.5" },
  close: { box: 16, width: 1.5, d: "M4.5 4.5L11.5 11.5M11.5 4.5L4.5 11.5" },
  block: {
    box: 16,
    width: 1.6,
    d: "M14 8A6 6 0 1 1 2 8A6 6 0 1 1 14 8ZM3.8 12.2L12.2 3.8",
  },
  lan: {
    box: 12,
    width: 1.2,
    d: [3.4, 5.8]
      .map((r) => arc(6, 6, r, 135, 225) + arc(6, 6, r, -45, 45))
      .join(""),
    dots: [[6, 6, 1.4]],
  },
  p2p_wifi: {
    box: 12,
    width: 1.1,
    d:
      "M1.8 4.4H4A0.5 0.5 0 0 1 4.5 4.9V6.5A0.5 0.5 0 0 1 4 7H1.8A0.5 0.5 0 0 1 1.3 6.5V4.9" +
      "A0.5 0.5 0 0 1 1.8 4.4ZM8 4.4H10.2A0.5 0.5 0 0 1 10.7 4.9V6.5A0.5 0.5 0 0 1 10.2 7H8" +
      "A0.5 0.5 0 0 1 7.5 6.5V4.9A0.5 0.5 0 0 1 8 4.4ZM0.8 9.27H5M7 9.27H11.2M3.4 2.4C4.8 0.5 " +
      "7.2 0.5 8.6 2.4",
  },
  bluetooth: {
    box: 12,
    width: 1.1,
    d: "M3.5 3.75L8.4 8.25L6.1 10.5V1.5L8.4 3.75L3.5 8.25",
  },
  internet: {
    box: 12,
    width: 1.1,
    d:
      "M10.6 6A4.6 4.6 0 1 1 1.4 6A4.6 4.6 0 1 1 10.6 6ZM1.4 6H10.6M6 1.4C7.1 1.4 8 3.46 8 " +
      "6S7.1 10.6 6 10.6S4 8.54 4 6S4.9 1.4 6 1.4Z",
  },
  relay: {
    box: 12,
    width: 1.1,
    d:
      "M2.5 1.5H9.5A1 1 0 0 1 10.5 2.5V4.5A1 1 0 0 1 9.5 5.5H2.5A1 1 0 0 1 1.5 4.5V2.5A1 1 0 0 " +
      "1 2.5 1.5ZM2.5 6.5H9.5A1 1 0 0 1 10.5 7.5V9.5A1 1 0 0 1 9.5 10.5H2.5A1 1 0 0 1 1.5 9.5" +
      "V7.5A1 1 0 0 1 2.5 6.5Z",
    dots: [
      [3.6, 3.5, 0.75],
      [3.6, 8.5, 0.75],
    ],
  },
  offline: {
    box: 12,
    width: 1.2,
    d: "M9.6 6A3.6 3.6 0 1 1 2.4 6A3.6 3.6 0 1 1 9.6 6ZM1.6 10.4L10.4 1.6",
  },
  copy: {
    box: 16,
    width: 1.4,
    d:
      "M6.5 5H12A1.5 1.5 0 0 1 13.5 6.5V12A1.5 1.5 0 0 1 12 13.5H6.5A1.5 1.5 0 0 1 5 12V6.5" +
      "A1.5 1.5 0 0 1 6.5 5ZM3 10.5V3.5A1 1 0 0 1 4 2.5H10.5",
  },
  back: { box: 16, width: 1.6, d: "M10 3L5 8L10 13" },
  verified: {
    box: 16,
    width: 1.6,
    d: "M14 8A6 6 0 1 1 2 8A6 6 0 1 1 14 8ZM5.2 8.2L7.2 10.2L10.8 6",
  },
};

export function Glyph({
  name,
  size = 16,
  className,
}: {
  name: GlyphName;
  size?: number;
  className?: string;
}) {
  const glyph = GLYPHS[name];
  return (
    <svg
      className={className ? `szf-glyph ${className}` : "szf-glyph"}
      width={size}
      height={size}
      viewBox={`0 0 ${glyph.box} ${glyph.box}`}
      aria-hidden="true"
      focusable="false"
    >
      <path
        d={glyph.d}
        fill={glyph.fill ? "currentColor" : "none"}
        fillRule={glyph.fill ? "evenodd" : undefined}
        stroke={glyph.fill ? "none" : "currentColor"}
        strokeWidth={glyph.width}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      {glyph.dots?.map(([cx, cy, r]) => (
        <circle key={`${cx}-${cy}`} cx={cx} cy={cy} r={r} fill="currentColor" />
      ))}
    </svg>
  );
}

/** One icon per route method, by kind when the method is null or unknown; nothing for none (PROTOCOL.md). */
export function routeGlyph(route: Route | null | undefined): GlyphName | null {
  if (!route) return null;
  if (route.kind === "offline") return "offline";
  if (route.kind === "connecting") return "internet";
  if (route.kind !== "local" && route.kind !== "online") return null;
  if (
    route.method &&
    ["lan", "p2p_wifi", "bluetooth", "internet", "relay"].includes(route.method)
  )
    return route.method as GlyphName;
  return route.kind === "local" ? "lan" : "internet";
}
export function RouteIcon({
  route,
  size = 12,
}: {
  route: Route | null | undefined;
  size?: number;
}) {
  const name = routeGlyph(route);
  if (!name) return null;
  return (
    <span
      className={`szf-route ${route?.kind === "connecting" || route?.kind === "offline" ? "offline" : ""}`}
      title={route?.label ?? undefined}
      role="img"
      aria-label={route?.label ?? undefined}
    >
      <Glyph name={name} size={size} />
    </span>
  );
}

const FOUND_GLYPHS: Record<string, GlyphName> = {
  lan: "lan",
  p2p_wifi: "p2p_wifi",
  bluetooth: "bluetooth",
};
/** How a person nearby was found: the route icon of each method that sees them, then the helper's words. */
export function FoundLine({ found }: { found: Found | null | undefined }) {
  if (!found?.label) return null;
  const glyphs = found.methods
    .map((method) => FOUND_GLYPHS[method])
    .filter((name): name is GlyphName => Boolean(name));
  return (
    <span className="szf-found" data-methods={found.methods.join(" ")}>
      {glyphs.map((name) => (
        <Glyph key={name} name={name} size={11} />
      ))}
      <span>{found.label}</span>
    </span>
  );
}
