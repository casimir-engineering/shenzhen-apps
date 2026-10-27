// The command palette (Cmd+K on a Mac, Ctrl+K elsewhere): type part of a command's name, or a word it is known by,
// and press Return to run it.
import { useEffect, useMemo, useRef, useState } from "react";

export type Command = {
  id: string;
  title: string;
  /** As the platform writes it (core/shortcuts.ts), e.g. "⌘J" or "Ctrl+J"; none on a phone without a keyboard. */
  shortcut?: string;
  /** Other words people look for it by, e.g. "chat" for Open Friends. */
  keywords?: string[];
  run(): void;
};

const words = (text: string) =>
  text
    .toLowerCase()
    .normalize("NFD")
    .replace(/\p{M}/gu, "")
    .split(/[^\p{L}\p{N}]+/u)
    .filter(Boolean);

/**
 * The commands that match `query`, best first: every word typed must begin a word of the title or of a keyword.
 * Commands matched by their title come before those matched only by a keyword; otherwise the order is the list's.
 */
export function matchCommands(commands: Command[], query: string) {
  const typed = words(query);
  if (!typed.length) return commands;
  const covers = (haystack: string[]) =>
    typed.every((word) =>
      haystack.some((candidate) => candidate.startsWith(word)),
    );
  const byTitle: Command[] = [];
  const byKeyword: Command[] = [];
  for (const command of commands) {
    const title = words(command.title);
    if (covers(title)) byTitle.push(command);
    else if (covers([...title, ...(command.keywords ?? []).flatMap(words)]))
      byKeyword.push(command);
  }
  return [...byTitle, ...byKeyword];
}

export function CommandPalette({
  open,
  commands,
  onClose,
}: {
  open: boolean;
  commands: Command[];
  onClose(): void;
}) {
  const dialog = useRef<HTMLDialogElement>(null);
  const input = useRef<HTMLInputElement>(null);
  const [query, setQuery] = useState("");
  const [selected, setSelected] = useState(0);
  const matches = useMemo(
    () => matchCommands(commands, query),
    [commands, query],
  );
  useEffect(() => {
    const element = dialog.current;
    if (!element) return;
    if (open && !element.open) {
      element.showModal();
      input.current?.focus();
    } else if (!open && element.open) element.close();
  }, [open]);
  useEffect(() => setSelected(0), [query]);
  // Each time it opens, it starts empty.
  const close = () => {
    setQuery("");
    setSelected(0);
    onClose();
  };
  const run = (command: Command | undefined) => {
    if (!command) return;
    close();
    // After the palette has closed and handed focus back, so the command can move it (Open Friends does).
    requestAnimationFrame(() => command.run());
  };
  return (
    <dialog
      ref={dialog}
      className="dialog command-palette"
      aria-label="Commands"
      onClose={close}
      onClick={(event) => event.target === dialog.current && close()}
    >
      <input
        ref={input}
        type="text"
        className="command-palette-input"
        placeholder="Search commands"
        aria-label="Search commands"
        role="combobox"
        aria-expanded="true"
        aria-controls="command-palette-list"
        aria-activedescendant={
          matches[selected] ? `command-${matches[selected].id}` : undefined
        }
        autoComplete="off"
        spellCheck={false}
        value={query}
        onChange={(event) => setQuery(event.target.value)}
        onKeyDown={(event) => {
          if (event.key === "ArrowDown" || event.key === "ArrowUp") {
            event.preventDefault();
            const step = event.key === "ArrowDown" ? 1 : -1;
            setSelected((index) =>
              matches.length
                ? (index + step + matches.length) % matches.length
                : 0,
            );
          } else if (event.key === "Enter") {
            event.preventDefault();
            run(matches[selected]);
          }
        }}
      />
      <ul
        id="command-palette-list"
        role="listbox"
        className="command-palette-list"
      >
        {matches.map((command, index) => (
          <li
            key={command.id}
            id={`command-${command.id}`}
            role="option"
            aria-selected={index === selected}
            className={index === selected ? "selected" : ""}
            onPointerMove={() => setSelected(index)}
            onClick={() => run(command)}
          >
            <span>{command.title}</span>
            {command.shortcut && <kbd>{command.shortcut}</kbd>}
          </li>
        ))}
      </ul>
      {!matches.length && (
        <p className="command-palette-empty">No matching commands</p>
      )}
    </dialog>
  );
}
