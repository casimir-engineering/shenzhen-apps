import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import * as T from 'three';
import { disposeDocument, fromObject, importFiles } from '../src/core/importers';
import { conversion } from '../src/core/units';

const fixture = (name: string) => new File([readFileSync(resolve('tests/fixtures/formats', name))], name);
const load = (name: string) => importFiles([fixture(name)], 'balanced', () => {});

describe('mesh format import', () => {
  it.each(['triangle.stl', 'colors.ply', 'quad.off'])('imports %s with measurable indexed geometry and an explicit unit warning', async name => {
    const doc = await load(name);
    try {
      expect(doc.parts).toHaveLength(1);
      expect(doc.unit).toBe('mm');
      expect(doc.warnings.some(w => /unit|millimeter/.test(w))).toBe(true);
      expect(doc.bytes).toBe(fixture(name).size);
      const { geometry } = [...doc.geometries.values()][0];
      geometry.computeBoundingBox();
      expect(geometry.boundingBox!.getSize(new T.Vector3()).toArray()).toEqual([10, 20, 0]);
      expect(geometry.index!.count).toBe(name.endsWith('.off') ? 6 : 3);
      expect(geometry.getAttribute('normal').array.every(Number.isFinite)).toBe(true);
    } finally { disposeDocument(doc); }
  });

  it('preserves per-vertex PLY colors', async () => {
    const doc = await load('colors.ply');
    try {
      const data = [...doc.geometries.values()][0];
      expect((data.materials[0] as T.MeshStandardMaterial).vertexColors).toBe(true);
      const colors = data.geometry.getAttribute('color');
      expect([0, 1, 2].flatMap(i => [colors.getX(i), colors.getY(i), colors.getZ(i)])).toEqual([1, 0, 0, 0, 1, 0, 0, 0, 1]);
    } finally { disposeDocument(doc); }
  });

  it('loads practical ASCII FBX material opacity and world transforms', async () => {
    const doc = await load('panel.fbx');
    try {
      expect(doc.parts).toHaveLength(1);
      expect(doc.unit).toBe('cm');
      expect(doc.parts[0].matrix.slice(12, 15)).toEqual([2, 3, 4]);
      const material = [...doc.geometries.values()][0].materials[0];
      expect(material.opacity).toBeCloseTo(0.4);
      expect(material.transparent).toBe(true);
    } finally { disposeDocument(doc); }
  });

  it('honors FBX UnitScaleFactor metadata for measurement scale', async () => {
    const text = (await fixture('panel.fbx').text()).replace('"UnitScaleFactor", "double", "Number", "",1', '"UnitScaleFactor", "double", "Number", "",100');
    const doc = await importFiles([new File([text], 'meters.fbx')], 'balanced', () => {});
    try {
      const data = [...doc.geometries.values()][0];
      const bounds = new T.Box3().setFromBufferAttribute(data.geometry.getAttribute('position')).applyMatrix4(new T.Matrix4().fromArray(doc.parts[0].matrix));
      expect(bounds.getSize(new T.Vector3()).x * conversion(doc.unit, 'mm')).toBeCloseTo(1000);
      expect(bounds.min.toArray().map(value => value * conversion(doc.unit, 'mm'))).toEqual([2000, 3000, 4000]);
    } finally { disposeDocument(doc); }
  });

  it('scales a collapsed FBX root group placement together with its children', async () => {
    const root = '\tModel: 4, "Model::Root", "Null" {\n\t\tVersion: 232\n\t\tProperties70:  {\n\t\t\tP: "Lcl Translation", "Lcl Translation", "", "A",5,0,0\n\t\t}\n\t}\n';
    const text = (await fixture('panel.fbx').text())
      .replace('"UnitScaleFactor", "double", "Number", "",1', '"UnitScaleFactor", "double", "Number", "",100')
      .replace('\n}\nConnections:', '\n' + root + '}\nConnections:')
      .replace('\tC: "OO",2,0', '\tC: "OO",2,4\n\tC: "OO",4,0');
    const doc = await importFiles([new File([text], 'root-group.fbx')], 'balanced', () => {});
    try {
      const matrix = new T.Matrix4().fromArray(doc.parts[0].matrix);
      const position = new T.Vector3().setFromMatrixPosition(matrix).multiplyScalar(conversion(doc.unit, 'mm'));
      expect(position.toArray()).toEqual([7000, 3000, 4000]);
    } finally { disposeDocument(doc); }
  });

  it('rejects companion-only and empty supported files with actionable errors', async () => {
    await expect(importFiles([fixture('panel.mtl')], 'balanced', () => {})).rejects.toThrow('supported');
    await expect(importFiles([new File(['o Empty\n'], 'empty.obj')], 'balanced', () => {})).rejects.toThrow('No displayable geometry');
  });

  it('keeps distinct instances and materials when object geometry is shared', () => {
    const root = new T.Group(), geometry = new T.BoxGeometry(1, 2, 3);
    const a = new T.Mesh(geometry, new T.MeshBasicMaterial({ color: 'red' }));
    const b = new T.Mesh(geometry, new T.MeshBasicMaterial({ color: 'blue' }));
    root.position.set(10, 20, 30); b.position.x = 5; root.add(a, b);
    const doc = fromObject(root, 'shared.obj');
    try {
      expect(doc.geometries.size).toBe(2);
      expect(doc.parts).toHaveLength(2);
      expect(doc.parts[0].matrix.slice(12, 15)).toEqual([10, 20, 30]);
      expect(doc.parts[1].matrix.slice(12, 15)).toEqual([15, 20, 30]);
    } finally { disposeDocument(doc); }
  });
});
