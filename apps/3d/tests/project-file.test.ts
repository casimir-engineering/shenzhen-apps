import { describe, expect, it } from 'vitest';
import { BufferGeometry, Float32BufferAttribute, Matrix4, MeshBasicMaterial, Vector3 } from 'three';
import { readFileSync } from 'node:fs';
import { zipSync, unzipSync, strToU8, strFromU8 } from 'fflate';
import { exportProject, readProject, restoreProjectState, PROJECT_LIMITS } from '../src/core/project-file';
import type { ProjectInput, ReviewNote } from '../src/core/project-file';
import type { ModelDocument, Pick, GeometryData } from '../src/core/types';
import { fromCad } from '../src/core/importers';

function document(suffix = 'old', cad = false): ModelDocument {
  const geometry = new BufferGeometry();
  geometry.setAttribute('position', new Float32BufferAttribute([0, 0, 0, 2, 0, 0, 0, 2, 0], 3));
  geometry.setIndex([0, 1, 2]);
  const data: GeometryData = { id: `geometry-${suffix}`, geometry, materials: [new MeshBasicMaterial()] };
  if (cad) {
    const shift = suffix === 'old' ? 0 : 100;
    data.exactHandle = suffix === 'old' ? 7 : 999;
    data.topology = {
      id: data.id, name: 'triangle', color: null,
      positions: new Float32Array(geometry.getAttribute('position').array), normals: new Float32Array(9), indices: new Uint32Array([0, 1, 2]),
      faces: [{ id: 10 + shift, name: 'face', firstIndex: 0, indexCount: 3, edgeIndices: [0], color: null }],
      edges: [{ id: 20 + shift, name: 'edge', points: new Float32Array([0, 0, 0, 2, 0, 0]), ownerFaceIds: [10 + shift], isFreeEdge: false, color: null }],
      vertices: [{ id: 30 + shift, position: [0, 0, 0] }], triangleToFaceMap: new Int32Array([10 + shift]),
    };
  }
  return { name: 'triangle.obj', format: cad ? 'step' : 'obj', parts: [{ id: `part-${suffix}`, name: 'Triangle', geometryId: data.id, matrix: new Matrix4().toArray(), parentId: `parent-${suffix}`, path: ['Model', 'Triangle'] }], geometries: new Map([[data.id, data]]), roots: [], unit: 'mm', sourceUnit: 'mm', warnings: [], importMs: 0, bytes: 0, is2D: false, ...(cad ? { exactModelId: suffix === 'old' ? 1 : 2 } : {}) };
}
function pick(doc: ModelDocument, kind: Pick['kind'] = 'point'): Pick {
  const part = doc.parts[0], data = doc.geometries.get(part.geometryId)!;
  return { id: 'runtime-pick-old', partId: part.id, partName: part.name, geometryId: part.geometryId, point: [0.4, 0.3, 0], localPoint: [0.4, 0.3, 0], kind, triangleIndex: 0, snap: 'Surface point', matrix: [...part.matrix], ...(kind === 'face' ? { elementId: data.topology?.faces[0].id ?? 0 } : kind === 'edge' ? { elementId: data.topology?.edges[0].id ?? 0 } : kind === 'vertex' ? { elementId: data.topology?.vertices[0].id ?? 0 } : {}), exactHandle: data.exactHandle };
}
function note(doc: ModelDocument, scope: ReviewNote['scope'] = 'point', kind: Pick['kind'] = 'point'): ReviewNote {
  return { id: `${scope}-${kind}`, text: '<b>Check this & keep plain text</b>', createdAt: '2026-10-15T10:00:00.000Z', updatedAt: '2026-10-15T10:01:00.000Z', resolved: false, scope, anchor: pick(doc, kind) };
}
function input(doc = document(), overrides: Partial<ProjectInput> = {}): ProjectInput {
  return { doc, files: [new File(['v 0 0 0\nv 2 0 0\nv 0 2 0\nf 1 2 3\n'], 'triangle.obj', { type: 'text/plain', lastModified: 123456 })], notes: [note(doc)], measurements: [{ id: 'measurement', name: 'Distance 1', kind: 'distance', points: [pick(doc), { ...pick(doc), point: [1, 0, 0], localPoint: [1, 0, 0] }], distance: 1, delta: [1, 0, 0], exact: false, note: 'Picked points' }], source: 'in', unit: 'cm', scale: 2, quality: 'fine', demo: false, ...overrides };
}
async function archive(options: ProjectInput) { return new File([await exportProject(options)], 'review.sz3d'); }
async function altered(file: File, mutate: (files: Record<string, Uint8Array>, manifest: any) => void) {
  const files = unzipSync(new Uint8Array(await file.arrayBuffer()));
  const manifest = JSON.parse(strFromU8(files['manifest.json']));
  mutate(files, manifest);
  files['manifest.json'] = strToU8(JSON.stringify(manifest));
  return new File([zipSync(files)], 'altered.sz3d');
}

describe('portable Shenzhen 3D review projects', () => {
  it('round-trips source inputs/companions, metadata, notes and saved measurements while rebinding random import IDs', async () => {
    const old = document(), original = input(old, { notes: [note(old), note(old, 'feature', 'face'), note(old, 'part')] });
    original.files = [...original.files, new File(['newmtl Surface'], 'triangle.mtl', { type: 'text/plain', lastModified: 54321 }), new File([new Uint8Array([137, 80, 78, 71])], 'albedo.png', { type: 'image/png' })];
    const file = await archive(original), data = await readProject(file), fresh = document('fresh');
    expect(data.files.map(file => file.name)).toEqual(['triangle.obj', 'triangle.mtl', 'albedo.png']);
    expect(await data.files[0].text()).toBe(await original.files[0].text());
    expect(data.files[0].lastModified).toBe(123456);
    expect(data.files[2].type).toBe('image/png');
    expect(data.quality).toBe('fine');
    const result = await restoreProjectState(data, fresh);
    expect(result).toMatchObject({ source: 'in', unit: 'cm', scale: 2, quality: 'fine', demo: false, warnings: [] });
    expect(result.notes).toHaveLength(3);
    expect(result.notes[0].text).toBe(original.notes![0].text);
    expect(result.notes[0].anchor.partId).toBe('part-fresh');
    expect(result.notes[0].anchor.geometryId).toBe('geometry-fresh');
    expect(result.notes[0].anchor.id).not.toBe('runtime-pick-old');
    expect(result.measurements[0].distance).toBe(1);
    expect(result.measurements[0].points.every(point => point.partId === 'part-fresh')).toBe(true);
    const manifestText = strFromU8(unzipSync(new Uint8Array(await file.arrayBuffer()))['manifest.json']);
    expect(manifestText).not.toContain('runtime-pick-old');
    expect(manifestText).not.toContain('exactHandle');
    expect(manifestText).not.toContain('geometry-old');
  });

  it('shares the built-in sample marker without archiving generated vertices or source files', async () => {
    const data = await readProject(await archive(input(document(), { demo: true, files: [] })));
    expect(data.demo).toBe(true);
    expect(data.files).toEqual([]);
    expect((await restoreProjectState(data, document('new-demo'))).notes).toHaveLength(1);
  });

  it('rejects ambiguous duplicate companion basenames on export and read', async () => {
    await expect(exportProject(input(document(), { files: [new File(['a'], 'model.obj'), new File(['b'], 'MODEL.OBJ')] }))).rejects.toThrow(/ambiguous/);
    const original = await archive(input(document(), { files: [new File(['a'], 'model.obj'), new File(['b'], 'texture.png')] }));
    await expect(readProject(await altered(original, (_files, manifest) => { manifest.sources[1].name = 'model.obj'; }))).rejects.toThrow(/ambiguous/);
  });

  it('rebinds fresh CAD exact handles and face/edge/vertex IDs by verified structural features', async () => {
    const old = document('old', true), fresh = document('new', true);
    const data = await readProject(await archive(input(old, { notes: [note(old, 'feature', 'face'), note(old, 'feature', 'edge'), note(old, 'feature', 'vertex')] })));
    const restored = await restoreProjectState(data, fresh);
    expect(restored.warnings).toEqual([]);
    expect(restored.notes.map(note => note.anchor.elementId)).toEqual([110, 120, 130]);
    expect(restored.notes.every(note => note.anchor.exactHandle === 999)).toBe(true);
    expect(restored.measurements[0].points.every(point => point.exactHandle === 999)).toBe(true);
    fresh.geometries.get(fresh.parts[0].geometryId)!.topology!.edges[0].points[3] = 9;
    const changed = await restoreProjectState(data, fresh);
    expect(changed.notes.map(note => note.anchor.kind)).toEqual(['face', 'vertex']);
    expect(changed.warnings).toHaveLength(1);
  });

  it('fails closed for changed geometry, transforms, part structure, or model counts', async () => {
    const data = await readProject(await archive(input()));
    for (const mutate of [
      (doc: ModelDocument) => doc.geometries.values().next().value!.geometry.getAttribute('position').setX(1, 3),
      (doc: ModelDocument) => { doc.parts[0].matrix[12] = 4; },
      (doc: ModelDocument) => { doc.parts[0].path = ['Another parent', 'Triangle']; },
      (doc: ModelDocument) => { doc.parts[0].name = 'Another part'; },
      (doc: ModelDocument) => { doc.parts.push({ ...doc.parts[0], id: 'additional' }); },
    ]) {
      const fresh = document('fresh'); mutate(fresh);
      const result = await restoreProjectState(data, fresh);
      expect(result.notes).toEqual([]);
      expect(result.measurements).toEqual([]);
      expect(result.warnings).toHaveLength(2);
    }
  });

  it('detects altered source bytes even if the ZIP remains structurally valid', async () => {
    const file = await archive(input());
    const bad = await altered(file, files => { files['files/000000'][0] ^= 1; });
    await expect(readProject(bad)).rejects.toThrow(/digest/);
  });

  it('rejects malformed or oversized manifest fields instead of coercing values', async () => {
    const file = await archive(input());
    for (const mutate of [
      (m: any) => { m.metadata.version = 99; },
      (m: any) => { m.metadata.scale = 0; },
      (m: any) => { m.metadata.scale = '2'; },
      (m: any) => { m.metadata.source = 'unknown'; },
      (m: any) => { m.metadata.quality = 'executable'; },
      (m: any) => { m.sources[0].name = '../outside.obj'; },
      (m: any) => { m.notes[0].text = 'x'.repeat(16001); },
      (m: any) => { m.notes[0].anchor.localPoint = [null, 0, 0]; },
      (m: any) => { m.notes[0].anchor.binding = 100; },
      (m: any) => { m.notes[0].createdAt = '<script>'; },
      (m: any) => { m.measurements[0].points = []; },
      (m: any) => { m.notes = Array(PROJECT_LIMITS.notes + 1).fill(m.notes[0]); },
      (m: any) => { m.notes.push(m.notes[0]); },
    ]) await expect(readProject(await altered(file, (_files, manifest) => mutate(manifest)))).rejects.toThrow();
  });

  it('rejects traversal, absolute paths, unknown files and truncated archives before extraction', async () => {
    const file = await archive(input()), valid = unzipSync(new Uint8Array(await file.arrayBuffer()));
    for (const path of ['../outside', '/outside', 'files/../outside', 'C:\\outside', 'files/unlisted']) {
      const files = Object.assign(Object.create(null), valid); files[path] = strToU8('bad');
      await expect(readProject(new File([zipSync(files)], 'bad.sz3d'))).rejects.toThrow(/archive|ZIP/);
    }
    await expect(readProject(new File([new Uint8Array([80, 75, 3, 4])], 'truncated.sz3d'))).rejects.toThrow(/truncated/);
  });

  it('rejects excessive declared ZIP expansion and encrypted entries before creating workers', async () => {
    const original = new Uint8Array(await (await archive(input())).arrayBuffer());
    for (const mutation of ['oversized', 'encrypted', 'zip64'] as const) {
      const bytes = original.slice(), view = new DataView(bytes.buffer);
      for (let i = 0; i < bytes.length - 46; i++) if (view.getUint32(i, true) === 0x02014b50) {
        if (mutation === 'oversized') view.setUint32(i + 24, PROJECT_LIMITS.fileBytes + 1, true);
        else if (mutation === 'encrypted') view.setUint16(i + 8, view.getUint16(i + 8, true) | 1, true);
        else view.setUint32(i + 24, 0xffffffff, true);
        break;
      }
      await expect(readProject(new File([bytes], 'bad.sz3d'))).rejects.toThrow(/ZIP/);
    }
  });

  it('rejects duplicate ZIP paths and corrupted manifest checksums', async () => {
    const file = await archive(input(document(), { files: [new File(['a'], 'model.obj'), new File(['b'], 'texture.png')] }));
    const original = new Uint8Array(await file.arrayBuffer());
    const duplicate = original.slice(), duplicateView = new DataView(duplicate.buffer);
    for (let i = 0; i < duplicate.length - 46; i++) if (duplicateView.getUint32(i, true) === 0x02014b50) {
      const length = duplicateView.getUint16(i + 28, true);
      if (strFromU8(duplicate.subarray(i + 46, i + 46 + length)) === 'files/000001') {
        duplicate.set(strToU8('files/000000'), i + 46);
        duplicate.set(strToU8('files/000000'), duplicateView.getUint32(i + 42, true) + 30);
      }
    }
    await expect(readProject(new File([duplicate], 'duplicate.sz3d'))).rejects.toThrow(/duplicate/);
    const corrupted = original.slice(), view = new DataView(corrupted.buffer);
    for (let i = 0; i < corrupted.length - 46; i++) if (view.getUint32(i, true) === 0x02014b50) {
      const length = view.getUint16(i + 28, true);
      if (strFromU8(corrupted.subarray(i + 46, i + 46 + length)) === 'manifest.json') {
        view.setUint32(i + 16, view.getUint32(i + 16, true) ^ 1, true);
        break;
      }
    }
    await expect(readProject(new File([corrupted], 'corrupted.sz3d'))).rejects.toThrow(/checksum/);
  });

  it('uses bounded asynchronous compression/expansion for large companion blobs without detaching original files', async () => {
    const bytes = new Uint8Array(512 * 1024);
    let state = 12345;
    for (let i = 0; i < bytes.length; i++) { state = (Math.imul(state, 1664525) + 1013904223) >>> 0; bytes[i] = state >>> 24; }
    const source = new File([bytes], 'large.bin');
    const result = await readProject(await archive(input(document(), { files: [new File(['obj'], 'model.obj'), source] })));
    expect(new Uint8Array(await result.files[1].arrayBuffer())).toEqual(bytes);
    expect(new Uint8Array(await source.arrayBuffer())).toEqual(bytes);
  });

  it('stops actual decompression when an entry lies about its expanded size', async () => {
    const original = await archive(input(document(), { files: [new File(['x'.repeat(100000)], 'model.obj')] }));
    const rewritten = await altered(original, (_files, manifest) => { manifest.sources[0].size = 16; });
    const bytes = new Uint8Array(await rewritten.arrayBuffer()), view = new DataView(bytes.buffer);
    for (let i = 0; i < bytes.length - 46; i++) if (view.getUint32(i, true) === 0x02014b50) {
      const nameLength = view.getUint16(i + 28, true), name = strFromU8(bytes.subarray(i + 46, i + 46 + nameLength));
      if (name === 'files/000000') {
        view.setUint32(i + 24, 16, true);
        view.setUint32(view.getUint32(i + 42, true) + 22, 16, true);
        break;
      }
    }
    await expect(readProject(new File([bytes], 'lying.sz3d'))).rejects.toThrow(/expanded/);
  });

  it('round-trips genuine sample STEP CAD features and saved exact measurements into a fresh native model', async () => {
    const { createKernel, importOptions } = await import('../scripts/benchmark.mjs');
    const kernel = await createKernel();
    const source = new File([readFileSync('fixtures/sample-assembly.step')], 'sample-assembly.step');
    const oldModel = kernel.OpenExactStepModel(new Uint8Array(await source.arrayBuffer()), importOptions);
    expect(oldModel.success).toBe(true);
    let freshModel: any;
    try {
      const old = fromCad(oldModel, source.name);
      const part = old.parts.find(part => old.parts.some(other => other.id !== part.id && other.geometryId === part.geometryId))!;
      const other = old.parts.find(candidate => candidate.id !== part.id && candidate.geometryId === part.geometryId)!;
      const geometry = old.geometries.get(part.geometryId)!;
      const face = geometry.topology!.faces[0], edge = geometry.topology!.edges[0], vertex = geometry.topology!.vertices[0];
      const anchor = (target: typeof part, kind: Pick['kind'], elementId: number, localPoint: [number, number, number]): Pick => ({ id: createPickId(), partId: target.id, partName: target.name, geometryId: target.geometryId, point: new Vector3(...localPoint).applyMatrix4(new Matrix4().fromArray(target.matrix)).toArray(), localPoint, kind, elementId, ...(kind === 'face' ? { triangleIndex: face.firstIndex / 3 } : {}), snap: 'Exact CAD feature', exactHandle: geometry.exactHandle, matrix: [...target.matrix] });
      const facePoint: [number, number, number] = Array.from(geometry.topology!.positions.slice(geometry.topology!.indices[face.firstIndex] * 3, geometry.topology!.indices[face.firstIndex] * 3 + 3)) as [number, number, number];
      const first = anchor(part, 'face', face.id, facePoint), second = anchor(other, 'face', face.id, facePoint);
      const distance = kernel.MeasureExactDistance(old.exactModelId, first.exactHandle, 'face', first.elementId, second.exactHandle, 'face', second.elementId, first.matrix, second.matrix);
      expect(distance.ok).toBe(true);
      const anchors = [first, anchor(part, 'edge', edge.id, Array.from(edge.points.slice(0, 3)) as [number, number, number]), anchor(part, 'vertex', vertex.id, vertex.position)];
      const notes = anchors.map((anchor, i) => ({ ...note(old, 'feature'), id: `real-${i}`, anchor }));
      const data = await readProject(await archive(input(old, { files: [source], notes, measurements: [{ id: 'native-measurement', name: 'Exact CAD distance', kind: 'distance', points: [first, second], distance: distance.value, exact: true, note: 'Native exact geometry' }] })));
      freshModel = kernel.OpenExactStepModel(new Uint8Array(await data.files[0].arrayBuffer()), importOptions);
      expect(freshModel.success).toBe(true);
      const fresh = fromCad(freshModel, source.name), restored = await restoreProjectState(data, fresh);
      expect(restored.warnings).toEqual([]);
      expect(restored.notes.map(note => note.anchor.kind)).toEqual(['face', 'edge', 'vertex']);
      const [a, b] = restored.measurements[0].points;
      expect(a.id).not.toBe(first.id);
      expect(a.exactHandle).toBe(fresh.geometries.get(a.geometryId)!.exactHandle);
      const queried = kernel.MeasureExactDistance(fresh.exactModelId, a.exactHandle, a.kind, a.elementId, b.exactHandle, b.kind, b.elementId, a.matrix, b.matrix);
      expect(queried.ok).toBe(true);
      expect(queried.value).toBeCloseTo(restored.measurements[0].distance, 8);
    } finally {
      if (freshModel?.exactModelId) kernel.ReleaseExactModel(freshModel.exactModelId);
      kernel.ReleaseExactModel(oldModel.exactModelId);
    }
  }, 60_000);
});

let pickSerial = 0;
function createPickId() { return `kernel-pick-${++pickSerial}`; }
