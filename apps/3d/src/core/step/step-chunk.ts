// Cuts one product out of an indexed STEP file as a small standalone STEP file:
// its product records, shape representations, everything they reference, and
// the colour styles attached to those shapes. Bytes are copied, not re-encoded.
import { entityIndex, refsOf, typeOf, type StepIndex } from "./step-index.ts";
import { linkedReps, relationsOf, type StepProduct } from "./step-assembly.ts";
import { parseRecord, refOf } from "./step-params.ts";

const STYLE_TYPES = new Set(["STYLED_ITEM", "OVER_RIDING_STYLED_ITEM"]);
// Records that describe something already kept (sub-shape names, colours,
// validation properties). They point at what they describe, so they are found
// through reverse references.
const DESCRIBING_TYPES = new Set([
  ...STYLE_TYPES,
  "SHAPE_ASPECT",
  "PROPERTY_DEFINITION",
  "PROPERTY_DEFINITION_REPRESENTATION",
  "SHAPE_DEFINITION_REPRESENTATION",
]);
const PRESENTATION_TYPES = new Set([
  "MECHANICAL_DESIGN_GEOMETRIC_PRESENTATION_REPRESENTATION",
  "DRAUGHTING_MODEL",
]);
const encoder = new TextEncoder();
const FOOTER = encoder.encode("ENDSEC;\nEND-ISO-10303-21;\n");

export interface StepLinks {
  pdsByTarget: Map<number, number[]>;
  sdrByPds: Map<number, number[]>;
  /** Describing records keyed by each entity index they reference. */
  describedBy: Map<number, number[]>;
  /** Presentation representation context per styled item. */
  contextByStyle: Map<number, number>;
  protocol: number[];
  nextId: number;
  /** Visit stamps, reused across chunks. */
  stamp: Uint32Array;
  generation: number;
}

export function linkStep(index: StepIndex): StepLinks {
  const at = (id: number | undefined) =>
    id === undefined ? -1 : entityIndex(index, id);
  const push = (map: Map<number, number[]>, key: number, value: number) =>
    (map.get(key) ?? map.set(key, []).get(key)!).push(value);
  const links: StepLinks = {
    pdsByTarget: new Map(),
    sdrByPds: new Map(),
    describedBy: new Map(),
    contextByStyle: new Map(),
    protocol: [],
    nextId: index.ids.reduce((m, id) => (id > m ? id : m), 0) + 1,
    stamp: new Uint32Array(index.count),
    generation: 0,
  };
  for (let k = 0; k < index.count; k++) {
    const t = typeOf(index, k);
    if (t === "PRODUCT_DEFINITION_SHAPE")
      push(links.pdsByTarget, at(refOf(parseRecord(index, k).args[2])), k);
    else if (
      t === "SHAPE_DEFINITION_REPRESENTATION" ||
      t === "CONTEXT_DEPENDENT_SHAPE_REPRESENTATION"
    ) {
      const definition = at(
        refsOf(index, k)[t === "SHAPE_DEFINITION_REPRESENTATION" ? 0 : 1],
      );
      push(links.sdrByPds, definition, k);
      // Sub-shape representations hang off a property definition, not a product.
      if (t === "SHAPE_DEFINITION_REPRESENTATION")
        push(links.describedBy, definition, k);
    } else if (STYLE_TYPES.has(t))
      push(links.describedBy, at(refOf(parseRecord(index, k).args[2])), k);
    else if (DESCRIBING_TYPES.has(t))
      for (const id of refsOf(index, k)) push(links.describedBy, at(id), k);
    else if (PRESENTATION_TYPES.has(t)) {
      const refs = refsOf(index, k);
      const ctx = at(refs[refs.length - 1]);
      for (let i = 0; i < refs.length - 1; i++)
        links.contextByStyle.set(at(refs[i]), ctx);
    } else if (t === "APPLICATION_PROTOCOL_DEFINITION") links.protocol.push(k);
  }
  return links;
}

/** Standalone STEP bytes for one product that has its own shape. */
export function productChunk(
  index: StepIndex,
  links: StepLinks,
  product: StepProduct,
  products?: Map<number, StepProduct>,
): Uint8Array {
  const stamp = links.stamp;
  const generation = ++links.generation;
  const picked: number[] = [];
  const stack: number[] = [];
  const add = (k: number) => {
    if (k < 0 || stamp[k] === generation) return;
    stamp[k] = generation;
    picked.push(k);
    stack.push(k);
  };
  const close = () => {
    while (stack.length) {
      const k = stack.pop()!;
      for (const id of refsOf(index, k)) add(entityIndex(index, id));
    }
  };
  const addProduct = (p: StepProduct) => {
    add(p.pd);
    for (const pds of links.pdsByTarget.get(p.pd) ?? []) {
      add(pds);
      for (const sdr of links.sdrByPds.get(pds) ?? []) add(sdr);
    }
    if (!products) return;
    for (const o of p.occurrences) {
      add(o.nauo);
      for (const pds of links.pdsByTarget.get(o.nauo) ?? []) {
        add(pds);
        for (const cdsr of links.sdrByPds.get(pds) ?? []) add(cdsr);
      }
      addProduct(products.get(o.child)!);
    }
  };
  addProduct(product);
  const allReps: number[] = [];
  const collect = (p: StepProduct) => {
    allReps.push(...p.reps);
    if (products)
      for (const o of p.occurrences) collect(products.get(o.child)!);
  };
  collect(product);
  const reps = linkedReps(index, allReps);
  reps.forEach(add);
  relationsOf(index, reps).forEach(add);
  links.protocol.forEach(add);
  close();
  // Styles, sub-shape names and properties point at what was kept.
  const styles: number[] = [];
  let contextEntity = -1;
  for (let scan = 0; scan < picked.length; scan++) {
    const found = links.describedBy.get(picked[scan]);
    if (!found) continue;
    for (const s of found) {
      if (stamp[s] === generation) continue;
      add(s);
      const ctx = links.contextByStyle.get(s);
      if (ctx === undefined) continue;
      styles.push(s);
      if (contextEntity < 0 && ctx >= 0) contextEntity = ctx;
    }
    close();
  }
  let extra = new Uint8Array(0);
  if (styles.length && contextEntity >= 0) {
    add(contextEntity);
    close();
    const list = styles.map((s) => "#" + index.ids[s]).join(",");
    extra = encoder.encode(
      `#${links.nextId} = MECHANICAL_DESIGN_GEOMETRIC_PRESENTATION_REPRESENTATION('',(${list}),#${index.ids[contextEntity]});\n`,
    );
  }
  picked.sort((a, b) => a - b);
  let size = index.dataStart + 1 + extra.length + FOOTER.length;
  for (const k of picked) size += index.ends[k] - index.starts[k] + 1;
  const out = new Uint8Array(size);
  out.set(index.bytes.subarray(0, index.dataStart));
  let o = index.dataStart;
  out[o++] = 0x0a;
  for (const k of picked) {
    out.set(index.bytes.subarray(index.starts[k], index.ends[k]), o);
    o += index.ends[k] - index.starts[k];
    out[o++] = 0x0a;
  }
  out.set(extra, o);
  o += extra.length;
  out.set(FOOTER, o);
  return out;
}
