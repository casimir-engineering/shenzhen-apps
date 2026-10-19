#!/usr/bin/env node
// Writes fixtures/sample-assembly.step: a synthetic AP214 STEP assembly used by
// the CAD checks, the browser tests, the benchmarks and the README screenshot.
//
//   node scripts/fixtures/make-sample-assembly.mjs [output.step]
//
// The model is a 248 x 72 mm plate carrying 150 small cell modules in three
// variants, four pin headers, fasteners and standoffs. Cells contain nested
// pad groups, so the tree is four levels deep, and every repeated part is one
// shared geometry placed many times (about 3,150 solid occurrences using 16
// geometries). Every product has its own colour. The output is deterministic:
// running the script again writes the same bytes.
import fs from 'node:fs';
import path from 'node:path';
import {pathToFileURL} from 'node:url';

const f = v => {
  const s = (Math.abs(v) < 1e-12 ? 0 : v).toPrecision(12);
  const t = s.includes('e') ? s : s.replace(/0+$/, '');
  return t.includes('.') || t.includes('e') ? t.replace('e', 'E') : t + '.';
};

export function generateSampleAssembly() {
  const lines = [];
  let next = 1;
  const add = body => { const id = next++; lines.push(`#${id} = ${body};`); return id; };
  const point = (x, y, z) => add(`CARTESIAN_POINT('',(${f(x)},${f(y)},${f(z)}))`);
  const dir = (x, y, z) => add(`DIRECTION('',(${f(x)},${f(y)},${f(z)}))`);
  const axis = (o, z, x) => add(`AXIS2_PLACEMENT_3D('',#${point(...o)},#${dir(...z)},#${dir(...x)})`);

  const app = add("APPLICATION_CONTEXT('core data for automotive mechanical design processes')");
  add(`APPLICATION_PROTOCOL_DEFINITION('international standard','automotive_design',2000,#${app})`);
  const mm = add('( LENGTH_UNIT() NAMED_UNIT(*) SI_UNIT(.MILLI.,.METRE.) )');
  const rad = add('( NAMED_UNIT(*) PLANE_ANGLE_UNIT() SI_UNIT($,.RADIAN.) )');
  const sr = add('( NAMED_UNIT(*) SI_UNIT($,.STERADIAN.) SOLID_ANGLE_UNIT() )');
  const unc = add(`UNCERTAINTY_MEASURE_WITH_UNIT(LENGTH_MEASURE(1.E-07),#${mm},'distance_accuracy_value','confusion accuracy')`);
  const ctx = add(`( GEOMETRIC_REPRESENTATION_CONTEXT(3) GLOBAL_UNCERTAINTY_ASSIGNED_CONTEXT((#${unc})) GLOBAL_UNIT_ASSIGNED_CONTEXT((#${mm},#${rad},#${sr})) REPRESENTATION_CONTEXT('Context','3D Context with UNIT and UNCERTAINTY') )`);
  const productContext = add(`PRODUCT_CONTEXT('',#${app},'mechanical')`);
  const pdContext = add(`PRODUCT_DEFINITION_CONTEXT('part definition',#${app},'design')`);

  const product = name => {
    const p = add(`PRODUCT('${name}','${name}','',(#${productContext}))`);
    const pdf = add(`PRODUCT_DEFINITION_FORMATION('','',#${p})`);
    const pd = add(`PRODUCT_DEFINITION('design','',#${pdf},#${pdContext})`);
    const pds = add(`PRODUCT_DEFINITION_SHAPE('','',#${pd})`);
    return {pd, pds};
  };

  const styles = [];
  let solids = 0;
  // A right prism over a counter-clockwise outline, from z = 0 to z = height.
  const extrusion = (name, outline, height, rgb) => {
    solids++;
    const made = product(name);
    const n = outline.length, bottom = [], top = [];
    for (const [x, y] of outline) {
      bottom.push(add(`VERTEX_POINT('',#${point(x, y, 0)})`));
      top.push(add(`VERTEX_POINT('',#${point(x, y, height)})`));
    }
    const edge = (from, to, p, q) => {
      const d = [q[0] - p[0], q[1] - p[1], q[2] - p[2]], len = Math.hypot(...d);
      const v = add(`VECTOR('',#${dir(d[0] / len, d[1] / len, d[2] / len)},${f(len)})`);
      return add(`EDGE_CURVE('',#${from},#${to},#${add(`LINE('',#${point(...p)},#${v})`)},.T.)`);
    };
    const b = [], t = [], v = [];
    for (let i = 0; i < n; i++) {
      const j = (i + 1) % n, p = outline[i], q = outline[j];
      b.push(edge(bottom[i], bottom[j], [...p, 0], [...q, 0]));
      t.push(edge(top[i], top[j], [...p, height], [...q, height]));
      v.push(edge(bottom[i], top[i], [...p, 0], [...p, height]));
    }
    const face = (edges, o, normal, x) => {
      const loop = add(`EDGE_LOOP('',(${edges.map(e => '#' + e).join(',')}))`);
      const bound = add(`FACE_OUTER_BOUND('',#${loop},.T.)`);
      return add(`ADVANCED_FACE('',(#${bound}),#${add(`PLANE('',#${axis(o, normal, x)})`)},.T.)`);
    };
    const faces = [];
    for (let i = 0; i < n; i++) {
      const j = (i + 1) % n, p = outline[i], q = outline[j];
      const tx = q[0] - p[0], ty = q[1] - p[1], tl = Math.hypot(tx, ty);
      faces.push(face([oriented(b[i], true), oriented(v[j], true), oriented(t[i], false), oriented(v[i], false)],
        [p[0], p[1], 0], [ty / tl, -tx / tl, 0], [tx / tl, ty / tl, 0]));
    }
    faces.push(face([...b].reverse().map(e => oriented(e, false)), [0, 0, 0], [0, 0, -1], [1, 0, 0]));
    faces.push(face(t.map(e => oriented(e, true)), [0, 0, height], [0, 0, 1], [1, 0, 0]));
    return body(name, made, faces, rgb);
  };
  const oriented = (e, same) => add(`ORIENTED_EDGE('',*,*,#${e},${same ? '.T.' : '.F.'})`);
  const bounded = (edges, surface) => {
    const loop = add(`EDGE_LOOP('',(${edges.map(e => '#' + e).join(',')}))`);
    return add(`ADVANCED_FACE('',(#${add(`FACE_OUTER_BOUND('',#${loop},.T.)`)}),#${surface},.T.)`);
  };
  // A true cylinder from z = 0 to z = height: two circular edges, one seam.
  const cylinder = (name, r, height, rgb) => {
    solids++;
    const made = product(name);
    const vb = add(`VERTEX_POINT('',#${point(r, 0, 0)})`), vt = add(`VERTEX_POINT('',#${point(r, 0, height)})`);
    const circle = z => add(`CIRCLE('',#${axis([0, 0, z], [0, 0, 1], [1, 0, 0])},${f(r)})`);
    const eb = add(`EDGE_CURVE('',#${vb},#${vb},#${circle(0)},.T.)`);
    const et = add(`EDGE_CURVE('',#${vt},#${vt},#${circle(height)},.T.)`);
    const seam = add(`LINE('',#${point(r, 0, 0)},#${add(`VECTOR('',#${dir(0, 0, 1)},${f(height)})`)})`);
    const es = add(`EDGE_CURVE('',#${vb},#${vt},#${seam},.T.)`);
    const side = add(`CYLINDRICAL_SURFACE('',#${axis([0, 0, 0], [0, 0, 1], [1, 0, 0])},${f(r)})`);
    const faces = [
      bounded([oriented(eb, true), oriented(es, true), oriented(et, false), oriented(es, false)], side),
      bounded([oriented(eb, false)], add(`PLANE('',#${axis([0, 0, 0], [0, 0, -1], [1, 0, 0])})`)),
      bounded([oriented(et, true)], add(`PLANE('',#${axis([0, 0, height], [0, 0, 1], [1, 0, 0])})`)),
    ];
    return body(name, made, faces, rgb);
  };
  const body = (name, made, faces, rgb) => {
    const shell = add(`CLOSED_SHELL('',(${faces.map(x => '#' + x).join(',')}))`);
    const solid = add(`MANIFOLD_SOLID_BREP('${name}',#${shell})`);
    const origin = axis([0, 0, 0], [0, 0, 1], [1, 0, 0]);
    const rep = add(`ADVANCED_BREP_SHAPE_REPRESENTATION('',(#${origin},#${solid}),#${ctx})`);
    add(`SHAPE_DEFINITION_REPRESENTATION(#${made.pds},#${rep})`);
    const colour = add(`COLOUR_RGB('',${rgb.map(f).join(',')})`);
    const fill = add(`FILL_AREA_STYLE('',(#${add(`FILL_AREA_STYLE_COLOUR('',#${colour})`)}))`);
    const side = add(`SURFACE_SIDE_STYLE('',(#${add(`SURFACE_STYLE_FILL_AREA(#${fill})`)}))`);
    const psa = add(`PRESENTATION_STYLE_ASSIGNMENT((#${add(`SURFACE_STYLE_USAGE(.BOTH.,#${side})`)}))`);
    styles.push(add(`STYLED_ITEM('color',(#${psa}),#${solid})`));
    return {pd: made.pd, rep: () => rep, origin, solids: 1};
  };
  const rect = (w, d) => [[-w / 2, -d / 2], [w / 2, -d / 2], [w / 2, d / 2], [-w / 2, d / 2]];
  const polygon = (sides, r, turn = 0) => Array.from({length: sides}, (_, i) => {
    const a = turn + i / sides * Math.PI * 2;
    return [r * Math.cos(a), r * Math.sin(a)];
  });

  // Assemblies: placements are collected first; usages are written after the
  // assembly's own representation exists.
  const usages = [];
  let serial = 0;
  const assembly = name => {
    const {pd, pds} = product(name);
    const origin = axis([0, 0, 0], [0, 0, 1], [1, 0, 0]);
    const a = {pd, pds, origin, placements: [origin], repId: 0, solids: 0, rep: () => a.repId};
    return a;
  };
  const finish = a => {
    a.repId = add(`SHAPE_REPRESENTATION('',(${a.placements.map(p => '#' + p).join(',')}),#${ctx})`);
    add(`SHAPE_DEFINITION_REPRESENTATION(#${a.pds},#${a.repId})`);
    return a;
  };
  const use = (parent, child, at, quarterTurns = 0, flip = false) => {
    const a = quarterTurns * Math.PI / 2;
    const placement = axis(at, [0, 0, flip ? -1 : 1], [Math.round(Math.cos(a)), Math.round(Math.sin(a)), 0]);
    parent.placements.push(placement);
    parent.solids += child.solids;
    usages.push(() => {
      serial++;
      const nauo = add(`NEXT_ASSEMBLY_USAGE_OCCURRENCE('${serial}','=>[0:1:1:${serial}]','',#${parent.pd},#${child.pd},$)`);
      const pds = add(`PRODUCT_DEFINITION_SHAPE('Placement','Placement of an item',#${nauo})`);
      const idt = add(`ITEM_DEFINED_TRANSFORMATION('','',#${child.origin},#${placement})`);
      const rr = add(`( REPRESENTATION_RELATIONSHIP('','',#${child.rep()},#${parent.rep()}) REPRESENTATION_RELATIONSHIP_WITH_TRANSFORMATION(#${idt}) SHAPE_REPRESENTATION_RELATIONSHIP() )`);
      add(`CONTEXT_DEPENDENT_SHAPE_REPRESENTATION(#${rr},#${pds})`);
    });
  };

  // Parts. The plate is dark and every part on it is light, so the browser
  // tests, which pick bright pixels, land on separate parts rather than on
  // one large plate face.
  const plate = extrusion('Base plate 248 x 72', [[0, 0], [248, 0], [248, 72], [0, 72]], 1.6, [0.12, 0.30, 0.22]);
  const blockA = extrusion('Block 4 x 4', rect(4, 4), 0.9, [0.80, 0.80, 0.84]);
  const blockB = extrusion('Block 3 x 3', rect(3, 3), 1.1, [0.72, 0.76, 0.86]);
  const blockC = extrusion('Block 5 x 2', rect(5, 2), 0.8, [0.86, 0.80, 0.70]);
  const pad = extrusion('Pad 0.6 x 0.3', rect(0.6, 0.3), 0.15, [0.90, 0.88, 0.80]);
  const passiveS = extrusion('Passive 1.0 x 0.5', rect(1.0, 0.5), 0.35, [0.84, 0.74, 0.56]);
  const passiveL = extrusion('Passive 1.6 x 0.8', rect(1.6, 0.8), 0.45, [0.78, 0.82, 0.62]);
  const spacer = cylinder('Spacer D1.2', 0.6, 1.2, [0.86, 0.86, 0.86]);
  const cap = cylinder('Round cap D2.4', 1.2, 1.5, [0.70, 0.80, 0.88]);
  const pin = extrusion('Pin 0.64', rect(0.64, 0.64), 6, [0.92, 0.84, 0.56]);
  const housing = extrusion('Header housing 1 x 20', rect(50.8, 2.54), 2.5, [0.66, 0.66, 0.70]);
  const standoff = cylinder('Standoff D5', 2.5, 5, [0.80, 0.82, 0.84]);
  const nut = extrusion('Hex nut M3', polygon(6, 3.2), 2.4, [0.88, 0.88, 0.90]);
  const washer = cylinder('Washer D7', 3.5, 0.5, [0.76, 0.78, 0.80]);
  const contact = cylinder('Contact D0.8', 0.4, 0.3, [0.93, 0.80, 0.52]);
  const label = extrusion('Label 20 x 8', rect(20, 8), 0.1, [0.95, 0.95, 0.92]);

  // Pad group: four pads in a row.
  const padGroup = assembly('Pad group 4');
  for (let i = 0; i < 4; i++) use(padGroup, pad, [(i - 1.5) * 0.8, 0, 0]);
  finish(padGroup);

  // Contact group: four contacts on the corners of a 5.6 x 9.6 mm cell.
  const contacts = assembly('Contact group 4');
  for (const [x, y] of [[-2.8, -4.8], [2.8, -4.8], [2.8, 4.8], [-2.8, 4.8]]) use(contacts, contact, [x, y, 0]);
  finish(contacts);

  // Three cell variants, each about 7 x 11 mm.
  const cellA = assembly('Cell A');
  use(cellA, blockA, [0, 0.5, 0]);
  use(cellA, padGroup, [0, 3.4, 0]); use(cellA, padGroup, [0, -2.4, 0], 2);
  for (let i = 0; i < 4; i++) use(cellA, passiveS, [-2.6 + (i % 2) * 5.2, -4.2 + Math.floor(i / 2) * 9, 0], 1);
  use(cellA, passiveL, [-1.5, -4.4, 0]); use(cellA, passiveL, [1.5, -4.4, 0]);
  use(cellA, spacer, [-2.8, 4.6, 0]); use(cellA, spacer, [2.8, 4.6, 0]);
  use(cellA, contacts, [0, 0, 0]);
  finish(cellA);
  const cellB = assembly('Cell B');
  use(cellB, blockB, [0, -1, 0]);
  use(cellB, padGroup, [-2.6, 1.5, 0], 1); use(cellB, padGroup, [2.6, 1.5, 0], 1);
  for (let i = 0; i < 6; i++) use(cellB, passiveS, [-2 + (i % 3) * 2, -4.4 + Math.floor(i / 3) * 0.9, 0]);
  use(cellB, cap, [0, 3.2, 0]);
  use(cellB, contacts, [0, 0, 0]);
  finish(cellB);
  const cellC = assembly('Cell C');
  use(cellC, blockC, [0, 0, 0], 1);
  for (let i = 0; i < 3; i++) use(cellC, padGroup, [0, -4 + i * 4, 0], i === 1 ? 0 : 2);
  for (let i = 0; i < 3; i++) use(cellC, passiveL, [2.4, -3.5 + i * 3.5, 0], 1);
  use(cellC, contacts, [0, 0, 0]);
  finish(cellC);

  // Pin header: 20 pins standing in a housing.
  const header = assembly('Header 1 x 20');
  use(header, housing, [0, 0, 0]);
  for (let i = 0; i < 20; i++) use(header, pin, [(i - 9.5) * 2.54, 0, -2.5]);
  finish(header);

  // Fastener stack: washer and nut.
  const fastener = assembly('Fastener M3');
  use(fastener, washer, [0, 0, 0]);
  use(fastener, nut, [0, 0, 0.5]);
  finish(fastener);

  const root = assembly('Sample assembly');
  use(root, plate, [0, 0, 0]);
  const cells = [cellA, cellB, cellC];
  for (let row = 0; row < 5; row++)
    for (let col = 0; col < 30; col++)
      use(root, cells[(row + col) % 3], [12 + col * 7.6, 10 + row * 11.6, 1.6], (row * 30 + col) % 7 === 0 ? 2 : 0);
  use(root, header, [62, 67.5, 1.6]); use(root, header, [186, 67.5, 1.6]);
  use(root, header, [62, 4.5, 1.6], 2); use(root, header, [186, 4.5, 1.6], 2);
  use(root, label, [124, 66, 1.6]);
  const corners = [[4.5, 4.5], [243.5, 4.5], [243.5, 67.5], [4.5, 67.5], [124, 4.5], [124, 36]];
  for (const [x, y] of corners) {
    use(root, fastener, [x, y, 1.6]);
    use(root, standoff, [x, y, 0], 0, true);
  }
  finish(root);

  usages.forEach(write => write());
  add(`MECHANICAL_DESIGN_GEOMETRIC_PRESENTATION_REPRESENTATION('',(${styles.map(s => '#' + s).join(',')}),#${ctx})`);
  const header214 = [
    'ISO-10303-21;',
    'HEADER;',
    "FILE_DESCRIPTION(('Shenzhen 3D generated sample assembly'),'2;1');",
    "FILE_NAME('sample-assembly.step','2026-01-01T00:00:00',(''),(''),'scripts/fixtures/make-sample-assembly.mjs','','');",
    "FILE_SCHEMA(('AUTOMOTIVE_DESIGN { 1 0 10303 214 1 1 1 1 }'));",
    'ENDSEC;',
    'DATA;',
  ];
  return {
    text: [...header214, ...lines, 'ENDSEC;', 'END-ISO-10303-21;', ''].join('\n'),
    geometries: solids,
    solidOccurrences: root.solids,
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const out = process.argv[2] || 'fixtures/sample-assembly.step';
  const {text, geometries, solidOccurrences} = generateSampleAssembly();
  fs.mkdirSync(path.dirname(out), {recursive: true});
  fs.writeFileSync(out, text);
  console.log(`${out}: ${text.length.toLocaleString('en')} bytes, ${solidOccurrences.toLocaleString('en')} solid occurrences of ${geometries} geometries`);
}
