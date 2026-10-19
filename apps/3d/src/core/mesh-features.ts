import {Vector3,type BufferGeometry,type BufferAttribute,type InterleavedBufferAttribute} from 'three';
import type {FeatureProperties,Vec3} from './types';

export interface MeshFeature {
  properties:FeatureProperties;
  triangleIndices:number[];
  /** Ordered geometry-local boundary polylines; a closed loop repeats its first point. */
  edgePaths:Vec3[][];
  perimeter:number;
  approximate:true;
}
interface Face {vertices:[number,number,number];normal:Vector3;area:number}
interface Topology {
  position:BufferAttribute|InterleavedBufferAttribute;index:BufferAttribute|null;
  positionVersion:number;indexVersion:number;points:Vector3[];faces:Face[];
  edges:Map<string,number[]>;tolerance:number;
}
const cache=new WeakMap<BufferGeometry,Topology>();
// Bound synchronous work and memory. Larger meshes retain triangle-level fallback.
const MAX_TRIANGLES=250_000,MAX_PATCH_TRIANGLES=100_000;
const edgeKey=(a:number,b:number)=>a<b?`${a}:${b}`:`${b}:${a}`;
function topology(geometry:BufferGeometry):Topology|undefined {
  const position=geometry.getAttribute('position'),index=geometry.index;
  if(!position)return;
  const count=index?.count??position.count,positionVersion='version'in position?position.version:position.data.version,indexVersion=index?.version??-1;
  if(count<3||count%3||count/3>MAX_TRIANGLES)return;
  const existing=cache.get(geometry);
  if(existing&&existing.position===position&&existing.index===index&&existing.positionVersion===positionVersion&&existing.indexVersion===indexVersion)return existing;
  const points:Vector3[]=[],remap:number[]=[],welded=new Map<string,number>();
  let scale=0;for(let i=0;i<position.count;i++)scale=Math.max(scale,Math.abs(position.getX(i)),Math.abs(position.getY(i)),Math.abs(position.getZ(i)));
  // Remove roundoff-only seams (for example sin(2π) at a cylinder seam).
  const weldTolerance=Math.max(scale*1e-12,1e-15);
  const minimum=new Vector3(Infinity,Infinity,Infinity),maximum=new Vector3(-Infinity,-Infinity,-Infinity);
  for(let i=0;i<position.count;i++){
    const point=new Vector3(position.getX(i),position.getY(i),position.getZ(i));if(!point.toArray().every(Number.isFinite))return;
    const key=point.toArray().map(value=>Math.round(value/weldTolerance)).join(',');let id=welded.get(key);
    if(id===undefined){id=points.length;points.push(point);welded.set(key,id);minimum.min(point);maximum.max(point);}remap.push(id);
  }
  const faces:Face[]=[],edges=new Map<string,number[]>(),ab=new Vector3(),ac=new Vector3();
  for(let i=0;i<count;i+=3){
    const vertices=[0,1,2].map(j=>remap[index?index.getX(i+j):i+j]) as [number,number,number];if(vertices.some(v=>v===undefined))return;
    const [a,b,c]=vertices.map(v=>points[v]);const normal=ab.subVectors(b,a).cross(ac.subVectors(c,a)).clone();const area=normal.length()/2;normal.normalize();
    const faceId=faces.length;faces.push({vertices,normal,area});if(!area)continue;
    for(let j=0;j<3;j++){const key=edgeKey(vertices[j],vertices[(j+1)%3]);const adjacent=edges.get(key);if(adjacent)adjacent.push(faceId);else edges.set(key,[faceId]);}
  }
  const result={position,index,positionVersion,indexVersion,points,faces,edges,tolerance:Math.max(maximum.distanceTo(minimum)*1e-7,1e-9)};
  cache.set(geometry,result);return result;
}
function boundaryPaths(boundary:[number,number][],points:Vector3[]):Vec3[][] {
  const adjacency=new Map<number,number[]>();
  boundary.forEach(([a,b],i)=>{for(const v of [a,b]){const links=adjacency.get(v);if(links)links.push(i);else adjacency.set(v,[i]);}});
  const used=new Set<number>(),paths:Vec3[][]=[];
  function trace(edgeId:number,start:number){let current=start;const path=[points[current].toArray() as Vec3];
    while(!used.has(edgeId)){used.add(edgeId);const [a,b]=boundary[edgeId];current=current===a?b:a;path.push(points[current].toArray() as Vec3);if(current===start)break;const links=adjacency.get(current)!;if(links.length!==2)break;const next=links.find(i=>!used.has(i));if(next===undefined)break;edgeId=next;}
    paths.push(path);
  }
  // Open or branched boundaries are split at junctions, never invented into loops.
  boundary.forEach(([a,b],i)=>{if(!used.has(i)){if(adjacency.get(a)!.length!==2)trace(i,a);else if(adjacency.get(b)!.length!==2)trace(i,b);}});
  boundary.forEach(([a],i)=>{if(!used.has(i))trace(i,a);});return paths;
}
function fitCircle(path:Vec3[],normal:Vector3,tolerance:number):{radius:number;diameter:number;center:Vec3}|undefined {
  if(path.length<13||new Vector3(...path[0]).distanceTo(new Vector3(...path.at(-1)!))>tolerance)return;
  const points=path.slice(0,-1).map(p=>new Vector3(...p)),origin=points.reduce((sum,p)=>sum.add(p),new Vector3()).multiplyScalar(1/points.length);
  const u=points[0].clone().sub(origin).normalize(),v=new Vector3().crossVectors(normal,u).normalize();if(v.lengthSq()<.5)return;
  const xy=points.map(point=>{const delta=point.clone().sub(origin);return [delta.dot(u),delta.dot(v)];});
  // Algebraic least squares circle fit in a centered local plane.
  const matrix=Array.from({length:3},()=>[0,0,0,0]);
  for(const [x,y]of xy){const row=[2*x,2*y,1],r=x*x+y*y;for(let i=0;i<3;i++){for(let j=0;j<3;j++)matrix[i][j]+=row[i]*row[j];matrix[i][3]+=row[i]*r;}}
  for(let column=0;column<3;column++){let pivot=column;for(let row=column+1;row<3;row++)if(Math.abs(matrix[row][column])>Math.abs(matrix[pivot][column]))pivot=row;if(Math.abs(matrix[pivot][column])<1e-20)return;[matrix[column],matrix[pivot]]=[matrix[pivot],matrix[column]];const divisor=matrix[column][column];for(let j=column;j<4;j++)matrix[column][j]/=divisor;for(let row=0;row<3;row++)if(row!==column){const factor=matrix[row][column];for(let j=column;j<4;j++)matrix[row][j]-=factor*matrix[column][j];}}
  const x=matrix[0][3],y=matrix[1][3],radius=Math.sqrt(matrix[2][3]+x*x+y*y);if(!Number.isFinite(radius)||radius<=tolerance)return;
  if(xy.some(([px,py])=>Math.abs(Math.hypot(px-x,py-y)-radius)>Math.max(radius*.001,tolerance*2)))return;
  // Require broad, dense angular coverage; a square or short arc is not a circle.
  const angles=xy.map(([px,py])=>Math.atan2(py-y,px-x));
  let winding=0,direction=0;for(let i=0;i<angles.length;i++){let step=angles[(i+1)%angles.length]-angles[i];if(step>Math.PI)step-=2*Math.PI;if(step<-Math.PI)step+=2*Math.PI;if(Math.abs(step)>Math.PI/3+1e-6||Math.abs(step)<1e-12)return;const sign=Math.sign(step);if(direction&&direction!==sign)return;direction=sign;winding+=step;}if(Math.abs(Math.abs(winding)-2*Math.PI)>1e-5)return;
  return {radius,diameter:radius*2,center:origin.addScaledVector(u,x).addScaledVector(v,y).toArray() as Vec3};
}
/**
 * Recover a connected coplanar face from triangle meshes without changing indices.
 * Measurements describe the tessellation, not an exact CAD surface. Circular
 * boundaries are fitted only with >=12 samples and <=0.1% radial residual.
 * Undefined means invalid input, degenerate geometry, or the work limit was hit.
 */
export function analyzeMeshFeature(geometry:BufferGeometry,triangleIndex:number):MeshFeature|undefined {
  if(!Number.isInteger(triangleIndex)||triangleIndex<0)return;
  const graph=topology(geometry),seed=graph?.faces[triangleIndex];if(!graph||!seed||seed.area===0)return;
  const origin=graph.points[seed.vertices[0]],selected=new Set<number>([triangleIndex]),queue=[triangleIndex];let area=0;
  for(let i=0;i<queue.length;i++){
    const face=graph.faces[queue[i]];area+=face.area;
    for(let j=0;j<3;j++){
      const neighbors=graph.edges.get(edgeKey(face.vertices[j],face.vertices[(j+1)%3]))!;
      if(neighbors.length!==2)continue; // Do not cross ambiguous non-manifold seams.
      for(const neighbor of neighbors){if(selected.has(neighbor))continue;const candidate=graph.faces[neighbor];
        if(Math.abs(seed.normal.dot(candidate.normal))<1-1e-6||candidate.vertices.some(id=>Math.abs(graph.points[id].clone().sub(origin).dot(seed.normal))>graph.tolerance))continue;
        selected.add(neighbor);queue.push(neighbor);if(queue.length>MAX_PATCH_TRIANGLES)return;
      }
    }
  }
  const boundary:[number,number][]=[],seenEdges=new Set<string>();
  for(const id of queue){const face=graph.faces[id];for(let j=0;j<3;j++){const a=face.vertices[j],b=face.vertices[(j+1)%3],key=edgeKey(a,b);if(seenEdges.has(key))continue;seenEdges.add(key);const neighbors=graph.edges.get(key)!;if(neighbors.filter(n=>selected.has(n)).length===1)boundary.push([a,b]);}}
  const edgePaths=boundaryPaths(boundary,graph.points),perimeter=boundary.reduce((sum,[a,b])=>sum+graph.points[a].distanceTo(graph.points[b]),0);
  const properties:FeatureProperties={family:'plane',area,exact:false};
  if(edgePaths.length===1){const circle=fitCircle(edgePaths[0],seed.normal,graph.tolerance);if(circle)Object.assign(properties,circle);}
  return {properties,triangleIndices:queue,edgePaths,perimeter,approximate:true};
}
