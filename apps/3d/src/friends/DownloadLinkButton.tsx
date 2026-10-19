// The header's Copy Download Link: a button whose menu offers how long the link works (download-link.ts). The
// header shows it only while a model is open and Friends offers links.
import { useEffect, useRef, useState } from "react";
import { COPY_DOWNLOAD_LINK, EXPIRY_CHOICES } from "./download-link";

export function DownloadLinkButton({
  busy,
  onChoose,
}: {
  busy: boolean;
  onChoose(days: number): void;
}) {
  const [open, setOpen] = useState(false);
  const root = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const down = (event: PointerEvent) => {
      if (root.current && !root.current.contains(event.target as Node))
        setOpen(false);
    };
    const key = (event: KeyboardEvent) => {
      if (event.key === "Escape") setOpen(false);
    };
    window.addEventListener("pointerdown", down, true);
    window.addEventListener("keydown", key);
    return () => {
      window.removeEventListener("pointerdown", down, true);
      window.removeEventListener("keydown", key);
    };
  }, [open]);
  return (
    <div className="friends-anchor" ref={root}>
      <button
        type="button"
        className={`icon-button ${open ? "active" : ""}`}
        title={COPY_DOWNLOAD_LINK}
        aria-label={COPY_DOWNLOAD_LINK}
        aria-haspopup="menu"
        aria-expanded={open}
        disabled={busy}
        data-szfriends="copy-download-link"
        onClick={() => setOpen((old) => !old)}
      >
        {/* lucide's "link", drawn here so this chunk shares no icon code with the app's first chunk. */}
        <svg
          width="18"
          height="18"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="2"
          strokeLinecap="round"
          strokeLinejoin="round"
          aria-hidden="true"
        >
          <path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71" />
          <path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71" />
        </svg>
      </button>
      {open && (
        <div
          className="friends-menu"
          role="menu"
          aria-label={COPY_DOWNLOAD_LINK}
        >
          <span className="friends-menu-title" aria-hidden="true">
            {COPY_DOWNLOAD_LINK}
          </span>
          {EXPIRY_CHOICES.map(({ days, label }) => (
            <button
              key={days}
              type="button"
              role="menuitem"
              data-days={days}
              onClick={() => {
                setOpen(false);
                onChoose(days);
              }}
            >
              {label}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
