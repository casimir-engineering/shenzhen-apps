#pragma once

#import "SPDFMacDelegatePrivate.h"
#import "SPDFMacMarkdownSession.h"

NS_ASSUME_NONNULL_BEGIN

// Private bridge used by the focused Markdown and shared file-action category
// implementations. Keeping these declarations here avoids growing the main
// delegate interface with cross-module implementation details.
@interface ShenzhenMacDelegate (SPDFMacMarkdownHostAccess)
// The shared toolbar-button factory (bezel, font, layout metrics) every
// toolbar image button is built with.
- (NSButton*)buttonWithTitle:(NSString*)title action:(SEL)action;
- (nullable NSDictionary*)fileAttributesForPath:(NSString*)path;
- (void)recordFileAttributes:(NSDictionary*)attributes forTab:(SPDFDocumentTab*)tab;
- (void)prepareSelectedTabViewState:(SPDFDocumentTab*)tab path:(NSString*)path;
- (void)showUnavailableSelectedTab:(SPDFDocumentTab*)tab
                              path:(NSString*)path
                           message:(NSString*)message
                     showOpenError:(BOOL)showOpenError
                             error:(const char* _Nullable)error;
- (NSInteger)indexOfTabForPath:(NSString*)path;
- (void)updateTabStrip;
- (void)updateControls;
- (void)syncToolbarState;
- (void)persistActiveState;
- (void)rememberRecentlyOpenedPath:(NSString*)path;
- (void)setSidebarActuallyVisible:(BOOL)visible;
- (void)setMinimapActuallyVisible:(BOOL)visible;
- (void)rebuildSidebar;
- (void)syncSidebarModeControlSegmentsForSearchAvailability:(BOOL)hasSearch;
- (void)syncSidebarFilterField;
- (void)syncSidebarTableColumnWidth;
- (void)restoreSidebarWidth;
- (void)selectCurrentSidebarRow;
- (void)applySinglePageMinimapDefaultToTab:(SPDFDocumentTab*)tab pageCount:(NSInteger)pageCount;
- (void)showError:(NSString*)message detail:(NSString*)detail;
- (void)ensureSecurityAccessForPath:(NSString*)path;
- (NSString*)displayNameForPathConsideringOpenTabs:(NSString*)path;
- (void)copyPathStringToPasteboard:(NSString*)path statusMessage:(NSString*)statusMessage;
- (void)copyTabFileToPasteboardAtIndex:(NSInteger)index;
- (void)selectPreviousTab:(nullable id)sender;
- (void)selectNextTab:(nullable id)sender;
- (void)beginOrSustainKeyboardScrollInDirection:(CGFloat)direction
                                           axis:(NSInteger)axis
                                        keyCode:(unsigned short)keyCode
                                       isRepeat:(BOOL)isRepeat;
// ShenzhenPDFMac.mm's shared toolbar-overflow item builder.
- (void)addOverflowItemWithTitle:(NSString*)title
                          action:(SEL)action
                            menu:(NSMenu*)menu
                           state:(NSControlStateValue)state
                         enabled:(BOOL)enabled;
@end

// The document-agnostic reading-theme toggle (always-visible toolbar button,
// Shift+Cmd+I, and the persisted "markdownTheme" preference), implemented in
// SPDFMacReadingThemeIntegration.mm and wired like the font-size controls.
@interface ShenzhenMacDelegate (SPDFMacReadingThemeIntegration)
- (SPDFMarkdownThemeVariant)markdownThemeVariant;
// Render flags every fixed-page render must carry, so one preference drives
// Markdown restyling and pixmap recoloring alike. Print and export never ask.
- (unsigned)readingThemeRenderFlags;
// A rendered bitmap carries what it was rendered with, so a stale one can be
// recognised: the theme, plus this document's keep-image-colors choice.
- (void)stampReadingThemeOnRenderedPage:(SPDFRenderedPage*)page renderFlags:(unsigned)renderFlags;
- (BOOL)renderedPageMatchesReadingTheme:(SPDFRenderedPage*)page;
- (void)buildReadingThemeToolbarButton;
- (NSString*)readingThemeToggleTitle;
- (void)updateReadingThemeControls;
- (void)applyReadingThemeToEveryTab;
- (void)applyReadingThemeToDocumentViewport;
- (void)toggleReadingTheme:(nullable id)sender;
- (void)toggleDefaultImageColors:(nullable id)sender;
- (void)toggleDarkThemePreservesImages:(nullable id)sender;
- (void)addReadingThemeOverflowItemsToMenu:(NSMenu*)menu hiddenViews:(NSSet<NSView*>*)hiddenViews;
@end

// Rotate on a Markdown document, implemented in SPDFMacMarkdownOrientation.mm.
// A PDF page rotation turns rendered pixels; a Markdown document has no pixels
// of its own, so the same command turns the PAPER between A4 portrait and A4
// landscape and the text RE-FLOWS onto it, still upright. Per tab, persisted in
// the session's "markdownLandscape" key.
@interface ShenzhenMacDelegate (SPDFMacMarkdownOrientation)
// Shared enablement for Rotate Clockwise / Rotate Anticlockwise: a rotatable
// PDF page (unchanged) or a loaded Markdown document.
- (BOOL)canRotateActivePage;
// Turns the active Markdown document's paper. Both directions swap the same two
// paper edges, so the sign only picks the wording. NO when no Markdown document
// is up, which is what keeps -rotateCurrentPageByDegrees: beeping for every
// other kind of non-PDF document.
- (BOOL)rotateMarkdownPaperByDegrees:(int)degrees;
@end

// Implemented in ShenzhenPDFMac.mm. A category of their own on purpose:
// declaring them in (SPDFMacMarkdownIntegration) makes the compiler expect
// SPDFMacMarkdownIntegration.mm to define them too.
@interface ShenzhenMacDelegate (SPDFMacMarkdownFocusHost)
// The tab-activation focus chokepoint. Safe to re-run: it only claims focus
// from a passive holder.
- (void)focusActiveDocumentViewAfterTabSelection;
// The view typing should reach: the Markdown canvas when one is up.
- (NSView*)activeDocumentKeyView;
@end

@interface ShenzhenMacDelegate (SPDFMacMarkdownIntegration)
- (void)installMarkdownHostInDocumentContainer;
- (SPDFMacMarkdownSession*)activeMarkdownSession;
- (BOOL)isMarkdownActive;
// Whole-document translation for Markdown; see SPDFMacMarkdownTranslate.h.
- (BOOL)beginWholeDocumentTranslationForMarkdown;
- (BOOL)hasActiveDocument;
- (void)deactivateActiveMarkdownView;
- (void)ensureActiveMarkdownTabHasContent;
- (void)loadSelectedMarkdownTab:(SPDFDocumentTab*)tab;
- (void)rememberActiveMarkdownStateForTab:(SPDFDocumentTab*)tab;
- (NSString*)markdownSelectedText;
- (void)printActiveMarkdown;
- (void)saveActiveMarkdownAsPDF;
- (void)updateControlsForActiveMarkdown;
// The document-just-loaded focus rule, which yields only to a live text edit.
- (void)focusMarkdownViewAfterLoad;
- (void)updateMarkdownFontControls;
- (void)decreaseMarkdownFontSize:(nullable id)sender;
- (void)increaseMarkdownFontSize:(nullable id)sender;
- (BOOL)markdownHasChapters;
- (BOOL)markdownHasSearchSidebar;
- (void)rebuildMarkdownSidebar;
- (void)activateMarkdownSidebarItem:(NSDictionary*)item;
@end

@interface ShenzhenMacDelegate (SPDFMacMarkdownFindIntegration)
- (void)configureMarkdownFindHandlersForSession:(SPDFMacMarkdownSession*)session tab:(SPDFDocumentTab*)tab;
// Markdown branch of startFindForCurrentQueryResetSavedIndex:revealMatch:.
- (void)startMarkdownFindForCurrentQueryResetSavedIndex:(BOOL)resetSavedIndex revealMatch:(BOOL)revealMatch;
- (void)startMarkdownFindForQuery:(NSString*)query preferredIndex:(NSInteger)preferredIndex reveal:(BOOL)reveal;
- (void)moveMarkdownFindForward:(BOOL)forward;
- (void)clearMarkdownFindResults;
@end

@interface ShenzhenMacDelegate (SPDFMacMarkdownInteractionIntegration)
- (void)updateMarkdownMinimap;
- (nullable NSDictionary*)currentMarkdownChapterItem;
- (BOOL)markdownArrowKeyDown:(NSEvent*)event;
- (BOOL)markdownZoomWithScrollWheelEvent:(NSEvent*)event centeredAtWindowPoint:(NSPoint)windowPoint;
- (void)markdownZoomWithMagnifyDelta:(CGFloat)delta centeredAtWindowPoint:(NSPoint)windowPoint;
- (void)markdownDocumentScrollPositionChanged;
- (void)markdownMinimapViewportTopFraction:(CGFloat)yFraction documentCenterX:(CGFloat)documentCenterX;
- (void)markdownMinimapViewportTopDocumentY:(CGFloat)documentTopY documentCenterX:(CGFloat)documentCenterX;
- (void)markdownMinimapCenterAtDocumentPoint:(NSPoint)documentPoint;
- (void)markdownMinimapCenterOnPage:(NSInteger)pageIndex
                    xFractionInPage:(CGFloat)xFraction
                    yFractionInPage:(CGFloat)yFraction;
- (void)markdownMinimapReceiveScrollWheel:(NSEvent*)event;
- (void)markdownMinimapReceiveZoomScrollWheel:(NSEvent*)event documentPoint:(NSPoint)documentPoint;
- (void)markdownMinimapReceiveMagnifyDelta:(CGFloat)delta documentPoint:(NSPoint)documentPoint;
- (void)markdownPreviousPage;
- (void)markdownNextPage;
- (void)markdownFirstPage;
- (void)markdownLastPage;
- (void)markdownGoToPage:(NSInteger)pageIndex;
- (void)markdownZoomByFactor:(CGFloat)factor;
- (void)markdownApplyFitMode:(SPDFFitMode)fitMode;
- (void)relayoutActiveMarkdownForViewportChange;
@end

@interface ShenzhenMacDelegate (SPDFMacMarkdownFileActions)
- (void)openInExternalReader:(nullable id)sender;
- (void)showPathInFolder:(NSString*)path;
- (void)showInFolder:(nullable id)sender;
- (void)copyCurrentDocumentPath:(nullable id)sender;
- (void)copyCurrentDocumentFile:(nullable id)sender;
- (void)openMarkdownInEditor:(nullable id)sender;
- (void)copyCurrentPageImage:(nullable id)sender;
- (void)copyCurrentPageAsPDF:(nullable id)sender;
// Shared enablement for the copy-page actions: PDF tabs need a saved path,
// permission, and a rendered page; Markdown tabs need the session's live
// pagination plan with a valid target page.
- (BOOL)canCopyCurrentPageAsPDF;
- (BOOL)canCopyPageAsPDFAtIndex:(NSInteger)pageIndex;
- (BOOL)canCopyCurrentPageImage;
@end

NS_ASSUME_NONNULL_END
