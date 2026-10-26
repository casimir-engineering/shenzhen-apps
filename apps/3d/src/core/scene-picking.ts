import {
  Box3,
  BufferGeometry,
  InstancedMesh,
  Line,
  Matrix4,
  Mesh,
  Object3D,
  Ray,
  Raycaster,
  Vector3,
} from 'three';
import type { Intersection } from 'three';
import type { VisibleDepth } from './view-clipping';

type Pickable = InstancedMesh | Line;

interface Occurrence {
  object: Pickable;
  instanceId?: number;
  bounds: Box3;
  order: number;
  linePadding: number;
}

interface Node {
  bounds: Box3;
  linePadding: number;
  start: number;
  end: number;
  left: number;
  right: number;
}

const LEAF_SIZE = 8;
const AXES = ['x', 'y', 'z'] as const;

/**
 * Broad phase for assembly picking, above the existing per-geometry raycaster.
 * Rebuild after changing instances, geometry, visibility, or world transforms.
 * Does not build/modify geometry BVHs or change triangle/instance numbering.
 */
export class ScenePickingIndex {
  readonly stats = {
    occurrenceCount: 0,
    nodeCount: 0,
    nodesVisited: 0,
    candidatesTested: 0,
  };

  private occurrences: Occurrence[] = [];
  private nodes: Node[] = [];
  private proxy = new Mesh();
  private emptyGeometry = this.proxy.geometry;
  private emptyMaterial = this.proxy.material;
  private instanceMatrix = new Matrix4();
  private worldMatrix = new Matrix4();
  private stack: number[] = [];
  private candidates: Occurrence[] = [];

  setObjects(objects: readonly Pickable[]): void {
    this.occurrences = [];
    this.nodes = [];
    this.candidates.length = 0;
    this.proxy.geometry = this.emptyGeometry;
    this.proxy.material = this.emptyMaterial;
    const geometryBounds = new Map<BufferGeometry, Box3>();

    for (const object of objects) {
      object.updateWorldMatrix(true, false);
      if (!isVisible(object)) continue;
      let localBounds = geometryBounds.get(object.geometry);
      if (!localBounds) {
        const position = object.geometry.getAttribute('position');
        if (!position) continue;
        // Computing our own bounds avoids mutating a shared geometry.
        localBounds = object.geometry.boundingBox?.clone() ?? new Box3();
        if (!object.geometry.boundingBox) {
          const point = new Vector3();
          for (let i = 0; i < position.count; i++) {
            point.set(position.getX(i), position.getY(i), position.getZ(i));
            localBounds.expandByPoint(point);
          }
        }
        geometryBounds.set(object.geometry, localBounds);
      }
      if (!finiteBounds(localBounds)) continue;

      if (object instanceof InstancedMesh) {
        for (let instanceId = 0; instanceId < object.count; instanceId++) {
          object.getMatrixAt(instanceId, this.instanceMatrix);
          this.worldMatrix.multiplyMatrices(object.matrixWorld, this.instanceMatrix);
          // The viewer hides occurrences by assigning a zero-scale matrix.
          if (this.worldMatrix.determinant() === 0) continue;
          this.addOccurrence(object, localBounds, this.worldMatrix, 0, instanceId);
        }
      } else {
        // Three tests line distance in local coordinates using the object's
        // average local scale. Account also for scaled/sheared ancestors so
        // broad-phase bounds conservatively contain every native line hit.
        const e = object.matrixWorld.elements;
        const averageScale = Math.abs((object.scale.x + object.scale.y + object.scale.z) / 3);
        const maxRowLength = Math.max(
          Math.hypot(e[0], e[4], e[8]),
          Math.hypot(e[1], e[5], e[9]),
          Math.hypot(e[2], e[6], e[10]),
        );
        const padding = averageScale === 0 ? Infinity : maxRowLength / averageScale;
        this.addOccurrence(object, localBounds, object.matrixWorld, padding);
      }
    }

    if (this.occurrences.length) this.buildNode(0, this.occurrences.length);
    this.stats.occurrenceCount = this.occurrences.length;
    this.stats.nodeCount = this.nodes.length;
    this.stats.nodesVisited = 0;
    this.stats.candidatesTested = 0;
  }

  intersect(raycaster: Raycaster): Intersection[] {
    const hits: Intersection[] = [];
    this.stats.nodesVisited = 0;
    this.stats.candidatesTested = 0;
    this.candidates.length = 0;
    this.stack.length = 0;
    if (!this.nodes.length) return hits;
    const threshold = Math.abs(raycaster.params.Line?.threshold ?? 1);
    this.stack.push(0);

    while (this.stack.length) {
      const node = this.nodes[this.stack.pop()!];
      this.stats.nodesVisited++;
      if (!intersectsBounds(raycaster.ray, node.bounds, paddingFor(node.linePadding, threshold))) continue;
      if (node.left !== -1) {
        this.stack.push(node.left, node.right);
        continue;
      }
      for (let i = node.start; i < node.end; i++) {
        const occurrence = this.occurrences[i];
        if (
          raycaster.layers.test(occurrence.object.layers) &&
          isVisible(occurrence.object) &&
          intersectsBounds(raycaster.ray, occurrence.bounds, paddingFor(occurrence.linePadding, threshold))
        ) this.candidates.push(occurrence);
      }
    }

    // Preserve Three's stable ordering for hits with identical distances.
    this.candidates.sort((a, b) => a.order - b.order);
    for (const { object, instanceId } of this.candidates) {
      this.stats.candidatesTested++;
      if (object instanceof InstancedMesh) {
        this.proxy.geometry = object.geometry;
        this.proxy.material = object.material;
        object.getMatrixAt(instanceId!, this.instanceMatrix);
        this.proxy.matrixWorld.multiplyMatrices(object.matrixWorld, this.instanceMatrix);
        const start = hits.length;
        // Uses the installed Mesh.raycast (including acceleratedRaycast), and
        // leaves firstHitOnly untouched: it applies per occurrence, not globally.
        this.proxy.raycast(raycaster, hits);
        for (let i = start; i < hits.length; i++) {
          hits[i].object = object;
          hits[i].instanceId = instanceId;
        }
      } else {
        object.raycast(raycaster, hits);
      }
    }
    return hits.sort((a, b) => a.distance - b.distance);
  }

  /**
   * Widen `depth` by the occurrences in view (their world bounds clipped to the
   * view's sides). `nearestOnly` finds just the nearest depth, skipping
   * everything that cannot be nearer: a perspective view needs no more.
   */
  addVisibleDepth(depth: VisibleDepth, nearestOnly: boolean): void {
    if (!this.nodes.length) return;
    const stack = this.stack;
    stack.length = 0;
    stack.push(0);
    while (stack.length) {
      const node = this.nodes[stack.pop()!];
      if (nearestOnly && depth.lowerBound(node.bounds) >= depth.min) continue;
      const where = depth.classify(node.bounds);
      if (where < 0) continue;
      if (where > 0 && !nearestOnly) {
        depth.addBounds(node.bounds);
        continue;
      }
      if (node.left === -1) {
        for (let i = node.start; i < node.end; i++) {
          const occurrence = this.occurrences[i];
          if (nearestOnly && depth.lowerBound(occurrence.bounds) >= depth.min) continue;
          if (isVisible(occurrence.object)) depth.addBox(occurrence.bounds);
        }
        continue;
      }
      // Nearer child last, so it is searched first and prunes the other.
      const left = this.nodes[node.left], right = this.nodes[node.right];
      if (depth.lowerBound(left.bounds) <= depth.lowerBound(right.bounds)) stack.push(node.right, node.left);
      else stack.push(node.left, node.right);
    }
    stack.length = 0;
  }

  private addOccurrence(object: Pickable, bounds: Box3, matrix: Matrix4, linePadding: number, instanceId?: number): void {
    const worldBounds = bounds.clone().applyMatrix4(matrix);
    if (!finiteBounds(worldBounds)) return;
    this.occurrences.push({ object, bounds: worldBounds, instanceId, linePadding, order: this.occurrences.length });
  }

  private buildNode(start: number, end: number): number {
    const bounds = new Box3();
    let linePadding = 0;
    for (let i = start; i < end; i++) {
      const occurrence = this.occurrences[i];
      bounds.union(occurrence.bounds);
      linePadding = Math.max(linePadding, occurrence.linePadding);
    }
    const node: Node = { bounds, linePadding, start, end, left: -1, right: -1 };
    const index = this.nodes.push(node) - 1;
    if (end - start > LEAF_SIZE) {
      const sizeX = bounds.max.x - bounds.min.x;
      const sizeY = bounds.max.y - bounds.min.y;
      const sizeZ = bounds.max.z - bounds.min.z;
      const axis = sizeX >= sizeY && sizeX >= sizeZ ? 'x' : sizeY >= sizeZ ? 'y' : 'z';
      const middle = (start + end) >>> 1;
      partitionMedian(this.occurrences, start, end - 1, middle, axis);
      node.left = this.buildNode(start, middle);
      node.right = this.buildNode(middle, end);
    }
    return index;
  }
}

function isVisible(object: Object3D): boolean {
  for (let current: Object3D | null = object; current; current = current.parent) {
    if (!current.visible) return false;
  }
  return true;
}

function finiteBounds(box: Box3): boolean {
  return !box.isEmpty() &&
    Number.isFinite(box.min.x) && Number.isFinite(box.min.y) && Number.isFinite(box.min.z) &&
    Number.isFinite(box.max.x) && Number.isFinite(box.max.y) && Number.isFinite(box.max.z);
}

function paddingFor(factor: number, threshold: number): number {
  return threshold === 0 ? 0 : factor * threshold;
}

function intersectsBounds(ray: Ray, bounds: Box3, padding: number): boolean {
  // Delegate near/far to the installed raycast. Its local-distance conversion
  // can differ under inherited nonuniform scales and shear.
  let minimum = 0;
  let maximum = Infinity;
  for (const axis of AXES) {
    const origin = ray.origin[axis];
    const direction = ray.direction[axis];
    const low = bounds.min[axis] - padding;
    const high = bounds.max[axis] + padding;
    if (direction === 0) {
      if (origin < low || origin > high) return false;
    } else {
      let entry = (low - origin) / direction;
      let exit = (high - origin) / direction;
      if (entry > exit) [entry, exit] = [exit, entry];
      minimum = Math.max(minimum, entry);
      maximum = Math.min(maximum, exit);
      if (minimum > maximum) return false;
    }
  }
  return minimum <= maximum;
}

/** In-place quickselect gives balanced nodes without sorting every subtree. */
function partitionMedian(entries: Occurrence[], left: number, right: number, middle: number, axis: 'x' | 'y' | 'z'): void {
  const center = (entry: Occurrence) => entry.bounds.min[axis] + entry.bounds.max[axis];
  while (left < right) {
    const pivot = center(entries[(left + right) >>> 1]);
    let i = left;
    let j = right;
    while (i <= j) {
      while (center(entries[i]) < pivot) i++;
      while (center(entries[j]) > pivot) j--;
      if (i <= j) {
        const temporary = entries[i];
        entries[i] = entries[j];
        entries[j] = temporary;
        i++;
        j--;
      }
    }
    if (middle <= j) right = j;
    else if (middle >= i) left = i;
    else return;
  }
}
