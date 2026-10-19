import * as T from 'three';
import DxfParser from 'dxf-parser';
import aci from 'dxf-parser/dist/AutoCadColorIndex.js';
import { NURBSCurve } from 'three/addons/curves/NURBSCurve.js';
import { fromObject } from './importers';
import type { ModelDocument, Unit, Vec3 } from './types';

// The two parsers expose different entity shapes; normalize at this boundary.
type Entity = Record<string, any>;
type Database = { entities: Entity[]; header?: Record<string, any>; blocks?: Record<string, Entity>; tables?: Record<string, any> };
export interface DrawingProperties { family: string; length?: number; area?: number; radius?: number; diameter?: number; center?: Vec3; exact: boolean }
const tau = Math.PI * 2;
const v = (p?: Entity): T.Vector3 => new T.Vector3(Number(p?.x ?? 0), Number(p?.y ?? 0), Number(p?.z ?? 0));
const sweep = (start: number, end: number) => ((end - start) % tau + tau) % tau || tau;
function arcPoints(center: T.Vector3, radius: number, start: number, angle: number) {
  const count = Math.max(2, Math.ceil(Math.abs(angle) / tau * 256));
  return Array.from({ length: count + 1 }, (_, i) => new T.Vector3(center.x + radius * Math.cos(start + angle * i / count), center.y + radius * Math.sin(start + angle * i / count), center.z));
}
function ocs(e: Entity) {
  const normal = v(e.extrusionDirection ?? { x: e.extrusionDirectionX ?? 0, y: e.extrusionDirectionY ?? 0, z: e.extrusionDirectionZ ?? 1 }).normalize();
  if (!normal.lengthSq()) normal.set(0, 0, 1);
  const x = (Math.abs(normal.x) < 1 / 64 && Math.abs(normal.y) < 1 / 64 ? new T.Vector3(0, 1, 0) : new T.Vector3(0, 0, 1)).cross(normal).normalize();
  return new T.Matrix4().makeBasis(x, normal.clone().cross(x), normal);
}
function unitInfo(code: number): { unit: Unit; scale: number; label: string } {
  const known: Record<number, [Unit, number, string]> = { 1: ['in', 1, 'Inches'], 2: ['ft', 1, 'Feet'], 3: ['ft', 5280, 'Miles (converted to feet)'], 4: ['mm', 1, 'Millimeters'], 5: ['cm', 1, 'Centimeters'], 6: ['m', 1, 'Meters'], 7: ['m', 1000, 'Kilometers (converted to meters)'], 8: ['in', .000001, 'Microinches (converted to inches)'], 9: ['in', .001, 'Mils (converted to inches)'], 10: ['ft', 3, 'Yards (converted to feet)'], 11: ['m', 1e-10, 'Angstroms (converted to meters)'], 12: ['m', 1e-9, 'Nanometers (converted to meters)'], 13: ['um', 1, 'Micrometers'], 14: ['mm', 100, 'Decimeters (converted to millimeters)'], 15: ['m', 10, 'Decameters (converted to meters)'], 16: ['m', 100, 'Hectometers (converted to meters)'], 17: ['m', 1e9, 'Gigameters (converted to meters)'], 18: ['m', 149597870700, 'Astronomical units (converted to meters)'], 19: ['m', 9460730472580800, 'Light years (converted to meters)'], 20: ['m', 30856775814913673, 'Parsecs (converted to meters)'], 21: ['m', 1200 / 3937, 'US survey feet (converted to meters)'] };
  const [unit, scale, label] = known[code] ?? ['mm', 1, 'Unitless / unknown (assumed millimeters)'];
  return { unit, scale, label };
}
function plainText(text: string) {
  return text.replace(/\\P/g, '\n').replace(/\\~/g, ' ').replace(/%%d/gi, '°').replace(/%%p/gi, '±').replace(/%%c/gi, 'Ø').replace(/\\U\+([0-9a-f]{4})/gi, (_, n) => String.fromCharCode(parseInt(n, 16))).replace(/\\[A-Za-z][^;]*;/g, '').replace(/[{}]/g, '');
}
function textMesh(e: Entity, color: number, isDwg: boolean): T.Mesh | undefined {
  if (typeof document === 'undefined') return undefined;
  const text = plainText(String(e.text ?? '')); if (!text) return undefined;
  const canvas = document.createElement('canvas'); const ctx = canvas.getContext('2d'); if (!ctx) return undefined;
  const rows = text.split('\n'); const fontSize = 64; ctx.font = `${fontSize}px sans-serif`;
  const widths = rows.map(t => ctx.measureText(t).width); const width = Math.max(1, ...widths);
  // Limit GPU allocation for untrusted or very large annotations.
  const rasterScale = Math.min(1, 4096 / (width + 16), 4096 / (rows.length * fontSize * 1.3 + 16));
  canvas.width = Math.ceil((width + 16) * rasterScale); canvas.height = Math.ceil((rows.length * fontSize * 1.3 + 16) * rasterScale);
  ctx.scale(rasterScale, rasterScale); ctx.font = `${fontSize}px sans-serif`; ctx.fillStyle = '#ffffff'; ctx.textBaseline = 'top'; rows.forEach((t, i) => ctx.fillText(t, 8, 8 + i * fontSize * 1.3));
  const h = Number(e.textHeight ?? e.height ?? 1); const w = (width + 16) / fontSize * h; const totalH = (rows.length * fontSize * 1.3 + 16) / fontSize * h;
  const geometry = new T.PlaneGeometry(w, totalH); geometry.translate(w / 2, totalH / 2, 0);
  if (e.type === 'MTEXT') {
    const attachment = Number(e.attachmentPoint ?? 1) - 1;
    geometry.translate(-w * (attachment % 3) / 2, -totalH * (1 - Math.floor(attachment / 3) / 2), 0);
  } else { geometry.translate(-w * ({ 1: .5, 2: 1, 4: .5 } as Record<number, number>)[e.halign] || 0, -totalH * ({ 2: .5, 3: 1 } as Record<number, number>)[e.valign] || 0, 0); }
  const texture = new T.CanvasTexture(canvas); texture.colorSpace = T.SRGBColorSpace;
  const mesh = new T.Mesh(geometry, new T.MeshBasicMaterial({ map: texture, color, transparent: true, depthWrite: false, side: T.DoubleSide }));
  mesh.position.copy(v(e.insertionPoint ?? e.position ?? ((e.halign || e.valign) && e.endPoint ? e.endPoint : e.startPoint)));
  const direction = e.directionVector ?? e.direction;
  mesh.rotation.z = direction && (direction.x || direction.y) ? Math.atan2(direction.y, direction.x) : Number(e.rotation ?? 0) * (isDwg ? 1 : Math.PI / 180);
  mesh.scale.x = Number(e.xScale ?? 1); mesh.updateMatrix(); mesh.matrix.premultiply(ocs(e)); mesh.matrixAutoUpdate = false;
  geometry.userData.drawing = { family: 'Text annotation', exact: false }; geometry.userData.text = text; return mesh;
}

/** Build local geometry from either parser's database. Exported for deterministic parser tests. */
export function drawingFromDatabase(db: Database, name: string, format: 'dxf' | 'dwg', initialWarnings: string[] = []): ModelDocument {
  const isDwg = format === 'dwg'; const root = new T.Group(); root.name = name;
  const warnings = new Set(initialWarnings); const skipped = new Map<string, number>(); const skip = (type: string) => skipped.set(type, (skipped.get(type) ?? 0) + 1);
  const layers: Record<string, Entity> = isDwg ? Object.fromEntries((db.tables?.LAYER?.entries ?? []).map((e: Entity) => [e.name, e])) : db.tables?.layer?.layers ?? {};
  const blocks: Record<string, Entity> = isDwg ? Object.fromEntries((db.tables?.BLOCK_RECORD?.entries ?? []).map((e: Entity) => [e.name, e])) : db.blocks ?? {};
  const paperSpaceHandles = new Set(Object.values(blocks).filter(b => /^\*Paper_Space/i.test(b.name ?? '')).map(b => b.handle));
  const materials = new Map<number, T.LineBasicMaterial>(); let count = 0;
  const colorFor = (e: Entity, layerName: string, inherited: number): number => {
    const layer = layers[layerName];
    if (e.colorIndex === 0) return inherited;
    if (e.color !== undefined && e.colorIndex !== 256) return Number(e.color);
    if (e.colorIndex > 0 && e.colorIndex < 256) return aci[e.colorIndex] ?? 0xffffff;
    return layer?.color ?? aci[Math.abs(layer?.colorIndex ?? 7)] ?? 0xffffff;
  };
  function line(points: T.Vector3[], props: DrawingProperties, color: number) {
    if (points.length < 2 || points.some(p => ![p.x, p.y, p.z].every(Number.isFinite))) throw new Error('Invalid coordinates');
    const geometry = new T.BufferGeometry().setFromPoints(points); geometry.userData.drawing = props;
    let material = materials.get(color); if (!material) { material = new T.LineBasicMaterial({ color }); materials.set(color, material); }
    return new T.Line(geometry, material);
  }
  function addEntities(entities: Entity[], group: T.Group, inheritedLayer = '0', inheritedColor = 0xffffff, stack: string[] = []) {
    for (const e of entities) {
      if (++count > 500000) throw new Error('Drawing exceeds 500,000 expanded entities; reduce or split the drawing.');
      const type = String(e.type ?? 'UNKNOWN').toUpperCase(); const layerName = e.layer && e.layer !== '0' ? e.layer : inheritedLayer;
      const layer = layers[layerName]; if (e.isInPaperSpace || e.inPaperSpace || e.paperSpace || paperSpaceHandles.has(e.ownerBlockRecordSoftId)) { skip('paper-space entities'); continue; }
      if (e.visible === false || e.isVisible === false || layer?.visible === false || layer?.off || layer?.frozen || e.colorIndex < 0) { skip('hidden entities'); continue; }
      const color = colorFor(e, layerName, inheritedColor); let object: T.Object3D | undefined; let applyOcs = false;
      try {
        switch (type) {
          case 'INSERT': case 'DIMENSION': {
            const blockName = e.name ?? e.block ?? e.blockName; const block = blocks[blockName];
            if (!block) { skip(type + ' (missing block ' + blockName + ')'); break; }
            if (stack.includes(blockName) || stack.length >= 32) { skip('recursive block ' + blockName); break; }
            const rows = Math.max(1, Math.min(10000, e.rowCount ?? 1)), columns = Math.max(1, Math.min(10000, e.columnCount ?? 1));
            if (rows * columns > 100000) throw new Error('Block array is too large');
            for (let row = 0; row < rows; row++) for (let col = 0; col < columns; col++) {
              const instance = new T.Group(); instance.name = `${blockName}${rows * columns > 1 ? ` [${row + 1},${col + 1}]` : ''}`;
              const point = type === 'DIMENSION' ? new T.Vector3() : v(e.insertionPoint ?? e.position);
              const rotation = Number(e.rotation ?? 0) * (isDwg ? 1 : Math.PI / 180);
              instance.matrix.copy(ocs(e)).multiply(new T.Matrix4().makeTranslation(point.x, point.y, point.z)).multiply(new T.Matrix4().makeRotationZ(rotation)).multiply(new T.Matrix4().makeTranslation(col * (e.columnSpacing ?? 0), row * (e.rowSpacing ?? 0), 0)).multiply(new T.Matrix4().makeScale(e.xScale ?? 1, e.yScale ?? 1, e.zScale ?? 1));
              const base = v(block.basePoint ?? block.position); instance.matrix.multiply(new T.Matrix4().makeTranslation(-base.x, -base.y, -base.z)); instance.matrixAutoUpdate = false;
              addEntities(block.entities ?? [], instance, layerName, color, [...stack, blockName]); group.add(instance);
            }
            if (e.attribs?.length) addEntities(e.attribs, group, layerName, color, stack);
            break;
          }
          case 'LINE': { const points = e.vertices?.map(v) ?? [v(e.startPoint), v(e.endPoint)]; object = line(points, { family: 'Line', length: points[0].distanceTo(points[1]), exact: true }, color); break; }
          case 'CIRCLE': case 'ARC': {
            const center = v(e.center), radius = Number(e.radius); if (!(radius > 0)) throw new Error('Invalid radius');
            const start = type === 'CIRCLE' ? 0 : Number(e.startAngle); const angle = type === 'CIRCLE' ? tau : sweep(start, Number(e.endAngle));
            object = line(arcPoints(center, radius, start, angle), { family: type === 'CIRCLE' ? 'Circle' : 'Circular arc', radius, diameter: radius * 2, center: center.toArray(), length: radius * angle, ...(type === 'CIRCLE' ? { area: Math.PI * radius * radius } : {}), exact: true }, color); applyOcs = true; break;
          }
          case 'LWPOLYLINE': case 'POLYLINE': case 'POLYLINE2D': case 'POLYLINE3D': {
            if (e.isPolyfaceMesh || e.is3dPolygonMesh || (e.flag & 64) || (e.flag & 16)) { skip(type + ' polygon mesh'); break; }
            const vertices: Entity[] = e.vertices ?? []; const closed = e.shape || Boolean((e.flag ?? 0) & 1); const points: T.Vector3[] = []; let length = 0; let area = 0;
            for (let i = 0; i < vertices.length; i++) {
              const a = v({ ...vertices[i], z: vertices[i].z ?? e.elevation ?? 0 }); points.push(a);
              if (i === vertices.length - 1 && !closed) break;
              const next = vertices[(i + 1) % vertices.length]; const b = v({ ...next, z: next.z ?? e.elevation ?? 0 }); const bulge = Number(vertices[i].bulge ?? 0); const chord = a.distanceTo(b);
              area += (a.x * b.y - b.x * a.y) / 2;
              if (Math.abs(bulge) > 1e-12 && chord > 0) {
                const angle = 4 * Math.atan(bulge); const radius = chord * (1 + bulge * bulge) / (4 * Math.abs(bulge));
                const center = a.clone().add(b).multiplyScalar(.5).add(new T.Vector3(-(b.y - a.y), b.x - a.x, 0).multiplyScalar((1 - bulge * bulge) / (4 * bulge)));
                points.push(...arcPoints(center, radius, Math.atan2(a.y - center.y, a.x - center.x), angle).slice(1, -1)); length += radius * Math.abs(angle); area += radius * radius * (angle - Math.sin(angle)) / 2;
              } else length += chord;
            }
            if (closed && points.length) points.push(points[0].clone());
            const planarXY = points.every(p => Math.abs(p.z - points[0].z) < 1e-9);
            object = line(points, { family: closed ? 'Closed polyline' : 'Polyline', length, ...(closed && planarXY ? { area: Math.abs(area) } : {}), exact: true }, color); applyOcs = type !== 'POLYLINE3D' && !e.is3dPolyline; break;
          }
          case 'ELLIPSE': {
            const center = v(e.center), major = v(e.majorAxisEndPoint), normal = v(e.extrusionDirection ?? { z: 1 }).normalize();
            const minor = normal.cross(major).normalize().multiplyScalar(major.length() * Number(e.axisRatio)); const start = Number(e.startAngle ?? 0), angle = sweep(start, Number(e.endAngle ?? tau));
            const points = Array.from({ length: 257 }, (_, i) => center.clone().addScaledVector(major, Math.cos(start + angle * i / 256)).addScaledVector(minor, Math.sin(start + angle * i / 256)));
            object = line(points, { family: 'Ellipse', center: center.toArray(), length: points.slice(1).reduce((s, p, i) => s + p.distanceTo(points[i]), 0), ...(Math.abs(angle - tau) < 1e-9 ? { area: Math.PI * major.length() * minor.length() } : {}), exact: false }, color); break;
          }
          case 'SPLINE': {
            const control: Entity[] = e.controlPoints ?? [], knots: number[] = e.knotValues ?? e.knots ?? []; const degree = Number(e.degreeOfSplineCurve ?? e.degree ?? 3); let points: T.Vector3[];
            if (control.length > degree && knots.length === control.length + degree + 1) {
              if ((e.rational || (e.flag & 4)) && !e.weights?.length && !control.some(p => p.weight !== undefined)) warnings.add('Rational spline weights were not supplied by the parser; this spline is approximated with unit weights.');
              const curve = new NURBSCurve(degree, knots, control.map((p, i) => new T.Vector4(p.x, p.y, p.z ?? 0, e.weights?.[i] ?? p.weight ?? 1))); points = curve.getPoints(Math.min(4096, Math.max(128, control.length * 24)));
            } else if (e.fitPoints?.length > 1) { points = new T.CatmullRomCurve3(e.fitPoints.map(v), Boolean(e.closed || (e.flag & 1))).getPoints(Math.max(128, e.fitPoints.length * 24)); warnings.add('Fit-point splines without a complete knot vector are interpolated approximately.'); }
            else throw new Error('Incomplete spline');
            object = line(points, { family: 'Spline', length: points.slice(1).reduce((s, p, i) => s + p.distanceTo(points[i]), 0), exact: false }, color); break;
          }
          case 'TEXT': case 'MTEXT': case 'ATTRIB': case 'ATTDEF': object = textMesh(e, color, isDwg); if (!object) skip(type + ' (text unavailable)'); else warnings.add('Drawing text uses a substitute font; formatting, alignment and line wrapping may differ.'); break;
          case 'SOLID': case 'TRACE': case '3DFACE': {
            const points: T.Vector3[] = e.points?.map(v) ?? e.vertices?.map(v) ?? [e.firstCorner, e.secondCorner, e.thirdCorner, e.fourthCorner].filter(Boolean).map(v);
            if (points.length < 3) throw new Error('Invalid face');
            const geometry = new T.BufferGeometry().setFromPoints(points); geometry.setIndex(points.length === 3 ? [0, 1, 2] : type === '3DFACE' ? [0, 1, 2, 0, 2, 3] : [0, 1, 2, 1, 3, 2]); geometry.computeVertexNormals(); geometry.userData.drawing = { family: 'Drawing face', exact: false };
            object = new T.Mesh(geometry, new T.MeshBasicMaterial({ color, side: T.DoubleSide })); applyOcs = type !== '3DFACE'; break;
          }
          case 'POINT': { const p = v(e.position ?? e.location ?? e); object = line([p, p.clone()], { family: 'Point', length: 0, exact: true }, color); break; }
          case 'SEQEND': case 'ENDBLK': break;
          default: skip(type);
        }
        if (object) { object.name = `${type}${e.text ? ': ' + plainText(e.text).slice(0, 60) : ''} · ${layerName}${e.handle ? ' #' + e.handle : ''}`; if (applyOcs) object.applyMatrix4(ocs(e)); group.add(object); }
      } catch (error) { skip(type + ' (' + (error instanceof Error ? error.message : 'invalid entity') + ')'); }
    }
  }
  addEntities(db.entities ?? [], root);
  for (const [type, n] of skipped) warnings.add(`Skipped ${n} ${type}.`);
  const units = unitInfo(Number(db.header?.$INSUNITS ?? db.header?.INSUNITS ?? 0)); root.scale.setScalar(units.scale);
  if (units.label.startsWith('Unitless')) warnings.add('Drawing has no recognized insertion units. Confirm source units before measuring.');
  warnings.add('Curves are tessellated for display and point-to-point measurements. Entity properties retain analytic lengths and radii where available. Linetypes, widths, hatches, embedded images, and paper-space layouts are not reproduced.');
  const doc = fromObject(root, name, units.unit, [...warnings], true); doc.sourceUnit = units.label; return doc;
}

function unparsedDxfWarnings(text: string): string[] {
  const supported = new Set(['LINE', 'LWPOLYLINE', 'POLYLINE', 'VERTEX', 'CIRCLE', 'ARC', 'ELLIPSE', 'SPLINE', 'INSERT', 'TEXT', 'MTEXT', 'SOLID', '3DFACE', 'POINT', 'DIMENSION', 'ATTDEF', 'BLOCK', 'ENDBLK', 'SEQEND']);
  const lines = text.split(/\r?\n/); const counts = new Map<string, number>(); let section = '';
  for (let i = 0; i + 1 < lines.length; i += 2) {
    const code = lines[i].trim(), value = lines[i + 1].trim();
    if (code === '0' && value === 'SECTION' && lines[i + 2]?.trim() === '2') section = lines[i + 3]?.trim() ?? '';
    if (code === '0' && value === 'ENDSEC') section = '';
    if (code === '0' && (section === 'ENTITIES' || section === 'BLOCKS') && !supported.has(value) && value !== 'SECTION') counts.set(value, (counts.get(value) ?? 0) + 1);
  }
  return [...counts].map(([type, count]) => `DXF parser skipped ${count} unsupported ${type} entities.`);
}
export async function importDrawing(buffer: ArrayBuffer, name: string, format: 'dxf' | 'dwg'): Promise<ModelDocument> {
  if (format === 'dxf') {
    const text = new TextDecoder().decode(buffer); if (text.startsWith('AutoCAD Binary DXF')) throw new Error('Binary DXF is not supported. Save this drawing as ASCII DXF or DWG.');
    const data = new DxfParser().parseSync(text); if (!data) throw new Error('DXF parser found no drawing.');
    return drawingFromDatabase(data, name, format, unparsedDxfWarnings(text));
  }
  const db = await new Promise<Database>((resolve, reject) => {
    const worker = new Worker(new URL('../workers/dwg.worker.ts', import.meta.url), { type: 'module' });
    const timer = setTimeout(() => { worker.terminate(); reject(new Error('DWG import exceeded 120 seconds. Try exporting the file as DXF.')); }, 120000);
    const finish = () => { clearTimeout(timer); worker.terminate(); };
    worker.onmessage = ({ data }) => { finish(); data.error ? reject(new Error(data.error)) : resolve(data.result); };
    worker.onerror = event => { finish(); reject(new Error(event.message || 'DWG decoder failed.')); };
    worker.postMessage({ buffer, wasmPath: new URL('wasm', document.baseURI).href }, [buffer]);
  });
  return drawingFromDatabase(db, name, format, ['DWG is decoded locally using LibreDWG. Unsupported or proprietary entities may be omitted.']);
}
