import {
  EdgesGeometry,
  BufferAttribute,
  InstancedBufferGeometry,
  LineBasicMaterial,
  LineSegments,
  Vector2,
  WireframeGeometry,
} from "three";
import type {
  BufferGeometry,
  ColorRepresentation,
  InstancedMesh,
  DepthModes,
} from "three";

export interface InstancedEdgeOptions {
  wireframe?: boolean;
  dashed?: boolean;
  depthFunc?: DepthModes;
  opacity?: number;
}

interface CachedEdges {
  geometry: BufferGeometry;
  references: number;
}

const edgeCache = new WeakMap<BufferGeometry, Map<string, CachedEdges>>();

function acquireEdges(
  source: BufferGeometry,
  thresholdAngle: number,
  wireframe: boolean,
) {
  const key = wireframe ? "triangles" : `creases:${thresholdAngle}`;
  let thresholds = edgeCache.get(source);
  if (!thresholds) {
    thresholds = new Map();
    edgeCache.set(source, thresholds);
  }
  let cached = thresholds.get(key);
  if (!cached) {
    cached = {
      geometry: wireframe
        ? new WireframeGeometry(source)
        : new EdgesGeometry(source, thresholdAngle),
      references: 0,
    };
    thresholds.set(key, cached);
  }
  cached.references++;
  return {
    geometry: cached.geometry,
    release() {
      if (--cached.references === 0) {
        thresholds.delete(key);
        cached.geometry.dispose();
        if (thresholds.size === 0) edgeCache.delete(source);
        return true;
      }
      return false;
    },
  };
}

/** Owns only its VAO; positions belong to the cache and matrices to the mesh. */
class EdgeInstanceGeometry extends InstancedBufferGeometry {
  private disposed = false;
  private sourceDisposed = false;
  private readonly onSourceDispose = () => {
    this.sourceDisposed = true;
  };

  constructor(
    private readonly releaseEdges: () => boolean,
    private readonly source: InstancedMesh,
  ) {
    super();
    source.addEventListener("dispose", this.onSourceDispose);
  }

  override dispose() {
    if (this.disposed) return;
    this.disposed = true;
    // WebGLGeometries removes every attached attribute on the dispose event.
    // Detach borrowed attributes first so other meshes/edge objects stay valid.
    // A render-only BatchedMesh source may never have registered its own
    // instanceMatrix disposal listener with WebGLObjects. Once that source is
    // disposed, this edge geometry must release its uploaded matrix buffer.
    if (!this.sourceDisposed) this.deleteAttribute("instanceMatrix");
    this.source.removeEventListener("dispose", this.onSourceDispose);
    // The cached EdgesGeometry is never submitted to the renderer itself. Its
    // final wrapper must release the position GPU buffer through its own event.
    const lastReference = this.releaseEdges();
    if (!lastReference) this.deleteAttribute("position");
    super.dispose();
    this.deleteAttribute("instanceMatrix");
    this.deleteAttribute("position");
  }
}

export class InstancedEdges extends LineSegments<
  InstancedBufferGeometry,
  LineBasicMaterial
> {
  constructor(
    readonly source: InstancedMesh,
    color: ColorRepresentation,
    thresholdAngle: number,
    options: InstancedEdgeOptions = {},
  ) {
    const cached = acquireEdges(
      source.geometry,
      thresholdAngle,
      !!options.wireframe,
    );
    const geometry = new EdgeInstanceGeometry(cached.release, source);
    geometry.setAttribute("position", cached.geometry.getAttribute("position"));
    geometry.setAttribute("instanceMatrix", source.instanceMatrix);
    if (options.dashed) {
      const position = geometry.getAttribute("position");
      const other = new Float32Array(position.count * 3);
      const end = new Float32Array(position.count);
      for (let i = 0; i < position.count; i++) {
        const paired = i % 2 ? i - 1 : i + 1;
        other[i * 3] = position.getX(paired);
        other[i * 3 + 1] = position.getY(paired);
        other[i * 3 + 2] = position.getZ(paired);
        end[i] = i % 2;
      }
      // Only these two small unique-geometry attributes belong to this wrapper.
      geometry.setAttribute("edgeOther", new BufferAttribute(other, 3));
      geometry.setAttribute("edgeEnd", new BufferAttribute(end, 1));
    }

    const material = new LineBasicMaterial({
      color,
      transparent: true,
      opacity: options.opacity ?? 0.45,
      depthWrite: false,
    });
    if (options.depthFunc !== undefined) material.depthFunc = options.depthFunc;
    const dashViewport = new Vector2(1, 1);
    const dashSize = { value: 6 };
    const gapSize = { value: 4 };
    // Keep Three's clipping, depth, fog and output-color handling. LineSegments
    // does not set USE_INSTANCING, so apply its matrix before project_vertex.
    material.onBeforeCompile = (shader) => {
      shader.vertexShader = `attribute mat4 instanceMatrix;\n${shader.vertexShader}`;
      shader.vertexShader = shader.vertexShader.replace(
        "#include <begin_vertex>",
        `#include <begin_vertex>
if ( dot( instanceMatrix[0].xyz, instanceMatrix[0].xyz ) +
     dot( instanceMatrix[1].xyz, instanceMatrix[1].xyz ) +
     dot( instanceMatrix[2].xyz, instanceMatrix[2].xyz ) == 0.0 ) {
  gl_Position = vec4( 2.0, 2.0, 2.0, 1.0 ); return;
}
transformed = ( instanceMatrix * vec4( transformed, 1.0 ) ).xyz;
${
  options.dashed
    ? `
vec4 edgeHereClip = projectionMatrix * modelViewMatrix * vec4( transformed, 1.0 );
vec4 edgeOtherClip = projectionMatrix * modelViewMatrix * instanceMatrix * vec4( edgeOther, 1.0 );
vec2 edgeDirection = ( edgeHereClip.xy / max( abs( edgeHereClip.w ), 0.000001 ) * sign( edgeHereClip.w ) -
  edgeOtherClip.xy / max( abs( edgeOtherClip.w ), 0.000001 ) * sign( edgeOtherClip.w ) ) * edgeViewport * ( edgeEnd * 2.0 - 1.0 );
vEdgeDirection = edgeDirection / max( length( edgeDirection ), 0.000001 );`
    : ""
}`,
      );
      if (options.dashed) {
        shader.uniforms.edgeViewport = { value: dashViewport };
        shader.uniforms.edgeDashSize = dashSize;
        shader.uniforms.edgeGapSize = gapSize;
        shader.vertexShader = `attribute vec3 edgeOther;\nattribute float edgeEnd;\nuniform vec2 edgeViewport;\nvarying vec2 vEdgeDirection;\n${shader.vertexShader}`;
        shader.fragmentShader = `varying vec2 vEdgeDirection;\nuniform float edgeDashSize;\nuniform float edgeGapSize;\n${shader.fragmentShader}`;
        shader.fragmentShader = shader.fragmentShader.replace(
          "#include <clipping_planes_fragment>",
          "#include <clipping_planes_fragment>\nif ( mod( dot( gl_FragCoord.xy, vEdgeDirection ), edgeDashSize + edgeGapSize ) > edgeDashSize ) discard;",
        );
      }
    };
    material.customProgramCacheKey = () =>
      options.dashed ? "gpu-edges-dashed-v2" : "gpu-edges-v2";
    super(geometry, material);
    this.name = "Instanced edges";
    this.matrixAutoUpdate = false;
    this.matrixWorldAutoUpdate = false;
    // A base-geometry sphere excludes translated/exploded instances. Avoid an
    // O(instance count) bounds rebuild; the viewer manages whole-model framing.
    this.frustumCulled = false;
    this.raycast = () => {};
    this.onBeforeRender = (renderer) => {
      this.syncFromSource();
      if (options.dashed) {
        renderer.getDrawingBufferSize(dashViewport);
        dashSize.value = 6 * renderer.getPixelRatio();
        gapSize.value = 4 * renderer.getPixelRatio();
      }
    };
    this.syncFromSource();
  }

  /** Matrix values are borrowed directly; hide/explode requires no edge rebuild. */
  syncFromSource() {
    const { source, geometry, material } = this;
    geometry.instanceCount = source.visible ? source.count : 0;
    this.matrixWorld.copy(source.matrixWorld);
    const sourceMaterial = Array.isArray(source.material)
      ? source.material[0]
      : source.material;
    material.clippingPlanes = sourceMaterial?.clippingPlanes ?? null;
    material.clipIntersection = sourceMaterial?.clipIntersection ?? false;
    material.clipShadows = sourceMaterial?.clipShadows ?? false;
  }
}

/**
 * Create once per mesh and retain across edge toggles, hide and explode changes.
 * Add beside the source, then dispose geometry and material when clearing it.
 * The source geometry and instanceMatrix must retain their identities; recreate
 * this helper if either is replaced. Mark source.instanceMatrix.needsUpdate after
 * editing it, as for the mesh itself. Material arrays use their first entry's
 * clipping policy (the viewer applies the same section plane to every entry).
 */
export function createInstancedEdges(
  source: InstancedMesh,
  color: ColorRepresentation = 0x536e79,
  thresholdAngle = 25,
  options: InstancedEdgeOptions = {},
) {
  return new InstancedEdges(source, color, thresholdAngle, options);
}
