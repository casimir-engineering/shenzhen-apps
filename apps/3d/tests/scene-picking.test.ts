import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  BoxGeometry,
  BufferGeometry,
  DoubleSide,
  Euler,
  Float32BufferAttribute,
  Group,
  InstancedMesh,
  Line,
  LineBasicMaterial,
  LineLoop,
  LineSegments,
  Matrix4,
  Mesh,
  MeshBasicMaterial,
  Quaternion,
  Raycaster,
  Vector3,
} from 'three';
import type { Intersection } from 'three';
import { acceleratedRaycast, MeshBVH } from 'three-mesh-bvh';
import { ScenePickingIndex } from '../src/core/scene-picking';

const nativeRaycast = Mesh.prototype.raycast;

function geometry() {
  const result = new BoxGeometry(1, 1, 1);
  result.boundsTree = new MeshBVH(result, { indirect: true });
  return result;
}

function batch(count: number, accelerated = true) {
  const object = new InstancedMesh(
    accelerated ? geometry() : new BoxGeometry(1, 1, 1),
    new MeshBasicMaterial({ side: DoubleSide }),
    count,
  );
  object.userData.partIds = Array.from({ length: count }, (_, i) => `part-${i}`);
  return object;
}

function expectSame(actual: Intersection[], expected: Intersection[]) {
  expect(actual.length).toBe(expected.length);
  for (let i = 0; i < actual.length; i++) {
    expect(actual[i].object).toBe(expected[i].object);
    expect(actual[i].instanceId).toBe(expected[i].instanceId);
    expect(actual[i].faceIndex).toBe(expected[i].faceIndex);
    expect(actual[i].index).toBe(expected[i].index);
    expect(actual[i].distance).toBeCloseTo(expected[i].distance, 8);
    expect(actual[i].point.distanceTo(expected[i].point)).toBeLessThan(1e-8);
    if (expected[i].uv) expect(actual[i].uv!.distanceTo(expected[i].uv!)).toBeLessThan(1e-8);
    if (expected[i].normal) expect(actual[i].normal!.distanceTo(expected[i].normal!)).toBeLessThan(1e-8);
  }
}

function ray(origin: Vector3, direction = new Vector3(0, 0, -1)) {
  return new Raycaster(origin, direction.clone().normalize());
}

function randomGenerator() {
  let state = 830219;
  return () => {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    return state / 0x100000000;
  };
}

describe('assembly picking broad phase', () => {
  beforeAll(() => { Mesh.prototype.raycast = acceleratedRaycast; });
  afterAll(() => { Mesh.prototype.raycast = nativeRaycast; });

  it('matches Three for random transformed instances, world scales, near/far, and both hit modes', () => {
    const random = randomGenerator();
    const objects = [batch(180), batch(90)];
    const parent = new Group();
    parent.scale.set(2, 0.8, 1.5);
    parent.rotation.set(0.1, -0.2, 0.15);
    parent.position.set(3, -2, 1);
    parent.add(...objects);
    const targets: Vector3[] = [];
    for (const object of objects) {
      object.rotation.set(0.3, 0.1, -0.2);
      object.scale.set(0.8, 1.4, 1.1);
      for (let i = 0; i < object.count; i++) {
        const position = new Vector3((random() - 0.5) * 25, (random() - 0.5) * 25, (random() - 0.5) * 12);
        const rotation = new Quaternion().setFromEuler(new Euler(random(), random(), random()));
        const scale = new Vector3(0.4 + random(), 0.4 + random(), 0.4 + random());
        object.setMatrixAt(i, new Matrix4().compose(position, rotation, scale));
        if (i % 15 === 0) targets.push(position.clone());
      }
    }
    parent.updateMatrixWorld(true);
    const index = new ScenePickingIndex();
    index.setObjects(objects);
    for (const firstHitOnly of [true, false]) {
      for (let i = 0; i < 60; i++) {
        const object = objects[i % 2];
        const target = targets[i % targets.length].clone().applyMatrix4(object.matrixWorld);
        const origin = new Vector3((random() - 0.5) * 50, (random() - 0.5) * 40, 35);
        const caster = ray(origin, target.sub(origin));
        caster.firstHitOnly = firstHitOnly;
        caster.near = i % 3 === 0 ? 30 : 0;
        caster.far = i % 4 === 0 ? 40 : Infinity;
        const actual = index.intersect(caster);
        const expected = caster.intersectObjects(objects, false);
        expectSame(actual, expected);
      }
    }
  });

  it('uses the installed native Mesh raycast when no geometry BVH exists', () => {
    Mesh.prototype.raycast = nativeRaycast;
    try {
      const object = batch(3, false);
      object.setMatrixAt(0, new Matrix4().makeTranslation(0, 0, -3));
      object.setMatrixAt(1, new Matrix4().makeTranslation(8, 0, 0));
      object.setMatrixAt(2, new Matrix4().makeTranslation(0, 0, -6));
      const index = new ScenePickingIndex();
      index.setObjects([object]);
      const caster = ray(new Vector3(0.1, 0.2, 10));
      expectSame(index.intersect(caster), caster.intersectObject(object, false));
    } finally {
      Mesh.prototype.raycast = acceleratedRaycast;
    }
  });

  it('rebuilds after hiding/exploding occurrences and returns original part IDs', () => {
    const object = batch(3);
    object.setMatrixAt(0, new Matrix4().makeTranslation(0, 0, 0));
    object.setMatrixAt(1, new Matrix4().makeTranslation(0, 0, -3));
    object.setMatrixAt(2, new Matrix4().makeTranslation(0, 0, -6));
    const index = new ScenePickingIndex();
    const caster = ray(new Vector3(0.1, 0.2, 10));
    caster.firstHitOnly = true;
    index.setObjects([object]);
    expect(index.intersect(caster).map(hit => hit.instanceId)).toEqual([0, 1, 2]);

    object.setMatrixAt(0, new Matrix4().makeScale(0, 0, 0));
    object.setMatrixAt(1, new Matrix4().makeTranslation(5, 0, -3));
    object.boundingSphere = null;
    index.setObjects([object]);
    const hits = index.intersect(caster);
    expectSame(hits, caster.intersectObject(object, false));
    expect(index.stats.occurrenceCount).toBe(2);
    expect(hits.map(hit => object.userData.partIds[hit.instanceId!])).toEqual(['part-2']);

    object.position.set(10, 0, 0);
    index.setObjects([object]);
    expect(index.intersect(caster)).toEqual([]);
    expect(index.intersect(ray(new Vector3(10.1, 0.2, 10)))[0].instanceId).toBe(2);
  });

  it('keeps all per-occurrence hits for section clipping and does not globally prune firstHitOnly', () => {
    const object = batch(2);
    object.setMatrixAt(1, new Matrix4().makeTranslation(0, 0, -4));
    const index = new ScenePickingIndex();
    index.setObjects([object]);
    const caster = ray(new Vector3(0.1, 0.2, 10));
    caster.firstHitOnly = true;
    expect(index.intersect(caster).map(hit => hit.instanceId)).toEqual([0, 1]);
    caster.firstHitOnly = false;
    const allHits = index.intersect(caster);
    expect(allHits).toHaveLength(4);
    for (const sectionPosition of [0, -4]) {
      const clipped = allHits.filter(hit => hit.point.z <= sectionPosition);
      const expected = caster.intersectObject(object, false).filter(hit => hit.point.z <= sectionPosition);
      expectSame(clipped, expected);
      expect(clipped[0].point.z).toBeCloseTo(sectionPosition - 0.5);
    }
  });

  it('expands line bounds at query time for threshold, segments/loops, and nonuniform ancestor scales', () => {
    const lineGeometry = new BufferGeometry().setFromPoints([new Vector3(-1, 0, 0), new Vector3(1, 0, 0), new Vector3(1, 0, -2)]);
    const lines = [
      new Line(lineGeometry, new LineBasicMaterial()),
      new LineSegments(lineGeometry, new LineBasicMaterial()),
      new LineLoop(lineGeometry, new LineBasicMaterial()),
    ];
    lines[1].position.x = 5;
    lines[2].position.x = -5;
    const parent = new Group();
    parent.scale.set(0.5, 10, 1.5);
    parent.add(...lines);
    const index = new ScenePickingIndex();
    index.setObjects(lines);
    for (const threshold of [0.01, 0.1, 0.5]) {
      for (const x of [0.1, 2.6, -2.4]) {
        // The world-space offset exceeds threshold: Three's local-space
        // distance rule still accepts it under this nonuniform parent scale.
        const caster = ray(new Vector3(x, threshold * 5, 10));
        caster.params.Line = { threshold };
        const expected = caster.intersectObjects(lines, false);
        expect(expected.length).toBeGreaterThan(0);
        expectSame(index.intersect(caster), expected);
      }
    }
    const caster = ray(new Vector3(0.1, 0.2, 10));
    caster.params.Line = { threshold: 0 };
    expectSame(index.intersect(caster), caster.intersectObjects(lines, false));
  });

  it('sorts mixed objects and honors layers, visibility, and empty rebuilds', () => {
    const object = batch(1);
    const line = new Line(new BufferGeometry().setFromPoints([new Vector3(-1, 0.2, 2), new Vector3(1, 0.2, 2)]), new LineBasicMaterial());
    const index = new ScenePickingIndex();
    index.setObjects([object, line]);
    const caster = ray(new Vector3(0.1, 0.2, 10));
    expectSame(index.intersect(caster), caster.intersectObjects([object, line], false));
    expect(index.intersect(caster)[0].object).toBe(line);
    line.layers.set(1);
    expectSame(index.intersect(caster), caster.intersectObjects([object, line], false));
    object.visible = false;
    expect(index.intersect(caster)).toEqual([]);
    index.setObjects([object, line]);
    expect(index.stats.occurrenceCount).toBe(1);
    index.setObjects([]);
    expect(index.intersect(caster)).toEqual([]);
    expect(index.stats.nodeCount).toBe(0);
  });

  it('leaves geometry attributes, index, and triangle mapping untouched', () => {
    const raw = new BufferGeometry().setAttribute('position', new Float32BufferAttribute([-1, -1, 0, 1, -1, 0, 0, 1, 0], 3));
    raw.setIndex([0, 1, 2]);
    const object = new InstancedMesh(raw, new MeshBasicMaterial({ side: DoubleSide }), 1);
    const position = raw.getAttribute('position');
    const indices = raw.index;
    const indexValues = Array.from(indices!.array);
    const index = new ScenePickingIndex();
    index.setObjects([object]);
    expect(raw.boundingBox).toBeNull();
    expect(raw.boundingSphere).toBeNull();
    expect(index.intersect(ray(new Vector3(0.1, 0.2, 10)))[0].faceIndex).toBe(0);
    expect(raw.getAttribute('position')).toBe(position);
    expect(raw.index).toBe(indices);
    expect(Array.from(raw.index!.array)).toEqual(indexValues);
  });

  it('limits a 100,000-instance query to spatial candidates', () => {
    const object = batch(100_000);
    const matrix = new Matrix4();
    for (let i = 0; i < object.count; i++) {
      object.setMatrixAt(i, matrix.makeTranslation((i % 1000) * 3, Math.floor(i / 1000) * 3, 0));
    }
    const index = new ScenePickingIndex();
    const buildStarted = performance.now();
    index.setObjects([object]);
    const buildMs = performance.now() - buildStarted;
    const caster = ray(new Vector3(12.1, 27.2, 10));
    caster.firstHitOnly = true;
    const queryStarted = performance.now();
    const hits = index.intersect(caster);
    const queryMs = performance.now() - queryStarted;
    expect(hits.map(hit => hit.instanceId)).toEqual([9004]);
    expect(index.stats.occurrenceCount).toBe(100_000);
    expect(index.stats.candidatesTested).toBe(1);
    expect(index.stats.nodesVisited).toBeLessThan(100);
    expectSame(hits, caster.intersectObject(object, false));
    console.log('100k assembly picking:', { buildMs: Math.round(buildMs), queryMs: Math.round(queryMs * 1000) / 1000, ...index.stats });
  });
});
