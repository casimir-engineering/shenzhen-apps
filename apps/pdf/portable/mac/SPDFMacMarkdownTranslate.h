#import <Cocoa/Cocoa.h>

#import "SPDFMacDelegatePrivate.h"

// Whole-document translation for a Markdown tab.
//
// The translator rewrites a PDF in place: each translated line is drawn back at
// its source line's position through the mupdf render path. A Markdown document
// has no such geometry -- it is an attributed string paginated at draw time --
// so there is nothing for that pass to write into, and Translate used to refuse.
//
// It does have a PDF rendition, though: the one Save as PDF writes. So a whole
// Markdown document is translated by rendering it beside the source file and
// translating THAT, which reaches the existing pipeline unchanged and puts both
// the rendition and the translation next to the document they came from.
@interface ShenzhenMacDelegate (SPDFMacMarkdownTranslate)
// Renders the active Markdown document to a PDF, opens it, and starts the
// whole-document translation on it. NO when the active tab is not Markdown, or
// when it has a selection (which translates on its own without any of this), so
// the caller can carry on with its usual path.
- (BOOL)beginWholeDocumentTranslationForMarkdown;
@end
