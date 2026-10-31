// A moving transfer's progress by route (PROTOCOL.md § Fast transfers, Progress by route): its route icons, the bar
// split by what each route carried, and the lines under it. The glyphs and colours are the approved mockup's, as the
// AppKit (mac/SZFriendsTransferProgress.m) and GTK (gtk/szfriends_gtk_transfer_progress.c) views draw them.
import type { TransferProgress as Progress } from "./protocol";

// Each a 16-unit SVG drawn in currentColor: white on the route's colour while in use, the muted colour once not.
const ICON: Record<string, string> = {
  lan: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"><path d="M1.8 6.2a9 9 0 0 1 12.4 0"/><path d="M4.1 8.7a5.7 5.7 0 0 1 7.8 0"/><path d="M6.4 11.1a2.4 2.4 0 0 1 3.2 0"/><circle cx="8" cy="13.2" r=".9" fill="currentColor" stroke="none"/></svg>',
  p2p_wifi:
    '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><rect x="1.4" y="8.2" width="3.6" height="6.2" rx=".9"/><rect x="11" y="8.2" width="3.6" height="6.2" rx=".9"/><path d="M4.6 5.2a4.8 4.8 0 0 1 6.8 0"/><path d="M6.2 7a2.5 2.5 0 0 1 3.6 0"/><circle cx="8" cy="8.6" r=".75" fill="currentColor" stroke="none"/></svg>',
  internet:
    '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.2"><circle cx="8" cy="5.4" r="4.4"/><path d="M3.6 5.4h8.8M8 1c1.6 1.6 1.6 7.2 0 8.8M8 1c-1.6 1.6-1.6 7.2 0 8.8"/><text x="8" y="15.6" text-anchor="middle" font-family="-apple-system, Helvetica, Arial, sans-serif" font-size="5.6" font-weight="800" fill="currentColor" stroke="none" letter-spacing="0.2">P2P</text></svg>',
  bluetooth:
    '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M4.6 5.2 11.2 10.8 8 13.6V2.4l3.2 2.8-6.6 5.6"/></svg>',
  relay:
    '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"><path d="M4.6 12.4h7a2.8 2.8 0 0 0 .4-5.6 4 4 0 0 0-7.7.9 2.4 2.4 0 0 0 .3 4.7Z"/></svg>',
};

/** The route's colour, the same in light and dark; never grey or red, which say "not working". */
export const ROUTE_COLOR: Record<string, string> = {
  lan: "#22a35a",
  p2p_wifi: "#0ea5b0",
  internet: "#8b5cf6",
  bluetooth: "#f59e0b",
  relay: "#3983f7",
};

export function RouteIcons({ progress }: { progress: Progress }) {
  const routes = progress.routes ?? [];
  if (!routes.length) return null;
  return (
    <span className="szf-routes">
      {routes.map((route) => (
        <span
          key={route.method}
          className={`szf-route-icon${route.active ? "" : " off"}`}
          style={{
            background: route.active ? ROUTE_COLOR[route.method] : undefined,
          }}
          title={route.label}
          role="img"
          aria-label={route.label}
          dangerouslySetInnerHTML={{ __html: ICON[route.method] ?? ICON.relay }}
        />
      ))}
    </span>
  );
}

export function SplitBar({ progress }: { progress: Progress }) {
  const segments = progress.segments ?? [];
  const percent = Math.round(Math.min(1, Math.max(0, progress.fraction)) * 100);
  return (
    <div
      className="szf-split-bar"
      role="progressbar"
      aria-label={progress.accessibility_label}
      aria-valuenow={progress.determinate ? percent : undefined}
      aria-valuemin={0}
      aria-valuemax={100}
    >
      {progress.finishing ? (
        <span className="szf-finishing" style={{ width: "100%" }} />
      ) : segments.length ? (
        segments.map((segment) => (
          <span
            key={segment.method}
            style={{
              width: `${Math.max(0, Math.min(1, segment.fraction)) * 100}%`,
              background: ROUTE_COLOR[segment.method] ?? ROUTE_COLOR.relay,
            }}
          />
        ))
      ) : (
        <span style={{ width: `${percent}%`, background: ROUTE_COLOR.relay }} />
      )}
    </div>
  );
}

export function ProgressLines({ progress }: { progress: Progress }) {
  return (
    <>
      <div className="szf-transfer-lines">
        <span>{progress.amount_label}</span>
        {progress.time_left_label && <span>{progress.time_left_label}</span>}
      </div>
      {progress.detail_label && (
        <div className="szf-transfer-lines">
          <span>{progress.detail_label}</span>
        </div>
      )}
    </>
  );
}
