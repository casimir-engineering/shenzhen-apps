import type {Unit, Vec3} from './types';
export const UNITS:Record<Unit,{label:string;mm:number}>={mm:{label:'Millimeters',mm:1},cm:{label:'Centimeters',mm:10},m:{label:'Meters',mm:1000},in:{label:'Inches',mm:25.4},ft:{label:'Feet',mm:304.8},um:{label:'Micrometers',mm:.001}};
export function conversion(from:Unit,to:Unit,power=1){return Math.pow(UNITS[from].mm/UNITS[to].mm,power)}
export function formatValue(value:number,from:Unit,to:Unit,precision=3,power=1){return (value*conversion(from,to,power)).toLocaleString('en-US',{minimumFractionDigits:precision,maximumFractionDigits:precision})}
export function pointDistance(a:Vec3,b:Vec3){const delta=b.map((v,i)=>v-a[i]) as Vec3;return {delta,distance:Math.hypot(...delta)}}
export function threePointAngle(a:Vec3,b:Vec3,c:Vec3){const u=a.map((v,i)=>v-b[i]),v=c.map((x,i)=>x-b[i]);const d=Math.hypot(...u)*Math.hypot(...v);return d<1e-15?undefined:Math.acos(Math.max(-1,Math.min(1,u.reduce((s,x,i)=>s+x*v[i],0)/d))) *180/Math.PI;}
export function sourceUnit(value:string|undefined):Unit {const s=(value||'mm').toLowerCase();return ({millimeter:'mm',millimetre:'mm',millimeters:'mm',meter:'m',metre:'m',inch:'in',inches:'in',foot:'ft',feet:'ft',centimeter:'cm',micrometer:'um'} as Record<string,Unit>)[s] || (s in UNITS?s as Unit:'mm')}
