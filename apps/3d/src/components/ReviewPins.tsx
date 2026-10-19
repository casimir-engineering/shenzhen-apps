import { useEffect, useRef } from "react";
import type { Viewer } from "../core/viewer";
import type { ReviewNote } from "../core/project-file";
export function ReviewPins({
  viewer,
  notes,
  selected,
  onSelect,
}: {
  viewer?: Viewer;
  notes: ReviewNote[];
  selected?: string;
  onSelect: (note: ReviewNote) => void;
}) {
  const host = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!viewer || !host.current) return;
    const previous = viewer.onViewChanged;
    const byId = new Map(notes.map((note) => [note.id, note]));
    const update = () => {
      previous?.();
      for (const button of host.current?.querySelectorAll<HTMLButtonElement>(
        "[data-note-id]",
      ) ?? []) {
        const note = byId.get(button.dataset.noteId ?? "");
        if (!note) continue;
        const point = viewer.projectPick(note.anchor);
        button.hidden = !point.visible;
        button.style.transform = `translate(${point.x}px, ${point.y}px) translate(-50%, -50%)`;
      }
    };
    viewer.onViewChanged = update;
    update();
    return () => {
      if (viewer.onViewChanged === update) viewer.onViewChanged = previous;
    };
  }, [viewer, notes]);
  return (
    <div ref={host} className="review-pins" aria-label="Model annotations">
      {notes.map(
        (note, index) =>
          !note.resolved && (
            <button
              key={note.id}
              data-note-id={note.id}
              className={`review-pin ${selected === note.id ? "selected" : ""}`}
              aria-label={`Note ${index + 1}: ${note.text.slice(0, 100)}`}
              title={note.text}
              onClick={(event) => {
                event.stopPropagation();
                onSelect(note);
              }}
            >
              {index + 1}
            </button>
          ),
      )}
    </div>
  );
}
