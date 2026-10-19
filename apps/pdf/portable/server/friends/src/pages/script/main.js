// Shenzhen Friends link pages, part 8 of 8: starts the page the body names (data-page "friend" or "download"). The
// link's secret stays in the fragment: it is read from location.hash and never sent anywhere; only the link id goes
// to the host, inside link_open.

const REMEMBERED_APP_KEY = 'szfriends-app';
const RENDER_EVERY_MS = 250;

function rememberedApp(win) {
    try {
        const value = win.localStorage.getItem(REMEMBERED_APP_KEY);
        return LINK_APPS.includes(value) ? value : null;
    } catch {
        return null;
    }
}

function rememberApp(win, app) {
    try {
        win.localStorage.setItem(REMEMBERED_APP_KEY, app);
    } catch {
        // Private browsing without storage: the choice is simply not remembered.
    }
}

function pageUrls(body) {
    return { pdf: body.getAttribute('data-pdf-url') || '', files: body.getAttribute('data-files-url') || '',
        '3d': body.getAttribute('data-3d-url') || '' };
}

function browserEnv(win) {
    return {
        WebSocket: win.WebSocket,
        RTCPeerConnection: win.RTCPeerConnection,
        crypto: win.crypto,
        setTimeout: (fn, ms) => win.setTimeout(fn, ms),
        clearTimeout: (timer) => win.clearTimeout(timer),
        now: () => Date.now(),
    };
}

function startFriendPage(win, doc) {
    const model = { link: parseLinkPayload('f', win.location.hash.slice(1)), traits: browserTraits(win),
        remembered: rememberedApp(win), opened: null, urls: pageUrls(doc.body) };
    const render = () => renderView(doc, friendView(model), (action) => {
        if (!action.app) return;
        rememberApp(win, action.app);
        model.remembered = action.app;
        // The link opens the app itself; if nothing happens, the page explains where to get it.
        win.setTimeout(() => {
            model.opened = action.app;
            render();
        }, 1500);
    });
    render();
}

function startDownloadPage(win, doc) {
    const body = doc.body;
    const model = { link: parseLinkPayload('d', win.location.hash.slice(1)), traits: browserTraits(win),
        remembered: rememberedApp(win), urls: pageUrls(body), state: 'connecting', detail: {} };
    let receiver = null;
    let renderTimer = null;
    const render = () => {
        win.clearTimeout(renderTimer);
        renderTimer = null;
        renderView(doc, downloadView(model), onAction);
    };
    const onState = (state, detail) => {
        if (state === 'ready') {
            model.meta = detail.meta;
            model.saver = chooseSaver(model.traits, detail.meta.size);
            if (detail.meta.thumbnail && !model.thumbnailUrl) {
                model.thumbnailUrl = win.URL.createObjectURL(new win.Blob([detail.meta.thumbnail],
                    { type: 'image/png' }));
            }
        }
        if (state === 'failed') model.wasDownloading = model.state === 'progress';
        const throttled = state === 'progress' && model.state === 'progress'
            && detail.resuming === model.detail.resuming;
        model.state = state;
        model.detail = detail;
        if (!throttled) render();
        else if (!renderTimer) renderTimer = win.setTimeout(render, RENDER_EVERY_MS);
    };
    const start = () => {
        receiver?.shutdown();
        model.state = 'connecting';
        model.sink = null;
        receiver = new LinkReceiver(browserEnv(win), {
            wsUrl: `${win.location.protocol === 'https:' ? 'wss' : 'ws'}://${win.location.host}/v1?guest=1`,
            link: model.link,
            stunUrls: (body.getAttribute('data-stun') || '').split(' ').filter(Boolean),
            onState,
        });
        render();
        receiver.start().catch(() => onState('failed', { reason: 'unreachable' }));
    };
    // Straight from the click, so the file picker has its user activation.
    async function download() {
        const sink = await openSink(win, doc, model.meta, model.traits);
        if (sink === null) return undefined;
        if (sink === 'nosave') return onState('failed', { reason: 'nosave' });
        model.sink = sink;
        return receiver.download(sink);
    }
    function onAction(action) {
        if (action.app) {
            rememberApp(win, action.app);
            model.remembered = action.app;
            win.setTimeout(() => {
                model.opened = action.app;
                render();
            }, 1500);
        } else if (action.id === 'download') {
            download();
        } else if (action.id === 'cancel') {
            receiver.cancel();
        } else if (action.id === 'retry') {
            start();
        }
    }
    win.addEventListener('pagehide', () => receiver?.shutdown());
    if (!model.link || !model.traits.webrtc) return render();
    return start();
}

if (typeof document !== 'undefined' && document.body) {
    const page = document.body.getAttribute('data-page');
    if (page === 'friend') startFriendPage(window, document);
    else if (page === 'download') startDownloadPage(window, document);
}
