import { describe, expect, it, vi } from "vitest";
import {
  BoxGeometry,
  InstancedMesh,
  Matrix4,
  MeshBasicMaterial,
  Plane,
  Raycaster,
  ShaderLib,
  Vector3,
  GreaterDepth,
} from "three";
import type { WebGLRenderer, WebGLProgramParametersWithUniforms } from "three";
import { createInstancedEdges } from "../src/core/gpu-edges";

function mesh(count = 1, geometry = new BoxGeometry()) {
  return new InstancedMesh(geometry, new MeshBasicMaterial(), count);
}

function disposeEdges(edges: ReturnType<typeof createInstancedEdges>) {
  edges.geometry.dispose();
  edges.material.dispose();
}

describe("GPU instanced edges", () => {
  it("stores unique edges once for thousands of instances and borrows matrices", () => {
    const source = mesh(10_000);
    const edges = createInstancedEdges(source);
    expect(edges.geometry.getAttribute("position").count).toBe(24);
    expect(edges.geometry.getAttribute("instanceMatrix")).toBe(
      source.instanceMatrix,
    );
    expect(edges.geometry.instanceCount).toBe(10_000);
    expect(edges.frustumCulled).toBe(false);
    disposeEdges(edges);
  });

  it("reuses cached edge positions while preserving independent mesh transforms", () => {
    const first = mesh();
    const second = mesh(2, first.geometry);
    const a = createInstancedEdges(first);
    const b = createInstancedEdges(second);
    expect(a.geometry.getAttribute("position")).toBe(
      b.geometry.getAttribute("position"),
    );
    expect(a.geometry.getAttribute("instanceMatrix")).not.toBe(
      b.geometry.getAttribute("instanceMatrix"),
    );
    const positions = b.geometry.getAttribute("position");
    a.geometry.addEventListener("dispose", () => {
      expect(a.geometry.getAttribute("position")).toBeUndefined();
      expect(a.geometry.getAttribute("instanceMatrix")).toBeUndefined();
    });
    b.geometry.addEventListener("dispose", () => {
      expect(b.geometry.getAttribute("position")).toBe(positions);
      expect(b.geometry.getAttribute("instanceMatrix")).toBeUndefined();
    });
    disposeEdges(a);
    expect(b.geometry.getAttribute("position")).toBe(positions);
    expect(b.geometry.instanceCount).toBe(2);
    disposeEdges(b);
  });

  it("reflects instance changes without reallocating edge positions", () => {
    const source = mesh(2);
    const edges = createInstancedEdges(source);
    const positions = edges.geometry.getAttribute("position");
    source.setMatrixAt(1, new Matrix4().makeTranslation(20, 30, 40));
    source.instanceMatrix.needsUpdate = true;
    source.count = 1;
    source.position.set(3, 4, 5);
    source.updateMatrixWorld();
    edges.syncFromSource();
    expect(edges.geometry.getAttribute("position")).toBe(positions);
    expect(edges.geometry.getAttribute("instanceMatrix").array[28]).toBe(20);
    expect(edges.geometry.instanceCount).toBe(1);
    expect(edges.matrixWorld.equals(source.matrixWorld)).toBe(true);
    source.visible = false;
    edges.syncFromSource();
    expect(edges.geometry.instanceCount).toBe(0);
    disposeEdges(edges);
  });

  it("keeps local clipping and the built-in line rendering pipeline", () => {
    const source = mesh();
    source.material.clippingPlanes = [new Plane(new Vector3(0, 0, 1), 2)];
    source.material.clipIntersection = true;
    const edges = createInstancedEdges(source);
    expect(edges.material.clippingPlanes).toBe(source.material.clippingPlanes);
    expect(edges.material.clipIntersection).toBe(true);
    expect(edges.material.transparent).toBe(true);
    expect(edges.material.depthWrite).toBe(false);
    const shader = {
      vertexShader: ShaderLib.basic.vertexShader,
    } as WebGLProgramParametersWithUniforms;
    edges.material.onBeforeCompile(shader, {} as WebGLRenderer);
    expect(shader.vertexShader).toContain("attribute mat4 instanceMatrix;");
    expect(shader.vertexShader).toContain(
      "transformed = ( instanceMatrix * vec4( transformed, 1.0 ) ).xyz;",
    );
    expect(shader.vertexShader).toContain("#include <project_vertex>");
    expect(shader.vertexShader).toContain("#include <clipping_planes_vertex>");
    disposeEdges(edges);
  });

  it("detaches borrowed attributes before disposal and releases cache only once", () => {
    const source = mesh();
    const disposeSource = vi.spyOn(source.geometry, "dispose");
    const edges = createInstancedEdges(source);
    const originalPositions = edges.geometry.getAttribute("position");
    const matrix = source.instanceMatrix;
    const onDispose = vi.fn(() => {
      expect(edges.geometry.getAttribute("instanceMatrix")).toBeUndefined();
      expect(edges.geometry.getAttribute("position")).toBe(originalPositions);
    });
    edges.geometry.addEventListener("dispose", onDispose);
    disposeEdges(edges);
    edges.geometry.dispose();
    expect(onDispose).toHaveBeenCalledTimes(1);
    expect(disposeSource).not.toHaveBeenCalled();
    expect(source.instanceMatrix).toBe(matrix);
    const recreated = createInstancedEdges(source);
    expect(recreated.geometry.getAttribute("position")).not.toBe(
      originalPositions,
    );
    disposeEdges(recreated);
  });

  it("excludes edge decorations from raycast picking", () => {
    const edges = createInstancedEdges(mesh());
    expect(
      new Raycaster(
        new Vector3(0, 0, 2),
        new Vector3(0, 0, -1),
      ).intersectObject(edges),
    ).toEqual([]);
    disposeEdges(edges);
  });

  it("releases matrices owned only by edges after the source proxy is disposed", () => {
    const source = mesh();
    const edges = createInstancedEdges(source);
    const matrix = source.instanceMatrix;
    source.dispose();
    const onDispose = vi.fn(() => {
      expect(edges.geometry.getAttribute("instanceMatrix")).toBe(matrix);
    });
    edges.geometry.addEventListener("dispose", onDispose);
    disposeEdges(edges);
    expect(onDispose).toHaveBeenCalledTimes(1);
    expect(edges.geometry.getAttribute("instanceMatrix")).toBeUndefined();
    expect(source.instanceMatrix).toBe(matrix);
  });

  it("caches full triangle wires separately from CAD crease edges", () => {
    const source = mesh(1000);
    const crease = createInstancedEdges(source);
    const wire = createInstancedEdges(source, 0xffffff, 25, {
      wireframe: true,
    });
    expect(crease.geometry.getAttribute("position").count).toBe(24);
    expect(wire.geometry.getAttribute("position").count).toBe(36);
    expect(wire.geometry.getAttribute("instanceMatrix")).toBe(
      source.instanceMatrix,
    );
    expect(wire.geometry.instanceCount).toBe(1000);
    disposeEdges(crease);
    disposeEdges(wire);
  });

  it("shares unique edge positions for dashed/solid passes and uses pixel-space dashes", () => {
    const source = mesh(1000);
    const solid = createInstancedEdges(source);
    const dashed = createInstancedEdges(source, 0xffffff, 25, {
      dashed: true,
      depthFunc: GreaterDepth,
    });
    expect(dashed.geometry.getAttribute("position")).toBe(
      solid.geometry.getAttribute("position"),
    );
    expect(dashed.geometry.getAttribute("edgeOther").count).toBe(24);
    expect(dashed.geometry.getAttribute("edgeEnd").array.slice(0, 4)).toEqual(
      new Float32Array([0, 1, 0, 1]),
    );
    expect(dashed.material.depthFunc).toBe(GreaterDepth);
    const shader = {
      vertexShader: ShaderLib.basic.vertexShader,
      fragmentShader: ShaderLib.basic.fragmentShader,
      uniforms: {},
    } as WebGLProgramParametersWithUniforms;
    dashed.material.onBeforeCompile(shader, {} as WebGLRenderer);
    expect(shader.fragmentShader).toContain(
      "dot( gl_FragCoord.xy, vEdgeDirection )",
    );
    expect(shader.vertexShader).toContain(
      "gl_Position = vec4( 2.0, 2.0, 2.0, 1.0 ); return;",
    );
    expect(shader.uniforms.edgeDashSize.value).toBe(6);
    disposeEdges(dashed);
    expect(solid.geometry.getAttribute("position").count).toBe(24);
    disposeEdges(solid);
  });
});
