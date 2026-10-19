// Shenzhen Friends link pages, part 6 of 8: what each page says, as plain data the renderer (part 7) puts on the
// page as text. Written for someone who may never have heard of these apps: what this is, what they can do here,
// and what happens next. Names from a link are wrapped in Unicode isolates so a hostile name cannot reorder the
// sentence around it.

const APP_NAMES = Object.freeze({ pdf: 'ShenzhenPDF', files: 'Shenzhen Files', '3d': 'Shenzhen 3D' });
// The apps as a sentence names them where any one of them will do.
const ANY_APP = 'ShenzhenPDF, Shenzhen Files or Shenzhen 3D';
// Where Shenzhen 3D opens these links besides a Mac (browserTraits' platforms); ShenzhenPDF and Shenzhen Files are
// Mac apps. Its iPhone, iPad and Android builds reach friends only nearby and open no links yet.
const THREE_D_ELSEWHERE = Object.freeze(['windows', 'linux']);

// The apps that open these links on the device in hand: all three on a Mac, Shenzhen 3D on Windows and Linux, none
// elsewhere.
function appsHere(traits) {
    if (traits.mac) return LINK_APPS;
    return THREE_D_ELSEWHERE.includes(traits.platform) ? ['3d'] : [];
}

function appsSentence(apps) {
    return apps.length > 1 ? ANY_APP : APP_NAMES[apps[0]];
}

// What the person holds, as "Nothing opened?" names it.
function deviceNoun(traits) {
    return traits.mac ? 'Mac' : 'computer';
}
const SIZE_UNITS = ['KB', 'MB', 'GB', 'TB', 'PB'];

function isolate(text) {
    return `⁨${text}⁩`;
}

function capitalize(text) {
    return text.charAt(0).toUpperCase() + text.slice(1);
}

function formatBytes(count) {
    if (count < 1000) return count === 1 ? '1 byte' : `${count} bytes`;
    let value = count / 1000;
    let unit = 0;
    while (unit < SIZE_UNITS.length - 1 && Number(value.toFixed(value < 10 ? 1 : 0)) >= 1000) {
        value /= 1000;
        unit += 1;
    }
    return `${value.toFixed(value < 10 ? 1 : 0)} ${SIZE_UNITS[unit]}`;
}

function aboutApps(urls, apps) {
    const links = apps.map((app) => ({ label: `Get ${APP_NAMES[app]}`, href: urls[app] })).filter((link) => link.href);
    if (apps.length === 1) {
        return { heading: 'New to Shenzhen 3D?', text: 'Shenzhen 3D is a 3D model viewer for Windows, Linux and Mac, '
            + 'and it’s all you need to open this link.', links };
    }
    return {
        heading: 'New to these apps?',
        text: 'ShenzhenPDF is a document reader, Shenzhen Files is a file manager and Shenzhen 3D is a 3D model '
            + 'viewer. All three are free for Macs with Apple silicon, and Shenzhen 3D also runs on Windows and Linux. '
            + 'Any one of them is all you need.',
        links,
    };
}

// The Open buttons for `apps`, the remembered app first; `primary` makes the first one the main button.
function openActions(link, remembered, primary, apps) {
    const order = apps.includes(remembered) ? [remembered, ...apps.filter((app) => app !== remembered)] : apps;
    return order.map((app, i) => ({ id: `open-${app}`, app, label: `Open in ${APP_NAMES[app]}`,
        href: appLinkUrl(app, link), primary: primary && i === 0 }));
}

// Points to the app's Get link when the page has one; otherwise to the other apps, which open the link as well.
function notOpenedNote(app, urls, traits) {
    const name = APP_NAMES[app];
    const missing = `Nothing opened? ${name} may not be on this ${deviceNoun(traits)} yet.`;
    if (urls[app]) return { text: `${missing} Get it below, then open this link again.` };
    const others = appsHere(traits).filter((other) => other !== app && urls[other]).map((other) => APP_NAMES[other]);
    return { text: missing + (others.length ? ` Open this link in ${others.join(' or ')} instead.` : '') };
}

const INCOMPLETE = Object.freeze({ lead: 'Part of the link is missing. Ask the person who sent it to copy the link '
    + 'again.' });

function friendView({ link, traits, remembered, opened, urls }) {
    if (!link) return { title: 'This invitation link is incomplete', lead: INCOMPLETE.lead, actions: [], notes: [] };
    const who = link.name ? isolate(link.name) : `Friends ID ${link.friendsId}`;
    const title = link.name ? `${who} invited you to Shenzhen Friends` : 'You’re invited to Shenzhen Friends';
    const apps = appsHere(traits);
    if (!apps.length) {
        return { title, lead: 'Shenzhen Friends works in ShenzhenPDF, Shenzhen Files and Shenzhen 3D on a Mac with '
            + `Apple silicon, and in Shenzhen 3D on Windows and Linux. Open this link on one of those computers to add `
            + `${who}.`, actions: [], notes: [], about: aboutApps(urls, LINK_APPS) };
    }
    const where = apps.length > 1 ? 'any of these apps' : APP_NAMES[apps[0]];
    return {
        title,
        lead: `With Shenzhen Friends, you and ${who} can send each other messages and documents. Open this `
            + `invitation in ${where} to add ${who}.`,
        actions: openActions(link, remembered, true, apps),
        notes: opened ? [notOpenedNote(opened, urls, traits)] : [],
        about: aboutApps(urls, apps),
    };
}

// A download link carries no name (PROTOCOL.md § Links): the sender is named once the sealed metadata arrives.
function senderWords(meta) {
    const name = meta?.sender || '';
    const who = name ? isolate(name) : 'the sender';
    return { who, Who: capitalize(who), computer: `${who}’s computer` };
}

// What a failed download says, by the receiver's reason (receiver.js), and whether Try again is offered.
function failureView(reason, s, downloading) {
    const stopped = downloading ? 'The download stopped and nothing was saved. ' : '';
    switch (reason) {
    case 'changed': return { title: `${s.Who} changed this file after sharing the link`,
        lead: `Ask ${s.who} to share it again.` };
    case 'revoked': return { title: `${s.Who} stopped sharing this file`, lead: '' };
    case 'expired': return { title: 'This link has expired', lead: `Ask ${s.who} to share the file again.` };
    case 'unavailable': return { title: `${s.Who} can’t send this file right now`,
        lead: `It may have been moved or deleted on their computer. Ask ${s.who} to share it again.` };
    case 'gone': return { title: 'This link isn’t working',
        lead: `${s.Who} may have stopped sharing the file. Ask ${s.who} for a new link.` };
    case 'nopath': return { title: `Couldn’t connect to ${s.who}`,
        lead: `${stopped}Try again, or try from another network.`, retry: true };
    case 'corrupt': return { title: 'The file didn’t arrive intact', lead: 'Nothing was saved. Try again.',
        retry: true };
    case 'unreachable': return { title: 'This page can’t connect',
        lead: 'Check your Internet connection, then try again.', retry: true };
    case 'busy': return { title: 'Too many downloads from this network right now',
        lead: 'Try again in a few minutes.', retry: true };
    case 'cancelled': return { title: 'Download cancelled', lead: '', retry: true };
    case 'nosave': return { title: 'This browser couldn’t save the file',
        lead: 'Try again, or open this page in Chrome or Edge on a computer.', retry: true };
    default: return { title: `The connection to ${s.who} was lost`, lead: `${stopped}Try again.`, retry: true };
    }
}

function fileCard(meta, thumbnailUrl) {
    return { name: meta.name, size: formatBytes(meta.size), thumbnailUrl };
}

function tooLargeNote(traits) {
    const here = appsHere(traits);
    const apps = here.length ? `, or open the file in ${appsSentence(here)}` : '';
    return { tone: 'warn', text: `This file is too large for this browser to save. Open this page in Chrome or Edge `
        + `on a computer${apps}.` };
}

// `model`: the link, the browser's traits, the remembered app, the receiver's state and detail, the metadata, how
// this browser saves (save.js) and, once done, the sink.
function downloadView(model) {
    const { link, traits, remembered, state, detail = {}, meta, saver, opened, urls } = model;
    if (!link) return { title: 'This download link is incomplete', lead: INCOMPLETE.lead, actions: [], notes: [] };
    const s = senderWords(meta);
    const here = appsHere(traits);
    const apps = openActions(link, remembered, false, here);
    const notes = opened ? [notOpenedNote(opened, urls, traits)] : [];
    const about = here.length ? aboutApps(urls, here) : null;
    if (!traits.webrtc) {
        return { title: 'This browser can’t receive the file', lead: 'Open this link in a recent version of Chrome, '
            + 'Edge, Firefox or Safari.', actions: apps, notes, about };
    }
    const file = meta ? fileCard(meta, model.thumbnailUrl) : null;
    switch (state) {
    case 'waiting':
        return { title: `Waiting for ${s.who}`, lead: `The file comes once ${s.who} has ${ANY_APP} open. `
            + 'Keep this page open.', actions: [], notes: [] };
    case 'ready': {
        // Download leads; when the browser cannot save the file, the first app (the remembered one) does.
        const actions = saver.tooLarge ? openActions(link, remembered, true, here)
            : [{ id: 'download', label: 'Download', primary: true }, ...apps];
        return { title: `${s.Who} shared a file with you`, lead: '', file, actions,
            notes: saver.tooLarge ? [tooLargeNote(traits), ...notes] : notes, about };
    }
    case 'progress':
        return { title: 'Downloading…', lead: '', file, progress: { value: detail.received, max: detail.size,
            text: `${formatBytes(detail.received)} of ${formatBytes(detail.size)}` },
        notes: [{ text: progressNote(detail.resuming, s) }], actions: [{ id: 'cancel', label: 'Cancel' }] };
    case 'done':
        return doneView(meta, model.sink, file);
    case 'failed': {
        const failure = failureView(detail.reason, s, model.wasDownloading);
        return { title: failure.title, lead: failure.lead, file,
            actions: failure.retry ? [{ id: 'retry', label: 'Try again', primary: true }] : [], notes: [] };
    }
    default:
        return { title: `Connecting to ${s.who}…`, lead: '', actions: [], notes: [] };
    }
}

// While a download reconnects it says so, and that nothing is lost.
function progressNote(resuming, s) {
    if (resuming === 'waiting') {
        return `Waiting for ${s.who} to come back online. The download will carry on from where it stopped. Keep `
            + 'this page open.';
    }
    if (resuming) return `The connection to ${s.who} dropped. Reconnecting to carry on from where it stopped…`;
    return `Keep this page open until the download finishes: the file is coming straight from ${s.computer}.`;
}

function doneView(meta, sink, file) {
    const name = isolate(meta.name);
    if (sink?.kind === 'memory') {
        return { title: 'Download complete', lead: `Save ${name} to keep it.`, file, notes: [],
            actions: [{ id: 'save', label: 'Save file', href: sink.url, download: saveName(meta.name),
                primary: true }] };
    }
    const lead = sink?.kind === 'file' ? `${name} is saved where you chose.` : `Your browser has saved ${name}.`;
    return { title: 'Download complete', lead, file, notes: [], actions: [] };
}
