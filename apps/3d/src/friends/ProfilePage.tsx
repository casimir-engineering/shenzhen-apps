// The profile behind Add by ID: your name, animal or own picture with its crop, your ID, Add by ID, Your links
// and Your computers.
import { useEffect, useRef, useState } from "react";
import type { DeviceRow, ProfileData } from "./protocol";
import {
  ActionButton,
  AvatarView,
  CopyButton,
  PageHeader,
  useAnimal,
  usePanel,
} from "./parts";
import { useView } from "./store";
import type { AnimalList } from "./bridge";

export function ProfilePage({ onBack }: { onBack(): void }) {
  const panel = usePanel();
  const { store } = panel;
  const strings = store.strings;
  const data = useView<ProfileData>(store, "profile", {
    type: "subscribe",
    fields: { view: "profile" },
  });
  const [name, setName] = useState<string | null>(null);
  const [friendID, setFriendID] = useState("");
  const [message, setMessage] = useState<string | null>(null);
  const [choosing, setChoosing] = useState(false);
  const [photo, setPhoto] = useState<{
    url: string;
    bytes: Uint8Array;
    width: number;
    height: number;
  } | null>(null);
  const fileInput = useRef<HTMLInputElement>(null);
  if (!data)
    return (
      <div className="szf-page">
        <PageHeader onBack={onBack} backLabel={strings.back} />
      </div>
    );
  const value = name ?? data.name.value ?? "";
  return (
    <div className="szf-page szf-profile">
      <PageHeader back={data.back} backLabel={strings.back} onBack={onBack}>
        <strong>{data.title}</strong>
      </PageHeader>
      <div className="szf-scroll szf-form">
        <div className="szf-identity">
          <AvatarView avatar={data.picture.avatar} size={64} />
          <div className="szf-actions">
            <button
              type="button"
              className="szf-button secondary"
              onClick={() => setChoosing((old) => !old)}
            >
              {data.picture.choose_label}
            </button>
            <button
              type="button"
              className="szf-button secondary"
              onClick={() => fileInput.current?.click()}
            >
              {data.picture.own_picture_label}
            </button>
            <input
              ref={fileInput}
              type="file"
              accept="image/png,image/jpeg,image/heic,image/webp,image/gif"
              hidden
              onChange={async (event) => {
                const file = event.target.files?.[0];
                event.target.value = "";
                if (!file) return;
                const bytes = new Uint8Array(await file.arrayBuffer());
                const url = URL.createObjectURL(file);
                const image = new Image();
                image.onload = () =>
                  setPhoto({
                    url,
                    bytes,
                    width: image.naturalWidth,
                    height: image.naturalHeight,
                  });
                image.src = url;
              }}
            />
          </div>
        </div>
        {choosing && (
          <AnimalPicker
            set={data.picture.animal_set}
            selected={data.picture.selected_index}
            onChoose={async (index) => {
              const reply = await store.send("set_picture", {
                picture: {
                  kind: "animal",
                  set: data.picture.animal_set,
                  index,
                },
              });
              panel.report(reply);
              if (reply.ok) setChoosing(false);
            }}
          />
        )}
        {photo && (
          <CropView
            photo={photo}
            onCancel={() => setPhoto(null)}
            onUse={async (crop) => {
              const reply = await store.send("set_picture", {
                picture: {
                  kind: "image",
                  data_base64: base64(photo.bytes),
                  crop,
                },
              });
              panel.report(reply);
              if (reply.ok) setPhoto(null);
            }}
          />
        )}
        <form
          className="szf-field"
          onSubmit={async (event) => {
            event.preventDefault();
            const reply = await store.send("set_name", { name: value });
            panel.report(reply);
            if (reply.ok) setName(null);
          }}
        >
          <label>
            <span>{data.name.label}</span>
            <input
              value={value}
              maxLength={data.name.max_length * 4}
              placeholder={data.name.placeholder}
              onChange={(event) => setName(event.target.value)}
              onBlur={(event) => event.currentTarget.form?.requestSubmit()}
            />
          </label>
        </form>
        <section className="szf-section">
          <span className="szf-label">{data.id.label}</span>
          <div className="szf-line">
            <strong className="szf-id">{data.id.friends_id}</strong>
            <CopyButton value={data.id.friends_id} label={data.id.copy_label} />
          </div>
          <small>{data.id.note}</small>
        </section>
        <form
          className="szf-field"
          onSubmit={async (event) => {
            event.preventDefault();
            if (!friendID.trim()) return;
            const reply = await store.send("add_by_id", {
              friends_id: friendID.trim(),
            });
            panel.report(reply);
            if (reply.ok) {
              setFriendID("");
              setMessage((reply.result?.message as string) ?? null);
            }
          }}
        >
          <label>
            <span>{data.add.label}</span>
            <span className="szf-inline">
              <input
                value={friendID}
                placeholder={data.add.placeholder}
                onChange={(event) => setFriendID(event.target.value)}
              />
              <button type="submit" className="szf-button primary">
                {data.add.button_label}
              </button>
            </span>
          </label>
          <small>{message ?? data.add.hint}</small>
        </form>
        {data.links && (
          <section className="szf-section">
            <strong>{data.links.title}</strong>
            <span className="szf-label">{data.links.friend.label}</span>
            <div className="szf-line">
              <span className="szf-url">{data.links.friend.url}</span>
              <CopyButton
                value={data.links.friend.url}
                label={data.links.friend.copy_label}
              />
            </div>
            <small>{data.links.friend.note}</small>
            <ActionButton action={data.links.friend.reset} />
            <span className="szf-label">{data.links.downloads_label}</span>
            {data.links.downloads_empty && (
              <small>{data.links.downloads_empty}</small>
            )}
            {data.links.downloads.map((link) => (
              <div key={link.link_id} className="szf-line">
                <span>
                  {link.file_name}
                  <small>
                    {link.downloads_label} · {link.expires_label}
                  </small>
                </span>
                <ActionButton action={link.revoke} />
              </div>
            ))}
          </section>
        )}
        {data.devices && (
          <section className="szf-section">
            <strong>{data.devices.title}</strong>
            {data.devices.rows.map((row) => (
              <DeviceRowView key={row.device_id} row={row} />
            ))}
            {data.devices.add && (
              <div className="szf-device-add">
                <strong>{data.devices.add.title}</strong>
                <ol>
                  {data.devices.add.steps.map((step) => (
                    <li key={step}>{step}</li>
                  ))}
                </ol>
              </div>
            )}
          </section>
        )}
      </div>
    </div>
  );
}

function base64(bytes: Uint8Array) {
  let text = "";
  for (let index = 0; index < bytes.length; index += 0x8000)
    text += String.fromCharCode(...bytes.subarray(index, index + 0x8000));
  return btoa(text);
}

function AnimalPicker({
  set,
  selected,
  onChoose,
}: {
  set: number;
  selected: number | null;
  onChoose(index: number): void;
}) {
  const { bridge, store } = usePanel();
  const [list, setList] = useState<AnimalList | null>(null);
  useEffect(() => {
    void bridge.animals().then(setList);
  }, [bridge]);
  if (!list || list.set !== set) return null;
  return (
    <div
      className="szf-animals"
      role="listbox"
      aria-label={store.strings.animals_title}
    >
      {store.strings.animals_title && (
        <strong>{store.strings.animals_title}</strong>
      )}
      <div className="szf-animal-grid">
        {list.animals.map((animal) => (
          <AnimalChoice
            key={animal.index}
            set={set}
            index={animal.index}
            name={animal.name}
            selected={animal.index === selected}
            onChoose={onChoose}
          />
        ))}
      </div>
    </div>
  );
}
function AnimalChoice({
  set,
  index,
  name,
  selected,
  onChoose,
}: {
  set: number;
  index: number;
  name: string;
  selected: boolean;
  onChoose(index: number): void;
}) {
  const url = useAnimal(set, index);
  return (
    <button
      type="button"
      role="option"
      aria-selected={selected}
      aria-label={name}
      title={name}
      className={selected ? "selected" : ""}
      onClick={() => onChoose(index)}
    >
      {url && <img src={url} alt="" width={40} height={40} draggable={false} />}
    </button>
  );
}

/** Crop your picture: a square on the photo, in source pixels; the helper makes the circle. */
function CropView({
  photo,
  onCancel,
  onUse,
}: {
  photo: { url: string; width: number; height: number };
  onCancel(): void;
  onUse(crop: { x: number; y: number; side: number }): void;
}) {
  const { store } = usePanel();
  const strings = store.strings;
  const view = 200;
  const short = Math.min(photo.width, photo.height);
  const [zoom, setZoom] = useState(1);
  const [center, setCenter] = useState({
    x: photo.width / 2,
    y: photo.height / 2,
  });
  const side = Math.max(1, Math.round(short / zoom));
  const clamp = (value: number, max: number) =>
    Math.min(Math.max(value, side / 2), max - side / 2);
  const x = Math.round(clamp(center.x, photo.width) - side / 2);
  const y = Math.round(clamp(center.y, photo.height) - side / 2);
  const scale = view / side;
  const drag = useRef<{ x: number; y: number; cx: number; cy: number } | null>(
    null,
  );
  useEffect(() => () => URL.revokeObjectURL(photo.url), [photo.url]);
  return (
    <div className="szf-crop">
      {strings.crop_title && <strong>{strings.crop_title}</strong>}
      <div
        className="szf-crop-view"
        style={{ width: view, height: view }}
        onPointerDown={(event) => {
          event.currentTarget.setPointerCapture(event.pointerId);
          drag.current = {
            x: event.clientX,
            y: event.clientY,
            cx: x + side / 2,
            cy: y + side / 2,
          };
        }}
        onPointerMove={(event) => {
          if (!drag.current) return;
          setCenter({
            x: drag.current.cx - (event.clientX - drag.current.x) / scale,
            y: drag.current.cy - (event.clientY - drag.current.y) / scale,
          });
        }}
        onPointerUp={() => (drag.current = null)}
      >
        <img
          src={photo.url}
          alt=""
          draggable={false}
          style={{
            width: photo.width * scale,
            height: photo.height * scale,
            left: -x * scale,
            top: -y * scale,
          }}
        />
      </div>
      <input
        type="range"
        min={1}
        max={4}
        step={0.01}
        value={zoom}
        onChange={(event) => setZoom(Number(event.target.value))}
        aria-label={strings.crop_title}
      />
      <div className="szf-actions">
        {strings.crop_use && (
          <button
            type="button"
            className="szf-button primary"
            onClick={() => onUse({ x, y, side })}
          >
            {strings.crop_use}
          </button>
        )}
        {strings.cancel && (
          <button type="button" className="szf-button link" onClick={onCancel}>
            {strings.cancel}
          </button>
        )}
      </div>
    </div>
  );
}

function DeviceRowView({ row }: { row: DeviceRow }) {
  const panel = usePanel();
  const [name, setName] = useState<string | null>(null);
  return (
    <div className="szf-device" aria-label={row.accessibility_label}>
      <span className={`szf-dot ${row.state}`} aria-hidden="true" />
      <span className="szf-device-text">
        <strong>{row.name}</strong>
        <small>{row.detail}</small>
      </span>
      {row.rename &&
        (name === null ? (
          <button
            type="button"
            className="szf-button link"
            onClick={() => setName(row.name)}
          >
            {row.rename.label}
          </button>
        ) : (
          <form
            className="szf-inline"
            onSubmit={async (event) => {
              event.preventDefault();
              const reply = await panel.store.send("rename_device", { name });
              panel.report(reply);
              if (reply.ok) setName(null);
            }}
          >
            <input
              autoFocus
              value={name}
              placeholder={row.rename.placeholder}
              onChange={(event) => setName(event.target.value)}
            />
            <button type="submit" className="szf-button primary">
              {row.rename.button_label}
            </button>
          </form>
        ))}
      {row.remove && <ActionButton action={row.remove} />}
    </div>
  );
}
