import * as T from 'three';
import {fromObject} from './importers';
export function createDemo(){
 const group=new T.Group();group.name='Precision mounting bracket';const shape=new T.Shape();shape.moveTo(-40,-28);shape.lineTo(40,-28);shape.lineTo(40,28);shape.lineTo(-40,28);shape.closePath();for(const x of [-28,28])for(const y of [-17,17]){const hole=new T.Path();hole.absarc(x,y,4,0,Math.PI*2,true);shape.holes.push(hole)}
 const base=new T.Mesh(new T.ExtrudeGeometry(shape,{depth:6,bevelEnabled:false,curveSegments:48}),new T.MeshStandardMaterial({color:0x8aabb5,metalness:.5,roughness:.3}));base.name='Base plate · 80 × 56 × 6';group.add(base);
 const upright=new T.Mesh(new T.BoxGeometry(80,6,34),new T.MeshStandardMaterial({color:0x8aabb5,metalness:.5,roughness:.3}));upright.position.set(0,25,23);upright.name='Upright · 80 × 6 × 34';group.add(upright);
 for(const x of [-20,20]){const screw=new T.Mesh(new T.CylinderGeometry(5,5,6,32),new T.MeshStandardMaterial({color:0xd6dad7,metalness:.8,roughness:.25}));screw.rotation.x=Math.PI/2;screw.position.set(x,0,9);screw.name='Fastener · Ø10';group.add(screw)}
 const doc=fromObject(group,'Mounting bracket · demo','mm',['Demo uses mesh geometry. Open STEP or IGES for exact CAD features.']);doc.format='demo';return doc;
}
