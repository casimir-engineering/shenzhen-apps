import type { TreeNode } from "./types";

/** A selection made from the assembly tree or by picking a part in the view. */
export interface PartSelection {
  /** The assembly row that represents the selection. */
  nodeId?: string;
  /** Every part the selection covers. */
  ids: string[];
}

export function nodeParts(node: TreeNode): string[] {
  return [...node.partIds, ...node.children.flatMap(nodeParts)];
}

/** Root-to-node path of the first depth-first match, deepest match preferred. */
function findPath(
  roots: TreeNode[],
  matches: (node: TreeNode) => boolean,
  deepest: boolean,
): TreeNode[] | undefined {
  const stack: TreeNode[] = [];
  let found: TreeNode[] | undefined;
  const walk = (node: TreeNode): boolean => {
    stack.push(node);
    if (!deepest && matches(node)) {
      found = [...stack];
      return true;
    }
    for (const child of node.children) if (walk(child)) return true;
    if (deepest && matches(node)) {
      found = [...stack];
      return true;
    }
    stack.pop();
    return false;
  };
  for (const root of roots) if (walk(root)) break;
  return found;
}

/** Path to a row by id. */
export function nodePath(roots: TreeNode[], nodeId: string) {
  return findPath(roots, (node) => node.id === nodeId, false);
}

/** Path to the row that owns a part directly, so picking a part names its own row. */
export function partRowPath(roots: TreeNode[], partId: string) {
  return findPath(roots, (node) => node.partIds.includes(partId), true);
}

/** The selection for a part picked in the view. */
export function selectionForPart(
  roots: TreeNode[],
  partId: string,
): PartSelection {
  return { nodeId: partRowPath(roots, partId)?.at(-1)?.id, ids: [partId] };
}
