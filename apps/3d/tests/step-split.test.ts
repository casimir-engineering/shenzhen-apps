import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { describe, expect, it } from "vitest";
import { planStep } from "../src/core/step/step-plan";
import { assembleModel, type PartResult } from "../src/core/step/step-assemble";
import type { StepAssembly } from "../src/core/step/step-assembly";
import { generateStepAssembly } from "./support/step-generator";
import type {
  OcctJSExactOpenResult,
  OcctJSModule,
  OcctJSNode,
} from "../vendor/occt/occt-js";

const require = createRequire(import.meta.url);
const Occt = require("../vendor/occt/occt-js.cjs") as (o: {
  wasmBinary: Uint8Array;
}) => Promise<OcctJSModule & { HEAPU8: Uint8Array }>;
const wasmBinary = readFileSync(
  new URL("../vendor/occt/occt-js.wasm", import.meta.url),
);
const params = {
  linearUnit: "millimeter",
  linearDeflectionType: "absolute_value",
  linearDeflection: 0.05,
  angularDeflection: 0.3,
  colorMode: "source",
  readNames: true,
  rootMode: "multiple-shapes",
} as const;
const MB = 1024 * 1024;
const flat = (roots: OcctJSNode[]) => {
  const out: {
    id: string;
    name: string;
    depth: number;
    meshes: string;
    transform: number[];
    children: number;
  }[] = [];
  const walk = (n: OcctJSNode, depth: number) => {
    out.push({
      id: n.id,
      name: n.name,
      depth,
      meshes: n.meshes.join(),
      transform: n.transform,
      children: n.children.length,
    });
    n.children.forEach((c) => walk(c, depth + 1));
  };
  roots.forEach((r) => walk(r, 0));
  return out;
};

describe("large STEP assemblies read product by product", () => {
  const generated = generateStepAssembly({
    products: 16,
    usesPerProduct: 12,
    sides: 120,
  });
  const bytes = new TextEncoder().encode(generated.text);

  it("matches a whole-file read with far less kernel memory and one geometry per repeated part", async () => {
    const planned = planStep(bytes);
    if (!planned.ok) throw new Error(planned.reason);
    const { plan } = planned;
    // The outline is curves only, so it is not read at all.
    expect(plan.parts).toHaveLength(generated.shapedProducts);
    expect(plan.parts.every((p) => p.size < bytes.length / 8)).toBe(true);

    const split = await Occt({ wasmBinary });
    const results = new Map<number, PartResult>();
    for (const part of plan.parts)
      results.set(part.pd, {
        result: split.ReadStepFile(part.bytes, params) as OcctJSExactOpenResult,
      });
    const splitMemory = split.HEAPU8.buffer.byteLength;
    const model = assembleModel(plan.assembly, results);

    const whole = await Occt({ wasmBinary });
    const reference = whole.OpenExactModel("step", bytes, params);
    expect(reference.success).toBe(true);
    const wholeMemory = whole.HEAPU8.buffer.byteLength;

    // Memory ceiling: each product file is small, and memory is reused between them.
    expect(splitMemory).toBeLessThanOrEqual(64 * MB);
    expect(wholeMemory).toBeGreaterThan(3 * splitMemory);

    // Instancing: every repeat of a product shares that product's geometry.
    expect(model.geometries).toHaveLength(generated.shapedProducts);
    expect(model.stats.partCount).toBe(generated.solidOccurrences);
    expect(model.stats.reusedInstanceCount).toBe(
      generated.solidOccurrences - generated.shapedProducts,
    );

    // Same tree, names, ids, placements (bit for bit), colours and triangles.
    expect(flat(model.rootNodes)).toEqual(flat(reference.rootNodes!));
    expect(
      model.geometries.map((g) => [
        g.id,
        g.name,
        g.color,
        g.indices.length,
        g.faces.length,
        g.edges.length,
      ]),
    ).toEqual(
      reference.geometries!.map((g) => [
        g.id,
        g.name,
        g.color,
        g.indices.length,
        g.faces.length,
        g.edges.length,
      ]),
    );
    expect(
      flat(model.rootNodes).find((n) => n.name === "generated-outline"),
    ).toMatchObject({ meshes: "", children: 0 });

    // Exact queries on separately opened products agree with the whole-file model.
    const a = plan.parts.find((p) => p.name === "part-0")!,
      b = plan.parts.find((p) => p.name === "part-1")!;
    const ma = split.OpenExactModel("step", a.bytes, params),
      mb = split.OpenExactModel("step", b.bytes, params);
    const ga = model.geometries.findIndex((g) =>
        /^part-0( body)?$/.test(g.name),
      ),
      gb = model.geometries.findIndex((g) => /^part-1( body)?$/.test(g.name));
    const handleA = reference.exactGeometryBindings!.find(
        (x) => x.geometryId === model.geometries[ga].id,
      )!.exactShapeHandle,
      handleB = reference.exactGeometryBindings!.find(
        (x) => x.geometryId === model.geometries[gb].id,
      )!.exactShapeHandle;
    const face = model.geometries[ga].faces[0].id;
    const area = split.MeasureExactFaceArea(
      ma.exactModelId!,
      ma.exactGeometryBindings![0].exactShapeHandle,
      "face",
      face,
    );
    const areaRef = whole.MeasureExactFaceArea(
      reference.exactModelId!,
      handleA,
      "face",
      face,
    );
    expect(area.ok && areaRef.ok && area.value).toBeCloseTo(
      areaRef.ok ? areaRef.value : NaN,
      9,
    );
    const left = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1] as const,
      right = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 25, 0, 0, 1] as const;
    const cross = split.MeasureExactDistanceCrossModel(
      ma.exactModelId!,
      ma.exactGeometryBindings![0].exactShapeHandle,
      "face",
      face,
      [...left],
      mb.exactModelId!,
      mb.exactGeometryBindings![0].exactShapeHandle,
      "face",
      face,
      [...right],
    );
    const same = whole.MeasureExactDistance(
      reference.exactModelId!,
      handleA,
      "face",
      face,
      handleB,
      "face",
      face,
      [...left],
      [...right],
    );
    expect(cross.ok && same.ok).toBe(true);
    if (cross.ok && same.ok) expect(cross.value).toBeCloseTo(same.value, 9);
  }, 120_000);

  it("leaves files it cannot split to the whole-file reader", () => {
    const single = generateStepAssembly({
      products: 1,
      usesPerProduct: 1,
      sides: 8,
    });
    expect(
      planStep(
        new TextEncoder().encode(
          single.text.replace(
            /NEXT_ASSEMBLY_USAGE_OCCURRENCE/g,
            "ASSEMBLY_COMPONENT_USAGE",
          ),
        ),
      ),
    ).toMatchObject({ ok: false });
    expect(
      planStep(new TextEncoder().encode("ISO-10303-21;\nHEADER;\nENDSEC;\n")),
    ).toMatchObject({ ok: false });
  });

  it("puts several top-level products under one synthetic root, numbered like the kernel", () => {
    const leaf = (pd: number, name: string) =>
      [
        pd,
        { pd, name, reps: [pd], occurrences: [], hasShape: true },
      ] as const;
    const assembly: StepAssembly = {
      products: new Map([leaf(1, "a"), leaf(2, "b")]),
      roots: [1, 2],
      occurrenceCount: 0,
    };
    const part = (name: string) => ({
      result: {
        success: true,
        geometries: [],
        rootNodes: [
          {
            id: "node_0",
            name,
            isAssembly: false,
            transform: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
            meshes: [],
            children: [],
          },
        ],
      } as unknown as OcctJSExactOpenResult,
    });
    const model = assembleModel(
      assembly,
      new Map([
        [1, part("a")],
        [2, part("b")],
      ]),
    );
    expect(model.rootNodes).toHaveLength(1);
    expect(model.rootNodes[0]).toMatchObject({ id: "__root__", name: "Root", isAssembly: true });
    expect(model.rootNodes[0].children.map((n) => [n.id, n.name])).toEqual([
      ["node_1", "a"],
      ["node_2", "b"],
    ]);
    expect(model.stats.nodeCount).toBe(3);
  });
});
