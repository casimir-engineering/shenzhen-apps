#import <Cocoa/Cocoa.h>

#import "SPDFMacDelegatePrivate.h"

// Adopting one document's own view state. Every document (re)load and every tab
// switch funnels through -prepareSelectedTabViewState:path:, which makes it both
// the invalidation choke point for per-page caches and the single place a tab's
// per-document preferences become the window's live state. Split out of
// ShenzhenPDFMac.mm so that seam is readable on its own.
@interface ShenzhenMacDelegate (SPDFMacTabViewState)

- (void)prepareSelectedTabViewState:(SPDFDocumentTab*)tab path:(NSString*)path;
// A newly opened document starts at the launch default (settings.yaml
// "darkThemePreservesImages") and remembers its own choice from there.
- (void)seedKeepImageColorsForNewTab:(SPDFDocumentTab*)tab;
// Everything a freshly opened document takes from what the app already knows
// about that file: the keep-image-colors default above, plus the Markdown page
// orientation it was last read on. Panel visibility is deliberately NOT part of
// this (see -newTabForPath:) -- orientation is, because a sheet turned for a
// wide table or a gantt chart belongs to the document, not to the window.
- (void)seedNewTabFromDocumentMemory:(SPDFDocumentTab*)tab;
// The document view the app installs. A tab switch replaces it, so everything
// window-level it carries -- including the reading theme, whose gutter and page
// border a fresh Light view would silently drop -- is applied here.
- (SPDFDocumentView*)newDocumentView;
- (void)replaceDocumentViewForTabSwitch;
- (void)rememberActiveMarkdownStateForTab:(SPDFDocumentTab*)tab;

@end
