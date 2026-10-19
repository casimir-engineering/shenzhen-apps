// Shenzhen Friends link pages, part 7 of 8: puts a view (part 6) on the page. Everything is set as text or as an
// attribute of an element made here; nothing is ever parsed as markup, so names and file names stay text.

function byId(doc, id) {
    return doc.getElementById(id);
}

function showText(element, text) {
    if (!element) return;
    element.textContent = text || '';
    element.hidden = !text;
}

function actionElement(doc, action, onAction) {
    const element = doc.createElement(action.href ? 'a' : 'button');
    element.className = action.primary ? 'button primary' : 'button';
    element.textContent = action.label;
    if (action.href) {
        element.setAttribute('href', action.href);
        if (action.download) element.setAttribute('download', action.download);
    } else {
        element.setAttribute('type', 'button');
    }
    element.addEventListener('click', (event) => onAction(action, event));
    return element;
}

function renderFile(doc, file) {
    const card = byId(doc, 'file');
    if (!card) return;
    card.hidden = !file;
    if (!file) return;
    showText(byId(doc, 'file-name'), file.name);
    showText(byId(doc, 'file-size'), file.size);
    const thumb = byId(doc, 'file-thumb');
    if (file.thumbnailUrl) {
        if (thumb.getAttribute('src') !== file.thumbnailUrl) thumb.setAttribute('src', file.thumbnailUrl);
        thumb.hidden = false;
    } else {
        thumb.removeAttribute('src');
        thumb.hidden = true;
    }
}

function renderProgress(doc, progress) {
    const box = byId(doc, 'progress');
    if (!box) return;
    box.hidden = !progress;
    if (!progress) return;
    const bar = byId(doc, 'progress-bar');
    bar.max = Math.max(progress.max, 1);
    bar.value = progress.max > 0 ? progress.value : 1;
    showText(byId(doc, 'progress-text'), progress.text);
}

function renderAbout(doc, about) {
    const section = byId(doc, 'about');
    if (!section) return;
    section.hidden = !about;
    if (!about) return;
    showText(byId(doc, 'about-heading'), about.heading);
    showText(byId(doc, 'about-text'), about.text);
    const links = about.links.map((link) => {
        const anchor = doc.createElement('a');
        anchor.setAttribute('href', link.href);
        anchor.setAttribute('rel', 'noopener noreferrer');
        anchor.textContent = link.label;
        return anchor;
    });
    byId(doc, 'about-links').replaceChildren(...links);
}

function renderView(doc, view, onAction) {
    doc.title = view.title;
    showText(byId(doc, 'title'), view.title);
    showText(byId(doc, 'lead'), view.lead);
    renderFile(doc, view.file ?? null);
    renderProgress(doc, view.progress ?? null);
    const notes = (view.notes ?? []).map((note) => {
        const paragraph = doc.createElement('p');
        paragraph.className = note.tone === 'warn' ? 'note warn' : 'note';
        paragraph.textContent = note.text;
        return paragraph;
    });
    byId(doc, 'notes').replaceChildren(...notes);
    // Buttons are made again only when they change, so progress updates never swallow a click on Cancel.
    const actions = view.actions ?? [];
    const box = byId(doc, 'actions');
    const key = JSON.stringify(actions.map((a) => [a.id, a.label, a.href, a.primary]));
    if (box.getAttribute('data-key') !== key) {
        box.setAttribute('data-key', key);
        box.replaceChildren(...actions.map((a) => actionElement(doc, a, onAction)));
    }
    renderAbout(doc, view.about ?? null);
}
