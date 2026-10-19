export const isNative=()=>Boolean((window as unknown as {__TAURI_INTERNALS__?:unknown}).__TAURI_INTERNALS__);
export async function saveBlob(blob:Blob,name:string){
 if(isNative()){const [{save},{writeFile}]=await Promise.all([import('@tauri-apps/plugin-dialog'),import('@tauri-apps/plugin-fs')]);const path=await save({defaultPath:name});if(path)await writeFile(path,new Uint8Array(await blob.arrayBuffer()));return;}
 const url=URL.createObjectURL(blob);const a=document.createElement('a');a.href=url;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(url),5000);
}
export async function nativeOpen(){const [{open},{readFile}]=await Promise.all([import('@tauri-apps/plugin-dialog'),import('@tauri-apps/plugin-fs')]);const paths=await open({multiple:true,directory:false,filters:[{name:'Models, drawings & companion files',extensions:['sz3d','step','stp','iges','igs','brep','brp','stl','obj','mtl','3mf','glb','gltf','bin','png','jpg','jpeg','ply','off','wrl','vrml','fbx','dae','dxf','dwg','svg']}]});if(!paths)return [];return Promise.all((Array.isArray(paths)?paths:[paths]).map(async path=>new File([await readFile(path)],path.split(/[\\/]/).pop()!)));}
