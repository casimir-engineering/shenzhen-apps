import { RotateCcw, Sun } from "lucide-react";
export type RenderStyle =
  "shaded" | "shaded-edges" | "wireframe" | "hidden-line";
export interface DisplayOptions {
  renderStyle: RenderStyle;
  lightAzimuth: number;
  lightElevation: number;
  lightIntensity: number;
  uniformLight: boolean;
  uniformIntensity: number;
}
export const DEFAULT_DISPLAY: DisplayOptions = {
  renderStyle: "shaded",
  lightAzimuth: (Math.atan2(-2, 1) * 180) / Math.PI,
  lightElevation: (Math.atan2(3, Math.sqrt(5)) * 180) / Math.PI,
  lightIntensity: 3.2,
  uniformLight: false,
  uniformIntensity: 2.6,
};
export function RenderStyleSelect({
  value,
  onChange,
  label = "Render style",
}: {
  value: RenderStyle;
  onChange: (value: RenderStyle) => void;
  label?: string;
}) {
  return (
    <select
      className="render-style-select"
      aria-label={label}
      value={value}
      onChange={(event) => onChange(event.target.value as RenderStyle)}
    >
      <option value="shaded">Shaded</option>
      <option value="shaded-edges">Shaded with edges</option>
      <option value="wireframe">Wireframe</option>
      <option value="hidden-line">Hidden edges dashed</option>
    </select>
  );
}
export function DisplaySettings({
  value,
  onChange,
}: {
  value: DisplayOptions;
  onChange: (value: DisplayOptions) => void;
}) {
  const change = (patch: Partial<DisplayOptions>) =>
    onChange({ ...value, ...patch });
  return (
    <>
      <label>
        Render style
        <RenderStyleSelect
          value={value.renderStyle}
          label="Settings render style"
          onChange={(renderStyle) => change({ renderStyle })}
        />
      </label>
      <details className="lighting-controls" open>
        <summary>
          <Sun size={14} /> Lighting
        </summary>
        <label>
          Light direction<output>{Math.round(value.lightAzimuth)}°</output>
          <input
            type="range"
            aria-label="Light direction"
            min={-180}
            max={180}
            step={1}
            value={value.lightAzimuth}
            onChange={(event) =>
              change({ lightAzimuth: Number(event.target.value) })
            }
          />
        </label>
        <label>
          Light elevation<output>{Math.round(value.lightElevation)}°</output>
          <input
            type="range"
            aria-label="Light elevation"
            min={-90}
            max={90}
            step={1}
            value={value.lightElevation}
            onChange={(event) =>
              change({ lightElevation: Number(event.target.value) })
            }
          />
        </label>
        <label>
          Key light<output>{value.lightIntensity.toFixed(1)}</output>
          <input
            type="range"
            aria-label="Key light intensity"
            min={0}
            max={8}
            step={0.1}
            value={value.lightIntensity}
            onChange={(event) =>
              change({ lightIntensity: Number(event.target.value) })
            }
          />
        </label>
        <label>
          <span>Uniform fill light</span>
          <input
            type="checkbox"
            aria-label="Uniform fill light"
            checked={value.uniformLight}
            onChange={(event) => change({ uniformLight: event.target.checked })}
          />
        </label>
        {value.uniformLight && (
          <label>
            Fill intensity<output>{value.uniformIntensity.toFixed(1)}</output>
            <input
              type="range"
              aria-label="Uniform light intensity"
              min={0}
              max={6}
              step={0.1}
              value={value.uniformIntensity}
              onChange={(event) =>
                change({ uniformIntensity: Number(event.target.value) })
              }
            />
          </label>
        )}
        <button
          className="text-link"
          onClick={() =>
            change({ ...DEFAULT_DISPLAY, renderStyle: value.renderStyle })
          }
        >
          <RotateCcw size={13} /> Reset lighting
        </button>
      </details>
    </>
  );
}
