#pragma once

#import <Foundation/Foundation.h>

// Where the Translate entry points are allowed to act, per tab kind.
//
// SELECTION translation only needs text, so it works on any tab that has a
// selection it may copy — a Markdown tab included, since Markdown has no
// copy-permission concept at all.
//
// WHOLE-DOCUMENT translation rewrites a rendered PDF in place: translated lines
// are drawn back at each source line's position, page by page, through the
// mupdf render path. A Markdown tab has no such geometry of its own, so it is
// first rendered to a PDF — the same rendition Save as PDF writes — and that
// PDF is what gets translated. It is therefore available on both kinds of tab.
typedef struct {
    bool markdownActive;             // rendered text session: Markdown, plain text, or source code
    bool pdfDocumentOpen;            // a mupdf document is loaded (PDF/XPS/EPUB/CBZ path)
    bool hasSelection;               // trimmed selected text is non-empty
    bool translationRunning;         // a translation job is in flight
    bool translationInstallRunning;  // the Argos installer panel is running
} spdf_translation_context;

// The Translate toolbar button and its overflow-menu twin. A PDF tab behaves
// exactly as before — enabled whenever a document is open and no translation
// job is running, with a copy-locked PDF explained on click rather than greyed
// out. Rendered text tabs also offer whole-document translation through a PDF
// rendition. Selection-only entry points require selected text.
bool spdf_translation_command_enabled(spdf_translation_context context);

// The selection-translation panel (toolbar with a selection, context menu,
// Services-style menu item).
bool spdf_translation_selection_enabled(spdf_translation_context context);

// Whole-document translation, the PDF-render-path feature. Copy permission is
// deliberately NOT part of this: a copy-locked PDF still reaches the command
// and gets the explicit "Translation is not allowed" sheet.
bool spdf_translation_whole_document_available(spdf_translation_context context);
