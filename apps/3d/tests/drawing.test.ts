import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import * as T from 'three';
import { drawingFromDatabase, importDrawing } from '../src/core/drawing';
const buffer = (name: string) => { const data = readFileSync(resolve('tests/fixtures/drawing', name)); return data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) as ArrayBuffer; };
function endpoints(doc: ReturnType<typeof drawingFromDatabase>, partIndex: number) {
  const part = doc.parts[partIndex], positions = doc.geometries.get(part.geometryId)!.geometry.getAttribute('position');
  const matrix = new T.Matrix4().fromArray(part.matrix);
  return [new T.Vector3().fromBufferAttribute(positions, 0).applyMatrix4(matrix), new T.Vector3().fromBufferAttribute(positions, positions.count - 1).applyMatrix4(matrix)];
}
describe('DXF drawing import', () => {
  it('preserves units, analytic measurements, colors, bulges and block transforms', async () => {
    const doc = await importDrawing(buffer('engineering.dxf'), 'engineering.dxf', 'dxf');
    expect(doc.parts).toHaveLength(6); expect(doc.unit).toBe('mm'); expect(doc.is2D).toBe(true);
    const geometry = [...doc.geometries.values()];
    expect(geometry[0].geometry.userData.drawing.length).toBe(50);
    expect((geometry[0].materials[0] as T.LineBasicMaterial).color.getHex()).toBe(0xff0000);
    expect(geometry[1].geometry.userData.drawing.radius).toBe(5);
    expect(geometry[1].geometry.userData.drawing.area).toBeCloseTo(Math.PI * 25);
    expect(geometry[2].geometry.userData.drawing.length).toBeCloseTo(10 * Math.PI / 9);
    expect(geometry[3].geometry.userData.drawing.length).toBeCloseTo(10 * Math.PI);
    const bulge = geometry[3].geometry.getAttribute('position');
    expect(new T.Vector3().fromBufferAttribute(bulge, Math.floor(bulge.count / 2)).y).toBeCloseTo(-10);
    const [a, b] = endpoints(doc, 4); expect(a.toArray()).toEqual([100, 50, 0]); expect(b.x).toBeCloseTo(100); expect(b.y).toBeCloseTo(54);
    expect(doc.warnings.some(w => w.includes('unsupported HATCH'))).toBe(true);
  });
  it('computes signed bulge area before absolute area for closed contours', () => {
    const doc = drawingFromDatabase({ entities: [{ type: 'LWPOLYLINE', shape: true, vertices: [{ x: -5, y: 0, bulge: 1 }, { x: 5, y: 0, bulge: 1 }] }] }, 'circle.dxf', 'dxf');
    const properties = [...doc.geometries.values()][0].geometry.userData.drawing;
    expect(properties.area).toBeCloseTo(Math.PI * 25); expect(properties.length).toBeCloseTo(10 * Math.PI);
  });
  it('uses object-coordinate normals for arcs without changing world-coordinate lines', () => {
    const doc = drawingFromDatabase({ entities: [{ type: 'ARC', center: { x: 0, y: 0 }, radius: 5, startAngle: 0, endAngle: Math.PI / 2, extrusionDirection: { x: 0, y: 1, z: 0 } }] }, 'vertical.dxf', 'dxf');
    const [a, b] = endpoints(doc, 0); expect(a.x).toBeCloseTo(-5); expect(a.y).toBeCloseTo(0); expect(b.z).toBeCloseTo(5);
  });
  it('bounds recursive blocks and explicitly reports unsupported objects', () => {
    const doc = drawingFromDatabase({ blocks: { recursive: { entities: [{ type: 'INSERT', name: 'recursive' }] } }, entities: [{ type: 'INSERT', name: 'recursive' }, { type: '3DSOLID' }] }, 'unsupported.dxf', 'dxf');
    expect(doc.parts).toHaveLength(0); expect(doc.warnings.some(w => w.includes('recursive block'))).toBe(true); expect(doc.warnings.some(w => w.includes('3DSOLID'))).toBe(true);
  });
  it('scales unsupported UI units into a supported coordinate unit', () => {
    const doc = drawingFromDatabase({ header: { $INSUNITS: 7 }, entities: [{ type: 'LINE', vertices: [{ x: 0, y: 0 }, { x: 1, y: 0 }] }] }, 'km.dxf', 'dxf');
    expect(doc.unit).toBe('m'); expect(endpoints(doc, 0)[1].x).toBe(1000); expect(doc.sourceUnit).toContain('Kilometers');
  });
  it('evaluates complete NURBS rather than treating control points as the curve', () => {
    const doc = drawingFromDatabase({ entities: [{ type: 'SPLINE', degreeOfSplineCurve: 2, knotValues: [0, 0, 0, 1, 1, 1], controlPoints: [{ x: 0, y: 0 }, { x: 5, y: 10 }, { x: 10, y: 0 }] }] }, 'spline.dxf', 'dxf');
    const attr = [...doc.geometries.values()][0].geometry.getAttribute('position');
    expect(new T.Vector3().fromBufferAttribute(attr, (attr.count - 1) / 2).y).toBeCloseTo(5);
  });
  it('rejects binary DXF with an actionable error', async () => {
    await expect(importDrawing(new TextEncoder().encode('AutoCAD Binary DXF\r\n').buffer, 'binary.dxf', 'dxf')).rejects.toThrow('ASCII DXF');
  });
});
describe('DWG normalized database', () => {
  it('accepts native DWG fields, radians, layer colors and polyline flags', () => {
    const doc = drawingFromDatabase({ header: { INSUNITS: 1 }, tables: { LAYER: { entries: [{ name: 'red', color: 0xff0000 }] }, BLOCK_RECORD: { entries: [{ name: 'B', basePoint: { x: 2, y: 2 }, entities: [{ type: 'LINE', startPoint: { x: 2, y: 2 }, endPoint: { x: 4, y: 2 } }] }] } }, entities: [{ type: 'INSERT', name: 'B', insertionPoint: { x: 10, y: 20 }, rotation: Math.PI / 2, layer: 'red' }, { type: 'POLYLINE2D', flag: 1, vertices: [{ x: 0, y: 0 }, { x: 5, y: 0 }, { x: 0, y: 5 }] }] }, 'native.dwg', 'dwg');
    expect(doc.unit).toBe('in'); expect(doc.parts).toHaveLength(2); const [a, b] = endpoints(doc, 0); expect(a.x).toBeCloseTo(10); expect(a.y).toBeCloseTo(20); expect(b.y).toBeCloseTo(22);
    expect([...doc.geometries.values()][1].geometry.userData.drawing.area).toBeCloseTo(12.5);
  });
  it('decodes real AutoCAD 2000 files with bundled LibreDWG', async () => {
    const { LibreDwg, Dwg_File_Type } = await import('@mlightcad/libredwg-web');
    const dwg = await LibreDwg.create(resolve('node_modules/@mlightcad/libredwg-web/wasm'));
    for (const name of ['arc-2000.dwg', 'polyline-2000.dwg']) {
      const ptr = dwg.dwg_read_data(buffer(name), Dwg_File_Type.DWG); expect(ptr).toBeTruthy();
      try { const database = dwg.convert(ptr); const doc = drawingFromDatabase(database, name, 'dwg'); expect(doc.parts.length).toBeGreaterThan(0); expect([...doc.geometries.values()].every(g => g.geometry.getAttribute('position').array.every(Number.isFinite))).toBe(true); }
      finally { dwg.dwg_free(ptr); }
    }
  }, 60000);
});
