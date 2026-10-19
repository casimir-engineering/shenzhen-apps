/// <reference lib="webworker" />
import * as T from "three/webgpu";
import { MeshBVH, SAH } from "three-mesh-bvh";
import { WebGPUPathTracer } from "three-gpu-pathtracer/webgpu";
import {
  traceResourceEstimate,
  unpackTraceRgba8,
} from "../core/ray-tracing-types";
import {
  buildEnvironment,
  inverseAcesFilmic,
} from "../core/ray-tracing-lighting";
import type {
  RayTracingSettings,
  TraceCamera,
  TraceScene,
} from "../core/ray-tracing-types";
let renderer: T.WebGPURenderer | undefined,
  tracer: WebGPUPathTracer | undefined,
  canvas: OffscreenCanvas | undefined,
  scene: T.Scene | undefined,
  camera: T.PerspectiveCamera | T.OrthographicCamera | undefined;
let settings: RayTracingSettings = { samples: 32, resolution: 0.5 },
  paused = true,
  running = false,
  timer: ReturnType<typeof setTimeout> | undefined,
  epoch = 0,
  sceneSnapshot: TraceScene | undefined,
  failed = false,
  lastStatus = "",
  lastSamples = -1;
const emit = (status: string, extra: Record<string, unknown> = {}) =>
  self.postMessage({
    type: "state",
    status,
    samples: 0,
    target: settings.samples,
    progress: 0,
    ...extra,
  });
function setCamera(data: TraceCamera) {
  camera =
    data.type === "perspective"
      ? new T.PerspectiveCamera(data.fov, data.aspect, data.near, data.far)
      : new T.OrthographicCamera(
          data.left,
          data.right,
          data.top,
          data.bottom,
          data.near,
          data.far,
        );
  camera.matrix.fromArray(data.matrix);
  camera.matrix.decompose(camera.position, camera.quaternion, camera.scale);
  camera.zoom = data.zoom;
  camera.updateProjectionMatrix();
  camera.updateMatrixWorld();
  tracer?.setCamera(camera);
  epoch++;
}
function compactGroups(geometry: T.BufferGeometry) {
  const index = geometry.index!,
    groups = geometry.groups.length
      ? geometry.groups
      : [{ start: 0, count: index.count, materialIndex: 0 }],
    byMaterial = new Map<number, number[]>(),
    covered = new Uint8Array(index.count);
  for (const group of groups) {
    if (
      group.start % 3 ||
      group.count % 3 ||
      group.start < 0 ||
      group.start + group.count > index.count ||
      !Number.isInteger(group.materialIndex ?? 0) ||
      (group.materialIndex ?? 0) < 0
    )
      throw new Error("This material-group layout cannot be ray traced.");
    const list = byMaterial.get(group.materialIndex ?? 0) ?? [];
    for (let i = group.start; i < group.start + group.count; i++) {
      if (covered[i])
        throw new Error(
          "Overlapping material groups are not supported by ray tracing.",
        );
      covered[i] = 1;
      list.push(index.getX(i));
    }
    byMaterial.set(group.materialIndex ?? 0, list);
  }
  if (byMaterial.size > 128)
    throw new Error(
      "Ray tracing supports up to 128 material groups per geometry.",
    );
  if (covered.some((v) => !v))
    throw new Error(
      "Incomplete material groups are not supported by ray tracing.",
    );
  const values = new Uint32Array(index.count);
  let offset = 0;
  geometry.clearGroups();
  for (const [material, list] of byMaterial) {
    values.set(list, offset);
    geometry.addGroup(offset, list.length, material);
    offset += list.length;
  }
  geometry.setIndex(new T.BufferAttribute(values, 1));
}
function setSize(width: number, height: number) {
  if (!renderer || !tracer) return;
  if (sceneSnapshot)
    traceResourceEstimate(
      sceneSnapshot.estimatedBytes,
      width,
      height,
      sceneSnapshot.budget,
    );
  lastSamples = -1;
  renderer.setSize(width, height, false);
  tracer.setSize(width, height);
  tracer.reset();
  epoch++;
}
async function tick() {
  if (!tracer || paused || running) return;
  running = true;
  const current = epoch;
  try {
    tracer.renderSample();
    const counts = await tracer.getSampleCountsAsync();
    if (current !== epoch || paused) return;
    const samples = Math.floor(counts.avg);
    const status = counts.min >= settings.samples ? "ready" : "rendering";
    if (samples !== lastSamples || status !== lastStatus) {
      emit(status, {
        samples,
        progress: Math.min(1, counts.min / settings.samples),
      });
      lastSamples = samples;
      lastStatus = status;
    }
    if (counts.min >= settings.samples) {
      paused = true;
      return;
    }
  } catch (error) {
    paused = true;
    emit("error", {
      reason: error instanceof Error ? error.message : String(error),
    });
  } finally {
    running = false;
    if (!paused) timer = setTimeout(tick, 0);
  }
}
function release() {
  clearTimeout(timer);
  paused = true;
  try {
    tracer?.dispose();
  } catch {
    /* Partial setup is disposable. */
  }
  renderer?.dispose();
  scene?.traverse((object) => {
    const mesh = object as T.Mesh;
    if (mesh.isMesh) {
      mesh.geometry.dispose();
      for (const material of Array.isArray(mesh.material)
        ? mesh.material
        : [mesh.material])
        material.dispose();
    }
  });
}
self.onmessage = async ({ data }) => {
  try {
    if (data.type === "init") {
      settings = data.settings;
      canvas = data.canvas;
      const snapshot = (sceneSnapshot = data.scene as TraceScene);
      const estimatedBytes = traceResourceEstimate(
        snapshot.estimatedBytes,
        data.width,
        data.height,
        snapshot.budget,
      );
      emit("preparing", {
        progress: 0.05,
        estimatedBytes,
      });
      if (!navigator.gpu)
        throw new Error("WebGPU is unavailable in this browser worker.");
      renderer = new T.WebGPURenderer({
        canvas: canvas!,
        antialias: false,
        alpha: false,
        powerPreference: "high-performance",
      });
      await renderer.init();
      const backend = renderer.backend as unknown as {
        isWebGPUBackend?: boolean;
        device?: GPUDevice;
      };
      if (!backend.isWebGPUBackend || !backend.device)
        throw new Error(
          "A genuine WebGPU compute backend is required for ray tracing.",
        );
      const limit = backend.device.limits.maxStorageBufferBindingSize;
      if (
        snapshot.estimatedBytes > snapshot.budget.maxBytes ||
        snapshot.geometries.reduce(
          (sum, g) =>
            sum +
            (g.attributes.position.array.length / 3) * 80 +
            (g.index.length / 3) * 64,
          0,
        ) > limit ||
        snapshot.objects.reduce((sum, o) => sum + o.matrices.length / 16, 0) *
          160 >
          limit
      )
        throw new Error(
          "The scene exceeds this GPU’s storage-buffer limit; raster remains available.",
        );
      backend.device.addEventListener("uncapturederror", (event) => {
        if (failed) return;
        failed = true;
        epoch++;
        paused = true;
        clearTimeout(timer);
        emit("error", {
          reason: `GPU ray-tracing validation failed: ${event.error.message}`,
        });
      });
      backend.device.lost.then((info) => {
        if (failed) return;
        failed = true;
        epoch++;
        paused = true;
        emit("error", {
          reason: `Ray-tracing GPU device lost: ${info.message || info.reason}`,
        });
      });
      // Same output transform as the raster viewer.
      const exposure = 1.35;
      renderer.toneMapping = T.ACESFilmicToneMapping;
      renderer.toneMappingExposure = exposure;
      const textures = snapshot.textures.map((dto) => {
        const texture = dto.data
          ? new T.DataTexture(
              dto.data,
              dto.width,
              dto.height,
              dto.format as T.PixelFormat,
              dto.type as T.TextureDataType,
            )
          : new T.Texture(dto.bitmap);
        texture.colorSpace = dto.colorSpace as T.ColorSpace;
        texture.flipY = dto.flipY;
        texture.wrapS = dto.wrapS as T.Wrapping;
        texture.wrapT = dto.wrapT as T.Wrapping;
        texture.magFilter = dto.magFilter as T.MagnificationTextureFilter;
        texture.minFilter = dto.minFilter as T.MinificationTextureFilter;
        texture.channel = dto.channel;
        texture.matrix.fromArray(dto.matrix);
        texture.matrixAutoUpdate = false;
        texture.needsUpdate = true;
        return texture;
      });
      const materials = snapshot.materials.map((dto) => {
        const material =
          dto.type === "physical"
            ? new T.MeshPhysicalMaterial()
            : new T.MeshStandardMaterial();
        const fields = material as unknown as Record<string, unknown>;
        for (const [key, value] of Object.entries(dto.properties)) {
          if (Array.isArray(value)) {
            const target = fields[key];
            if (target instanceof T.Color) target.fromArray(value);
            else if (target instanceof T.Vector2) target.fromArray(value);
          } else fields[key] = value;
        }
        for (const [key, id] of Object.entries(dto.textures))
          fields[key] = textures[id];
        return material;
      });
      const geometries: T.BufferGeometry[] = [];
      for (let i = 0; i < snapshot.geometries.length; i++) {
        const dto = snapshot.geometries[i],
          geometry = new T.BufferGeometry();
        for (const [name, attribute] of Object.entries(dto.attributes))
          geometry.setAttribute(
            name,
            new T.BufferAttribute(attribute.array, attribute.itemSize),
          );
        geometry.setIndex(new T.BufferAttribute(dto.index, 1));
        for (const group of dto.groups)
          geometry.addGroup(group.start, group.count, group.materialIndex);
        compactGroups(geometry);
        if (!geometry.hasAttribute("normal")) geometry.computeVertexNormals();
        geometry.boundsTree = new MeshBVH(geometry, {
          strategy: SAH,
          targetLeafSize: 5,
        });
        geometries.push(geometry);
        emit("preparing", {
          progress: 0.1 + (0.35 * (i + 1)) / snapshot.geometries.length,
        });
      }
      scene = new T.Scene();
      // Raster shows its plain background without tone mapping; pre-invert the
      // trace's tone mapping so both views show the same background colour. A
      // half-float texel keeps dark values that an 8-bit colour would round off.
      const background = new T.DataTexture(
        new Uint16Array([
          ...inverseAcesFilmic(snapshot.background, exposure).map((v) =>
            T.DataUtils.toHalfFloat(v),
          ),
          T.DataUtils.toHalfFloat(1),
        ]),
        1,
        1,
        T.RGBAFormat,
        T.HalfFloatType,
      );
      background.mapping = T.EquirectangularReflectionMapping;
      // The tracer samples both maps with filtering samplers.
      background.minFilter = T.LinearFilter;
      background.magFilter = T.LinearFilter;
      background.needsUpdate = true;
      scene.background = background;
      for (const dto of snapshot.objects) {
        const geometry = geometries[dto.geometry],
          mesh = new T.InstancedMesh(
            geometry,
            dto.materials.length === 1
              ? materials[dto.materials[0]]
              : dto.materials.map((i) => materials[i]),
            dto.matrices.length / 16,
          );
        mesh.instanceMatrix = new T.InstancedBufferAttribute(dto.matrices, 16);
        if (dto.colors)
          mesh.instanceColor = new T.InstancedBufferAttribute(dto.colors, 3);
        mesh.matrix.fromArray(dto.matrix);
        mesh.matrixAutoUpdate = false;
        scene.add(mesh);
      }
      // Ambient and hemisphere lights become an equivalent environment
      // (radiance = irradiance / PI); directional lights stay directional.
      const lighting = snapshot.lighting,
        radiance = buildEnvironment(lighting),
        environmentData = new Uint16Array(radiance.data.length);
      for (let i = 0; i < radiance.data.length; i++)
        environmentData[i] = T.DataUtils.toHalfFloat(radiance.data[i]);
      const environment = new T.DataTexture(
        environmentData,
        radiance.width,
        radiance.height,
        T.RGBAFormat,
        T.HalfFloatType,
      );
      environment.mapping = T.EquirectangularReflectionMapping;
      environment.minFilter = T.LinearFilter;
      environment.magFilter = T.LinearFilter;
      environment.needsUpdate = true;
      scene.environment = environment;
      for (const dto of lighting.directional ?? []) {
        if (!(dto.intensity > 0)) continue;
        const light = new T.DirectionalLight(
          new T.Color().fromArray(dto.color),
          dto.intensity,
        );
        light.position.fromArray(dto.direction).normalize().multiplyScalar(10);
        scene.add(light, light.target);
      }
      tracer = new WebGPUPathTracer(renderer);
      tracer.maxSamples = settings.samples;
      tracer.maxBounces = 4;
      tracer.maxTransparentBounces = 8;
      // Public API unit is path slots, not milliseconds; cap work and per-slot buffers.
      tracer.frameBudget = 65_536;
      tracer.dynamicLowRes = false;
      tracer.minSamples = 0;
      tracer.fadeDuration = 0;
      tracer.renderDelay = 0;
      tracer.synchronizeRenderSize = false;
      setCamera(snapshot.camera);
      setSize(data.width, data.height);
      emit("preparing", { progress: 0.5 });
      tracer.setScene(scene, camera!);
      emit("rendering", {
        progress: 0,
        estimatedBytes,
      });
      self.postMessage({ type: "prepared" });
      paused = data.paused ?? true;
      if (!paused) void tick();
    } else if (data.type === "camera") {
      setCamera(data.camera);
      tracer?.reset();
    } else if (data.type === "pause") {
      epoch++;
      paused = true;
      clearTimeout(timer);
    } else if (data.type === "resume") {
      epoch++;
      paused = false;
      void tick();
    } else if (data.type === "settings") {
      settings = data.settings;
      if (tracer) {
        tracer.maxSamples = settings.samples;
        tracer.reset();
        epoch++;
      }
      setSize(data.width, data.height);
      if (!paused) void tick();
    } else if (data.type === "snapshot") {
      if (!canvas || !renderer || !tracer || lastSamples < 1)
        throw new Error("Ray tracing has not produced an image.");
      const target = new T.RenderTarget(canvas.width, canvas.height, {
        type: T.UnsignedByteType,
        format: T.RGBAFormat,
      });
      // The output pass encodes sRGB; an sRGB GPU attachment would encode twice.
      target.texture.colorSpace = T.NoColorSpace;
      const previous = renderer.getRenderTarget(),
        previousOutput = renderer.getOutputRenderTarget(),
        wasPaused = tracer.pause,
        wasLoopPaused = paused,
        snapshotEpoch = epoch;
      paused = true;
      clearTimeout(timer);
      try {
        tracer.pause = true;
        // Treat the export target as display output so Three applies the same
        // exposure, tone mapping and output color-space transform as the canvas.
        renderer.setOutputRenderTarget(target);
        renderer.setRenderTarget(target);
        tracer.renderSample();
        // Restore the default target before yielding to camera/pause messages.
        renderer.setRenderTarget(previous);
        renderer.setOutputRenderTarget(previousOutput);
        tracer.pause = wasPaused;
        const pixels = await renderer.readRenderTargetPixelsAsync(
          target,
          0,
          0,
          canvas.width,
          canvas.height,
        );
        const exportCanvas = new OffscreenCanvas(canvas.width, canvas.height),
          context = exportCanvas.getContext("2d");
        if (!context)
          throw new Error("PNG export needs an OffscreenCanvas 2D context.");
        context.putImageData(
          new ImageData(
            unpackTraceRgba8(pixels as Uint8Array, canvas.width, canvas.height),
            canvas.width,
            canvas.height,
          ),
          0,
          0,
        );
        const blob = await exportCanvas.convertToBlob({ type: "image/png" });
        self.postMessage({ type: "snapshot", id: data.id, blob });
      } finally {
        tracer.pause = wasPaused;
        renderer.setRenderTarget(previous);
        renderer.setOutputRenderTarget(previousOutput);
        target.dispose();
        // A navigation message received during readback owns the newer pause state.
        if (epoch === snapshotEpoch) paused = wasLoopPaused;
        if (!paused) void tick();
      }
    } else if (data.type === "dispose") {
      release();
      self.close();
    }
  } catch (error) {
    paused = true;
    if (data.type === "snapshot")
      self.postMessage({
        type: "snapshot-error",
        id: data.id,
        reason: error instanceof Error ? error.message : String(error),
      });
    emit(data.type === "init" ? "unsupported" : "error", {
      reason: error instanceof Error ? error.message : String(error),
    });
    self.postMessage({ type: "failed" });
  }
};
