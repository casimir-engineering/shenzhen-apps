import { Zip, ZipDeflate, AsyncZipDeflate, AsyncInflate, strToU8 } from 'fflate';
import type { GeometryData, Measurement, ModelDocument, Part, Pick, Unit, Vec3 } from './types';
import { createId } from './id';

export interface ReviewNote {
  id: string;
  text: string;
  createdAt: string;
  updatedAt: string;
  resolved: boolean;
  scope: 'point' | 'feature' | 'part';
  anchor: Pick;
}
export type ProjectQuality = 'fast' | 'balanced' | 'fine';
export interface ProjectInput {
  doc: ModelDocument;
  files: readonly File[];
  notes?: readonly ReviewNote[];
  measurements?: readonly Measurement[];
  source: Unit;
  unit: Unit;
  scale: number;
  quality: string;
  demo: boolean;
}
export interface ProjectMetadata {
  version: 1;
  name: string;
  createdAt: string;
  source: Unit;
  unit: Unit;
  scale: number;
  quality: ProjectQuality;
  demo: boolean;
}
interface SourceEntry { path: string; name: string; type: string; lastModified: number; size: number; sha256: string }
interface PartBinding {
  partIndex: number;
  name: string;
  path: string[];
  matrix: number[];
  geometry: { sha256: string; vertices: number; indices: number; cad: boolean; lines: boolean };
}
interface FeatureBinding { kind: 'face' | 'edge' | 'vertex'; index: number; signature: string }
type StoredPick = Omit<Pick, 'id' | 'partId' | 'partName' | 'geometryId' | 'exactHandle' | 'matrix' | 'elementId'> & { binding: number; elementIndex?: number; feature?: FeatureBinding };
type StoredNote = Omit<ReviewNote, 'anchor'> & { anchor: StoredPick };
type StoredMeasurement = Omit<Measurement, 'points'> & { points: StoredPick[] };
interface Manifest {
  format: 'shenzhen-3d/project';
  metadata: ProjectMetadata;
  sources: SourceEntry[];
  partCount: number;
  geometryCount: number;
  bindings: PartBinding[];
  notes: StoredNote[];
  measurements: StoredMeasurement[];
}
export interface ProjectData {
  files: File[];
  demo: boolean;
  quality: ProjectQuality;
  metadata: ProjectMetadata;
  /** Validated portable data; runtime geometry and exact handles are never archived. */
  readonly manifest: Manifest;
}
export interface RestoredProjectState {
  notes: ReviewNote[];
  measurements: Measurement[];
  source: Unit;
  unit: Unit;
  scale: number;
  quality: ProjectQuality;
  demo: boolean;
  warnings: string[];
}
export const PROJECT_LIMITS = Object.freeze({ archiveBytes: 256 * 1024 * 1024, expandedBytes: 512 * 1024 * 1024, fileBytes: 256 * 1024 * 1024, manifestBytes: 8 * 1024 * 1024, files: 256, notes: 2000, measurements: 1000, bindings: 10000 });
const units = new Set(['mm', 'cm', 'm', 'in', 'ft', 'um']);
const qualities = new Set(['fast', 'balanced', 'fine']);
const hashPattern = /^[a-f0-9]{64}$/;
const decoder = new TextDecoder('utf-8', { fatal: true });

function fail(message: string): never { throw new Error(`Invalid Shenzhen 3D project: ${message}`); }
function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) fail('expected an object');
  return value as Record<string, unknown>;
}
function text(value: unknown, maximum = 512, multiline = false): string {
  if (typeof value !== 'string' || value.length > maximum || (multiline ? /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/ : /[\x00-\x1f\x7f]/).test(value)) fail('invalid or oversized text');
  return value;
}
function number(value: unknown, minimum = -1e15, maximum = 1e15): number {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < minimum || value > maximum) fail('number outside supported range');
  return value;
}
function integer(value: unknown, maximum = 1e9): number { const n = number(value, 0, maximum); if (!Number.isInteger(n)) fail('expected an integer'); return n; }
function boolean(value: unknown): boolean { if (typeof value !== 'boolean') fail('expected a boolean'); return value; }
function array(value: unknown, maximum: number): unknown[] { if (!Array.isArray(value) || value.length > maximum) fail('too many entries'); return value; }
function vector(value: unknown): Vec3 { const a = array(value, 3); if (a.length !== 3) fail('invalid coordinate'); return a.map(v => number(v)) as Vec3; }
function matrix(value: unknown): number[] { const a = array(value, 16); if (a.length !== 16) fail('invalid transform'); return a.map(v => number(v)); }
function date(value: unknown): string { const result = text(value, 40); if (!/^\d{4}-\d\d-\d\dT/.test(result) || !Number.isFinite(Date.parse(result))) fail('invalid timestamp'); return result; }
function hash(value: unknown): string { const result = text(value, 64); if (!hashPattern.test(result)) fail('invalid digest'); return result; }
function safeName(value: unknown): string { const result = text(value, 256); if (!result || result === '.' || result === '..' || /[/\\:]/.test(result)) fail('unsafe source filename'); return result; }
async function sha256(bytes: Uint8Array): Promise<string> {
  const input = bytes.buffer instanceof ArrayBuffer ? bytes as Uint8Array<ArrayBuffer> : Uint8Array.from(bytes);
  return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', input)), value => value.toString(16).padStart(2, '0')).join('');
}
const stringHash = (value: unknown) => sha256(strToU8(JSON.stringify(value)));
function rawBytes(values: ArrayBufferView): Uint8Array { return new Uint8Array(values.buffer, values.byteOffset, values.byteLength); }
async function geometryBinding(data: GeometryData): Promise<PartBinding['geometry']> {
  const position = data.geometry.getAttribute('position');
  if (!position) fail('anchor geometry has no positions');
  const index = data.geometry.index;
  const [positions, indices] = await Promise.all([sha256(rawBytes(position.array)), index ? sha256(rawBytes(index.array)) : Promise.resolve('none')]);
  const attributes = { count: position.count, size: position.itemSize, type: position.array.constructor.name, normalized: position.normalized, ...('data' in position ? { stride: position.data.stride, offset: position.offset } : {}) };
  return { sha256: await stringHash({ positions, indices, attributes, groups: data.geometry.groups, indexType: index?.array.constructor.name }), vertices: position.count, indices: index?.count ?? 0, cad: !!data.topology, lines: !!data.lines };
}
async function featureSignature(data: GeometryData, kind: FeatureBinding['kind'], index: number): Promise<string> {
  const topology = data.topology;
  if (!topology) fail('feature topology is missing');
  if (kind === 'face') {
    const face = topology.faces[index];
    if (!face) fail('face no longer exists');
    return stringHash([face.firstIndex, face.indexCount]);
  }
  if (kind === 'edge') {
    const edge = topology.edges[index];
    if (!edge) fail('edge no longer exists');
    return sha256(rawBytes(edge.points));
  }
  const vertex = topology.vertices[index];
  if (!vertex) fail('vertex no longer exists');
  return stringHash(vertex.position);
}

function validatePick(value: unknown, bindings: number): StoredPick {
  const p = object(value);
  const kind = text(p.kind, 10);
  if (!['point', 'face', 'edge', 'vertex'].includes(kind)) fail('invalid pick kind');
  const result: StoredPick = { binding: integer(p.binding, Math.max(0, bindings - 1)), point: vector(p.point), localPoint: vector(p.localPoint), kind: kind as Pick['kind'], snap: text(p.snap, 256) };
  if (!bindings) fail('pick has no part binding');
  if (p.triangleIndex !== undefined) result.triangleIndex = integer(p.triangleIndex);
  if (p.elementIndex !== undefined) result.elementIndex = integer(p.elementIndex);
  if (p.feature !== undefined) {
    const f = object(p.feature), featureKind = text(f.kind, 10);
    if (!['face', 'edge', 'vertex'].includes(featureKind) || featureKind !== kind) fail('invalid feature binding');
    result.feature = { kind: featureKind as FeatureBinding['kind'], index: integer(f.index), signature: hash(f.signature) };
  }
  return result;
}
function validateManifest(value: unknown): Manifest {
  const m = object(value), metadata = object(m.metadata);
  if (m.format !== 'shenzhen-3d/project' || metadata.version !== 1) fail('unsupported project format/version');
  const source = text(metadata.source, 4), unit = text(metadata.unit, 4), quality = text(metadata.quality, 16);
  if (!units.has(source) || !units.has(unit) || !qualities.has(quality)) fail('unsupported units or import quality');
  const meta: ProjectMetadata = { version: 1, name: text(metadata.name, 1024), createdAt: date(metadata.createdAt), source: source as Unit, unit: unit as Unit, scale: number(metadata.scale, Number.MIN_VALUE, 1e12), quality: quality as ProjectQuality, demo: boolean(metadata.demo) };
  const sources = array(m.sources, PROJECT_LIMITS.files).map(value => {
    const f = object(value), path = text(f.path, 32);
    if (!/^files\/\d{6}$/.test(path)) fail('unsafe archive source path');
    return { path, name: safeName(f.name), type: text(f.type, 128), lastModified: integer(f.lastModified, 8.64e15), size: integer(f.size, PROJECT_LIMITS.fileBytes), sha256: hash(f.sha256) };
  });
  if (new Set(sources.map(f => f.path)).size !== sources.length || new Set(sources.map(f => f.name.normalize('NFC').toLowerCase())).size !== sources.length || (!meta.demo && !sources.length) || (meta.demo && sources.length)) fail('invalid or ambiguous source file list');
  if (sources.reduce((sum, f) => sum + f.size, 0) > PROJECT_LIMITS.expandedBytes) fail('source files exceed size limit');
  const partCount = integer(m.partCount, 10_000_000), geometryCount = integer(m.geometryCount, 1_000_000);
  const bindings = array(m.bindings, PROJECT_LIMITS.bindings).map(value => {
    const p = object(value), g = object(p.geometry);
    return { partIndex: integer(p.partIndex, Math.max(0, partCount - 1)), name: text(p.name, 1024), path: array(p.path, 128).map(value => text(value, 1024)), matrix: matrix(p.matrix), geometry: { sha256: hash(g.sha256), vertices: integer(g.vertices), indices: integer(g.indices), cad: boolean(g.cad), lines: boolean(g.lines) } };
  });
  if ((!partCount && bindings.length) || new Set(bindings.map(p => p.partIndex)).size !== bindings.length) fail('invalid or duplicate part bindings');
  const notes = array(m.notes ?? [], PROJECT_LIMITS.notes).map(value => {
    const n = object(value), scope = text(n.scope, 10);
    if (!['point', 'feature', 'part'].includes(scope)) fail('invalid note scope');
    return { id: text(n.id, 128), text: text(n.text, 16000, true), createdAt: date(n.createdAt), updatedAt: date(n.updatedAt), resolved: boolean(n.resolved), scope: scope as ReviewNote['scope'], anchor: validatePick(n.anchor, bindings.length) };
  });
  if (new Set(notes.map(n => n.id)).size !== notes.length) fail('duplicate note IDs');
  const measurements = array(m.measurements ?? [], PROJECT_LIMITS.measurements).map(value => {
    const item = object(value), kind = text(item.kind, 12), reference = item.reference;
    if (!['distance', 'angle', 'path'].includes(kind) || (reference !== undefined && !['minimum', 'center', 'picked'].includes(reference as string))) fail('invalid measurement kind/reference');
    const points = array(item.points, 3).map(value => validatePick(value, bindings.length));
    if (points.length !== (kind === 'angle' ? 3 : 2)) fail('invalid measurement point count');
    const result: StoredMeasurement = { id: text(item.id, 128), name: text(item.name, 1024), kind: kind as Measurement['kind'], points, exact: boolean(item.exact), note: text(item.note, 16000, true) };
    if (reference !== undefined) result.reference = reference as Measurement['reference'];
    for (const field of ['distance', 'surfaceLength'] as const) if (item[field] !== undefined) result[field] = number(item[field], 0);
    if (item.angle !== undefined) result.angle = number(item.angle, 0, 180);
    if (item.delta !== undefined) result.delta = vector(item.delta);
    if (item.path !== undefined) result.path = array(item.path, 100000).map(vector);
    return result;
  });
  if (new Set(measurements.map(m => m.id)).size !== measurements.length) fail('duplicate measurement IDs');
  return { format: 'shenzhen-3d/project', metadata: meta, sources, partCount, geometryCount, bindings, notes, measurements };
}

/** Stores original inputs once; geometry/vertices and native exact handles are never duplicated in the archive. */
export async function exportProject(input: ProjectInput): Promise<Blob> {
  const { doc, files } = input;
  if ((input.notes?.length ?? 0) > PROJECT_LIMITS.notes || (input.measurements?.length ?? 0) > PROJECT_LIMITS.measurements) fail('too many notes or measurements');
  if (new Set(files.map(file => safeName(file.name).normalize('NFC').toLowerCase())).size !== files.length) fail('ambiguous source file list');
  if (files.length > PROJECT_LIMITS.files || files.some(f => f.size > PROJECT_LIMITS.fileBytes) || files.reduce((sum, f) => sum + f.size, 0) > PROJECT_LIMITS.expandedBytes) fail('source files exceed size/count limits');
  const bindings: PartBinding[] = [], bindingIds = new Map<string, number>(), geometryHashes = new Map<string, Promise<PartBinding['geometry']>>();
  const indices = new Map(doc.parts.map((part, index) => [part.id, index]));
  const storePick = async (pick: Pick): Promise<StoredPick> => {
    const partIndex = indices.get(pick.partId);
    if (partIndex === undefined) fail('annotation references a missing part');
    const part = doc.parts[partIndex], data = doc.geometries.get(part.geometryId);
    if (!data || pick.geometryId !== part.geometryId) fail('annotation geometry does not match its part');
    let binding = bindingIds.get(part.id);
    if (binding === undefined) {
      if (!geometryHashes.has(part.geometryId)) geometryHashes.set(part.geometryId, geometryBinding(data));
      binding = bindings.length;
      bindings.push({ partIndex, name: part.name, path: [...part.path], matrix: [...part.matrix], geometry: await geometryHashes.get(part.geometryId)! });
      bindingIds.set(part.id, binding);
    }
    const stored: StoredPick = { binding, point: [...pick.point], localPoint: [...pick.localPoint], kind: pick.kind, snap: pick.snap };
    if (pick.triangleIndex !== undefined) stored.triangleIndex = pick.triangleIndex;
    if (pick.kind !== 'point' && data.topology) {
      const list = pick.kind === 'face' ? data.topology.faces : pick.kind === 'edge' ? data.topology.edges : data.topology.vertices;
      const index = list.findIndex(feature => feature.id === pick.elementId);
      if (index < 0) fail('annotation feature is missing');
      stored.feature = { kind: pick.kind, index, signature: await featureSignature(data, pick.kind, index) };
    } else if (pick.elementId !== undefined) stored.elementIndex = pick.elementId;
    return stored;
  };
  const notes: StoredNote[] = [];
  for (const note of input.notes ?? []) notes.push({ ...note, anchor: await storePick(note.anchor) });
  const measurements: StoredMeasurement[] = [];
  for (const measurement of input.measurements ?? []) {
    const points: StoredPick[] = [];
    for (const pick of measurement.points) points.push(await storePick(pick));
    measurements.push({ ...measurement, points });
  }
  const chunks: Uint8Array<ArrayBuffer>[] = [], sources: SourceEntry[] = [];
  let total = 0, fatal: Error | undefined, rejectCurrent: ((error: Error) => void) | undefined;
  const writer = new Zip((error, chunk) => {
    if (error) fatal = error;
    else if ((total += chunk.length) > PROJECT_LIMITS.archiveBytes) fatal = new Error('Project archive exceeds size limit');
    else chunks.push(chunk);
    if (fatal) rejectCurrent?.(fatal);
  });
  const add = (path: string, bytes: Uint8Array) => new Promise<void>((resolve, reject) => {
    const stream = bytes.length >= 160000 ? new AsyncZipDeflate(path, { level: 1 }) : new ZipDeflate(path, { level: 1 });
    writer.add(stream);
    const send = stream.ondata;
    let offset = 0;
    rejectCurrent = reject;
    stream.ondata = (error, chunk, final) => {
      send(error, chunk, final);
      if (fatal || error) reject(fatal ?? error!);
      else if (final) { if ('terminate' in stream) stream.terminate(); resolve(); }
    };
    void (async () => {
      if (bytes.length < 160000) { stream.push(bytes, true); return; }
      while (offset < bytes.length) {
        if (fatal) throw fatal;
        const end = Math.min(bytes.length, offset + 65536);
        stream.push(bytes.slice(offset, end), end === bytes.length);
        offset = end;
        // Keep CRC work and queued worker buffers bounded while yielding UI.
        if (offset < bytes.length) await new Promise(resolve => setTimeout(resolve, 0));
      }
    })().catch(reject);
  });
  try {
    // Process one source at a time, with bounded worker chunks. This avoids
    // spawning a worker per companion and never transfers live model buffers.
    for (let i = 0; i < files.length; i++) {
      const file = files[i], bytes = new Uint8Array(await file.arrayBuffer()), path = `files/${String(i).padStart(6, '0')}`;
      sources.push({ path, name: file.name, type: file.type, lastModified: file.lastModified, size: bytes.length, sha256: await sha256(bytes) });
      await add(path, bytes);
    }
    const manifest = validateManifest({ format: 'shenzhen-3d/project', metadata: { version: 1, name: doc.name, createdAt: new Date().toISOString(), source: input.source, unit: input.unit, scale: input.scale, quality: input.quality, demo: input.demo }, sources, partCount: doc.parts.length, geometryCount: doc.geometries.size, bindings, notes, measurements });
    const metadata = strToU8(JSON.stringify(manifest));
    if (metadata.length > PROJECT_LIMITS.manifestBytes || sources.reduce((sum, source) => sum + source.size, 0) + metadata.length > PROJECT_LIMITS.expandedBytes) fail('manifest/archive expansion exceeds size limit');
    await add('manifest.json', metadata);
    writer.end();
    if (fatal) throw fatal;
    return new Blob(chunks, { type: 'application/vnd.shenzhen3d.project+zip' });
  } catch (error) { writer.terminate(); throw error; }
}

/** Validate ZIP directory sizes/paths before any decompressor allocates output. ZIP64/encryption are intentionally unsupported. */
interface ArchiveEntry { expanded: number; compressed: number; start: number; method: number; crc: number }
function inspectArchive(bytes: Uint8Array): Map<string, ArchiveEntry> {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength), size = bytes.length;
  if (size < 22) fail('truncated ZIP');
  let end = size - 22;
  for (; end >= Math.max(0, size - 65557); end--) if (view.getUint32(end, true) === 0x06054b50 && end + 22 + view.getUint16(end + 20, true) === size) break;
  if (end < Math.max(0, size - 65557)) fail('missing ZIP directory');
  const count = view.getUint16(end + 10, true), directorySize = view.getUint32(end + 12, true), directory = view.getUint32(end + 16, true);
  if (view.getUint16(end + 4, true) || view.getUint16(end + 6, true) || view.getUint16(end + 8, true) !== count || !count || count > PROJECT_LIMITS.files + 1 || directory + directorySize !== end) fail('unsupported ZIP directory');
  const entries = new Map<string, ArchiveEntry>(), spans: [number, number][] = [];
  let offset = directory, total = 0;
  for (let i = 0; i < count; i++) {
    if (offset + 46 > end || view.getUint32(offset, true) !== 0x02014b50) fail('corrupt ZIP entry');
    const flags = view.getUint16(offset + 8, true), method = view.getUint16(offset + 10, true), compressed = view.getUint32(offset + 20, true), expanded = view.getUint32(offset + 24, true);
    const nameLength = view.getUint16(offset + 28, true), extraLength = view.getUint16(offset + 30, true), commentLength = view.getUint16(offset + 32, true), local = view.getUint32(offset + 42, true);
    if (!nameLength || nameLength > 512 || offset + 46 + nameLength + extraLength + commentLength > end || flags & ~(2048 | 8 | 6) || ![0, 8].includes(method) || expanded > PROJECT_LIMITS.fileBytes || (view.getUint32(offset + 38, true) >>> 16 & 0xf000) === 0xa000) fail('unsupported or oversized ZIP entry');
    const name = decoder.decode(bytes.subarray(offset + 46, offset + 46 + nameLength));
    if (name !== 'manifest.json' && !/^files\/\d{6}$/.test(name)) fail('unsafe or unknown archive path');
    if (entries.has(name) || (name === 'manifest.json' && expanded > PROJECT_LIMITS.manifestBytes)) fail('duplicate or oversized manifest');
    total += expanded;
    if (total > PROJECT_LIMITS.expandedBytes) fail('archive expansion exceeds limit');
    if (local + 30 > directory || view.getUint32(local, true) !== 0x04034b50 || view.getUint16(local + 6, true) !== flags || view.getUint16(local + 8, true) !== method) fail('corrupt local ZIP header');
    const localNameLength = view.getUint16(local + 26, true), start = local + 30 + localNameLength + view.getUint16(local + 28, true);
    if (start + compressed > directory || decoder.decode(bytes.subarray(local + 30, local + 30 + localNameLength)) !== name) fail('inconsistent ZIP entry');
    if (!(flags & 8) && (view.getUint32(local + 18, true) !== compressed || view.getUint32(local + 22, true) !== expanded || view.getUint32(local + 14, true) !== view.getUint32(offset + 16, true))) fail('inconsistent local ZIP sizes/checksum');
    if (method === 0 && compressed !== expanded) fail('inconsistent stored ZIP sizes');
    spans.push([local, start + compressed]);
    entries.set(name, { expanded, compressed, start, method, crc: view.getUint32(offset + 16, true) });
    offset += 46 + nameLength + extraLength + commentLength;
  }
  if (offset !== end || !entries.has('manifest.json')) fail('incomplete ZIP directory');
  spans.sort((a, b) => a[0] - b[0]);
  if (spans[0][0] !== 0 || spans.some((span, i) => i > 0 && span[0] < spans[i - 1][1])) fail('overlapping ZIP entries');
  return entries;
}

const crcTable = new Uint32Array(256);
for (let i = 0; i < 256; i++) { let value = i; for (let bit = 0; bit < 8; bit++) value = value & 1 ? 0xedb88320 ^ value >>> 1 : value >>> 1; crcTable[i] = value; }
async function verifyCrc(bytes: Uint8Array, expected: number): Promise<void> {
  let crc = 0xffffffff;
  for (let offset = 0; offset < bytes.length; offset += 1024 * 1024) {
    const end = Math.min(bytes.length, offset + 1024 * 1024);
    for (let i = offset; i < end; i++) crc = crcTable[(crc ^ bytes[i]) & 255] ^ crc >>> 8;
    if (end < bytes.length) await new Promise(resolve => setTimeout(resolve, 0));
  }
  if ((crc ^ 0xffffffff) >>> 0 !== expected) fail('ZIP checksum mismatch');
}

async function expandEntry(bytes: Uint8Array, entry: ArchiveEntry): Promise<Uint8Array<ArrayBuffer>> {
  if (entry.method === 0) return bytes.slice(entry.start, entry.start + entry.compressed);
  return new Promise((resolve, reject) => {
    const chunks: Uint8Array[] = [];
    let length = 0, offset = entry.start, stopped = false;
    const end = entry.start + entry.compressed;
    const stream = new AsyncInflate((error, chunk, final) => {
      if (stopped) return;
      if (error || (length += chunk.length) > entry.expanded) {
        stopped = true;
        stream.terminate();
        reject(error ?? new Error('Archive expanded beyond its declared size'));
        return;
      }
      chunks.push(chunk);
      if (final) {
        stopped = true;
        stream.terminate();
        if (length !== entry.expanded) { reject(new Error('Archive expanded size mismatch')); return; }
        const output = new Uint8Array(length);
        let cursor = 0;
        for (const data of chunks) { output.set(data, cursor); cursor += data.length; }
        resolve(output);
      }
    });
    const push = () => {
      if (stopped) return;
      const next = Math.min(end, offset + 65536), chunk = bytes.slice(offset, next);
      offset = next;
      stream.push(chunk, next === end);
    };
    stream.ondrain = () => { if (offset < end) push(); };
    push();
  });
}

export async function readProject(file: File): Promise<ProjectData> {
  if (file.size > PROJECT_LIMITS.archiveBytes) fail('archive exceeds size limit');
  const bytes = new Uint8Array(await file.arrayBuffer()), entries = inspectArchive(bytes);
  let raw: unknown;
  const metadata = await expandEntry(bytes, entries.get('manifest.json')!);
  await verifyCrc(metadata, entries.get('manifest.json')!.crc);
  try { raw = JSON.parse(decoder.decode(metadata)); } catch { fail('invalid manifest JSON'); }
  const manifest = validateManifest(raw);
  if (entries.size !== manifest.sources.length + 1) fail('unlisted archive files');
  const files: File[] = [];
  for (const entry of manifest.sources) {
    const archived = entries.get(entry.path);
    if (!archived || archived.expanded !== entry.size) fail('source file size mismatch');
    const data = await expandEntry(bytes, archived);
    await verifyCrc(data, archived.crc);
    if (await sha256(data) !== entry.sha256) fail('source file digest mismatch');
    files.push(new File([data], entry.name, { type: entry.type, lastModified: entry.lastModified }));
  }
  return { files, demo: manifest.metadata.demo, quality: manifest.metadata.quality, metadata: manifest.metadata, manifest };
}

function samePart(binding: PartBinding, part: Part, geometry: PartBinding['geometry']): boolean {
  return binding.name === part.name && JSON.stringify(binding.path) === JSON.stringify(part.path) && binding.matrix.every((value, i) => value === part.matrix[i]) && JSON.stringify(binding.geometry) === JSON.stringify(geometry);
}

/** Rebind only verified structural/index matches. Never guess across changed imports or persist native handles. */
export async function restoreProjectState(data: ProjectData, doc: ModelDocument): Promise<RestoredProjectState> {
  const manifest = validateManifest(data.manifest), metadata = manifest.metadata, warnings: string[] = [];
  const result: RestoredProjectState = { notes: [], measurements: [], source: metadata.source, unit: metadata.unit, scale: metadata.scale, quality: metadata.quality, demo: metadata.demo, warnings };
  const matches = new Map<number, { part: Part; geometry: GeometryData }>();
  const geometryHashes = new Map<string, Promise<PartBinding['geometry']>>();
  if (doc.parts.length === manifest.partCount && doc.geometries.size === manifest.geometryCount) {
    for (let i = 0; i < manifest.bindings.length; i++) {
      const binding = manifest.bindings[i], part = doc.parts[binding.partIndex], geometry = part && doc.geometries.get(part.geometryId);
      if (!geometry) continue;
      if (!geometryHashes.has(part.geometryId)) geometryHashes.set(part.geometryId, geometryBinding(geometry));
      if (samePart(binding, part, await geometryHashes.get(part.geometryId)!)) matches.set(i, { part, geometry });
    }
  }
  const restorePick = async (stored: StoredPick): Promise<Pick | undefined> => {
    const match = matches.get(stored.binding);
    if (!match) return;
    const { part, geometry } = match;
    const triangleCount = (geometry.geometry.index?.count ?? geometry.geometry.getAttribute('position').count) / 3;
    if (stored.triangleIndex !== undefined && stored.triangleIndex >= triangleCount) return;
    let elementId = stored.elementIndex;
    if (stored.feature) {
      const feature = stored.feature;
      try { if (!geometry.topology || await featureSignature(geometry, feature.kind, feature.index) !== feature.signature) return; } catch { return; }
      const list = feature.kind === 'face' ? geometry.topology!.faces : feature.kind === 'edge' ? geometry.topology!.edges : geometry.topology!.vertices;
      elementId = list[feature.index].id;
      if (feature.kind === 'face' && stored.triangleIndex !== undefined && geometry.topology!.triangleToFaceMap[stored.triangleIndex] !== elementId) return;
    } else if (geometry.topology && stored.kind !== 'point') return;
    else if (stored.kind === 'face') { if (stored.triangleIndex === undefined) return; elementId = stored.triangleIndex; }
    else if (elementId !== undefined && elementId >= geometry.geometry.getAttribute('position').count) return;
    const { binding: _binding, elementIndex: _elementIndex, feature: _feature, ...pick } = stored;
    return { ...pick, id: createId(), partId: part.id, partName: part.name, geometryId: part.geometryId, elementId, exactHandle: geometry.exactHandle, matrix: [...part.matrix] };
  };
  for (const note of manifest.notes) {
    const anchor = await restorePick(note.anchor);
    if (anchor) result.notes.push({ ...note, anchor });
    else warnings.push(`Note “${note.id}” was not restored because its original part or feature changed.`);
  }
  for (const measurement of manifest.measurements) {
    const points = await Promise.all(measurement.points.map(restorePick));
    if (points.every((point): point is Pick => !!point)) result.measurements.push({ ...measurement, points });
    else warnings.push(`Measurement “${measurement.id}” was not restored because its original part or feature changed.`);
  }
  return result;
}
