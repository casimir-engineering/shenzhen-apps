#pragma once

#import "SPDFMacTabPreviewCache.h"
#import "markdown/SPDFMarkdownDecorations.h"

@class SPDFMarkdownPaginationPlan;

NS_ASSUME_NONNULL_BEGIN

// Tab hover thumbnails for the documents the reader lays out as text pages
// itself (Markdown, plain text, code: SPDFIsRenderedTextDocumentPath): the
// tab's current page as the reader draws it, on its paper, in its theme.

// Page `pageIndex` of a laid-out document, drawn into a thumbnail at most
// kSPDFTabPreviewMaxPoints on its long side at `scale` pixels per point. Any
// thread: the minimap draws from the same plan and text off the main thread.
SPDFTabPreviewEntry* _Nullable SPDFTabPreviewEntryForTextPage(SPDFMarkdownPaginationPlan* plan,
                                                              NSAttributedString* text, NSInteger pageIndex,
                                                              CGFloat scale);

// How the reader would lay the file out now; read on the main thread, used on
// a worker.
typedef struct {
    SPDFMarkdownThemeVariant variant;
    BOOL preservesImageColors;
    CGFloat fontScale;
    BOOL landscape;
} SPDFTabPreviewTextLayout;

// Parses and lays out the file as the reader does (font scale, theme, paper
// and its orientation, the author's paper from front matter) and draws that
// page. Off the main thread: a long document takes a while to lay out.
SPDFTabPreviewEntry* _Nullable SPDFTabPreviewEntryForTextFile(NSString* path, NSInteger pageIndex,
                                                              SPDFTabPreviewTextLayout layout, CGFloat scale);

// What a thumbnail of the file under `layout` depends on besides the page: the
// file and the layout, as one stamp. Nil when the file cannot be read.
NSString* _Nullable SPDFTabPreviewTextStamp(NSString* path, SPDFTabPreviewTextLayout layout);

// Files laid out ahead of a hover (not only on one) up to this size: past it a
// thumbnail is made when the tab is hovered.
static const unsigned long long kSPDFTabPreviewTextPrepareMaxBytes = 2u * 1024u * 1024u;

NS_ASSUME_NONNULL_END
