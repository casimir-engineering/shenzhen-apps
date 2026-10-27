import { memo, useEffect, useMemo, useState, useRef } from "react";
import {
  ChevronDown,
  ChevronRight,
  Box,
  Layers,
  Eye,
  EyeOff,
  Search,
  Focus,
} from "lucide-react";
import type { ModelDocument, TreeNode } from "../core/types";
import {
  nodeParts,
  nodePath,
  type PartSelection,
} from "../core/assembly-selection";
import { shortcutLabel, useKeyHints } from "../core/shortcuts";
export { nodeParts };
interface Props {
  doc: ModelDocument;
  hidden: Set<string>;
  selected?: string;
  /** Each new selection's row is expanded to and scrolled into view. */
  selection?: PartSelection;
  onToggle: (ids: string[]) => void;
  /** `deselect` asks to clear the selection (Cmd/Ctrl-click on the selected row). */
  onSelect: (nodeId: string, ids: string[], deselect: boolean) => void;
  onIsolate: (ids: string[]) => void;
}
const ROW = 32;
export const AssemblyTree = memo(function AssemblyTree({
  doc,
  hidden,
  selected,
  selection,
  onToggle,
  onSelect,
  onIsolate,
}: Props) {
  const [expanded, setExpanded] = useState<Set<string>>(
    () => new Set(doc.roots.map((n) => n.id)),
  );
  const [search, setSearch] = useState("");
  const keyHints = useKeyHints();
  const [scroll, setScroll] = useState(0);
  const container = useRef<HTMLDivElement>(null);
  const rows = useMemo(() => {
    const out: { node: TreeNode; depth: number }[] = [];
    const walk = (node: TreeNode, depth: number) => {
      const match =
        !search || node.name.toLowerCase().includes(search.toLowerCase());
      if (search) {
        if (match) out.push({ node, depth: 0 });
        node.children.forEach((n) => walk(n, 0));
      } else {
        out.push({ node, depth });
        if (expanded.has(node.id))
          node.children.forEach((n) => walk(n, depth + 1));
      }
    };
    doc.roots.forEach((n) => walk(n, 0));
    return out;
  }, [doc, search, expanded]);
  const selectedNode = selection?.nodeId;
  const reveal = useRef(selectedNode);
  useEffect(() => {
    reveal.current = selectedNode;
    const ancestors = selectedNode
      ? (nodePath(doc.roots, selectedNode) ?? []).slice(0, -1).map((n) => n.id)
      : [];
    if (ancestors.length)
      setExpanded((old) =>
        ancestors.every((id) => old.has(id))
          ? old
          : new Set([...old, ...ancestors]),
      );
  }, [doc, selection]);
  useEffect(() => {
    const element = container.current;
    const index = reveal.current
      ? rows.findIndex(({ node }) => node.id === reveal.current)
      : -1;
    if (!element || index < 0) return;
    reveal.current = undefined;
    const top = index * ROW;
    if (
      top < element.scrollTop ||
      top + ROW > element.scrollTop + element.clientHeight
    ) {
      element.scrollTop = Math.max(0, top - (element.clientHeight - ROW) / 2);
      setScroll(element.scrollTop);
    }
  }, [rows, selection]);
  const start = Math.max(0, Math.floor(scroll / ROW) - 5),
    visible = rows.slice(start, start + 45);
  return (
    <>
      <div className="tree-search">
        <Search size={14} />
        <input
          aria-label="Search assembly"
          placeholder="Find a part…"
          value={search}
          onChange={(e) => {
            setSearch(e.target.value);
            setScroll(0);
            if (container.current) container.current.scrollTop = 0;
          }}
        />
        {keyHints && <kbd>{shortcutLabel("F")}</kbd>}
      </div>
      <div
        className="tree-scroll"
        ref={container}
        onScroll={(e) => setScroll(e.currentTarget.scrollTop)}
        role="tree"
        aria-label="Assembly structure"
      >
        <div style={{ height: rows.length * ROW, position: "relative" }}>
          {visible.map(({ node, depth }, i) => {
            const ids = nodeParts(node);
            const allHidden =
              ids.length > 0 && ids.every((id) => hidden.has(id));
            const active = selectedNode
              ? node.id === selectedNode
              : !!selected && ids.includes(selected);
            return (
              <div
                className={`tree-row ${active ? "selected" : ""} ${allHidden ? "muted" : ""}`}
                role="treeitem"
                aria-selected={active}
                aria-level={depth + 1}
                aria-expanded={
                  node.children.length ? expanded.has(node.id) : undefined
                }
                key={node.id}
                style={{
                  position: "absolute",
                  top: (start + i) * ROW,
                  left: 0,
                  right: 0,
                  paddingLeft: 8 + depth * 12,
                }}
              >
                <button
                  className="tree-expand"
                  aria-label={
                    expanded.has(node.id)
                      ? "Collapse " + node.name
                      : "Expand " + node.name
                  }
                  disabled={!node.children.length}
                  onClick={() =>
                    setExpanded((old) => {
                      const next = new Set(old);
                      next.has(node.id)
                        ? next.delete(node.id)
                        : next.add(node.id);
                      return next;
                    })
                  }
                >
                  {node.children.length ? (
                    expanded.has(node.id) ? (
                      <ChevronDown size={12} />
                    ) : (
                      <ChevronRight size={12} />
                    )
                  ) : (
                    <span />
                  )}
                </button>
                <button
                  className="tree-name"
                  title={node.name}
                  onClick={(event) =>
                    ids[0] &&
                    onSelect(
                      node.id,
                      ids,
                      active && (event.metaKey || event.ctrlKey),
                    )
                  }
                >
                  {node.children.length ? (
                    <Layers size={13} />
                  ) : (
                    <Box size={13} />
                  )}
                  <span>{node.name}</span>
                </button>
                <button
                  className="tree-action"
                  title="Isolate"
                  aria-label={"Isolate " + node.name}
                  onClick={() => onIsolate(ids)}
                >
                  <Focus size={13} />
                </button>
                <button
                  className="tree-action"
                  title={allHidden ? "Show" : "Hide"}
                  aria-label={(allHidden ? "Show " : "Hide ") + node.name}
                  onClick={() => onToggle(ids)}
                >
                  {allHidden ? <EyeOff size={13} /> : <Eye size={13} />}
                </button>
              </div>
            );
          })}
        </div>
      </div>
      <div className="panel-foot">
        {doc.parts.length.toLocaleString()} instances <span>·</span>{" "}
        {doc.geometries.size.toLocaleString()} geometries
      </div>
    </>
  );
});
