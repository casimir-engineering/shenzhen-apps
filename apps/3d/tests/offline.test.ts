import { readFile } from "node:fs/promises";
import vm from "node:vm";
import { stripTypeScriptTypes } from "node:module";
import { describe, expect, it, vi } from "vitest";
import {
  offlineCacheName,
  offlineWorkerSource,
} from "../scripts/offline-plugin";

const origin = "https://viewer.test/";
const assets = [
  "./index.html",
  "./assets/app.js",
  "./assets/cad.worker.js",
  "./cad.wasm",
  "./assets/drawing.js",
  "./assets/ray-tracing.worker.js",
];
const pause = () => new Promise((resolve) => setTimeout(resolve, 0));
function worker(
  fetcher: (request: Request & { priority: string }) => Promise<Response>,
) {
  const listeners = new Map<string, (event: any) => void>();
  const storage = new Map<string, Map<string, Response>>();
  const normalize = (request: string | Request) =>
    new URL(typeof request === "string" ? request : request.url, origin).href;
  const caches = {
    open: async (name: string) => {
      if (!storage.has(name)) storage.set(name, new Map());
      const entries = storage.get(name)!;
      return {
        put: async (request: string, response: Response) => {
          entries.set(normalize(request), response);
        },
        match: async (request: string | Request, options: unknown) => {
          expect(options).toEqual({ ignoreVary: true });
          return entries.get(normalize(request))?.clone();
        },
      };
    },
    keys: async () => [...storage.keys()],
    delete: async (name: string) => storage.delete(name),
  };
  class LocalRequest extends Request {
    priority: string;
    constructor(input: string, options: RequestInit & { priority: string }) {
      super(new URL(input, origin), options);
      this.priority = options.priority;
    }
  }
  const claim = vi.fn();
  vm.runInNewContext(offlineWorkerSource("shenzhen-3d-new", assets), {
    self: {
      addEventListener: (name: string, callback: (event: any) => void) =>
        listeners.set(name, callback),
      clients: { claim },
    },
    caches,
    fetch: fetcher,
    Request: LocalRequest,
    AbortController,
    URL,
    location: new URL(origin),
  });
  const lifecycle = (name: string) => {
    let pending!: Promise<void>;
    listeners.get(name)!({
      waitUntil: (promise: Promise<void>) => {
        pending = promise;
      },
    });
    return pending;
  };
  const fetch = (request: { method: string; url: string; mode: string }) => {
    let pending: Promise<Response | undefined> | undefined;
    listeners.get("fetch")!({
      request,
      respondWith: (promise: Promise<Response>) => {
        pending = promise;
      },
    });
    return pending;
  };
  return { lifecycle, fetch, storage, claim };
}

describe("complete offline precaching without a startup request burst", () => {
  it("copies every format at low priority with at most two requests, then activates", async () => {
    let active = 0,
      peak = 0;
    const requests: Request[] = [],
      finish: (() => void)[] = [];
    const subject = worker(async (request) => {
      expect(request.priority).toBe("low");
      requests.push(request);
      peak = Math.max(peak, ++active);
      await new Promise<void>((resolve) => finish.push(resolve));
      active--;
      return new Response(request.url);
    });
    subject.storage.set("shenzhen-3d-old", new Map());
    subject.storage.set("another-app", new Map());
    let installed = false;
    const installing = subject.lifecycle("install").then(() => {
      installed = true;
    });
    await pause();
    expect(requests).toHaveLength(2);
    expect(installed).toBe(false);
    expect(subject.storage.has("shenzhen-3d-old")).toBe(true);
    for (let index = 0; index < assets.length; index++) {
      finish[index]();
      await pause();
    }
    await installing;
    expect(peak).toBe(2);
    expect([...subject.storage.get("shenzhen-3d-new")!.keys()].sort()).toEqual(
      assets.map((asset) => new URL(asset, origin).href).sort(),
    );
    expect(subject.claim).not.toHaveBeenCalled();
    await subject.lifecycle("activate");
    expect(subject.storage.has("shenzhen-3d-old")).toBe(false);
    expect(subject.storage.has("another-app")).toBe(true);
    expect(subject.claim).toHaveBeenCalledOnce();
  });

  it("aborts an unsuccessful upgrade, removes the partial cache and preserves the active version", async () => {
    let requests = 0;
    const subject = worker(async (request) => {
      if (++requests === 1) {
        await pause();
        return new Response("missing", { status: 404 });
      }
      await new Promise((_, reject) =>
        request.signal.addEventListener(
          "abort",
          () => reject(new Error("aborted")),
          { once: true },
        ),
      );
      return new Response();
    });
    subject.storage.set(
      "shenzhen-3d-old",
      new Map([[origin, new Response("old shell")]]),
    );
    await expect(subject.lifecycle("install")).rejects.toThrow(
      "Offline asset unavailable",
    );
    expect(requests).toBe(2);
    expect(subject.storage.has("shenzhen-3d-new")).toBe(false);
    expect(subject.storage.get("shenzhen-3d-old")!.size).toBe(1);
    expect(subject.claim).not.toHaveBeenCalled();
  });

  it("serves only the current version offline, keeps navigation online first and ignores unrelated requests", async () => {
    let offline = false;
    const network = vi.fn(async (request) => {
      if (offline) throw new Error("offline");
      return new Response(request.url);
    });
    const subject = worker(network);
    await subject.lifecycle("install");
    subject.storage.set(
      "shenzhen-3d-old",
      new Map([
        [new URL("./assets/old.js", origin).href, new Response("stale")],
      ]),
    );
    offline = true;
    for (const asset of assets) {
      const response = await subject.fetch({
        method: "GET",
        url: new URL(asset, origin).href,
        mode: "cors",
      });
      expect(await response!.text()).toBe(new URL(asset, origin).href);
    }
    const navigation = {
      method: "GET",
      url: origin + "review",
      mode: "navigate",
    };
    expect(await (await subject.fetch(navigation))!.text()).toBe(
      origin + "index.html",
    );
    await expect(
      subject.fetch({
        method: "GET",
        url: origin + "assets/old.js",
        mode: "cors",
      }),
    ).rejects.toThrow("offline");
    expect(
      subject.fetch({ method: "POST", url: origin, mode: "cors" }),
    ).toBeUndefined();
    expect(
      subject.fetch({
        method: "GET",
        url: "https://other.test/",
        mode: "cors",
      }),
    ).toBeUndefined();
    offline = false;
    expect(await (await subject.fetch(navigation))!.text()).toBe(
      navigation.url,
    );
  });

  it("versions paths and bytes deterministically, including asset renames", () => {
    const files = [
      { path: "a.js", content: new Uint8Array([1, 2]) },
      { path: "b.wasm", content: new Uint8Array([3]) },
    ];
    expect(offlineCacheName(files)).toBe(
      offlineCacheName([...files].reverse()),
    );
    expect(offlineCacheName(files)).not.toBe(
      offlineCacheName([{ ...files[0], path: "c.js" }, files[1]]),
    );
    expect(offlineCacheName(files)).not.toBe(
      offlineCacheName([
        files[0],
        { ...files[1], content: new Uint8Array([4]) },
      ]),
    );
  });
});

describe("registration waits for paint and bounded idle time", () => {
  async function registration(
    protocol = "https:",
    native = false,
    idle = true,
    loaded = true,
  ) {
    const source = await readFile(
      new URL("../src/main.tsx", import.meta.url),
      "utf8",
    );
    const block = source
      .slice(source.indexOf("if (\n  import.meta.env.PROD"))
      .replace("import.meta.env.PROD", "true");
    expect(block).toContain("serviceWorker");
    const frames: (() => void)[] = [],
      timers: { callback: () => void; delay: number }[] = [];
    let onLoad: (() => void) | undefined,
      idleCallback: (() => void) | undefined;
    const register = vi.fn(async () => ({}));
    const window = {
      location: { protocol },
      ...(native ? { __TAURI_INTERNALS__: {} } : {}),
      setTimeout: (callback: () => void, delay: number) =>
        timers.push({ callback, delay }),
      ...(idle
        ? {
            requestIdleCallback: (
              callback: () => void,
              options: { timeout: number },
            ) => {
              expect(options.timeout).toBe(2000);
              idleCallback = callback;
            },
          }
        : {}),
      addEventListener: (
        event: string,
        callback: () => void,
        options: unknown,
      ) => {
        expect(event).toBe("load");
        expect(options).toEqual({ once: true });
        onLoad = callback;
      },
    };
    vm.runInNewContext(stripTypeScriptTypes(block), {
      window,
      navigator: { serviceWorker: { register } },
      document: { readyState: loaded ? "complete" : "loading" },
      requestAnimationFrame: (callback: () => void) => frames.push(callback),
    });
    return {
      frames,
      timers,
      register,
      load: () => onLoad?.(),
      idle: () => idleCallback?.(),
    };
  }
  it("does not register during load, shell paint or the first four seconds", async () => {
    const subject = await registration("https:", false, true, false);
    expect(subject.frames).toHaveLength(0);
    subject.load();
    subject.frames[0]();
    expect(subject.timers).toHaveLength(0);
    subject.frames[1]();
    expect(subject.timers[0].delay).toBe(4000);
    expect(subject.register).not.toHaveBeenCalled();
    subject.timers[0].callback();
    expect(subject.register).not.toHaveBeenCalled();
    subject.idle();
    expect(subject.register).toHaveBeenCalledWith("./sw.js");
  });
  it("has a timer fallback and excludes bundled native protocols and Tauri", async () => {
    const fallback = await registration("http:", false, false);
    fallback.frames[0]();
    fallback.frames[1]();
    fallback.timers[0].callback();
    expect(fallback.register).toHaveBeenCalledOnce();
    for (const [protocol, native] of [
      ["app:", false],
      ["tauri:", false],
      ["https:", true],
    ] as const) {
      const subject = await registration(protocol, native);
      expect(subject.frames).toHaveLength(0);
      expect(subject.register).not.toHaveBeenCalled();
    }
  });
});
