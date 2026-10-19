/* Search uses deterministic fixture text; it is not a native document index. */
function plainSnippet(doc) {
  return doc.snippet.replace(/<[^>]*>/g, "");
}
function markedText(text, query) {
  const term = query.trim();
  if (!term) return escapeHtml(text);
  const lower = text.toLowerCase(), needle = term.toLowerCase();
  let cursor = 0, found, output = "";
  while ((found = lower.indexOf(needle, cursor)) !== -1) {
    output += escapeHtml(text.slice(cursor, found));
    output += `<mark>${escapeHtml(text.slice(found, found + term.length))}</mark>`;
    cursor = found + term.length;
  }
  return output + escapeHtml(text.slice(cursor));
}
function collectionMatches() {
  const query = state.query.trim().toLowerCase();
  return docs.filter(doc =>
    (state.filter === "All" || doc.ext === state.filter) &&
    (!query || `${doc.title} ${plainSnippet(doc)}`.toLowerCase().includes(query))
  );
}
function collectionCount() {
  const count = collectionMatches().length;
  return `${count} ${state.query.trim() ? (count === 1 ? "match" : "matches") : (count === 1 ? "document" : "documents")}`;
}
function globalResults(query = "") {
  const collectionOnly = query.trim().toLowerCase().startsWith("col:");
  const term = query.trim().replace(/^col:\s*/i, "");
  if (!term) return `<div class="info-box">Search sample document titles, group names and retained text. Use <strong>col:</strong> for Collection only.</div><p class="caption">Deterministic sample results · No device files are indexed.</p>`;
  const matches = text => text.toLowerCase().includes(term.toLowerCase());
  const titles = docs.filter(doc => matches(doc.title));
  const matchingGroups = collectionOnly ? [] : groups.map((g, id) => ({ ...g, id })).filter(g => matches(g.name));
  const text = docs.filter(doc => !titles.includes(doc) && matches(plainSnippet(doc)));
  const section = (title, body) => body ? `<div class="section-title"><h2>${title}</h2></div>${body}` : "";
  const docResult = (doc, snippet = false) => `<button class="switch-item" data-action="${snippet ? "hit" : "doc"}:${doc.id}">${thumb(doc)}<span class="grow"><strong>${markedText(doc.title, term)}</strong><small>${doc.ext} · ${doc.group}</small>${snippet ? `<p class="search-snippet">${markedText(plainSnippet(doc), term)}</p>` : ""}</span>${icon("chevron")}</button>`;
  const count = titles.length + matchingGroups.length + text.length;
  return `<p class="caption" role="status">${count} sample ${count === 1 ? "result" : "results"}${collectionOnly ? " · Collection only" : ""}</p>` +
    section(collectionOnly ? "Collection titles" : "Document titles", titles.map(doc => docResult(doc)).join("")) +
    section("Groups", matchingGroups.map(g => `<button class="switch-item" data-action="group:${g.id}">${icon("groups")}<span class="grow"><strong>${markedText(g.name, term)}</strong><small>${g.count} documents</small></span>${icon("chevron")}</button>`).join("")) +
    section("Collected sample text", text.map(doc => docResult(doc, true)).join("")) +
    (count ? `<p class="caption">Opening a result opens its sample document. Native match positioning is outside this prototype.</p>` : `<div class="empty"><h3>No matches</h3><p>Try “quiet”, “space”, or “noticing”.</p></div>`);
}
function bindGlobalSearch() {
  $("#global-query")?.addEventListener("input", event => {
    // Replace only results so the existing input retains focus and caret position.
    state.globalTerm = event.target.value;
    $("#global-results").innerHTML = globalResults(event.target.value);
    scaleLargeText();
    $("#global-results").querySelectorAll("[data-action]").forEach(el => {
      el.onclick = () => act(el.dataset.action);
    });
  });
}
function scaleLargeText() {
  // Undo previous scaling before reading inherited sizes for freshly replaced results.
  app.querySelectorAll('[data-base-font]').forEach(el => {
    el.style.fontSize = el.dataset.baseFont;
  });
  if (!state.large) return;
  const sizes = [...app.querySelectorAll('*')]
    .filter(el => !el.closest('.status,.preview-label,.thumb,svg'))
    .map(el => [el, parseFloat(getComputedStyle(el).fontSize)]);
  sizes.forEach(([el, size]) => {
    el.dataset.baseFont = `${size}px`;
    el.style.fontSize = `${size * 2}px`;
  });
}
