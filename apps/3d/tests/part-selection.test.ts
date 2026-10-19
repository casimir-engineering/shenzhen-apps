import { describe, expect, it } from "vitest";
import { Vector3 } from "three";
import { CameraGlide, glideProgress } from "../src/core/camera-glide";
import {
  nodeParts,
  nodePath,
  partRowPath,
  selectionForPart,
} from "../src/core/assembly-selection";
import type { TreeNode } from "../src/core/types";

const node = (
  id: string,
  partIds: string[],
  children: TreeNode[] = [],
): TreeNode => ({ id, name: id, partIds, children });
const roots = [
  node(
    "root",
    [],
    [
      node(
        "strip",
        ["plate"],
        [node("chip-1", ["chip-1:0", "chip-1:1"]), node("cap", ["cap:0"])],
      ),
      node("bracket", ["bracket:0"]),
    ],
  ),
];

describe("assembly rows for picked parts", () => {
  it("finds the row that owns a part and every ancestor to expand", () => {
    expect(partRowPath(roots, "chip-1:1")?.map((n) => n.id)).toEqual([
      "root",
      "strip",
      "chip-1",
    ]);
    expect(partRowPath(roots, "plate")?.map((n) => n.id)).toEqual([
      "root",
      "strip",
    ]);
    expect(partRowPath(roots, "missing")).toBeUndefined();
    expect(nodePath(roots, "cap")?.map((n) => n.id)).toEqual([
      "root",
      "strip",
      "cap",
    ]);
  });

  it("selects only the picked part, named by its own row", () => {
    expect(selectionForPart(roots, "chip-1:0")).toEqual({
      nodeId: "chip-1",
      ids: ["chip-1:0"],
    });
    expect(selectionForPart(roots, "missing")).toEqual({
      nodeId: undefined,
      ids: ["missing"],
    });
    expect(nodeParts(roots[0].children[0])).toEqual([
      "plate",
      "chip-1:0",
      "chip-1:1",
      "cap:0",
    ]);
  });
});

describe("centering glide", () => {
  const harness = () => {
    let time = 0;
    const queue: (() => void)[] = [];
    const total = new Vector3();
    const glide = new CameraGlide(
      (delta) => total.add(delta),
      () => time,
      (callback) => queue.push(callback),
      () => queue.splice(0),
    );
    const advance = (ms: number) => {
      time += ms;
      queue.splice(0).forEach((callback) => callback());
    };
    return { glide, total, advance };
  };

  it("pans exactly the requested offset and then stops", () => {
    const { glide, total, advance } = harness();
    glide.start(new Vector3(10, -4, 2), 200);
    advance(50);
    expect(total.x).toBeGreaterThan(0);
    expect(total.x).toBeLessThan(10);
    advance(500);
    expect(total.distanceTo(new Vector3(10, -4, 2))).toBeLessThan(1e-12);
    expect(glide.active).toBe(false);
  });

  it("moves at once without animation and stops when canceled", () => {
    const { glide, total, advance } = harness();
    glide.start(new Vector3(1, 2, 3), 0);
    expect(total.toArray()).toEqual([1, 2, 3]);
    glide.start(new Vector3(5, 0, 0), 200);
    advance(20);
    glide.cancel();
    const stopped = total.x;
    advance(500);
    expect(total.x).toBe(stopped);
  });

  it("eases out within bounds", () => {
    expect(glideProgress(-1)).toBe(0);
    expect(glideProgress(0.5)).toBeGreaterThan(0.5);
    expect(glideProgress(2)).toBe(1);
  });
});
