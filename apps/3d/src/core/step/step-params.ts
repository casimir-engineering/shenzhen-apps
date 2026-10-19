// Parameter parser for individual small STEP records (assembly links, units,
// placements). Geometry records are never parsed; they are copied as bytes.
import type { StepIndex } from "./step-index.ts";

export type StepValue =
  | { ref: number }
  | { str: string }
  | { enum: string }
  | { typed: string; args: StepValue[] }
  | StepValue[]
  | number
  | null;

export interface StepRecord {
  type: string;
  args: StepValue[];
}

const decoder = new TextDecoder("latin1");

class Reader {
  i: number;
  private b: Uint8Array;
  private end: number;
  constructor(b: Uint8Array, start: number, end: number) {
    this.b = b;
    this.i = start;
    this.end = end;
  }
  ws() {
    const b = this.b;
    while (this.i < this.end) {
      const c = b[this.i];
      if (c === 0x20 || c === 0x0a || c === 0x0d || c === 0x09) this.i++;
      else if (c === 0x2f && b[this.i + 1] === 0x2a) {
        this.i += 2;
        while (
          this.i < this.end &&
          !(b[this.i] === 0x2a && b[this.i + 1] === 0x2f)
        )
          this.i++;
        this.i += 2;
      } else break;
    }
  }
  peek() {
    this.ws();
    return this.b[this.i];
  }
  ident() {
    this.ws();
    const s = this.i;
    while (this.i < this.end) {
      const c = this.b[this.i];
      if (
        (c >= 0x41 && c <= 0x5a) ||
        (c >= 0x61 && c <= 0x7a) ||
        (c >= 0x30 && c <= 0x39) ||
        c === 0x5f
      )
        this.i++;
      else break;
    }
    return decoder.decode(this.b.subarray(s, this.i));
  }
  list(): StepValue[] {
    this.ws();
    if (this.b[this.i] !== 0x28)
      throw new Error("STEP parameter list expected");
    this.i++;
    const out: StepValue[] = [];
    if (this.peek() === 0x29) {
      this.i++;
      return out;
    }
    for (;;) {
      out.push(this.value());
      const c = this.peek();
      this.i++;
      if (c === 0x29) return out;
      if (c !== 0x2c) throw new Error("Malformed STEP parameter list");
    }
  }
  value(): StepValue {
    const c = this.peek(),
      b = this.b;
    if (c === 0x23) {
      this.i++;
      let n = 0;
      while (b[this.i] >= 0x30 && b[this.i] <= 0x39)
        n = n * 10 + b[this.i++] - 0x30;
      return { ref: n };
    }
    if (c === 0x27) {
      this.i++;
      let s = "";
      let from = this.i;
      for (;;) {
        if (b[this.i] === 0x27) {
          s += decoder.decode(b.subarray(from, this.i));
          if (b[this.i + 1] === 0x27) {
            s += "'";
            this.i += 2;
            from = this.i;
            continue;
          }
          this.i++;
          return { str: s };
        }
        this.i++;
      }
    }
    if (c === 0x2e) {
      this.i++;
      const s = this.i;
      while (b[this.i] !== 0x2e) this.i++;
      return { enum: decoder.decode(b.subarray(s, this.i++)) };
    }
    if (c === 0x28) return this.list();
    if (c === 0x24 || c === 0x2a) {
      this.i++;
      return null;
    }
    if ((c >= 0x41 && c <= 0x5a) || c === 0x5f) {
      const typed = this.ident();
      return { typed, args: this.list() };
    }
    const s = this.i;
    while (this.i < this.end && !/[,)\s]/.test(String.fromCharCode(b[this.i])))
      this.i++;
    return Number(decoder.decode(b.subarray(s, this.i)));
  }
}

/** Records of entity k: one for a simple entity, several for a complex one. */
export function parseRecords(index: StepIndex, k: number): StepRecord[] {
  const r = new Reader(index.bytes, index.bodyStarts[k], index.ends[k] - 1);
  if (r.peek() === 0x28) {
    r.i++;
    const out: StepRecord[] = [];
    while (r.peek() !== 0x29) {
      const type = r.ident();
      out.push({ type, args: r.list() });
    }
    return out;
  }
  const type = r.ident();
  return [{ type, args: r.list() }];
}

export const parseRecord = (index: StepIndex, k: number) =>
  parseRecords(index, k)[0];

export const refOf = (v: StepValue | undefined): number | undefined =>
  v && typeof v === "object" && "ref" in v ? v.ref : undefined;
export const strOf = (v: StepValue | undefined): string =>
  v && typeof v === "object" && "str" in v ? v.str : "";
export const listOf = (v: StepValue | undefined): StepValue[] =>
  Array.isArray(v) ? v : [];
