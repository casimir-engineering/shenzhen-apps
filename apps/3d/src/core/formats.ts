export const SUPPORTED = [
  "step",
  "stp",
  "iges",
  "igs",
  "brep",
  "brp",
  "stl",
  "obj",
  "glb",
  "gltf",
  "3mf",
  "ply",
  "off",
  "fbx",
  "dae",
  "wrl",
  "vrml",
  "dxf",
  "dwg",
  "svg",
];
export const ACCEPT =
  SUPPORTED.map((s) => "." + s).join(",") + ",.mtl,.png,.jpg,.jpeg,.webp,.bin";
