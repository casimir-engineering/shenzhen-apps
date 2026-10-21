import { version as appVersion } from "../package.json";
import {
  lazy,
  Suspense,
  useCallback,
  useEffect,
  useRef,
  useState,
} from "react";
import type { UpdateState } from "./core/updates";
import type { Vector3 } from "three";
import { createId } from "./core/id";
import "./core/safe-area";
import "./core/keyboard";
import { CommandPalette, type Command } from "./components/CommandPalette";
import {
  friendsRequests,
  friendsShortcutLabel,
  isFriendsShortcut,
  isPaletteShortcut,
  shortcutLabel,
} from "./friends/requests";
import {
  Box,
  Upload,
  MousePointer2,
  ScanLine,
  Ruler,
  Route,
  Triangle,
  Maximize,
  Camera,
  Grid3X3,
  Scissors,
  Settings2,
  HelpCircle,
  X,
  ChevronDown,
  ChevronRight,
  Eye,
  Focus,
  Plus,
  Trash2,
  Download,
  Check,
  Copy,
  Sun,
  Moon,
  PanelLeftClose,
  PanelRightClose,
  PanelLeftOpen,
  PanelRightOpen,
  RotateCcw,
  LoaderCircle,
  FolderOpen,
  FileBox,
  Magnet,
  ZoomIn,
  ZoomOut,
  Info,
  MessageSquare,
  Share2,
} from "lucide-react";
import { Viewport } from "./components/Viewport";
import { AssemblyTree } from "./components/AssemblyTree";
import {
  selectionForPart,
  type PartSelection,
} from "./core/assembly-selection";
import { ReviewPanel } from "./components/ReviewPanel";
import { ReviewPins } from "./components/ReviewPins";
import {
  DisplaySettings,
  RenderStyleSelect,
  DEFAULT_DISPLAY,
  type DisplayOptions,
} from "./components/DisplaySettings";
import type { ReviewNote } from "./core/project-file";
import type { Viewer } from "./core/viewer";
import type { RecentEntry } from "./core/recent-files";
import { viewportShortcut } from "./core/viewport-shortcuts";
import type { RayTracingState } from "./core/ray-tracing-types";
import { ACCEPT } from "./core/formats";
import { cad } from "./core/cad-client";
import {
  UNITS,
  conversion,
  formatValue,
  pointDistance,
  threePointAngle,
} from "./core/units";
import { isNative, nativeOpen, saveBlob } from "./core/files";
import type {
  ModelDocument,
  Pick,
  SelectionMode,
  FeatureFilter,
  ToolMode,
  Measurement,
  FeatureProperties,
  Unit,
  Vec3,
  ExactPair,
} from "./core/types";
type ModelRuntime = typeof import("./core/model-runtime");
const UpdatesDialog = lazy(() => import("./components/UpdatesDialog"));
// Shenzhen Friends loads only where its bridge exists (the Mac app), a second after the first paint.
const FriendsHeader = lazy(() =>
  import("./friends/FriendsButton").then((module) => ({
    default: module.FriendsHeader,
  })),
);
const FriendsSettingsSlot = lazy(() =>
  import("./friends/FriendsButton").then((module) => ({
    default: module.FriendsSettingsSlot,
  })),
);
// Failed chunk fetches can be retried by opening a file again.
let runtimePromise: Promise<ModelRuntime> | undefined;
const loadRuntime = () =>
  (runtimePromise ??= import("./core/model-runtime").catch((error) => {
    runtimePromise = undefined;
    throw error;
  }));
const readPrefs = () => {
  try {
    return JSON.parse(localStorage.getItem("shenzhen-preferences") || "{}");
  } catch {
    return {};
  }
};
const uid = createId;
function noteTarget(pick: Pick, scope: ReviewNote["scope"]): Pick {
  return scope === "feature"
    ? pick
    : { ...pick, kind: "point", elementId: undefined };
}
function IconButton({
  title,
  active,
  onClick,
  children,
  disabled = false,
}: {
  title: string;
  active?: boolean;
  onClick: () => void;
  children: React.ReactNode;
  disabled?: boolean;
}) {
  return (
    <button
      className={`icon-button ${active ? "active" : ""}`}
      title={title}
      aria-label={title}
      aria-pressed={active === undefined ? undefined : active}
      onClick={onClick}
      disabled={disabled}
    >
      {children}
    </button>
  );
}
function Metric({
  label,
  value,
  unit,
  axis,
}: {
  label: string;
  value: string;
  unit?: string;
  axis?: string;
}) {
  return (
    <div className="metric">
      <span className={axis ? "axis-" + axis : ""}>{label}</span>
      <strong>{value}</strong>
      {unit && <small>{unit}</small>}
    </div>
  );
}
function App() {
  const preferences = useRef(readPrefs());
  const [doc, setDoc] = useState<ModelDocument>();
  const docRef = useRef<ModelDocument | undefined>(undefined);
  docRef.current = doc;
  const viewer = useRef<Viewer | undefined>(undefined);
  // Set while an assembly fills in, so later views keep the camera.
  const keepView = useRef(false);
  const [ready, setReady] = useState(false);
  const [runtime, setRuntime] = useState<ModelRuntime>();
  const [viewerAttempt, setViewerAttempt] = useState(0);
  const [viewerFailed, setViewerFailed] = useState(false);
  const [dimensions, setDimensions] = useState<Vector3>();
  const fileInput = useRef<HTMLInputElement>(null);
  const help = useRef<HTMLDialogElement>(null);
  const settings = useRef<HTMLDialogElement>(null);
  const [updatesOpen, setUpdatesOpen] = useState(false);
  const [updateStatus, setUpdateStatus] = useState<UpdateState["status"]>();
  useEffect(
    () =>
      window.shenzhenUpdates?.subscribe((state) =>
        setUpdateStatus(state.status),
      ),
    [],
  );
  const [mode, setMode] = useState<SelectionMode>("point"),
    [filter, setFilter] = useState<FeatureFilter>("auto"),
    [tool, setTool] = useState<ToolMode>("distance"),
    [snap, setSnap] = useState(true);
  const [distanceReference, setDistanceReference] = useState<
    "minimum" | "center" | "picked"
  >("minimum");
  const [points, setPoints] = useState<Pick[]>([]),
    [current, setCurrent] = useState<Measurement>(),
    [properties, setProperties] = useState<FeatureProperties>(),
    [pair, setPair] = useState<ExactPair>();
  const [saved, setSaved] = useState<Measurement[]>([]),
    [selectedPart, setSelectedPart] = useState<string>(),
    [partSelection, setPartSelection] = useState<PartSelection>(),
    [hidden, setHidden] = useState<Set<string>>(new Set());
  const [unit, setUnit] = useState<Unit>(preferences.current.unit || "mm"),
    [source, setSource] = useState<Unit>("mm"),
    [scale, setScale] = useState(1),
    [precision, setPrecision] = useState(preferences.current.precision ?? 3);
  const [theme, setTheme] = useState<"dark" | "light">(
    preferences.current.theme || "dark",
  );
  const [navigationDetail, setNavigationDetail] = useState<"auto" | "full">(
    preferences.current.navigationDetail === "full" ? "full" : "auto",
  );
  const [usingNavigationDetail, setUsingNavigationDetail] = useState(false);
  const [display, setDisplay] = useState<DisplayOptions>(DEFAULT_DISPLAY);
  const [rayTracing, setRayTracing] = useState(false);
  const [raySamples, setRaySamples] = useState<32 | 128 | 512>(128);
  const [rayResolution, setRayResolution] = useState<0.5 | 1>(0.5);
  const [rayState, setRayState] = useState<RayTracingState>();
  const lastRayUpdate = useRef(0);
  const [notes, setNotes] = useState<ReviewNote[]>([]);
  const [selectedNote, setSelectedNote] = useState<string>();
  const [noteScope, setNoteScope] = useState<ReviewNote["scope"]>("point");
  const [placingNote, setPlacingNote] = useState(false);
  const [noteAnchor, setNoteAnchor] = useState<Pick>();
  const [sharing, setSharing] = useState(false);
  const sourceFiles = useRef<File[]>([]);
  const demoProject = useRef(false);
  const [edges, setEdges] = useState(false),
    [grid, setGrid] = useState(true),
    [opacity, setOpacity] = useState(1),
    [explode, setExplode] = useState(0),
    [section, setSection] = useState(false),
    [sectionAxis, setSectionAxis] = useState<"x" | "y" | "z">("z"),
    [sectionPosition, setSectionPosition] = useState(0.5),
    [ortho, setOrtho] = useState(false);
  const [left, setLeft] = useState(window.innerWidth > 900),
    [right, setRight] = useState(window.innerWidth > 700),
    [panel, setPanel] = useState<"measure" | "saved" | "review">("measure");
  const [loading, setLoading] = useState(""),
    [error, setError] = useState(""),
    [toast, setToast] = useState(""),
    [hover, setHover] = useState(""),
    [dragging, setDragging] = useState(false),
    [quality, setQuality] = useState("balanced"),
    [measuring, setMeasuring] = useState(false);
  const epoch = useRef(0),
    loadEpoch = useRef(0);
  const [recent, setRecent] = useState<RecentEntry[]>([]);
  useEffect(() => {
    let active = true;
    void import("./core/recent-files")
      .then((store) => store.listRecent())
      .then((entries) => {
        if (active) setRecent(entries);
      })
      .catch(() => {
        if (active) setError("Recent files could not be restored.");
      });
    return () => {
      active = false;
    };
  }, []);
  const number = useCallback(
    (value: number, power = 1) =>
      formatValue(
        value * Math.pow(scale, power),
        source,
        unit,
        precision,
        power,
      ),
    [source, unit, precision, scale],
  );
  const notify = (message: string) => {
    setToast(message);
  };
  useEffect(() => {
    if (toast) {
      const timer = setTimeout(() => setToast(""), 4000);
      return () => clearTimeout(timer);
    }
  }, [toast]);
  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    localStorage.setItem(
      "shenzhen-preferences",
      JSON.stringify({
        unit,
        precision,
        theme,
        navigation: "auto",
        navigationVersion: 4,
        navigationDetail,
      }),
    );
  }, [unit, precision, theme, navigationDetail]);
  const clear = useCallback(() => {
    epoch.current++;
    setPoints([]);
    setCurrent(undefined);
    setProperties(undefined);
    setPair(undefined);
    setMeasuring(false);
    setPlacingNote(false);
    setNoteAnchor(undefined);
    setPartSelection(undefined);
    viewer.current?.highlight([]);
    viewer.current?.setOverlay({ points: [] });
  }, []);
  const install = useCallback(
    (model: ModelDocument) => {
      clear();
      setSaved([]);
      setNotes([]);
      setSelectedNote(undefined);
      setHidden(new Set());
      setSelectedPart(undefined);
      setSource(model.unit);
      setScale(1);
      setExplode(0);
      setSection(false);
      setOpacity(1);
      setDoc(model);
      setOrtho(model.is2D);
    },
    [clear],
  );
  useEffect(() => {
    if (ready && doc) {
      viewer.current!.setModel(doc, keepView.current);
      keepView.current = false;
      setDimensions(
        viewer.current!.getBounds().getSize(new runtime!.Vector3()),
      );
    }
  }, [doc, ready]);
  useEffect(() => {
    if (ready) viewer.current?.selectParts(partSelection?.ids ?? []);
  }, [partSelection, doc, ready]);
  useEffect(() => {
    if (ready)
      viewer.current!.applyOptions({
        edges,
        grid,
        opacity,
        explode,
        section,
        sectionAxis,
        sectionPosition,
        hidden,
        theme,
        navigation: "auto",
        navigationDetail,
        ...display,
        rayTracing,
        raySamples,
        rayResolution,
      });
  }, [
    ready,
    doc,
    edges,
    grid,
    opacity,
    explode,
    section,
    sectionAxis,
    sectionPosition,
    hidden,
    theme,
    navigationDetail,
    display,
    rayTracing,
    raySamples,
    rayResolution,
  ]);
  useEffect(() => {
    viewer.current?.setSelectionMode(mode, filter, snap);
  }, [mode, filter, snap, ready]);
  useEffect(() => {
    viewer.current?.setProjection(ortho);
  }, [ortho, ready]);
  const demo = async () => {
    const generation = ++loadEpoch.current;
    cad.cancel();
    clear();
    viewer.current?.clearModel();
    if (docRef.current) runtime!.disposeDocument(docRef.current);
    setDoc(undefined);
    setError("");
    setLoading("Opening sample model…");
    try {
      const engine = await loadRuntime();
      if (generation !== loadEpoch.current) return;
      setRuntime(engine);
      if (!ready) {
        setViewerFailed(false);
        setViewerAttempt((old) => old + 1);
      }
      sourceFiles.current = [];
      demoProject.current = true;
      install(engine.createDemo());
    } catch (failure) {
      if (generation === loadEpoch.current)
        setError(failure instanceof Error ? failure.message : String(failure));
    } finally {
      if (generation === loadEpoch.current) setLoading("");
    }
  };
  const load = useCallback(
    async (files: File[]) => {
      if (!files.length) return;
      const generation = ++loadEpoch.current;
      cad.cancel();
      clear();
      setError("");
      setDoc(undefined);
      viewer.current?.clearModel();
      if (docRef.current) runtime!.disposeDocument(docRef.current);
      setLoading("Reading file…");
      try {
        const engine = await loadRuntime();
        if (generation !== loadEpoch.current) return;
        setRuntime(engine);
        if (!ready) {
          setViewerFailed(false);
          setViewerAttempt((old) => old + 1);
        }
        const projectFile = files.find((file) =>
          file.name.toLowerCase().endsWith(".sz3d"),
        );
        const projectTools = projectFile
          ? await import("./core/project-file")
          : undefined;
        if (generation !== loadEpoch.current) return;
        const project = projectFile
          ? await projectTools!.readProject(projectFile)
          : undefined;
        if (generation !== loadEpoch.current) return;
        const modelFiles = project?.files ?? files;
        let shown = false;
        const model = project?.demo
          ? engine.createDemo()
          : await engine.importFiles(
              modelFiles,
              project?.quality ?? quality,
              (message) => {
                if (generation === loadEpoch.current) setLoading(message);
              },
              project
                ? undefined
                : (partial) => {
                    if (generation !== loadEpoch.current) return;
                    keepView.current = shown;
                    shown = true;
                    install(partial);
                  },
            );
        let restored;
        try {
          restored = project
            ? await projectTools!.restoreProjectState(project, model)
            : undefined;
        } catch (failure) {
          engine.disposeDocument(model);
          throw failure;
        }
        if (generation !== loadEpoch.current) {
          engine.disposeDocument(model);
          return;
        }
        sourceFiles.current = modelFiles;
        demoProject.current = project?.demo ?? false;
        keepView.current = shown;
        install(model);
        if (restored) {
          setNotes(restored.notes);
          setSaved(restored.measurements);
          setSource(restored.source);
          setUnit(restored.unit);
          setScale(restored.scale);
          setQuality(restored.quality);
          setPanel("review");
          setRight(true);
          if (restored.warnings.length) setError(restored.warnings.join(" "));
          else notify(`Opened project · ${restored.notes.length} notes`);
        }
        const recentName = projectFile?.name ?? model.name;
        void import("./core/recent-files")
          .then(async (store) => {
            await store.rememberRecent(
              files,
              recentName,
              projectFile ? "sz3d" : model.format,
            );
            setRecent(await store.listRecent());
          })
          .catch((failure) => {
            if (generation === loadEpoch.current)
              notify(
                `Opened file. Could not save it to recent files: ${failure instanceof Error ? failure.message : String(failure)}`,
              );
          });
        if (window.innerWidth < 900) setLeft(false);
      } catch (e) {
        if (generation === loadEpoch.current) {
          dropLoadingView();
          setError(e instanceof Error ? e.message : String(e));
        }
      } finally {
        if (generation === loadEpoch.current) setLoading("");
      }
    },
    [quality, clear, install, runtime, ready],
  );
  const nativeLoad = useRef(load);
  nativeLoad.current = load;
  useEffect(() => {
    if (!isNative() && !window.shenzhenFiles) return;
    let canceled = false;
    let unsubscribe: (() => void) | undefined;
    void import("./core/native-file-open")
      .then(async ({ subscribeNativeFiles }) => {
        if (canceled) return;
        const stop = await subscribeNativeFiles(
          (files) => nativeLoad.current(files),
          (failure) =>
            setError(
              failure instanceof Error ? failure.message : String(failure),
            ),
        );
        if (canceled) stop();
        else unsubscribe = stop;
      })
      .catch((failure) => {
        if (!canceled) setError(String(failure));
      });
    return () => {
      canceled = true;
      unsubscribe?.();
    };
  }, []);
  const open = useCallback(async () => {
    try {
      if (isNative() && !/Android|iPhone|iPad|iPod/.test(navigator.userAgent)) {
        const files = await nativeOpen();
        await load(files);
      } else fileInput.current?.click();
    } catch (e) {
      setError(String(e));
    }
  }, [load]);
  const closeDocument = () => {
    if (
      (notes.length || saved.length) &&
      !window.confirm(
        "Close this document? Save your commented project first to keep notes and measurements.",
      )
    )
      return;
    ++loadEpoch.current;
    cad.cancel();
    clear();
    viewer.current?.clearModel();
    if (docRef.current) runtime?.disposeDocument(docRef.current);
    viewer.current = undefined;
    setDoc(undefined);
    setRuntime(undefined);
    setReady(false);
    setNotes([]);
    setSaved([]);
    setRayTracing(false);
    setError("");
    setHover("");
    sourceFiles.current = [];
  };
  const startNote = (scope: ReviewNote["scope"]) => {
    if (!doc) return;
    const previous = points.at(-1);
    clear();
    setNoteScope(scope);
    setMode(
      scope === "part" ? "part" : scope === "feature" ? "feature" : "point",
    );
    setPlacingNote(true);
    setPanel("review");
    setRight(true);
    if (previous && (scope !== "feature" || previous.kind !== "point"))
      setNoteAnchor(noteTarget(previous, scope));
    else if (scope === "part" && doc && selectedPart) {
      const part = doc.parts.find((item) => item.id === selectedPart);
      const geometry = part && doc.geometries.get(part.geometryId);
      if (part && geometry) {
        geometry.geometry.computeBoundingBox();
        const local = geometry.geometry.boundingBox!.getCenter(
          new runtime!.Vector3(),
        );
        const world = local
          .clone()
          .applyMatrix4(new runtime!.Matrix4().fromArray(part.matrix));
        setNoteAnchor({
          id: uid(),
          partId: part.id,
          partName: part.name,
          geometryId: part.geometryId,
          point: world.toArray(),
          localPoint: local.toArray(),
          kind: "point",
          snap: "Part center",
          matrix: part.matrix.slice(),
          exactHandle: geometry.exactHandle,
        });
      }
    }
  };
  const createNote = (text: string) => {
    if (!noteAnchor) return;
    const timestamp = new Date().toISOString();
    const note: ReviewNote = {
      id: uid(),
      text,
      createdAt: timestamp,
      updatedAt: timestamp,
      resolved: false,
      scope: noteScope,
      anchor: noteAnchor,
    };
    setNotes((old) => [...old, note]);
    setSelectedNote(note.id);
    setPlacingNote(false);
    setNoteAnchor(undefined);
    notify("Note saved");
  };
  const selectNote = (note: ReviewNote) => {
    setSelectedNote(note.id);
    setSelectedPart(note.anchor.partId);
    setPartSelection(undefined);
    setPlacingNote(false);
    setMode(
      note.scope === "part"
        ? "part"
        : note.scope === "feature"
          ? "feature"
          : "point",
    );
    setPanel("review");
    setRight(true);
    if (hidden.has(note.anchor.partId))
      setHidden((old) => {
        const next = new Set(old);
        next.delete(note.anchor.partId);
        return next;
      });
    viewer.current?.setSelectionMode(
      note.scope === "part"
        ? "part"
        : note.scope === "feature"
          ? "feature"
          : "point",
      filter,
      snap,
    );
    viewer.current?.highlight([note.anchor]);
    viewer.current?.focusPick(note.anchor);
  };
  // The open model as a project file: the original files, notes and saved measurements.
  const buildProject = async () => {
    if (!doc) throw Error("No open model");
    const { exportProject } = await import("./core/project-file");
    const blob = await exportProject({
      doc,
      files: sourceFiles.current.slice(),
      notes,
      measurements: saved,
      source,
      unit,
      scale,
      quality,
      demo: demoProject.current,
    });
    return { blob, name: doc.name.replace(/\.[^.]+$/, "") + ".sz3d" };
  };
  const projectName = doc ? doc.name.replace(/\.[^.]+$/, "") + ".sz3d" : null;
  const [friendsLoaded, setFriendsLoaded] = useState(false);
  // Whether Friends runs here and is on: its commands and its shortcut's line in Help show only then.
  const [friendsOn, setFriendsOn] = useState(false);
  const [paletteOpen, setPaletteOpen] = useState(false);
  const friendsState = useRef({ loaded: false, on: false });
  friendsState.current = { loaded: friendsLoaded, on: friendsOn };
  // Cmd/Ctrl+K and Cmd/Ctrl+J work while typing too (Cmd+J closes Friends from its own search field), so they are
  // handled before the shortcuts below, which leave text fields alone. Neither acts over another dialog.
  useEffect(() => {
    const key = (event: KeyboardEvent) => {
      if (event.defaultPrevented || event.repeat) return;
      const palette = isPaletteShortcut(event);
      const friends =
        isFriendsShortcut(event) && Boolean(window.shenzhenFriends);
      if (!palette && !friends) return;
      event.preventDefault();
      if (document.querySelector("dialog[open]")) return;
      if (palette) setPaletteOpen(true);
      else if (!friendsState.current.loaded) {
        setFriendsLoaded(true); // Cmd+J in the first second after launch loads Friends at once.
        friendsRequests.request("toggle");
      } else if (friendsState.current.on) friendsRequests.request("toggle");
    };
    window.addEventListener("keydown", key, true);
    return () => window.removeEventListener("keydown", key, true);
  }, []);
  useEffect(() => {
    if (!window.shenzhenFriends) return;
    let timer: number | undefined;
    requestAnimationFrame(() =>
      requestAnimationFrame(() => {
        timer = window.setTimeout(() => setFriendsLoaded(true), 1000);
      }),
    );
    return () => window.clearTimeout(timer);
  }, []);
  const [settingsSeen, setSettingsSeen] = useState(false);
  useEffect(() => {
    const dialog = settings.current;
    if (!dialog || settingsSeen) return;
    // The Friends section loads the first time Settings opens, never at launch.
    const observer = new MutationObserver(
      () => dialog.open && setSettingsSeen(true),
    );
    observer.observe(dialog, { attributes: true, attributeFilter: ["open"] });
    return () => observer.disconnect();
  }, [settingsSeen]);
  const shareProject = async () => {
    if (!doc || sharing) return;
    setSharing(true);
    try {
      const { blob, name } = await buildProject();
      const file = new File([blob], name, { type: "application/octet-stream" });
      if (!isNative() && navigator.canShare?.({ files: [file] })) {
        try {
          await navigator.share({ files: [file], title: doc.name });
        } catch (failure) {
          if (failure instanceof DOMException && failure.name === "AbortError")
            throw failure;
          // A large archive may outlive the browser's transient share gesture.
          await saveBlob(blob, name);
        }
      } else await saveBlob(blob, name);
      notify("Project exported");
    } catch (failure) {
      if (!(failure instanceof DOMException && failure.name === "AbortError"))
        setError(failure instanceof Error ? failure.message : String(failure));
    } finally {
      setSharing(false);
    }
  };
  // An unfinished assembly view must not stay on screen as if it had opened.
  function dropLoadingView() {
    const shown = docRef.current;
    if (!shown?.loading) return;
    viewer.current?.clearModel();
    void loadRuntime().then((engine) => engine.disposeDocument(shown));
    docRef.current = undefined;
    setDoc(undefined);
  }
  const cancel = () => {
    loadEpoch.current++;
    cad.cancel();
    dropLoadingView();
    setLoading("");
    setError("Import canceled.");
  };
  const complete = useCallback(
    async (next: Pick[]) => {
      const generation = ++epoch.current;
      setPoints(next);
      setCurrent(undefined);
      setPair(undefined);
      setProperties(undefined);
      viewer.current?.highlight(next);
      if (!doc) return;
      const first = next[0];
      setPartSelection(undefined);
      setSelectedPart(next.at(-1)?.partId);
      setRight(true);
      setPanel("measure");
      if (mode === "feature" && next.length === 1) {
        setMeasuring(true);
        try {
          const props = await runtime!.featureProperties(doc, first);
          if (epoch.current === generation) setProperties(props);
        } catch (e) {
          if (epoch.current === generation)
            notify("Feature query unavailable: " + String(e));
        } finally {
          if (epoch.current === generation) setMeasuring(false);
        }
      }
      const count = tool === "angle" && mode !== "feature" ? 3 : 2;
      if (next.length < count) return;
      const measurement: Measurement = {
        id: uid(),
        name:
          tool === "distance"
            ? "Distance"
            : tool === "angle"
              ? "Angle"
              : "Surface path",
        kind: tool,
        reference: distanceReference,
        points: next,
        exact: false,
      };
      if (tool === "angle" && next.length === 3) {
        measurement.angle = threePointAngle(
          next[0].point,
          next[1].point,
          next[2].point,
        );
        measurement.note = "Angle at point B";
      } else {
        Object.assign(measurement, pointDistance(next[0].point, next[1].point));
        measurement.note =
          mode === "feature"
            ? "Distance between picked positions"
            : "Straight-line distance between picked points";
      }
      if (tool === "angle" && next.length === 2 && !doc.exactModelId) {
        const a = runtime!.featureDirection(doc, next[0]),
          b = runtime!.featureDirection(doc, next[1]);
        if (a && b) {
          measurement.angle = (a.angleTo(b) * 180) / Math.PI;
          measurement.note =
            "Angle between mesh surface normals or line directions (approximate).";
        } else
          measurement.note =
            "Angle is unavailable for this pair; use three-point angle mode.";
      }
      if (tool === "path") {
        if (next[0].partId !== next[1].partId) {
          measurement.note =
            "Surface paths require two points on the same part.";
          setCurrent(measurement);
          return;
        }
        setMeasuring(true);
        await new Promise((resolve) => setTimeout(resolve, 20));
        try {
          const g = doc.geometries.get(first.geometryId)!.geometry;
          const path = runtime!.surfacePath(
            g,
            first.localPoint,
            next[1].localPoint,
            first.triangleIndex,
            next[1].triangleIndex,
          );
          if (path) {
            const matrix = new runtime!.Matrix4().fromArray(first.matrix);
            measurement.path = path.points.map(
              (p) =>
                new runtime!.Vector3()
                  .fromArray(p)
                  .applyMatrix4(matrix)
                  .toArray() as Vec3,
            );
            measurement.surfaceLength = measurement.path
              .slice(1)
              .reduce(
                (sum, p, i) =>
                  sum + pointDistance(measurement.path![i], p).distance,
                0,
              );
            measurement.note =
              "Approximate shortest route along mesh edges; not an exact geodesic.";
          } else
            measurement.note =
              "No connected surface route between these points.";
        } catch (e) {
          measurement.note = String(e);
        } finally {
          if (epoch.current === generation) setMeasuring(false);
        }
      }
      if (tool === "distance" && distanceReference === "center") {
        setMeasuring(true);
        try {
          const [a, b] = await Promise.all(
            next.map((p) => runtime!.featureProperties(doc, p)),
          );
          if (!a.center || !b.center) {
            measurement.distance = undefined;
            measurement.delta = undefined;
            measurement.note =
              "Center is unavailable for one of these features. Select circular features, planar faces, or edges.";
          } else {
            Object.assign(measurement, pointDistance(a.center, b.center));
            measurement.points = next.map((p, i) => ({
              ...p,
              point: i === 0 ? a.center! : b.center!,
            }));
            measurement.exact = a.exact && b.exact;
            measurement.note = "Distance between feature centers / centroids";
          }
        } catch (e) {
          measurement.distance = undefined;
          measurement.delta = undefined;
          measurement.note = "Center query unavailable.";
        } finally {
          if (epoch.current === generation) setMeasuring(false);
        }
      } else if (
        doc.exactModelId &&
        next.length === 2 &&
        next.every((p) => p.exactHandle && p.kind !== "point") &&
        tool !== "path" &&
        (tool === "angle" || distanceReference === "minimum")
      ) {
        setMeasuring(true);
        try {
          const exact = await cad.pair(doc.exactModelId, next[0], next[1]);
          if (epoch.current !== generation) return;
          setPair(exact);
          if (tool === "angle") {
            if (exact.angle?.ok) {
              measurement.angle = exact.angle.value;
              measurement.exact = true;
              measurement.note = "Exact angle between CAD features";
            } else
              measurement.note =
                exact.angle?.message ||
                "Angle is unavailable for this feature pair.";
          } else if (exact.distance?.ok) {
            measurement.distance = exact.distance.value;
            measurement.delta = pointDistance(
              exact.distance.pointA,
              exact.distance.pointB,
            ).delta;
            measurement.points = next.map((p, i) => ({
              ...p,
              point: i === 0 ? exact.distance!.pointA : exact.distance!.pointB,
            }));
            measurement.exact = true;
            measurement.note = "Exact minimum distance between CAD features";
          }
        } catch (e) {
          measurement.note =
            "Exact query failed; showing picked-position distance.";
        } finally {
          if (epoch.current === generation) setMeasuring(false);
        }
      }
      if (epoch.current === generation) setCurrent(measurement);
    },
    [doc, mode, tool, distanceReference, runtime],
  );
  const pick = useCallback(
    (p: Pick) => {
      if (placingNote) {
        if (noteScope === "feature" && p.kind === "point") {
          notify("Pick an edge, face or vertex to attach this feature note.");
          return;
        }
        setNoteAnchor(noteTarget(p, noteScope));
        setSelectedPart(p.partId);
        viewer.current?.highlight([p]);
        setPanel("review");
        setRight(true);
        return;
      }
      if (mode === "part") {
        // Same selection as the assembly row; the view stays where it is.
        if (doc) setPartSelection(selectionForPart(doc.roots, p.partId));
        setSelectedPart(p.partId);
        viewer.current?.highlight([]);
        setLeft(true);
        return;
      }
      if (explode) {
        setExplode(0);
        notify(
          "Assembly restored for measurement. Dimensions use original coordinates.",
        );
      }
      const count = tool === "angle" && mode !== "feature" ? 3 : 2;
      const next = points.length >= count ? [p] : [...points, p];
      void complete(next);
    },
    [points, tool, mode, explode, complete, placingNote, noteScope, doc],
  );
  const miss = useCallback(() => {
    if (mode !== "part" || placingNote) return;
    setPartSelection(undefined);
    setSelectedPart(undefined);
  }, [mode, placingNote]);
  useEffect(() => {
    const p = current?.points || points;
    const text = current
      ? current.kind === "angle"
        ? current.angle !== undefined
          ? current.angle.toFixed(precision) + "°"
          : undefined
        : number(current.surfaceLength ?? current.distance ?? 0) + " " + unit
      : undefined;
    viewer.current?.setOverlay({
      points: p.map((p) => p.point),
      text,
      path: current?.path,
      showAxes: current?.kind === "distance" && !!current.delta,
      axisTexts:
        current?.kind === "distance" && current.delta
          ? (current.delta.map(
              (value, axis) => `Δ${"XYZ"[axis]} ${number(value)} ${unit}`,
            ) as [string, string, string])
          : undefined,
    });
  }, [current, points, number, unit, precision, ready]);
  const changeMode = (m: SelectionMode) => {
    clear();
    setMode(m);
  };
  const changeTool = (t: ToolMode) => {
    clear();
    setTool(t);
    if (t === "path" || mode === "part") setMode("point");
  };
  const toggleHidden = useCallback(
    (ids: string[]) =>
      setHidden((old) => {
        const next = new Set(old);
        const show = ids.every((id) => next.has(id));
        ids.forEach((id) => (show ? next.delete(id) : next.add(id)));
        return next;
      }),
    [],
  );
  const selectParts = useCallback(
    (nodeId: string, ids: string[], deselect: boolean) => {
      if (deselect) {
        setPartSelection(undefined);
        setSelectedPart(undefined);
        return;
      }
      setPartSelection({ nodeId, ids });
      setSelectedPart(ids[0]);
      // Center without changing zoom; Shift+F still fits the selection.
      viewer.current?.centerOnParts(ids);
    },
    [],
  );
  const isolate = useCallback(
    (ids: string[]) => {
      if (doc) {
        const keep = new Set(ids);
        setHidden(
          new Set(doc.parts.filter((p) => !keep.has(p.id)).map((p) => p.id)),
        );
      }
    },
    [doc],
  );
  const saveMeasurement = () => {
    if (!current) return;
    const m = { ...current, name: current.name + " " + (saved.length + 1) };
    setSaved((old) => [...old, m]);
    notify("Measurement saved");
  };
  const saveOutput = async (blob: Blob, name: string) => {
    try {
      await saveBlob(blob, name);
    } catch (e) {
      setError(
        "Could not save file: " + (e instanceof Error ? e.message : String(e)),
      );
    }
  };
  const exportMeasurements = async (format: "json" | "csv") => {
    if (!doc) return;
    const rows = saved.length ? saved : current ? [current] : [];
    if (!rows.length) {
      notify("Create a measurement first");
      return;
    }
    const report = {
      application: "Shenzhen 3D",
      version: 1,
      file: doc.name,
      sourceUnit: source,
      customScale: scale,
      displayUnit: unit,
      measurements: rows.map((m) => ({
        ...m,
        displayDistance:
          m.distance !== undefined
            ? m.distance * scale * conversion(source, unit)
            : undefined,
        displaySurfaceLength:
          m.surfaceLength !== undefined
            ? m.surfaceLength * scale * conversion(source, unit)
            : undefined,
      })),
    };
    const escape = (s: unknown) =>
      '"' + String(s ?? "").replaceAll('"', '""') + '"';
    const text =
      format === "json"
        ? JSON.stringify(report, null, 2)
        : [
            [
              "Name",
              "Type",
              "Distance (" + unit + ")",
              "Delta X",
              "Delta Y",
              "Delta Z",
              "Angle (deg)",
              "Surface path (" + unit + ")",
              "Accuracy",
              "Note",
            ],
            ...rows.map((m) => [
              m.name,
              m.kind,
              m.distance === undefined
                ? ""
                : m.distance * scale * conversion(source, unit),
              ...(m.delta || ["", "", ""]).map((v) =>
                typeof v === "number"
                  ? v * scale * conversion(source, unit)
                  : v,
              ),
              m.angle ?? "",
              m.surfaceLength === undefined
                ? ""
                : m.surfaceLength * scale * conversion(source, unit),
              m.exact ? "Exact CAD" : "Approximate / picked points",
              m.note,
            ]),
          ]
            .map((row) => row.map(escape).join(","))
            .join("\r\n");
    await saveOutput(
      new Blob([text], {
        type: format === "json" ? "application/json" : "text/csv",
      }),
      doc.name.replace(/\.[^.]+$/, "") + "-measurements." + format,
    );
  };
  const screenshot = async () => {
    if (viewer.current)
      await saveOutput(
        await viewer.current.screenshot(),
        (doc?.name || "shenzhen-3d") + ".png",
      );
  };
  const fitSelection = () => {
    if (points.length) viewer.current?.fitSelection(points);
    else if (partSelection?.ids.length) viewer.current?.fit(partSelection.ids);
    else if (selectedPart) viewer.current?.fit([selectedPart]);
  };
  const normalToSelection = () => {
    const face = points.find((point) => point.kind === "face");
    if (!face || !viewer.current?.normalToFace(face))
      notify("Select a planar face first.");
  };
  const hideSelection = (showAll: boolean) => {
    if (showAll) {
      setHidden(new Set());
      return;
    }
    const ids = points.length
      ? points.map((point) => point.partId)
      : partSelection?.ids.length
        ? partSelection.ids
        : selectedPart
          ? [selectedPart]
          : [viewer.current?.getHoveredPartId()].filter(
              (id): id is string => !!id,
            );
    if (ids.length) setHidden((previous) => new Set([...previous, ...ids]));
  };
  const actions = useRef({
    open,
    clear,
    screenshot,
    exportMeasurements,
    startNote,
    shareProject,
    fitSelection,
    normalToSelection,
    hideSelection,
  });
  actions.current = {
    open,
    clear,
    screenshot,
    exportMeasurements,
    startNote,
    shareProject,
    fitSelection,
    normalToSelection,
    hideSelection,
  };
  useEffect(() => {
    const key = (event: KeyboardEvent) => {
      const typing =
        event.target instanceof HTMLInputElement ||
        event.target instanceof HTMLTextAreaElement ||
        event.target instanceof HTMLSelectElement ||
        (event.target instanceof HTMLElement && event.target.isContentEditable);
      if (typing || event.defaultPrevented || event.repeat) return;
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "o") {
        event.preventDefault();
        void actions.current.open();
        return;
      }
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "s") {
        event.preventDefault();
        void actions.current.shareProject();
        return;
      }
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "f") {
        event.preventDefault();
        setLeft(true);
        requestAnimationFrame(() =>
          document
            .querySelector<HTMLInputElement>('[aria-label="Search assembly"]')
            ?.focus(),
        );
        return;
      }
      if (document.querySelector("dialog[open]")) return;
      if (event.key === "Escape") {
        actions.current.clear();
        setSelectedPart(undefined);
        return;
      }
      if (!docRef.current || !viewer.current) {
        if (event.key === "?") help.current?.showModal();
        return;
      }
      const shortcut = viewportShortcut(event);
      if (shortcut) {
        event.preventDefault();
        switch (shortcut.type) {
          case "view":
            viewer.current.preset(shortcut.view);
            break;
          case "fit":
            shortcut.selected
              ? actions.current.fitSelection()
              : viewer.current.fit();
            break;
          case "normal":
            actions.current.normalToSelection();
            break;
          case "comment":
            actions.current.startNote("point");
            break;
          case "section":
            setSection((value) => !value);
            break;
          case "hide":
            actions.current.hideSelection(shortcut.showAll);
            break;
        }
        return;
      }
      if (event.metaKey || event.ctrlKey || event.altKey) return;
      if (event.key.toLowerCase() === "p") {
        setMode("point");
        actions.current.clear();
      }
      if (event.key.toLowerCase() === "e") {
        setMode("feature");
        actions.current.clear();
      }
      if (event.key === "?") help.current?.showModal();
      if (event.key === "Delete" || event.key === "Backspace")
        actions.current.clear();
    };
    window.addEventListener("keydown", key);
    let unlisten: (() => void) | undefined;
    if (isNative())
      void import("@tauri-apps/api/event")
        .then(({ listen }) =>
          listen<{ action: string } | string>("native-menu", ({ payload }) => {
            const action =
              typeof payload === "string" ? payload : payload.action;
            if (action === "open") void actions.current.open();
            if (action === "fit") viewer.current?.fit();
            if (
              [
                "isometric",
                "front",
                "back",
                "left",
                "right",
                "top",
                "bottom",
              ].includes(action)
            )
              viewer.current?.preset(
                action === "isometric"
                  ? "iso"
                  : (action as
                      "front" | "back" | "left" | "right" | "top" | "bottom"),
              );
            if (action === "clear") actions.current.clear();
            if (action === "point" || action === "feature") {
              setMode(action);
              actions.current.clear();
            }
            if (action === "help") help.current?.showModal();
            if (action === "settings") settings.current?.showModal();
            if (action === "export")
              void actions.current.exportMeasurements("csv");
          }),
        )
        .then((fn) => (unlisten = fn));
    return () => {
      window.removeEventListener("keydown", key);
      unlisten?.();
    };
  }, []);
  const showSearchAssembly = () => {
    setLeft(true);
    requestAnimationFrame(() =>
      document
        .querySelector<HTMLInputElement>('[aria-label="Search assembly"]')
        ?.focus(),
    );
  };
  // Cmd/Ctrl+K. Friends' commands show only while Friends runs and is on.
  const commands: Command[] = [
    {
      id: "open",
      title: "Open file…",
      shortcut: shortcutLabel("O"),
      keywords: ["model", "drawing", "import"],
      run: () => void actions.current.open(),
    },
    ...(doc
      ? [
          {
            id: "share",
            title: "Share commented project",
            shortcut: shortcutLabel("S"),
            keywords: ["save", "sz3d", "export"],
            run: () => void actions.current.shareProject(),
          },
          {
            id: "search-assembly",
            title: "Search assembly",
            shortcut: shortcutLabel("F"),
            keywords: ["find", "part", "tree"],
            run: showSearchAssembly,
          },
          {
            id: "fit",
            title: "Fit model",
            shortcut: "F",
            keywords: ["zoom", "view"],
            run: () => viewer.current?.fit(),
          },
        ]
      : []),
    ...(friendsOn
      ? [
          {
            id: "friends-open",
            title: "Open Friends",
            shortcut: friendsShortcutLabel,
            keywords: [
              "friend",
              "nearby",
              "add by id",
              "chat",
              "message",
              "people",
            ],
            run: () => friendsRequests.request("open"),
          },
          {
            id: "friends-add",
            title: "Add by ID…",
            keywords: ["friends", "friend", "add", "invite"],
            run: () => friendsRequests.request("add_by_id"),
          },
          {
            id: "friends-visible",
            title: "Make myself visible",
            keywords: ["friends", "nearby", "discoverable"],
            run: () => friendsRequests.request("visible"),
          },
          {
            id: "friends-settings",
            title: "Friends Settings…",
            keywords: ["preferences"],
            run: () => {
              settings.current?.showModal();
              // The Friends section loads when Settings first opens.
              let frames = 0;
              const reveal = () => {
                const section = document.querySelector(
                  '[data-szfriends="settings"]',
                );
                if (section) section.scrollIntoView({ block: "start" });
                else if (++frames < 120) requestAnimationFrame(reveal);
              };
              requestAnimationFrame(reveal);
            },
          },
        ]
      : []),
    {
      id: "settings",
      title: "Settings…",
      shortcut: shortcutLabel(","),
      keywords: ["preferences", "units", "theme"],
      run: () => settings.current?.showModal(),
    },
    {
      id: "help",
      title: "Help & shortcuts",
      shortcut: "?",
      keywords: ["keyboard", "controls"],
      run: () => help.current?.showModal(),
    },
  ];
  const instruction =
    mode === "part"
      ? "Select a part to inspect"
      : points.length === 0
        ? "Pick a point on the model"
        : tool === "angle" && mode !== "feature"
          ? points.length === 1
            ? "Pick the angle vertex (B)"
            : points.length === 2
              ? "Pick the third point (C)"
              : "Angle complete · pick to start again"
          : points.length === 1
            ? "Pick a second " + (mode === "feature" ? "feature" : "point")
            : "Measurement complete · pick to start again";
  return (
    <div
      className="app"
      onDragOver={(e) => {
        e.preventDefault();
        if (e.dataTransfer.types.includes("Files")) setDragging(true);
      }}
      onDragLeave={(e) => {
        if (!e.currentTarget.contains(e.relatedTarget as Node))
          setDragging(false);
      }}
      onDrop={(e) => {
        e.preventDefault();
        setDragging(false);
        void load(Array.from(e.dataTransfer.files));
      }}
    >
      <input
        ref={fileInput}
        type="file"
        accept={
          /Android|iPhone|iPad|iPod/.test(navigator.userAgent)
            ? undefined
            : ACCEPT + ",.sz3d"
        }
        multiple
        hidden
        onChange={(e) => {
          void load(Array.from(e.target.files || []));
          e.target.value = "";
        }}
      />
      <header className="app-header">
        <a
          className="brand"
          href="#"
          onClick={(e) => e.preventDefault()}
          aria-label="Shenzhen 3D"
        >
          <img src="/icon.svg" alt="" />
          <span>
            shenzhen<span className="brand-3d">3D</span>
          </span>
        </a>
        {doc && <div className="header-divider" />}
        <div className="document-title">
          {doc ? (
            <>
              <span>{doc.name}</span>
              <small>{doc.format.toUpperCase()}</small>
            </>
          ) : null}
        </div>
        <button
          className="button primary"
          onClick={() => void open()}
          disabled={!!loading}
        >
          <FolderOpen size={16} />
          <span>Open file</span>
          <kbd>⌘ O</kbd>
        </button>
        {doc && (
          <IconButton
            title="Share commented project"
            disabled={sharing}
            onClick={() => void shareProject()}
          >
            <Share2 size={18} />
          </IconButton>
        )}
        {doc && (
          <IconButton
            title="Close document"
            onClick={closeDocument}
            disabled={!!loading}
          >
            <X size={18} />
          </IconButton>
        )}
        {friendsLoaded && (
          <Suspense fallback={null}>
            <FriendsHeader
              projectName={projectName}
              recent={recent}
              buildProject={buildProject}
              onError={setError}
              onNotice={notify}
              onAvailable={setFriendsOn}
            />
          </Suspense>
        )}
        <IconButton
          title="Settings"
          onClick={() => settings.current?.showModal()}
        >
          <Settings2 size={18} />
        </IconButton>
        <IconButton
          title="Help & shortcuts"
          onClick={() => help.current?.showModal()}
        >
          <HelpCircle size={18} />
        </IconButton>
      </header>
      {doc && (
        <div className="workspace-toolbar">
          <div className="toolbar-cluster">
            <IconButton
              title={left ? "Hide assembly" : "Show assembly"}
              onClick={() => setLeft(!left)}
            >
              {left ? (
                <PanelLeftClose size={17} />
              ) : (
                <PanelLeftOpen size={17} />
              )}
            </IconButton>
            <div className="segmented" aria-label="Selection mode">
              <button
                className={mode === "point" ? "active" : ""}
                onClick={() => changeMode("point")}
                title="Pick points · P"
              >
                <MousePointer2 size={15} />
                <span>Point</span>
              </button>
              <button
                className={mode === "feature" ? "active" : ""}
                onClick={() => changeMode("feature")}
                title="Pick CAD features · E"
              >
                <ScanLine size={15} />
                <span>Feature</span>
              </button>
              <button
                className={mode === "part" ? "active" : ""}
                onClick={() => changeMode("part")}
              >
                <Box size={15} />
                <span>Part</span>
              </button>
            </div>
            {mode === "feature" && (
              <select
                aria-label="Feature selection filter"
                value={filter}
                onChange={(e) => setFilter(e.target.value as FeatureFilter)}
              >
                <option value="auto">Auto feature</option>
                <option value="face">Faces</option>
                <option value="edge">Edges</option>
                <option value="vertex">Vertices</option>
              </select>
            )}
            <IconButton
              title="Snap to vertices and edges"
              active={snap}
              onClick={() => setSnap(!snap)}
            >
              <Magnet size={17} />
            </IconButton>
          </div>
          <div className="toolbar-cluster display-tools">
            <RenderStyleSelect
              value={display.renderStyle}
              onChange={(renderStyle) => {
                setDisplay((value) => ({ ...value, renderStyle }));
                if (renderStyle !== "shaded") setRayTracing(false);
              }}
            />
            <IconButton
              title="Review notes"
              active={panel === "review" && right}
              onClick={() => {
                setPanel("review");
                setRight(true);
              }}
            >
              <MessageSquare size={17} />
            </IconButton>
            <IconButton
              title="Fit model · F"
              onClick={() => viewer.current?.fit()}
              disabled={!doc}
            >
              <Maximize size={17} />
            </IconButton>
            <IconButton
              title="Show edges"
              disabled={display.renderStyle !== "shaded" || rayTracing}
              active={edges || display.renderStyle === "shaded-edges"}
              onClick={() => setEdges(!edges)}
            >
              <Box size={17} />
            </IconButton>
            <IconButton
              title="Ground grid"
              disabled={rayTracing}
              active={grid}
              onClick={() => setGrid(!grid)}
            >
              <Grid3X3 size={17} />
            </IconButton>
            <IconButton
              title="Section plane"
              active={section}
              onClick={() => setSection(!section)}
              disabled={!doc}
            >
              <Scissors size={17} />
            </IconButton>
            <IconButton
              title="Save screenshot"
              onClick={() => void screenshot()}
              disabled={!doc}
            >
              <Camera size={17} />
            </IconButton>
            <span className="toolbar-separator" />
            <button
              className={`text-tool ${ortho ? "active" : ""}`}
              onClick={() => setOrtho(!ortho)}
            >
              {ortho ? "Orthographic" : "Perspective"}
            </button>
            <IconButton
              title={right ? "Hide measurements" : "Show measurements"}
              onClick={() => setRight(!right)}
            >
              {right ? (
                <PanelRightClose size={17} />
              ) : (
                <PanelRightOpen size={17} />
              )}
            </IconButton>
          </div>
        </div>
      )}
      <main
        className={`workspace ${doc && left ? "with-tree" : ""} ${doc && right ? "with-inspector" : ""}`}
      >
        {doc && left && (
          <aside className="assembly-panel">
            <div className="panel-heading">
              <h2>Assembly</h2>
              <button
                className="text-link"
                onClick={() => setHidden(new Set())}
                disabled={!hidden.size}
              >
                Show all
              </button>
              <button
                className="mobile-close icon-button"
                aria-label="Close assembly"
                onClick={() => setLeft(false)}
              >
                <X size={16} />
              </button>
            </div>
            <AssemblyTree
              key={doc.name + doc.importMs}
              doc={doc}
              hidden={hidden}
              selected={selectedPart}
              selection={partSelection}
              onToggle={toggleHidden}
              onSelect={selectParts}
              onIsolate={isolate}
            />
            {doc && (
              <div className="assembly-controls">
                <label>
                  <span>Explode assembly</span>
                  <output>{Math.round(explode * 100)}%</output>
                </label>
                <input
                  aria-label="Explode assembly"
                  type="range"
                  min="0"
                  max="1"
                  step=".01"
                  value={explode}
                  onChange={(e) => setExplode(Number(e.target.value))}
                />
                <label>
                  <span>Opacity</span>
                  <output>{Math.round(opacity * 100)}%</output>
                </label>
                <input
                  aria-label="Model opacity"
                  type="range"
                  min=".08"
                  max="1"
                  step=".01"
                  value={opacity}
                  onChange={(e) => setOpacity(Number(e.target.value))}
                />
                <div className="document-size">
                  <span>Model envelope</span>
                  {dimensions && (
                    <strong>
                      {[dimensions.x, dimensions.y, dimensions.z]
                        .map((x) => number(x))
                        .join(" × ")}{" "}
                      <small>{unit}</small>
                    </strong>
                  )}
                </div>
              </div>
            )}
          </aside>
        )}
        <section className="viewport-region">
          <Viewport
            key={viewerAttempt}
            ViewerClass={runtime?.Viewer}
            onPick={pick}
            onMiss={miss}
            onHover={setHover}
            onReady={(v) => {
              viewer.current = v;
              v.onNavigationDetail = setUsingNavigationDetail;
              v.onRayTracingState = (state) => {
                const now = performance.now();
                if (
                  state.status !== "rendering" ||
                  now - lastRayUpdate.current > 100
                ) {
                  lastRayUpdate.current = now;
                  setRayState(state);
                }
              };
              setReady(true);
            }}
            onError={(message) => {
              setViewerFailed(true);
              setError(message);
            }}
          />
          {sharing && (
            <div className="project-progress" role="status">
              <LoaderCircle size={15} className="spin" /> Preparing commented
              project…
            </div>
          )}
          {rayTracing && doc && (
            <div className="ray-status-badge" role="status">
              {rayState?.status === "unsupported" ||
              rayState?.status === "error" ? (
                <button onClick={() => settings.current?.showModal()}>
                  Ray tracing unavailable · details
                </button>
              ) : (
                <>
                  <span
                    className={
                      rayState?.status === "ready" ? "status-dot" : "trace-busy"
                    }
                  />
                  {rayState?.status === "preparing"
                    ? "Preparing ray tracing"
                    : rayState?.status === "ready"
                      ? `Ray traced · ${rayState.samples} samples`
                      : `Ray tracing · ${rayState?.samples ?? 0}/${raySamples}`}
                  <button
                    aria-label="Stop ray tracing"
                    onClick={() => setRayTracing(false)}
                  >
                    <X size={13} />
                  </button>
                </>
              )}
            </div>
          )}
          {doc && (
            <ReviewPins
              viewer={ready ? viewer.current : undefined}
              notes={notes}
              selected={selectedNote}
              onSelect={selectNote}
            />
          )}
          {doc && (
            <>
              <div className="viewport-top">
                <div className="model-badge">
                  <span className="status-dot" />
                  {doc.is2D
                    ? "2D drawing"
                    : doc.exactModelId
                      ? "CAD model"
                      : "Mesh model"}
                  <span className="dot-divider">·</span>
                  {doc.parts.length.toLocaleString()} parts
                </div>
                <div className="view-presets">
                  <button
                    onClick={() => viewer.current?.preset("iso")}
                    title="Isometric · Shift 7"
                  >
                    ISO
                  </button>
                  <button
                    onClick={() => viewer.current?.preset("top")}
                    title="Top · Shift 5"
                  >
                    TOP
                  </button>
                  <button
                    onClick={() => viewer.current?.preset("front")}
                    title="Front · Shift 1"
                  >
                    FRONT
                  </button>
                  <button
                    onClick={() => viewer.current?.preset("right")}
                    title="Right · Shift 4"
                  >
                    RIGHT
                  </button>
                </div>
              </div>
              <div className="viewport-bottom">
                <span className="pick-instruction">
                  <span className="pick-dot" />
                  {placingNote
                    ? `Pick ${noteScope === "part" ? "a part" : noteScope === "feature" ? "a feature" : "a point"} to attach your note`
                    : instruction}
                </span>
                <div className="zoom-controls">
                  <IconButton
                    title="Zoom out"
                    onClick={() => viewer.current?.zoom(1 / 1.2)}
                  >
                    <ZoomOut size={16} />
                  </IconButton>
                  <IconButton
                    title="Zoom in"
                    onClick={() => viewer.current?.zoom(1.2)}
                  >
                    <ZoomIn size={16} />
                  </IconButton>
                  <IconButton
                    title="Fit model"
                    onClick={() => viewer.current?.fit()}
                  >
                    <Maximize size={16} />
                  </IconButton>
                </div>
              </div>
              <div className="axis-key">
                <span className="axis-x">X</span>
                <span className="axis-y">Y</span>
                <span className="axis-z">Z</span>
              </div>
            </>
          )}
          {!doc && !loading && (
            <div className="welcome">
              <div className="welcome-actions">
                <button
                  className="button primary large"
                  onClick={() => void open()}
                >
                  <FolderOpen size={18} /> Open file
                </button>
                <button className="button subtle" onClick={demo}>
                  Sample model <ChevronRight size={15} />
                </button>
              </div>
              <small className="drop-hint">Drop files here</small>
              <section className="recent" aria-label="Recent files">
                <span>RECENT FILES</span>
                {recent.length ? (
                  recent.map((entry) => (
                    <button
                      key={entry.id}
                      title={`Reopen ${entry.name}`}
                      onClick={() => {
                        const generation = ++loadEpoch.current;
                        setLoading(`Opening ${entry.name}…`);
                        setError("");
                        void import("./core/recent-files")
                          .then((store) => store.openRecent(entry))
                          .then((files) => {
                            if (generation === loadEpoch.current)
                              return load(files);
                          })
                          .catch((failure) => {
                            if (generation !== loadEpoch.current) return;
                            setLoading("");
                            setError(
                              failure instanceof Error
                                ? failure.message
                                : String(failure),
                            );
                          });
                      }}
                    >
                      <FileBox size={16} />
                      <span>{entry.name}</span>
                      <small>{entry.format.toUpperCase()}</small>
                      <ChevronRight size={14} />
                    </button>
                  ))
                ) : (
                  <p>No recent files</p>
                )}
              </section>
            </div>
          )}
          {section && doc && (
            <div className="section-controls">
              <Scissors size={16} />
              <strong>Section</strong>
              <select
                aria-label="Section axis"
                value={sectionAxis}
                onChange={(e) =>
                  setSectionAxis(e.target.value as "x" | "y" | "z")
                }
              >
                <option value="x">X plane</option>
                <option value="y">Y plane</option>
                <option value="z">Z plane</option>
              </select>
              <input
                aria-label="Section position"
                type="range"
                min="0"
                max="1"
                step=".001"
                value={sectionPosition}
                onChange={(e) => setSectionPosition(Number(e.target.value))}
              />
              <button
                aria-label="Close section"
                className="icon-button"
                onClick={() => setSection(false)}
              >
                <X size={14} />
              </button>
            </div>
          )}
          {(!!loading || (doc && !ready && !viewerFailed)) && (
            <div
              className={`loading-overlay${doc?.loading ? " compact" : ""}`}
              role="status"
            >
              <LoaderCircle className="spin" size={30} />
              <h2>{loading || "Starting 3D viewer…"}</h2>
              <div className="indeterminate-progress" />
              <button className="button subtle" onClick={cancel}>
                Cancel import
              </button>
            </div>
          )}
          {error && (
            <div className="error-banner" role="alert">
              <Info size={18} />
              <span>{error}</span>
              <button
                className="icon-button"
                aria-label="Dismiss error"
                onClick={() => setError("")}
              >
                <X size={16} />
              </button>
            </div>
          )}
        </section>
        {doc && right && (
          <aside className="inspector">
            <div className="panel-heading inspector-tabs">
              <button
                className={panel === "measure" ? "selected" : ""}
                onClick={() => setPanel("measure")}
              >
                Measure
              </button>
              <button
                className={panel === "saved" ? "selected" : ""}
                onClick={() => setPanel("saved")}
              >
                Saved <span>{saved.length}</span>
              </button>
              <button
                className={panel === "review" ? "selected" : ""}
                onClick={() => setPanel("review")}
              >
                Notes{" "}
                <span>{notes.filter((note) => !note.resolved).length}</span>
              </button>
              <button
                className="mobile-close icon-button"
                aria-label="Close measurements"
                onClick={() => setRight(false)}
              >
                <X size={16} />
              </button>
            </div>
            {panel === "review" ? (
              <ReviewPanel
                notes={notes}
                selected={selectedNote}
                anchor={noteAnchor}
                scope={noteScope}
                placing={placingNote}
                enabled={!!doc}
                sharing={sharing}
                onStart={startNote}
                onCancel={() => {
                  setPlacingNote(false);
                  setNoteAnchor(undefined);
                }}
                onCreate={createNote}
                onSelect={selectNote}
                onUpdate={(updated) =>
                  setNotes((old) =>
                    old.map((note) =>
                      note.id === updated.id ? updated : note,
                    ),
                  )
                }
                onDelete={(id) => {
                  setNotes((old) => old.filter((note) => note.id !== id));
                  if (selectedNote === id) {
                    setSelectedNote(undefined);
                    viewer.current?.highlight([]);
                  }
                }}
                onShare={() => void shareProject()}
              />
            ) : panel === "measure" ? (
              <div className="inspector-content">
                <div className="measurement-tools">
                  <button
                    className={tool === "distance" ? "active" : ""}
                    onClick={() => changeTool("distance")}
                  >
                    <Ruler size={17} />
                    <span>Distance</span>
                  </button>
                  <button
                    className={tool === "angle" ? "active" : ""}
                    onClick={() => changeTool("angle")}
                  >
                    <Triangle size={17} />
                    <span>Angle</span>
                  </button>
                  <button
                    className={tool === "path" ? "active" : ""}
                    onClick={() => changeTool("path")}
                  >
                    <Route size={17} />
                    <span>Surface</span>
                  </button>
                </div>
                <div className="unit-line">
                  <span>Display units</span>
                  <select
                    aria-label="Display units"
                    value={unit}
                    onChange={(e) => setUnit(e.target.value as Unit)}
                  >
                    {Object.keys(UNITS).map((u) => (
                      <option key={u} value={u}>
                        {u}
                      </option>
                    ))}
                  </select>
                </div>
                {mode === "feature" && tool === "distance" && (
                  <label className="reference-select">
                    Measure between
                    <select
                      aria-label="Distance reference"
                      value={distanceReference}
                      onChange={(e) => {
                        setDistanceReference(
                          e.target.value as "minimum" | "center" | "picked",
                        );
                        clear();
                      }}
                    >
                      <option value="minimum">Closest features</option>
                      <option value="center">Centers / centroids</option>
                      <option value="picked">Picked positions</option>
                    </select>
                  </label>
                )}
                <div className="point-list">
                  {Array.from(
                    { length: tool === "angle" && mode !== "feature" ? 3 : 2 },
                    (_, i) => (
                      <div
                        className={`point-row ${points[i] ? "filled" : ""}`}
                        key={i}
                      >
                        <span className={"point-letter point-" + i}>
                          {String.fromCharCode(65 + i)}
                        </span>
                        <div>
                          {points[i] ? (
                            <>
                              <strong title={points[i].partName}>
                                {points[i].partName}
                              </strong>
                              <small>
                                {mode === "feature"
                                  ? points[i].snap
                                  : points[i].point
                                      .map((v) => number(v))
                                      .join(", ") +
                                    " " +
                                    unit}
                              </small>
                            </>
                          ) : (
                            <>
                              <strong>
                                {i === 0
                                  ? "Start here"
                                  : tool === "angle" && i === 1
                                    ? "Angle vertex"
                                    : "Then pick here"}
                              </strong>
                              <small>
                                {mode === "feature"
                                  ? "Select a face, edge or vertex"
                                  : "Select a point on the model"}
                              </small>
                            </>
                          )}
                        </div>
                        {points[i] && <Check size={14} />}
                      </div>
                    ),
                  )}
                </div>
                {measuring && (
                  <div className="query-status">
                    <LoaderCircle size={14} className="spin" /> Calculating
                    geometry…
                  </div>
                )}
                {current ? (
                  <>
                    <div className="result-hero">
                      <span>
                        {tool === "angle"
                          ? "ANGLE"
                          : tool === "path"
                            ? "SURFACE ROUTE"
                            : distanceReference === "center"
                              ? "CENTER DISTANCE"
                              : distanceReference === "picked"
                                ? "PICKED DISTANCE"
                                : "SHORTEST DISTANCE"}
                      </span>
                      <div>
                        <strong>
                          {tool === "angle"
                            ? (current.angle?.toFixed(precision) ?? "—")
                            : current.surfaceLength !== undefined
                              ? number(current.surfaceLength)
                              : tool === "path"
                                ? "—"
                                : current.distance !== undefined
                                  ? number(current.distance)
                                  : "—"}
                        </strong>
                        <small>{tool === "angle" ? "°" : unit}</small>
                      </div>
                      <span className="accuracy-tag">
                        <span />
                        {current.exact
                          ? "Exact CAD geometry"
                          : tool === "path"
                            ? "Approximate mesh route"
                            : "Picked-point measurement"}
                      </span>
                    </div>
                    {current.delta && (
                      <div className="delta-grid">
                        <Metric
                          label="ΔX"
                          axis="x"
                          value={number(current.delta[0])}
                          unit={unit}
                        />
                        <Metric
                          label="ΔY"
                          axis="y"
                          value={number(current.delta[1])}
                          unit={unit}
                        />
                        <Metric
                          label="ΔZ"
                          axis="z"
                          value={number(current.delta[2])}
                          unit={unit}
                        />
                      </div>
                    )}
                    {pair?.angle?.ok && tool !== "angle" && (
                      <Metric
                        label="Feature angle"
                        value={pair.angle.value.toFixed(precision)}
                        unit="°"
                      />
                    )}
                    {pair?.thickness?.ok && (
                      <Metric
                        label="Normal thickness"
                        value={number(pair.thickness.value)}
                        unit={unit}
                      />
                    )}
                    <p className="measurement-note">{current.note}</p>
                    <div className="result-actions">
                      <button
                        className="button primary"
                        onClick={saveMeasurement}
                      >
                        <Plus size={15} /> Save measurement
                      </button>
                      <IconButton
                        title="Copy measurement"
                        onClick={() => {
                          void navigator.clipboard
                            .writeText(
                              tool === "angle"
                                ? `${current.angle?.toFixed(precision)}°`
                                : `${number(current.distance ?? 0)} ${unit}; ΔX ${number(current.delta?.[0] ?? 0)}, ΔY ${number(current.delta?.[1] ?? 0)}, ΔZ ${number(current.delta?.[2] ?? 0)}`,
                            )
                            .then(() => notify("Copied measurement"))
                            .catch(() =>
                              notify("Use Export to save this measurement."),
                            );
                        }}
                      >
                        <Copy size={16} />
                      </IconButton>
                    </div>
                  </>
                ) : (
                  <div className="measure-empty">
                    <div className="empty-deltas">
                      <span className="axis-x">ΔX —</span>
                      <span className="axis-y">ΔY —</span>
                      <span className="axis-z">ΔZ —</span>
                    </div>
                  </div>
                )}
                {properties && (
                  <div className="feature-properties">
                    <div className="subheading">
                      <h3>Feature properties</h3>
                      <span>{properties.exact ? "Exact" : "Approx."}</span>
                    </div>
                    {properties.family && (
                      <div className="property-type">{properties.family}</div>
                    )}
                    {properties.radius !== undefined && (
                      <Metric
                        label="Radius"
                        value={number(properties.radius)}
                        unit={unit}
                      />
                    )}{" "}
                    {properties.diameter !== undefined && (
                      <Metric
                        label="Diameter"
                        value={number(properties.diameter)}
                        unit={unit}
                      />
                    )}{" "}
                    {properties.length !== undefined && (
                      <Metric
                        label="Length"
                        value={number(properties.length)}
                        unit={unit}
                      />
                    )}{" "}
                    {properties.perimeter !== undefined && (
                      <Metric
                        label="Perimeter"
                        value={number(properties.perimeter)}
                        unit={unit}
                      />
                    )}{" "}
                    {properties.area !== undefined && (
                      <Metric
                        label="Area"
                        value={number(properties.area, 2)}
                        unit={unit + "²"}
                      />
                    )}
                  </div>
                )}
                {points.length > 0 && (
                  <button className="clear-button" onClick={clear}>
                    <RotateCcw size={14} /> Clear measurement <kbd>Esc</kbd>
                  </button>
                )}
                <details className="units-details">
                  <summary>
                    <Settings2 size={14} /> Source units & scale
                  </summary>
                  <p>
                    {doc?.sourceUnit ? `File reports: ${doc.sourceUnit}. ` : ""}
                    {doc?.exactModelId
                      ? "CAD coordinates are normalized to mm. "
                      : ""}
                    Override how one model coordinate is interpreted.
                  </p>
                  <label>
                    Interpret coordinates as
                    <select
                      aria-label="Source units"
                      value={source}
                      onChange={(e) => setSource(e.target.value as Unit)}
                    >
                      {Object.entries(UNITS).map(([u, v]) => (
                        <option key={u} value={u}>
                          {v.label} ({u})
                        </option>
                      ))}
                    </select>
                  </label>
                  <label>
                    Custom scale factor
                    <input
                      aria-label="Custom scale factor"
                      type="number"
                      min="0.000000001"
                      step="any"
                      value={scale}
                      onChange={(e) => {
                        const n = Number(e.target.value);
                        if (Number.isFinite(n) && n > 0) setScale(n);
                      }}
                    />
                  </label>
                  {["wrl", "vrml"].includes(doc?.format || "") && (
                    <button
                      className="text-link"
                      onClick={() => {
                        setSource("in");
                        setScale(0.1);
                      }}
                    >
                      Use KiCad WRL convention (0.1 inch)
                    </button>
                  )}
                  <button
                    className="text-link"
                    onClick={() => {
                      setSource(doc?.unit || "mm");
                      setScale(1);
                    }}
                  >
                    Reset to imported units
                  </button>
                </details>
              </div>
            ) : (
              <div className="saved-content">
                {saved.length ? (
                  <>
                    <div className="export-row">
                      <button
                        className="button subtle"
                        onClick={() => void exportMeasurements("csv")}
                      >
                        <Download size={14} /> CSV
                      </button>
                      <button
                        className="button subtle"
                        onClick={() => void exportMeasurements("json")}
                      >
                        <Download size={14} /> JSON
                      </button>
                    </div>
                    {saved.map((m) => (
                      <div className="saved-measurement" key={m.id}>
                        <button
                          onClick={() => {
                            clear();
                            setCurrent(m);
                            setPoints(m.points);
                            viewer.current?.highlight(m.points);
                            setTool(m.kind);
                            setDistanceReference(m.reference || "minimum");
                            setPanel("measure");
                          }}
                        >
                          <span>
                            {m.kind === "angle" ? (
                              <Triangle size={16} />
                            ) : (
                              <Ruler size={16} />
                            )}
                            <strong>{m.name}</strong>
                          </span>
                          <b>
                            {m.kind === "angle"
                              ? m.angle?.toFixed(precision) + "°"
                              : number(m.surfaceLength ?? m.distance ?? 0) +
                                " " +
                                unit}
                          </b>
                          <small>
                            {m.exact ? "Exact CAD" : "Picked / approximate"}
                          </small>
                        </button>
                        <IconButton
                          title="Delete measurement"
                          onClick={() =>
                            setSaved((s) => s.filter((x) => x.id !== m.id))
                          }
                        >
                          <Trash2 size={14} />
                        </IconButton>
                      </div>
                    ))}
                  </>
                ) : (
                  <div className="empty-panel">
                    <Ruler size={28} />
                    <p>No saved measurements</p>
                  </div>
                )}
              </div>
            )}
            {doc && doc.warnings.length > 0 && (
              <details className="import-notes">
                <summary>
                  <Info size={13} />
                  {doc.warnings.length} import note
                  {doc.warnings.length > 1 ? "s" : ""}
                </summary>
                {doc.warnings.map((w, i) => (
                  <p key={i}>{w}</p>
                ))}
              </details>
            )}
          </aside>
        )}
      </main>
      <footer className="status-bar">
        <span className="status-main">{hover || doc?.name}</span>
        <span>
          {doc?.importMs
            ? `Imported in ${(doc.importMs / 1000).toFixed(2)}s`
            : ""}
        </span>
        {doc && (
          <span className="status-navigation">
            {usingNavigationDetail
              ? "Navigation detail · full detail when still"
              : "Drag to pan · right-drag to orbit, or to pan with ⌘ or Ctrl held · swipe, pinch or wheel to zoom"}
          </span>
        )}
        {doc && (
          <button onClick={() => settings.current?.showModal()}>
            {unit} <ChevronDown size={11} />
          </button>
        )}
        {window.shenzhenUpdates ? (
          <button
            data-open-updates
            aria-label="Updates"
            onClick={() => {
              setUpdatesOpen(true);
              void window.shenzhenUpdates
                ?.check()
                .catch(() =>
                  notify("Update check unavailable. Try again from Updates."),
                );
            }}
          >
            {updateStatus === "available" || updateStatus === "ready"
              ? "Update available"
              : `v${appVersion} · Updates`}
          </button>
        ) : (
          <span className="version">v{appVersion}</span>
        )}
      </footer>
      {updatesOpen && (
        <Suspense
          fallback={
            <div className="toast" role="status">
              Opening updates…
            </div>
          }
        >
          <UpdatesDialog onClose={() => setUpdatesOpen(false)} />
        </Suspense>
      )}
      {toast && (
        <div className="toast" role="status">
          <Check size={16} />
          {toast}
        </div>
      )}
      {dragging && (
        <div className="drop-overlay">
          <Upload size={40} />
          <h2>Drop to open</h2>
          <p>Models, drawings, textures, and companion files</p>
        </div>
      )}
      <CommandPalette
        open={paletteOpen}
        commands={commands}
        onClose={() => setPaletteOpen(false)}
      />
      <dialog ref={help} className="dialog">
        <div className="dialog-heading">
          <h2>Help & shortcuts</h2>
          <IconButton title="Close help" onClick={() => help.current?.close()}>
            <X size={20} />
          </IconButton>
        </div>
        <div className="help-columns">
          <div>
            <h3>Navigation</h3>
            <dl>
              <dt>Orbit</dt>
              <dd>
                Right-drag (two-finger click-drag on a trackpad) around the
                current view center · one-finger touch
              </dd>
              <dt>Pan</dt>
              <dd>
                Left-drag or middle-drag · right-drag or two-finger click-drag
                while holding <kbd>⌘</kbd> or <kbd>Ctrl</kbd> · two-finger touch
                · two-finger trackpad swipe while holding <kbd>⌘</kbd> or{" "}
                <kbd>Ctrl</kbd>
              </dd>
              <dt>Zoom</dt>
              <dd>Two-finger trackpad swipe · mouse wheel · pinch</dd>
              {window.shenzhenScroll?.subscribeRotate && (
                <>
                  <dt>Rotate view</dt>
                  <dd>Two-finger trackpad twist</dd>
                </>
              )}
              <dt>Fit model</dt>
              <dd>
                <kbd>F</kbd>
              </dd>
              <dt>Fit selection</dt>
              <dd>
                <kbd>Shift F</kbd>
              </dd>
              <dt>Standard views</dt>
              <dd>
                <kbd>Shift 1</kbd>–<kbd>Shift 7</kbd>
                <small className="shortcut-detail">
                  Front, back, left, right, top, bottom, isometric
                </small>
              </dd>
              <dt>Normal to face</dt>
              <dd>
                <kbd>N</kbd> · repeat to flip
              </dd>
              <dt>Section</dt>
              <dd>
                <kbd>Shift X</kbd>
              </dd>
              <dt>Hide selection / show all</dt>
              <dd>
                <kbd>Y</kbd> / <kbd>Shift Y</kbd>
              </dd>
            </dl>
          </div>
          <div>
            <h3>Measurement</h3>
            <dl>
              <dt>Point mode</dt>
              <dd>
                <kbd>P</kbd> · Pick on geometry
              </dd>
              <dt>Feature mode</dt>
              <dd>
                <kbd>E</kbd> · Edges, faces, vertices
              </dd>
              <dt>Clear selections</dt>
              <dd>
                <kbd>Esc</kbd>
              </dd>
              <dt>Open file</dt>
              <dd>
                <kbd>⌘ / Ctrl O</kbd>
              </dd>
              <dt>Find a command</dt>
              <dd>
                <kbd>⌘ / Ctrl K</kbd>
              </dd>
              {friendsOn && (
                <>
                  <dt>Open or close Friends</dt>
                  <dd>
                    <kbd>⌘ / Ctrl J</kbd>
                  </dd>
                </>
              )}
              <dt>Angle</dt>
              <dd>Three points, vertex at B</dd>
              <dt>Surface route</dt>
              <dd>Approximate mesh-edge path</dd>
            </dl>
          </div>
        </div>
        <p className="help-note">
          Use <kbd>C</kbd> or the Notes tab to attach a comment to a point,
          feature or part. <kbd>⌘ / Ctrl S</kbd> shares a project containing the
          original model, notes and saved measurements. Open that .sz3d file to
          continue the review.
        </p>
        <p className="help-note">
          STEP, IGES and BREP retain CAD topology for exact feature queries.
          Mesh measurements depend on tessellation. “Shortest distance” is
          straight-line separation; “Surface” follows the mesh. Section planes
          hide geometry without modifying it. Source-unit overrides apply to all
          measurements and exports.
        </p>
        <div className="dialog-footer">
          <button
            className="button primary"
            onClick={() => help.current?.close()}
          >
            Close
          </button>
        </div>
      </dialog>
      <dialog ref={settings} className="dialog settings-dialog">
        <div className="dialog-heading">
          <h2>Settings</h2>
          <IconButton
            title="Close settings"
            onClick={() => settings.current?.close()}
          >
            <X size={20} />
          </IconButton>
        </div>
        <div className="settings-view">
          <h3>View controls</h3>
          <div className="settings-toggles">
            <button
              className={
                edges || display.renderStyle === "shaded-edges" ? "active" : ""
              }
              disabled={display.renderStyle !== "shaded" || rayTracing}
              onClick={() => setEdges(!edges)}
            >
              <Box size={16} /> Edges
            </button>
            <button
              className={grid ? "active" : ""}
              disabled={rayTracing}
              onClick={() => setGrid(!grid)}
            >
              <Grid3X3 size={16} /> Grid
            </button>
            <button
              className={ortho ? "active" : ""}
              onClick={() => setOrtho(!ortho)}
            >
              <Focus size={16} /> Orthographic
            </button>
            <button
              className={section ? "active" : ""}
              onClick={() => {
                setSection(!section);
                settings.current?.close();
              }}
            >
              <Scissors size={16} /> Section
            </button>
            <button onClick={() => void screenshot()}>
              <Camera size={16} /> Screenshot
            </button>
            <button
              onClick={() => {
                viewer.current?.fit();
                settings.current?.close();
              }}
            >
              <Maximize size={16} /> Fit model
            </button>
          </div>
          <label>
            Model opacity
            <input
              aria-label="Settings opacity"
              type="range"
              min=".08"
              max="1"
              step=".01"
              value={opacity}
              onChange={(e) => setOpacity(Number(e.target.value))}
            />
          </label>
          <label>
            Explode assembly
            <input
              aria-label="Settings explode"
              type="range"
              min="0"
              max="1"
              step=".01"
              value={explode}
              onChange={(e) => setExplode(Number(e.target.value))}
            />
          </label>
        </div>
        <DisplaySettings
          value={display}
          onChange={(next) => {
            setDisplay(next);
            if (next.renderStyle !== "shaded") setRayTracing(false);
          }}
        />
        <div className="raytrace-controls">
          <label>
            <span>GPU ray tracing</span>
            <input
              type="checkbox"
              aria-label="GPU ray tracing"
              checked={rayTracing}
              disabled={!doc || doc.is2D}
              onChange={(event) => {
                setRayTracing(event.target.checked);
                if (event.target.checked)
                  setDisplay((value) => ({ ...value, renderStyle: "shaded" }));
              }}
            />
          </label>
          <p className="render-status">
            Uses shaded mode during navigation. The ground grid is excluded.
          </p>
          {rayTracing && (
            <>
              <label>
                Samples
                <select
                  aria-label="Ray tracing samples"
                  value={raySamples}
                  onChange={(event) =>
                    setRaySamples(Number(event.target.value) as 32 | 128 | 512)
                  }
                >
                  <option value={32}>32 · Preview</option>
                  <option value={128}>128 · Balanced</option>
                  <option value={512}>512</option>
                </select>
              </label>
              <label>
                Resolution
                <select
                  aria-label="Ray tracing resolution"
                  value={rayResolution}
                  onChange={(event) =>
                    setRayResolution(Number(event.target.value) as 0.5 | 1)
                  }
                >
                  <option value={0.5}>Half</option>
                  <option value={1}>Full</option>
                </select>
              </label>
              <p className="render-status" role="status">
                {rayState?.reason ||
                  (rayState?.status === "preparing"
                    ? "Preparing geometry for GPU tracing…"
                    : rayState?.status === "ready"
                      ? `Complete · ${rayState.samples} samples`
                      : rayState?.status === "rendering"
                        ? `Rendering · ${rayState.samples} / ${rayState.target} samples`
                        : "Starting GPU ray tracing…")}
              </p>
              {rayState?.status === "rendering" && (
                <progress
                  aria-label="Ray tracing progress"
                  value={rayState.samples}
                  max={rayState.target}
                />
              )}
            </>
          )}
        </div>
        <label>
          Appearance
          <div className="segmented">
            <button
              className={theme === "dark" ? "active" : ""}
              onClick={() => setTheme("dark")}
            >
              <Moon size={15} /> Dark
            </button>
            <button
              className={theme === "light" ? "active" : ""}
              onClick={() => setTheme("light")}
            >
              <Sun size={15} /> Light
            </button>
          </div>
        </label>
        <label>
          Navigation detail
          <select
            aria-label="Navigation detail"
            value={navigationDetail}
            onChange={(e) =>
              setNavigationDetail(e.target.value as "auto" | "full")
            }
          >
            <option value="auto">Automatic</option>
            <option value="full">Full detail</option>
          </select>
          <small>
            Reduces distant detail during navigation. Measurements use the
            original geometry.
          </small>
        </label>
        <label>
          Decimal places
          <select
            value={precision}
            onChange={(e) => setPrecision(Number(e.target.value))}
          >
            {[0, 1, 2, 3, 4, 5, 6].map((n) => (
              <option key={n} value={n}>
                {n}
              </option>
            ))}
          </select>
        </label>
        <label>
          CAD tessellation
          <select value={quality} onChange={(e) => setQuality(e.target.value)}>
            <option value="fast">Fast · 0.2 mm</option>
            <option value="balanced">Balanced · 0.05 mm</option>
            <option value="fine">Fine · 0.01 mm</option>
          </select>
        </label>
        <p className="muted">
          Applies to the next import. Exact CAD measurements are unaffected.
        </p>
        {settingsSeen && window.shenzhenFriends && (
          <Suspense fallback={null}>
            <FriendsSettingsSlot visible />
          </Suspense>
        )}
        <div className="dialog-footer">
          <button
            className="button primary"
            onClick={() => settings.current?.close()}
          >
            Done
          </button>
        </div>
      </dialog>
    </div>
  );
}
export default App;
