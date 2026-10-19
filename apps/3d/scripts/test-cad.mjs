import assert from 'node:assert/strict';
import fs from 'node:fs';
import {Matrix4,Vector3} from 'three';
import {createKernel,importOptions,summarizeModel} from './benchmark.mjs';
import {checkSplitAssembly} from './test-cad-split.mjs';
const started=performance.now(),occt=await createKernel(),results=[];
const near=(actual,expected,tolerance=1e-7)=>assert.ok(Math.abs(actual-expected)<=tolerance,`${actual} != ${expected}`);
const query=result=>{assert.equal(result.ok,true,result.message);return result;};
const models=[];
function open(result){assert.equal(result.success,true,result.error);assert.ok(result.exactModelId);models.push(result.exactModelId);return result;}
function check(name,test){test();results.push({name,passed:true});console.log(`PASS ${name}`);}
try{
  const box=open(occt.OpenExactExtrudedShape({units:'mm',profile:{start:[0,0],segments:[{kind:'line',end:[10,0]},{kind:'line',end:[10,20]},{kind:'line',end:[0,20]},{kind:'line',end:[0,0]}]},extrusion:{depth:30}}));
  const id=box.exactModelId,handle=box.exactGeometryBindings[0].exactShapeHandle,geometry=box.geometries[0],bindings=box.extrudedShape.faceBindings;
  const bottom=bindings.find(b=>b.systemRole==='start_cap').faceId,top=bindings.find(b=>b.systemRole==='end_cap').faceId,identity=new Matrix4().toArray();
  check('exact box face area 200 mm²',()=>near(query(occt.MeasureExactFaceArea(id,handle,'face',bottom)).value,200));
  check('exact box edge lengths 10, 20, 30 mm',()=>{const lengths=geometry.edges.map(e=>query(occt.MeasureExactEdgeLength(id,handle,'edge',e.id)).value);for(const length of lengths)assert.ok([10,20,30].some(expected=>Math.abs(length-expected)<1e-7));assert.equal(lengths.length,12);});
  check('exact parallel face distance and thickness 30 mm',()=>{near(query(occt.MeasureExactDistance(id,handle,'face',bottom,handle,'face',top,identity,identity)).value,30);near(query(occt.MeasureExactThickness(id,handle,'face',bottom,handle,'face',top,identity,identity)).value,30);});
  check('exact perpendicular face angle π/2 radians',()=>{const a=bindings.find(b=>b.segmentIndex===0).faceId,b=bindings.find(b=>b.segmentIndex===1).faceId;near(query(occt.MeasureExactAngle(id,handle,'face',a,handle,'face',b,identity,identity)).value,Math.PI/2);});
  check('transformed occurrence face distance 70 mm',()=>{const translated=new Matrix4().makeTranslation(0,0,100).toArray();near(query(occt.MeasureExactDistance(id,handle,'face',top,handle,'face',bottom,identity,translated)).value,70);});
  check('rotated and translated occurrence vertex distance',()=>{const vertex=geometry.vertices[0],a=new Matrix4().makeRotationY(.6).setPosition(20,-5,40),b=new Matrix4().makeRotationZ(-.4).setPosition(-7,8,11);const expected=new Vector3(...vertex.position).applyMatrix4(a).distanceTo(new Vector3(...vertex.position).applyMatrix4(b));near(query(occt.MeasureExactDistance(id,handle,'vertex',vertex.id,handle,'vertex',vertex.id,a.toArray(),b.toArray())).value,expected);});
  const cylinder=open(occt.OpenExactExtrudedShape({units:'mm',profile:{start:[5,0],segments:[{kind:'arc_center',center:[0,0],end:[0,5]},{kind:'arc_center',center:[0,0],end:[-5,0]},{kind:'arc_center',center:[0,0],end:[0,-5]},{kind:'arc_center',center:[0,0],end:[5,0]}]},extrusion:{depth:12}}));
  const cylinderHandle=cylinder.exactGeometryBindings[0].exactShapeHandle;
  check('exact circle radius 5 mm, diameter 10 mm and arc length',()=>{const circles=cylinder.geometries[0].edges.filter(edge=>occt.GetExactGeometryType(cylinder.exactModelId,cylinderHandle,'edge',edge.id).family==='circle');assert.ok(circles.length);for(const edge of circles){const radius=query(occt.MeasureExactRadius(cylinder.exactModelId,cylinderHandle,'edge',edge.id));near(radius.radius,5);near(radius.diameter,10);near(query(occt.MeasureExactEdgeLength(cylinder.exactModelId,cylinderHandle,'edge',edge.id)).value,Math.PI*2.5);}});
  check('exact circular face area 25π mm²',()=>{const face=cylinder.extrudedShape.faceBindings.find(b=>b.systemRole==='start_cap').faceId;near(query(occt.MeasureExactFaceArea(cylinder.exactModelId,cylinderHandle,'face',face)).value,25*Math.PI);});
  check('exact handle retain, release and invalid handle rejection',()=>{assert.equal(occt.RetainExactModel(id).ok,true);assert.equal(occt.ReleaseExactModel(id).ok,true);assert.equal(occt.MeasureExactFaceArea(id,handle,'face',bottom).ok,true);assert.equal(occt.MeasureExactFaceArea(id,handle,'face',999999).ok,false);});
  const importStart=performance.now(),assembly=open(occt.OpenExactStepModel(fs.readFileSync('fixtures/sample-assembly.step'),importOptions)),importMs=performance.now()-importStart,summary=summarizeModel(assembly);
  check('Sample STEP assembly instances, transforms, colors and dimensions',()=>{assert.equal(summary.stats.partCount,3154);assert.equal(summary.nodeCount,3815);assert.equal(summary.stats.geometryCount,16);assert.equal(summary.meshInstances,3154);assert.equal(summary.uniqueTriangles,960);assert.equal(summary.renderedTriangles,153720);assert.equal(summary.nonIdentityTransforms,3603);assert.equal(summary.invalidTransforms,0);assert.equal(summary.materials,16);assert.equal(summary.coloredGeometries,16);near(summary.unitScaleToMeters,.001);[248,72,10.1].forEach((value,i)=>near(summary.bounds.size[i],value,.001));});
  check('Sample STEP face topology maps to valid exact handles',()=>{for(const g of assembly.geometries){const binding=assembly.exactGeometryBindings.find(b=>b.geometryId===g.id);assert.ok(binding);const faceIds=new Set(g.faces.map(f=>f.id));assert.equal(g.triangleToFaceMap.length,g.indices.length/3);for(const faceId of g.triangleToFaceMap)assert.ok(faceIds.has(faceId));for(const face of g.faces.slice(0,1)){const area=query(occt.MeasureExactFaceArea(assembly.exactModelId,binding.exactShapeHandle,'face',face.id));assert.ok(area.value>0);}}});
  check('Sample STEP read part by part matches the whole-file assembly',()=>checkSplitAssembly(occt,fs.readFileSync('fixtures/sample-assembly.step'),assembly));
  while(models.length){const released=models.pop();assert.equal(occt.ReleaseExactModel(released).ok,true);assert.equal(occt.ReleaseExactModel(released).ok,false);}
  check('all exact models released',()=>assert.equal(occt.GetExactModelDiagnostics().liveExactModelCount,0));
  const report={date:new Date().toISOString(),checks:results.length,results,elapsedMs:performance.now()-started,assemblyImportMs:importMs,assembly:summary};fs.mkdirSync('artifacts',{recursive:true});fs.writeFileSync('artifacts/cad-validation.json',JSON.stringify(report,null,2)+'\n');console.log(`${results.length} CAD regression checks passed; STEP import ${Math.round(importMs)} ms.`);
}finally{for(const id of models)occt.ReleaseExactModel(id);}
