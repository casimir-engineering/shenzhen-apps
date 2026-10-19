import {describe,it,expect} from 'vitest';
import {BufferGeometry,Float32BufferAttribute} from 'three';
import {surfacePath} from '../src/core/surface-path';
function mesh(points:number[],indices?:number[]){const geometry=new BufferGeometry().setAttribute('position',new Float32BufferAttribute(points,3));if(indices)geometry.setIndex(indices);return geometry;}
describe('surface-constrained graph path',()=>{
  it('retains actual interior anchor points and takes direct same-triangle route',()=>{const geometry=mesh([0,0,0,2,0,0,0,2,0]);const result=surfacePath(geometry,[.2,.2,0],[.7,.6,0],0,0)!;expect(result.points).toEqual([[.2,.2,0],[.7,.6,0]]);expect(result.length).toBeCloseTo(Math.hypot(.5,.4));expect(result.approximate).toBe(true);});
  it('welds unindexed duplicate seam vertices and travels over a fold',()=>{const geometry=mesh([0,0,0,1,0,0,0,1,0,1,0,0,1,1,1,0,1,0]);const result=surfacePath(geometry,[0,0,0],[1,1,1],0,1)!;expect(result.length).toBeCloseTo(1+Math.sqrt(2));expect(result.points[0]).toEqual([0,0,0]);expect(result.points.at(-1)).toEqual([1,1,1]);});
  it('supports indexed mesh and implicit triangle discovery',()=>{const geometry=mesh([0,0,0,1,0,0,0,1,0,1,1,0],[0,1,2,1,3,2]);expect(surfacePath(geometry,[0,0,0],[1,1,0])?.length).toBe(2);});
  it('does not bridge disconnected surfaces or tiny gaps',()=>{const geometry=mesh([0,0,0,1,0,0,0,1,0,0,0,.000001,1,0,.000001,0,1,.000001]);expect(surfacePath(geometry,[0,0,0],[0,0,.000001],0,1)).toBeUndefined();});
  it('rejects off-surface picks, invalid indices and nonfinite coordinates',()=>{const geometry=mesh([0,0,0,1,0,0,0,1,0]);expect(surfacePath(geometry,[0,0,1],[0,0,0])).toBeUndefined();expect(surfacePath(geometry,[0,0,0],[0,0,0],8,0)).toBeUndefined();expect(surfacePath(geometry,[NaN,0,0],[0,0,0])).toBeUndefined();});
  it('invalidates its graph when vertex coordinates change',()=>{const geometry=mesh([0,0,0,1,0,0,0,1,0]);surfacePath(geometry,[0,0,0],[1,0,0]);geometry.getAttribute('position').setX(1,2);geometry.getAttribute('position').needsUpdate=true;expect(surfacePath(geometry,[0,0,0],[2,0,0])?.length).toBe(2);});
});
