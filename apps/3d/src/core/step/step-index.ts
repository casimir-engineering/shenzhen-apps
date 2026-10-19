// Byte-level index of a STEP Part 21 file: one pass, no string copy of the file.
// Each entity keeps its byte range, its type and its outgoing #references so a
// product's sub-graph can be cut out without parsing parameter values.

const HASH = 0x23,
  QUOTE = 0x27,
  SEMI = 0x3b,
  EQ = 0x3d,
  LPAREN = 0x28,
  SLASH = 0x2f,
  STAR = 0x2a;
const isDigit = (c: number) => c >= 0x30 && c <= 0x39;
const isSpace = (c: number) =>
  c === 0x20 || c === 0x0a || c === 0x0d || c === 0x09;
const isIdent = (c: number) =>
  (c >= 0x41 && c <= 0x5a) ||
  (c >= 0x61 && c <= 0x7a) ||
  isDigit(c) ||
  c === 0x5f;

export interface StepIndex {
  bytes: Uint8Array;
  /** Byte offset where the DATA section's first entity begins. */
  dataStart: number;
  /** Byte offset of the ENDSEC that closes DATA. */
  dataEnd: number;
  count: number;
  /** Entity number (#id) per index. */
  ids: Uint32Array;
  /** Statement byte range [start, end) including the trailing ';'. */
  starts: Uint32Array;
  ends: Uint32Array;
  /** Byte range of the record after '=' (type name or complex list). */
  bodyStarts: Uint32Array;
  types: Uint16Array;
  typeNames: string[];
  refStarts: Uint32Array;
  refs: Uint32Array;
  /** Maps #id to index + 1 (0 = absent). */
  byId: Uint32Array;
}

const COMPLEX = "(COMPLEX)";

function findData(bytes: Uint8Array): number {
  // "DATA;" appears after the header; search for the token at a line start.
  const pat = [0x44, 0x41, 0x54, 0x41, 0x3b];
  outer: for (let i = 0; i < bytes.length - 5; i++) {
    for (let j = 0; j < 5; j++) if (bytes[i + j] !== pat[j]) continue outer;
    if (i === 0 || isSpace(bytes[i - 1]) || bytes[i - 1] === SEMI) return i + 5;
  }
  throw new Error("This STEP file has no DATA section.");
}

class Grow {
  data: Uint32Array;
  length = 0;
  constructor(size: number) {
    this.data = new Uint32Array(size);
  }
  push(v: number) {
    if (this.length === this.data.length) {
      const next = new Uint32Array(this.data.length * 2);
      next.set(this.data);
      this.data = next;
    }
    this.data[this.length++] = v;
  }
  done() {
    return this.data.slice(0, this.length);
  }
}

export function indexStep(bytes: Uint8Array): StepIndex {
  const dataStart = findData(bytes);
  const estimate = Math.max(1024, (bytes.length / 60) | 0);
  const ids = new Grow(estimate),
    starts = new Grow(estimate),
    ends = new Grow(estimate),
    bodies = new Grow(estimate),
    types = new Grow(estimate),
    refStarts = new Grow(estimate + 1),
    refs = new Grow(estimate * 3);
  const typeIds = new Map<string, number>(),
    typeNames: string[] = [];
  const typeId = (name: string) => {
    let id = typeIds.get(name);
    if (id === undefined) {
      id = typeNames.length;
      typeIds.set(name, id);
      typeNames.push(name);
    }
    return id;
  };
  const decoder = new TextDecoder("latin1");
  const n = bytes.length;
  let i = dataStart,
    dataEnd = n,
    maxId = 0;
  while (i < n) {
    let c = bytes[i];
    if (isSpace(c)) {
      i++;
      continue;
    }
    if (c === SLASH && bytes[i + 1] === STAR) {
      const close = indexOfPair(bytes, i + 2, STAR, SLASH);
      i = close < 0 ? n : close + 2;
      continue;
    }
    if (c !== HASH) {
      // ENDSEC or a stray token: the DATA section is over.
      dataEnd = i;
      break;
    }
    const start = i;
    i++;
    let id = 0;
    while (i < n && isDigit((c = bytes[i]))) {
      id = id * 10 + (c - 0x30);
      i++;
    }
    while (i < n && bytes[i] !== EQ) i++;
    i++;
    while (i < n && isSpace(bytes[i])) i++;
    const body = i;
    let type: number;
    if (bytes[i] === LPAREN) type = typeId(COMPLEX);
    else {
      let e = i;
      while (e < n && isIdent(bytes[e])) e++;
      type = typeId(decoder.decode(bytes.subarray(i, e)));
      i = e;
    }
    refStarts.push(refs.length);
    // Walk to the terminating ';' outside strings, collecting #refs.
    while (i < n) {
      c = bytes[i];
      if (c === QUOTE) {
        i++;
        while (i < n) {
          if (bytes[i] === QUOTE) {
            if (bytes[i + 1] === QUOTE) i += 2;
            else break;
          } else i++;
        }
        i++;
        continue;
      }
      if (c === HASH) {
        i++;
        let ref = 0;
        while (i < n && isDigit((c = bytes[i]))) {
          ref = ref * 10 + (c - 0x30);
          i++;
        }
        refs.push(ref);
        continue;
      }
      if (c === SEMI) break;
      i++;
    }
    i++;
    ids.push(id);
    starts.push(start);
    ends.push(i);
    bodies.push(body);
    types.push(type);
    if (id > maxId) maxId = id;
  }
  refStarts.push(refs.length);
  const idArray = ids.done();
  const byId = new Uint32Array(maxId + 1);
  for (let k = 0; k < idArray.length; k++) byId[idArray[k]] = k + 1;
  return {
    bytes,
    dataStart,
    dataEnd,
    count: idArray.length,
    ids: idArray,
    starts: starts.done(),
    ends: ends.done(),
    bodyStarts: bodies.done(),
    types: Uint16Array.from(types.done()),
    typeNames,
    refStarts: refStarts.done(),
    refs: refs.done(),
    byId,
  };
}

function indexOfPair(bytes: Uint8Array, from: number, a: number, b: number) {
  for (let i = from; i < bytes.length - 1; i++)
    if (bytes[i] === a && bytes[i + 1] === b) return i;
  return -1;
}

/** Index of an entity by #id, or -1. */
export const entityIndex = (index: StepIndex, id: number) =>
  id < index.byId.length ? index.byId[id] - 1 : -1;

export const typeOf = (index: StepIndex, k: number) =>
  index.typeNames[index.types[k]];

/** Outgoing references of entity k as #ids. */
export const refsOf = (index: StepIndex, k: number) =>
  index.refs.subarray(index.refStarts[k], index.refStarts[k + 1]);

/** Raw record text after '=' (for reading a few parameters of small entities). */
export const bodyText = (index: StepIndex, k: number) =>
  new TextDecoder("latin1").decode(
    index.bytes.subarray(index.bodyStarts[k], index.ends[k] - 1),
  );
