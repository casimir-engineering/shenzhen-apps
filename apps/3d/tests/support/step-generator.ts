// Writes a synthetic AP214 STEP assembly for tests: distinct prism parts
// (each with its own colour and many faces), each placed many times, a nested
// module whose placements are in inches and which is itself used twice, and a
// curve-only outline product like the ones board exporters write.

export interface GeneratedAssemblyOptions {
  products: number;
  usesPerProduct: number;
  /** Side faces per prism; more sides make each part's file larger. */
  sides: number;
}

export interface GeneratedAssembly {
  text: string;
  /** Distinct products that carry a solid. */
  shapedProducts: number;
  /** Solid occurrences in the whole tree. */
  solidOccurrences: number;
}

const f = (v: number) => {
  const s = (Math.abs(v) < 1e-12 ? 0 : v).toPrecision(12);
  return s.includes(".") || s.includes("e") ? s.replace("e", "E") : s + ".";
};

export function generateStepAssembly(
  options: GeneratedAssemblyOptions,
): GeneratedAssembly {
  const lines: string[] = [];
  let next = 1;
  const add = (body: string) => {
    const id = next++;
    lines.push(`#${id} = ${body};`);
    return id;
  };
  const point = (x: number, y: number, z: number) =>
    add(`CARTESIAN_POINT('',(${f(x)},${f(y)},${f(z)}))`);
  const dir = (x: number, y: number, z: number) =>
    add(`DIRECTION('',(${f(x)},${f(y)},${f(z)}))`);
  const axis = (o: number[], z: number[], x: number[]) =>
    add(
      `AXIS2_PLACEMENT_3D('',#${point(o[0], o[1], o[2])},#${dir(z[0], z[1], z[2])},#${dir(x[0], x[1], x[2])})`,
    );
  const appContext = add(
    "APPLICATION_CONTEXT('core data for automotive mechanical design processes')",
  );
  add(
    `APPLICATION_PROTOCOL_DEFINITION('international standard','automotive_design',2000,#${appContext})`,
  );
  const mm = add("( LENGTH_UNIT() NAMED_UNIT(*) SI_UNIT(.MILLI.,.METRE.) )");
  const rad = add("( NAMED_UNIT(*) PLANE_ANGLE_UNIT() SI_UNIT($,.RADIAN.) )");
  const sr = add("( NAMED_UNIT(*) SI_UNIT($,.STERADIAN.) SOLID_ANGLE_UNIT() )");
  const inchMeasure = add(
    `LENGTH_MEASURE_WITH_UNIT(LENGTH_MEASURE(25.4),#${mm})`,
  );
  const dims = add("DIMENSIONAL_EXPONENTS(1.,0.,0.,0.,0.,0.,0.)");
  const inch = add(
    `( CONVERSION_BASED_UNIT('INCH',#${inchMeasure}) LENGTH_UNIT() NAMED_UNIT(#${dims}) )`,
  );
  const context = (length: number) => {
    const u = add(
      `UNCERTAINTY_MEASURE_WITH_UNIT(LENGTH_MEASURE(1.E-07),#${length},'distance_accuracy_value','confusion accuracy')`,
    );
    return add(
      `( GEOMETRIC_REPRESENTATION_CONTEXT(3) GLOBAL_UNCERTAINTY_ASSIGNED_CONTEXT((#${u})) GLOBAL_UNIT_ASSIGNED_CONTEXT((#${length},#${rad},#${sr})) REPRESENTATION_CONTEXT('Context','3D Context with UNIT and UNCERTAINTY') )`,
    );
  };
  const mmContext = context(mm),
    inchContext = context(inch);
  const productContext = add(`PRODUCT_CONTEXT('',#${appContext},'mechanical')`);
  const pdContext = add(
    `PRODUCT_DEFINITION_CONTEXT('part definition',#${appContext},'design')`,
  );
  const product = (name: string) => {
    const p = add(`PRODUCT('${name}','${name}','',(#${productContext}))`);
    const pdf = add(`PRODUCT_DEFINITION_FORMATION('','',#${p})`);
    const pd = add(`PRODUCT_DEFINITION('design','',#${pdf},#${pdContext})`);
    const pds = add(`PRODUCT_DEFINITION_SHAPE('','',#${pd})`);
    return { pd, pds };
  };
  const styles: number[] = [];
  const prism = (
    name: string,
    sides: number,
    radius: number,
    height: number,
    rgb: number[],
  ) => {
    const made = product(name);
    const pds = made.pds;
    const bottom: number[] = [],
      top: number[] = [],
      pts: number[][] = [];
    for (let i = 0; i < sides; i++) {
      const a = (i / sides) * Math.PI * 2;
      pts.push([radius * Math.cos(a), radius * Math.sin(a)]);
      bottom.push(add(`VERTEX_POINT('',#${point(pts[i][0], pts[i][1], 0)})`));
      top.push(add(`VERTEX_POINT('',#${point(pts[i][0], pts[i][1], height)})`));
    }
    const lineEdge = (from: number, to: number, p: number[], q: number[]) => {
      const d = [q[0] - p[0], q[1] - p[1], q[2] - p[2]],
        len = Math.hypot(d[0], d[1], d[2]);
      const v = add(
        `VECTOR('',#${dir(d[0] / len, d[1] / len, d[2] / len)},${f(len)})`,
      );
      const line = add(`LINE('',#${point(p[0], p[1], p[2])},#${v})`);
      return add(`EDGE_CURVE('',#${from},#${to},#${line},.T.)`);
    };
    const b: number[] = [],
      t: number[] = [],
      v: number[] = [];
    for (let i = 0; i < sides; i++) {
      const j = (i + 1) % sides;
      b.push(lineEdge(bottom[i], bottom[j], [...pts[i], 0], [...pts[j], 0]));
      t.push(
        lineEdge(top[i], top[j], [...pts[i], height], [...pts[j], height]),
      );
      v.push(lineEdge(bottom[i], top[i], [...pts[i], 0], [...pts[i], height]));
    }
    const oriented = (e: number, same: boolean) =>
      add(`ORIENTED_EDGE('',*,*,#${e},${same ? ".T." : ".F."})`);
    const face = (edges: number[], o: number[], n: number[], x: number[]) => {
      const loop = add(
        `EDGE_LOOP('',(${edges.map((e) => "#" + e).join(",")}))`,
      );
      const bound = add(`FACE_OUTER_BOUND('',#${loop},.T.)`);
      const plane = add(`PLANE('',#${axis(o, n, x)})`);
      return add(`ADVANCED_FACE('',(#${bound}),#${plane},.T.)`);
    };
    const faces: number[] = [];
    for (let i = 0; i < sides; i++) {
      const j = (i + 1) % sides,
        mid = ((i + 0.5) / sides) * Math.PI * 2;
      const tx = pts[j][0] - pts[i][0],
        ty = pts[j][1] - pts[i][1],
        tl = Math.hypot(tx, ty);
      faces.push(
        face(
          [
            oriented(b[i], true),
            oriented(v[j], true),
            oriented(t[i], false),
            oriented(v[i], false),
          ],
          [pts[i][0], pts[i][1], 0],
          [Math.cos(mid), Math.sin(mid), 0],
          [tx / tl, ty / tl, 0],
        ),
      );
    }
    faces.push(
      face(
        [...b].reverse().map((e) => oriented(e, false)),
        [0, 0, 0],
        [0, 0, -1],
        [1, 0, 0],
      ),
    );
    faces.push(
      face(
        t.map((e) => oriented(e, true)),
        [0, 0, height],
        [0, 0, 1],
        [1, 0, 0],
      ),
    );
    const shell = add(
      `CLOSED_SHELL('',(${faces.map((x) => "#" + x).join(",")}))`,
    );
    const solid = add(`MANIFOLD_SOLID_BREP('${name} body',#${shell})`);
    const origin = axis([0, 0, 0], [0, 0, 1], [1, 0, 0]);
    const rep = add(
      `ADVANCED_BREP_SHAPE_REPRESENTATION('',(#${origin},#${solid}),#${mmContext})`,
    );
    add(`SHAPE_DEFINITION_REPRESENTATION(#${pds},#${rep})`);
    const rgbId = add(`COLOUR_RGB('',${f(rgb[0])},${f(rgb[1])},${f(rgb[2])})`);
    const fill = add(`FILL_AREA_STYLE_COLOUR('',#${rgbId})`);
    const area = add(`FILL_AREA_STYLE('',(#${fill}))`);
    const surface = add(`SURFACE_STYLE_FILL_AREA(#${area})`);
    const side = add(`SURFACE_SIDE_STYLE('',(#${surface}))`);
    const usage = add(`SURFACE_STYLE_USAGE(.BOTH.,#${side})`);
    const psa = add(`PRESENTATION_STYLE_ASSIGNMENT((#${usage}))`);
    styles.push(add(`STYLED_ITEM('color',(#${psa}),#${solid})`));
    return { pd: made.pd, rep: () => rep, origin };
  };
  const assembly = (name: string, ctx: number) => {
    const { pd, pds } = product(name);
    const origin = axis([0, 0, 0], [0, 0, 1], [1, 0, 0]);
    return { pd, pds, origin, placements: [origin] as number[], ctx, rep: 0 };
  };
  const finish = (a: ReturnType<typeof assembly>) => {
    a.rep = add(
      `SHAPE_REPRESENTATION('',(${a.placements.map((p) => "#" + p).join(",")}),#${a.ctx})`,
    );
    add(`SHAPE_DEFINITION_REPRESENTATION(#${a.pds},#${a.rep})`);
  };
  const occurrences: (() => void)[] = [];
  let serial = 0;
  const use = (
    parent: ReturnType<typeof assembly>,
    child: { pd: number; rep: () => number; origin: number },
    at: number[],
    angle: number,
  ) => {
    const placement = axis(
      at,
      [0, 0, 1],
      [Math.cos(angle), Math.sin(angle), 0],
    );
    parent.placements.push(placement);
    occurrences.push(() => {
      serial++;
      const nauo = add(
        `NEXT_ASSEMBLY_USAGE_OCCURRENCE('${serial}','R${serial}','',#${parent.pd},#${child.pd},$)`,
      );
      const pds = add(
        `PRODUCT_DEFINITION_SHAPE('Placement','Placement of an item',#${nauo})`,
      );
      const idt = add(
        `ITEM_DEFINED_TRANSFORMATION('','',#${child.origin},#${placement})`,
      );
      const rr = add(
        `( REPRESENTATION_RELATIONSHIP('','',#${child.rep()},#${parent.rep}) REPRESENTATION_RELATIONSHIP_WITH_TRANSFORMATION(#${idt}) SHAPE_REPRESENTATION_RELATIONSHIP() )`,
      );
      add(`CONTEXT_DEPENDENT_SHAPE_REPRESENTATION(#${rr},#${pds})`);
    });
  };
  const root = assembly("generated-board", mmContext);
  const module = assembly("generated-module", inchContext);
  const parts: { pd: number; rep: () => number; origin: number }[] = [];
  let solidOccurrences = 0;
  for (let p = 0; p < options.products; p++) {
    const r = 0.5 + (p % 7) * 0.25,
      h = 0.4 + (p % 5) * 0.3;
    parts.push(
      prism(`part-${p}`, options.sides + (p % 3), r, h, [
        ((p * 37) % 100) / 100,
        ((p * 61) % 100) / 100,
        ((p * 13) % 100) / 100,
      ]),
    );
  }
  const columns = Math.ceil(
    Math.sqrt(options.products * options.usesPerProduct),
  );
  let slot = 0;
  for (const part of parts)
    for (let u = 0; u < options.usesPerProduct; u++, slot++) {
      use(
        root,
        part,
        [(slot % columns) * 4, Math.floor(slot / columns) * 4, 1.6],
        (slot % 4) * (Math.PI / 2),
      );
      solidOccurrences++;
    }
  // Module: three parts in inch placements, used twice on the board.
  for (let i = 0; i < 3; i++)
    use(module, parts[i % parts.length], [i * 0.2, 0.1, 0], i * 0.5);
  const moduleRef = {
    pd: module.pd,
    rep: () => module.rep,
    origin: module.origin,
  };
  use(root, moduleRef, [-20, 0, 1.6], 0);
  use(root, moduleRef, [-20, 20, 0], Math.PI);
  solidOccurrences += 6;
  // Board outline written as curves only.
  const outline = product("generated-outline");
  const c1 = point(0, 0, 0),
    c2 = point(10, 0, 0);
  const v = add(`VECTOR('',#${dir(1, 0, 0)},10.)`);
  const line = add(`LINE('',#${c1},#${v})`);
  const trimmed = add(
    `TRIMMED_CURVE('',#${line},(#${c1},PARAMETER_VALUE(0.)),(#${c2},PARAMETER_VALUE(10.)),.T.,.PARAMETER.)`,
  );
  const set = add(`GEOMETRIC_CURVE_SET('',(#${trimmed}))`);
  const outlineOrigin = axis([0, 0, 0], [0, 0, 1], [1, 0, 0]);
  const outlineRep = add(
    `SHAPE_REPRESENTATION('',(#${outlineOrigin},#${set}),#${mmContext})`,
  );
  add(`SHAPE_DEFINITION_REPRESENTATION(#${outline.pds},#${outlineRep})`);
  use(
    root,
    { pd: outline.pd, rep: () => outlineRep, origin: outlineOrigin },
    [0, 0, 0],
    0,
  );
  finish(module);
  finish(root);
  occurrences.forEach((o) => o());
  add(
    `MECHANICAL_DESIGN_GEOMETRIC_PRESENTATION_REPRESENTATION('',(${styles.map((s) => "#" + s).join(",")}),#${mmContext})`,
  );
  const header = [
    "ISO-10303-21;",
    "HEADER;",
    "FILE_DESCRIPTION(('generated assembly'),'2;1');",
    "FILE_NAME('generated.step','2026-01-01T00:00:00',(''),(''),'','','');",
    "FILE_SCHEMA(('AUTOMOTIVE_DESIGN { 1 0 10303 214 1 1 1 1 }'));",
    "ENDSEC;",
    "DATA;",
  ];
  return {
    text: [...header, ...lines, "ENDSEC;", "END-ISO-10303-21;", ""].join("\n"),
    shapedProducts: options.products,
    solidOccurrences,
  };
}
