import {Triangle, Vector3, type BufferGeometry, type BufferAttribute, type InterleavedBufferAttribute} from 'three';
import type {Vec3} from './types';

export interface SurfacePath {length:number; points:Vec3[]; approximate:true}
interface Graph {position:BufferAttribute|InterleavedBufferAttribute; index:BufferAttribute|null; points:Vec3[]; triangles:number[][]; neighbors:Map<number,number>[]; tolerance:number; positionVersion:number; indexVersion:number}
const graphs=new WeakMap<BufferGeometry,Graph>();
const distance=(a:Vec3,b:Vec3)=>Math.hypot(a[0]-b[0],a[1]-b[1],a[2]-b[2]);

/** Binary min heap; avoids sorting the complete frontier for every visited vertex. */
class Frontier {
  private values:{id:number; cost:number}[]=[];
  push(id:number,cost:number){const entry={id,cost};let i=this.values.length;this.values.push(entry);while(i>0){const parent=(i-1)>>1;if(this.values[parent].cost<=cost)break;this.values[i]=this.values[parent];i=parent;}this.values[i]=entry;}
  pop(){const first=this.values[0],last=this.values.pop();if(!last)return undefined;if(this.values.length){let i=0;while(i*2+1<this.values.length){let child=i*2+1;if(child+1<this.values.length&&this.values[child+1].cost<this.values[child].cost)child++;if(this.values[child].cost>=last.cost)break;this.values[i]=this.values[child];i=child;}this.values[i]=last;}return first;}
}
function buildGraph(geometry:BufferGeometry):Graph|undefined {
  const position=geometry.getAttribute('position'),index=geometry.index;
  if(!position||position.count<3)return;
  const positionVersion='version' in position?position.version:position.data.version;
  const cached=graphs.get(geometry);
  if(cached&&cached.position===position&&cached.index===index&&cached.positionVersion===positionVersion&&cached.indexVersion===(index?.version??-1))return cached;
  const points:Vec3[]=[], remap:number[]=[],weld=new Map<string,number>();
  let scale=0;
  for(let i=0;i<position.count;i++){
    const point:Vec3=[position.getX(i),position.getY(i),position.getZ(i)];
    if(!point.every(Number.isFinite))return;
    scale=Math.max(scale,...point.map(Math.abs));
    // Coincident positions weld CAD face seams and unindexed STL triangles. Exact
    // coordinates avoid bridging a real thin gap or accidentally merging parts.
    const key=point.join(',');let id=weld.get(key);
    if(id===undefined){id=points.length;weld.set(key,id);points.push(point);}remap.push(id);
  }
  const neighbors=points.map(()=>new Map<number,number>()),triangles:number[][]=[];
  const count=index?.count??position.count;
  for(let i=0;i+2<count;i+=3){
    const ids=[0,1,2].map(j=>remap[index?index.getX(i+j):i+j]);
    if(ids.some(id=>id===undefined))return;
    triangles.push(ids);
    for(let j=0;j<3;j++){const a=ids[j],b=ids[(j+1)%3];if(a===b)continue;const length=distance(points[a],points[b]);neighbors[a].set(b,length);neighbors[b].set(a,length);}
  }
  const graph={position,index,points,triangles,neighbors,tolerance:Math.max(scale*1e-7,1e-8),positionVersion,indexVersion:index?.version??-1};graphs.set(geometry,graph);return graph;
}
function anchorTriangle(graph:Graph,point:Vec3,requested?:number):number|undefined {
  const query=new Vector3(...point),nearest=new Vector3(),triangle=new Triangle();
  const squaredTolerance=graph.tolerance**2;
  function contains(id:number){const ids=graph.triangles[id];if(!ids)return false;triangle.set(...ids.map(i=>new Vector3(...graph.points[i])) as [Vector3,Vector3,Vector3]);triangle.closestPointToPoint(query,nearest);return nearest.distanceToSquared(query)<=squaredTolerance;}
  if(requested!==undefined)return Number.isInteger(requested)&&contains(requested)?requested:undefined;
  for(let id=0;id<graph.triangles.length;id++)if(contains(id))return id;
}
/**
 * Shortest route on the welded triangle-edge graph, with real picked-point anchors.
 * All coordinates are geometry-local. This is a surface-constrained approximation,
 * not an exact continuous geodesic. Disconnected surfaces return undefined.
 */
export function surfacePath(geometry:BufferGeometry,start:Vec3,end:Vec3,startTriangle?:number,endTriangle?:number):SurfacePath|undefined {
  if(![...start,...end].every(Number.isFinite))return;
  const graph=buildGraph(geometry);if(!graph)return;
  const a=anchorTriangle(graph,start,startTriangle),b=anchorTriangle(graph,end,endTriangle);if(a===undefined||b===undefined)return;
  if(a===b)return {length:distance(start,end),points:[[...start],[...end]],approximate:true};
  const total=graph.points.length,endId=total,costs=new Float64Array(total+1).fill(Infinity),previous=new Int32Array(total+1).fill(-1),frontier=new Frontier();
  const endVertices=new Set(graph.triangles[b]);
  for(const id of graph.triangles[a]){const cost=distance(start,graph.points[id]);costs[id]=cost;frontier.push(id,cost+distance(graph.points[id],end));}
  let entry;
  while((entry=frontier.pop())){
    const {id,cost}=entry;if(id===endId)break;
    if(cost>costs[id]+distance(graph.points[id],end)+graph.tolerance)continue;
    const visit=(next:number,weight:number)=>{const candidate=costs[id]+weight;if(candidate<costs[next]){costs[next]=candidate;previous[next]=id;frontier.push(next,candidate+(next===endId?0:distance(graph.points[next],end)));}};
    for(const [next,weight] of graph.neighbors[id])visit(next,weight);
    if(endVertices.has(id))visit(endId,distance(graph.points[id],end));
  }
  if(!Number.isFinite(costs[endId]))return;
  const route:Vec3[]=[[...end]];let id=previous[endId];while(id>=0){route.push([...graph.points[id]]);id=previous[id];}route.push([...start]);route.reverse();
  const points=route.filter((point,i)=>i===0||distance(point,route[i-1])>1e-14);
  return {length:costs[endId],points,approximate:true};
}
