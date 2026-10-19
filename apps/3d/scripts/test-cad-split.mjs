// Part-by-part STEP reading must reproduce the whole-file assembly: same tree,
// node ids, names, placements (bit for bit), geometry order, faces and colours.
// Tessellation may differ by a few triangles because each product is healed on
// its own; totals must stay within 0.1%.
import assert from 'node:assert/strict';
import {planStep} from '../src/core/step/step-plan.ts';
import {assembleModel} from '../src/core/step/step-assemble.ts';
import {importOptions} from './benchmark.mjs';

const options={...importOptions,colorMode:'source',rootMode:'multiple-shapes'};
const flat=roots=>{const out=[];const walk=(n,d)=>{out.push([n.id,n.name,d,n.isAssembly,n.meshes.join(),n.transform.join()]);n.children.forEach(c=>walk(c,d+1));};roots.forEach(r=>walk(r,0));return out;};

export function checkSplitAssembly(occt,bytes,whole){
  const planned=planStep(new Uint8Array(bytes));
  assert.equal(planned.ok,true,planned.reason);
  const results=new Map();
  for(const part of planned.plan.parts){const result=occt.ReadStepFile(part.bytes,options);assert.equal(result.success,true,result.error);results.set(part.pd,{result});}
  const model=assembleModel(planned.plan.assembly,results);
  assert.deepEqual(flat(model.rootNodes),flat(whole.rootNodes));
  assert.deepEqual(model.geometries.map(g=>[g.id,g.name,JSON.stringify(g.color),g.faces.length,g.edges.length,JSON.stringify(g.faces.map(f=>f.color))]),whole.geometries.map(g=>[g.id,g.name,JSON.stringify(g.color),g.faces.length,g.edges.length,JSON.stringify(g.faces.map(f=>f.color))]));
  const triangles=list=>list.reduce((sum,g)=>sum+g.indices.length/3,0);
  assert.ok(Math.abs(triangles(model.geometries)-triangles(whole.geometries))<=triangles(whole.geometries)*1e-3);
  assert.equal(model.stats.reusedInstanceCount,whole.stats.reusedInstanceCount);
}
