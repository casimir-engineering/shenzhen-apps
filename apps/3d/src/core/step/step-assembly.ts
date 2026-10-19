// Reads the product/occurrence structure of an indexed STEP file: which
// products are assemblies, where each occurrence is placed, and which products
// carry their own shape. Anything outside the plain AP203/AP214 pattern is
// reported as unsupported so the caller can read the file in one piece instead.
import { entityIndex, refsOf, typeOf, type StepIndex } from "./step-index.ts";
import {
  listOf,
  parseRecord,
  parseRecords,
  refOf,
  strOf,
  type StepRecord,
} from "./step-params.ts";

export interface StepOccurrence {
  /** NAUO entity index; occurrences keep the file's NAUO order. */
  nauo: number;
  child: number;
  /** Column-major 4x4 placement of the child in the parent, in millimetres. */
  matrix: number[];
}

export interface StepProduct {
  /** PRODUCT_DEFINITION entity index. */
  pd: number;
  name: string;
  /** Entity indices of the product's shape representations. */
  reps: number[];
  occurrences: StepOccurrence[];
  /** True when the product has geometry of its own (not only placements). */
  hasShape: boolean;
}

export interface StepAssembly {
  products: Map<number, StepProduct>;
  roots: number[];
  /** Number of occurrences, including nested ones. */
  occurrenceCount: number;
}

export type StepAssemblyResult =
  { ok: true; assembly: StepAssembly } | { ok: false; reason: string };

const PLACEMENT_TYPES = new Set([
  "AXIS2_PLACEMENT_3D",
  "AXIS2_PLACEMENT_2D",
  "AXIS1_PLACEMENT",
]);
// Items the kernel reads but never turns into displayable geometry (outline
// and silkscreen curve sets). Products holding only these become empty nodes.
const UNDISPLAYED_TYPES = new Set(["GEOMETRIC_CURVE_SET"]);
const UNSUPPORTED_TYPES = new Set([
  "MAPPED_ITEM",
  "PRESENTATION_STYLE_BY_CONTEXT",
  "CONTEXT_DEPENDENT_OVER_RIDING_STYLED_ITEM",
  "SHAPE_ASPECT_RELATIONSHIP",
  "PRODUCT_DEFINITION_USAGE",
  "ASSEMBLY_COMPONENT_USAGE",
  "SPECIFIED_HIGHER_USAGE_OCCURRENCE",
]);

const rec = (index: StepIndex, k: number) => parseRecord(index, k);
const at = (index: StepIndex, id: number | undefined) =>
  id === undefined ? -1 : entityIndex(index, id);

function findRecord(records: StepRecord[], type: string) {
  return records.find((r) => r.type === type);
}

/** Millimetres per unit of the length unit entity. */
function lengthUnitMm(
  index: StepIndex,
  k: number,
  depth = 0,
): number | undefined {
  if (k < 0 || depth > 4) return undefined;
  const records = parseRecords(index, k);
  const si = findRecord(records, "SI_UNIT");
  if (si && findRecord(records, "LENGTH_UNIT")) {
    const prefix = (si.args[0] as { enum: string } | null)?.enum;
    const scale: Record<string, number> = {
      MILLI: 1,
      CENTI: 10,
      DECI: 100,
      KILO: 1e6,
      MICRO: 1e-3,
      NANO: 1e-6,
    };
    if (!prefix) return 1000;
    return scale[prefix];
  }
  const conv = findRecord(records, "CONVERSION_BASED_UNIT");
  if (conv && findRecord(records, "LENGTH_UNIT")) {
    const m = at(index, refOf(conv.args[1]));
    if (m < 0) return undefined;
    const measure = rec(index, m);
    const value = measure.args[0];
    const v =
      typeof value === "number"
        ? value
        : typeof value === "object" && value && "typed" in value
          ? (value.args[0] as number)
          : NaN;
    const base = lengthUnitMm(
      index,
      at(index, refOf(measure.args[1])),
      depth + 1,
    );
    return Number.isFinite(v) && base !== undefined ? v * base : undefined;
  }
  return undefined;
}

/** Millimetres per model unit for a representation's context. */
function repUnitMm(
  index: StepIndex,
  rep: number,
  cache: Map<number, number | undefined>,
) {
  const refs = refsOf(index, rep);
  const ctx = at(index, refs[refs.length - 1]);
  if (cache.has(ctx)) return cache.get(ctx);
  let result: number | undefined;
  const units =
    ctx >= 0
      ? findRecord(parseRecords(index, ctx), "GLOBAL_UNIT_ASSIGNED_CONTEXT")
      : undefined;
  for (const u of listOf(units?.args[0])) {
    const mm = lengthUnitMm(index, at(index, refOf(u)));
    if (mm !== undefined) result = mm;
  }
  cache.set(ctx, result);
  return result;
}

function vec(index: StepIndex, id: number | undefined): number[] | undefined {
  const k = at(index, id);
  if (k < 0) return undefined;
  const values = listOf(rec(index, k).args[1]);
  return values.length >= 3 && values.every((v) => typeof v === "number")
    ? (values as number[])
    : undefined;
}

/** Column-major matrix of an AXIS2_PLACEMENT_3D, translation scaled to mm. */
export function placementMatrix(
  index: StepIndex,
  k: number,
  mm: number,
): number[] | undefined {
  const r = rec(index, k);
  if (r.type !== "AXIS2_PLACEMENT_3D") return undefined;
  const p = vec(index, refOf(r.args[1]));
  if (!p) return undefined;
  const z = norm(vec(index, refOf(r.args[2])) ?? [0, 0, 1]);
  let x =
    vec(index, refOf(r.args[3])) ??
    (Math.abs(z[0]) < 0.9 ? [1, 0, 0] : [0, 0, 1]);
  const d = dot(x, z);
  x = norm([x[0] - d * z[0], x[1] - d * z[1], x[2] - d * z[2]]);
  const y = [
    z[1] * x[2] - z[2] * x[1],
    z[2] * x[0] - z[0] * x[2],
    z[0] * x[1] - z[1] * x[0],
  ];
  return [...x, 0, ...y, 0, ...z, 0, p[0] * mm, p[1] * mm, p[2] * mm, 1];
}

const dot = (a: number[], b: number[]) =>
  a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
function norm(v: number[]) {
  const l = Math.hypot(v[0], v[1], v[2]) || 1;
  return [v[0] / l, v[1] / l, v[2] / l];
}

/** Inverse of a rigid column-major matrix. */
export function invertRigid(m: number[]): number[] {
  const t = [m[12], m[13], m[14]];
  const r = [m[0], m[4], m[8], 0, m[1], m[5], m[9], 0, m[2], m[6], m[10], 0];
  const tx = -(r[0] * t[0] + r[4] * t[1] + r[8] * t[2]);
  const ty = -(r[1] * t[0] + r[5] * t[1] + r[9] * t[2]);
  const tz = -(r[2] * t[0] + r[6] * t[1] + r[10] * t[2]);
  return [...r, tx, ty, tz, 1];
}

export function multiply(a: number[], b: number[]): number[] {
  const out = new Array<number>(16);
  for (let c = 0; c < 4; c++)
    for (let r = 0; r < 4; r++)
      out[c * 4 + r] =
        a[r] * b[c * 4] +
        a[4 + r] * b[c * 4 + 1] +
        a[8 + r] * b[c * 4 + 2] +
        a[12 + r] * b[c * 4 + 3];
  return out;
}

export function readAssembly(index: StepIndex): StepAssemblyResult {
  const byType = new Map<string, number[]>();
  for (let k = 0; k < index.count; k++) {
    const t = typeOf(index, k);
    if (UNSUPPORTED_TYPES.has(t)) return { ok: false, reason: t };
    let list = byType.get(t);
    if (!list) byType.set(t, (list = []));
    list.push(k);
  }
  const of = (t: string) => byType.get(t) ?? [];
  const products = new Map<number, StepProduct>();
  for (const pd of [
    ...of("PRODUCT_DEFINITION"),
    ...of("PRODUCT_DEFINITION_WITH_ASSOCIATED_DOCUMENTS"),
  ]) {
    const pdf = at(index, refOf(rec(index, pd).args[2]));
    const product = pdf >= 0 ? at(index, refOf(rec(index, pdf).args[2])) : -1;
    const name =
      product >= 0
        ? strOf(rec(index, product).args[1]) ||
          strOf(rec(index, product).args[0])
        : "";
    products.set(pd, { pd, name, reps: [], occurrences: [], hasShape: false });
  }
  if (!products.size) return { ok: false, reason: "no products" };
  const pdsTarget = new Map<number, number>();
  for (const pds of of("PRODUCT_DEFINITION_SHAPE")) {
    const target = at(index, refOf(rec(index, pds).args[2]));
    if (target >= 0) pdsTarget.set(pds, target);
  }
  for (const sdr of of("SHAPE_DEFINITION_REPRESENTATION")) {
    const [pdsId, repId] = refsOf(index, sdr);
    const target = pdsTarget.get(at(index, pdsId));
    const product = target === undefined ? undefined : products.get(target);
    if (product) product.reps.push(at(index, repId));
  }
  // Placement links: NAUO -> CDSR -> representation relationship with transformation.
  const cdsrByNauo = new Map<number, number>();
  for (const cdsr of of("CONTEXT_DEPENDENT_SHAPE_REPRESENTATION")) {
    const [rr, pds] = refsOf(index, cdsr);
    const nauo = pdsTarget.get(at(index, pds));
    if (nauo !== undefined) cdsrByNauo.set(nauo, at(index, rr));
  }
  const unitCache = new Map<number, number | undefined>();
  const childOf = new Set<number>();
  let occurrenceCount = 0;
  for (const nauo of of("NEXT_ASSEMBLY_USAGE_OCCURRENCE")) {
    const r = rec(index, nauo);
    const parent = products.get(at(index, refOf(r.args[3])));
    const child = at(index, refOf(r.args[4]));
    if (!parent || !products.has(child))
      return { ok: false, reason: "dangling occurrence" };
    const rr = cdsrByNauo.get(nauo);
    if (rr === undefined)
      return { ok: false, reason: "occurrence without placement" };
    const records = parseRecords(index, rr);
    const rel = findRecord(records, "REPRESENTATION_RELATIONSHIP");
    const withT = findRecord(
      records,
      "REPRESENTATION_RELATIONSHIP_WITH_TRANSFORMATION",
    );
    const idt = withT ? at(index, refOf(withT.args[0])) : -1;
    if (!rel || idt < 0 || typeOf(index, idt) !== "ITEM_DEFINED_TRANSFORMATION")
      return { ok: false, reason: "unsupported placement" };
    let rep1 = at(index, refOf(rel.args[2])),
      rep2 = at(index, refOf(rel.args[3]));
    const t = rec(index, idt);
    let item1 = at(index, refOf(t.args[2])),
      item2 = at(index, refOf(t.args[3]));
    // rep_1 normally belongs to the child. Some writers reverse the pair.
    const childReps = products.get(child)!.reps;
    if (!childReps.includes(rep1) && childReps.includes(rep2)) {
      [rep1, rep2] = [rep2, rep1];
      [item1, item2] = [item2, item1];
    }
    const mm1 = repUnitMm(index, rep1, unitCache),
      mm2 = repUnitMm(index, rep2, unitCache);
    if (mm1 === undefined || mm2 === undefined)
      return { ok: false, reason: "unknown length unit" };
    const a = placementMatrix(index, item1, mm1),
      b = placementMatrix(index, item2, mm2);
    if (!a || !b) return { ok: false, reason: "unsupported placement" };
    parent.occurrences.push({
      nauo,
      child,
      matrix: multiply(b, invertRigid(a)),
    });
    childOf.add(child);
    occurrenceCount++;
  }
  for (const product of products.values())
    product.hasShape = hasOwnShape(index, product, byType);
  for (const product of products.values())
    if (product.occurrences.length && product.hasShape)
      return { ok: false, reason: "assembly with its own shape" };
  const roots = [...products.keys()].filter(
    (pd) => !childOf.has(pd) && products.get(pd)!.reps.length,
  );
  if (!roots.length) return { ok: false, reason: "no root product" };
  if (hasCycle(products, roots))
    return { ok: false, reason: "cyclic assembly" };
  return { ok: true, assembly: { products, roots, occurrenceCount } };
}

/** A representation group carries shape when any item is not a bare placement. */
function hasOwnShape(
  index: StepIndex,
  product: StepProduct,
  byType: Map<string, number[]>,
) {
  for (const rep of linkedReps(index, product.reps, byType))
    for (const id of itemsOf(index, rep)) {
      const k = at(index, id);
      if (
        k >= 0 &&
        !PLACEMENT_TYPES.has(typeOf(index, k)) &&
        !UNDISPLAYED_TYPES.has(typeOf(index, k))
      )
        return true;
    }
  return false;
}

/** Item references of a representation (all refs except the trailing context). */
export function itemsOf(index: StepIndex, rep: number) {
  const refs = refsOf(index, rep);
  return refs.subarray(0, Math.max(0, refs.length - 1));
}

const relationCache = new WeakMap<StepIndex, Map<number, number[]>>();
/** Representations joined to `reps` by plain (non-occurrence) shape relationships. */
export function linkedReps(
  index: StepIndex,
  reps: number[],
  byType?: Map<string, number[]>,
): number[] {
  let links = relationCache.get(index);
  if (!links) {
    links = new Map();
    const candidates = byType
      ? [
          ...(byType.get("SHAPE_REPRESENTATION_RELATIONSHIP") ?? []),
          ...(byType.get("(COMPLEX)") ?? []),
        ]
      : Array.from({ length: index.count }, (_, k) => k);
    for (const k of candidates) {
      const t = typeOf(index, k);
      if (t !== "SHAPE_REPRESENTATION_RELATIONSHIP" && t !== "(COMPLEX)")
        continue;
      const records = parseRecords(index, k);
      const rel =
        findRecord(records, "REPRESENTATION_RELATIONSHIP") ??
        findRecord(records, "SHAPE_REPRESENTATION_RELATIONSHIP");
      if (
        !rel ||
        findRecord(records, "REPRESENTATION_RELATIONSHIP_WITH_TRANSFORMATION")
      )
        continue;
      const a = at(index, refOf(rel.args[2])),
        b = at(index, refOf(rel.args[3]));
      if (a < 0 || b < 0) continue;
      (links.get(a) ?? links.set(a, []).get(a)!).push(b, k);
      (links.get(b) ?? links.set(b, []).get(b)!).push(a, k);
    }
    relationCache.set(index, links);
  }
  const seen = new Set(reps),
    queue = [...reps];
  while (queue.length) {
    const rep = queue.pop()!;
    const linked = links.get(rep) ?? [];
    for (let i = 0; i < linked.length; i += 2)
      if (!seen.has(linked[i])) {
        seen.add(linked[i]);
        queue.push(linked[i]);
      }
  }
  return [...seen];
}

/** Plain shape relationships (entity indices) touching any of `reps`. */
export function relationsOf(index: StepIndex, reps: number[]): number[] {
  linkedReps(index, reps);
  const links = relationCache.get(index)!,
    out = new Set<number>();
  for (const rep of reps) {
    const linked = links.get(rep) ?? [];
    for (let i = 1; i < linked.length; i += 2) out.add(linked[i]);
  }
  return [...out];
}

function hasCycle(products: Map<number, StepProduct>, roots: number[]) {
  const state = new Map<number, number>();
  const visit = (pd: number): boolean => {
    const s = state.get(pd);
    if (s === 1) return true;
    if (s === 2) return false;
    state.set(pd, 1);
    for (const o of products.get(pd)!.occurrences)
      if (visit(o.child)) return true;
    state.set(pd, 2);
    return false;
  };
  return roots.some(visit);
}
