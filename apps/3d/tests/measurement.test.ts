import {describe,it,expect} from 'vitest';
import {conversion,formatValue,pointDistance,sourceUnit,threePointAngle} from '../src/core/units';
describe('measurement units and coordinates',()=>{
  it('converts distance, area and volume by their dimension',()=>{expect(conversion('in','mm')).toBe(25.4);expect(conversion('m','mm',2)).toBe(1e6);expect(conversion('cm','mm',3)).toBe(1000);expect(formatValue(25.4,'mm','in')).toBe('1.000');});
  it('preserves signed axis deltas while measuring Euclidean distance',()=>{expect(pointDistance([1,2,3],[-2,6,15])).toEqual({delta:[-3,4,12],distance:13});});
  it('converts declared units and safely defaults absent units',()=>{expect(sourceUnit('INCHES')).toBe('in');expect(sourceUnit('millimeter')).toBe('mm');expect(sourceUnit(undefined)).toBe('mm');});
  it('uses the middle point as angle vertex',()=>{expect(threePointAngle([1,0,0],[0,0,0],[0,1,0])).toBe(90);expect(threePointAngle([-1,0,0],[0,0,0],[1,0,0])).toBe(180);expect(threePointAngle([0,0,0],[0,0,0],[1,0,0])).toBeUndefined();});
});
