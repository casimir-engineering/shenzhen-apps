# Markdown Reader Parity

This document exercises the same paged reading interface used for PDF files.

## Untyped Code Block

The fenced block below intentionally has no language identifier. Use the language control above the block to search for and select a syntax highlighter.

```
function summarizePages(pages) {
  const visible = pages.filter((page) => page.visible);
  return visible.map((page) => page.title).join(", ");
}

const result = summarizePages([
  { title: "Introduction", visible: true },
  { title: "Appendix", visible: false },
]);
```

The complete fenced region must behave as one code block, never as independent line-by-line blocks.

### Navigation Detail

This H3 heading should appear nested beneath the H2 entry in the Chapters panel.

The reader should preserve normal text selection, link activation, keyboard navigation, trackpad scrolling, pointer-anchored zoom, and minimap dragging while this document remains rendered as A4 sheets.

1. Open the Chapters panel and jump between the H1, H2, and H3 entries.
2. Search for `visible` and use the shared Search panel to visit every result.
3. Zoom with the toolbar, a pinch gesture, and Command-scroll without changing the selected chapter.
4. Drag the minimap viewport and verify that the document follows continuously.
5. Return to this page and confirm that the code fence above still behaves as one block.

### A4 Pagination Notes

Each sheet is drawn from the canonical attributed document. Screen pagination reserves a compact row for the syntax selector, while printing and PDF export use the same text without that interactive row.

The syntax selector belongs to the complete fenced region. Choosing JavaScript, TypeScript, Python, Swift, or Plain Text must rerender the complete block, never one visual line at a time.

The paragraphs in this fixture deliberately extend beyond one sheet. This makes the existing PDF minimap useful during acceptance instead of triggering the correct single-page behavior that hides it by default.

## Search and Map

Search for the word `visible` to verify result navigation and highlighting. The minimap should represent every A4 page and keep its viewport synchronized while scrolling or zooming.

### Reader Parity Checklist

- The document opens inside the ordinary tab strip and shares the standard page counter.
- Fit Page, Fit Width, Fit Height, Actual Size, and custom zoom remain available.
- Previous, next, first, and last page navigation use the same toolbar and menu commands.
- Command-W closes the current tab, and reopening the file restores its own position.
- The Chapters panel contains headings from levels one through three and excludes deeper headings.
- Search results retain their canonical text ranges after zooming or resizing the side panel.
- The minimap starts with lightweight page proxies and fills thumbnails lazily outside first paint.
- Scrolling the minimap, dragging its viewport, and zooming over it preserve the pointer anchor.
- Text remains selectable across ordinary paragraphs, lists, links, and the complete code block.
- Double-click selection chooses a word and triple-click selection chooses a text line or block.
- Opening an external link uses the normal system browser while local Markdown links stay in the reader.
- Printing and Save as PDF remain vector text operations so exported text stays selectable.
- A change to the source file invalidates the cached Markdown session without affecting other tabs.
- Switching between a PDF and this Markdown file restores each document's independent viewport.
- Background thumbnail work is cancellable and must never delay direct page or zoom input.
- The first visible sheet appears before non-visible pages are warmed.

### Additional Search Context

The word visible appears here so the Search panel has a result outside the code block. A second visible occurrence appears in ordinary prose, and a third visible occurrence follows after this sentence.

The page counter should update as this section crosses a sheet boundary. The currently selected chapter should follow the closest preceding H1-H3 heading, even when several headings happen to share one physical A4 page.

The minimap viewport is based on the real document coordinate system. It must neither drift during zoom nor wait for a mouse release before showing the destination sheet.

### Long-Document Interaction

Trackpad input should remain two-dimensional. A horizontal gesture must not make the following vertical gesture feel sticky, and fast movement should remain bounded rather than jumping to the beginning or end of the document.

Mouse-wheel input over the minimap is capped for discrete wheels while precise trackpad input remains smooth. Command or Control modifiers perform zoom only and never change the page at the same time.

The page canvas remains vector-backed. Zooming changes geometry immediately, and the document must stay responsive while any secondary thumbnail or cache work continues away from the interaction path.

### State Restoration

This section provides another chapter boundary for the sidebar. Move to the middle of the paragraph, switch to a PDF tab, and return: the visible location, selected text, zoom mode, side panel, minimap, and search result should belong to this document alone.

Opening a second Markdown document must create a separate session. Language choices, search ranges, and scroll positions cannot leak between tabs, even when both documents contain headings with identical titles.

Resizing the window or side panel recomputes Fit modes without resetting a custom zoom. Backing-scale changes should preserve the same logical page and avoid a flash of the hidden PDF canvas.

### Export Boundary

The on-screen language selector is interactive chrome. It reserves space in the reader, but it must not leave a blank synthetic line in printed output or in the saved PDF.

The exported document should retain searchable text, code formatting, headings, lists, and links. Images, when present, stay within a bounded resource budget and do not block the initial sheet.

#### This H4 Must Not Become A Chapter

This heading is intentionally deeper than H3. It renders in the document but must not appear in the Chapters panel.

### Final Check

The Chapters panel should include this heading, while headings below H3 would intentionally be omitted from the document outline.

Search once more for `visible`, choose a language for the untyped fence, drag to the final minimap sheet, and return to the first chapter. The controls should behave exactly as they do for a PDF tab.
