import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {Matrix4,Vector3,Box3} from 'three';
import Occt from '../vendor/occt/occt-js.cjs';

export const importOptions={linearUnit:'millimeter',linearDeflectionType:'absolute_value',linearDeflection:.05,angularDeflection:.3,readColors:true,readNames:true};
export async function createKernel(){return Occt({wasmBinary:fs.readFileSync(new URL('../vendor/occt/occt-js.wasm',import.meta.url))});}
export function summarizeModel(model){
  const bounds=new Box3(),point=new Vector3();let nodeCount=0,meshInstances=0,renderedTriangles=0,nonIdentityTransforms=0,invalidTransforms=0;
  const identity=new Matrix4();
  function walk(node,parent){nodeCount++;const local=new Matrix4().fromArray(node.transform);if(node.transform.length!==16||!node.transform.every(Number.isFinite))invalidTransforms++;if(!local.equals(identity))nonIdentityTransforms++;const world=parent.clone().multiply(local);
    for(const index of node.meshes){const geometry=model.geometries[index];if(!geometry)throw new Error(`Missing geometry ${index}`);meshInstances++;renderedTriangles+=geometry.indices.length/3;for(let i=0;i<geometry.positions.length;i+=3)bounds.expandByPoint(point.fromArray(geometry.positions,i).applyMatrix4(world));}
    node.children.forEach(child=>walk(child,world));
  }
  model.rootNodes.forEach(root=>walk(root,new Matrix4()));
  return {stats:model.stats,sourceUnit:model.sourceUnit,unitScaleToMeters:model.unitScaleToMeters,nodeCount,meshInstances,renderedTriangles,nonIdentityTransforms,invalidTransforms,uniqueTriangles:model.geometries.reduce((sum,g)=>sum+g.indices.length/3,0),geometryBytes:model.geometries.reduce((sum,g)=>sum+g.positions.byteLength+g.normals.byteLength+g.indices.byteLength+g.triangleToFaceMap.byteLength,0),materials:model.materials.length,coloredGeometries:model.geometries.filter(g=>g.color||g.faces.some(f=>f.color)).length,bounds:{min:bounds.min.toArray(),max:bounds.max.toArray(),size:bounds.getSize(new Vector3()).toArray()}};
}
async function main(){
  const filename=process.argv[2]||'fixtures/sample-assembly.step',bytes=fs.readFileSync(filename),started=performance.now(),occt=await createKernel(),ready=performance.now();
  const model=occt.OpenExactStepModel(bytes,importOptions),imported=performance.now();
  if(!model.success)throw new Error(model.error||'STEP import failed');
  try{const summary={file:path.basename(filename),fileBytes:bytes.length,kernelMs:ready-started,importMs:imported-ready,...summarizeModel(model)};fs.mkdirSync('artifacts',{recursive:true});fs.writeFileSync('artifacts/step-benchmark.json',JSON.stringify(summary,null,2)+'\n');console.log(JSON.stringify(summary,null,2));}
  finally{occt.ReleaseExactModel(model.exactModelId);}
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url))main().catch(error=>{console.error(error);process.exitCode=1;});
