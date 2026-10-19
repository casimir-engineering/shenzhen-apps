/* Sample DOM navigation makes the prototype's reading-state transitions inspectable. */
function contentsItems() {
  return d().ext === "EPUB"
    ? ["The small things", "An invitation to look again", "Begin where you are"]
    : d().ext === "MD"
      ? ["Field notes", "01 / Materials", "02 / A small experiment", "03 / Next visit"]
      : ["A room for thought", "Light, space & stillness", "Leave a little room"];
}
function bindFind() {
  $("#find-query")?.addEventListener("input", event => {
    const query = event.target.value.trim();
    state.findQuery = query;
    const sample = document.createElement("template");
    sample.innerHTML = paper();
    state.findResults = [...sample.content.querySelectorAll('p,h1,h2,.dek,li')]
      .map(el => el.textContent)
      .filter(text => query && text.toLowerCase().includes(query.toLowerCase()));
    $("#find-results").innerHTML = !query
      ? `<p class="caption">Search this sample document's actual text.</p>`
      : state.findResults.length
        ? `<p class="caption" role="status">${state.findResults.length} sample matches</p>` + state.findResults.map((text, i) => `<button class="switch-item" data-action="found:${i}"><span><strong>${d().ext} · Match ${i + 1}</strong><p class="search-snippet">${markedText(text, query)}</p></span>${icon("arrow")}</button>`).join("")
        : `<div class="empty"><h3>No matches</h3><p>No sample text contains “${escapeHtml(query)}”.</p></div>`;
    $("#find-results").querySelectorAll('[data-action]').forEach(el => el.onclick = () => act(el.dataset.action));
    scaleLargeText();
  });
}
function captureSearchOrigin() {
  return { screen: state.screen, doc: state.doc, older: state.older,
    revisionDate: state.revisionDate, query: state.query, filter: state.filter,
    scroll: $('.scroll')?.scrollTop || 0 };
}
function handleReadingAction(name, value) {
  if (name === 'export') {
    const explicitUnverified = value === 'captured-24';
    const explicitDate = explicitUnverified ? '24 Sep 2026' : value ? `${value} Sep 2026` : null;
    state.exportTarget = { doc: state.doc,
      revisionDate: explicitDate || (state.older ? state.revisionDate || '18 Sep 2026' : null),
      unverified: explicitUnverified || (!explicitDate && !!state.unverified) };
    state.sheet = 'export'; render(); return true;
  }
  if (name === 'latest' && state.missing && state.preferredRecoveryDate) {
    state.older = true; state.unverified = false;
    state.revisionDate = state.preferredRecoveryDate;
    state.searchActive = false; state.staleMatch = false;
    state.screen = 'reader'; state.sheet = null; render(); return true;
  }

  if (name === 'found' || name === 'hit') {
    state.searchOrigin = captureSearchOrigin();
    state.searchTerm = name === 'found' ? state.findQuery : (state.sheet === "globalsearch" ? state.globalTerm : state.query).replace(/^col:\s*/i, '');
    state.hitIndex = name === 'found' ? Number(value) : 0;
    if (name === 'hit') { state.doc = Number(value); state.older = false; }
    state.searchActive = true; state.sheet = null; state.screen = 'reader';
    render(); return true;
  }
  if (name === 'returnsearch') {
    const origin = state.searchOrigin;
    state.searchActive = false; state.staleMatch = false;
    if (origin) Object.assign(state, origin);
    state.sheet = null; render();
    requestAnimationFrame(() => { if ($('.scroll')) $('.scroll').scrollTop = origin?.scroll || 0; });
    return true;
  }
  if (name === 'latest' && state.staleMatch) {
    state.searchActive = false; state.staleMatch = false;
  }
  if (name === 'recovery') { state.sheet = 'recovery'; render(); return true; }
  if (name === 'opencapture') {
    state.unverified = true; state.older = true; state.revisionDate = '24 Sep 2026';
    state.screen = 'reader'; state.sheet = null; render(); return true;
  }
  if (name === 'chapter') {
    state.sheet = null; render();
    requestAnimationFrame(() => {
      const target = [...app.querySelectorAll('.paper h1,.paper h2')][Math.min(Number(value), app.querySelectorAll('.paper h1,.paper h2').length-1)];
      target?.scrollIntoView({block:'start'});
    });
    return true;
  }
  return false;
}
function renderReadingEnhancements() {
  if (state.screen !== 'reader') return;
  const viewport = $('.reader-scroll');
  if (state.unverified) {
    const note = document.createElement('div');note.className = 'notice';
    note.innerHTML = `<span>Captured copy · ${state.revisionDate}<br>Source consistency unverified</span>`;
    viewport.before(note);
  }
  if (!state.searchActive) return;
  const notice = document.createElement('div');notice.className = 'notice search-destination';
  notice.innerHTML = `<span>${state.staleMatch ? `Match in saved version · ${state.revisionDate}` : 'Match in sample text'}<br><strong>${escapeHtml(state.searchTerm || '')}</strong></span><button data-action="returnsearch">Return</button>${state.staleMatch ? '<button data-action="latest">Open latest</button>' : ''}`;
  viewport.before(notice);
  notice.querySelectorAll('button').forEach(el => el.onclick = () => act(el.dataset.action));
  const term = (state.searchTerm || '').toLowerCase();
  if (!term) return;
  const nodes = [], walker = document.createTreeWalker($('.paper'), NodeFilter.SHOW_TEXT);
  while (walker.nextNode()) if (walker.currentNode.textContent.toLowerCase().includes(term)) nodes.push(walker.currentNode);
  const node = nodes[Math.min(state.hitIndex || 0, nodes.length - 1)];
  if (node) {
    const span = document.createElement('span');span.innerHTML = markedText(node.textContent, state.searchTerm);
    node.replaceWith(span);
    requestAnimationFrame(() => span.querySelector('mark')?.scrollIntoView({block:'center'}));
  }
}
function recoverySheet() {
  if (state.onlyUnverified) return sheet('Choose a recovery copy', `<p class="lead">The original is unavailable. The only complete saved capture could not be verified against a stable source.</p><div class="info-box">24 Sep 2026 · Source consistency unverified<br>No Latest badge: this is not a verified original revision.</div><button class="primary" data-action="opencapture">Open captured copy · 24 Sep</button><button class="secondary" data-action="locate">Find original</button><button class="text-button" style="width:100%" data-action="export:captured-24">Save a separate copy</button>`);
  return sheet('A verified way back', `<p class="lead">The original is unavailable. Your latest verified copy is open, even though a newer unverified capture exists.</p><div class="revision-card"><span class="pill">Latest verified</span><h3 style="margin-top:8px">18 Sep 2026</h3><p>Verified source · Read-only saved copy</p></div><div class="revision-card"><span class="pill gold">Unverified capture</span><h3 style="margin-top:8px">24 Sep 2026</h3><p>Newer, but source consistency was not verified.</p><button data-action="opencapture">Open this capture explicitly</button></div><button class="primary" style="margin-top:18px" data-action="close">Keep reading verified copy</button><button class="secondary" data-action="locate">Find original</button>`);
}
function initReadingFixtures() {
  if (scene === 'dark') state.dark = true;
  if (scene === 'overflow') { docs[6].group = docs[0].group; groups[0].count=7; state.sheet='switcher'; }
  if (scene === 'onealternative') {
    docs.slice(2).forEach(doc => doc.group='Research');groups[0].count=2;
    state.slots=[0,1];state.sheet='switcher';
  }
  if (scene === 'longtitles') {
    docs[0].title='A room for thought: observations on the spaces between everyday life and a quieter way of working';
    groups[0].name='Design, architecture & the everyday spaces we call home';
    docs.slice(0,6).forEach(doc => doc.group=groups[0].name);
    state.sheet='switcher';
  }
  if (scene === 'stale') {
    state.staleMatch=true;state.searchActive=true;state.searchTerm='quiet';state.older=true;
    state.revisionDate='12 Sep 2026';state.searchOrigin={screen:'collection',doc:0,older:false,query:'quiet',filter:'All',scroll:0};
  }
  if (scene === 'recovery' || scene === 'unverified') {
    state.missing=true;state.onlyUnverified=scene==='unverified';state.sheet='recovery';
    if(state.onlyUnverified) state.screen='groups';
    else {state.older=true;state.revisionDate='18 Sep 2026';state.preferredRecoveryDate='18 Sep 2026';}
  }
}

function revisionReturnControl() {
  if (!state.missing) return '<button data-action="latest">Return to latest</button>';
  if (!state.preferredRecoveryDate) return '<button data-action="recovery">Recovery choices</button>';
  return state.unverified || state.revisionDate !== state.preferredRecoveryDate
    ? '<button data-action="latest">Return to latest verified</button>'
    : '<span class="pill">Latest verified</span>';
}
function exportTargetDescription() {
  const target = state.exportTarget || {doc:state.doc};
  const doc = docs[target.doc];
  return `${doc.title}.${doc.ext.toLowerCase()}<br>${target.revisionDate
    ? `${target.revisionDate} version${target.unverified ? ' · source consistency unverified' : ''}`
    : 'Current readable version'}`;
}
