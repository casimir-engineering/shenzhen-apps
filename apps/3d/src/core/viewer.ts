import type { NativeRotation } from "./native-scroll";
import * as T from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { MeshBVH, acceleratedRaycast } from "three-mesh-bvh";
import { analyzeMeshFeature } from "./mesh-features";
import { createId } from "./id";
import {
  WheelGestureClassifier,
  swipeZoomStep,
  pointerDrag,
  orbitMouseAction,
  type NavigationMode,
} from "./navigation-gestures";
import {
  DEFAULT_NAVIGATION_STYLE,
  type NavigationStyleId,
} from "./navigation-style";
import {
  measurementComponents,
  MEASUREMENT_AXIS_COLORS,
  layoutMeasurementLabels,
} from "./measurement-overlay";
import { createInstancedEdges } from "./gpu-edges";
import { clippingRange } from "./view-clipping";
import {
  PartHighlight,
  SelectionMarker,
  type HighlightEntry,
} from "./part-highlight";
import { CameraGlide } from "./camera-glide";
import { ScenePickingIndex } from "./scene-picking";
import { createRenderBatches, type RenderBatches } from "./render-batches";
import { createNavigationLods, type NavigationLod } from "./navigation-lod";
import {
  applySurfaceRenderStyle,
  isLineOnlyStyle,
  updateViewerLighting,
} from "./render-styles";
import type {
  ProgressiveRayTracer,
  RayTracingState,
} from "./progressive-ray-tracer";
import type { RayTracingLighting } from "./ray-tracing-types";
import type {
  ModelDocument,
  Part,
  Pick,
  SelectionMode,
  FeatureFilter,
  Vec3,
  GeometryData,
} from "./types";
T.Mesh.prototype.raycast = acceleratedRaycast;
export interface ViewOptions {
  edges: boolean;
  grid: boolean;
  opacity: number;
  explode: number;
  section: boolean;
  sectionAxis: "x" | "y" | "z";
  sectionPosition: number;
  hidden: Set<string>;
  theme: "dark" | "light";
  navigation?: NavigationMode;
  navigationStyle?: NavigationStyleId;
  reverseWheelZoom?: boolean;
  navigationDetail?: "auto" | "full";
  renderStyle?: "shaded" | "shaded-edges" | "wireframe" | "hidden-line";
  lightAzimuth?: number;
  lightElevation?: number;
  lightIntensity?: number;
  uniformLight?: boolean;
  uniformIntensity?: number;
  rayTracing?: boolean;
  raySamples?: 32 | 128 | 512;
  rayResolution?: 0.5 | 1;
}
export interface OverlayData {
  points: Vec3[];
  text?: string;
  path?: Vec3[];
  /** Formatted X/Y/Z labels; explicitly enables components for a two-endpoint path. */
  axisTexts?: readonly [string, string, string];
  showAxes?: boolean;
}
const AXES = {
  x: new T.Vector3(1, 0, 0),
  y: new T.Vector3(0, 1, 0),
  z: new T.Vector3(0, 0, 1),
};
const zeroMatrix = new T.Matrix4().makeScale(0, 0, 0);
export class Viewer {
  readonly renderer: T.WebGLRenderer;
  readonly scene = new T.Scene();
  camera: T.PerspectiveCamera | T.OrthographicCamera;
  controls: OrbitControls;
  private resizeObserver: ResizeObserver;
  private content = new T.Group();
  private overlay = new T.Group();
  private hoverGroup = new T.Group();
  private selection = new T.Group();
  private grid = new T.GridHelper(100, 20, 0x62777e, 0x394b53);
  private model?: ModelDocument;
  private batches = new Map<string, T.InstancedMesh>();
  private renderBatches?: RenderBatches;
  private navigationLods = new Map<T.InstancedMesh, NavigationLod>();
  private fullGeometries = new Map<T.InstancedMesh, T.BufferGeometry>();
  private lodAbort?: AbortController;
  private navigationUntil = 0;
  private navigationTimer = 0;
  private usingNavigationDetail = false;
  /** Background render preparation; measurements and the full model are usable immediately. */
  whenReady: Promise<void> = Promise.resolve();
  private lineObjects = new Map<string, T.Line>();
  private parts = new Map<string, Part>();
  private partDisplay = new Map<string, T.Matrix4>();
  private materials: T.Material[] = [];
  private edgeObjects: T.LineSegments[] = [];
  private edgeSets = new Map<string, T.LineSegments[]>();
  private hemisphereLight = new T.HemisphereLight(0xe9f5ff, 0x64727a, 2.6);
  private keyLight = new T.DirectionalLight(0xffffff, 3.2);
  private rimLight = new T.DirectionalLight(0xb3d5ff, 1.5);
  private uniformLight = new T.AmbientLight(0xffffff, 0);
  private rayTracer?: ProgressiveRayTracer;
  private rayTraceAbort?: AbortController;
  private rayTraceTimer = 0;
  private rayTraceGeneration = 0;
  private rayTraceEnabled = false;
  private rayTraceMoving = true;
  private rayTraceState?: RayTracingState;
  private bounds = new T.Box3();
  private center = new T.Vector3();
  private radius = 50;
  private raycaster = new T.Raycaster();
  private pickingIndex = new ScenePickingIndex();
  private sectionPlane = new T.Plane();
  private transformsDirty = false;
  private hoverFrame = 0;
  private hoverEvent?: PointerEvent;
  private pointerStart?: { x: number; y: number; time: number; moved: boolean };
  private pendingPick?: Pick;
  private pendingMiss = false;
  private activePointers = new Set<number>();
  private gesture = false;
  private lastHoverKey = "";
  private frame = 0;
  private disposed = false;
  private unsubscribeRotation?: () => void;
  private rotationFrame = 0;
  private pendingRotation = 0;
  private label: HTMLDivElement;
  private axisLabels: HTMLDivElement[] = [];
  private axisMidpoints: (T.Vector3 | undefined)[] = [];
  private axisLines: T.Line[] = [];
  private labelMidpoint = new T.Vector3();
  private labelProjection = new T.Vector3();
  private labelLayout = Array.from({ length: 4 }, () => ({
    anchorX: 0,
    anchorY: 0,
    width: 0,
    height: 0,
    x: 0,
    y: 0,
    visible: false,
  }));
  private labelMeasureDirty = true;
  private wheelGestures = new WheelGestureClassifier();
  private ctrlHeld = false;
  private trackControl = (event: KeyboardEvent | FocusEvent) => {
    this.ctrlHeld = "ctrlKey" in event && event.ctrlKey;
  };
  private hoveredPartId?: string;
  private normalFaceKey?: string;
  private clipCenter = new T.Vector3();
  private partHighlight = new PartHighlight();
  private selectedPartIds: string[] = [];
  private selectionBounds = new T.Box3();
  private selectionMarker: SelectionMarker;
  private glide = new CameraGlide((delta) => {
    this.camera.position.add(delta);
    this.controls.target.add(delta);
    this.controls.update();
  });
  private overlayData: OverlayData = { points: [] };
  private markers: T.Mesh[] = [];
  private mode: SelectionMode = "point";
  private filter: FeatureFilter = "auto";
  private snap = true;
  private options: ViewOptions = {
    edges: false,
    grid: true,
    opacity: 1,
    explode: 0,
    section: false,
    sectionAxis: "z",
    sectionPosition: 0.5,
    hidden: new Set(),
    theme: "dark",
    navigation: "auto",
    navigationStyle: DEFAULT_NAVIGATION_STYLE,
    reverseWheelZoom: false,
  };
  onPick?: (pick: Pick) => void;
  /** A click that hit no model geometry. */
  onMiss?: () => void;
  onHover?: (text: string) => void;
  onNavigationDetail?: (active: boolean) => void;
  onViewChanged?: () => void;
  onRayTracingState?: (state: RayTracingState) => void;
  onStats?: (stats: { calls: number; triangles: number }) => void;
  constructor(private host: HTMLElement) {
    this.renderer = new T.WebGLRenderer({
      antialias: true,
      alpha: true,
      preserveDrawingBuffer: false,
      powerPreference: "high-performance",
    });
    this.renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
    this.renderer.localClippingEnabled = true;
    this.renderer.outputColorSpace = T.SRGBColorSpace;
    this.renderer.toneMapping = T.ACESFilmicToneMapping;
    this.renderer.toneMappingExposure = 1.35;
    // A traced image sits underneath this canvas; raster interaction stays on top.
    Object.assign(this.renderer.domElement.style, {
      position: "relative",
      zIndex: "2",
    });
    host.appendChild(this.renderer.domElement);
    this.camera = new T.PerspectiveCamera(38, 1, 0.01, 100000);
    this.camera.up.set(0, 0, 1);
    this.camera.position.set(100, -120, 100);
    this.controls = this.makeControls();
    this.scene.add(this.hemisphereLight);
    const key = this.keyLight;
    key.position.set(1, -2, 3);
    this.scene.add(key);
    this.uniformLight.visible = false;
    this.scene.add(key.target, this.uniformLight);
    this.rimLight.position.set(-2, 1, 1);
    this.scene.add(this.rimLight);
    this.scene.add(
      this.content,
      this.overlay,
      this.hoverGroup,
      this.selection,
      this.partHighlight.group,
      this.grid,
    );
    this.grid.rotation.x = Math.PI / 2;
    this.label = document.createElement("div");
    this.label.className = "dimension-label";
    this.label.style.zIndex = "3";
    this.label.hidden = true;
    host.appendChild(this.label);
    for (const axis of ["x", "y", "z"]) {
      const label = document.createElement("div");
      label.className = `dimension-label dimension-axis-label axis-${axis}`;
      label.dataset.axis = axis;
      Object.assign(label.style, {
        zIndex: "3",
        color: `var(--axis-${axis})`,
        borderColor: "currentColor",
        background: "var(--bench, #182126)",
      });
      label.hidden = true;
      host.appendChild(label);
      this.axisLabels.push(label);
    }
    this.selectionMarker = new SelectionMarker(host);
    this.resizeObserver = new ResizeObserver(() => this.resize());
    this.resizeObserver.observe(host);
    const canvas = this.renderer.domElement;
    canvas.addEventListener("pointerdown", this.configureDrag, true);
    canvas.addEventListener("pointerdown", this.down);
    canvas.addEventListener("pointerup", this.up);
    canvas.addEventListener("click", this.click);
    canvas.addEventListener("pointermove", this.move);
    canvas.addEventListener("pointercancel", this.cancelPointer);
    canvas.addEventListener("pointerleave", this.leave);
    canvas.addEventListener("contextmenu", this.contextMenu);
    canvas.addEventListener("wheel", this.wheel, {
      passive: false,
      capture: true,
    });
    window.addEventListener("keydown", this.trackControl, true);
    window.addEventListener("keyup", this.trackControl, true);
    window.addEventListener("blur", this.trackControl);
    canvas.addEventListener("webglcontextlost", this.contextLost);
    canvas.addEventListener("webglcontextrestored", this.contextRestored);
    this.unsubscribeRotation = window.shenzhenScroll?.subscribeRotate?.(
      this.nativeRotation,
    );
    this.resize();
  }
  private contextLost = (e: Event) => {
    e.preventDefault();
    this.onHover?.("Graphics context paused. Waiting for recovery…");
  };
  private contextRestored = () => {
    this.onHover?.("Graphics restored");
    this.invalidate();
  };
  private makeControls() {
    const c = new OrbitControls(this.camera, this.renderer.domElement);
    c.enableDamping = false;
    c.zoomToCursor = false;
    c.screenSpacePanning = true;
    c.rotateSpeed = 0.75;
    c.zoomSpeed = 1.3;
    this.applyNavigationBindings(c);
    c.addEventListener("change", this.cameraChanged);
    return c;
  }
  private applyNavigationBindings(controls = this.controls) {
    const unmodified = { shiftKey: false, ctrlKey: false, metaKey: false };
    for (const [key, button] of [
      ["LEFT", 0],
      ["MIDDLE", 1],
      ["RIGHT", 2],
    ] as const)
      controls.mouseButtons[key] = this.mouseAction(button, unmodified);
    controls.touches.ONE = this.model?.is2D ? T.TOUCH.PAN : T.TOUCH.ROTATE;
    controls.touches.TWO = T.TOUCH.DOLLY_PAN;
  }
  private mouseAction(
    button: number,
    modifiers: { shiftKey: boolean; ctrlKey: boolean; metaKey: boolean },
  ) {
    const action = orbitMouseAction(
      pointerDrag(
        this.options.navigationStyle ?? DEFAULT_NAVIGATION_STYLE,
        button,
        modifiers,
        !!this.model?.is2D,
      ),
      modifiers,
    );
    return action === "rotate"
      ? T.MOUSE.ROTATE
      : action === "pan"
        ? T.MOUSE.PAN
        : action === "dolly"
          ? T.MOUSE.DOLLY
          : null;
  }
  private configureDrag = (event: PointerEvent) => {
    this.controls.zoomSpeed = 1.3;
    if (event.pointerType === "touch") return;
    const key =
      event.button === 0
        ? "LEFT"
        : event.button === 1
          ? "MIDDLE"
          : event.button === 2
            ? "RIGHT"
            : undefined;
    if (key)
      this.controls.mouseButtons[key] = this.mouseAction(event.button, event);
  };
  private cameraChanged = () => {
    this.syncClipping();
    this.navigationUntil = performance.now() + 180;
    window.clearTimeout(this.navigationTimer);
    this.navigationTimer = window.setTimeout(this.invalidate, 190);
    if (this.rayTracer && this.rayTraceEnabled) {
      this.rayTraceMoving = true;
      this.rayTracer.setMoving(true);
      this.rayTracer.setCamera(this.camera);
    }
    this.invalidate();
  };
  private resize() {
    this.labelMeasureDirty = true;
    const width = Math.max(this.host.clientWidth, 1),
      height = Math.max(this.host.clientHeight, 1);
    this.renderer.setSize(width, height);
    if (this.camera instanceof T.PerspectiveCamera)
      this.camera.aspect = width / height;
    else {
      const h = (this.camera.top - this.camera.bottom) / 2;
      this.camera.left = (-h * width) / height;
      this.camera.right = (h * width) / height;
    }
    this.camera.updateProjectionMatrix();
    if (this.rayTraceEnabled) {
      this.rayTracer?.setCamera(this.camera);
      this.rayTracer?.resize();
    }
    this.invalidate();
  }
  invalidate = () => {
    if (this.disposed || this.frame) return;
    this.frame = requestAnimationFrame(() => {
      this.frame = 0;
      this.draw();
    });
  };
  private draw() {
    this.updateNavigationDetail();
    this.syncRayTraceActivity();
    const worldPixel = this.worldPerPixel();
    for (const m of this.markers) m.scale.setScalar(worldPixel * 5);
    for (const line of this.axisLines) {
      const material = line.material as T.LineDashedMaterial;
      material.dashSize = worldPixel * 7;
      material.gapSize = worldPixel * 4;
    }
    if (this.overlayData.points.length) {
      this.positionLabel(this.label, this.labelMidpoint, 0);
      for (let axis = 0; axis < 3; axis++) {
        const midpoint = this.axisMidpoints[axis];
        if (midpoint)
          this.positionLabel(this.axisLabels[axis], midpoint, axis + 1);
      }
      this.labelMeasureDirty = false;
      layoutMeasurementLabels(
        this.labelLayout,
        this.host.clientWidth,
        this.host.clientHeight,
      );
      this.applyLabelPosition(this.label, 0);
      for (let axis = 0; axis < 3; axis++)
        this.applyLabelPosition(this.axisLabels[axis], axis + 1);
    }
    this.selectionMarker.place(
      this.selectionBounds,
      this.camera,
      this.host.clientWidth,
      this.host.clientHeight,
      this.options.theme,
    );
    this.renderScene(!!this.rayTracer?.imageVisible && !this.rayTraceMoving);
    this.onStats?.({
      calls: this.renderer.info.render.calls,
      triangles: this.renderer.info.render.triangles,
    });
    this.onViewChanged?.();
  }
  private positionLabel(
    label: HTMLDivElement,
    midpoint: T.Vector3,
    index: number,
  ) {
    const p = this.labelProjection.copy(midpoint).project(this.camera);
    label.hidden =
      !label.textContent ||
      !Number.isFinite(p.x + p.y + p.z) ||
      Math.abs(p.z) > 1 ||
      Math.abs(p.x) > 1 ||
      Math.abs(p.y) > 1;
    const layout = this.labelLayout[index];
    layout.visible = !label.hidden;
    if (!label.hidden) {
      layout.anchorX = (p.x * 0.5 + 0.5) * this.host.clientWidth;
      layout.anchorY = (-p.y * 0.5 + 0.5) * this.host.clientHeight;
      if (this.labelMeasureDirty || !layout.width) {
        layout.width = label.offsetWidth;
        layout.height = label.offsetHeight;
      }
    }
  }
  private applyLabelPosition(label: HTMLDivElement, index: number) {
    const layout = this.labelLayout[index];
    if (!layout.visible) return;
    label.style.left = layout.x + layout.width / 2 + "px";
    label.style.top = layout.y + layout.height * 1.5 + "px";
  }
  /** Depth range follows the current pose; see view-clipping.ts. */
  private syncClipping() {
    const camera = this.camera;
    camera.updateMatrixWorld();
    const center = this.clipCenter
      .copy(this.center)
      .applyMatrix4(camera.matrixWorldInverse);
    const { near, far } = clippingRange({
      orthographic: camera instanceof T.OrthographicCamera,
      viewDistance: camera.position.distanceTo(this.controls.target),
      centerDistance: center.length(),
      centerDepth: -center.z,
      radius: this.radius,
    });
    if (camera.near === near && camera.far === far) return;
    camera.near = near;
    camera.far = far;
    camera.updateProjectionMatrix();
  }
  private renderScene(overlaysOnly: boolean) {
    this.syncClipping();
    if (!overlaysOnly) {
      this.renderer.render(this.scene, this.camera);
      return;
    }
    const background = this.scene.background,
      content = this.content.visible,
      grid = this.grid.visible,
      clearAlpha = this.renderer.getClearAlpha();
    this.scene.background = null;
    this.content.visible = this.grid.visible = false;
    this.renderer.setClearAlpha(0);
    try {
      this.renderer.render(this.scene, this.camera);
    } finally {
      this.scene.background = background;
      this.content.visible = content;
      this.grid.visible = grid;
      this.renderer.setClearAlpha(clearAlpha);
    }
  }
  projectPick(pick: Pick) {
    const matrix = this.partDisplay.get(pick.partId);
    if (!matrix || this.options.hidden.has(pick.partId))
      return { x: 0, y: 0, visible: false };
    this.camera.updateMatrixWorld();
    const world = new T.Vector3()
      .fromArray(pick.localPoint)
      .applyMatrix4(matrix);
    const clipped =
      this.options.section && this.sectionPlane.distanceToPoint(world) < 0;
    const behind =
      world.clone().applyMatrix4(this.camera.matrixWorldInverse).z >= 0;
    const point = world.project(this.camera);
    return {
      x: (point.x * 0.5 + 0.5) * this.host.clientWidth,
      y: (-point.y * 0.5 + 0.5) * this.host.clientHeight,
      visible:
        !clipped &&
        !behind &&
        Number.isFinite(point.x + point.y + point.z) &&
        Math.abs(point.x) <= 1 &&
        Math.abs(point.y) <= 1 &&
        Math.abs(point.z) <= 1,
    };
  }
  focusPick(pick: Pick) {
    this.glide.cancel();
    const matrix = this.partDisplay.get(pick.partId);
    if (!matrix) return;
    const point = new T.Vector3()
      .fromArray(pick.localPoint)
      .applyMatrix4(matrix);
    this.camera.position.add(point.clone().sub(this.controls.target));
    this.controls.target.copy(point);
    this.controls.update();
    this.invalidate();
  }
  private cancelRayTracing() {
    window.clearTimeout(this.rayTraceTimer);
    this.rayTraceTimer = 0;
    this.rayTraceGeneration++;
    this.rayTraceAbort?.abort();
    this.rayTraceAbort = undefined;
    this.rayTracer?.cancel();
    this.rayTraceEnabled = false;
    this.rayTraceMoving = true;
    this.rayTraceState = undefined;
  }
  private syncRayTraceActivity() {
    if (!this.rayTracer || !this.rayTraceEnabled) return;
    const moving =
      performance.now() < this.navigationUntil || this.activePointers.size > 0;
    if (moving === this.rayTraceMoving) return;
    this.rayTraceMoving = moving;
    this.rayTracer.setMoving(moving);
  }
  private updateRayTracing(sceneChanged: boolean, settingsChanged: boolean) {
    const supportedStyle = (this.options.renderStyle ?? "shaded") === "shaded";
    const enabled =
      !!this.options.rayTracing &&
      !!this.model &&
      supportedStyle &&
      !this.lineObjects.size;
    if (!enabled) {
      if (this.rayTraceEnabled || this.rayTraceTimer) this.cancelRayTracing();
      if (
        this.options.rayTracing &&
        this.model &&
        (!supportedStyle || this.lineObjects.size)
      )
        this.onRayTracingState?.({
          status: "unsupported",
          samples: 0,
          target: this.options.raySamples ?? 128,
          progress: 0,
          reason: !supportedStyle
            ? "Ray tracing supports shaded surfaces. Select Shaded to enable it."
            : "Ray tracing supports 3D triangle meshes; drawing lines remain available in raster rendering.",
        });
      return;
    }
    const retry =
      settingsChanged &&
      (this.rayTraceState?.status === "unsupported" ||
        this.rayTraceState?.status === "error");
    if (sceneChanged || !this.rayTraceEnabled || retry) {
      this.cancelRayTracing();
      this.rayTraceEnabled = true;
      const generation = this.rayTraceGeneration;
      const abort = (this.rayTraceAbort = new AbortController());
      // Coalesce slider/visibility changes; camera changes only send matrices.
      this.rayTraceTimer = window.setTimeout(() => {
        this.rayTraceTimer = 0;
        void this.prepareRayTracing(generation, abort.signal);
      }, 160);
    } else if (settingsChanged)
      this.rayTracer?.setSettings({
        samples: this.options.raySamples ?? 128,
        resolution: this.options.rayResolution ?? 0.5,
      });
  }
  /** The raster lights, read from the lights themselves so a trace matches them. */
  private traceLighting(): RayTracingLighting {
    const rgb = (light: T.Light, color = light.color) =>
      color.toArray() as Vec3;
    const directional = (light: T.DirectionalLight) => ({
      direction: light.position
        .clone()
        .sub(light.target.position)
        .normalize()
        .toArray() as Vec3,
      color: rgb(light),
      intensity: light.visible ? light.intensity : 0,
    });
    const hemisphere = this.hemisphereLight,
      ambient = this.uniformLight;
    return {
      hemisphere: {
        up: hemisphere.position.clone().normalize().toArray() as Vec3,
        sky: rgb(hemisphere),
        ground: rgb(hemisphere, hemisphere.groundColor),
        intensity: hemisphere.visible ? hemisphere.intensity : 0,
      },
      ambient: {
        color: rgb(ambient),
        intensity: ambient.visible ? ambient.intensity : 0,
      },
      directional: [this.keyLight, this.rimLight].map(directional),
    };
  }
  private async prepareRayTracing(generation: number, signal: AbortSignal) {
    try {
      const { ProgressiveRayTracer } = await import("./progressive-ray-tracer");
      if (
        signal.aborted ||
        this.disposed ||
        generation !== this.rayTraceGeneration
      )
        return;
      this.rayTracer ??= new ProgressiveRayTracer(
        this.host,
        this.renderer,
        (state) => {
          if (!this.rayTraceEnabled || this.disposed) return;
          this.rayTraceState = state;
          this.onRayTracingState?.(state);
          this.onViewChanged?.();
          this.invalidate();
        },
      );
      this.rayTraceMoving = true;
      this.rayTracer.setMoving(true);
      await this.rayTracer.prepare(
        {
          sources: [...this.batches.values()],
          camera: this.camera,
          background: this.scene.background as T.Color,
          lighting: this.traceLighting(),
        },
        {
          samples: this.options.raySamples ?? 128,
          resolution: this.options.rayResolution ?? 0.5,
        },
        signal,
      );
      if (
        signal.aborted ||
        this.disposed ||
        generation !== this.rayTraceGeneration
      )
        return;
      this.rayTracer.setCamera(this.camera);
      this.syncRayTraceActivity();
    } catch (error) {
      if (!signal.aborted && generation === this.rayTraceGeneration)
        this.onRayTracingState?.({
          status: "error",
          samples: 0,
          target: this.options.raySamples ?? 128,
          progress: 0,
          reason: error instanceof Error ? error.message : String(error),
        });
    }
  }
  private updateNavigationDetail() {
    const navigating =
      this.options.navigationDetail !== "full" &&
      !isLineOnlyStyle(this.options.renderStyle) &&
      performance.now() < this.navigationUntil;
    let active = false;
    const pixelHeight = this.renderer.domElement.height;
    this.camera.updateMatrixWorld();
    const viewCenter = new T.Vector3();
    for (const [original, rendered] of this.renderBatches?.renderedInstances ??
      []) {
      const lod = this.navigationLods.get(rendered);
      if (!lod) continue;
      let useLod = false;
      if (navigating) {
        const sphere = original.boundingSphere;
        const scale = original.userData.maxInstanceScale ?? 1;
        const nearDistance = sphere
          ? Math.max(
              this.camera.near,
              -viewCenter
                .copy(sphere.center)
                .applyMatrix4(this.camera.matrixWorldInverse).z - sphere.radius,
            )
          : this.camera.near;
        const worldPerPixel =
          this.camera instanceof T.PerspectiveCamera
            ? (2 *
                nearDistance *
                Math.tan(T.MathUtils.degToRad(this.camera.fov / 2))) /
              pixelHeight
            : (this.camera.top - this.camera.bottom) /
              this.camera.zoom /
              pixelHeight;
        // Meshoptimizer's estimated geometric error must remain subpixel at
        // the nearest part of this batch, including scaled/exploded instances.
        useLod = lod.error * scale <= worldPerPixel * 0.75;
      }
      rendered.geometry = useLod
        ? lod.geometry
        : this.fullGeometries.get(rendered)!;
      active ||= useLod;
    }
    if (active !== this.usingNavigationDetail) {
      this.usingNavigationDetail = active;
      this.onNavigationDetail?.(active);
    }
  }
  private prepareNavigationDetail() {
    const sources = [...this.renderBatches!.renderedInstances.values()];
    const triangles = sources.reduce(
      (sum, mesh) =>
        sum +
        ((mesh.geometry.index?.count ??
          mesh.geometry.attributes.position.count) /
          3) *
          mesh.count,
      0,
    );
    if (triangles < 5_000_000) return;
    const abort = (this.lodAbort = new AbortController());
    for (const source of sources)
      this.fullGeometries.set(source, source.geometry);
    this.whenReady = createNavigationLods(sources, abort.signal)
      .then((lods) => {
        if (abort.signal.aborted || this.disposed) {
          for (const lod of lods.values()) lod.dispose();
          return;
        }
        this.navigationLods = lods;
        this.invalidate();
      })
      .catch(() => {
        // Navigation acceleration is optional; retain the complete render model.
      });
  }
  private worldPerPixel() {
    return this.camera instanceof T.PerspectiveCamera
      ? (2 *
          this.camera.position.distanceTo(this.controls.target) *
          Math.tan(T.MathUtils.degToRad(this.camera.fov / 2))) /
          this.host.clientHeight
      : (this.camera.top - this.camera.bottom) /
          this.camera.zoom /
          this.host.clientHeight;
  }
  setSelectionMode(mode: SelectionMode, filter: FeatureFilter, snap: boolean) {
    this.lastHoverKey = "";
    this.hoveredPartId = undefined;
    this.clearGroup(this.hoverGroup);
    this.mode = mode;
    this.filter = filter;
    this.snap = snap;
    this.invalidate();
  }
  /** `keepView` keeps the camera when a loading assembly gains parts. */
  setModel(doc: ModelDocument, keepView = false) {
    this.clearModel();
    this.model = doc;
    this.bounds.makeEmpty();
    const partGroups = new Map<string, Part[]>();
    for (const p of doc.parts) {
      this.parts.set(p.id, p);
      const list = partGroups.get(p.geometryId) || [];
      list.push(p);
      partGroups.set(p.geometryId, list);
      const g = doc.geometries.get(p.geometryId)!;
      if (!g.geometry.boundingBox) g.geometry.computeBoundingBox();
      this.bounds.union(
        g.geometry
          .boundingBox!.clone()
          .applyMatrix4(new T.Matrix4().fromArray(p.matrix)),
      );
    }
    this.bounds.getCenter(this.center);
    this.radius = Math.max(
      this.bounds.getSize(new T.Vector3()).length() / 2,
      0.001,
    );
    for (const [key, parts] of partGroups) {
      const data = doc.geometries.get(key)!;
      const geo = data.geometry;
      if (
        !data.lines &&
        !geo.boundsTree &&
        geo.index &&
        geo.attributes.position.count > 20
      ) {
        try {
          geo.boundsTree = new MeshBVH(geo, { indirect: true });
        } catch {
          /* malformed imported geometry remains selectable by standard raycaster */
        }
      }
      const materials = data.materials.map((m) => {
        const cloned = m.clone();
        cloned.userData.sourceOpacity = m.opacity;
        cloned.userData.sourceTransparent = m.transparent;
        cloned.userData.sourceDepthWrite = m.depthWrite;
        cloned.userData.sourceIsLine = !!data.lines;
        this.materials.push(cloned);
        return cloned;
      });
      if (data.lines) {
        for (const p of parts) {
          const line = new T.Line(geo, materials[0] as T.LineBasicMaterial);
          line.matrixAutoUpdate = false;
          line.matrix.fromArray(p.matrix);
          line.userData.partId = p.id;
          this.content.add(line);
          this.lineObjects.set(p.id, line);
          this.partDisplay.set(p.id, line.matrix.clone());
        }
      } else {
        const mesh = new T.InstancedMesh(
          geo,
          materials.length === 1 ? materials[0] : materials,
          parts.length,
        );
        mesh.userData.partIds = parts.map((p) => p.id);
        parts.forEach((p, i) => {
          const m = new T.Matrix4().fromArray(p.matrix);
          mesh.setMatrixAt(i, m);
          this.partDisplay.set(p.id, m);
        });
        mesh.instanceMatrix.setUsage(T.DynamicDrawUsage);
        this.batches.set(key, mesh);
      }
    }
    this.renderBatches = createRenderBatches([...this.batches.values()], {
      multiDraw: this.renderer.extensions.has("WEBGL_multi_draw"),
    });
    for (const object of this.renderBatches.objects) this.content.add(object);
    const size = 10 ** Math.floor(Math.log10(this.radius * 2));
    this.grid.scale.setScalar(size / 10);
    this.grid.position.set(
      this.center.x,
      this.center.y,
      this.bounds.min.z - this.radius * 0.002,
    );
    this.applyNavigationBindings();
    this.transformsDirty = true;
    this.applyOptions(this.options);
    if (keepView) this.invalidate();
    else if (doc.is2D) {
      this.setProjection(true);
      this.preset("top");
    } else {
      this.preset("iso");
    }
    if (!keepView) this.fit();
    this.prepareNavigationDetail();
  }
  clearModel() {
    this.glide.cancel();
    this.selectedPartIds = [];
    this.selectionBounds.makeEmpty();
    this.partHighlight.clear();
    this.hoveredPartId = undefined;
    this.normalFaceKey = undefined;
    this.cancelRayTracing();
    this.lodAbort?.abort();
    this.lodAbort = undefined;
    this.whenReady = Promise.resolve();
    for (const [mesh, geometry] of this.fullGeometries)
      mesh.geometry = geometry;
    for (const lod of this.navigationLods.values()) lod.dispose();
    this.navigationLods.clear();
    this.fullGeometries.clear();
    this.usingNavigationDetail = false;
    this.onNavigationDetail?.(false);
    this.cancelHover();
    this.pickingIndex.setObjects([]);
    this.content.clear();
    this.renderBatches?.dispose();
    this.renderBatches = undefined;
    this.clearGroup(this.selection);
    this.clearGroup(this.hoverGroup);
    this.batches.forEach((b) => b.dispose());
    this.batches.clear();
    this.lineObjects.clear();
    this.parts.clear();
    this.partDisplay.clear();
    this.materials.forEach((m) => m.dispose());
    this.materials = [];
    this.edgeObjects.forEach((e) => {
      e.geometry.dispose();
      (e.material as T.Material).dispose();
    });
    this.edgeObjects = [];
    this.edgeSets.clear();
    this.model = undefined;
    this.setOverlay({ points: [] });
  }
  getBounds() {
    return this.bounds.clone();
  }
  fit(partId?: string | string[]) {
    if (!this.model) return;
    let bounds = this.bounds;
    if (partId) {
      const selectedBounds = this.partBounds(
        Array.isArray(partId) ? partId : [partId],
      );
      if (!selectedBounds.isEmpty()) bounds = selectedBounds;
    }
    this.fitBounds(bounds);
  }
  private partBounds(ids: string[], visibleOnly = false) {
    const bounds = new T.Box3();
    for (const id of ids) {
      const p = this.parts.get(id);
      if (!p || (visibleOnly && this.options.hidden.has(id))) continue;
      const g = this.model?.geometries.get(p.geometryId);
      if (!g?.geometry.boundingBox) continue;
      bounds.union(
        g.geometry.boundingBox.clone().applyMatrix4(this.partDisplay.get(id)!),
      );
    }
    return bounds;
  }
  /** Pans so the parts' center is the view center; distance, zoom and orientation stay. */
  centerOnParts(ids: string[], animate = true) {
    if (!this.model) return;
    let bounds = this.partBounds(ids, true);
    if (bounds.isEmpty()) bounds = this.partBounds(ids);
    if (bounds.isEmpty()) return;
    const offset = bounds.getCenter(new T.Vector3()).sub(this.controls.target);
    const still =
      !animate ||
      globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
    this.glide.start(offset, still ? 0 : undefined);
  }
  /** Emphasizes whole parts, independent of point and feature picks. */
  selectParts(ids: string[]) {
    this.selectedPartIds = [...ids];
    this.refreshPartHighlight();
  }
  private refreshPartHighlight() {
    this.selectionBounds = this.partBounds(this.selectedPartIds, true);
    if (!this.model || !this.selectedPartIds.length) {
      if (this.partHighlight.size) this.partHighlight.clear();
      this.invalidate();
      return;
    }
    const entries = new Map<string, HighlightEntry>();
    for (const id of this.selectedPartIds) {
      const part = this.parts.get(id),
        matrix = this.partDisplay.get(id);
      const data = part && this.model.geometries.get(part.geometryId);
      if (!data || !matrix || this.options.hidden.has(id)) continue;
      let entry = entries.get(data.id);
      if (!entry)
        entries.set(
          data.id,
          (entry = {
            geometry: data.geometry,
            lines: !!data.lines,
            matrices: [],
          }),
        );
      entry.matrices.push(matrix);
    }
    this.partHighlight.update(
      [...entries.values()],
      this.options.theme,
      this.options.section ? [this.sectionPlane] : [],
    );
    this.invalidate();
  }
  private fitBounds(bounds: T.Box3) {
    this.glide.cancel();
    if (bounds.isEmpty()) return;
    if (bounds.getSize(new T.Vector3()).lengthSq() === 0) {
      const offset = this.camera.position.clone().sub(this.controls.target),
        center = bounds.getCenter(new T.Vector3());
      this.controls.target.copy(center);
      this.camera.position.copy(center).add(offset);
      this.controls.update();
      this.invalidate();
      return;
    }
    const center = bounds.getCenter(new T.Vector3()),
      size = bounds.getSize(new T.Vector3());
    const r = Math.max(size.length() / 2, 0.001);
    const dir = this.camera.position
      .clone()
      .sub(this.controls.target)
      .normalize();
    if (dir.lengthSq() === 0) dir.set(1, -1, 1).normalize();
    const aspect = this.host.clientWidth / this.host.clientHeight;
    this.camera.lookAt(this.controls.target);
    this.camera.updateMatrixWorld();
    const right = new T.Vector3().setFromMatrixColumn(
        this.camera.matrixWorld,
        0,
      ),
      up = new T.Vector3().setFromMatrixColumn(this.camera.matrixWorld, 1);
    const corners: T.Vector3[] = [];
    for (const x of [bounds.min.x, bounds.max.x])
      for (const y of [bounds.min.y, bounds.max.y])
        for (const z of [bounds.min.z, bounds.max.z])
          corners.push(new T.Vector3(x, y, z).sub(center));
    if (this.camera instanceof T.PerspectiveCamera) {
      const halfV = T.MathUtils.degToRad(this.camera.fov / 2);
      const halfH = Math.atan(Math.tan(halfV) * aspect);
      const distance =
        Math.max(
          r * 0.01,
          ...corners.map(
            (p) =>
              Math.max(
                Math.abs(p.dot(right)) / Math.tan(halfH),
                Math.abs(p.dot(up)) / Math.tan(halfV),
              ) + p.dot(dir),
          ),
        ) * 1.18;
      this.camera.position.copy(center).addScaledVector(dir, distance);
    } else {
      const h =
        Math.max(
          r * 0.001,
          ...corners.map((p) =>
            Math.max(Math.abs(p.dot(up)), Math.abs(p.dot(right)) / aspect),
          ),
        ) * 1.15;
      this.camera.left = -h * aspect;
      this.camera.right = h * aspect;
      this.camera.top = h;
      this.camera.bottom = -h;
      this.camera.zoom = 1;
      this.camera.position.copy(center).addScaledVector(dir, r * 4);
    }
    this.controls.target.copy(center);
    this.syncClipping();
    this.camera.updateProjectionMatrix();
    this.controls.update();
    this.invalidate();
  }
  /** Fits feature geometry in its current display transform; stale picks fall back to their part. */
  fitSelection(picks: Pick[]) {
    if (!this.model) return;
    const bounds = new T.Box3();
    for (const pick of picks) {
      const feature = new T.Box3();
      if (
        this.mode !== "part" &&
        this.featureVertices(pick, (point) => feature.expandByPoint(point))
      )
        bounds.union(feature);
      else {
        const part = this.parts.get(pick.partId),
          matrix = this.partDisplay.get(pick.partId);
        const geometry =
          part && this.model.geometries.get(part.geometryId)?.geometry;
        if (geometry && matrix) {
          geometry.computeBoundingBox();
          bounds.union(geometry.boundingBox!.clone().applyMatrix4(matrix));
        }
      }
    }
    if (!bounds.isEmpty()) this.fitBounds(bounds);
  }
  private featureVertices(
    pick: Pick,
    visit: (point: T.Vector3) => void,
  ): boolean {
    const data = this.model?.geometries.get(pick.geometryId);
    if (!data || !this.parts.has(pick.partId)) return false;
    const matrix =
        this.partDisplay.get(pick.partId) ??
        new T.Matrix4().fromArray(pick.matrix),
      point = new T.Vector3();
    let count = 0,
      invalid = false;
    const add = (x: number, y: number, z: number) => {
      point.set(x, y, z).applyMatrix4(matrix);
      if (!Number.isFinite(point.x + point.y + point.z)) {
        invalid = true;
        return;
      }
      visit(point);
      count++;
    };
    const position = data.geometry.getAttribute("position"),
      index = data.geometry.index;
    if (pick.kind === "point" || pick.kind === "vertex") {
      const vertex =
        pick.kind === "vertex"
          ? data.topology?.vertices.find((v) => v.id === pick.elementId)
          : undefined;
      const p = vertex?.position ?? pick.localPoint;
      add(...p);
    } else if (pick.kind === "edge") {
      const edge = data.topology?.edges.find((e) => e.id === pick.elementId);
      if (edge)
        for (let i = 0; i < edge.points.length; i += 3)
          add(edge.points[i], edge.points[i + 1], edge.points[i + 2]);
      else if (data.lines && position)
        for (let i = 0; i < position.count; i++)
          add(position.getX(i), position.getY(i), position.getZ(i));
    } else if (pick.kind === "face" && position) {
      const face = data.topology?.faces.find((f) => f.id === pick.elementId);
      if (data.topology && !face) return false;
      const triangle =
        pick.triangleIndex ?? (!data.topology ? pick.elementId : undefined);
      const offsets = face
        ? undefined
        : triangle === undefined
          ? []
          : (analyzeMeshFeature(data.geometry, triangle)?.triangleIndices ?? [
              triangle,
            ]);
      const addOffset = (offset: number) => {
        if (
          !Number.isInteger(offset) ||
          offset < 0 ||
          offset >= (index?.count ?? position.count)
        ) {
          invalid = true;
          return;
        }
        const n = index ? index.getX(offset) : offset;
        add(position.getX(n), position.getY(n), position.getZ(n));
      };
      if (face)
        for (
          let i = face.firstIndex;
          i < face.firstIndex + face.indexCount;
          i++
        )
          addOffset(i);
      else
        for (const triangle of offsets ?? [])
          for (let j = 0; j < 3; j++) addOffset(triangle * 3 + j);
    }
    return count > 0 && !invalid;
  }
  /** Aligns to a planar selected face; a repeated aligned command views its reverse side. */
  normalToFace(pick: Pick): boolean {
    this.glide.cancel();
    if (pick.kind !== "face") return false;
    const bounds = new T.Box3(),
      a = new T.Vector3(),
      b = new T.Vector3(),
      normal = new T.Vector3();
    let hasA = false,
      hasB = false;
    if (
      !this.featureVertices(pick, (p) => {
        bounds.expandByPoint(p);
        if (!hasA) {
          a.copy(p);
          hasA = true;
        } else if (!hasB && p.distanceToSquared(a) > 0) {
          b.copy(p);
          hasB = true;
        } else if (hasB && normal.lengthSq() === 0) {
          const ab = b.clone().sub(a),
            ac = p.clone().sub(a);
          normal.crossVectors(ab, ac);
          if (normal.lengthSq() <= ab.lengthSq() * ac.lengthSq() * 1e-16)
            normal.set(0, 0, 0);
        }
      }) ||
      normal.lengthSq() === 0
    )
      return false;
    normal.normalize();
    const tolerance = Math.max(
      bounds.getSize(new T.Vector3()).length() * 1e-6,
      1e-7,
    );
    let planar = true;
    this.featureVertices(pick, (p) => {
      if (Math.abs(p.clone().sub(a).dot(normal)) > tolerance) planar = false;
    });
    if (!planar) return false;
    const center = bounds.getCenter(new T.Vector3()),
      direction = this.camera.position.clone().sub(this.controls.target);
    const distance = Math.max(direction.length(), 1e-6);
    direction.normalize();
    const key = `${pick.partId}:${pick.elementId}:${pick.triangleIndex}`;
    const repeat =
      this.normalFaceKey === key &&
      Math.abs(direction.dot(normal)) > 1 - 1e-6 &&
      this.controls.target.distanceTo(center) < tolerance;
    if (repeat) normal.copy(direction).negate();
    else if (normal.dot(direction) < 0) normal.negate();
    this.controls.target.copy(center);
    this.camera.position.copy(center).addScaledVector(normal, distance);
    this.normalFaceKey = key;
    this.controls.update();
    this.invalidate();
    return true;
  }
  getHoveredPartId(): string | undefined {
    return this.hoveredPartId &&
      this.parts.has(this.hoveredPartId) &&
      !this.options.hidden.has(this.hoveredPartId)
      ? this.hoveredPartId
      : undefined;
  }
  preset(view: "iso" | "top" | "front" | "right" | "bottom" | "back" | "left") {
    this.glide.cancel();
    const dirs = {
      iso: [1, -1, 1],
      top: [0, 0, 1],
      bottom: [0, 0, -1],
      front: [0, -1, 0],
      back: [0, 1, 0],
      right: [1, 0, 0],
      left: [-1, 0, 0],
    };
    this.camera.up.set(0, 0, 1);
    if (view === "top" || view === "bottom") this.camera.up.set(0, 1, 0);
    const distance = Math.max(
      this.camera.position.distanceTo(this.controls.target),
      this.radius * 3,
    );
    this.camera.position
      .copy(this.controls.target)
      .add(new T.Vector3(...dirs[view]).normalize().multiplyScalar(distance));
    this.rebaseControls();
    this.invalidate();
  }
  setProjection(orthographic: boolean) {
    if (orthographic === this.camera instanceof T.OrthographicCamera) return;
    const old = this.camera;
    const aspect = this.host.clientWidth / this.host.clientHeight;
    const distance = old.position.distanceTo(this.controls.target);
    const h =
      old instanceof T.PerspectiveCamera
        ? distance * Math.tan(T.MathUtils.degToRad(old.fov / 2))
        : this.radius;
    this.camera = orthographic
      ? new T.OrthographicCamera(
          -h * aspect,
          h * aspect,
          h,
          -h,
          0.00001,
          Math.max(this.radius * 100, 1000),
        )
      : new T.PerspectiveCamera(
          38,
          aspect,
          // Keep the fitted model's depth precision when returning from a 2D
          // drawing. A fixed microscopic near plane causes thin CAD surfaces
          // to fight even though their geometry and depth buffers are intact.
          Math.max(distance / 10000, 0.00001),
          Math.max(distance * 100, 1000),
        );
    this.camera.position.copy(old.position);
    this.camera.quaternion.copy(old.quaternion);
    this.camera.up.copy(old.up);
    const target = this.controls.target.clone();
    this.controls.dispose();
    this.controls = this.makeControls();
    this.controls.target.copy(target);
    this.controls.update();
    this.invalidate();
  }
  zoom(factor: number) {
    if (this.camera instanceof T.OrthographicCamera) {
      this.camera.zoom *= factor;
      this.camera.updateProjectionMatrix();
    } else
      this.camera.position
        .sub(this.controls.target)
        .multiplyScalar(1 / factor)
        .add(this.controls.target);
    this.controls.update();
    this.invalidate();
  }
  applyOptions(options: ViewOptions) {
    const old = this.options;
    const traceSceneChanged =
      this.transformsDirty ||
      old.explode !== options.explode ||
      old.hidden !== options.hidden ||
      old.opacity !== options.opacity ||
      old.theme !== options.theme ||
      old.section !== options.section ||
      old.sectionAxis !== options.sectionAxis ||
      old.sectionPosition !== options.sectionPosition ||
      old.renderStyle !== options.renderStyle ||
      old.lightAzimuth !== options.lightAzimuth ||
      old.lightElevation !== options.lightElevation ||
      old.lightIntensity !== options.lightIntensity ||
      old.uniformLight !== options.uniformLight ||
      old.uniformIntensity !== options.uniformIntensity;
    this.options = options;
    if (old.navigationStyle !== options.navigationStyle)
      this.applyNavigationBindings();
    this.scene.background = new T.Color(
      options.theme === "dark" ? 0x182126 : 0xe9eeef,
    );
    for (const line of this.axisLines)
      (line.material as T.LineDashedMaterial).color.setHex(
        MEASUREMENT_AXIS_COLORS[options.theme][line.userData.axis],
      );
    this.grid.visible = options.grid;
    updateViewerLighting(
      this.keyLight,
      this.uniformLight,
      this.center,
      this.radius,
      options,
    );
    const axis = AXES[options.sectionAxis];
    const min = this.bounds.isEmpty()
        ? 0
        : this.bounds.min[options.sectionAxis],
      max = this.bounds.isEmpty() ? 1 : this.bounds.max[options.sectionAxis];
    const plane = this.sectionPlane;
    plane.normal.copy(axis).negate();
    plane.constant = min + (max - min) * options.sectionPosition;
    for (const m of this.materials) {
      const wasTransparent = m.transparent;
      const wasClipped = !!m.clippingPlanes?.length;
      m.opacity = (m.userData.sourceOpacity ?? 1) * options.opacity;
      m.transparent = !!m.userData.sourceTransparent || m.opacity < 1;
      m.depthWrite = m.userData.sourceDepthWrite !== false && m.opacity > 0.9;
      m.clippingPlanes = options.section ? [plane] : [];
      if (!m.userData.sourceIsLine)
        applySurfaceRenderStyle(m, options.renderStyle);
      if (wasTransparent !== m.transparent || wasClipped !== options.section)
        m.needsUpdate = true;
    }
    if (this.model) {
      const transformsChanged =
        this.transformsDirty ||
        old.explode !== options.explode ||
        old.hidden !== options.hidden;
      if (transformsChanged) {
        for (const [key, mesh] of this.batches) {
          const ids = mesh.userData.partIds as string[];
          let maxScale = 0;
          if (!mesh.geometry.boundingSphere)
            mesh.geometry.computeBoundingSphere();
          const localSphere = mesh.geometry.boundingSphere!;
          const occurrenceSphere = new T.Sphere();
          const visibleSphere = mesh.boundingSphere ?? new T.Sphere();
          visibleSphere.makeEmpty();
          ids.forEach((id, i) => {
            const p = this.parts.get(id)!;
            const matrix = this.displayMatrix(p, options.explode);
            this.partDisplay.set(id, matrix);
            mesh.setMatrixAt(i, options.hidden.has(id) ? zeroMatrix : matrix);
            // sqrt(||A||1 * ||A||inf) bounds maximum stretch even for shear.
            const e = matrix.elements;
            const columnNorm = Math.max(
              Math.abs(e[0]) + Math.abs(e[1]) + Math.abs(e[2]),
              Math.abs(e[4]) + Math.abs(e[5]) + Math.abs(e[6]),
              Math.abs(e[8]) + Math.abs(e[9]) + Math.abs(e[10]),
            );
            const rowNorm = Math.max(
              Math.abs(e[0]) + Math.abs(e[4]) + Math.abs(e[8]),
              Math.abs(e[1]) + Math.abs(e[5]) + Math.abs(e[9]),
              Math.abs(e[2]) + Math.abs(e[6]) + Math.abs(e[10]),
            );
            const stretch = Math.sqrt(columnNorm * rowNorm);
            maxScale = Math.max(maxScale, stretch);
            if (!options.hidden.has(id)) {
              occurrenceSphere.center
                .copy(localSphere.center)
                .applyMatrix4(matrix);
              occurrenceSphere.radius = localSphere.radius * stretch;
              visibleSphere.union(occurrenceSphere);
            }
          });
          mesh.userData.maxInstanceScale = maxScale;
          mesh.instanceMatrix.needsUpdate = true;
          // Ignore hidden zero matrices and conservatively enclose sheared parts.
          mesh.boundingSphere = visibleSphere;
        }
        for (const [id, line] of this.lineObjects) {
          line.visible = !options.hidden.has(id);
          line.matrix.copy(
            this.displayMatrix(this.parts.get(id)!, options.explode),
          );
          this.partDisplay.set(id, line.matrix.clone());
        }
        this.pickingIndex.setObjects([
          ...this.batches.values(),
          ...this.lineObjects.values(),
        ]);
        this.transformsDirty = false;
        this.renderBatches?.syncFromSources();
      }
      this.renderBatches?.syncMaterials();
      this.applyEdgeStyle();
      if (this.selectedPartIds.length) this.refreshPartHighlight();
    }
    this.updateRayTracing(
      traceSceneChanged,
      old.raySamples !== options.raySamples ||
        old.rayResolution !== options.rayResolution,
    );
    this.invalidate();
  }
  private displayMatrix(part: Part, explode: number) {
    const matrix = new T.Matrix4().fromArray(part.matrix);
    if (explode) {
      const g = this.model!.geometries.get(part.geometryId)!;
      const c = g.geometry
        .boundingBox!.getCenter(new T.Vector3())
        .applyMatrix4(matrix);
      const offset = c.sub(this.center).multiplyScalar(explode);
      matrix.elements[12] += offset.x;
      matrix.elements[13] += offset.y;
      matrix.elements[14] += offset.z;
    }
    return matrix;
  }
  private buildEdges(wireframe = false, dashed = false) {
    const key = `${wireframe ? "triangles" : "creases"}:${dashed ? "hidden" : "visible"}`;
    if (this.edgeSets.has(key)) return;
    const objects: T.LineSegments[] = [];
    for (const mesh of this.batches.values()) {
      const line = createInstancedEdges(mesh, 0x536e79, 25, {
        wireframe,
        dashed,
        depthFunc: dashed ? T.GreaterDepth : T.LessEqualDepth,
      });
      line.renderOrder = dashed ? 3 : 2;
      this.content.add(line);
      this.edgeObjects.push(line);
      objects.push(line);
    }
    this.edgeSets.set(key, objects);
  }
  private applyEdgeStyle() {
    const style = this.options.renderStyle ?? "shaded";
    const lineOnly = isLineOnlyStyle(style);
    const showEdges =
      lineOnly || style === "shaded-edges" || this.options.edges;
    const wireframe = style === "wireframe";
    if (showEdges) this.buildEdges(wireframe);
    if (lineOnly) this.buildEdges(wireframe, true);
    const visibleKey = `${wireframe ? "triangles" : "creases"}:visible`;
    const hiddenKey = `${wireframe ? "triangles" : "creases"}:hidden`;
    for (const [key, objects] of this.edgeSets) {
      const active =
        showEdges && (key === visibleKey || (lineOnly && key === hiddenKey));
      for (const object of objects) {
        object.visible = active;
        const material = object.material as T.LineBasicMaterial;
        const hidden = key.endsWith(":hidden");
        material.opacity = lineOnly ? (hidden ? 0.5 : 1) : 0.45;
        material.color.set(
          lineOnly
            ? this.options.theme === "dark"
              ? hidden
                ? 0x718791
                : 0xc8d5da
              : hidden
                ? 0x819099
                : 0x263c46
            : 0x536e79,
        );
        material.clippingPlanes = this.options.section
          ? [this.sectionPlane]
          : [];
      }
    }
  }
  private clearGroup(group: T.Group) {
    group.traverse((o) => {
      if (o instanceof T.Mesh || o instanceof T.Line) {
        o.geometry.dispose();
        const materials = Array.isArray(o.material) ? o.material : [o.material];
        materials.forEach((m) => m.dispose());
      }
    });
    group.clear();
  }
  highlight(picks: Pick[]) {
    this.clearGroup(this.selection);
    for (const p of picks)
      this.highlightPick(p, this.selection, 0x71e5bb, 0.25);
    this.syncRayTraceActivity();
    this.invalidate();
  }
  private highlightPick(
    p: Pick,
    group: T.Group,
    color: number,
    opacity: number,
  ) {
    const d = this.model?.geometries.get(p.geometryId);
    if (!d) return;
    const transform =
      this.partDisplay.get(p.partId) || new T.Matrix4().fromArray(p.matrix);
    if (d.lines) {
      const line = new T.Line(
        d.geometry.clone(),
        new T.LineBasicMaterial({ color, depthTest: false }),
      );
      line.applyMatrix4(transform);
      line.renderOrder = 10;
      group.add(line);
    } else if (p.kind === "edge" && d.topology) {
      const edge = d.topology.edges.find((e) => e.id === p.elementId);
      if (edge) {
        const g = new T.BufferGeometry().setAttribute(
          "position",
          new T.BufferAttribute(edge.points.slice(), 3),
        );
        const l = new T.Line(
          g,
          new T.LineBasicMaterial({ color, depthTest: false, linewidth: 3 }),
        );
        l.applyMatrix4(transform);
        l.renderOrder = 10;
        group.add(l);
      }
    } else if (p.kind === "face" || this.mode === "part") {
      const g = new T.BufferGeometry();
      const source = d.geometry;
      let start = 0,
        count = source.index?.count ?? source.attributes.position.count;
      let triangles: number[] | undefined;
      if (p.kind === "face") {
        const face = d.topology?.faces.find((f) => f.id === p.elementId);
        start = face?.firstIndex ?? (p.triangleIndex ?? 0) * 3;
        count = face?.indexCount ?? 3;
        if (
          !d.topology &&
          group === this.selection &&
          p.triangleIndex !== undefined
        )
          triangles = analyzeMeshFeature(
            source,
            p.triangleIndex,
          )?.triangleIndices;
      }
      const indices = triangles
        ? triangles.flatMap((t) => [t * 3, t * 3 + 1, t * 3 + 2])
        : Array.from({ length: count }, (_, i) => start + i);
      const positions = new Float32Array(indices.length * 3);
      indices.forEach((i, j) => {
        const n = source.index ? source.index.getX(i) : i;
        positions[j * 3] = source.attributes.position.getX(n);
        positions[j * 3 + 1] = source.attributes.position.getY(n);
        positions[j * 3 + 2] = source.attributes.position.getZ(n);
      });
      g.setAttribute("position", new T.BufferAttribute(positions, 3));
      const m = new T.MeshBasicMaterial({
        color,
        transparent: true,
        opacity,
        side: T.DoubleSide,
        depthWrite: false,
        polygonOffset: true,
        polygonOffsetFactor: -2,
        polygonOffsetUnits: -2,
      });
      const mesh = new T.Mesh(g, m);
      mesh.applyMatrix4(transform);
      mesh.renderOrder = 3;
      group.add(mesh);
    }
  }
  setOverlay(data: OverlayData) {
    const worldPixel = this.worldPerPixel();
    this.clearGroup(this.overlay);
    this.overlayData = data;
    this.labelMeasureDirty = true;
    for (const layout of this.labelLayout) layout.visible = false;
    this.markers = [];
    this.axisLines = [];
    this.axisMidpoints = [];
    for (const label of this.axisLabels) {
      label.hidden = true;
      label.textContent = "";
    }
    this.label.textContent = data.text || "";
    this.label.hidden = !data.text;
    if (data.points.length) {
      this.labelMidpoint.fromArray(data.points[0]);
      if (data.points.length > 1)
        this.labelMidpoint
          .add(this.labelProjection.fromArray(data.points.at(-1)!))
          .multiplyScalar(0.5);
    }
    data.points.forEach((p, i) => {
      const m = new T.Mesh(
        new T.SphereGeometry(1, 12, 8),
        new T.MeshBasicMaterial({
          color: i === 0 ? 0x6ce1b6 : 0xf5c873,
          depthTest: false,
        }),
      );
      m.position.fromArray(p);
      m.renderOrder = 20;
      this.markers.push(m);
      this.overlay.add(m);
    });
    if (data.points.length > 1) {
      const points = (data.path || data.points).map((p) =>
        new T.Vector3().fromArray(p),
      );
      const line = new T.Line(
        new T.BufferGeometry().setFromPoints(points),
        new T.LineBasicMaterial({
          color: 0x9ceccd,
          depthTest: false,
          transparent: true,
          opacity: 0.95,
        }),
      );
      line.renderOrder = 19;
      line.name = "measurement-connector";
      this.overlay.add(line);
      if (
        data.points.length === 2 &&
        data.showAxes !== false &&
        (!data.path ||
          (data.path.length === 2 && (data.axisTexts || data.showAxes)))
      ) {
        const [a, b] = data.points;
        for (const component of measurementComponents(a, b)) {
          const axis = component.axis;
          const dashed = new T.Line(
            new T.BufferGeometry().setFromPoints([
              new T.Vector3(...component.start),
              new T.Vector3(...component.end),
            ]),
            new T.LineDashedMaterial({
              color: MEASUREMENT_AXIS_COLORS[this.options.theme][axis],
              dashSize: worldPixel * 7,
              gapSize: worldPixel * 4,
              depthTest: false,
              depthWrite: false,
            }),
          );
          dashed.name = `measurement-axis-${"xyz"[axis]}`;
          dashed.userData.axis = axis;
          dashed.computeLineDistances();
          dashed.renderOrder = 18;
          this.overlay.add(dashed);
          this.axisLines.push(dashed);
          this.axisMidpoints[axis] = new T.Vector3(...component.midpoint);
          this.axisLabels[axis].textContent =
            data.axisTexts?.[axis] ?? `Δ${"XYZ"[axis]}`;
        }
      }
    }
    this.syncRayTraceActivity();
    this.invalidate();
  }
  private screen(point: T.Vector3) {
    const p = point.clone().project(this.camera);
    return new T.Vector2(
      ((p.x + 1) * this.host.clientWidth) / 2,
      ((-p.y + 1) * this.host.clientHeight) / 2,
    );
  }
  private pick(event: PointerEvent | MouseEvent): Pick | undefined {
    if (!this.model) return;
    const rect = this.renderer.domElement.getBoundingClientRect();
    const mouse = new T.Vector2(
      event.clientX - rect.left,
      event.clientY - rect.top,
    );
    this.raycaster.setFromCamera(
      new T.Vector2(
        (mouse.x / rect.width) * 2 - 1,
        (-mouse.y / rect.height) * 2 + 1,
      ),
      this.camera,
    );
    this.raycaster.params.Line = { threshold: this.worldPerPixel() * 7 };
    this.raycaster.firstHitOnly = !this.options.section;
    const hits = this.pickingIndex.intersect(this.raycaster);
    const hit = hits.find((h) => {
      const id =
        h.object instanceof T.InstancedMesh
          ? h.object.userData.partIds[h.instanceId!]
          : h.object.userData.partId;
      if (!id || this.options.hidden.has(id)) return false;
      return (
        !this.options.section ||
        h.point[this.options.sectionAxis] <=
          this.bounds.min[this.options.sectionAxis] +
            (this.bounds.max[this.options.sectionAxis] -
              this.bounds.min[this.options.sectionAxis]) *
              this.options.sectionPosition +
            1e-6
      );
    });
    if (!hit) return;
    const id =
      hit.object instanceof T.InstancedMesh
        ? hit.object.userData.partIds[hit.instanceId!]
        : hit.object.userData.partId;
    const part = this.parts.get(id)!,
      d = this.model.geometries.get(part.geometryId)!;
    const display = this.partDisplay.get(id)!;
    let local = hit.point.clone().applyMatrix4(display.clone().invert());
    let kind: Pick["kind"] = "point",
      elementId: number | undefined,
      snap = "Surface point";
    const triangle = hit.faceIndex ?? undefined;
    const faceId =
      triangle !== undefined
        ? d.topology?.triangleToFaceMap[triangle]
        : undefined;
    let nearestVertex:
      { id: number; position: T.Vector3; distance: number } | undefined;
    if (this.snap || this.mode === "feature") {
      const candidates =
        d.topology?.vertices ||
        (hit.face
          ? [hit.face.a, hit.face.b, hit.face.c].map((i) => ({
              id: i,
              position: new T.Vector3()
                .fromBufferAttribute(d.geometry.getAttribute("position"), i)
                .toArray() as Vec3,
            }))
          : d.lines
            ? Array.from(
                { length: d.geometry.attributes.position.count },
                (_, i) => ({
                  id: i,
                  position: new T.Vector3()
                    .fromBufferAttribute(d.geometry.attributes.position, i)
                    .toArray() as Vec3,
                }),
              )
            : []);
      for (const vertex of candidates) {
        const position = new T.Vector3().fromArray(vertex.position);
        const distance = this.screen(
          position.clone().applyMatrix4(display),
        ).distanceTo(mouse);
        if (
          distance <
            (event instanceof PointerEvent && event.pointerType === "touch"
              ? 22
              : 12) &&
          (!nearestVertex || distance < nearestVertex.distance)
        )
          nearestVertex = { id: vertex.id, position, distance };
      }
    }
    let nearestEdge:
      { id: number; point: T.Vector3; distance: number } | undefined;
    if (d.topology && (this.snap || this.mode === "feature"))
      for (const edge of d.topology.edges) {
        if (
          faceId !== undefined &&
          edge.ownerFaceIds.length &&
          !edge.ownerFaceIds.includes(faceId)
        )
          continue;
        for (let i = 0; i < edge.points.length - 3; i += 3) {
          const a = new T.Vector3().fromArray(edge.points, i),
            b = new T.Vector3().fromArray(edge.points, i + 3);
          const sa = this.screen(a.clone().applyMatrix4(display)),
            sb = this.screen(b.clone().applyMatrix4(display)),
            ab = sb.clone().sub(sa);
          const t = T.MathUtils.clamp(
            mouse.clone().sub(sa).dot(ab) / Math.max(ab.lengthSq(), 1e-20),
            0,
            1,
          );
          const distance = sa.addScaledVector(ab, t).distanceTo(mouse);
          if (
            distance < 10 &&
            (!nearestEdge || distance < nearestEdge.distance)
          )
            nearestEdge = { id: edge.id, point: a.lerp(b, t), distance };
        }
      }
    if (this.mode === "feature") {
      if (
        (this.filter === "auto" || this.filter === "vertex") &&
        nearestVertex
      ) {
        kind = "vertex";
        elementId = nearestVertex.id;
        local = nearestVertex.position;
        snap = "Vertex";
      } else if (
        (this.filter === "auto" || this.filter === "edge") &&
        nearestEdge
      ) {
        kind = "edge";
        elementId = nearestEdge.id;
        local = nearestEdge.point;
        snap = "Edge";
      } else if (
        (this.filter === "edge" || this.filter === "auto") &&
        d.lines
      ) {
        kind = "edge";
        elementId = 0;
        snap = "Drawing curve";
      } else if (this.filter === "edge" || this.filter === "vertex") return;
      else {
        kind = "face";
        elementId = faceId ?? triangle;
        snap = d.topology ? "CAD face" : "Mesh triangle";
      }
    } else if (this.mode === "point" && this.snap) {
      if (nearestVertex) {
        local = nearestVertex.position;
        kind = d.topology ? "vertex" : "point";
        elementId = nearestVertex.id;
        snap = d.topology ? "Vertex snap" : "Mesh vertex snap";
      } else if (nearestEdge) {
        local = nearestEdge.point;
        snap = "Edge snap";
      }
    }
    const world = local
      .clone()
      .applyMatrix4(new T.Matrix4().fromArray(part.matrix));
    return {
      id: createId(),
      partId: id,
      partName: part.name,
      geometryId: part.geometryId,
      point: world.toArray() as Vec3,
      localPoint: local.toArray() as Vec3,
      kind,
      elementId,
      triangleIndex: triangle,
      snap,
      exactHandle: d.exactHandle,
      matrix: part.matrix,
    };
  }
  private down = (event: PointerEvent) => {
    this.cancelHover();
    this.pendingPick = undefined;
    this.pendingMiss = false;
    this.activePointers.add(event.pointerId);
    this.syncRayTraceActivity();
    if (this.activePointers.size > 1) this.gesture = true;
    this.pointerStart = {
      x: event.clientX,
      y: event.clientY,
      time: performance.now(),
      moved: false,
    };
  };
  private up = (event: PointerEvent) => {
    const start = this.pointerStart;
    this.activePointers.delete(event.pointerId);
    this.syncRayTraceActivity();
    const wasGesture = this.gesture;
    if (!this.activePointers.size) this.gesture = false;
    this.pointerStart = undefined;
    if (!start || event.button !== 0 || wasGesture) return;
    if (
      start.moved ||
      Math.hypot(event.clientX - start.x, event.clientY - start.y) > 5 ||
      performance.now() - start.time > 700
    )
      return;
    this.pendingPick = this.pick(event);
    this.pendingMiss = !this.pendingPick;
  };
  private click = () => {
    // Open the inspector after the compatibility click targets the canvas.
    // Opening on pointerup lets touch clicks land on the new sheet beneath them.
    const pick = this.pendingPick,
      miss = this.pendingMiss;
    this.pendingPick = undefined;
    this.pendingMiss = false;
    if (pick) this.onPick?.(pick);
    else if (miss) this.onMiss?.();
  };
  private cancelPointer = (event: PointerEvent) => {
    this.pendingPick = undefined;
    this.pendingMiss = false;
    this.activePointers.delete(event.pointerId);
    this.syncRayTraceActivity();
    this.pointerStart = undefined;
    if (!this.activePointers.size) this.gesture = false;
  };
  private move = (event: PointerEvent) => {
    if (
      this.pointerStart &&
      Math.hypot(
        event.clientX - this.pointerStart.x,
        event.clientY - this.pointerStart.y,
      ) > 5
    )
      this.pointerStart.moved = true;
    if (event.buttons || event.pointerType === "touch") return;
    this.hoverEvent = event;
    if (this.hoverFrame) return;
    this.hoverFrame = requestAnimationFrame(() => {
      this.hoverFrame = 0;
      const latest = this.hoverEvent;
      this.hoverEvent = undefined;
      if (latest && !this.disposed) this.updateHover(latest);
    });
  };
  private cancelHover() {
    cancelAnimationFrame(this.hoverFrame);
    this.hoverFrame = 0;
    this.hoverEvent = undefined;
  }
  private updateHover(event: PointerEvent) {
    const p = this.pick(event);
    this.hoveredPartId = p?.partId;
    this.onHover?.(p ? `${p.partName} · ${p.snap}` : "");
    this.renderer.domElement.style.cursor = p ? "crosshair" : "grab";
    const key = p ? `${p.partId}:${p.kind}:${p.elementId}` : "";
    if (key !== this.lastHoverKey) {
      this.lastHoverKey = key;
      this.clearGroup(this.hoverGroup);
      if (p && this.mode === "feature")
        this.highlightPick(p, this.hoverGroup, 0xa7cddd, 0.15);
      this.syncRayTraceActivity();
      this.invalidate();
    }
  }
  private leave = () => {
    this.hoveredPartId = undefined;
    this.cancelHover();
    this.lastHoverKey = "";
    this.clearGroup(this.hoverGroup);
    this.syncRayTraceActivity();
    this.onHover?.("");
    this.invalidate();
  };
  private contextMenu = (event: Event) => event.preventDefault();
  private nativeRotation = (event: NativeRotation) => {
    if (
      this.disposed ||
      this.activePointers.size ||
      !Number.isFinite(event.degrees) ||
      Math.abs(event.degrees) > 180 ||
      !Number.isFinite(event.clientX) ||
      !Number.isFinite(event.clientY) ||
      document.elementFromPoint(event.clientX, event.clientY) !==
        this.renderer.domElement
    )
      return;
    this.pendingRotation += event.degrees;
    if (this.rotationFrame) return;
    this.rotationFrame = requestAnimationFrame(() => {
      this.rotationFrame = 0;
      const degrees = this.pendingRotation;
      this.pendingRotation = 0;
      if (!this.activePointers.size) this.rollView(degrees);
    });
  };
  /** Rotate the view around its sight line without changing model coordinates. */
  rollView(degrees: number) {
    if (this.disposed || !Number.isFinite(degrees) || !degrees) return;
    const position = this.camera.position.clone();
    const target = this.controls.target.clone();
    const direction = target.clone().sub(position).normalize();
    if (!direction.lengthSq()) return;
    // AppKit reports counterclockwise object rotation. Rotate the camera up
    // around its forward axis so the image follows the fingers.
    this.camera.up
      .set(0, 1, 0)
      .applyQuaternion(this.camera.quaternion)
      .applyAxisAngle(direction, T.MathUtils.degToRad(degrees))
      .normalize();
    this.rebaseControls();
    this.cameraChanged();
  }
  private rebaseControls() {
    const position = this.camera.position.clone();
    const target = this.controls.target.clone();
    // OrbitControls caches its up-axis basis at construction. Rebase through
    // its public constructor, once per display frame; geometry stays intact.
    const old = this.controls;
    const limits = {
      minDistance: old.minDistance,
      maxDistance: old.maxDistance,
      minZoom: old.minZoom,
      maxZoom: old.maxZoom,
      enabled: old.enabled,
    };
    old.dispose();
    this.controls = this.makeControls();
    Object.assign(this.controls, limits);
    this.camera.position.copy(position);
    this.controls.target.copy(target);
    this.controls.update();
  }
  private wheel = (event: WheelEvent) => {
    const action = this.wheelGestures.classify(
      {
        deltaX: event.deltaX,
        deltaY: event.deltaY,
        deltaMode: event.deltaMode,
        ctrlKey: event.ctrlKey,
        metaKey: event.metaKey,
        ctrlHeld: this.ctrlHeld,
        wheelDeltaX: (event as WheelEvent & { wheelDeltaX?: number })
          .wheelDeltaX,
        wheelDeltaY: (event as WheelEvent & { wheelDeltaY?: number })
          .wheelDeltaY,
        momentum: (event as WheelEvent & { momentum?: boolean }).momentum,
        devicePixelRatio: window.devicePixelRatio,
        nativeSource:
          event.isTrusted && (!event.ctrlKey || this.ctrlHeld)
            ? window.shenzhenScroll?.source(
                performance.timeOrigin + event.timeStamp,
              )
            : null,
      },
      "auto",
      performance.now(),
    );
    if (action === "swipe-zoom") {
      event.preventDefault();
      event.stopImmediatePropagation();
      if (!this.controls.enabled || !this.controls.enableZoom) return;
      const step = swipeZoomStep(
        event.deltaY,
        event.deltaMode,
        this.host.clientHeight,
        this.controls.zoomSpeed,
      );
      if (step)
        step.out
          ? this.controls.dollyOut(step.scale)
          : this.controls.dollyIn(step.scale);
      return;
    }
    if (action === "pan") {
      event.preventDefault();
      event.stopImmediatePropagation();
      const scale =
        event.deltaMode === 1
          ? 16
          : event.deltaMode === 2
            ? this.host.clientHeight
            : 1;
      this.controls.pan(-event.deltaX * scale, -event.deltaY * scale);
      return;
    }
    this.controls.zoomSpeed = 1.3;
  };
  async screenshot() {
    let traced: ImageBitmap | undefined;
    const generation = this.rayTraceGeneration;
    if (
      this.options.rayTracing &&
      this.rayTracer &&
      this.rayTracer.imageVisible &&
      !this.rayTraceMoving &&
      (this.rayTraceState?.samples ?? 0) > 0
    ) {
      try {
        traced = await createImageBitmap(await this.rayTracer.snapshot());
        if (
          generation !== this.rayTraceGeneration ||
          this.rayTraceMoving ||
          !this.rayTracer.imageVisible
        ) {
          traced.close();
          traced = undefined;
        }
      } catch {
        /* A canceled/unsupported trace still has a complete raster export. */
      }
    }
    // Export full geometry even if the request arrives during navigation.
    this.navigationUntil = 0;
    this.draw();
    // A failed worker readback must still export the complete raster model.
    if (!traced && this.rayTracer?.imageVisible) this.renderScene(false);
    const canvas = document.createElement("canvas");
    canvas.width = this.renderer.domElement.width;
    canvas.height = this.renderer.domElement.height;
    const ctx = canvas.getContext("2d")!;
    if (traced) {
      ctx.drawImage(traced, 0, 0, canvas.width, canvas.height);
      traced.close();
    }
    ctx.drawImage(this.renderer.domElement, 0, 0);
    this.invalidate();
    for (const label of [this.label, ...this.axisLabels])
      if (!label.hidden) {
        const ratio = this.renderer.getPixelRatio();
        const x = parseFloat(label.style.left) * ratio,
          y = parseFloat(label.style.top) * ratio;
        ctx.font = `${14 * ratio}px monospace`;
        const width = ctx.measureText(label.textContent!).width + 20 * ratio;
        const style =
          label === this.label ? undefined : getComputedStyle(label);
        ctx.fillStyle = style?.backgroundColor ?? "#142b24";
        ctx.fillRect(x - width / 2, y - 34 * ratio, width, 28 * ratio);
        ctx.fillStyle = style?.color ?? "#b9f7dd";
        ctx.textAlign = "center";
        ctx.fillText(label.textContent!, x, y - 15 * ratio);
      }
    return new Promise<Blob>((resolve) =>
      canvas.toBlob((b) => resolve(b!), "image/png"),
    );
  }
  dispose() {
    this.disposed = true;
    window.removeEventListener("keydown", this.trackControl, true);
    window.removeEventListener("keyup", this.trackControl, true);
    window.removeEventListener("blur", this.trackControl);
    this.unsubscribeRotation?.();
    cancelAnimationFrame(this.rotationFrame);
    this.pendingRotation = 0;
    cancelAnimationFrame(this.frame);
    window.clearTimeout(this.navigationTimer);
    this.resizeObserver.disconnect();
    this.controls.dispose();
    this.clearModel();
    this.rayTracer?.dispose();
    this.clearGroup(this.overlay);
    this.grid.geometry.dispose();
    (this.grid.material as T.Material).dispose();
    this.renderer.dispose();
    this.renderer.domElement.remove();
    this.label.remove();
    for (const label of this.axisLabels) label.remove();
    this.selectionMarker.dispose();
    this.glide.cancel();
  }
}
