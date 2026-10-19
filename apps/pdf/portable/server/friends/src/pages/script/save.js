// Shenzhen Friends link pages, part 5 of 8: where a download goes (friends-links.md, Saving in the browser).
//
// Chromium on a computer streams to a file the person picks (File System Access). Other browsers that can stream a
// download through a service worker do that (/d/sw.js). The rest (Safari, and every browser on iPhone and iPad) keep
// the file in memory until it is saved, so a file larger than such a browser can hold is refused before it starts.
// Each sink has write(bytes), close() and abort(); the receiver writes the last chunk only after the file's SHA-256
// matched, and aborts otherwise.

const MEMORY_LIMIT_BYTES = Object.freeze({ handheld: 512 * 1048576, computer: 2 * 1073741824 });
const SAVE_WORKER = Object.freeze({ script: '/d/sw.js', scope: '/d/save/', readyMs: 5000 });

function browserTraits(win) {
    const nav = win.navigator;
    const ua = String(nav.userAgent || '');
    const touchMac = /Macintosh/.test(ua) && nav.maxTouchPoints > 1; // an iPad asking for the desktop site
    const apple = /iPhone|iPad|iPod/.test(ua) || touchMac;
    const handheld = apple || /Android|Mobile/.test(ua);
    const mac = !handheld && (nav.userAgentData?.platform === 'macOS' || /Macintosh|Mac OS X/.test(ua));
    // Safari, and every browser on iPhone and iPad (all WebKit), cannot be relied on to stream a download from a
    // service worker.
    const webkit = apple || (/Safari\//.test(ua) && !/Chrome\/|Chromium\/|Edg\/|Firefox\/|Android/.test(ua));
    // Where the person is, for which apps can open a link here (view.js).
    let platform = 'other';
    if (apple) platform = 'ipad-iphone';
    else if (/Android/.test(ua)) platform = 'android';
    else if (mac) platform = 'mac';
    else if (/Windows/.test(ua)) platform = 'windows';
    else if (/Linux|X11/.test(ua) && !/CrOS/.test(ua)) platform = 'linux';
    return {
        mac,
        platform,
        handheld,
        webrtc: typeof win.RTCPeerConnection === 'function' && Boolean(win.crypto?.subtle),
        fileSystemAccess: typeof win.showSaveFilePicker === 'function',
        serviceWorker: Boolean(win.isSecureContext && nav.serviceWorker && !webkit
            && typeof win.ReadableStream === 'function'),
    };
}

// How this browser saves a file of `size` bytes, and whether it is too large for it.
function chooseSaver(traits, size) {
    if (traits.fileSystemAccess) return { kind: 'file', tooLarge: false };
    if (traits.serviceWorker) return { kind: 'stream', tooLarge: false };
    const limit = traits.handheld ? MEMORY_LIMIT_BYTES.handheld : MEMORY_LIMIT_BYTES.computer;
    return { kind: 'memory', tooLarge: size > limit };
}

// A file name the browser and the person's file system accept: no path separators, control or bidi characters
// (so the extension saved is the one shown), no leading dots, at most 200 characters, cut before the extension.
function saveName(name) {
    let cleaned = plainName(name).replace(/[\\/:*?"<>|\p{Cc}]/gu, '_').replace(/^[.\s]+/, '').trim();
    if (cleaned.length > 200) {
        const dot = cleaned.lastIndexOf('.');
        const extension = dot > 0 && cleaned.length - dot <= 16 ? cleaned.slice(dot) : '';
        cleaned = cleaned.slice(0, 200 - extension.length) + extension;
    }
    return cleaned || 'download';
}

function sinkError(reason) {
    const error = new Error(reason);
    error.linkReason = reason;
    return error;
}

// Must be called straight from the Download click: the file picker needs the click's user activation.
async function fileSink(win, meta) {
    const handle = await win.showSaveFilePicker({ suggestedName: saveName(meta.name) });
    const writable = await handle.createWritable();
    return {
        kind: 'file',
        write: (bytes) => writable.write(bytes),
        close: () => writable.close(),
        abort: () => writable.abort(),
    };
}

function memorySink(win, meta) {
    let parts = [];
    const sink = {
        kind: 'memory',
        url: null,
        write: async (bytes) => {
            parts.push(bytes);
        },
        close: async () => {
            sink.url = win.URL.createObjectURL(new win.Blob(parts, { type: meta.type }));
            parts = [];
        },
        abort: async () => {
            parts = [];
        },
    };
    return sink;
}

function activeWorker(win, registration) {
    const worker = registration.active || registration.waiting || registration.installing;
    if (!worker) return Promise.reject(new Error('no worker'));
    if (worker.state === 'activated') return Promise.resolve(worker);
    return new Promise((resolve, reject) => {
        const timer = win.setTimeout(() => reject(new Error('worker not ready')), SAVE_WORKER.readyMs);
        worker.addEventListener('statechange', () => {
            if (worker.state === 'activated') {
                win.clearTimeout(timer);
                resolve(worker);
            } else if (worker.state === 'redundant') {
                win.clearTimeout(timer);
                reject(new Error('worker failed'));
            }
        });
    });
}

// Streams through the service worker: the page posts each chunk when the worker's stream asks for one ("pull"), and
// a hidden frame opens /d/save/<id>, which the worker answers with the stream as a download.
async function streamSink(win, doc, meta) {
    const registration = await win.navigator.serviceWorker.register(SAVE_WORKER.script, { scope: SAVE_WORKER.scope });
    const worker = await activeWorker(win, registration);
    const id = Array.from(win.crypto.getRandomValues(new Uint8Array(16)), (b) => b.toString(16).padStart(2, '0'))
        .join('');
    const channel = new win.MessageChannel();
    const port = channel.port1;
    let credits = 0;
    let stopped = false;
    let wake = null;
    let ready = null;
    const isReady = new Promise((resolve, reject) => {
        ready = resolve;
        win.setTimeout(() => reject(new Error('worker did not answer')), SAVE_WORKER.readyMs);
    });
    port.onmessage = (event) => {
        const type = event.data?.type;
        if (type === 'ready') ready();
        else if (type === 'pull') credits += 1;
        else if (type === 'cancel') stopped = true;
        wake?.();
    };
    worker.postMessage({ type: 'szf-save', id, name: saveName(meta.name), size: meta.size }, [channel.port2]);
    await isReady;
    const frame = doc.createElement('iframe');
    frame.hidden = true;
    frame.src = `${SAVE_WORKER.scope}${id}`;
    doc.body.append(frame);
    return {
        kind: 'stream',
        async write(bytes) {
            while (credits === 0 && !stopped) await new Promise((resolve) => { wake = resolve; });
            wake = null;
            if (stopped) throw sinkError('cancelled');
            credits -= 1;
            const own = bytes.byteOffset === 0 && bytes.byteLength === bytes.buffer.byteLength ? bytes : bytes.slice();
            port.postMessage({ type: 'chunk', bytes: own }, [own.buffer]);
        },
        // The port is let go once the last message is posted; the worker still receives it.
        async close() {
            port.postMessage({ type: 'close' });
            port.close();
        },
        async abort() {
            port.postMessage({ type: 'abort' });
            port.close();
        },
    };
}

// The sink a Download click gets: the file picker, the service worker, or else memory. Null when the person closed the
// file picker; 'nosave' when only memory is left and the file is too large for it.
async function openSink(win, doc, meta, traits) {
    const saver = chooseSaver(traits, meta.size);
    if (saver.kind === 'file') {
        try {
            return await fileSink(win, meta);
        } catch (error) {
            if (error?.name === 'AbortError') return null;
        }
    } else if (saver.kind === 'stream') {
        const sink = await streamSink(win, doc, meta).catch(() => null);
        if (sink) return sink;
    }
    const memory = chooseSaver({ ...traits, fileSystemAccess: false, serviceWorker: false }, meta.size);
    return memory.tooLarge ? 'nosave' : memorySink(win, meta);
}
