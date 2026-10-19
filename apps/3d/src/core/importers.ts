import * as T from 'three';
import { cad } from './cad-client';
import { sourceUnit } from './units';
import type {ModelDocument, GeometryData, Part, TreeNode, Unit, CadResult} from './types';
import { SUPPORTED } from './formats';
import { SPLIT_MIN_BYTES } from './step/split-threshold';
export { SUPPORTED, ACCEPT } from './formats';
const ext=(name:string)=>name.split('.').pop()!.toLowerCase();
const material=(color:T.ColorRepresentation=0xb8c7cc)=>new T.MeshStandardMaterial({color,roughness:.48,metalness:.12,side:T.DoubleSide});
/** `shared` lets successive views of a loading assembly reuse built geometry. */
export function fromCad(result:CadResult,name:string,shared?:WeakMap<object,GeometryData>):ModelDocument {
 const geometries=new Map<string,GeometryData>();
 result.geometries?.forEach(g=>{
  const exactHandle=result.exactGeometryBindings?.find(b=>b.geometryId===g.id)?.exactShapeHandle;
  const known=shared?.get(g.positions);if(known){geometries.set(g.id,{...known,id:g.id,exactHandle});return}
  const geometry=new T.BufferGeometry();geometry.setAttribute('position',new T.BufferAttribute(g.positions,3));geometry.setAttribute('normal',new T.BufferAttribute(g.normals,3));geometry.setIndex(new T.BufferAttribute(g.indices,1));
  const materials:T.Material[]=[];const colors=new Map<string,number>();
  const getMaterial=(c:typeof g.color)=>{const color=c||{r:.70,g:.76,b:.8};const key=JSON.stringify(color);if(colors.has(key))return colors.get(key)!;const m=material(new T.Color(color.r,color.g,color.b));m.opacity=color.opacity??1;m.transparent=m.opacity<1;colors.set(key,materials.length);materials.push(m);return materials.length-1};
  for(const f of g.faces)geometry.addGroup(f.firstIndex,f.indexCount,getMaterial(f.color||g.color));
  if(!materials.length)materials.push(material());
  const data={id:g.id,geometry,materials,topology:g,exactHandle};geometries.set(g.id,data);shared?.set(g.positions,data);
 });
 const parts:Part[]=[];
 const walk=(node:NonNullable<CadResult['rootNodes']>[number],parent:T.Matrix4,path:string[]):TreeNode=>{
  const matrix=parent.clone().multiply(new T.Matrix4().fromArray(node.transform));const fullPath=[...path,node.name];const partIds:string[]=[];
  node.meshes.forEach((index,i)=>{const g=result.geometries![index];const id=node.id+':'+i;partIds.push(id);parts.push({id,name:node.name||g.name||'Part',geometryId:g.id,matrix:matrix.toArray(),parentId:node.id,path:fullPath})});
  return {id:node.id,name:node.name||'Assembly',partIds,children:node.children.map(c=>walk(c,matrix,fullPath))};
 };
 const roots=result.rootNodes!.map(n=>walk(n,new T.Matrix4(),[]));
 return {name,format:ext(name),geometries,parts,roots,unit:'mm',sourceUnit:result.sourceUnit||'Unknown (assumed mm)',warnings:(result.warnings||[]).map(w=>typeof w==='string'?w:JSON.stringify(w)),importMs:0,bytes:0,exactModelId:result.exactModelId,exactWorkerGeneration:result.exactWorkerGeneration,is2D:false};
}
export function fromObject(root:T.Object3D,name:string,unit:Unit='mm',warnings:string[]=[],is2D=false):ModelDocument{
 root.updateMatrixWorld(true);const geometries=new Map<string,GeometryData>(),parts:Part[]=[];
 const walk=(node:T.Object3D,path:string[]):TreeNode=>{
  const id=node.uuid;const partIds:string[]=[];const full=[...path,node.name||'Part'];
  if(node instanceof T.Mesh||node instanceof T.Line){const key=node.geometry.uuid+':'+(Array.isArray(node.material)?node.material.map(m=>m.uuid).join(','):node.material.uuid);if(!geometries.has(key)){
   const geometry=node.geometry;const materials=Array.isArray(node.material)?node.material:[node.material];
   if(!geometry.index && node instanceof T.Mesh){geometry.setIndex(Array.from({length:geometry.attributes.position.count},(_,i)=>i))}
   if(!geometry.attributes.normal && node instanceof T.Mesh)geometry.computeVertexNormals();
   geometries.set(key,{id:key,geometry,materials,lines:node instanceof T.Line});
  }
  partIds.push(id);parts.push({id,name:node.name||name,geometryId:key,matrix:node.matrixWorld.toArray(),parentId:id,path:full});}
  return {id,name:node.name||name,partIds,children:node.children.map(n=>walk(n,full))};
 };
 return {name,format:ext(name),geometries,parts,roots:[walk(root,[])],unit,sourceUnit:unit,warnings,importMs:0,bytes:0,is2D};
}
export async function importFiles(files:File[],quality:string,onProgress:(s:string)=>void,onPartial?:(doc:ModelDocument)=>void):Promise<ModelDocument>{
 const file=files.find(f=>SUPPORTED.includes(ext(f.name)));if(!file)throw new Error('Choose a supported 3D model or 2D drawing.');
 const start=performance.now();const format=ext(file.name);onProgress('Reading '+file.name);const buffer=await file.arrayBuffer();let doc:ModelDocument;
 if(['step','stp','iges','igs','brep','brp'].includes(format)){
  let source:ArrayBuffer|undefined=buffer,split:ModelDocument|undefined;
  if((format==='step'||format==='stp')&&file.size>=SPLIT_MIN_BYTES){
   // Large assemblies are read product by product; see docs/PERFORMANCE.md.
   const {importSplitStep}=await import('./step/split-import');
   const outcome=await importSplitStep(buffer,{name:file.name,quality,onProgress,onPartial});
   if('fallback' in outcome)source=outcome.fallback;else split=outcome;
  }
  if(split)doc=split;
  else{onProgress('Reading CAD geometry and assembly…');const result=await cad.open(({stp:'step',igs:'iges',brp:'brep'} as Record<string,string>)[format]||format,source!,quality);doc=fromCad(result,file.name);}
 }else if(format==='dxf'||format==='dwg'){
  onProgress('Reading drawing entities…');const {importDrawing}=await import('./drawing');doc=await importDrawing(buffer,file.name,format);
 }else{
  onProgress('Building model…');const urls:string[]=[];const warnings:string[]=[];const manager=new T.LoadingManager();
  manager.setURLModifier(url=>{if(url.startsWith('blob:')||url.startsWith('data:'))return url;const decoded=decodeURIComponent(url).split(/[\\/]/).pop();const f=files.find(f=>f.name===decoded);if(f){const objectUrl=URL.createObjectURL(f);urls.push(objectUrl);return objectUrl;}warnings.push('Missing companion file: '+decoded);return 'data:application/octet-stream;base64,';});
  manager.onError=url=>warnings.push('Could not load texture or companion: '+url.slice(0,100));
  const text=()=>new TextDecoder().decode(buffer);let object:T.Object3D;let unit:Unit='mm';let sourceDescription:string|undefined;
  try{
   switch(format){
    case 'stl': {const {STLLoader}=await import('three/addons/loaders/STLLoader.js');const g=new STLLoader().parse(buffer);const m=material();if(g.hasAttribute('color'))m.vertexColors=true;object=new T.Mesh(g,m);warnings.push('STL has no standard units. Confirm source units before measuring.');break}
    case 'obj': {const {OBJLoader}=await import('three/addons/loaders/OBJLoader.js');const loader=new OBJLoader(manager);const mtl=files.find(f=>ext(f.name)==='mtl');if(mtl){const {MTLLoader}=await import('three/addons/loaders/MTLLoader.js');const materials=new MTLLoader(manager).parse(await mtl.text(),'');materials.preload();loader.setMaterials(materials)}object=loader.parse(text());warnings.push('OBJ coordinates are unitless. Confirm source units.');break}
    case 'glb':case 'gltf':{const {GLTFLoader}=await import('three/addons/loaders/GLTFLoader.js');const {DRACOLoader}=await import('three/addons/loaders/DRACOLoader.js');const draco=new DRACOLoader(manager).setDecoderPath('/draco/');const loader=new GLTFLoader(manager).setDRACOLoader(draco);const {MeshoptDecoder}=await import('three/addons/libs/meshopt_decoder.module.js');loader.setMeshoptDecoder(MeshoptDecoder);try{object=(await loader.parseAsync(buffer,'')).scene;}finally{draco.dispose()}unit='m';break}
    case '3mf': {const {ThreeMFLoader}=await import('three/addons/loaders/3MFLoader.js');object=new ThreeMFLoader(manager).parse(buffer);object.traverse(node=>{if(node instanceof T.Mesh){const materials=Array.isArray(node.material)?node.material:[node.material];for(const m of materials)if(m.opacity<1)m.transparent=true}});const {unzipSync}=await import('fflate');const zip=unzipSync(new Uint8Array(buffer));const model=Object.keys(zip).find(k=>k.toLowerCase()==='3d/3dmodel.model')||Object.keys(zip).find(k=>k.endsWith('.model'));unit=sourceUnit(model?new TextDecoder().decode(zip[model]).match(/<model[^>]*\bunit="([^"]+)"/)?.[1]:'mm');break}
    case 'ply':{const {PLYLoader}=await import('three/addons/loaders/PLYLoader.js');const g=new PLYLoader().parse(buffer);const m=material();m.vertexColors=g.hasAttribute('color');object=new T.Mesh(g,m);warnings.push('PLY units are assumed millimeters.');break}
    case 'fbx':{
     const {FBXLoader}=await import('three/addons/loaders/FBXLoader.js');object=new FBXLoader(manager).parse(buffer,'');unit='cm';
     // FBXLoader preserves source coordinates and exposes centimeters per unit as metadata.
     const factor=Number(object.userData.unitScaleFactor);
     if(Number.isFinite(factor)&&factor>0){object.position.multiplyScalar(factor);object.scale.multiplyScalar(factor);sourceDescription=`FBX ${factor} cm per unit (normalized to cm)`}
     else warnings.push('FBX has no valid unit metadata. Centimeters are assumed; verify source scale.');
     break
    }
    case 'dae':{const {ColladaLoader}=await import('three/addons/loaders/ColladaLoader.js');object=new ColladaLoader(manager).parse(text(),'')!.scene;unit='m';break}
    case 'wrl':case 'vrml':{const {VRMLLoader}=await import('three/addons/loaders/VRMLLoader.js');object=new VRMLLoader(manager).parse(text(),'');unit='m';warnings.push('VRML uses meters by specification. KiCad libraries may use 0.1 inch per unit; set source units or a custom scale if needed.');break}
    case 'off':{object=parseOFF(text());warnings.push('OFF units are assumed millimeters.');break}
    case 'svg':{const {SVGLoader}=await import('three/addons/loaders/SVGLoader.js');const data=new SVGLoader().parse(text());const group=new T.Group();for(const path of data.paths){const style=path.userData?.style as Record<string,string|number>|undefined;if(style?.fill!=='none'){for(const shape of SVGLoader.createShapes(path)){const m=new T.MeshBasicMaterial({color:path.color,side:T.DoubleSide,transparent:true,opacity:Number(style?.fillOpacity??1),depthWrite:false});group.add(new T.Mesh(new T.ShapeGeometry(shape,32),m))}}if(style?.stroke && style.stroke!=='none')for(const sub of path.subPaths){const points=sub.getPoints(96);if(points.length>1){const g=new T.BufferGeometry().setFromPoints(points);group.add(new T.Line(g,new T.LineBasicMaterial({color:style?.stroke && style.stroke!=='none'?String(style.stroke):path.color})))}}}group.scale.y=-1;const root=data.xml as unknown as Element;const width=root.getAttribute('width')||'';const vb=root.getAttribute('viewBox')?.split(/[ ,]+/).map(Number);const unitMatch=width.match(/^([\d.]+)(mm|cm|in|pt|px)?$/);let scale=25.4/96;if(unitMatch){const factor=({mm:1,cm:10,in:25.4,pt:25.4/72,px:25.4/96} as Record<string,number>)[unitMatch[2]||'px'];scale=vb?.[2]?Number(unitMatch[1])*factor/vb[2]:factor}group.scale.multiplyScalar(scale);object=group;warnings.push('SVG curves are sampled for measurements; text and raster images are not imported.');break}
    default:throw new Error('Unsupported file type: '+format);
   }
   object.name=file.name;doc=fromObject(object,file.name,unit,warnings,format==='svg');if(sourceDescription)doc.sourceUnit=sourceDescription;
  }finally{setTimeout(()=>urls.forEach(u=>URL.revokeObjectURL(u)),30000)}
 }
 if(!doc.parts.length){disposeDocument(doc);throw new Error('No displayable geometry found in this file.')}
 doc.importMs=performance.now()-start;doc.bytes=file.size;return doc;
}
function parseOFF(text:string){const words=text.replace(/#[^\n]*/g,'').trim().split(/\s+/);if(words.shift()!=='OFF')throw new Error('Only plain OFF files are supported.');const count=Number(words.shift()),faces=Number(words.shift());words.shift();if(!Number.isSafeInteger(count)||count<0||count>10000000)throw new Error('Invalid OFF vertex count');const positions=words.splice(0,count*3).map(Number),indices:number[]=[];for(let f=0;f<faces;f++){const n=Number(words.shift());const face=words.splice(0,n).map(Number);for(let i=1;i<n-1;i++)indices.push(face[0],face[i],face[i+1])}const g=new T.BufferGeometry();g.setAttribute('position',new T.Float32BufferAttribute(positions,3));g.setIndex(indices);g.computeVertexNormals();return new T.Mesh(g,material())}
export function disposeDocument(doc:ModelDocument){const materials=new Set<T.Material>();const textures=new Set<T.Texture>();for(const g of doc.geometries.values()){g.geometry.dispose();for(const m of g.materials){materials.add(m);for(const value of Object.values(m))if(value instanceof T.Texture)textures.add(value)}}materials.forEach(m=>m.dispose());textures.forEach(t=>t.dispose());if(doc.exactModelId)void cad.release(doc.exactModelId,doc.exactWorkerGeneration).catch(()=>{});}
