#import "SPDFMacAIIntegration.h"
#import "SPDFMacReadOnlyCopy.h"
#import "SPDFMacMenuText.h"
#import "SPDFMacClipboardIntegration.h"
#import "SPDFMacQuitFinishing.h"
#import "SPDFMacStatePrefetch.h"
#import "SPDFMacWritableCopy.h"
#import "SPDFMacShortcutHelpStyle.h"
#import "SPDFMacFindContext.h"
#import "SPDFMacFindExecution.h"
#import "SPDFMacDocumentToolInputIntegration.h"
#import "SPDFMacImageSaveIntegration.h"
#import "SPDFMacPalettePresentation.h"
#import "SPDFMacWorkspaceChrome.h"
#import "SPDFMacFindInteraction.h"
#import "SPDFMacFindFailure.h"
#import "SPDFMacWorkspacePanels.h"
#import "SPDFMacCollectionCompanion.h"
#import "SPDFMacSidebarWorkspace.h"
#import <Cocoa/Cocoa.h>
#import <PDFKit/PDFKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#import <os/log.h>
#include <CommonCrypto/CommonDigest.h>
#include <sys/stat.h>

#import "SPDFMacDefaultReader.h"
#import "SPDFMacDelegatePrivate.h"
#import "SPDFMacCollectionReaderNavigation.h"
#import "SPDFMacDocumentView.h"
#import "SPDFMacFileBrowsing.h"
#import "SPDFMacDocumentOpening.h"
#import "SPDFMacFileExplorerPreference.h"
#import "SPDFMacFindNearest.h"
#import "SPDFMacInactivePreload.h"
#import "SPDFMacLaunchPrerenderPrivate.h"
#import "SPDFMacLaunchWorkIntegration.h"
#import "SPDFMacZoomSelfTestIntegration.h"
#import "SPDFMacModels.h"
#import "SPDFMacOCRCommand.h"
#import "SPDFMacOCRInstall.h"
#import "SPDFMacOCRValidation.h"
#import "SPDFMacReadingTheme.h"
#import "SPDFMacTabDetach.h"
#import "SPDFMacTabGroupIntegration.h"
#import "SPDFMacAgentCommand.h"
#import "SPDFMacAgentIntegration.h"
#import "SPDFMacCollectionPalette.h"
#import "SPDFMacCollectionPathPolicy.h"
#import "SPDFMacPreviousTabIntegration.h"
#import "SPDFMacMarkdownEditor.h"
#import "SPDFMacTranslationInstall.h"
#import "SPDFMacToolEnvironment.h"
#import "SPDFMacMinimapView.h"
#import "SPDFMacMinimapWindow.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacTranslationEnablement.h"
#import "SPDFMacTranslationChoice.h"
#import "SPDFMacTranslatedPDF.h"
#import "SPDFMacMarkdownRouting.h"
#import "SPDFMacPaletteResults.h"
#import "SPDFMacPaletteActivation.h"
#import "SPDFMacPaletteDocumentNames.h"
#import "SPDFMacStateDirectory.h"
#import "SPDFMacPassword.h"
#import "SPDFMacPrintView.h"
#import "SPDFMacPropertiesPanel.h"
#import "SPDFMacSelectionAdapter.h"
#import "SPDFMacSidebarChapters.h"
#import "SPDFMacSidebarPresentation.h"
#import "SPDFMacReaderNavigationMenu.h"
#import "SPDFMacSupport.h"
#import "SPDFMacTabViewState.h"
#import "SPDFMacWindowPlacement.h"
#import "SPDFMacTabLifecycle.h"
#import "SPDFMacTabStripView.h"
#import "SPDFMacUIHelpers.h"
#import "SPDFMacViewportRenderPriority.h"
#import "SPDFUpdater.h"

#include "shenzhen_pdf_core.h"
#include "spdf_yaml.h"

#include <math.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/mount.h>
#include <dirent.h>
#include <unistd.h>

static const CGFloat kPageMargin = 44.0;
static const CGFloat kPageGap = 26.0;
// Non-static: shared with the launch prerender worker (SPDFMacLaunchPrerender.mm),
// declared in SPDFMacLaunchPrerenderPrivate.h.
const CGFloat kMinZoom = 0.10;
const CGFloat kMaxZoom = 16.00;
static const CGFloat kTabStripHeight = 44.0;
static const CGFloat kMinWindowWidth = 560.0;
static const CGFloat kMinWindowHeight = 380.0;
static const CGFloat kDefaultMinimapWidth = 126.5;
static const CGFloat kDefaultSidebarWidth = 240.0;
static const CGFloat kMinSidebarWidth = 208.0;
static const CGFloat kSearchSidebarMinWidth = 216.0;
static const CGFloat kMaxSidebarWidth = 320.0;
static const CGFloat kSidebarMaxWidthFraction = 0.34;
static const CGFloat kMinimapDividerWidth = 5.0;
static const CGFloat kSidebarDividerWidth = SPDFPaneDividerHitWidth;
static const CGFloat kTopChromeResizeCornerSize = 16.0;
// Comment rows carry the full annotation text, so they wrap to a few lines.
// Size the row to the wrapped text plus a little vertical breathing room above
// and below (mirroring the comfortable spacing chapter rows get for free).
static const NSInteger kSidebarCommentMaxLines = 3;
static const CGFloat kSidebarCommentVerticalPadding = 5.0;
static const NSInteger kBackgroundRenderBatchSize = 8;
static const NSInteger kRecentDocumentLimit = 25;  // menu depth, and what Cmd+K can find
static const NSInteger kRenderedImageKeepRadius = 12;
static const NSUInteger kRenderedImageKeepAllTotalByteLimit = (NSUInteger)512 * 1024 * 1024;
static const NSUInteger kRenderedImageKeepAllPerPageByteLimit = (NSUInteger)(2.5 * 1024 * 1024);
static const CGFloat kMaxRenderedPageBitmapDimension = 32760.0;
// Cap full-page bitmaps to a size that renders in a few hundred ms and cannot
// starve the main thread of memory bandwidth; beyond this the viewport
// crop/pan-crop path keeps the visible region crisp instead.
static const NSUInteger kMaxRenderedPageBitmapByteLimit = (NSUInteger)96 * 1024 * 1024;
static const NSUInteger kRenderedImageSoftByteLimit = (NSUInteger)192 * 1024 * 1024;
static const NSUInteger kRenderedImageTargetByteLimit = (NSUInteger)128 * 1024 * 1024;
static const CGFloat kBaseZoomCacheZoom = 1.0;
static const CGFloat kBaseZoomCacheDisplayScale = 1.0;
static const NSUInteger kBaseZoomCacheMaxPageBytes = (NSUInteger)24 * 1024 * 1024;
static const NSUInteger kBaseZoomCacheTotalByteLimit = (NSUInteger)512 * 1024 * 1024;
static const CGFloat kHighQualityZoomCacheZoom = 2.0;
static const NSUInteger kHighQualityZoomCacheMaxPageBytes = (NSUInteger)96 * 1024 * 1024;
static const NSUInteger kHighQualityZoomCacheTotalByteLimit = (NSUInteger)384 * 1024 * 1024;
static const NSTimeInterval kAfterFirstPaintDelay = 0.05;
static const NSTimeInterval kLaunchVisibleStartDelay = 0.05;
static const NSTimeInterval kLaunchInactiveIdleDelay = 0.35;
static const NSTimeInterval kLaunchWarmStageDelay = 0.10;
static const NSTimeInterval kDocumentPanLiveCropRenderInterval = 0.05;
static const NSTimeInterval kLiveZoomFinishDelay = 0.28;
static const NSTimeInterval kLiveZoomFinishWhilePanningDelay = 0.12;
static const NSTimeInterval kLiveZoomStateSaveDelay = 0.20;
static const NSTimeInterval kLiveZoomMinimapUpdateInterval = 1.0 / 60.0;
static const NSTimeInterval kPostLiveZoomCrispRenderDelay = 0.02;
static const NSTimeInterval kPostLiveZoomBackgroundRenderDelay = 0.18;
static const NSInteger kPageGeometryCacheVersion = 1;
static const NSTimeInterval kPageGeometryModificationTolerance = 0.001;

#ifndef SPDF_MAC_TRANSLATION_CORE_READY
#define SPDF_MAC_TRANSLATION_CORE_READY 0
#endif

typedef struct SPDFPageAnchor {
    NSInteger pageIndex;
    NSPoint pagePoint;
    NSPoint offsetInViewport;
    BOOL valid;
} SPDFPageAnchor;

static CGFloat spdf_clamp_cg(CGFloat value, CGFloat minValue, CGFloat maxValue) {
    return MAX(minValue, MIN(maxValue, value));
}

// Profiling-only (SPDF_ZOOM_PROFILE): logs "<name> <elapsed>ms" when a scope
// exceeds thresholdMs. Zero work when profiling is disabled.
struct SPDFScopedProfileLog {
    const char* name;
    double threshold;
    double start;
    SPDFScopedProfileLog(const char* n, double thresholdMs)
        : name(n), threshold(thresholdMs), start(spdf_zoom_profile_enabled() ? spdf_zoom_profile_now_ms() : 0.0) {}
    ~SPDFScopedProfileLog() {
        if (start <= 0.0) return;
        double elapsed = spdf_zoom_profile_now_ms() - start;
        if (elapsed > threshold) spdf_zoom_profile_log(@"%s %.1fms", name, elapsed);
    }
};

// Profiling-only (SPDF_LAUNCH_PROFILE): logs "<name> <elapsed>ms" when the
// scope exits. Zero work when launch profiling is disabled.
struct SPDFScopedLaunchPhaseLog {
    const char* name;
    double start;
    explicit SPDFScopedLaunchPhaseLog(const char* n)
        : name(n), start(spdf_launch_profile_enabled() ? spdf_zoom_profile_now_ms() : 0.0) {}
    ~SPDFScopedLaunchPhaseLog() {
        if (start <= 0.0) return;
        spdf_launch_profile_log(@"%s %.1fms", name, spdf_zoom_profile_now_ms() - start);
    }
};

static CGFloat spdf_smoothstep_cg(CGFloat value) {
    value = spdf_clamp_cg(value, 0.0, 1.0);
    return value * value * value * (value * (value * 6.0 - 15.0) + 10.0);
}

static CGFloat spdf_max_sidebar_width_for_container(CGFloat containerWidth) {
    if (containerWidth <= 0) return kMaxSidebarWidth;
    return MAX(kMinSidebarWidth, MIN(kMaxSidebarWidth, floor(containerWidth * kSidebarMaxWidthFraction)));
}

static CGFloat spdf_sane_sidebar_width(CGFloat width, CGFloat containerWidth) {
    if (!isfinite(width) || width < kMinSidebarWidth || width > kMaxSidebarWidth) return kDefaultSidebarWidth;
    return spdf_clamp_cg(width, kMinSidebarWidth, spdf_max_sidebar_width_for_container(containerWidth));
}

static NSSize spdf_sane_window_content_size(NSSize size, NSScreen* screen) {
    if (!isfinite(size.width) || !isfinite(size.height) || size.width <= 0 || size.height <= 0) return NSZeroSize;
    NSRect visibleFrame = screen ? screen.visibleFrame : NSScreen.mainScreen.visibleFrame;
    CGFloat maxWidth = MAX(kMinWindowWidth, MIN(2200.0, NSWidth(visibleFrame) - 40.0));
    CGFloat maxHeight = MAX(kMinWindowHeight, MIN(1600.0, NSHeight(visibleFrame) - 40.0));
    return NSMakeSize(spdf_clamp_cg(size.width, kMinWindowWidth, maxWidth),
                      spdf_clamp_cg(size.height, kMinWindowHeight, maxHeight));
}

static NSString* spdf_menu_symbol_name_for_item(NSMenuItem* item) {
    if (!item || [item isSeparatorItem]) return nil;

    SEL action = item.action;
    NSString* title = item.title ?: @"";
    if (action == @selector(showAboutPanel:)) return @"info.circle";
    if (action == @selector(terminate:)) return @"power";
    if (action == @selector(openDocument:)) return @"folder";
    if (action == @selector(reopenLastClosedDocument:)) return @"arrow.uturn.backward";
    if (action == @selector(openRecentDocument:)) return @"clock";
    if (action == @selector(openInExternalReader:)) return @"arrow.up.forward.app";
    if (action == @selector(makeDefaultPDFReader:)) return @"checkmark.seal";
    if (action == @selector(showInFolder:)) return @"folder";
    if (action == @selector(copyCurrentDocumentPath:)) return @"doc.text";
    if (action == @selector(copyCurrentDocumentFile:)) return @"doc.on.clipboard";
    if (action == @selector(copyCurrentPageAsPDF:)) return @"doc.on.clipboard.fill";
    if (action == @selector(searchSelectedTextInBrowser:)) return @"safari";
    if (action == @selector(saveDocumentAs:)) return @"square.and.arrow.down";
    if (action == @selector(closeDocument:)) return @"xmark.circle";
    if (action == @selector(printDocument:)) return @"printer";
    if (action == @selector(ocrDocument:)) return @"text.viewfinder";
    if (action == @selector(deleteAllTextFromDocument:)) return @"text.badge.minus";
    if (action == @selector(translateDocument:) || action == @selector(showSelectionTranslationPanel:))
        return @"translate";
    if (action == @selector(showProperties:)) return @"info.circle";
    if (action == @selector(firstPage:)) return @"arrow.left.to.line";
    if (action == @selector(previousPage:)) return @"chevron.left";
    if (action == @selector(nextPage:)) return @"chevron.right";
    if (action == @selector(lastPage:)) return @"arrow.right.to.line";
    if (action == @selector(focusPageField:)) return @"number";
    if (action == @selector(zoomIn:)) return @"plus.magnifyingglass";
    if (action == @selector(zoomOut:)) return @"minus.magnifyingglass";
    if (action == @selector(actualSize:)) return @"magnifyingglass";
    if (action == @selector(fitPage:) || action == @selector(fitWidth:) || action == @selector(fitHeight:))
        return @"arrow.up.left.and.arrow.down.right";
    if (action == @selector(toggleSidebar:)) return @"sidebar.left";
    if (action == @selector(toggleMinimap:)) return @"map";
    if (action == @selector(togglePresentation:)) return @"play.rectangle";
    if (action == @selector(togglePreventSleepInPresentation:)) return @"bolt.fill";
    if (action == @selector(toggleFullScreen:)) return @"arrow.up.left.and.arrow.down.right";
    if (action == @selector(rotateClockwise:)) return @"rotate.right";
    if (action == @selector(rotateAnticlockwise:)) return @"rotate.left";
    if (action == @selector(performMiniaturize:)) return @"minus.rectangle";
    if (action == @selector(performZoom:)) return @"plus.rectangle";
    if (action == @selector(arrangeInFront:)) return @"rectangle.on.rectangle";
    if (action == @selector(cut:)) return @"scissors";
    if (action == @selector(copy:) || action == @selector(copySelection:)) return @"doc.on.doc";
    if (action == @selector(paste:)) return @"clipboard";
    if (action == @selector(selectAll:)) return @"selection.pin.in.out";
    if (action == @selector(focusFind:) || action == @selector(findNext:) || action == @selector(findPrevious:))
        return @"magnifyingglass";
    if (action == @selector(toggleFindRegex:) || action == @selector(toggleFindRegexMultiline:)) return @"textformat";
    if (action == @selector(toggleCollapseWhitespaceWhenCopyingText:)) return @"text.alignleft";
    if (action == @selector(setCommentAuthor:)) return @"person.crop.circle";
    if (action == @selector(showFavoritesPalette:) || action == @selector(favoriteCurrentPage:) ||
        action == @selector(favoriteCurrentDocument:))
        return @"star";
    if (action == @selector(toggleDefaultSidebarForNewDocuments:)) return @"sidebar.left";
    if (action == @selector(toggleDefaultMinimapForNewDocuments:)) return @"map";
    if (action == @selector(toggleReadingTheme:)) return @"moon.stars";
    if (action == @selector(toggleDarkThemePreservesImages:)) return @"photo";
    if (action == @selector(toggleSearchJumpsToNearestResult:)) return @"scope";
    if (action == @selector(openStateFile:)) return @"curlybraces";
    if (action == @selector(revealSettingsFolder:)) return @"folder";
    if (action == @selector(showShortcutHelp:)) return @"keyboard";
    if (action == @selector(addComment:)) return @"text.bubble";
    if (action == @selector(editComment:)) return @"square.and.pencil";
    if (action == @selector(deleteComment:)) return @"trash";
    if (action == @selector(copyCurrentPageImage:)) return @"photo.on.rectangle";
    if (action == @selector(fillWindow:) || action == @selector(centerWindowInScreen:) ||
        action == @selector(moveWindowToLeftHalf:) || action == @selector(moveWindowToRightHalf:) ||
        action == @selector(moveWindowToTopHalf:) || action == @selector(moveWindowToBottomHalf:))
        return @"rectangle.arrowtriangle.2.inward";

    if ([title isEqualToString:@"File"]) return @"doc";
    if ([title isEqualToString:@"Go To"]) return @"arrow.right.circle";
    if ([title isEqualToString:@"Zoom"]) return @"magnifyingglass";
    if ([title isEqualToString:@"View"]) return @"eye";
    if ([title isEqualToString:@"Window"]) return @"rectangle.on.rectangle";
    if ([title isEqualToString:@"Edit"]) return @"pencil";
    if ([title isEqualToString:@"Favorites"]) return @"star";
    if ([title isEqualToString:@"Settings"]) return @"gearshape";
    if ([title isEqualToString:@"Help"]) return @"questionmark.circle";
    if ([title isEqualToString:@"Recently Opened"]) return @"clock";
    if ([title isEqualToString:@"File Manager"]) return @"folder.badge.gearshape";
    if ([title isEqualToString:@"Finder"] || [title isEqualToString:@"Shenzhen Files"]) return @"folder";
    if ([title isEqualToString:@"Move & Resize Window"]) return @"rectangle.arrowtriangle.2.inward";
    return nil;
}

static NSString* SPDFAppleScriptStringLiteral(NSString* text) {
    NSMutableString* escaped = [SPDFTextByCollapsingWhitespace(text) mutableCopy];
    if (!escaped) escaped = [NSMutableString string];
    [escaped replaceOccurrencesOfString:@"\\" withString:@"\\\\" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"\"" withString:@"\\\"" options:0 range:NSMakeRange(0, escaped.length)];
    return [NSString stringWithFormat:@"\"%@\"", escaped];
}

static BOOL SPDFPerformSystemTextSearchService(NSString* query) {
    NSString* normalized = SPDFTextByCollapsingWhitespace(query);
    if (normalized.length == 0) return NO;

    NSPasteboard* pasteboard = [NSPasteboard pasteboardWithUniqueName];
    [pasteboard clearContents];
    [pasteboard setString:normalized forType:NSPasteboardTypeString];
    if (NSPerformService(@"Search With Google", pasteboard)) return YES;
    if (NSPerformService(@"Search with Google", pasteboard)) return YES;
    return NO;
}

static BOOL SPDFSearchWithSafariDefaultEngine(NSString* query, NSString** errorOut) {
    if (errorOut) *errorOut = nil;
    NSString* normalized = SPDFTextByCollapsingWhitespace(query);
    if (normalized.length == 0) return NO;

    NSURL* httpsURL = [NSURL URLWithString:@"https://example.com/"];
    NSURL* browserURL = httpsURL ? [NSWorkspace.sharedWorkspace URLForApplicationToOpenURL:httpsURL] : nil;
    NSString* handler = browserURL ? [NSBundle bundleWithURL:browserURL].bundleIdentifier : nil;
    if (![handler isEqualToString:@"com.apple.Safari"]) {
        if (errorOut)
            *errorOut = @"macOS did not expose a system text-search service for the selected text. "
                        @"Set Safari as the default browser or use the browser search field directly.";
        return NO;
    }

    NSString* source = [NSString stringWithFormat:@"tell application id \"com.apple.Safari\"\n"
                                                  @"activate\n"
                                                  @"search the web for %@\n"
                                                  @"end tell",
                                                  SPDFAppleScriptStringLiteral(normalized)];
    NSAppleScript* script = [[NSAppleScript alloc] initWithSource:source];
    NSDictionary* errorInfo = nil;
    [script executeAndReturnError:&errorInfo];
    if (errorInfo) {
        if (errorOut) *errorOut = errorInfo[NSAppleScriptErrorMessage] ?: @"Safari could not search the selected text.";
        return NO;
    }
    return YES;
}

void spdf_apply_system_icons_to_menu(NSMenu* menu) {
    for (NSMenuItem* item in menu.itemArray) {
        spdf_set_menu_item_system_symbol(item, spdf_menu_symbol_name_for_item(item));
        if (item.submenu) spdf_apply_system_icons_to_menu(item.submenu);
    }
}

static void spdf_apply_system_icons_to_main_menu_contents(NSMenu* mainMenu) {
    for (NSMenuItem* item in mainMenu.itemArray) {
        if (item.submenu) spdf_apply_system_icons_to_menu(item.submenu);
    }
}

/* A canceled render reports 0 with this exact core message; it is a
 * cancellation, not a failure, and must never reach error UI. */
static BOOL spdf_render_was_canceled(const char* err) {
    return err && strcmp(err, "Render canceled.") == 0;
}

/* NSBlockOperation whose -cancel also aborts an in-flight mupdf render via an
 * spdf_render_token (fz_cookie). Queue-level cancelAllOperations reaches the
 * override too, so a gesture-start queue purge aborts running renders within
 * milliseconds instead of letting up to ~230ms of mupdf work run to completion.
 *
 * Lifetime: the token is created before the execution block can run and freed
 * in -dealloc; NSOperation guarantees execution blocks have finished before the
 * operation can be released by its queue, so the render never outlives the
 * token. The execution block references the operation WEAKLY (a __strong
 * capture would be a retain cycle: operation retains block retains operation).
 * While the block runs, the queue holds a strong reference, so the weak load
 * only returns nil if the block somehow ran without a queue.
 * -cancel may race the render start; cookie.abort is a plain int flag mupdf
 * polls between display-list nodes / content tokens, so a flag set before
 * fz_run begins simply makes the run abort at its first poll. */
@interface SPDFRenderOperation : NSBlockOperation
@property(atomic, readonly) spdf_render_token* renderToken; /* created in init, freed in dealloc */
+ (instancetype)operationWithRenderBlock:(void (^)(spdf_render_token* token))block;
@end

@implementation SPDFRenderOperation {
    spdf_render_token* _renderToken;
}

@synthesize renderToken = _renderToken;

+ (instancetype)operationWithRenderBlock:(void (^)(spdf_render_token* token))block {
    SPDFRenderOperation* operation = [[self alloc] init];
    operation->_renderToken = spdf_render_token_new();
    __weak SPDFRenderOperation* weakOperation = operation;
    [operation addExecutionBlock:^{
      SPDFRenderOperation* strongOperation = weakOperation;
      if (!strongOperation) return;
      block(strongOperation.renderToken);
    }];
    return operation;
}

- (void)cancel {
    [super cancel];
    spdf_render_token_cancel(self.renderToken);
}

- (void)dealloc {
    spdf_render_token_free(_renderToken);
}

@end

@class ShenzhenMacDelegate;

static NSMutableArray<ShenzhenMacDelegate*>* gSPDFWindowControllers;
static BOOL gSPDFTerminatingAllWindows;

NSArray<ShenzhenMacDelegate*>* SPDFMacZoomSelfTestWindowControllers(void) {
    return gSPDFWindowControllers ?: @[];
}
NSArray<ShenzhenMacDelegate*>* SPDFMacAllWindowControllers(void) { return gSPDFWindowControllers ?: @[]; }

static NSDictionary* spdf_dictionary_from_window_frame(NSRect frame) {
    return @{
        @"x" : @(NSMinX(frame)),
        @"y" : @(NSMinY(frame)),
        @"width" : @(NSWidth(frame)),
        @"height" : @(NSHeight(frame))
    };
}

static BOOL spdf_window_frame_from_dictionary(NSDictionary* item, NSRect* frame) {
    if (![item isKindOfClass:NSDictionary.class]) return NO;
    CGFloat width = [item[@"width"] doubleValue];
    CGFloat height = [item[@"height"] doubleValue];
    if (width < kMinWindowWidth || height < kMinWindowHeight) return NO;
    if (frame) *frame = NSMakeRect([item[@"x"] doubleValue], [item[@"y"] doubleValue], width, height);
    return YES;
}

static NSRect spdf_sane_window_frame(NSRect frame, NSScreen* fallbackScreen) {
    NSScreen* bestScreen = nil;
    CGFloat bestArea = 0;
    for (NSScreen* screen in NSScreen.screens) {
        NSRect intersection = NSIntersectionRect(frame, screen.visibleFrame);
        CGFloat area = NSWidth(intersection) * NSHeight(intersection);
        if (area > bestArea) {
            bestArea = area;
            bestScreen = screen;
        }
    }
    NSScreen* screen = bestScreen ?: fallbackScreen ?: NSScreen.mainScreen;
    NSRect visible = screen.visibleFrame;
    frame.size.width = MAX(kMinWindowWidth, MIN(NSWidth(frame), NSWidth(visible)));
    frame.size.height = MAX(kMinWindowHeight, MIN(NSHeight(frame), NSHeight(visible)));
    if (bestArea < 80.0 * 80.0) {
        frame.origin.x = floor(NSMidX(visible) - NSWidth(frame) / 2.0);
        frame.origin.y = floor(NSMidY(visible) - NSHeight(frame) / 2.0);
    } else {
        frame.origin.x = MIN(MAX(NSMinX(frame), NSMinX(visible)), NSMaxX(visible) - NSWidth(frame));
        frame.origin.y = MIN(MAX(NSMinY(frame), NSMinY(visible)), NSMaxY(visible) - NSHeight(frame));
    }
    return frame;
}

static NSString* spdf_json_string_from_object(id object) {
    NSData* data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

static NSDictionary* spdf_json_dictionary_from_string(NSString* string) {
    NSData* data = [string dataUsingEncoding:NSUTF8StringEncoding];
    id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

unsigned long long spdf_file_size_from_attributes(NSDictionary* attributes) {
    return [attributes[NSFileSize] unsignedLongLongValue];
}

NSDate* spdf_file_modification_date_from_attributes(NSDictionary* attributes) {
    NSDate* date = attributes[NSFileModificationDate];
    return [date isKindOfClass:NSDate.class] ? date : nil;
}

// Bare lstat() of a path: SILENT (no macOS "access data from other apps"
// prompt), unlike -[NSFileManager isWritableFileAtPath:] (an access(W_OK)
// write-intent check) or -[NSFileManager attributesOfItemAtPath:]. Used for
// read-only DETECTION and change-detection on a read-only SOURCE so the app
// never prompts to touch the source. Returns NO (and leaves *stOut untouched)
// for a missing path or a non-regular file (symlink target not followed; a
// directory/special file is treated as "no stat" so callers fall through to
// their existing not-a-document handling).
static BOOL spdf_bare_lstat(NSString* path, struct stat* stOut) {
    if (!path.length || !stOut) return NO;
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) != 0) return NO;
    if (!S_ISREG(st.st_mode)) return NO;
    *stOut = st;
    return YES;
}

// Build an (NSFileSize, NSFileModificationDate) dictionary from a bare lstat,
// matching the shape -fileAttributesForPath: returns so the existing
// cache-coherency / copy-reuse comparisons work unchanged — but WITHOUT the
// prompting -[NSFileManager attributesOfItemAtPath:] call. Returns nil when the
// path cannot be stat'd as a regular file.
static NSDictionary* spdf_bare_lstat_attributes(NSString* path) {
    struct stat st;
    if (!spdf_bare_lstat(path, &st)) return nil;
    NSTimeInterval mtime = (NSTimeInterval)st.st_mtimespec.tv_sec + (NSTimeInterval)st.st_mtimespec.tv_nsec / 1e9;
    return @{
        NSFileSize : @((unsigned long long)st.st_size),
        NSFileModificationDate : [NSDate dateWithTimeIntervalSince1970:mtime]
    };
}

// Read-only determination from a bare lstat's mode/uid/gid vs the effective
// user/group: read-only iff no write bit that applies to this process is set.
// Pure metadata math on the lstat result — SILENT, no access(W_OK).
static BOOL spdf_stat_is_read_only(const struct stat* st) {
    if (!st) return NO;
    mode_t mode = st->st_mode;
    if (st->st_uid == geteuid()) return (mode & S_IWUSR) == 0;
    if (st->st_gid == getegid()) return (mode & S_IWGRP) == 0;
    return (mode & S_IWOTH) == 0;
}

static char kSPDFPasswordPromptClosesNewTabKey;

@interface ShenzhenMacDelegate ()
@property(nonatomic, strong) SPDFPasswordSheetController* passwordSheetController;
@property(nonatomic, copy) NSString* pendingPasswordPromptToken;
@property(nonatomic, strong) SPDFMacTabLifecycle* tabLifecycle;
@property(nonatomic, strong) SPDFMacLaunchWorkCoordinator* launchWorkCoordinator;
@property(nonatomic, strong) NSOperationQueue* inactiveTabPreloadQueue;
- (void)preloadInactiveTabsWithCompletion:(dispatch_block_t _Nullable)completion;
@end
@implementation ShenzhenMacDelegate

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    (void)notification;
    spdf_mac_launch_began(); // logs "applicationDidFinishLaunching enter"
    // Quit-for-update IPC: every process (primary and restored siblings) listens
    // for the driver's distributed request so it can exit WITHOUT re-cascading
    // terminate to all other processes (the N-squared storm). Non-sandboxed only.
    if (!spdf_is_sandboxed()) {
        [[NSDistributedNotificationCenter defaultCenter] addObserver:self
                                                            selector:@selector(handleQuitForUpdateNotification:)
                                                                name:@"com.intuition.shenzhenpdf.QuitForUpdate"
                                                              object:nil];
    }
    double launchPhaseStart = spdf_launch_profile_enabled() ? spdf_zoom_profile_now_ms() : 0.0;
    _zoom = 1.0;
    _rememberedCustomZoom = 1.0;
    _fitMode = SPDFFitModePage;
    _highlightPageIndex = -1;
    _selectionPageIndex = -1;
    _contextPageIndex = -1;
    _contextCommentIndex = -1;
    _defaultSidebarVisibleForNewDocuments = YES;
    _defaultMinimapVisibleForNewDocuments = YES;
    _sidebarPreferredVisible = YES;
    _sidebarVisible = YES;
    _minimapPreferredVisible = YES;
    _minimapVisible = YES;
    _presentationMode = NO;
    _presentationEnteredFullScreen = NO;
    _presentationUsingBorderlessWindow = NO;
    _pendingWindowArrangementAction = NULL;
    _translationRunning = NO;
    _translationInstallRunning = NO;
    _selectionTranslationGeneration = 0;
    _collapseWhitespaceWhenCopyingText = YES;
    _searchJumpsToNearestResult = YES;
    _showShortcutHelpOnLaunch = YES;
    _autoUpdateEnabled = YES;
    _skippedUpdateVersion = nil;
    _preventSleepInPresentation = YES;
    _defaultReaderPromptDismissed = NO;
    _fullDiskAccessPromptDismissed = NO;
    _permissionsWizardShown = NO;
    _terminateOnlyThisProcess = NO;
    _suppressSessionWriteOnTerminate = NO;
    _suspendPersistentStateSaves = NO;
    _needsDeferredPersistentStateSave = NO;
    _suppressViewportRerender = NO;
    _liveZooming = NO;
    _liveZoomQueuesPaused = NO;
    _liveZoomMinimapUpdateScheduled = NO;
    _visibleCropRenderSequence = 0;
    _restoringSidebarLayout = NO;
    _allowSidebarWidthPersistence = NO;
    _sidebarWidth = kDefaultSidebarWidth;
    _minimapWidth = kDefaultMinimapWidth;
    _printScalingMode = SPDFPrintScalingModeFit;
    _printCustomScale = 1.0;
    _markdownFontScale = 1.0;
    _findRegexMultiline = YES;
    _translationSourceLanguage = @"zh";
    _translationTargetLanguage = @"en";
    _chapterFilterText = @"";
    _commentFilterText = @"";
    _sidebarItems = [NSMutableArray array];
    _renderedPages = [NSMutableArray array];
    _tabs = [NSMutableArray array];
    self.tabLifecycle = [[SPDFMacTabLifecycle alloc] init];
    _favorites = [NSMutableArray array];
    _documentStates = [NSMutableDictionary dictionary];
    _recentlyOpenedPaths = [NSMutableArray array];
    _closedDocumentPaths = [NSMutableArray array];
    _securityBookmarks = [NSMutableDictionary dictionary];
    _activeSecurityScopedURLs = [NSMutableSet set];
    _paletteFavoritePendingDelete = nil;
    _findHighlights = [NSMutableDictionary dictionary];
    _findMatches = [NSMutableArray array];
    _preloadingPaths = [NSMutableSet set];
    _preloadTokens = [NSMutableDictionary dictionary];
    _preloadResults = [NSMutableDictionary dictionary];
    _findMatchIndex = -1;
    _paletteResults = [NSMutableArray array];
    _shortcutHelpRows = [NSMutableArray array];
    _pendingOpenPaths = [NSMutableArray array];
    _pendingRestoreWindowIDs = [NSMutableArray array];
    _queuedRenderPages = [NSMutableSet set];
    _queuedRenderOperations = [NSMutableDictionary dictionary];
    _queuedBaseRenderPages = [NSMutableSet set];
    _queuedBaseRenderOperations = [NSMutableDictionary dictionary];
    _queuedHighQualityRenderPages = [NSMutableSet set];
    _queuedHighQualityRenderOperations = [NSMutableDictionary dictionary];
    _queuedMinimapThumbnailPages = [NSMutableSet set];
    _queuedMinimapThumbnailOperations = [NSMapTable strongToWeakObjectsMapTable];
    _selectedTabIndex = -1;
    _windowSessionID = NSUUID.UUID.UUIDString;
    _pendingFindPreferredPage = -1;
    _pendingFindPreferredMatchIndex = -1;

    NSInteger cpuCount = MAX(2, NSProcessInfo.processInfo.activeProcessorCount);
    _renderQueue = [[NSOperationQueue alloc] init];
    _renderQueue.name = @"Shenzhen PDF page renderer";
    // More than a few concurrent page renders saturates memory bandwidth and
    // visibly stalls main-thread input even though the work is off-main.
    _renderQueue.maxConcurrentOperationCount = MAX(2, MIN((NSInteger)3, cpuCount - 1));
    // Profiling-only override (SPDF_RENDER_WORKERS): force the foreground render
    // concurrency to test the memory-bandwidth hypothesis. No-op when unset.
    if (const char* forcedWorkers = getenv("SPDF_RENDER_WORKERS")) {
        NSInteger forced = (NSInteger)strtol(forcedWorkers, NULL, 10);
        if (forced >= 1 && forced <= 16) {
            _renderQueue.maxConcurrentOperationCount = forced;
            spdf_zoom_profile_log(@"renderQueue maxConcurrent forced to %ld via SPDF_RENDER_WORKERS", (long)forced);
        }
    }
    _renderQueue.qualityOfService = NSQualityOfServiceUserInitiated;
    _zoomSeedRenderQueue = [[NSOperationQueue alloc] init];
    _zoomSeedRenderQueue.name = @"Shenzhen PDF zoom seed renderer";
    _zoomSeedRenderQueue.maxConcurrentOperationCount = 1;
    _zoomSeedRenderQueue.qualityOfService = NSQualityOfServiceUtility;
    _cacheRenderQueue = [[NSOperationQueue alloc] init];
    _cacheRenderQueue.name = @"Shenzhen PDF zoom cache warmer";
    _cacheRenderQueue.maxConcurrentOperationCount = 1;
    _cacheRenderQueue.qualityOfService = NSQualityOfServiceUtility;
    _backgroundRenderQueue = [[NSOperationQueue alloc] init];
    _backgroundRenderQueue.name = @"Shenzhen PDF background page renderer";
    _backgroundRenderQueue.maxConcurrentOperationCount = 1;
    _backgroundRenderQueue.qualityOfService = NSQualityOfServiceUtility;
    _minimapQueue = [[NSOperationQueue alloc] init];
    _minimapQueue.name = @"Shenzhen PDF minimap thumbnails";
    _minimapQueue.maxConcurrentOperationCount = MAX(1, MIN(2, (NSInteger)floor((double)cpuCount * 0.25)));
    _minimapQueue.qualityOfService = NSQualityOfServiceUtility;
    _preloadQueue = [[NSOperationQueue alloc] init];
    _preloadQueue.name = @"Shenzhen PDF tab preloader";
    _preloadQueue.maxConcurrentOperationCount = MAX(1, MIN(2, (NSInteger)floor((double)cpuCount * 0.60)));
    _preloadQueue.qualityOfService = NSQualityOfServiceUtility;
    self.inactiveTabPreloadQueue = [[NSOperationQueue alloc] init];
    _inactiveTabPreloadQueue.name = @"Shenzhen PDF inactive tab preloader";
    _inactiveTabPreloadQueue.maxConcurrentOperationCount = spdf_mac_launch_inactive_worker_limit();
    _inactiveTabPreloadQueue.qualityOfService = NSQualityOfServiceBackground;
    self.launchWorkCoordinator =
        [[SPDFMacLaunchWorkCoordinator alloc] initWithVisibleStartDelay:kLaunchVisibleStartDelay
                                                      inactiveIdleDelay:kLaunchInactiveIdleDelay
                                                             stageDelay:kLaunchWarmStageDelay];
    __weak __typeof(self) weakSelf = self;
    [_launchWorkCoordinator
        activateWithStageHandler:^(SPDFMacLaunchWarmStage stage, NSUInteger generation, id context) {
          [weakSelf runLaunchWarmStage:stage generation:generation context:context];
        }
        interruptionHandler:^{
          spdf_launch_profile_log(@"inactive-tab warm deferred by user input");
          [weakSelf cancelInactiveTabPreloads];
        }];
    _findQueue = [[NSOperationQueue alloc] init];
    _findQueue.name = @"Shenzhen PDF document find";
    _findQueue.maxConcurrentOperationCount = 1;
    _findQueue.qualityOfService = NSQualityOfServiceUserInitiated;
    _cursorRegionQueue = [[NSOperationQueue alloc] init];
    _cursorRegionQueue.name = @"Shenzhen PDF cursor regions";
    _cursorRegionQueue.maxConcurrentOperationCount = 1;
    _cursorRegionQueue.qualityOfService = NSQualityOfServiceUtility;
    _cursorRegionCache = [NSMutableDictionary dictionary];
    _cursorRegionPagesBuilding = [NSMutableSet set];
    if (launchPhaseStart > 0.0) {
        spdf_launch_profile_log(@"ivar+queue setup %.1fms", spdf_zoom_profile_now_ms() - launchPhaseStart);
    }

    {
        SPDFScopedLaunchPhaseLog launchPhase("loadPersistentState");
        [self loadPersistentState];
    }
    // Here, not after the first paint, so the launches overlap (WindowPlacement.h).
    [self spawnPendingRestoredWindowsIfNeeded];
    // Read-only shadow copy: the orphaned-temp-copy sweep is deferred to
    // -resumePersistentStateSavesAfterLaunch (after first paint, after tabs are
    // restored, after the catch-up save). Running it here against the stale
    // on-disk session.yaml races copy (re)creation on the main thread and could
    // delete an in-use / just-created copy. See -sweepOrphanedReadOnlyCopies.
    if (!gSPDFWindowControllers) gSPDFWindowControllers = [NSMutableArray array];
    if (![gSPDFWindowControllers containsObject:self]) [gSPDFWindowControllers addObject:self];

    // Suspend persistent-state saves across the whole launch sequence: window
    // construction fires windowDidResize (and sidebar restoration fires split
    // view delegate callbacks) which each trigger a full savePersistentState
    // cycle (session.lock flock + session.yaml read + serialize + compare)
    // before the first paint. Item 68 batched these into one save at the end
    // of the launch block, but that single flock/read/serialize cycle still
    // ran before the first paint; nothing about the saved state is needed for
    // the first frame, so the suspension now extends just past it and the
    // catch-up save (identical bytes — it serializes the same live state)
    // runs ~50ms after the first paint instead. Every termination path goes
    // through applicationWillTerminate, which lifts the suspension before its
    // own save, so no state can be lost to an early quit.
    _suspendPersistentStateSaves = YES;
    {
        SPDFScopedLaunchPhaseLog launchPhase("buildMenu");
        [self buildMenu];
    }
    {
        SPDFScopedLaunchPhaseLog launchPhase("buildWindow");
        [self buildWindow];
    }
    {
        SPDFScopedLaunchPhaseLog launchPhase("installWindowArrangementShortcutMonitor");
        [self installWindowArrangementShortcutMonitor];
    }
    self->_uiReady = YES;

    {
        SPDFScopedLaunchPhaseLog launchPhase("performStartupDocumentWork");
        [self performStartupDocumentWork];
    }
    self->_allowSidebarWidthPersistence = YES;
    {
        SPDFScopedLaunchPhaseLog launchPhase("restoreSidebarWidth+toolbarOverflow");
        [self restoreSidebarWidth];
        // buildWindow left overflow updates suppressed: the startup document
        // work above would otherwise solve the toolbar nine times before the
        // first frame, none of them displayed. One pass here replaces them.
        _suppressToolbarOverflowUpdates = NO;
        [self updateToolbarOverflow];
    }

    {
        SPDFScopedLaunchPhaseLog launchPhase("makeKeyAndOrderFront");
        [_window makeKeyAndOrderFront:nil];
    }
    if (self.restoreWindowID.length == 0 && !spdf_launch_activation_suppressed())
        [NSApp activateIgnoringOtherApps:YES];
    // Post-first-paint launch tail. The async hop reaches the next runloop
    // pass, displayIfNeeded forces the (already fully laid out) first frame
    // onto screen if it has not drawn yet, and only then does the timer for
    // the non-paint work start. Everything in the timer block was previously
    // queued with plain dispatch_async and could execute before the first
    // draw: the launch-end persistent-state save (flock + state serialize),
    // the default-reader LaunchServices query, and — on first run — the
    // whole shortcut-help panel construction.
    dispatch_async(dispatch_get_main_queue(), ^{
      [self->_pageScrollView displayIfNeeded];
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kAfterFirstPaintDelay * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), ^{
                       spdf_mac_first_paint_done(); // Collection's launch capture, after the first frame
                       [self resumePersistentStateSavesAfterLaunch];
                       [self showUnifiedSettingsAfterFirstPaint];
                       [self listenForDocumentsOpenedInOtherWindows];
                       if (self.restoreWindowID.length == 0) {
                           if (!self.detachedTabLaunch) {
                               // Consume the post-update health marker FIRST (writes
                               // update_ok / deletes .old / shows the success banner, or
                               // rolls back a failed new version), then arm the daily check.
                               [[SPDFUpdater shared] consumePendingUpdateMarkerAndSweep];
                               [[SPDFUpdater shared] scheduleDailyUpdateCheckIfNeeded];
                           }
                       }
                       // EVERY process (primary, restored sibling, detached tab)
                       // keeps the daily check alive while the app runs for days
                       // without a relaunch; the flock'd 24h gate still collapses
                       // all processes' triggers to at most one check per day.
                       [[SPDFUpdater shared] armRecurringUpdateCheck];
                     });
    });
    if (spdf_zoom_profile_enabled()) {
        // Main-thread stall detector: a background thread pings the main queue
        // and reports gaps; CPU cost is negligible.
        static dispatch_source_t stallTimer;
        static double lastBeat;
        lastBeat = spdf_zoom_profile_now_ms();
        stallTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                            dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));
        dispatch_source_set_timer(stallTimer, DISPATCH_TIME_NOW, (uint64_t)(4 * NSEC_PER_MSEC), NSEC_PER_MSEC);
        dispatch_source_set_event_handler(stallTimer, ^{
          double scheduled = spdf_zoom_profile_now_ms();
          dispatch_async(dispatch_get_main_queue(), ^{
            double now = spdf_zoom_profile_now_ms();
            double latency = now - scheduled;
            static double lastStallLog;
            if (latency > 30.0 && now - lastStallLog > 200.0) {
                lastStallLog = now;
                spdf_zoom_profile_log(@"MAIN-STALL %.0fms", latency);
            }
          });
        });
        dispatch_resume(stallTimer);
    }
    if (getenv("SPDF_ZOOM_SELFTEST")) {
        spdf_zoom_profile_log(@"SELFTEST scheduled");
        NSTimer* timer = [NSTimer timerWithTimeInterval:4.0
                                                 target:self
                                               selector:@selector(zoomSelfTestTimerFired:)
                                               userInfo:nil
                                                repeats:NO];
        [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    }
    spdf_launch_profile_log(@"applicationDidFinishLaunching exit");
}

- (void)performStartupDocumentWork {
    _startupDocumentWorkInProgress = YES;
    NSMutableArray<NSString*>* startupPaths = [NSMutableArray array];
    if (_pendingOpenPath.length > 0) [startupPaths addObject:_pendingOpenPath];
    for (NSString* path in _pendingOpenPaths) {
        if (path.length > 0 && ![startupPaths containsObject:path]) [startupPaths addObject:path];
    }
    if (self.initialPath.length > 0) [startupPaths addObject:self.initialPath];
    _pendingOpenPath = nil;
    [_pendingOpenPaths removeAllObjects];
    if (startupPaths.count > 0) {
        NSArray<NSString*>* pathsToOpen = [self openableDocumentPathsFromPaths:startupPaths showErrors:YES];
        [self openPaths:pathsToOpen];
    } else if (_tabs.count > 0) {
        [self selectTabAtIndex:MAX(0, _selectedTabIndex)];
    } else {
        [self showEmptyDocumentViewWithMessage:@"Open a document"];
    }
    // Restore backstop: whatever path ran above, the selected markdown tab
    // must end with content installed or work in flight (idempotent no-op
    // otherwise) — a cancel landing during restore must not strand it.
    [self ensureActiveMarkdownTabHasContent];
    _startupDocumentWorkInProgress = NO;
    // Sibling-window restore processes are spawned from the post-first-paint
    // block in applicationDidFinishLaunching: each spawn pages in another
    // copy of the binary, which on a cold launch competes with this window's
    // own pre-paint disk reads. Their windows are separate processes that
    // were never part of this window's first frame.
    // Whatever launch path ran above, the prerender had its one adoption
    // chance; release a leftover (e.g. empty session, missing file) off-main.
    spdf_discard_launch_prerender();
    [self releaseLaunchPrerenderedMetadata];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
    (void)sender;
    return YES;
}

// Every change is saved as it is made, so a quit asks nothing: hide, then write (SPDFMacQuitFinishing.mm).
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication*)sender {
    if (![self beginQuit]) return (void)sender, NSTerminateLater; // already finishing
    if (!_terminateOnlyThisProcess && !gSPDFTerminatingAllWindows) {
        gSPDFTerminatingAllWindows = YES;
        for (NSRunningApplication* app in [self otherRunningShenzhenApplications]) [app terminate];
    }
    return [self finishQuitAfterHiding];
}

- (void)applicationWillTerminate:(NSNotification*)notification {
    if ((void)notification, ![self quitClaimFinalWrites]) return [self quitRelaunchIfRequested];
    [self dismissPendingPasswordPrompt];
    [SPDFPasswordCredentialStore.sharedStore removeAllCredentials];
    [self stopKeyboardScrollAnimation];
    [self dismissTabHoverPanel];
    [self removeWindowArrangementShortcutMonitor];
    [self removePresentationEventMonitor];
    [self endPresentationSleepActivity];
    [_translationInstallTask terminate];
    [_translationTask terminate];
    [_renderQueue cancelAllOperations];
    [self cancelCacheRenderOperations];
    [_minimapQueue cancelAllOperations];
    [_queuedRenderPages removeAllObjects];
    [_queuedRenderOperations removeAllObjects];
    [_queuedMinimapThumbnailPages removeAllObjects];
    [_preloadQueue cancelAllOperations];
    [_inactiveTabPreloadQueue cancelAllOperations];
    [_launchWorkCoordinator stop];
    [_findQueue cancelAllOperations];
    [self cancelProgressiveFind];
    [self rememberActiveTabState];
    // If the app terminates before the post-first-paint resume ran, lift the
    // launch save suspension so this final save cannot be swallowed.
    [self resumePersistentStateSavesAfterLaunch];
    [self savePersistentState];
    [self teardownActiveFileWatcher];
    [self clearActiveMetadata];
    [self closeActiveDocumentIfUnowned];
    spdf_teardown_inactive_magnify_tap();
    [self quitRelaunchIfRequested];
}

- (void)applicationDidResignActive:(NSNotification*)notification {
    (void)notification;
    [self dismissTabHoverPanel];
    // Out-of-focus trackpad pinch zoom needs an Accessibility grant (the tap is a
    // listen-only kCGHIDEventTap). Arm it whenever Accessibility is authorized,
    // which the user grants via the Permissions wizard. spdf_install_inactive_magnify_tap
    // is idempotent (no-ops if already armed) and never prompts; if the grant is
    // missing we do nothing, so there is no UI side effect.
    if (spdf_inactive_magnify_tap_authorized()) (void)spdf_install_inactive_magnify_tap();
}

- (BOOL)windowShouldClose:(NSWindow*)sender {
    if (sender != _window) return YES;
    // The red close button quits the entire app, exactly like Cmd+Q: cascade
    // terminate to every sibling window and write the normal session so the next
    // launch restores all windows. Do not special-case other open windows. The
    // window leaves the screen now; the quit writes the session out of sight.
    _terminateOnlyThisProcess = NO;
    _suppressSessionWriteOnTerminate = NO;
    [self hideWindowsForQuit];
    dispatch_async(dispatch_get_main_queue(), ^{
      [NSApp terminate:self];
    });
    return NO;
}

- (void)windowDidResize:(NSNotification*)notification {
    (void)notification;
    [self dismissTabHoverPanel];
    [self updateTabStripFrame];
    [self updateToolbarOverflow];
    if (_windowLiveResizing) {
        [self resizeDocumentViewForWindowLiveResize];
        return;
    }
    [self applyWorkspacePanelPolicy];
    [self restoreSidebarWidth];
    [self relayoutDocumentForViewportChange];
    [self savePersistentState];
}

- (void)windowWillStartLiveResize:(NSNotification*)notification {
    (void)notification;
    _windowLiveResizing = YES;
    [self dismissTabHoverPanel];
}

- (void)windowDidEndLiveResize:(NSNotification*)notification {
    (void)notification;
    if (!_windowLiveResizing) return;
    _windowLiveResizing = NO;
    [self applyWorkspacePanelPolicy];
    [self restoreSidebarWidth];
    [self relayoutDocumentForViewportChange];
    [self savePersistentState];
}

- (void)windowDidChangeBackingProperties:(NSNotification*)notification {
    (void)notification;
    [self dismissTabHoverPanel];
    if ([self isMarkdownActive])
        [self relayoutActiveMarkdownForViewportChange];
    else if (_doc)
        [self renderDocumentPreservingScrollPosition];
    else
        [self resizeDocumentView];
}

- (void)windowDidResignKey:(NSNotification*)notification {
    (void)notification;
    [self stopKeyboardScrollAnimation];
    [self dismissTabHoverPanel];
}

- (void)windowDidBecomeKey:(NSNotification*)notification {
    (void)notification;
    // Non-active tabs are not watched continuously: catch up on any on-disk
    // changes that happened while this window was in the background, and refresh
    // the active tab in place if its file changed. Deferred so it never blocks
    // the focus transition; skipped entirely during launch (no key window yet
    // when applicationDidFinishLaunching runs its critical path).
    dispatch_async(dispatch_get_main_queue(), ^{
      [self checkAllTabsForExternalChangesOnFocus];
      // Stamp this window as the focused one so a relaunch reopens it in front
      // (spdf_session_focused_window_index) even if the app is inactive at quit.
      // Not during launch, whose own session write follows shortly.
      if (!self->_suspendPersistentStateSaves) [self writeSessionStateForCurrentWindow];
    });
}

- (void)windowWillMiniaturize:(NSNotification*)notification {
    (void)notification;
    [self dismissTabHoverPanel];
}

- (void)windowWillEnterFullScreen:(NSNotification*)notification {
    (void)notification;
    [self dismissTabHoverPanel];
}

- (void)windowDidEnterFullScreen:(NSNotification*)notification {
    (void)notification;
    [self dismissTabHoverPanel];
    dispatch_async(dispatch_get_main_queue(), ^{
      [self updateTabStripFrame];
      if (self->_presentationMode && self->_doc) {
          [self renderDocumentAndScrollToPage:self->_pageIndex alignTop:YES];
          [self->_window makeFirstResponder:self->_presentationOverlayView ?: self->_pageView];
      }
    });
}

- (void)windowWillExitFullScreen:(NSNotification*)notification {
    (void)notification;
    [self dismissTabHoverPanel];
}

- (void)windowDidExitFullScreen:(NSNotification*)notification {
    (void)notification;
    [self dismissTabHoverPanel];
    if (_presentationMode && _presentationEnteredFullScreen)
        [self leavePresentationModeAndExitFullScreen:NO sender:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
      [self updateTabStripFrame];
      [self drainPendingWindowArrangementAction];
    });
}

- (NSString*)supportDirectory {
    return spdf_mac_support_directory();
}

- (NSString*)pathForStateFile:(NSString*)name {
    return [[self supportDirectory] stringByAppendingPathComponent:name];
}

// State files are YAML on disk (see core/spdf_yaml.h); in memory the app keeps
// using NSJSONSerialization object graphs, converting at this file boundary.
// A YAML file that fails to parse behaves exactly like the old corrupt-JSON
// path: the file is ignored and defaults apply.
// Non-static: the launch prerender worker (SPDFMacLaunchPrerender.mm) peeks at
// session.yaml through it; declared in SPDFMacLaunchPrerenderPrivate.h.
id spdf_state_object_from_yaml_data(NSData* data) {
    if (!data) return nil;
    NSMutableData* terminated = [data mutableCopy];
    [terminated appendBytes:"" length:1];
    char* json = spdf_json_from_yaml((const char*)terminated.bytes);
    if (!json) return nil;
    NSData* jsonData = [NSData dataWithBytesNoCopy:json length:strlen(json) freeWhenDone:YES];
    return [NSJSONSerialization JSONObjectWithData:jsonData options:NSJSONReadingMutableContainers error:nil];
}

- (id)stateObjectFromFile:(NSString*)name {
    double launchStart = spdf_launch_profile_enabled() ? spdf_zoom_profile_now_ms() : 0.0;
    NSString* path = [self pathForStateFile:name];
    id object = spdf_mac_take_prefetched_state(path); // parsed while AppKit started (SPDFMacStatePrefetch.mm)
    NSData* data = object ? nil : [NSData dataWithContentsOfFile:path];
    if (!object && !data) {
        if (launchStart > 0.0)
            spdf_launch_profile_log(@"state %@ missing %.1fms", name, spdf_zoom_profile_now_ms() - launchStart);
        return nil;
    }
    if (!object) object = spdf_state_object_from_yaml_data(data);
    if (launchStart > 0.0) {
        spdf_launch_profile_log(@"state %@ %lu bytes %.1fms", name, (unsigned long)data.length,
                                spdf_zoom_profile_now_ms() - launchStart);
    }
    return object;
}

- (void)writeStateObject:(id)object toFile:(NSString*)name {
    // Sorted-keys JSON keeps the converted YAML key order stable across saves,
    // so the files stay diffable just like the pretty-printed JSON used to be.
    NSData* jsonData = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:nil];
    if (!jsonData) return;
    NSMutableData* terminated = [jsonData mutableCopy];
    [terminated appendBytes:"" length:1];
    char header[128];
    spdf_state_header_for_file(name.UTF8String, header, sizeof(header));
    char* yaml = spdf_yaml_from_json((const char*)terminated.bytes, header);
    if (!yaml) return;
    NSData* data = [NSData dataWithBytesNoCopy:yaml length:strlen(yaml) freeWhenDone:YES];
    NSString* path = [self pathForStateFile:name];
    if (path.length > 0) {
        NSData* existing = [NSData dataWithContentsOfFile:path];
        if (existing && [existing isEqualToData:data]) return;
    }
    [data writeToFile:path atomically:YES];
}

// One-time per-file JSON -> YAML migration, run before anything reads state
// (including the launch prerender's session peek). Serialized across the
// app's processes by flock inside spdf_state_migrate_dir, and idempotent: an
// existing YAML file wins and its JSON sibling is left untouched, unless the
// JSON is strictly newer (a pre-YAML build ran after the YAML was written) —
// then it is re-migrated so the user's most recent state wins.
- (void)migrateStateFilesIfNeeded {
    static const char* const stems[] = {"settings", "session", "documents", "favorites", "bookmarks"};
    spdf_state_migrate_dir([self supportDirectory].fileSystemRepresentation, stems, 5);
}

- (void)loadPersistentState {
    NSDictionary* settings = [self friendsLaunchWithSettings:[self stateObjectFromFile:@"settings.yaml"]];
    _darkThemePreservesImagesDefault = YES; /* default ON; a stored key overrides below */
    if ([settings isKindOfClass:NSDictionary.class]) {
        NSNumber* fit = settings[@"fitMode"];
        /* viewMode is intentionally not read: single-page view mode was removed
         * and the app is always continuous. Old settings.yaml with viewMode=0
         * (single) are ignored and open as continuous. */
        NSNumber* sidebarWidth = settings[@"sidebarWidth"];
        NSNumber* minimapWidth = settings[@"minimapWidth"];
        NSNumber* defaultSidebarVisible = settings[@"defaultSidebarVisibleForNewDocuments"];
        NSNumber* defaultMinimapVisible = settings[@"defaultMinimapVisibleForNewDocuments"];
        NSNumber* collapseWhitespaceWhenCopyingText = settings[@"collapseWhitespaceWhenCopyingText"];
        NSNumber* searchJumpsToNearestResult = settings[@"searchJumpsToNearestResult"];
        NSNumber* showShortcutHelp = settings[@"showShortcutHelpOnLaunch"];
        NSNumber* autoUpdateEnabled = settings[@"autoUpdateEnabled"];
        NSString* skippedUpdateVersion = settings[@"skippedUpdateVersion"];
        NSNumber* preventSleepInPresentation = settings[@"preventSleepInPresentation"];
        NSNumber* defaultReaderPromptDismissed = settings[@"defaultReaderPromptDismissed"];
        NSNumber* fullDiskAccessPromptDismissed = settings[@"fullDiskAccessPromptDismissed"];
        NSNumber* permissionsWizardShown = settings[@"permissionsWizardShown"];
        NSNumber* printScalingMode = settings[@"printScalingMode"];
        NSNumber* printCustomScale = settings[@"printCustomScale"];
        NSNumber* markdownFontScale = settings[@"markdownFontScale"];
        /* "markdownTheme" now means the reading theme for EVERY document; the
         * key kept its name so an existing "dark" choice carries over with no
         * migration. Missing key keeps the light default. */
        _darkReadingTheme = [settings[@"markdownTheme"] isEqual:@"dark"];
        NSNumber* darkThemePreservesImages = settings[@"darkThemePreservesImages"];
        NSDictionary* windowSize = settings[@"windowSize"];
        NSString* commentAuthor = settings[@"commentAuthor"];
        NSString* translateSource = settings[@"translateSourceLanguage"];
        NSString* translateTarget = settings[@"translateTargetLanguage"];
        NSArray* recentlyOpened = settings[@"recentlyOpened"];
        if (fit) _fitMode = (SPDFFitMode)MAX(0, MIN(4, fit.integerValue));
        if (sidebarWidth) _sidebarWidth = spdf_sane_sidebar_width(sidebarWidth.doubleValue, 0);
        if (minimapWidth) _minimapWidth = spdf_clamp_cg(minimapWidth.doubleValue, 72.0, 260.0);
        if (defaultSidebarVisible) _defaultSidebarVisibleForNewDocuments = defaultSidebarVisible.boolValue;
        if (defaultMinimapVisible) _defaultMinimapVisibleForNewDocuments = defaultMinimapVisible.boolValue;
        if (darkThemePreservesImages) _darkThemePreservesImagesDefault = darkThemePreservesImages.boolValue;
        if (collapseWhitespaceWhenCopyingText)
            _collapseWhitespaceWhenCopyingText = collapseWhitespaceWhenCopyingText.boolValue;
        /* Missing key (settings.yaml from an older build) keeps the enabled default. */
        if (searchJumpsToNearestResult) _searchJumpsToNearestResult = searchJumpsToNearestResult.boolValue;
        if (showShortcutHelp) _showShortcutHelpOnLaunch = showShortcutHelp.boolValue;
        if (autoUpdateEnabled) _autoUpdateEnabled = autoUpdateEnabled.boolValue;
        if ([skippedUpdateVersion isKindOfClass:NSString.class] && skippedUpdateVersion.length)
            _skippedUpdateVersion = [skippedUpdateVersion copy];
        if (preventSleepInPresentation) _preventSleepInPresentation = preventSleepInPresentation.boolValue;
        if (defaultReaderPromptDismissed) _defaultReaderPromptDismissed = defaultReaderPromptDismissed.boolValue;
        if (fullDiskAccessPromptDismissed) _fullDiskAccessPromptDismissed = fullDiskAccessPromptDismissed.boolValue;
        if (permissionsWizardShown) _permissionsWizardShown = permissionsWizardShown.boolValue;
        if (printScalingMode) _printScalingMode = (SPDFPrintScalingMode)MAX(0, MIN(2, printScalingMode.integerValue));
        if (printCustomScale) _printCustomScale = SPDFClampPrintCustomScale(printCustomScale.doubleValue);
        if (markdownFontScale) _markdownFontScale = MAX(0.5, MIN(3.0, markdownFontScale.doubleValue));
        if ([windowSize isKindOfClass:NSDictionary.class]) {
            _restoredWindowContentSize = spdf_sane_window_content_size(
                NSMakeSize([windowSize[@"width"] doubleValue], [windowSize[@"height"] doubleValue]),
                NSScreen.mainScreen);
        }
        if ([commentAuthor isKindOfClass:NSString.class]) _commentAuthor = [commentAuthor copy];
        if ([translateSource isKindOfClass:NSString.class] && translateSource.length)
            _translationSourceLanguage = [self trimmedLanguageCode:translateSource];
        if ([translateTarget isKindOfClass:NSString.class] && translateTarget.length)
            _translationTargetLanguage = [self trimmedLanguageCode:translateTarget];
        if ([recentlyOpened isKindOfClass:NSArray.class]) {
            for (NSString* path in recentlyOpened) {
                if (![path isKindOfClass:NSString.class] || path.length == 0) continue;
                NSString* standardized = path.stringByStandardizingPath;
                BOOL duplicate = NO;
                for (NSString* existingPath in _recentlyOpenedPaths) {
                    if ([existingPath.stringByStandardizingPath isEqualToString:standardized]) {
                        duplicate = YES;
                        break;
                    }
                }
                if (duplicate) continue;
                [_recentlyOpenedPaths addObject:path];
                if (_recentlyOpenedPaths.count >= kRecentDocumentLimit) break;
            }
        }
    }

    NSArray* favorites = [self stateObjectFromFile:@"favorites.yaml"];
    if ([favorites isKindOfClass:NSArray.class]) [_favorites addObjectsFromArray:favorites];

    NSDictionary* documents = [self stateObjectFromFile:@"documents.yaml"];
    if ([documents isKindOfClass:NSDictionary.class])
        _documentStates = [documents mutableCopy];
    else
        _documentStates = [NSMutableDictionary dictionary];
    [self loadSecurityBookmarks];

    if (self.detachedTabLaunch) return [self adoptDetachedTabForLaunch];

    NSMutableDictionary* session =
        [self normalizedMultiWindowSessionFromObject:[self stateObjectFromFile:@"session.yaml"]];
    NSArray* windows = session[@"windows"];
    NSDictionary* windowState = nil;
    if (self.restoreWindowID.length > 0) {
        for (NSDictionary* candidate in windows) {
            if ([candidate[@"id"] isEqualToString:self.restoreWindowID]) {
                windowState = candidate;
                break;
            }
        }
    } else {
        // This is the process that activates, so it takes the window the reader
        // left focused; every other window is spawned behind it.
        NSUInteger focused = spdf_session_focused_window_index(windows);
        windowState = focused == NSNotFound ? nil : windows[focused];
        for (NSUInteger i = 0; i < windows.count; i++) {
            NSString* windowID = [windows[i][@"id"] isKindOfClass:NSString.class] ? windows[i][@"id"] : nil;
            if (i != focused && windowID.length > 0) [_pendingRestoreWindowIDs addObject:windowID];
        }
    }
    if (windowState)
        [self loadSessionWindowState:windowState];
    else if (self.restoreWindowID.length > 0)
        _windowSessionID = [self.restoreWindowID copy];
}

- (NSMutableDictionary*)normalizedMultiWindowSessionFromObject:(id)object {
    NSMutableArray* windows = [NSMutableArray array];
    if ([object isKindOfClass:NSDictionary.class]) {
        NSDictionary* dictionary = object;
        NSArray* storedWindows = dictionary[@"windows"];
        if ([storedWindows isKindOfClass:NSArray.class]) {
            for (NSDictionary* window in storedWindows) {
                if (![window isKindOfClass:NSDictionary.class]) continue;
                NSMutableDictionary* copy = [window mutableCopy];
                NSString* windowID = [copy[@"id"] isKindOfClass:NSString.class] ? copy[@"id"] : nil;
                if (windowID.length == 0) copy[@"id"] = NSUUID.UUID.UUIDString;
                NSArray* rawTabs = [copy[@"tabs"] isKindOfClass:NSArray.class] ? copy[@"tabs"] : @[];
                NSMutableArray* tabs = [NSMutableArray array];
                for (NSDictionary* tab in rawTabs) {
                    if (![tab isKindOfClass:NSDictionary.class]) continue;
                    NSString* path = [tab[@"path"] isKindOfClass:NSString.class] ? tab[@"path"] : nil;
                    if (path.length > 0) [tabs addObject:tab];
                }
                if (tabs.count == 0 && !SPDFSessionHasEmptyTabGroups(copy)) continue;
                copy[@"tabs"] = tabs;
                [windows addObject:copy];
            }
        } else if ([dictionary[@"tabs"] isKindOfClass:NSArray.class]) {
            NSMutableArray* tabs = [NSMutableArray array];
            for (NSDictionary* tab in dictionary[@"tabs"]) {
                if (![tab isKindOfClass:NSDictionary.class]) continue;
                NSString* path = [tab[@"path"] isKindOfClass:NSString.class] ? tab[@"path"] : nil;
                if (path.length > 0) [tabs addObject:tab];
            }
            if (tabs.count == 0) return [@{@"version" : @2, @"windows" : windows} mutableCopy];
            NSMutableDictionary* migrated =
                [@{@"id" : NSUUID.UUID.UUIDString, @"selectedTab" : dictionary[@"selectedTab"] ?: @0, @"tabs" : tabs}
                    mutableCopy];
            [windows addObject:migrated];
        }
    }
    return [@{@"version" : @2, @"windows" : windows} mutableCopy];
}

- (void)loadSessionWindowState:(NSDictionary*)windowState {
    if (![windowState isKindOfClass:NSDictionary.class]) return;
    [self restoreSidebarWorkspaceState:windowState[@"sidebar"]];
    NSString* windowID = [windowState[@"id"] isKindOfClass:NSString.class] ? windowState[@"id"] : nil;
    if (windowID.length > 0) _windowSessionID = [windowID copy];
    NSRect frame;
    if (spdf_window_frame_from_dictionary(windowState[@"frame"], &frame)) {
        _restoredWindowFrame = frame;  // raw: the fallback is chosen at window creation, and never saved
        _hasRestoredWindowFrame = YES;
        _restoredWindowContentSize = _restoredWindowFrame.size;
    }
    NSArray* tabs = [windowState[@"tabs"] isKindOfClass:NSArray.class] ? windowState[@"tabs"] : @[];
    [self.tabLifecycle reset];
    [_tabs removeAllObjects];
    for (NSDictionary* item in tabs) {
        SPDFDocumentTab* tab = spdf_tab_from_dictionary(item);
        if (item[@"preservesImageColors"] == nil) [self seedKeepImageColorsForNewTab:tab];
        if (!tab) continue;
        if (!tab.title.length) tab.title = spdf_display_name_for_path(tab.path);
        if (item[@"showSidebar"] == nil) tab.showSidebar = _defaultSidebarVisibleForNewDocuments;
        if (item[@"showMinimap"] == nil) tab.showMinimap = _defaultMinimapVisibleForNewDocuments;
        if (item[@"showSidebar"] == nil || item[@"showMinimap"] == nil) [self applyStoredDocumentStateToTab:tab];
        [_tabs addObject:tab];
    }
    spdf_tab_groups_normalize(_tabs);
    if (_tabs.count > 0)
        _selectedTabIndex = MIN(MAX(0, [windowState[@"selectedTab"] integerValue]), MAX(0, (NSInteger)_tabs.count - 1));
    else
        _selectedTabIndex = -1;
}

- (NSString*)documentStateKeyForPath:(NSString*)path {
    if (path.length == 0) return @"";
    return path.stringByStandardizingPath ?: path;
}

- (void)applyStoredDocumentStateToTab:(SPDFDocumentTab*)tab {
    if (!tab.path.length) return;
    NSDictionary* state = _documentStates[[self documentStateKeyForPath:tab.path]];
    if (![state isKindOfClass:NSDictionary.class]) return;
    if (state[@"showSidebar"] != nil) tab.showSidebar = [state[@"showSidebar"] boolValue];
    if (state[@"showMinimap"] != nil) {
        tab.showMinimap = [state[@"showMinimap"] boolValue];
        tab.hasMinimapPreference = YES;
    }
}

- (void)applySinglePageMinimapDefaultToTab:(SPDFDocumentTab*)tab pageCount:(NSInteger)pageCount {
    if (!tab || pageCount != 1 || tab.hasMinimapPreference) return;
    tab.showMinimap = NO;
}

- (NSDictionary*)pageGeometryStateForPath:(NSString*)path {
    if (!path.length) return nil;
    NSDictionary* state = _documentStates[[self documentStateKeyForPath:path]];
    return [state isKindOfClass:NSDictionary.class] ? [state copy] : nil;
}

- (void)removePageGeometryFromState:(NSMutableDictionary*)state {
    [state removeObjectForKey:@"geometryVersion"];
    [state removeObjectForKey:@"geometryFileSize"];
    [state removeObjectForKey:@"geometryModifiedAt"];
    [state removeObjectForKey:@"geometryPageCount"];
    [state removeObjectForKey:@"pageGeometry"];
}

- (NSDictionary*)pageGeometryDictionaryForTab:(SPDFDocumentTab*)tab {
    if (!tab.path.length || !tab.cachedDocument) return nil;
    NSInteger pageCount = spdf_page_count(tab.cachedDocument);
    if (pageCount <= 0 || tab.cachedRenderedPages.count != (NSUInteger)pageCount) return nil;

    NSDate* modificationDate = tab.cachedModificationDate;
    unsigned long long fileSize = tab.cachedFileSize;
    if (!modificationDate || fileSize == 0) {
        // Read-only source: stat via a bare lstat (silent) — never the prompting
        // -attributesOfItemAtPath:. (The cache is normally already populated for a
        // read-only tab, so this fallback rarely fires.)
        NSDictionary* attributes =
            tab.readOnly ? [self readOnlySourceAttributesForPath:tab.path] : [self fileAttributesForPath:tab.path];
        modificationDate = spdf_file_modification_date_from_attributes(attributes);
        fileSize = spdf_file_size_from_attributes(attributes);
    }
    if (!modificationDate || fileSize == 0) return nil;

    NSMutableArray<NSNumber*>* geometry = [NSMutableArray arrayWithCapacity:(NSUInteger)pageCount * 2];
    for (NSInteger i = 0; i < pageCount; ++i) {
        SPDFRenderedPage* page = tab.cachedRenderedPages[(NSUInteger)i];
        if (page.pageIndex != i || !isfinite(page.pageWidth) || !isfinite(page.pageHeight) || page.pageWidth <= 0.0 ||
            page.pageHeight <= 0.0)
            return nil;
        [geometry addObject:@(page.pageWidth)];
        [geometry addObject:@(page.pageHeight)];
    }

    return @{
        @"geometryVersion" : @(kPageGeometryCacheVersion),
        @"geometryFileSize" : @(fileSize),
        @"geometryModifiedAt" : @(modificationDate.timeIntervalSince1970),
        @"geometryPageCount" : @(pageCount),
        @"pageGeometry" : geometry
    };
}

- (BOOL)primePageGeometryCacheForDocument:(spdf_document*)doc
                        pageGeometryState:(NSDictionary*)state
                                 fileSize:(unsigned long long)fileSize
                         modificationDate:(NSDate*)modificationDate {
    if (!doc || ![state isKindOfClass:NSDictionary.class] || !modificationDate || fileSize == 0) return NO;
    if ([state[@"geometryVersion"] integerValue] != kPageGeometryCacheVersion) return NO;
    if ([state[@"geometryFileSize"] unsignedLongLongValue] != fileSize) return NO;

    double storedModifiedAt = [state[@"geometryModifiedAt"] doubleValue];
    if (!isfinite(storedModifiedAt) ||
        fabs(storedModifiedAt - modificationDate.timeIntervalSince1970) > kPageGeometryModificationTolerance)
        return NO;

    NSInteger pageCount = spdf_page_count(doc);
    NSArray* geometry = state[@"pageGeometry"];
    if (pageCount <= 0 || [state[@"geometryPageCount"] integerValue] != pageCount ||
        ![geometry isKindOfClass:NSArray.class] || geometry.count != (NSUInteger)pageCount * 2)
        return NO;

    NSMutableArray<NSNumber*>* validated = [NSMutableArray arrayWithCapacity:geometry.count];
    for (id value in geometry) {
        if (![value respondsToSelector:@selector(doubleValue)]) return NO;
        double dimension = [value doubleValue];
        if (!isfinite(dimension) || dimension <= 0.0 || dimension > CGFLOAT_MAX) return NO;
        [validated addObject:@(dimension)];
    }

    for (NSInteger i = 0; i < pageCount; ++i) {
        float width = (float)[validated[(NSUInteger)(i * 2)] doubleValue];
        float height = (float)[validated[(NSUInteger)(i * 2 + 1)] doubleValue];
        if (!spdf_set_page_size_cache(doc, (int)i, width, height)) return NO;
    }
    return YES;
}

// --- Security-scoped bookmarks (App Sandbox file access) --------------------
// Unsupported sandboxed repackaging cannot benefit from Full Disk Access, so the
// app may only read files the user picked through the Open panel / drag — which
// grant a temporary extension that is lost on quit. To reopen a file later
// (restored session tabs, recents, favorites, Open Path) we persist a
// security-scoped bookmark and re-acquire access on the next launch. A single
// path -> bookmark side table (bookmarks.yaml) covers every reopen surface
// because they all key on the file path. On a non-sandboxed build these are
// inert: bookmark creation returns nil (no entitlement), so nothing is stored
// and files open straight from their path.
- (void)captureSecurityBookmarkForPath:(NSString*)path {
    if (path.length == 0) return;
    NSData* data = [[NSURL fileURLWithPath:path] bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope
                                          includingResourceValuesForKeys:nil
                                                           relativeToURL:nil
                                                                   error:NULL];
    if (!data) return; // no current access, non-sandboxed, or non-bookmarkable
    @synchronized(_securityBookmarks) {
        _securityBookmarks[path] = data;
    }
}

// Resolve path's stored bookmark and start accessing it so spdf_open can read
// the file inside the sandbox. Idempotent and thread-safe (render workers call
// it). No stored bookmark -> nothing to do (fresh opens already hold access).
- (void)ensureSecurityAccessForPath:(NSString*)path {
    if (path.length == 0) return;
    NSData* data = nil;
    @synchronized(_securityBookmarks) {
        data = _securityBookmarks[path];
    }
    if (!data) return;
    BOOL stale = NO;
    NSURL* url = [NSURL URLByResolvingBookmarkData:data
                                           options:NSURLBookmarkResolutionWithSecurityScope
                                     relativeToURL:nil
                               bookmarkDataIsStale:&stale
                                             error:NULL];
    if (!url) return;
    @synchronized(_activeSecurityScopedURLs) {
        if (![_activeSecurityScopedURLs containsObject:url] && [url startAccessingSecurityScopedResource])
            [_activeSecurityScopedURLs addObject:url];
    }
    if (stale) [self captureSecurityBookmarkForPath:path];
}

// Every document open funnels through here so the sandbox's security-scoped
// access is acquired BEFORE spdf_open — otherwise restored tabs / recents fail
// with "Operation not permitted". ensureSecurityAccessForPath is a no-op when
// there is no stored bookmark (fresh opens already hold access; non-sandboxed
// builds open by path directly), so this is safe on every open path and thread.
- (spdf_document*)openSpdfDocumentAtPath:(NSString*)path
                              sourcePath:(NSString*)sourcePath
                                  status:(spdf_open_status*)status
                                   error:(char*)err
                             errorLength:(size_t)errLen {
    NSString* source = sourcePath.length ? sourcePath : path;
    [self ensureSecurityAccessForPath:source];
    if (![source.stringByStandardizingPath isEqualToString:path.stringByStandardizingPath])
        [self ensureSecurityAccessForPath:path];
    return SPDFOpenDocumentWithStoredCredential(path, source, status, NULL, err, errLen);
}

- (void)loadSecurityBookmarks {
    id stored = [self stateObjectFromFile:@"bookmarks.yaml"];
    if (![stored isKindOfClass:NSDictionary.class]) return;
    @synchronized(_securityBookmarks) {
        for (NSString* path in (NSDictionary*)stored) {
            id b64 = ((NSDictionary*)stored)[path];
            if (![path isKindOfClass:NSString.class] || ![b64 isKindOfClass:NSString.class]) continue;
            NSData* data = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
            if (data) _securityBookmarks[path] = data;
        }
    }
}

- (void)saveSecurityBookmarks {
    NSMutableDictionary<NSString*, NSString*>* out = [NSMutableDictionary dictionary];
    @synchronized(_securityBookmarks) {
        for (NSString* path in _securityBookmarks)
            out[path] = [_securityBookmarks[path] base64EncodedStringWithOptions:0];
    }
    [self writeStateObject:out toFile:@"bookmarks.yaml"];
}

- (void)saveDocumentStateForTab:(SPDFDocumentTab*)tab {
    if (!tab.path.length) return;
    NSString* key = [self documentStateKeyForPath:tab.path];
    if (!key.length) return;
    NSMutableDictionary* state = [_documentStates[key] isKindOfClass:NSMutableDictionary.class]
                                     ? _documentStates[key]
                                     : [_documentStates[key] mutableCopy];
    if (!state) state = [NSMutableDictionary dictionary];
    state[@"path"] = tab.path;
    state[@"title"] = tab.title.length ? tab.title : spdf_display_name_for_path(tab.path);
    state[@"showSidebar"] = @(tab.showSidebar);
    state[@"showMinimap"] = @(tab.showMinimap);
    NSDictionary* geometry = [self pageGeometryDictionaryForTab:tab];
    if (geometry)
        [state addEntriesFromDictionary:geometry];
    else if (tab.cachedDocument)
        [self removePageGeometryFromState:state];
    state[@"updatedAt"] = @((NSInteger)NSDate.date.timeIntervalSince1970);
    _documentStates[key] = state;
}

- (NSMutableDictionary*)currentWindowSessionDictionary {
    NSMutableArray* tabs = [NSMutableArray array];
    for (SPDFDocumentTab* tab in _tabs) {
        if (!tab.path.length) continue;
        // One writer for a tab's persisted fields, shared with the tab-strip
        // drag payload. This used to be a second inline copy kept in sync by
        // hand, and it drifted: preservesImageColors was added to the shared
        // writer and to the reader, tested through both, and still never
        // reached session.yaml -- so a document's keep-image-colors choice was
        // silently lost on relaunch. The drag-only sourcePID/sourceWindow keys
        // ride along and are ignored on restore.
        [tabs addObject:spdf_dictionary_from_tab(tab, _window.windowNumber)];
    }

    NSRect frame = _window ? _window.frame : _restoredWindowFrame;
    if (_presentationMode && _presentationUsingBorderlessWindow) frame = _presentationPreviousWindowFrame;
    if (NSIsEmptyRect(frame)) {
        NSSize contentSize =
            NSEqualSizes(_restoredWindowContentSize, NSZeroSize) ? NSMakeSize(1120, 800) : _restoredWindowContentSize;
        NSRect visible = NSScreen.mainScreen.visibleFrame;
        frame = NSMakeRect(floor(NSMidX(visible) - contentSize.width / 2.0),
                           floor(NSMidY(visible) - contentSize.height / 2.0), contentSize.width, contentSize.height);
    }
    frame = spdf_window_frame_to_persist(_window, spdf_sane_window_frame(frame, _window.screen ?: NSScreen.mainScreen));
    if (!_windowSessionID.length) _windowSessionID = NSUUID.UUID.UUIDString;
    return [@{
        @"id" : _windowSessionID,
        @"frame" : spdf_dictionary_from_window_frame(frame),
        @"selectedTab" : @(_selectedTabIndex),
        @"tabs" : tabs, @"sidebar" : [self sidebarWorkspaceSnapshot],
        @"pid" : @(getpid()) // Lets another window's process hand this window a document it already shows.
    } mutableCopy];
}

- (void)withLockedSessionStore:(BOOL (^)(NSMutableDictionary* session))block {
    if (!block) return;
    NSString* lockPath = [self pathForStateFile:@"session.lock"];
    int fd = open(lockPath.fileSystemRepresentation, O_CREAT | O_RDWR, 0600);
    if (fd >= 0) flock(fd, LOCK_EX);
    NSMutableDictionary* session =
        [self normalizedMultiWindowSessionFromObject:[self stateObjectFromFile:@"session.yaml"]];
    BOOL changed = block(session);
    if (changed) [self writeStateObject:session toFile:@"session.yaml"];
    if (fd >= 0) {
        flock(fd, LOCK_UN);
        close(fd);
    }
}

- (void)writeSessionStateForCurrentWindow {
    if (_suppressSessionWriteOnTerminate) return;
    [self rememberActiveTabState];
    if (_tabs.count == 0 && ![self emptyTabGroups].count) {
        [self removeSessionStateForCurrentWindow];
        return;
    }
    NSMutableDictionary* currentWindow = [self currentWindowSessionDictionary];
    [self withLockedSessionStore:^BOOL(NSMutableDictionary* session) {
      NSMutableArray* windows = [session[@"windows"] isKindOfClass:NSMutableArray.class] ? session[@"windows"] : nil;
      if (!windows) {
          windows = [NSMutableArray array];
          session[@"windows"] = windows;
      }
      NSUInteger existing = NSNotFound;
      for (NSUInteger i = 0; i < windows.count; i++) {
          if ([windows[i][@"id"] isEqualToString:self->_windowSessionID]) {
              existing = i;
              break;
          }
      }
      // Stamped only in the active app: a restored window is key in its own process too (SPDFMacTabStateTests).
      BOOL focusedNow = NSApp.isActive && self->_window.isKeyWindow;
      id previous = existing == NSNotFound ? nil : windows[existing][@"focusedAt"];
      currentWindow[@"focusedAt"] = focusedNow ? @(NSDate.timeIntervalSinceReferenceDate) : (previous ?: @0);
      if (existing == NSNotFound) {
          [windows addObject:currentWindow];
          return YES;
      }
      if ([windows[existing] isEqual:currentWindow])
          return NO;
      else {
          windows[existing] = currentWindow;
          return YES;
      }
    }];
}

- (void)removeSessionStateForCurrentWindow {
    if (!_windowSessionID.length) return;
    [self withLockedSessionStore:^BOOL(NSMutableDictionary* session) {
      NSMutableArray* windows = [session[@"windows"] isKindOfClass:NSMutableArray.class] ? session[@"windows"] : nil;
      if (!windows) return YES;
      for (NSInteger i = (NSInteger)windows.count - 1; i >= 0; i--) {
          if ([windows[(NSUInteger)i][@"id"] isEqualToString:self->_windowSessionID]) {
              [windows removeObjectAtIndex:(NSUInteger)i];
          }
      }
      return YES;
    }];
}

- (BOOL)canOpenDocumentAtPath:(NSString*)path showError:(BOOL)showError {
    if (path.length == 0) return NO;
    if ([path.pathExtension isEqualToString:@"spdf-command"]) { [self acceptAgentCommandAtPath:path]; return NO; }
    BOOL isDirectory = NO;
    BOOL fileExists = [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory];
    if (!fileExists || isDirectory) {
        if (showError) [self showError:@"File moved or deleted" detail:path];
        return NO;
    }
    return YES;
}

- (NSArray<NSString*>*)openableDocumentPathsFromPaths:(NSArray<NSString*>*)paths showErrors:(BOOL)showErrors {
    NSMutableArray<NSString*>* openable = [NSMutableArray array];
    for (NSString* path in paths) {
        if (![path isKindOfClass:NSString.class] || path.length == 0) continue;
        if ([self canOpenDocumentAtPath:path showError:showErrors]) [openable addObject:path];
    }
    return openable;
}

- (NSArray<NSRunningApplication*>*)otherRunningShenzhenApplications {
    NSString* bundleID = NSBundle.mainBundle.bundleIdentifier;
    pid_t currentPID = NSProcessInfo.processInfo.processIdentifier;
    NSMutableArray<NSRunningApplication*>* apps = [NSMutableArray array];
    for (NSRunningApplication* app in [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID]) {
        if (app.processIdentifier != currentPID) [apps addObject:app];
    }
    return apps;
}

- (BOOL)hasOtherShenzhenWindows {
    for (ShenzhenMacDelegate* controller in gSPDFWindowControllers ?: @[]) {
        if (controller != self && controller->_window && controller->_window.visible) return YES;
    }
    return [self otherRunningShenzhenApplications].count > 0;
}

- (void)activateWindowForExternalOpen {
    if (!_window) return;
    [NSApp activateIgnoringOtherApps:YES];
    [_window orderFrontRegardless];
    [_window makeKeyAndOrderFront:nil];
    [_window makeMainWindow];
}

- (void)dismissTabHoverPanel {
    [_tabStrip dismissHoverPanel];
}

- (void)spawnPendingRestoredWindowsIfNeeded {
    if (self.detachedTabLaunch || self.restoreWindowID.length > 0) return;
    spdf_spawn_restored_window_processes(_pendingRestoreWindowIDs, _windowSessionID);
    [_pendingRestoreWindowIDs removeAllObjects];
}

- (void)performWithBatchedPersistentStateSaves:(void (^)(void))block {
    if (!block) return;
    BOOL wasSuspended = _suspendPersistentStateSaves;
    _suspendPersistentStateSaves = YES;
    block();
    _suspendPersistentStateSaves = wasSuspended;
    if (!wasSuspended && _needsDeferredPersistentStateSave) {
        _needsDeferredPersistentStateSave = NO;
        [self savePersistentState];
    }
}

// Lifts the launch-wide save suspension installed at the top of
// applicationDidFinishLaunching and performs the catch-up save if anything
// requested one during launch. Runs just after the first paint; also called
// defensively from every termination path so a quit during the brief
// suspension window can never drop state.
- (void)resumePersistentStateSavesAfterLaunch {
    if (!_suspendPersistentStateSaves) return;
    _suspendPersistentStateSaves = NO;
    if (_needsDeferredPersistentStateSave) {
        _needsDeferredPersistentStateSave = NO;
        [self savePersistentState];
    }
    // Read-only shadow copy: now that tabs are restored and the catch-up save has
    // run, it is safe to sweep orphaned temp copies against the LIVE tabs. Primary
    // launch only, once. (Detached-tab launches share the same ReadOnlyCopies dir
    // but must not sweep — their tab set is partial.)
    if (!_didSweepReadOnlyCopies && !self.detachedTabLaunch) {
        _didSweepReadOnlyCopies = YES;
        [self sweepOrphanedReadOnlyCopies];
    }
}

- (void)savePersistentState {
    SPDFScopedProfileLog spdfScopedProfile("savePersistentState", 4.0);
    if (_suspendPersistentStateSaves) {
        _needsDeferredPersistentStateSave = YES;
        return;
    }

    NSSize windowContentSize = _restoredWindowContentSize;
    if (_window && !_window.miniaturized && !_presentationMode && !(_window.styleMask & NSWindowStyleMaskFullScreen)) {
        windowContentSize = [_window contentRectForFrameRect:_window.frame].size;
        _restoredWindowContentSize = windowContentSize;
    }
    windowContentSize = spdf_sane_window_content_size(windowContentSize, _window.screen ?: NSScreen.mainScreen);

    if (!_suppressSessionWriteOnTerminate) [self writeSessionStateForCurrentWindow];
    CGFloat sidebarWidth = spdf_sane_sidebar_width(_sidebarWidth, 0);
    [self writeStateObject:SPDFMacFriendsSettingsForSaving(@{
        @"version" : @1,
        @"fitMode" : @(_fitMode),
        /* Always continuous now; kept for backward compat (see SPDFMacModels.mm). */
        @"viewMode" : @1,
        @"sidebarWidth" : @(sidebarWidth),
        @"minimapWidth" : @(_minimapWidth),
        @"defaultSidebarVisibleForNewDocuments" : @(_defaultSidebarVisibleForNewDocuments),
        @"defaultMinimapVisibleForNewDocuments" : @(_defaultMinimapVisibleForNewDocuments),
        @"collapseWhitespaceWhenCopyingText" : @(_collapseWhitespaceWhenCopyingText),
        @"searchJumpsToNearestResult" : @(_searchJumpsToNearestResult),
        @"windowSize" : @{@"width" : @(windowContentSize.width), @"height" : @(windowContentSize.height)},
        @"commentAuthor" : _commentAuthor ?: @"",
        @"translateSourceLanguage" : _translationSourceLanguage ?: @"zh",
        @"translateTargetLanguage" : _translationTargetLanguage ?: @"en",
        @"showShortcutHelpOnLaunch" : @(_showShortcutHelpOnLaunch),
        @"autoUpdateEnabled" : @(_autoUpdateEnabled),
        @"skippedUpdateVersion" : _skippedUpdateVersion ?: @"",
        @"preventSleepInPresentation" : @(_preventSleepInPresentation),
        @"defaultReaderPromptDismissed" : @(_defaultReaderPromptDismissed),
        @"fullDiskAccessPromptDismissed" : @(_fullDiskAccessPromptDismissed),
        @"permissionsWizardShown" : @(_permissionsWizardShown),
        @"printScalingMode" : @(_printScalingMode),
        @"printCustomScale" : @(SPDFClampPrintCustomScale(_printCustomScale)),
        @"markdownFontScale" : @(round(MAX(0.5, MIN(3.0, _markdownFontScale)) * 100.0) / 100.0),
        @"markdownTheme" : _darkReadingTheme ? @"dark" : @"light",
        @"darkThemePreservesImages" : @(_darkThemePreservesImagesDefault),
        @"recentlyOpened" : _recentlyOpenedPaths ?: @[]
    })
                   toFile:@"settings.yaml"];
    [self writeStateObject:_favorites toFile:@"favorites.yaml"];
    [self writeStateObject:_documentStates ?: @{} toFile:@"documents.yaml"];
    [self saveSecurityBookmarks];
}

- (void)rebuildRecentlyOpenedMenu {
    if (!_recentlyOpenedMenu) return;
    [_recentlyOpenedMenu removeAllItems];
    if (_recentlyOpenedPaths.count == 0) {
        NSMenuItem* empty = [[NSMenuItem alloc] initWithTitle:@"No Recent Documents" action:nil keyEquivalent:@""];
        empty.enabled = NO;
        [_recentlyOpenedMenu addItem:empty];
        return;
    }
    NSUInteger count = MIN((NSUInteger)kRecentDocumentLimit, _recentlyOpenedPaths.count);
    for (NSUInteger i = 0; i < count; i++) {
        NSString* path = _recentlyOpenedPaths[i];
        NSString* title = spdf_display_name_for_path(path);
        NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title
                                                      action:@selector(openRecentDocument:)
                                               keyEquivalent:@""];
        item.representedObject = path;
        item.toolTip = path;
        [_recentlyOpenedMenu addItem:item];
    }
    spdf_apply_system_icons_to_menu(_recentlyOpenedMenu);
}

- (void)rememberRecentlyOpenedPath:(NSString*)path {
    if (path.length == 0 || SPDFMacPathIsCollectionArchive(path)) return;
    NSString* standardized = path.stringByStandardizingPath;
    for (NSInteger i = (NSInteger)_recentlyOpenedPaths.count - 1; i >= 0; --i) {
        NSString* existingPath = _recentlyOpenedPaths[(NSUInteger)i];
        if ([existingPath.stringByStandardizingPath isEqualToString:standardized])
            [_recentlyOpenedPaths removeObjectAtIndex:(NSUInteger)i];
    }
    [_recentlyOpenedPaths insertObject:[path copy] atIndex:0];
    while (_recentlyOpenedPaths.count > kRecentDocumentLimit) [_recentlyOpenedPaths removeLastObject];
    [self rebuildRecentlyOpenedMenu];
}

- (void)rememberClosedDocumentPath:(NSString*)path {
    if (path.length == 0) return;
    [_closedDocumentPaths addObject:[path copy]]; [self activityDocumentWillClose]; // the tab in front may change
    while (_closedDocumentPaths.count > kRecentDocumentLimit) [_closedDocumentPaths removeObjectAtIndex:0];
}

- (void)buildMenu {
    NSMenu* mainMenu = [[NSMenu alloc] initWithTitle:@""];

    NSMenuItem* appItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    [mainMenu addItem:appItem];
    NSMenu* appMenu = [[NSMenu alloc] initWithTitle:@"Shenzhen PDF"];
    [appMenu addItemWithTitle:@"About Shenzhen PDF" action:@selector(showAboutPanel:) keyEquivalent:@""];
    if (!spdf_is_sandboxed()) {
        [appMenu addItem:[NSMenuItem separatorItem]];
        [appMenu addItemWithTitle:@"Check for Updates…" action:@selector(checkForUpdates:) keyEquivalent:@""];
        [appMenu addItemWithTitle:@"Automatically check for updates"
                           action:@selector(toggleAutomaticUpdateChecks:)
                    keyEquivalent:@""];
    }
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Settings…" action:@selector(showUnifiedSettings:) keyEquivalent:@","];
    [appMenu addItemWithTitle:@"Make Shenzhen PDF Default PDF Reader..."
                       action:@selector(makeDefaultPDFReader:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit Shenzhen PDF" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;

    NSMenuItem* fileItem = [[NSMenuItem alloc] initWithTitle:@"File" action:nil keyEquivalent:@""];
    [mainMenu addItem:fileItem];
    NSMenu* fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    [fileMenu addItemWithTitle:@"Open..." action:@selector(openDocument:) keyEquivalent:@"o"];
    NSMenuItem* openPathItem = [fileMenu addItemWithTitle:@"Open Path..."
                                                   action:@selector(openPathPrompt:)
                                            keyEquivalent:@"o"];
    openPathItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    NSMenuItem* reopenClosed = [fileMenu addItemWithTitle:@"Reopen Last Closed"
                                                   action:@selector(reopenLastClosedDocument:)
                                            keyEquivalent:@"t"];
    reopenClosed.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    NSMenuItem* recentItem = [[NSMenuItem alloc] initWithTitle:@"Recently Opened" action:nil keyEquivalent:@""];
    _recentlyOpenedMenu = [[NSMenu alloc] initWithTitle:@"Recently Opened"];
    // Populated lazily via menuNeedsUpdate: (NSMenuDelegate) — AppKit calls it
    // synchronously right before the submenu is shown, so the items (and
    // their SF-symbol icons) never need to exist before the first paint and
    // can never be observed missing or stale. One disabled placeholder keeps
    // the submenu non-empty so the parent item can never be auto-disabled
    // before the first open; it matches the empty-list state the eager build
    // produced and is replaced on first display.
    NSMenuItem* recentPlaceholder = [[NSMenuItem alloc] initWithTitle:@"No Recent Documents"
                                                               action:nil
                                                        keyEquivalent:@""];
    recentPlaceholder.enabled = NO;
    [_recentlyOpenedMenu addItem:recentPlaceholder];
    _recentlyOpenedMenu.delegate = self;
    recentItem.submenu = _recentlyOpenedMenu;
    [fileMenu addItem:recentItem];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [fileMenu addItemWithTitle:@"Open in Adobe Acrobat Reader"
                        action:@selector(openInExternalReader:)
                 keyEquivalent:@""];
    [fileMenu addItemWithTitle:@"Show in Folder" action:@selector(showInFolder:) keyEquivalent:@""];
    [fileMenu addItemWithTitle:@"Copy Path" action:@selector(copyCurrentDocumentPath:) keyEquivalent:@""];
    [fileMenu addItemWithTitle:@"Save As..." action:@selector(saveDocumentAs:) keyEquivalent:@"s"];
    [fileMenu addItemWithTitle:@"Close" action:@selector(closeDocument:) keyEquivalent:@"w"];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [fileMenu addItemWithTitle:@"Print..." action:@selector(printDocument:) keyEquivalent:@"p"];
    [fileMenu addItemWithTitle:@"OCR Document..." action:@selector(ocrDocument:) keyEquivalent:@""];
    [fileMenu addItemWithTitle:@"Delete All Text..." action:@selector(deleteAllTextFromDocument:) keyEquivalent:@""];
    [fileMenu addItemWithTitle:@"Translate..." action:@selector(translateDocument:) keyEquivalent:@""];
    NSMenuItem* propertiesItem = [fileMenu addItemWithTitle:@"Properties..."
                                                     action:@selector(showProperties:)
                                              keyEquivalent:@"i"];
    // Opt+I, not Cmd+I: Cmd+I is the colour inversion, which is reached far more
    // often than a document's metadata.
    propertiesItem.keyEquivalentModifierMask = NSEventModifierFlagOption;
    fileItem.submenu = fileMenu;

    NSMenuItem* goItem = [[NSMenuItem alloc] initWithTitle:@"Go To" action:nil keyEquivalent:@""];
    [mainMenu addItem:goItem];
    NSMenu* goMenu = [[NSMenu alloc] initWithTitle:@"Go To"];
    // Key equivalents mirror the keyboard navigation handled in
    // documentArrowKeyDown:. Page navigation is on Option+arrows: Option+Up/Down =
    // first/last page, Option+Left/Right = previous/next page. Cmd+Left/Right
    // switch tabs (Cmd+Up/Down also page through, handled directly in
    // documentArrowKeyDown: since they are not menu equivalents). Plain arrows are
    // intentionally NOT menu equivalents: they stay context-aware (page change vs
    // smooth scroll) in documentArrowKeyDown:.
    NSMenuItem* firstPageItem =
        [goMenu addItemWithTitle:@"First Page"
                          action:@selector(firstPage:)
                   keyEquivalent:[NSString stringWithFormat:@"%C", static_cast<unichar>(NSUpArrowFunctionKey)]];
    firstPageItem.keyEquivalentModifierMask = NSEventModifierFlagOption;
    NSMenuItem* previousPageItem =
        [goMenu addItemWithTitle:@"Previous Page"
                          action:@selector(previousPage:)
                   keyEquivalent:[NSString stringWithFormat:@"%C", static_cast<unichar>(NSLeftArrowFunctionKey)]];
    previousPageItem.keyEquivalentModifierMask = NSEventModifierFlagOption;
    NSMenuItem* nextPageItem =
        [goMenu addItemWithTitle:@"Next Page"
                          action:@selector(nextPage:)
                   keyEquivalent:[NSString stringWithFormat:@"%C", static_cast<unichar>(NSRightArrowFunctionKey)]];
    nextPageItem.keyEquivalentModifierMask = NSEventModifierFlagOption;
    NSMenuItem* lastPageItem =
        [goMenu addItemWithTitle:@"Last Page"
                          action:@selector(lastPage:)
                   keyEquivalent:[NSString stringWithFormat:@"%C", static_cast<unichar>(NSDownArrowFunctionKey)]];
    lastPageItem.keyEquivalentModifierMask = NSEventModifierFlagOption;
    for (NSMenuItem* item in @[ firstPageItem, previousPageItem, nextPageItem, lastPageItem ]) item.target = self;
    [goMenu addItem:[NSMenuItem separatorItem]];
    [goMenu addItemWithTitle:@"Go To Page..." action:@selector(focusPageField:) keyEquivalent:@"l"];
    [goMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem* previousTabItem =
        [goMenu addItemWithTitle:@"Previous Tab"
                          action:@selector(selectPreviousTab:)
                   keyEquivalent:[NSString stringWithFormat:@"%C", static_cast<unichar>(NSLeftArrowFunctionKey)]];
    previousTabItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    NSMenuItem* nextTabItem =
        [goMenu addItemWithTitle:@"Next Tab"
                          action:@selector(selectNextTab:)
                   keyEquivalent:[NSString stringWithFormat:@"%C", static_cast<unichar>(NSRightArrowFunctionKey)]];
    nextTabItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    for (NSMenuItem* item in @[ previousTabItem, nextTabItem ]) item.target = self;
    goItem.submenu = goMenu;

    NSMenuItem* zoomItem = [[NSMenuItem alloc] initWithTitle:@"Zoom" action:nil keyEquivalent:@""];
    [mainMenu addItem:zoomItem];
    NSMenu* zoomMenu = [[NSMenu alloc] initWithTitle:@"Zoom"];
    NSMenuItem* zoomIn = [zoomMenu addItemWithTitle:@"Zoom In" action:@selector(zoomIn:) keyEquivalent:@"+"];
    NSMenuItem* zoomOut = [zoomMenu addItemWithTitle:@"Zoom Out" action:@selector(zoomOut:) keyEquivalent:@"-"];
    NSMenuItem* actualSize = [zoomMenu addItemWithTitle:@"100%" action:@selector(actualSize:) keyEquivalent:@"4"];
    [zoomMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem* zoomFitPage = [zoomMenu addItemWithTitle:@"Fit Page" action:@selector(fitPage:) keyEquivalent:@"1"];
    NSMenuItem* zoomFitWidth = [zoomMenu addItemWithTitle:@"Fit Width" action:@selector(fitWidth:) keyEquivalent:@"2"];
    NSMenuItem* zoomFitHeight = [zoomMenu addItemWithTitle:@"Fit Height"
                                                    action:@selector(fitHeight:)
                                             keyEquivalent:@"3"];
    for (NSMenuItem* item in @[ zoomIn, zoomOut, actualSize, zoomFitPage, zoomFitWidth, zoomFitHeight ])
        item.target = self;
    zoomItem.submenu = zoomMenu;

    NSMenuItem* viewItem = [[NSMenuItem alloc] initWithTitle:@"View" action:nil keyEquivalent:@""];
    [mainMenu addItem:viewItem];
    NSMenu* viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
    NSMenuItem* sidePanelItem = [viewMenu addItemWithTitle:@"Show Side Panel"
                                                    action:@selector(toggleSidebar:)
                                             keyEquivalent:@""];
    sidePanelItem.target = self;
    NSMenuItem* minimapItem = [viewMenu addItemWithTitle:@"Show Minimap"
                                                  action:@selector(toggleMinimap:)
                                           keyEquivalent:@""];
    minimapItem.target = self;
    SPDFMacInstallReadingThemeMenuItems(viewMenu, self);
    [viewMenu addItem:[NSMenuItem separatorItem]];
    // One visible Presentation Mode row: it shows ⇧⌘F natively and advertises
    // the F5 shortcut via the "(F5)" suffix added in -validateMenuItem:. F5 keeps
    // working through the hidden companion item below, so there is no duplicate
    // row in the View menu.
    NSMenuItem* presentation = [viewMenu addItemWithTitle:@"Presentation Mode"
                                                   action:@selector(togglePresentation:)
                                            keyEquivalent:@"f"];
    presentation.target = self;
    presentation.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    NSMenuItem* presentationF5 =
        [viewMenu addItemWithTitle:@"Presentation Mode"
                            action:@selector(togglePresentation:)
                     keyEquivalent:[NSString stringWithFormat:@"%C", static_cast<unichar>(NSF5FunctionKey)]];
    presentationF5.target = self;
    presentationF5.keyEquivalentModifierMask = 0;
    presentationF5.hidden = YES;
    presentationF5.allowsKeyEquivalentWhenHidden = YES;
    NSMenuItem* preventSleep = [viewMenu addItemWithTitle:@"Prevent Sleep During Presentation"
                                                   action:@selector(togglePreventSleepInPresentation:)
                                            keyEquivalent:@""];
    preventSleep.target = self;
    NSMenuItem* fullScreen = [viewMenu addItemWithTitle:@"Full Screen"
                                                 action:@selector(toggleFullScreen:)
                                          keyEquivalent:@"f"];
    fullScreen.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagControl;
    [viewMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem* rotateClockwise = [viewMenu addItemWithTitle:@"Rotate Clockwise"
                                                      action:@selector(rotateClockwise:)
                                               keyEquivalent:@"r"];
    rotateClockwise.target = self;
    rotateClockwise.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    NSMenuItem* rotateAnticlockwise = [viewMenu addItemWithTitle:@"Rotate Anticlockwise"
                                                          action:@selector(rotateAnticlockwise:)
                                                   keyEquivalent:@"r"];
    rotateAnticlockwise.target = self;
    rotateAnticlockwise.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    viewItem.submenu = viewMenu;

    NSMenuItem* windowItem = [[NSMenuItem alloc] initWithTitle:@"Window" action:nil keyEquivalent:@""];
    [mainMenu addItem:windowItem];
    _windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    _windowMenu.delegate = self;
    NSMenuItem* minimizeItem = [_windowMenu addItemWithTitle:@"Minimize"
                                                      action:@selector(performMiniaturize:)
                                               keyEquivalent:@"m"];
    minimizeItem.target = nil;
    NSMenuItem* zoomItemWindow = [_windowMenu addItemWithTitle:@"Zoom"
                                                        action:@selector(performZoom:)
                                                 keyEquivalent:@""];
    zoomItemWindow.target = nil;
    [_windowMenu addItem:[NSMenuItem separatorItem]];
    [self addWindowArrangementItemsToMenu:_windowMenu includeKeyEquivalents:YES];
    [_windowMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem* bringAllToFront = [_windowMenu addItemWithTitle:@"Bring All to Front"
                                                         action:@selector(arrangeInFront:)
                                                  keyEquivalent:@""];
    bringAllToFront.target = NSApp;
    windowItem.submenu = _windowMenu;
    [NSApp setWindowsMenu:_windowMenu];

    NSMenuItem* editItem = [[NSMenuItem alloc] initWithTitle:@"Edit" action:nil keyEquivalent:@""];
    [mainMenu addItem:editItem];
    NSMenu* editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Copy Selected Document Text" action:@selector(copySelection:) keyEquivalent:@""];
    [editMenu addItemWithTitle:@"Replace Line Breaks When Copying Text"
                        action:@selector(toggleCollapseWhitespaceWhenCopyingText:)
                 keyEquivalent:@""];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Find" action:@selector(focusFind:) keyEquivalent:@"f"];
    [editMenu addItemWithTitle:@"Find Next" action:@selector(findNext:) keyEquivalent:@""];
    [editMenu addItemWithTitle:@"Find Previous" action:@selector(findPrevious:) keyEquivalent:@""];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Regex Multiline" action:@selector(toggleFindRegexMultiline:) keyEquivalent:@""];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Set Author for Comments..." action:@selector(setCommentAuthor:) keyEquivalent:@""];
    editItem.submenu = editMenu;

    NSMenuItem* favoritesItem = [[NSMenuItem alloc] initWithTitle:@"Favorites" action:nil keyEquivalent:@""];
    [mainMenu addItem:favoritesItem];
    NSMenu* favoritesMenu = [[NSMenu alloc] initWithTitle:@"Favorites"];
    [favoritesMenu addItemWithTitle:@"Search Favorites..." action:@selector(showFavoritesPalette:) keyEquivalent:@"k"];
    [favoritesMenu addItem:[NSMenuItem separatorItem]];
    [favoritesMenu addItemWithTitle:@"Favorite Current Page" action:@selector(favoriteCurrentPage:) keyEquivalent:@"b"];
    NSMenuItem* docFav = [favoritesMenu addItemWithTitle:@"Favorite Current Document"
                                                  action:@selector(favoriteCurrentDocument:)
                                           keyEquivalent:@"B"];
    docFav.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [favoritesMenu addItemWithTitle:@"Manage Favorites..." action:@selector(showFavoritesPalette:) keyEquivalent:@""];
    favoritesItem.submenu = favoritesMenu;

    NSMenuItem* settingsItem = [[NSMenuItem alloc] initWithTitle:@"Settings" action:nil keyEquivalent:@""];
    [mainMenu addItem:settingsItem];
    NSMenu* settingsMenu = [[NSMenu alloc] initWithTitle:@"Settings"];
    [settingsMenu addItemWithTitle:@"Settings & AI…" action:@selector(showUnifiedSettings:) keyEquivalent:@""].target=self;
    NSMenuItem* defaultSidebarItem = [settingsMenu addItemWithTitle:@"Open New Documents with Side Panel"
                                                             action:@selector(toggleDefaultSidebarForNewDocuments:)
                                                      keyEquivalent:@""];
    defaultSidebarItem.target = self;
    NSMenuItem* defaultMinimapItem = [settingsMenu addItemWithTitle:@"Open New Documents with Map"
                                                             action:@selector(toggleDefaultMinimapForNewDocuments:)
                                                      keyEquivalent:@""];
    defaultMinimapItem.target = self;
    NSMenuItem* nearestSearchItem = [settingsMenu addItemWithTitle:@"Search Jumps to Nearest Result"
                                                            action:@selector(toggleSearchJumpsToNearestResult:)
                                                     keyEquivalent:@""];
    nearestSearchItem.target = self;
    [settingsMenu addItem:[NSMenuItem separatorItem]];
    [settingsMenu addItemWithTitle:@"Keep Image Colors in Dark Theme by Default" action:@selector(toggleDefaultImageColors:) keyEquivalent:@""].target=self;
    SPDFMacInstallFileExplorerSettingsMenu(settingsMenu);
    SPDFMacInstallMarkdownEditorSettingsMenu(settingsMenu);
    [self installCollectionSettingsMenu:settingsMenu];
    [settingsMenu addItem:[NSMenuItem separatorItem]];
    NSArray<NSString*>* stateFiles =
        @[ @"settings.yaml", @"session.yaml", @"documents.yaml", @"favorites.yaml", @"bookmarks.yaml" ];
    for (NSString* stateFile in stateFiles) {
        NSMenuItem* stateItem =
            [settingsMenu addItemWithTitle:[NSString stringWithFormat:@"Open %@...", stateFile]
                                    action:@selector(openStateFile:)
                             keyEquivalent:[stateFile isEqualToString:@"settings.yaml"] ? @"," : @""];
        stateItem.target = self;
        stateItem.representedObject = stateFile;
    }
    [settingsMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem* revealSettings = [settingsMenu addItemWithTitle:@"Reveal Settings Folder"
                                                         action:@selector(revealSettingsFolder:)
                                                  keyEquivalent:@""];
    revealSettings.target = self;
    settingsItem.submenu = settingsMenu;

    NSMenuItem* helpItem = [[NSMenuItem alloc] initWithTitle:@"Help" action:nil keyEquivalent:@""];
    [mainMenu addItem:helpItem];
    NSMenu* helpMenu = [[NSMenu alloc] initWithTitle:@"Help"];
    NSMenuItem* shortcuts =
        [helpMenu addItemWithTitle:@"Keyboard Shortcuts"
                            action:@selector(showShortcutHelp:)
                     keyEquivalent:[NSString stringWithFormat:@"%C", static_cast<unichar>(NSF1FunctionKey)]];
    shortcuts.target = self;
    shortcuts.keyEquivalentModifierMask = 0;
    helpItem.submenu = helpMenu;

    SPDFInstallReaderNavigationMenu(appMenu, goMenu, viewMenu, self);
    NSApp.mainMenu = mainMenu;
    // SF-symbol decoration creates ~70 system-symbol images (CoreUI asset
    // lookups). Menu-item icons are only visible once a submenu is opened,
    // which cannot happen before the first paint, so build them just after
    // launch instead of on the critical path. The menu bar itself (titles
    // only) is identical either way. Not a dispatch_after from here: its timer
    // fired while launch still ran and queued the block ahead of the first frame.
    spdf_mac_after_first_paint(^{ spdf_apply_system_icons_to_main_menu_contents(mainMenu); });
}

- (NSString*)displayVersion {
    // The release (SZFReleaseTag), as the update dialog names it; not CFBundleVersion, which Friends changes raise.
    return spdf_running_version_from_info(NSBundle.mainBundle.infoDictionary) ?: @"unknown";
}

// ----- Auto-updater bridge (Dev ID build only; runtime sandbox re-check) -------

- (void)checkForUpdates:(id)sender {
    (void)sender;
    if (spdf_is_sandboxed()) return;
    [[SPDFUpdater shared] checkForUpdatesUserInitiated:YES];
}

- (void)toggleAutomaticUpdateChecks:(id)sender {
    (void)sender;
    if (spdf_is_sandboxed()) return;
    _autoUpdateEnabled = !_autoUpdateEnabled;
    [self savePersistentState];
}

// The update driver calls this on itself before quitting siblings so an
// incoming sibling-cascade terminate can't pre-empt the helper spawn.
- (void)prepareForUpdateTerminate {
    _terminateOnlyThisProcess = YES;
}

// A sibling received the driver's "quit for update" request. Exit this process
// WITHOUT re-broadcasting terminate to every other process (set
// _terminateOnlyThisProcess so applicationShouldTerminate's cascade guard at
// :1193 short-circuits), after writing this window's session synchronously so
// the relaunched primary restores the full multi-window set.
- (void)handleQuitForUpdateNotification:(NSNotification*)note {
    (void)note;
    if (spdf_is_sandboxed()) return;
    _terminateOnlyThisProcess = YES;
    [self resumePersistentStateSavesAfterLaunch];
    if (!_suppressSessionWriteOnTerminate) [self writeSessionStateForCurrentWindow];
    [self savePersistentState];
    dispatch_async(dispatch_get_main_queue(), ^{
      [NSApp terminate:nil];
    });
}

// Accessors used by SPDFUpdater to read/write the persisted prefs.
- (BOOL)autoUpdateEnabledForUpdater {
    return _autoUpdateEnabled;
}

- (NSString*)skippedUpdateVersionForUpdater {
    return _skippedUpdateVersion;
}

- (void)setSkippedUpdateVersionForUpdater:(NSString*)tag {
    _skippedUpdateVersion = [tag copy];
    [self savePersistentState];
}

- (void)showAboutPanel:(id)sender {
    (void)sender;
    if (!_aboutPanel) {
        _aboutPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0.0, 0.0, 440.0, 238.0)
                                                 styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
        _aboutPanel.title = @"About Shenzhen PDF";
        _aboutPanel.releasedWhenClosed = NO;
        _aboutPanel.floatingPanel = YES;
        _aboutPanel.hidesOnDeactivate = YES;
        _aboutPanel.level = NSModalPanelWindowLevel;
        _aboutPanel.collectionBehavior =
            NSWindowCollectionBehaviorMoveToActiveSpace | NSWindowCollectionBehaviorFullScreenAuxiliary;

        NSView* content = [[NSView alloc] initWithFrame:_aboutPanel.contentView.bounds];
        content.translatesAutoresizingMaskIntoConstraints = NO;
        _aboutPanel.contentView = content;

        NSImageView* iconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
        iconView.image = NSApp.applicationIconImage;
        iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
        // Mask to the app-icon squircle ourselves: whether the system icon
        // pipeline returns themed or raw artwork varies with LaunchServices
        // cache state, so the About panel applies the continuous-corner mask
        // deterministically (radius ≈ 22.37% of the 56pt icon side).
        iconView.wantsLayer = YES;
        iconView.layer.cornerRadius = 56.0 * 0.2237;
        iconView.layer.cornerCurve = kCACornerCurveContinuous;
        iconView.layer.masksToBounds = YES;
        iconView.translatesAutoresizingMaskIntoConstraints = NO;

        NSTextField* titleLabel = [NSTextField labelWithString:@"Shenzhen PDF"];
        titleLabel.font = [NSFont systemFontOfSize:22.0 weight:NSFontWeightSemibold];
        titleLabel.alignment = NSTextAlignmentCenter;

        NSTextField* versionLabel =
            [NSTextField labelWithString:[NSString stringWithFormat:@"Version %@", [self displayVersion]]];
        versionLabel.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightRegular];
        versionLabel.textColor = SPDFCollectionColor(@"secondary");
        versionLabel.alignment = NSTextAlignmentCenter;

        NSTextField* aboutLabel =
            [NSTextField wrappingLabelWithString:@"Shenzhen PDF is an Open Source app in the spirit of Sumatra PDF, "
                                                 @"created by Raphaël Casimir, published by Intuition R&T."];
        aboutLabel.font = [NSFont systemFontOfSize:12.5];
        aboutLabel.alignment = NSTextAlignmentCenter;

        NSButton* okButton = [NSButton buttonWithTitle:@"OK" target:_aboutPanel action:@selector(orderOut:)];
        okButton.bezelStyle = NSBezelStyleRounded;
        okButton.keyEquivalent = @"\r";
        okButton.translatesAutoresizingMaskIntoConstraints = NO;

        NSButton* updateLink = nil;
        if (!spdf_is_sandboxed()) {
            updateLink = [NSButton buttonWithTitle:@"Check for Updates" target:self action:@selector(checkForUpdates:)];
            updateLink.bezelStyle = NSBezelStyleInline;
            updateLink.bordered = NO;
            updateLink.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightRegular];
            updateLink.contentTintColor = SPDFCollectionColor(@"accent");
            updateLink.translatesAutoresizingMaskIntoConstraints = NO;
            updateLink.accessibilityRole = NSAccessibilityButtonRole;
            updateLink.accessibilityLabel = @"Check for Updates";
        }

        NSMutableArray<NSView*>* views = [@[ iconView, titleLabel, versionLabel, aboutLabel, okButton ] mutableCopy];
        if (updateLink) [views addObject:updateLink];
        for (NSView* view in views) {
            view.translatesAutoresizingMaskIntoConstraints = NO;
            [content addSubview:view];
        }

        [NSLayoutConstraint activateConstraints:@[
            [iconView.topAnchor constraintEqualToAnchor:content.topAnchor constant:22.0],
            [iconView.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
            [iconView.widthAnchor constraintEqualToConstant:56.0],
            [iconView.heightAnchor constraintEqualToConstant:56.0],

            [titleLabel.topAnchor constraintEqualToAnchor:iconView.bottomAnchor constant:10.0],
            [titleLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24.0],
            [titleLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-24.0],

            [versionLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:4.0],
            [versionLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24.0],
            [versionLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-24.0],

            [aboutLabel.topAnchor constraintEqualToAnchor:versionLabel.bottomAnchor constant:14.0],
            [aboutLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:34.0],
            [aboutLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-34.0],

            [okButton.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
            [okButton.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-18.0],
            [okButton.widthAnchor constraintEqualToConstant:86.0],
        ]];

        if (updateLink) {
            [NSLayoutConstraint activateConstraints:@[
                [updateLink.topAnchor constraintGreaterThanOrEqualToAnchor:aboutLabel.bottomAnchor constant:12.0],
                [updateLink.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
                [okButton.topAnchor constraintEqualToAnchor:updateLink.bottomAnchor constant:12.0],
            ]];
        } else {
            [NSLayoutConstraint activateConstraints:@[
                [okButton.topAnchor constraintGreaterThanOrEqualToAnchor:aboutLabel.bottomAnchor constant:18.0],
            ]];
        }
    }

    if (_aboutPanel.parentWindow != _window) {
        [_aboutPanel.parentWindow removeChildWindow:_aboutPanel];
        if (_window) [_window addChildWindow:_aboutPanel ordered:NSWindowAbove];
    }

    if (_window) {
        NSRect windowFrame = _window.frame;
        NSRect panelFrame = _aboutPanel.frame;
        panelFrame.origin.x = NSMidX(windowFrame) - NSWidth(panelFrame) * 0.5;
        panelFrame.origin.y = NSMidY(windowFrame) - NSHeight(panelFrame) * 0.5;
        [_aboutPanel setFrame:panelFrame display:NO];
    } else {
        [_aboutPanel center];
    }

    [NSApp activateIgnoringOtherApps:YES];
    [_aboutPanel orderFrontRegardless];
    [_aboutPanel makeKeyAndOrderFront:nil];
}

- (NSButton*)buttonWithTitle:(NSString*)title action:(SEL)action {
    NSButton* button = [NSButton buttonWithTitle:title target:self action:action];
    button.bezelStyle = NSBezelStyleTexturedRounded;
    NSFont* font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightLight];
    button.font = font;
    button.cell.font = font;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                     forOrientation:NSLayoutConstraintOrientationHorizontal];
    return button;
}

- (void)pageSegmentsClicked:(id)sender {
    if (_pageSegments.selectedSegment == 0)
        [self previousPage:sender];
    else
        [self nextPage:sender];
}

- (void)zoomSegmentsClicked:(id)sender {
    if (_zoomSegments.selectedSegment == 0)
        [self zoomOut:sender];
    else
        [self zoomIn:sender];
}

- (void)findSegmentsClicked:(id)sender {
    if (_findSegments.selectedSegment == 0)
        [self findPrevious:sender];
    else
        [self findNext:sender];
}

- (void)markdownFontSizeSegmentsClicked:(id)sender {
    if (_markdownFontSizeSegments.selectedSegment == 0)
        [self decreaseMarkdownFontSize:sender];
    else
        [self increaseMarkdownFontSize:sender];
}

- (void)styleToolbarTextButton:(NSButton*)button {
    NSFont* font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightLight];
    NSMutableParagraphStyle* style = [[NSMutableParagraphStyle alloc] init];
    style.lineBreakMode = NSLineBreakByTruncatingTail;
    button.font = font;
    button.cell.font = font;
    button.cell.wraps = NO;
    button.cell.lineBreakMode = NSLineBreakByTruncatingTail;
    button.attributedTitle = [[NSAttributedString alloc] initWithString:button.title
                                                             attributes:@{
                                                                 NSFontAttributeName : font,
                                                                 NSForegroundColorAttributeName : SPDFCollectionColor(@"text"),
                                                                 NSParagraphStyleAttributeName : style,
                                                             }];
}

- (void)styleToolbarPanelButton:(NSButton*)button
                          title:(NSString*)title
                         active:(BOOL)active
                        tooltip:(NSString*)tooltip {
    button.state = NSControlStateValueOff;
    button.title = title;
    if ([button isKindOfClass:SPDFToolbarToggleButton.class]) ((SPDFToolbarToggleButton*)button).active = active;
    button.toolTip = tooltip;
}

- (void)addOverflowItemWithTitle:(NSString*)title
                          action:(SEL)action
                            menu:(NSMenu*)menu
                           state:(NSControlStateValue)state
                         enabled:(BOOL)enabled {
    NSMenuItem* item = [menu addItemWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    item.state = state;
    item.enabled = enabled;
}

- (void)addWindowArrangementItemsToMenu:(NSMenu*)menu includeKeyEquivalents:(BOOL)includeKeyEquivalents {
    NSEventModifierFlags modifiers = NSEventModifierFlagControl | NSEventModifierFlagFunction;
    NSDictionary* fillInfo = @{
        @"title" : @"Fill",
        @"action" : NSStringFromSelector(@selector(fillWindow:)),
        @"key" : includeKeyEquivalents ? @"f" : @""
    };
    NSDictionary* centerInfo = @{
        @"title" : @"Center",
        @"action" : NSStringFromSelector(@selector(centerWindowInScreen:)),
        @"key" : includeKeyEquivalents ? @"c" : @""
    };
    for (NSDictionary* itemInfo in @[ fillInfo, centerInfo ]) {
        NSMenuItem* item = [menu addItemWithTitle:itemInfo[@"title"]
                                           action:NSSelectorFromString(itemInfo[@"action"])
                                    keyEquivalent:itemInfo[@"key"]];
        item.target = self;
        if (includeKeyEquivalents) item.keyEquivalentModifierMask = modifiers;
    }

    NSMenuItem* moveResizeItem = [[NSMenuItem alloc] initWithTitle:@"Move & Resize Window"
                                                            action:nil
                                                     keyEquivalent:@""];
    NSMenu* moveResizeMenu = [[NSMenu alloc] initWithTitle:@"Move & Resize Window"];
    NSArray<NSDictionary*>* moveResizeActions = @[
        @{
            @"title" : @"Left Half",
            @"action" : NSStringFromSelector(@selector(moveWindowToLeftHalf:)),
            @"key" : includeKeyEquivalents ? [NSString stringWithFormat:@"%C", (unichar)NSLeftArrowFunctionKey] : @""
        },
        @{
            @"title" : @"Right Half",
            @"action" : NSStringFromSelector(@selector(moveWindowToRightHalf:)),
            @"key" : includeKeyEquivalents ? [NSString stringWithFormat:@"%C", (unichar)NSRightArrowFunctionKey] : @""
        },
        @{
            @"title" : @"Top Half",
            @"action" : NSStringFromSelector(@selector(moveWindowToTopHalf:)),
            @"key" : includeKeyEquivalents ? [NSString stringWithFormat:@"%C", (unichar)NSUpArrowFunctionKey] : @""
        },
        @{
            @"title" : @"Bottom Half",
            @"action" : NSStringFromSelector(@selector(moveWindowToBottomHalf:)),
            @"key" : includeKeyEquivalents ? [NSString stringWithFormat:@"%C", (unichar)NSDownArrowFunctionKey] : @""
        }
    ];
    for (NSDictionary* itemInfo in moveResizeActions) {
        NSMenuItem* item = [moveResizeMenu addItemWithTitle:itemInfo[@"title"]
                                                     action:NSSelectorFromString(itemInfo[@"action"])
                                              keyEquivalent:itemInfo[@"key"]];
        item.target = self;
        if (includeKeyEquivalents) item.keyEquivalentModifierMask = modifiers;
    }
    moveResizeItem.submenu = moveResizeMenu;
    [menu addItem:moveResizeItem];
}

- (void)rebuildToolbarOverflowMenuWithHiddenViews:(NSSet<NSView*>*)hiddenViews {
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Toolbar"];
    BOOL hasDoc = _doc != NULL;
    if ([hiddenViews containsObject:_ocrButton])
        [self addOverflowItemWithTitle:@"OCR Document..."
                                action:@selector(ocrDocument:)
                                  menu:menu
                                 state:NSControlStateValueOff
                               enabled:hasDoc && SPDFOCRPathSupported(_path)];
    if ([hiddenViews containsObject:_translateButton])
        [self addOverflowItemWithTitle:@"Translate..."
                                action:@selector(translateDocument:)
                                  menu:menu
                                 state:NSControlStateValueOff
                               enabled:spdf_translation_command_enabled([self translationContext])];
    if ([hiddenViews containsObject:_findRegexCheckbox])
        [self addOverflowItemWithTitle:@"Regex"
                                action:@selector(toggleFindRegex:)
                                  menu:menu
                                 state:_findRegexCheckbox.state
                               enabled:hasDoc];
    if ([hiddenViews containsObject:_findCountLabel] && _findCountLabel.stringValue.length > 0) {
        NSMenuItem* countItem = [menu addItemWithTitle:_findCountLabel.stringValue action:nil keyEquivalent:@""];
        countItem.enabled = NO;
    }
    if ([hiddenViews containsObject:_findSegments]) {
        [self addOverflowItemWithTitle:@"Find Previous"
                                action:@selector(findPrevious:)
                                  menu:menu
                                 state:NSControlStateValueOff
                               enabled:[_findSegments isEnabledForSegment:0]];
        [self addOverflowItemWithTitle:@"Find Next"
                                action:@selector(findNext:)
                                  menu:menu
                                 state:NSControlStateValueOff
                               enabled:[_findSegments isEnabledForSegment:1]];
    }
    if ([hiddenViews containsObject:_markdownFontSizeSegments]) {
        [self addOverflowItemWithTitle:@"Decrease Text Size"
                                action:@selector(decreaseMarkdownFontSize:)
                                  menu:menu
                                 state:NSControlStateValueOff
                               enabled:[_markdownFontSizeSegments isEnabledForSegment:0]];
        [self addOverflowItemWithTitle:@"Increase Text Size"
                                action:@selector(increaseMarkdownFontSize:)
                                  menu:menu
                                 state:NSControlStateValueOff
                               enabled:[_markdownFontSizeSegments isEnabledForSegment:1]];
    }
    [self addReadingThemeOverflowItemsToMenu:menu hiddenViews:hiddenViews];
    if ([hiddenViews containsObject:_fitModePopup] || [hiddenViews containsObject:_zoomSegments]) {
        [menu addItem:[NSMenuItem separatorItem]];
        if ([hiddenViews containsObject:_zoomSegments]) {
            [self addOverflowItemWithTitle:@"Zoom Out"
                                    action:@selector(zoomOut:)
                                      menu:menu
                                     state:NSControlStateValueOff
                                   enabled:[_zoomSegments isEnabledForSegment:0]];
            [self addOverflowItemWithTitle:@"Zoom In"
                                    action:@selector(zoomIn:)
                                      menu:menu
                                     state:NSControlStateValueOff
                                   enabled:[_zoomSegments isEnabledForSegment:1]];
        }
        [self addOverflowItemWithTitle:@"Actual Size"
                                action:@selector(actualSize:)
                                  menu:menu
                                 state:_fitMode == SPDFFitModeActual ? NSControlStateValueOn : NSControlStateValueOff
                               enabled:hasDoc];
        [self addOverflowItemWithTitle:@"Fit Width"
                                action:@selector(fitWidth:)
                                  menu:menu
                                 state:_fitMode == SPDFFitModeWidth ? NSControlStateValueOn : NSControlStateValueOff
                               enabled:hasDoc];
        [self addOverflowItemWithTitle:@"Fit Height"
                                action:@selector(fitHeight:)
                                  menu:menu
                                 state:_fitMode == SPDFFitModeHeight ? NSControlStateValueOn : NSControlStateValueOff
                               enabled:hasDoc];
        [self addOverflowItemWithTitle:@"Fit Page"
                                action:@selector(fitPage:)
                                  menu:menu
                                 state:_fitMode == SPDFFitModePage ? NSControlStateValueOn : NSControlStateValueOff
                               enabled:hasDoc];
    }
    spdf_apply_system_icons_to_menu(menu);
    _toolbarOverflowMenu = menu;
    _toolbarOverflowButton.enabled = menu.numberOfItems > 0;
}

- (void)showToolbarOverflowMenu:(id)sender {
    (void)sender;
    if (_toolbarOverflowMenu.numberOfItems == 0) return;
    NSEvent* event = NSApp.currentEvent;
    NSPoint point = NSMakePoint(0.0, NSHeight(_toolbarOverflowButton.bounds) + 2.0);
    if (event && event.window == _window)
        [NSMenu popUpContextMenu:_toolbarOverflowMenu withEvent:event forView:_toolbarOverflowButton];
    else
        [_toolbarOverflowMenu popUpMenuPositioningItem:nil atLocation:point inView:_toolbarOverflowButton];
}
- (void)updateToolbarOverflow {
    if (_suppressToolbarOverflowUpdates) return;
    [self collectionUpdateVersionIndicator];
    [self syncWorkspaceChrome];
}

- (void)buildWindow {
    NSScreen* screen = NSScreen.mainScreen;
    NSSize restoredSize = spdf_sane_window_content_size(_restoredWindowContentSize, screen);
    NSSize contentSize = NSEqualSizes(restoredSize, NSZeroSize) ? NSMakeSize(1120, 800) : restoredSize;
    _restoredWindowContentSize = contentSize;
    NSRect frame = _hasRestoredWindowFrame
                       ? spdf_sane_window_frame(_restoredWindowFrame, screen)
                       : NSMakeRect(floor(NSMidX(screen.visibleFrame) - contentSize.width / 2.0),
                                    floor(NSMidY(screen.visibleFrame) - contentSize.height / 2.0),
                                    contentSize.width, contentSize.height);
    double launchWindowStart = spdf_launch_profile_enabled() ? spdf_zoom_profile_now_ms() : 0.0;
    _window = [[SPDFWindow alloc] initWithContentRect:spdf_window_content_rect_for_saved_frame(frame)
                                            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                      NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
    if (launchWindowStart > 0.0)
        spdf_launch_profile_log(@"buildWindow.windowInit %.1fms", spdf_zoom_profile_now_ms() - launchWindowStart);
    _window.titleVisibility = NSWindowTitleHidden;
    _window.titlebarAppearsTransparent = YES;
    _window.styleMask |= NSWindowStyleMaskFullSizeContentView;
    _window.movable = NO;
    _window.movableByWindowBackground = NO;
    spdf_window_configure_document_window(_window, self, NSMakeSize(kMinWindowWidth, kMinWindowHeight),
                                          _restoredWindowFrame, _hasRestoredWindowFrame);

    SPDFDropView* content = [[SPDFDropView alloc] initWithFrame:frame];
    content.reader = self;
    [content registerForDraggedTypes:@[ NSPasteboardTypeFileURL ]];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    _window.contentView = content;

    // Window-first (default): show the styled empty window before any
    // controls exist; chrome and document fill in on the following display
    // cycles. SPDF_NO_WINDOW_FIRST=1 restores the single-frame launch.
    if (!getenv("SPDF_NO_WINDOW_FIRST")) {
        SPDFScopedLaunchPhaseLog launchPhase("orderFront(bare)");
        [_window makeKeyAndOrderFront:nil];
    }

    _tabStrip = [[SPDFTabStripView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(frame), kTabStripHeight)];
    _tabStrip.reader = self;
    _tabStrip.emptyGroups = [self emptyTabGroups]; _tabStrip.tabs = _tabs;
    _tabStrip.selectedIndex = _selectedTabIndex;
    _tabStrip.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:_tabStrip];
    [self updateTabStripFrame];
    if (launchWindowStart > 0.0)
        spdf_launch_profile_log(@"buildWindow.contentAndTabStrip done at %.1fms",
                                spdf_zoom_profile_now_ms() - launchWindowStart);

    _toolbar = [[SPDFToolbarStackView alloc] init];
    _toolbar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    _toolbar.alignment = NSLayoutAttributeCenterY;
    _toolbar.spacing = 4.0;
    _toolbar.edgeInsets = NSEdgeInsetsMake(7, 6, 7, 6);
    _toolbar.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:_toolbar];

    _pageSegments = spdf_paired_toolbar_segments(
        self, @selector(pageSegmentsClicked:),
        [NSImage imageWithSystemSymbolName:@"chevron.left" accessibilityDescription:@"Previous Page"],
        [NSImage imageWithSystemSymbolName:@"chevron.right" accessibilityDescription:@"Next Page"]);
    [_pageSegments setToolTip:@"Go to the previous page" forSegment:0];
    [_pageSegments setToolTip:@"Go to the next page" forSegment:1];
    _sidebarToggleButton = [[SPDFToolbarToggleButton alloc] initWithTitle:@"Side Panel"
                                                                   target:self
                                                                   action:@selector(toggleSidebar:)];
    _sidebarToggleButton.toolTip = @"Show or hide the side panel";
    _pageField = [[NSTextField alloc] init];
    _pageField.translatesAutoresizingMaskIntoConstraints = NO;
    _pageField.alignment = NSTextAlignmentRight;
    _pageField.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightRegular];
    _pageField.delegate = self;
    _pageField.target = self;
    _pageField.action = @selector(pageFieldChanged:);
    [_pageField.widthAnchor constraintEqualToConstant:50].active = YES;
    _pageCountLabel = [SPDFToolbarDragLabel labelWithString:@"/ 0"];
    _pageCountLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _zoomSegments = spdf_paired_toolbar_segments(
        self, @selector(zoomSegmentsClicked:),
        [NSImage imageWithSystemSymbolName:@"minus" accessibilityDescription:@"Zoom Out"],
        [NSImage imageWithSystemSymbolName:@"plus" accessibilityDescription:@"Zoom In"]);
    [_zoomSegments setToolTip:@"Zoom out" forSegment:0];
    [_zoomSegments setToolTip:@"Zoom in" forSegment:1];
    _markdownFontSizeSegments = spdf_paired_toolbar_segments(self, @selector(markdownFontSizeSegmentsClicked:),
                                                             spdf_markdown_font_size_toolbar_image(NO),
                                                             spdf_markdown_font_size_toolbar_image(YES));
    _markdownFontSizeSegments.hidden = YES; // text-renderer only; updateMarkdownFontControls reveals it
    [self buildReadingThemeToolbarButton]; // reading-theme toggle, right of the pill
    [self updateMarkdownFontControls];

    _fitModePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    NSArray<NSDictionary*>* fitItems = @[
        @{@"title" : @"100%", @"mode" : @(SPDFFitModeActual)},
        @{@"title" : @"Fit Width", @"mode" : @(SPDFFitModeWidth)},
        @{@"title" : @"Fit Height", @"mode" : @(SPDFFitModeHeight)},
        @{@"title" : @"Fit Page", @"mode" : @(SPDFFitModePage)}
    ];
    for (NSDictionary* item in fitItems) {
        [_fitModePopup addItemWithTitle:item[@"title"]];
        _fitModePopup.lastItem.tag = [item[@"mode"] integerValue];
    }
    _fitModePopup.target = self;
    _fitModePopup.action = @selector(fitModePopupChanged:);
    _fitModePopup.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightLight];
    _fitModePopup.cell.font = _fitModePopup.font;
    _fitModePopup.translatesAutoresizingMaskIntoConstraints = NO;
    spdf_fit_popup_select_and_size(_fitModePopup, nil);
    [_fitModePopup setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                            forOrientation:NSLayoutConstraintOrientationHorizontal];

    _searchField = [[SPDFFindSearchField alloc] init];
    _searchField.placeholderString = @"Find";
    _searchField.translatesAutoresizingMaskIntoConstraints = NO;
    _searchField.delegate = self;
    _searchField.target = nil;
    _searchField.action = NULL;
    NSTextFieldCell* searchCell = _searchField.cell;
    searchCell.usesSingleLineMode = YES;
    searchCell.scrollable = YES;
    searchCell.wraps = NO;
    searchCell.lineBreakMode = NSLineBreakByClipping;
    [_searchField.widthAnchor constraintGreaterThanOrEqualToConstant:88].active = YES;
    [_searchField.widthAnchor constraintLessThanOrEqualToConstant:141].active = YES;
    [_searchField setContentHuggingPriority:NSLayoutPriorityDefaultLow - 1
                             forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_searchField setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                           forOrientation:NSLayoutConstraintOrientationHorizontal];
    _findRegexCheckbox = SPDFWorkspaceRegexCheckbox(self,@selector(toggleFindRegex:));
    [self styleToolbarTextButton:_findRegexCheckbox];
    _findRegexCheckbox.translatesAutoresizingMaskIntoConstraints = NO;
    [_findRegexCheckbox.widthAnchor constraintEqualToConstant:68].active = YES;
    [_findRegexCheckbox setContentHuggingPriority:NSLayoutPriorityRequired
                                   forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_findRegexCheckbox setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                                 forOrientation:NSLayoutConstraintOrientationHorizontal];
    _ocrButton = [self buttonWithTitle:@"" action:@selector(ocrDocument:)];
    _ocrButton.image = spdf_ocr_toolbar_image();
    _ocrButton.imagePosition = NSImageOnly;
    _ocrButton.toolTip = @"Run OCR on this PDF";
    _ocrButton.accessibilityLabel = @"Run OCR";
    [_ocrButton.widthAnchor constraintEqualToConstant:32].active = YES;
    [_ocrButton setContentHuggingPriority:NSLayoutPriorityRequired
                           forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_ocrButton setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                         forOrientation:NSLayoutConstraintOrientationHorizontal];
    _translateButton = [self buttonWithTitle:@"" action:@selector(translateDocument:)];
    _translateButton.image = spdf_translate_toolbar_image();
    _translateButton.imagePosition = NSImageOnly;
    _translateButton.toolTip = @"Translate this document";
    _translateButton.accessibilityLabel = @"Translate Document";
    [_translateButton.widthAnchor constraintEqualToConstant:32].active = YES;
    [_translateButton setContentHuggingPriority:NSLayoutPriorityRequired
                                 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_translateButton setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                               forOrientation:NSLayoutConstraintOrientationHorizontal];
    _findSegments = spdf_paired_toolbar_segments(
        self, @selector(findSegmentsClicked:),
        [NSImage imageWithSystemSymbolName:@"chevron.left" accessibilityDescription:@"Previous Match"],
        [NSImage imageWithSystemSymbolName:@"chevron.right" accessibilityDescription:@"Next Match"]);
    [_findSegments setToolTip:@"Previous match" forSegment:0];
    [_findSegments setToolTip:@"Next match" forSegment:1];
    _minimapToggleButton = [[SPDFToolbarToggleButton alloc] initWithTitle:@"Map"
                                                                   target:self
                                                                   action:@selector(toggleMinimap:)];
    _minimapToggleButton.toolTip = @"Show or hide the minimap";
    _findCountLabel = [SPDFToolbarDragLabel labelWithString:@""];
    _findCountLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _findCountLabel.alignment = NSTextAlignmentCenter;
    _findCountLabel.textColor = SPDFCollectionColor(@"secondary");
    _findCountLabel.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
    // Wide enough for "1,234 / 5,678" and "12,345 matches…" while a search runs.
    [_findCountLabel.widthAnchor constraintGreaterThanOrEqualToConstant:64].active = YES;
    [_findCountLabel setContentHuggingPriority:NSLayoutPriorityRequired
                                forOrientation:NSLayoutConstraintOrientationHorizontal];

    _ocrSeparator = [[NSBox alloc] init];
    _ocrSeparator.boxType = NSBoxSeparator;
    _ocrSeparator.translatesAutoresizingMaskIntoConstraints = NO;
    [_ocrSeparator.widthAnchor constraintEqualToConstant:1].active = YES;

    _toolbarOverflowButton = [[SPDFToolbarMenuButton alloc] initWithFrame:NSZeroRect];
    _toolbarOverflowButton.target = self;
    _toolbarOverflowButton.action = @selector(showToolbarOverflowMenu:);
    _toolbarOverflowButton.toolTip = @"More toolbar actions";
    [_toolbarOverflowButton.widthAnchor constraintEqualToConstant:30].active = YES;
    _toolbarSpacer = [[SPDFToolbarDragView alloc] initWithFrame:NSZeroRect];
    _toolbarSpacer.translatesAutoresizingMaskIntoConstraints = NO;
    [_toolbarSpacer setContentHuggingPriority:NSLayoutPriorityDefaultLow + 1
                               forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_toolbarSpacer setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                             forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_toolbarSpacer.widthAnchor constraintGreaterThanOrEqualToConstant:0.0].active = YES;

    [_toolbar addArrangedSubview:_sidebarToggleButton];
    [_toolbar addArrangedSubview:_ocrButton];
    [_toolbar addArrangedSubview:_translateButton];
    [_toolbar addArrangedSubview:_ocrSeparator];
    [_toolbar addArrangedSubview:_pageField];
    [_toolbar addArrangedSubview:_pageCountLabel];
    [_toolbar addArrangedSubview:_pageSegments];
    [_toolbar addArrangedSubview:_fitModePopup];
    [_toolbar addArrangedSubview:_zoomSegments];
    [_toolbar addArrangedSubview:_markdownFontSizeSegments];
    [_toolbar addArrangedSubview:_readingThemeButton];
    [_toolbar addArrangedSubview:_searchField];
    [_toolbar addArrangedSubview:_findRegexCheckbox];
    [_toolbar addArrangedSubview:_findCountLabel];
    [_toolbar addArrangedSubview:_findSegments];
    [_toolbar addArrangedSubview:_toolbarSpacer];
    [_toolbar addArrangedSubview:_toolbarOverflowButton];
    [_toolbar addArrangedSubview:_minimapToggleButton];
    [_toolbar setCustomSpacing:8.0 afterView:_zoomSegments];
    [_toolbar setCustomSpacing:8.0 afterView:_readingThemeButton];
    [_toolbar setCustomSpacing:8.0 afterView:_searchField];

    if (launchWindowStart > 0.0)
        spdf_launch_profile_log(@"buildWindow.toolbar done at %.1fms", spdf_zoom_profile_now_ms() - launchWindowStart);
    _splitView = [[NSSplitView alloc] init];
    _splitView.vertical = YES;
    _splitView.dividerStyle = NSSplitViewDividerStyleThin;
    _splitView.delegate = self;
    _splitView.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:_splitView];

    _sidebarContainer = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 600)];
    _sidebarContainer.translatesAutoresizingMaskIntoConstraints = NO;
    _sidebarModeControl = [[SPDFSidebarNavigationControl alloc] init];
    spdf_sidebar_mode_control_configure(_sidebarModeControl, YES, NO); [self applySidebarWorkspaceState];
    _sidebarModeControl.target = self;
    _sidebarModeControl.action = @selector(sidebarModeChanged:);
    _sidebarModeControl.translatesAutoresizingMaskIntoConstraints = NO;
    [_sidebarContainer addSubview:_sidebarModeControl];

    _sidebarFilterField = [[NSSearchField alloc] init];
    _sidebarFilterField.placeholderString = @"Filter Chapters";
    _sidebarFilterField.delegate = self;
    _sidebarFilterField.translatesAutoresizingMaskIntoConstraints = NO;
    [_sidebarContainer addSubview:_sidebarFilterField];

    NSScrollView* sidebarScroll = [[NSScrollView alloc] init];
    sidebarScroll.hasVerticalScroller = YES;
    sidebarScroll.translatesAutoresizingMaskIntoConstraints = NO;
    [_sidebarContainer addSubview:sidebarScroll];

    _sidebarTable = [[SPDFSidebarTableView alloc] init];
    ((SPDFSidebarTableView*)_sidebarTable).reader = self;
    _sidebarTable.headerView = nil;
    _sidebarTable.rowHeight = 32.0;
    _sidebarTable.intercellSpacing = NSZeroSize;
    _sidebarTable.style = NSTableViewStylePlain;
    _sidebarTable.dataSource = self;
    _sidebarTable.delegate = self;
    _sidebarTable.target = self;
    _sidebarTable.action = @selector(activateSidebarRow:);
    _sidebarTable.doubleAction = @selector(activateSidebarRow:);
    NSMenu* sidebarMenu = [[NSMenu alloc] initWithTitle:@""];
    NSMenuItem* sidebarEditComment = [sidebarMenu addItemWithTitle:@"Edit Comment..."
                                                            action:@selector(editComment:)
                                                     keyEquivalent:@""];
    sidebarEditComment.target = self;
    NSMenuItem* sidebarDeleteComment = [sidebarMenu addItemWithTitle:@"Delete Comment..."
                                                              action:@selector(deleteComment:)
                                                       keyEquivalent:@""];
    sidebarDeleteComment.target = self;
    // Context-menu icons are invisible until a right-click opens the menu,
    // which cannot happen before the first paint; decorate off the critical
    // path (same policy as the main-menu SF symbols in buildMenu). If the
    // menu is somehow opened sooner, it works identically minus icons for
    // one open.
    spdf_mac_after_first_paint(^{ spdf_apply_system_icons_to_menu(sidebarMenu); });
    _sidebarTable.menu = sidebarMenu;
    NSTableColumn* column = [[NSTableColumn alloc] initWithIdentifier:@"title"];
    column.title = @"Title";
    column.width = 230.0;
    column.resizingMask = NSTableColumnAutoresizingMask;
    _sidebarTable.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    [_sidebarTable addTableColumn:column];
    sidebarScroll.documentView = _sidebarTable;

    _sidebarFilterTopConstraint =
        [_sidebarFilterField.topAnchor constraintEqualToAnchor:_sidebarModeControl.bottomAnchor constant:8];
    _sidebarScrollBelowFilterConstraint =
        [sidebarScroll.topAnchor constraintEqualToAnchor:_sidebarFilterField.bottomAnchor constant:8];
    _sidebarScrollBelowModeConstraint =
        [sidebarScroll.topAnchor constraintEqualToAnchor:_sidebarModeControl.bottomAnchor constant:8];
    _sidebarScrollBelowModeConstraint.active = NO;
    [NSLayoutConstraint activateConstraints:@[
        [_sidebarModeControl.topAnchor constraintEqualToAnchor:_sidebarContainer.topAnchor],
        [_sidebarModeControl.leadingAnchor constraintEqualToAnchor:_sidebarContainer.leadingAnchor constant:8],
        [_sidebarModeControl.trailingAnchor constraintEqualToAnchor:_sidebarContainer.trailingAnchor constant:-8],
        _sidebarFilterTopConstraint,
        [_sidebarFilterField.leadingAnchor constraintEqualToAnchor:_sidebarContainer.leadingAnchor constant:8],
        _sidebarScrollBelowFilterConstraint,
        [sidebarScroll.leadingAnchor constraintEqualToAnchor:_sidebarContainer.leadingAnchor],
        [sidebarScroll.trailingAnchor constraintEqualToAnchor:_sidebarContainer.trailingAnchor],
        [sidebarScroll.bottomAnchor constraintEqualToAnchor:_sidebarContainer.bottomAnchor]
    ]];

    [self installChapterOutlineControls];
    if (launchWindowStart > 0.0)
        spdf_launch_profile_log(@"buildWindow.sidebar done at %.1fms", spdf_zoom_profile_now_ms() - launchWindowStart);
    _pageScrollView = [[SPDFScrollView alloc] init];
    _pageScrollView.reader = self;
    // Custom clip view so horizontal panning can be locked on pages that fit the
    // viewport (see updateHorizontalScrollLockAnimated:).
    _pageScrollView.contentView = [[SPDFDocumentClipView alloc] init];
    _markerScroller = [[SPDFFindMarkerScroller alloc] initWithFrame:NSZeroRect];
    _markerScroller.reader = self;
    _pageScrollView.verticalScroller = _markerScroller;
    _pageScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _pageScrollView.hasVerticalScroller = !_presentationMode;
    _pageScrollView.hasHorizontalScroller = NO;
    _pageScrollView.usesPredominantAxisScrolling = NO;
    _pageScrollView.verticalScrollElasticity = NSScrollElasticityAllowed;
    _pageScrollView.horizontalScrollElasticity = NSScrollElasticityAllowed;
    _pageScrollView.autohidesScrollers = NO;
    _pageScrollView.borderType = NSNoBorder;
    _pageScrollView.drawsBackground = YES;
    _pageScrollView.contentView.drawsBackground = YES;
    _pageScrollView.contentView.postsBoundsChangedNotifications = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(clipViewBoundsChanged:)
                                                 name:NSViewBoundsDidChangeNotification
                                               object:_pageScrollView.contentView];

    _pageView = [self newDocumentView];
    _pageScrollView.documentView = _pageView;
    [self applyReadingThemeToDocumentViewport];

    _documentContainer = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
    _documentContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [_documentContainer addSubview:_pageScrollView];
    [_documentContainer addSubview:_toolbar];

    _minimapDividerView = [[SPDFMinimapDividerView alloc] init];
    _minimapDividerView.translatesAutoresizingMaskIntoConstraints = NO;
    _minimapDividerView.reader = self;
    [_documentContainer addSubview:_minimapDividerView];

    _minimapView = [[SPDFMinimapView alloc] init];
    _minimapView.themeVariant = self.markdownThemeVariant;
    _minimapView.translatesAutoresizingMaskIntoConstraints = NO;
    _minimapView.reader = self;
    _minimapView.wantsLayer = YES;
    [_documentContainer addSubview:_minimapView];
    _minimapWidthConstraint = [_minimapView.widthAnchor constraintEqualToConstant:_minimapWidth];
    _minimapDividerWidthConstraint = [_minimapDividerView.widthAnchor constraintEqualToConstant:SPDFPaneDividerHitWidth];
    _pageScrollToMinimapConstraint =
        [_pageScrollView.trailingAnchor constraintEqualToAnchor:_minimapView.leadingAnchor constant:-kMinimapDividerWidth];
    _pageScrollFullWidthConstraint =
        [_pageScrollView.trailingAnchor constraintEqualToAnchor:_documentContainer.trailingAnchor];
    _pageScrollFullWidthConstraint.active = NO;

    [NSLayoutConstraint activateConstraints:@[
        [_pageScrollView.topAnchor constraintEqualToAnchor:_toolbar.bottomAnchor],
        [_pageScrollView.leadingAnchor constraintEqualToAnchor:_documentContainer.leadingAnchor],
        [_pageScrollView.bottomAnchor constraintEqualToAnchor:_documentContainer.bottomAnchor],
        _pageScrollToMinimapConstraint,
        // Paint full height; divider hit testing leaves the native bottom resize zone passive.
        [_minimapDividerView.topAnchor constraintEqualToAnchor:_documentContainer.topAnchor],
        [_minimapDividerView.bottomAnchor constraintEqualToAnchor:_documentContainer.bottomAnchor],
        [_minimapDividerView.centerXAnchor constraintEqualToAnchor:_minimapView.leadingAnchor constant:-kMinimapDividerWidth/2],
        _minimapDividerWidthConstraint, [_minimapView.topAnchor constraintEqualToAnchor:_toolbar.bottomAnchor],
        [_minimapView.trailingAnchor constraintEqualToAnchor:_documentContainer.trailingAnchor],
        [_minimapView.bottomAnchor constraintEqualToAnchor:_documentContainer.bottomAnchor], _minimapWidthConstraint
    ]];
    [self installMarkdownHostInDocumentContainer];

    [_splitView addSubview:_sidebarContainer];
    [_splitView addSubview:_documentContainer];

    _sidebarDividerView = [[SPDFSidebarDividerView alloc] init];
    _sidebarDividerView.translatesAutoresizingMaskIntoConstraints = NO;
    _sidebarDividerView.reader = self;
    [content addSubview:_sidebarDividerView positioned:NSWindowAbove relativeTo:_splitView];

    _statusLabel = [NSTextField labelWithString:@"Ready"];
    _statusLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;

    _tabStripHeightConstraint = [_tabStrip.heightAnchor constraintEqualToConstant:kTabStripHeight];
    _toolbarHeightConstraint = [_toolbar.heightAnchor constraintEqualToConstant:36.0];
    [NSLayoutConstraint activateConstraints:@[
        [_tabStrip.topAnchor constraintEqualToAnchor:content.topAnchor],
        [_tabStrip.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [_tabStrip.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-44], _tabStripHeightConstraint,
        [_toolbar.topAnchor constraintEqualToAnchor:_documentContainer.topAnchor],
        [_toolbar.leadingAnchor constraintEqualToAnchor:_documentContainer.leadingAnchor],
        _toolbarHeightConstraint,
        [_splitView.topAnchor constraintEqualToAnchor:_tabStrip.bottomAnchor],
        [_splitView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [_splitView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [_splitView.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
        [_sidebarDividerView.topAnchor constraintEqualToAnchor:_splitView.topAnchor],
        [_sidebarDividerView.bottomAnchor constraintEqualToAnchor:_splitView.bottomAnchor],
        [_sidebarDividerView.widthAnchor constraintEqualToConstant:kSidebarDividerWidth],
        [_sidebarDividerView.centerXAnchor constraintEqualToAnchor:_sidebarContainer.trailingAnchor]
    ]];

    [self installWorkspaceChrome];
    if (launchWindowStart > 0.0)
        spdf_launch_profile_log(@"buildWindow.viewsAndConstraints done at %.1fms",
                                spdf_zoom_profile_now_ms() - launchWindowStart);
    // Suppress toolbar-overflow recomputation (toolbar layout + fittingSize
    // solves) from here through the startup document work; see the single
    // pass in applicationDidFinishLaunching. Nothing in between is displayed.
    _suppressToolbarOverflowUpdates = YES;
    {
        SPDFScopedLaunchPhaseLog launchPhase("buildWindow.finalSync.restoreSidebarWidth");
        [self restoreSidebarWidth];
    }
    if (!_sidebarPreferredVisible) [self setSidebarActuallyVisible:NO];
    {
        SPDFScopedLaunchPhaseLog launchPhase("buildWindow.finalSync.setMinimapActuallyVisible");
        [self setMinimapActuallyVisible:_minimapPreferredVisible];
    }
    {
        SPDFScopedLaunchPhaseLog launchPhase("buildWindow.finalSync.syncToolbarState");
        [self syncToolbarState];
    }
    {
        SPDFScopedLaunchPhaseLog launchPhase("buildWindow.finalSync.updateControls");
        [self updateControls];
    }
    if (launchWindowStart > 0.0)
        spdf_launch_profile_log(@"buildWindow.finalSync done at %.1fms",
                                spdf_zoom_profile_now_ms() - launchWindowStart);
}

- (CGFloat)backingScale {
    CGFloat scale = _window.backingScaleFactor;
    if (scale <= 0) scale = NSScreen.mainScreen.backingScaleFactor;
    return scale > 0 ? scale : 1.0;
}

- (NSSize)documentClipSizeForLayout {
    NSSize size = _pageScrollView.contentSize;
    if (size.width <= 1.0 || size.height <= 1.0) size = _pageScrollView.contentView.frame.size;
    if (size.width <= 1.0 || size.height <= 1.0) size = _pageScrollView.contentView.bounds.size;
    if (size.width <= 1.0) size.width = NSWidth(_documentContainer.bounds);
    if (size.height <= 1.0) size.height = NSHeight(_documentContainer.bounds);
    return size;
}

- (SPDFRenderedPage*)renderedPageAtIndex:(NSInteger)pageIndex
                                document:(spdf_document*)doc
                                    zoom:(CGFloat)zoom
                            displayScale:(CGFloat)displayScale
                                   error:(char*)err
                             errorLength:(size_t)errLen {
    return [self renderedPageAtIndex:pageIndex
                            document:doc
                                zoom:zoom
                        displayScale:displayScale
                         renderToken:NULL
                               error:err
                         errorLength:errLen];
}

- (SPDFRenderedPage*)renderedPageAtIndex:(NSInteger)pageIndex
                                document:(spdf_document*)doc
                                    zoom:(CGFloat)zoom
                            displayScale:(CGFloat)displayScale
                             renderToken:(spdf_render_token*)renderToken
                                   error:(char*)err
                             errorLength:(size_t)errLen {
    float pageWidth = 0;
    float pageHeight = 0;
    if (!spdf_page_size(doc, (int)pageIndex, &pageWidth, &pageHeight, err, errLen)) return nil;

    displayScale = displayScale > 0 ? displayScale : 1.0;
    CGFloat requestedDisplayScale = displayScale;
    CGFloat renderDisplayScale = [self renderDisplayScaleForPageWidth:pageWidth
                                                           pageHeight:pageHeight
                                                                 zoom:zoom
                                                         displayScale:requestedDisplayScale];
    if (renderDisplayScale <= 0.0) {
        if (err && errLen > 0) snprintf(err, errLen, "%s", "Rendered page would be too large.");
        return nil;
    }

    double profileStart = spdf_zoom_profile_enabled() ? spdf_zoom_profile_now_ms() : 0.0;
    spdf_bitmap bitmap;
    unsigned renderFlags = [self readingThemeRenderFlags];
    if (!spdf_render_page_rgba_opts(doc, (int)pageIndex, (float)(zoom * renderDisplayScale), renderFlags, renderToken,
                                    &bitmap, err, errLen))
        return nil;
    if (spdf_zoom_profile_enabled()) {
        double elapsed = spdf_zoom_profile_now_ms() - profileStart;
        spdf_zoom_profile_log(@"renderFullPage page=%ld zoom=%.2f scale=%.2f px=%dx%d bytes=%dMB %.1fms [%s]",
                              (long)pageIndex, zoom, renderDisplayScale, bitmap.width, bitmap.height,
                              (int)(((long long)bitmap.stride * bitmap.height) / (1024 * 1024)), elapsed,
                              NSThread.isMainThread ? "MAIN" : "bg");
    }

    NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                    pixelsWide:bitmap.width
                                                                    pixelsHigh:bitmap.height
                                                                 bitsPerSample:8
                                                               samplesPerPixel:4
                                                                      hasAlpha:YES
                                                                      isPlanar:NO
                                                                colorSpaceName:NSDeviceRGBColorSpace
                                                                   bytesPerRow:bitmap.stride
                                                                  bitsPerPixel:32];
    if (!rep || !rep.bitmapData) {
        spdf_free_bitmap(&bitmap);
        if (err && errLen > 0) snprintf(err, errLen, "%s", "Could not allocate page bitmap.");
        return nil;
    }
    memcpy(rep.bitmapData, bitmap.rgba, (size_t)bitmap.stride * (size_t)bitmap.height);

    NSSize pointSize = NSMakeSize((CGFloat)pageWidth * zoom, (CGFloat)pageHeight * zoom);
    if (!isfinite(pointSize.width) || !isfinite(pointSize.height) || pointSize.width <= 0.0 || pointSize.height <= 0.0)
        pointSize = NSMakeSize((CGFloat)bitmap.width / MAX(0.01, renderDisplayScale),
                               (CGFloat)bitmap.height / MAX(0.01, renderDisplayScale));
    rep.size = pointSize;
    NSImage* image = [[NSImage alloc] initWithSize:pointSize];
    if (!image) {
        spdf_free_bitmap(&bitmap);
        if (err && errLen > 0) snprintf(err, errLen, "%s", "Could not allocate page image.");
        return nil;
    }
    [image addRepresentation:rep];
    spdf_free_bitmap(&bitmap);

    SPDFRenderedPage* page = [[SPDFRenderedPage alloc] init];
    page.pageIndex = pageIndex;
    page.pageWidth = pageWidth;
    page.pageHeight = pageHeight;
    page.imagePointWidth = pointSize.width;
    page.imagePointHeight = pointSize.height;
    page.imageZoom = zoom;
    page.imageScale = requestedDisplayScale;
    [self stampReadingThemeOnRenderedPage:page renderFlags:renderFlags];
    page.image = image;
    page.highlights = @[];
    page.selectionRects = @[];
    return page;
}

static BOOL spdf_page_list_cache_disabled(void) {
    static BOOL disabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      disabled = getenv("SPDF_DISABLE_LIST_CACHE") != NULL;
    });
    return disabled;
}

- (NSImage*)renderedPageCropImageAtIndex:(NSInteger)pageIndex
                                document:(spdf_document*)doc
                                    zoom:(CGFloat)zoom
                            displayScale:(CGFloat)displayScale
                            pageCropRect:(NSRect)pageCropRect
                                 useList:(BOOL)useList
                                   error:(char*)err
                             errorLength:(size_t)errLen {
    return [self renderedPageCropImageAtIndex:pageIndex
                                     document:doc
                                         zoom:zoom
                                 displayScale:displayScale
                                 pageCropRect:pageCropRect
                                      useList:useList
                                  renderToken:NULL
                                        error:err
                                  errorLength:errLen];
}

- (NSImage*)renderedPageCropImageAtIndex:(NSInteger)pageIndex
                                document:(spdf_document*)doc
                                    zoom:(CGFloat)zoom
                            displayScale:(CGFloat)displayScale
                            pageCropRect:(NSRect)pageCropRect
                                 useList:(BOOL)useList
                             renderToken:(spdf_render_token*)renderToken
                                   error:(char*)err
                             errorLength:(size_t)errLen {
    if (NSIsEmptyRect(pageCropRect)) return nil;
    spdf_rect crop;
    crop.x0 = (float)NSMinX(pageCropRect);
    crop.y0 = (float)NSMinY(pageCropRect);
    crop.x1 = (float)NSMaxX(pageCropRect);
    crop.y1 = (float)NSMaxY(pageCropRect);

    if (spdf_page_list_cache_disabled()) useList = NO;
    unsigned renderFlags = (useList ? SPDF_RENDER_USE_PAGE_LIST : SPDF_RENDER_DEFAULT) | [self readingThemeRenderFlags];
    double profileStart = spdf_zoom_profile_enabled() ? spdf_zoom_profile_now_ms() : 0.0;
    spdf_bitmap bitmap;
    if (!spdf_render_page_region_rgba_opts(doc, (int)pageIndex, (float)(zoom * displayScale), crop, renderFlags,
                                           renderToken, &bitmap, err, errLen))
        return nil;
    if (spdf_zoom_profile_enabled()) {
        double elapsed = spdf_zoom_profile_now_ms() - profileStart;
        spdf_render_stats stats = spdf_last_render_stats(doc);
        const char* listState = stats.used_list ? (stats.built_list ? "build" : "hit") : "off";
        spdf_zoom_profile_log(@"renderCrop page=%ld zoom=%.2f px=%dx%d bytes=%dMB %.1fms [%s] list=%s build=%.0fms",
                              (long)pageIndex, zoom, bitmap.width, bitmap.height,
                              (int)(((long long)bitmap.stride * bitmap.height) / (1024 * 1024)), elapsed,
                              NSThread.isMainThread ? "MAIN" : "bg", listState, stats.build_ms);
    }

    NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                    pixelsWide:bitmap.width
                                                                    pixelsHigh:bitmap.height
                                                                 bitsPerSample:8
                                                               samplesPerPixel:4
                                                                      hasAlpha:YES
                                                                      isPlanar:NO
                                                                colorSpaceName:NSDeviceRGBColorSpace
                                                                   bytesPerRow:bitmap.stride
                                                                  bitsPerPixel:32];
    if (!rep || !rep.bitmapData) {
        spdf_free_bitmap(&bitmap);
        if (err && errLen > 0) snprintf(err, errLen, "%s", "Could not allocate page crop bitmap.");
        return nil;
    }
    memcpy(rep.bitmapData, bitmap.rgba, (size_t)bitmap.stride * (size_t)bitmap.height);
    spdf_free_bitmap(&bitmap);

    NSSize pointSize = NSMakeSize(NSWidth(pageCropRect) * zoom, NSHeight(pageCropRect) * zoom);
    rep.size = pointSize;
    NSImage* image = [[NSImage alloc] initWithSize:pointSize];
    if (!image) {
        if (err && errLen > 0) snprintf(err, errLen, "%s", "Could not allocate page crop image.");
        return nil;
    }
    [image addRepresentation:rep];
    return image;
}

- (SPDFRenderedPage*)renderedPageAtIndex:(NSInteger)pageIndex error:(char*)err errorLength:(size_t)errLen {
    return [self renderedPageAtIndex:pageIndex
                            document:_doc
                                zoom:_zoom
                        displayScale:[self backingScale]
                               error:err
                         errorLength:errLen];
}

- (SPDFRenderedPage*)placeholderPageAtIndex:(NSInteger)pageIndex
                                   document:(spdf_document*)doc
                              fallbackWidth:(CGFloat)fallbackWidth
                             fallbackHeight:(CGFloat)fallbackHeight {
    CGFloat pageWidth = fallbackWidth;
    CGFloat pageHeight = fallbackHeight;
    if (doc) {
        char err[256];
        float nativeWidth = 0;
        float nativeHeight = 0;
        if (spdf_page_size(doc, (int)pageIndex, &nativeWidth, &nativeHeight, err, sizeof(err)) && nativeWidth > 0 &&
            nativeHeight > 0) {
            pageWidth = nativeWidth;
            pageHeight = nativeHeight;
        }
    }

    SPDFRenderedPage* page = [[SPDFRenderedPage alloc] init];
    page.pageIndex = pageIndex;
    page.pageWidth = pageWidth;
    page.pageHeight = pageHeight;
    page.highlights = @[];
    page.selectionRects = @[];
    return page;
}

- (spdf_document*)workerDocumentForPath:(NSString*)path
                             sourcePath:(NSString*)sourcePath
                                  error:(char*)err
                            errorLength:(size_t)errLen {
    if (!path.length || !sourcePath.length) return NULL;

    NSDictionary* attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    NSDate* modificationDate = attributes[NSFileModificationDate];
    unsigned long long fileSize = [attributes[NSFileSize] unsignedLongLongValue];
    NSString* standardizedPath = path.stringByStandardizingPath ?: path;
    NSString* credentialToken = [SPDFPasswordCredentialStore.sharedStore cacheTokenForSourcePath:sourcePath];
    NSString* cacheKey =
        modificationDate ? [NSString stringWithFormat:@"%@:%llu:%.6f:%@", standardizedPath, fileSize,
                                                      modificationDate.timeIntervalSinceReferenceDate, credentialToken]
                         : [NSString stringWithFormat:@"%@:%@", standardizedPath, credentialToken];

    NSMutableDictionary* threadDictionary = NSThread.currentThread.threadDictionary;
    SPDFWorkerDocument* holder = threadDictionary[@"ShenzhenPDFWorkerDocument"];
    if (holder && [holder.cacheKey isEqualToString:cacheKey] && holder.document) return holder.document;

    holder = [[SPDFWorkerDocument alloc] init];
    holder.path = path;
    holder.cacheKey = cacheKey;
    spdf_open_status status = SPDF_OPEN_ERROR;
    holder.document = [self openSpdfDocumentAtPath:path
                                        sourcePath:sourcePath
                                            status:&status
                                             error:err
                                       errorLength:errLen];
    if (!holder.document) return NULL;
    threadDictionary[@"ShenzhenPDFWorkerDocument"] = holder;
    return holder.document;
}

- (NSArray<NSNumber*>*)pageRenderOrderForCount:(NSInteger)pageCount
                                 preferredPage:(NSInteger)preferredPage
                                      maxPages:(NSInteger)maxPages {
    if (pageCount <= 0 || maxPages <= 0) return @[];
    NSMutableArray<NSNumber*>* order = [NSMutableArray arrayWithCapacity:(NSUInteger)MIN(pageCount, maxPages)];
    if (preferredPage >= 0 && preferredPage < pageCount) [order addObject:@(preferredPage)];
    for (NSInteger distance = 1; distance < pageCount && (NSInteger)order.count < maxPages; ++distance) {
        NSInteger after = preferredPage + distance;
        NSInteger before = preferredPage - distance;
        if (after < pageCount && (NSInteger)order.count < maxPages) [order addObject:@(after)];
        if (before >= 0 && (NSInteger)order.count < maxPages) [order addObject:@(before)];
    }
    return order;
}

- (NSOperationQueuePriority)queuePriorityForRenderDistance:(NSInteger)distance {
    if (distance <= 2) return NSOperationQueuePriorityVeryHigh;
    if (distance <= 6) return NSOperationQueuePriorityHigh;
    if (distance <= 18) return NSOperationQueuePriorityNormal;
    return NSOperationQueuePriorityLow;
}

- (BOOL)renderedPageImage:(SPDFRenderedPage*)page matchesZoom:(CGFloat)zoom displayScale:(CGFloat)displayScale {
    if (!page.image) return NO;
    if (![self renderedPageMatchesReadingTheme:page]) return NO;
    return fabs(page.imageZoom - zoom) <= 0.001 && fabs(page.imageScale - displayScale) <= 0.001;
}

- (BOOL)minimapThumbnailImage:(SPDFRenderedPage*)page matchesZoom:(CGFloat)zoom displayScale:(CGFloat)displayScale {
    if (!page.minimapImage) return NO;
    return fabs(page.minimapImageZoom - zoom) <= 0.01 && fabs(page.minimapImageScale - displayScale) <= 0.01;
}

- (void)copyMinimapThumbnailFromPage:(SPDFRenderedPage*)source toPage:(SPDFRenderedPage*)destination {
    if (!source || !destination) return;
    destination.minimapImage = source.minimapImage;
    destination.minimapImageZoom = source.minimapImageZoom;
    destination.minimapImageScale = source.minimapImageScale;
    destination.baseImage = source.baseImage;
    destination.baseImagePointWidth = source.baseImagePointWidth;
    destination.baseImagePointHeight = source.baseImagePointHeight;
    destination.baseImageZoom = source.baseImageZoom;
    destination.baseImageScale = source.baseImageScale;
    destination.highQualityImage = source.highQualityImage;
    destination.highQualityImagePointWidth = source.highQualityImagePointWidth;
    destination.highQualityImagePointHeight = source.highQualityImagePointHeight;
    destination.highQualityImageZoom = source.highQualityImageZoom;
    destination.highQualityImageScale = source.highQualityImageScale;
}

- (NSArray<NSNumber*>*)pageNeighborhoodIndexesAroundPage:(NSInteger)pageIndex {
    return [self pageNeighborhoodIndexesAroundPage:pageIndex radius:1];
}

- (NSArray<NSNumber*>*)pageNeighborhoodIndexesAroundPage:(NSInteger)pageIndex radius:(NSInteger)radius {
    if (_renderedPages.count == 0) return @[];
    pageIndex = MAX(0, MIN(pageIndex, (NSInteger)_renderedPages.count - 1));
    radius = MAX(0, radius);
    // Center-out order so the nearest neighbours render first under the
    // distance-priority queue.
    NSMutableArray<NSNumber*>* indexes = [NSMutableArray arrayWithCapacity:(NSUInteger)(2 * radius + 1)];
    [indexes addObject:@(pageIndex)];
    for (NSInteger d = 1; d <= radius; ++d) {
        if (pageIndex + d < (NSInteger)_renderedPages.count) [indexes addObject:@(pageIndex + d)];
        if (pageIndex - d >= 0) [indexes addObject:@(pageIndex - d)];
    }
    return indexes;
}

- (NSArray<NSNumber*>*)currentPageNeighborhoodIndexes {
    return [self pageNeighborhoodIndexesAroundPage:_pageIndex];
}

- (void)addPageNeighborhoodAroundPage:(NSInteger)pageIndex toOrderedSet:(NSMutableOrderedSet<NSNumber*>*)set {
    if (!set || pageIndex < 0 || _renderedPages.count == 0) return;
    for (NSNumber* number in [self pageNeighborhoodIndexesAroundPage:pageIndex]) [set addObject:number];
}

- (NSArray<NSNumber*>*)liveZoomSeedPageIndexesForAnchorPage:(NSInteger)anchorPageIndex {
    NSMutableOrderedSet<NSNumber*>* indexes = [NSMutableOrderedSet orderedSet];
    [self addPageNeighborhoodAroundPage:anchorPageIndex toOrderedSet:indexes];
    [self addPageNeighborhoodAroundPage:_pageIndex toOrderedSet:indexes];
    [self addPageNeighborhoodAroundPage:_pageView.currentPageIndex toOrderedSet:indexes];
    NSInteger preferredPage = -1;
    for (NSNumber* visiblePage in [self visibleDocumentPageIndexesWithExtraRadius:1 preferredPage:&preferredPage])
        [indexes addObject:visiblePage];
    [self addPageNeighborhoodAroundPage:preferredPage toOrderedSet:indexes];
    return indexes.array;
}

- (void)clearLiveZoomSeeds {
    for (SPDFRenderedPage* page in _renderedPages ?: @[]) {
        page.zoomSeedImage = nil;
        page.zoomSeedPageRect = NSZeroRect;
        page.zoomSeedZoom = 0.0;
        page.zoomSeedScale = 0.0;
    }
}

- (void)setZoomSeedForPage:(SPDFRenderedPage*)page
                     image:(NSImage*)image
                  pageRect:(NSRect)pageRect
                      zoom:(CGFloat)zoom
              displayScale:(CGFloat)displayScale {
    if (!page || !image || NSIsEmptyRect(pageRect)) return;
    page.zoomSeedImage = image;
    page.zoomSeedPageRect = pageRect;
    page.zoomSeedZoom = zoom;
    page.zoomSeedScale = displayScale;
}

- (void)prepareLiveZoomSeedsForPageIndexes:(NSArray<NSNumber*>*)pageIndexes {
    for (NSNumber* number in pageIndexes) {
        NSInteger pageIndex = number.integerValue;
        if (pageIndex < 0 || pageIndex >= (NSInteger)_renderedPages.count) continue;
        SPDFRenderedPage* page = _renderedPages[(NSUInteger)pageIndex];
        page.zoomSeedImage = nil;
        page.zoomSeedPageRect = NSZeroRect;
        page.zoomSeedZoom = 0.0;
        page.zoomSeedScale = 0.0;
    }
    CGFloat backingScale = [self backingScale];
    for (NSNumber* number in pageIndexes) {
        NSInteger pageIndex = number.integerValue;
        if (pageIndex < 0 || pageIndex >= (NSInteger)_renderedPages.count) continue;
        SPDFRenderedPage* page = _renderedPages[(NSUInteger)pageIndex];
        NSRect fullPageRect = NSMakeRect(0.0, 0.0, page.pageWidth, page.pageHeight);
        if (page.highQualityImage &&
            [self renderedHighQualityImageByteCost:page] <= kHighQualityZoomCacheMaxPageBytes) {
            [self setZoomSeedForPage:page
                               image:page.highQualityImage
                            pageRect:fullPageRect
                                zoom:page.highQualityImageZoom
                        displayScale:page.highQualityImageScale];
        } else if ([self renderedPageImage:page matchesZoom:_zoom displayScale:backingScale]) {
            [self setZoomSeedForPage:page
                               image:page.image
                            pageRect:fullPageRect
                                zoom:page.imageZoom
                        displayScale:page.imageScale];
        } else if (page.viewportImage && !NSIsEmptyRect(page.viewportImagePageRect) &&
                   fabs(page.viewportImageZoom - _zoom) <= 0.001) {
            [self setZoomSeedForPage:page
                               image:page.viewportImage
                            pageRect:page.viewportImagePageRect
                                zoom:page.viewportImageZoom
                        displayScale:page.viewportImageScale];
        } else if (page.image && [self renderedImageByteCost:page] <= kRenderedImageTargetByteLimit / 2) {
            [self setZoomSeedForPage:page
                               image:page.image
                            pageRect:fullPageRect
                                zoom:page.imageZoom
                        displayScale:page.imageScale];
        } else if (page.baseImage) {
            [self setZoomSeedForPage:page
                               image:page.baseImage
                            pageRect:fullPageRect
                                zoom:page.baseImageZoom
                        displayScale:page.baseImageScale];
        }
    }
}

- (BOOL)basePageImage:(SPDFRenderedPage*)page matchesDisplayScale:(CGFloat)displayScale {
    if (!page.baseImage) return NO;
    return fabs(page.baseImageZoom - kBaseZoomCacheZoom) <= 0.001 && fabs(page.baseImageScale - displayScale) <= 0.001;
}

- (CGFloat)highQualityZoomCacheDisplayScale {
    return MAX(1.0, [self backingScale]);
}

- (BOOL)highQualityPageImage:(SPDFRenderedPage*)page matchesZoom:(CGFloat)zoom displayScale:(CGFloat)displayScale {
    if (!page.highQualityImage) return NO;
    return fabs(page.highQualityImageZoom - zoom) <= 0.001 && fabs(page.highQualityImageScale - displayScale) <= 0.001;
}

// Prefetch radius scaled to zoom: keep roughly two viewports of pages rendered
// on each side. Zoomed out (small pages, many per screen, fast page turnover) →
// a wide radius; zoomed in (a page taller than the viewport) → as few as ±2.
// Capped at the eviction keep window so nothing is rendered just to be dropped,
// and zoomed-out renders are individually small (fewer pixels) so the wider
// radius does not blow up memory.
- (NSInteger)zoomScaledNeighborhoodRenderRadius {
    if (_renderedPages.count == 0) return 2;
    CGFloat viewportHeight = NSHeight(_pageScrollView.contentView.bounds);
    NSRect pageRect = [_pageView rectForPageAtIndex:_pageIndex];
    CGFloat pageHeight = NSHeight(pageRect);
    if (viewportHeight < 1.0 || pageHeight < 1.0) return 2;
    CGFloat pagesPerViewport = viewportHeight / pageHeight;
    NSInteger radius = (NSInteger)ceil(pagesPerViewport * 2.0) + 1;
    return MAX(2, MIN(radius, kRenderedImageKeepRadius));
}

- (void)enqueueCurrentPageNeighborhoodRendersForGeneration:(NSUInteger)generation
                                             preferredPage:(NSInteger)preferredPage
                                         forceHighPriority:(BOOL)forceHighPriority {
    // Zoom-scaled radius so the pages about to scroll into view are already
    // resident; eviction keeps a ±kRenderedImageKeepRadius window plus all queued
    // pages, so nothing is rendered just to be dropped.
    NSArray<NSNumber*>* pages = [self pageNeighborhoodIndexesAroundPage:preferredPage
                                                                 radius:[self zoomScaledNeighborhoodRenderRadius]];
    [self enqueuePageRendersForGeneration:generation
                              pageIndexes:pages
                            preferredPage:preferredPage
                        forceHighPriority:forceHighPriority];
}

// Largest displayScale at which the whole page (at `zoom`) still renders within
// `byteLimit` and the max bitmap dimension. Used to give an oversized page —
// whose full-resolution render is over budget — the highest-resolution
// whole-page "navigation base" it can have. Returns 0 if even a tiny render
// would not fit (shouldn't happen for real pages).
- (CGFloat)cappedFullPageDisplayScaleForPage:(SPDFRenderedPage*)page
                                        zoom:(CGFloat)zoom
                                   byteLimit:(NSUInteger)byteLimit {
    if (!page || page.pageWidth <= 0.0 || page.pageHeight <= 0.0 || zoom <= 0.0) return 0.0;
    double w = (double)page.pageWidth * (double)zoom;
    double h = (double)page.pageHeight * (double)zoom;
    if (w <= 0.0 || h <= 0.0) return 0.0;
    double byteScale = sqrt((double)byteLimit / 4.0 / (w * h));
    double dimScale = MIN((double)kMaxRenderedPageBitmapDimension / w, (double)kMaxRenderedPageBitmapDimension / h);
    double s = MIN(byteScale, dimScale) * 0.97; // safety for ceil()/+2 padding in the budget check
    if (!isfinite(s) || s <= 0.0) return 0.0;
    // Guarantee the renderer accepts it — renderDisplayScaleForPageWidth: bails if
    // the padded bitmap is even one pixel over the exact limit.
    for (int i = 0; i < 8 && [self renderDisplayScaleForPageWidth:page.pageWidth
                                                       pageHeight:page.pageHeight
                                                             zoom:zoom
                                                     displayScale:s] <= 0.0;
         ++i)
        s *= 0.9;
    return [self renderDisplayScaleForPageWidth:page.pageWidth pageHeight:page.pageHeight zoom:zoom
                                   displayScale:s] > 0.0
               ? s
               : 0.0;
}

- (void)enqueueBaseZoomCacheForPageIndexes:(NSArray<NSNumber*>*)pageIndexes
                          renderGeneration:(NSUInteger)generation
                             preferredPage:(NSInteger)preferredPage
                              seedPriority:(BOOL)seedPriority {
    if (!_doc || !_path.length || pageIndexes.count == 0) return;

    NSString* path = [_path copy];
    // Render workers open the working path (temp copy for a read-only source);
    // the staleness guard still compares against the SOURCE _path.
    NSString* workingPath = [self activeWorkingPath];
    CGFloat displayScale = kBaseZoomCacheDisplayScale;
    NSUInteger scheduledBytes = 0;
    for (SPDFRenderedPage* page in _renderedPages) scheduledBytes += [self renderedBaseImageByteCost:page];

    for (NSNumber* number in pageIndexes) {
        NSInteger index = number.integerValue;
        if (index < 0 || index >= (NSInteger)_renderedPages.count) continue;
        SPDFRenderedPage* existing = _renderedPages[(NSUInteger)index];
        // Normal pages cache a whole-page base at kBaseZoomCacheDisplayScale. An
        // oversized page (full render over budget) instead gets a "navigation
        // base": the whole page at the largest scale that fits a single bitmap,
        // so panning inside it shows real content rather than the tiny minimap
        // thumbnail stretched over the whole page.
        CGFloat pageDisplayScale = displayScale;
        NSUInteger perPageByteLimit = kBaseZoomCacheMaxPageBytes;
        if (![self fullPageRenderAllowedForPage:existing zoom:kBaseZoomCacheZoom displayScale:displayScale]) {
            pageDisplayScale = [self cappedFullPageDisplayScaleForPage:existing
                                                                  zoom:kBaseZoomCacheZoom
                                                             byteLimit:kMaxRenderedPageBitmapByteLimit];
            if (pageDisplayScale <= 0.0 || pageDisplayScale >= displayScale) continue;
            perPageByteLimit = kMaxRenderedPageBitmapByteLimit;
        }
        if ([self basePageImage:existing matchesDisplayScale:pageDisplayScale]) continue;
        NSUInteger estimatedBytes = [self estimatedRenderedImageByteCostForPage:existing
                                                                           zoom:kBaseZoomCacheZoom
                                                                   displayScale:pageDisplayScale];
        if (estimatedBytes == 0 || estimatedBytes > perPageByteLimit) continue;
        if (scheduledBytes > kBaseZoomCacheTotalByteLimit ||
            estimatedBytes > kBaseZoomCacheTotalByteLimit - scheduledBytes)
            continue;
        NSOperation* queuedOperation = _queuedBaseRenderOperations[number];
        if (queuedOperation) {
            if (seedPriority && !queuedOperation.isExecuting) {
                [queuedOperation cancel];
                [_queuedBaseRenderPages removeObject:number];
                [_queuedBaseRenderOperations removeObjectForKey:number];
            } else {
                if (seedPriority) {
                    queuedOperation.queuePriority = NSOperationQueuePriorityVeryHigh;
                    queuedOperation.qualityOfService = NSQualityOfServiceUtility;
                }
                continue;
            }
        }

        scheduledBytes += estimatedBytes;
        [_queuedBaseRenderPages addObject:number];
        NSInteger distance = labs(index - preferredPage);
        SPDFRenderOperation* operation = [SPDFRenderOperation operationWithRenderBlock:^(spdf_render_token* token) {
          @autoreleasepool {
              if (generation != self->_renderGeneration || self->_liveZooming) {
                  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                    [self->_queuedBaseRenderPages removeObject:number];
                    [self->_queuedBaseRenderOperations removeObjectForKey:number];
                  }];
                  return;
              }
              char err[1024];
              spdf_document* workerDoc = [self workerDocumentForPath:workingPath
                                                          sourcePath:path
                                                               error:err
                                                         errorLength:sizeof(err)];
              if (!workerDoc) {
                  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                    [self->_queuedBaseRenderPages removeObject:number];
                    [self->_queuedBaseRenderOperations removeObjectForKey:number];
                  }];
                  return;
              }
              if (self->_liveZooming) {
                  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                    [self->_queuedBaseRenderPages removeObject:number];
                    [self->_queuedBaseRenderOperations removeObjectForKey:number];
                  }];
                  return;
              }
              SPDFRenderedPage* rendered = [self renderedPageAtIndex:(NSInteger)index
                                                            document:workerDoc
                                                                zoom:kBaseZoomCacheZoom
                                                        displayScale:pageDisplayScale
                                                         renderToken:token
                                                               error:err
                                                         errorLength:sizeof(err)];
              if (!rendered && spdf_render_was_canceled(err) && spdf_zoom_profile_enabled())
                  spdf_zoom_profile_log(@"renderCanceled page=%ld site=baseZoomCache", (long)index);
              [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                [self->_queuedBaseRenderPages removeObject:number];
                [self->_queuedBaseRenderOperations removeObjectForKey:number];
                if (!rendered || generation != self->_renderGeneration || !self->_doc ||
                    index >= (NSInteger)self->_renderedPages.count || ![self->_path isEqualToString:path])
                    return;
                SPDFRenderedPage* page = self->_renderedPages[(NSUInteger)index];
                page.baseImage = rendered.image;
                page.baseImagePointWidth = rendered.imagePointWidth;
                page.baseImagePointHeight = rendered.imagePointHeight;
                page.baseImageZoom = kBaseZoomCacheZoom;
                page.baseImageScale = pageDisplayScale;
                if (self->_liveZooming && labs(index - self->_pageIndex) <= 1 && !page.zoomSeedImage) {
                    [self setZoomSeedForPage:page
                                       image:page.baseImage
                                    pageRect:NSMakeRect(0.0, 0.0, page.pageWidth, page.pageHeight)
                                        zoom:page.baseImageZoom
                                displayScale:page.baseImageScale];
                    [self->_pageView setNeedsDisplayInRect:[self->_pageView rectForPageAtIndex:index]];
                }
                if (!self->_liveZooming) {
                    [self cacheActiveRenderedPagesForSelectedTab];
                    [self scheduleRenderAdoptionMaintenance];
                }
              }];
          }
        }];
        operation.queuePriority = seedPriority
                                      ? NSOperationQueuePriorityVeryHigh
                                      : (distance <= 1 ? NSOperationQueuePriorityHigh : NSOperationQueuePriorityLow);
        operation.qualityOfService = NSQualityOfServiceUtility;
        _queuedBaseRenderOperations[number] = operation;
        [(seedPriority ? _zoomSeedRenderQueue : _cacheRenderQueue) addOperation:operation];
    }
}

- (void)enqueueFocusedDocumentBaseCacheForGeneration:(NSUInteger)generation preferredPage:(NSInteger)preferredPage {
    NSArray<NSNumber*>* order = [self pageRenderOrderForCount:(NSInteger)_renderedPages.count
                                                preferredPage:preferredPage
                                                     maxPages:(NSInteger)_renderedPages.count];
    [self enqueueBaseZoomCacheForPageIndexes:order
                            renderGeneration:generation
                               preferredPage:preferredPage
                                seedPriority:NO];
}

- (void)enqueueZoomSeedCachesForGeneration:(NSUInteger)generation
                             preferredPage:(NSInteger)preferredPage
                          includeWholeBase:(BOOL)includeWholeBase {
    NSArray<NSNumber*>* pages = [self pageNeighborhoodIndexesAroundPage:preferredPage];
    [self enqueueHighQualityZoomCacheForPageIndexes:pages
                                   renderGeneration:generation
                                   liveZoomSequence:_liveZoomSequence
                                      preferredPage:preferredPage];
    [self enqueueBaseZoomCacheForPageIndexes:pages
                            renderGeneration:generation
                               preferredPage:preferredPage
                                seedPriority:YES];
    if (includeWholeBase) [self enqueueFocusedDocumentBaseCacheForGeneration:generation preferredPage:preferredPage];
}

- (void)enqueueHighQualityZoomCacheForPageIndexes:(NSArray<NSNumber*>*)pageIndexes
                                 renderGeneration:(NSUInteger)generation
                                 liveZoomSequence:(NSUInteger)liveZoomSequence
                                    preferredPage:(NSInteger)preferredPage {
    (void)liveZoomSequence;
    if (!_doc || !_path.length || pageIndexes.count == 0) return;

    NSString* path = [_path copy];
    NSString* workingPath = [self activeWorkingPath]; // temp copy for read-only source
    CGFloat zoom = kHighQualityZoomCacheZoom;
    CGFloat displayScale = [self highQualityZoomCacheDisplayScale];
    for (NSNumber* number in pageIndexes) {
        NSInteger index = number.integerValue;
        if (index < 0 || index >= (NSInteger)_renderedPages.count) continue;
        SPDFRenderedPage* existing = _renderedPages[(NSUInteger)index];
        if ([self highQualityPageImage:existing matchesZoom:zoom displayScale:displayScale]) continue;
        if (![self fullPageRenderAllowedForPage:existing zoom:zoom displayScale:displayScale]) continue;
        if ([self estimatedRenderedImageByteCostForPage:existing zoom:zoom
                                           displayScale:displayScale] > kHighQualityZoomCacheMaxPageBytes)
            continue;
        NSOperation* queuedOperation = _queuedHighQualityRenderOperations[number];
        if (queuedOperation) {
            queuedOperation.queuePriority =
                index == preferredPage ? NSOperationQueuePriorityVeryHigh : NSOperationQueuePriorityHigh;
            queuedOperation.qualityOfService = NSQualityOfServiceUtility;
            continue;
        }

        [_queuedHighQualityRenderPages addObject:number];
        NSInteger distance = labs(index - preferredPage);
        SPDFRenderOperation* operation = [SPDFRenderOperation operationWithRenderBlock:^(spdf_render_token* token) {
          @autoreleasepool {
              if (generation != self->_renderGeneration || self->_liveZooming) {
                  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                    [self->_queuedHighQualityRenderPages removeObject:number];
                    [self->_queuedHighQualityRenderOperations removeObjectForKey:number];
                  }];
                  return;
              }
              char err[1024];
              spdf_document* workerDoc = [self workerDocumentForPath:workingPath
                                                          sourcePath:path
                                                               error:err
                                                         errorLength:sizeof(err)];
              if (!workerDoc) {
                  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                    [self->_queuedHighQualityRenderPages removeObject:number];
                    [self->_queuedHighQualityRenderOperations removeObjectForKey:number];
                  }];
                  return;
              }
              if (self->_liveZooming) {
                  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                    [self->_queuedHighQualityRenderPages removeObject:number];
                    [self->_queuedHighQualityRenderOperations removeObjectForKey:number];
                  }];
                  return;
              }
              SPDFRenderedPage* rendered = [self renderedPageAtIndex:index
                                                            document:workerDoc
                                                                zoom:zoom
                                                        displayScale:displayScale
                                                         renderToken:token
                                                               error:err
                                                         errorLength:sizeof(err)];
              if (!rendered && spdf_render_was_canceled(err) && spdf_zoom_profile_enabled())
                  spdf_zoom_profile_log(@"renderCanceled page=%ld site=highQualityZoomCache", (long)index);
              [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                [self->_queuedHighQualityRenderPages removeObject:number];
                [self->_queuedHighQualityRenderOperations removeObjectForKey:number];
                if (!rendered || generation != self->_renderGeneration || !self->_doc ||
                    index >= (NSInteger)self->_renderedPages.count || ![self->_path isEqualToString:path] ||
                    fabs(displayScale - [self highQualityZoomCacheDisplayScale]) > 0.001)
                    return;
                SPDFRenderedPage* page = self->_renderedPages[(NSUInteger)index];
                page.highQualityImage = rendered.image;
                page.highQualityImagePointWidth = rendered.imagePointWidth;
                page.highQualityImagePointHeight = rendered.imagePointHeight;
                page.highQualityImageZoom = zoom;
                page.highQualityImageScale = displayScale;
                if (self->_liveZooming && labs(index - self->_pageIndex) <= 1) {
                    [self setZoomSeedForPage:page
                                       image:page.highQualityImage
                                    pageRect:NSMakeRect(0.0, 0.0, page.pageWidth, page.pageHeight)
                                        zoom:page.highQualityImageZoom
                                displayScale:page.highQualityImageScale];
                    [self->_pageView setNeedsDisplayInRect:[self->_pageView rectForPageAtIndex:index]];
                }
                if (!self->_liveZooming) {
                    [self cacheActiveRenderedPagesForSelectedTab];
                    [self scheduleRenderAdoptionMaintenance];
                }
              }];
          }
        }];
        operation.queuePriority = distance == 0 ? NSOperationQueuePriorityVeryHigh : NSOperationQueuePriorityHigh;
        operation.qualityOfService = NSQualityOfServiceUtility;
        _queuedHighQualityRenderOperations[number] = operation;
        [_zoomSeedRenderQueue addOperation:operation];
    }
}
- (void)scheduleNearbyPageRendersAfterFirstPaintForGeneration:(NSUInteger)generation
                                                preferredPage:(NSInteger)preferredPage {
    [self spdf_scheduleIdleNearbyPageRendersForGeneration:generation preferredPage:preferredPage];
}

- (void)enqueuePageRendersForGeneration:(NSUInteger)generation
                            pageIndexes:(NSArray<NSNumber*>*)pageIndexes
                          preferredPage:(NSInteger)preferredPage
                      forceHighPriority:(BOOL)forceHighPriority {
    if (!_doc || !_path.length) return;

    NSString* sourcePath = [_path copy];
    NSString* workingPath = [self activeWorkingPath]; // temp copy for read-only source
    CGFloat zoom = _zoom;
    CGFloat displayScale = [self backingScale];
    NSUInteger liveZoomSequence = _liveZoomSequence;
    for (NSNumber* number in pageIndexes) {
        NSInteger index = number.integerValue;
        if (index < 0 || index >= (NSInteger)_renderedPages.count) continue;
        SPDFRenderedPage* existing = _renderedPages[(NSUInteger)index];
        if ([self renderedPageImage:existing matchesZoom:zoom displayScale:displayScale]) continue;
        if (![self fullPageRenderAllowedForPage:existing zoom:zoom displayScale:displayScale]) continue;
        NSOperation* queuedOperation = _queuedRenderOperations[number];
        if (queuedOperation) {
            if (forceHighPriority) {
                queuedOperation.queuePriority = NSOperationQueuePriorityVeryHigh;
                queuedOperation.qualityOfService = NSQualityOfServiceUserInitiated;
            }
            continue;
        }
        [_queuedRenderPages addObject:number];

        NSInteger distance = labs(index - preferredPage);
        __block __weak SPDFRenderOperation* weakOperation = nil; // cleanup forgets only its own queue entry
        SPDFRenderOperation* operation = [SPDFRenderOperation operationWithRenderBlock:^(spdf_render_token* token) {
          @autoreleasepool {
              if (generation != self->_renderGeneration || liveZoomSequence != self->_liveZoomSequence) {
                  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                    [self spdf_forgetQueuedRenderOperation:weakOperation page:number];
                  }];
                  return;
              }
              char err[1024];
              spdf_document* workerDoc = [self workerDocumentForPath:workingPath
                                                          sourcePath:sourcePath
                                                               error:err
                                                         errorLength:sizeof(err)];
              if (!workerDoc) {
                  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                    [self spdf_forgetQueuedRenderOperation:weakOperation page:number];
                  }];
                  return;
              }
              SPDFRenderedPage* page = [self renderedPageAtIndex:index
                                                        document:workerDoc
                                                            zoom:zoom
                                                    displayScale:displayScale
                                                     renderToken:token
                                                           error:err
                                                     errorLength:sizeof(err)];
              if (!page) {
                  /* On cancel: bookkeeping cleanup only, no error UI. */
                  if (spdf_render_was_canceled(err) && spdf_zoom_profile_enabled())
                      spdf_zoom_profile_log(@"renderCanceled page=%ld site=pageRender", (long)index);
                  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                    [self spdf_forgetQueuedRenderOperation:weakOperation page:number];
                  }];
                  return;
              }

              [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                double adoptT0 = spdf_zoom_profile_enabled() ? spdf_zoom_profile_now_ms() : 0.0;
                [self spdf_forgetQueuedRenderOperation:weakOperation page:number];
                if (generation != self->_renderGeneration || !self->_doc ||
                    index >= (NSInteger)self->_renderedPages.count || fabs(zoom - self->_zoom) > 0.001 ||
                    fabs(displayScale - [self backingScale]) > 0.001)
                    return;
                SPDFRenderedPage* old = self->_renderedPages[(NSUInteger)index];
                page.highlights = self->_findHighlights[@(index)] ?: old.highlights ?: @[];
                page.selectionRects = old.selectionRects ?: @[];
                [self copyMinimapThumbnailFromPage:old toPage:page];
                BOOL geometryChanged =
                    fabs(old.pageWidth - page.pageWidth) > 0.01 || fabs(old.pageHeight - page.pageHeight) > 0.01;
                [self->_renderedPages replaceObjectAtIndex:(NSUInteger)index withObject:page];
                double adoptT1 = adoptT0 > 0.0 ? spdf_zoom_profile_now_ms() : 0.0;
                // The rendered page's highlights are already set above (line with
                // _findHighlights). Do NOT call applySearchHighlightsToCurrentPage
                // here — it reassigns _pageView.pages (full layout invalidate +
                // whole-view redraw) and runs a full updateMinimap (strip rebuild)
                // on EVERY render completion, which was the residual scroll stutter.
                double adoptT2 = adoptT0 > 0.0 ? spdf_zoom_profile_now_ms() : 0.0;
                if (geometryChanged)
                    [self resizeDocumentView];
                else
                    // Image-only update: avoid the full layout-invalidate + whole-view
                    // redraw the `pages` setter does — that per-completion O(n) rebuild
                    // was the downward-scroll stutter as prefetch renders landed.
                    [self->_pageView refreshRenderedPages:self->_renderedPages changedPageIndex:index];
                double adoptT3 = adoptT0 > 0.0 ? spdf_zoom_profile_now_ms() : 0.0;
                [self cacheActiveRenderedPagesForSelectedTab];
                double adoptT4 = adoptT0 > 0.0 ? spdf_zoom_profile_now_ms() : 0.0;
                // Coalesced: the per-completion full updateMinimap + eviction were
                // the page-to-page scroll stutter when many prefetch renders land.
                [self scheduleRenderAdoptionMaintenance];
                if (adoptT0 > 0.0) {
                    double adoptT5 = spdf_zoom_profile_now_ms();
                    double total = adoptT5 - adoptT0;
                    if (total > 4.0)
                        spdf_zoom_profile_log(@"ADOPT-PAGE page=%ld img=%p bytes=%luMB geom=%d total=%.1fms "
                                              @"replace=%.1f highlights=%.1f display=%.1f cache=%.1f evict=%.1f",
                                              (long)index, (__bridge void*)page.image,
                                              (unsigned long)([self renderedImageByteCost:page] / (1024 * 1024)),
                                              geometryChanged, total, adoptT1 - adoptT0, adoptT2 - adoptT1,
                                              adoptT3 - adoptT2, adoptT4 - adoptT3, adoptT5 - adoptT4);
                }
              }];
          }
        }];
        operation.queuePriority =
            forceHighPriority ? NSOperationQueuePriorityVeryHigh : [self queuePriorityForRenderDistance:distance];
        operation.qualityOfService = forceHighPriority ? NSQualityOfServiceUserInitiated : NSQualityOfServiceUtility;
        _queuedRenderOperations[number] = weakOperation = operation;
        [(forceHighPriority ? _renderQueue : _backgroundRenderQueue) addOperation:operation];
    }
}

- (void)enqueueNearbyPageRendersForGeneration:(NSUInteger)generation preferredPage:(NSInteger)preferredPage {
    NSArray<NSNumber*>* order = [self pageRenderOrderForCount:(NSInteger)_renderedPages.count
                                                preferredPage:preferredPage
                                                     maxPages:[self backgroundRenderBatchSizeForCurrentZoom]];
    [self enqueuePageRendersForGeneration:generation
                              pageIndexes:order
                            preferredPage:preferredPage
                        forceHighPriority:NO];
}

// Cancel queued minimap-thumbnail renders for pages that fell out of the
// thumbnail window (e.g. after a drag/jump far away) so nearby thumbnails
// don't wait behind stale far-away work. In-flight renders abort via their
// render token; their completion blocks clean up _queuedMinimapThumbnailPages.
- (void)cancelQueuedMinimapThumbnailRendersOutsideWindow:(SPDFMinimapThumbnailWindow)window {
    if (_queuedMinimapThumbnailPages.count == 0) return;
    NSMutableArray<NSNumber*>* stale = [NSMutableArray array];
    for (NSNumber* number in _queuedMinimapThumbnailPages) {
        if (!spdf_minimap_window_contains(window, number.integerValue)) [stale addObject:number];
    }
    for (NSNumber* number in stale) {
        [[_queuedMinimapThumbnailOperations objectForKey:number] cancel];
        [_queuedMinimapThumbnailOperations removeObjectForKey:number];
        [_queuedMinimapThumbnailPages removeObject:number];
    }
}

// Window-based thumbnail eviction: drop thumbnails that fell far enough
// outside the window (see spdf_minimap_window_should_evict) so minimap memory
// stays bounded no matter the page count. Evicted slots are always off-screen
// and re-render lazily when the window recenters over them. Documents that fit
// inside the window (+ slack) never evict, preserving the old keep-everything
// behavior for small documents. No strip-cache repaint is needed: the cached
// strip only exists for documents far shorter than the window (see
// kLiveContentCacheMaxHeight), which never evict.
- (void)evictMinimapThumbnailsOutsideWindow:(SPDFMinimapThumbnailWindow)window {
    for (SPDFRenderedPage* page in _renderedPages) {
        if (!page.minimapImage) continue;
        if (!spdf_minimap_window_should_evict(window, page.pageIndex)) continue;
        page.minimapImage = nil;
        page.minimapImageZoom = 0.0;
        page.minimapImageScale = 0.0;
    }
}

- (void)enqueueVisibleMinimapThumbnailRenders {
    if (!_minimapVisible || !_doc || !_path.length || _renderedPages.count == 0 || _liveZooming) return;
    // Windowed lazy loading (see SPDFMacMinimapWindow.h): only pages inside a
    // window around the visible strip range get thumbnails, rendered
    // nearest-to-the-viewport first; queued renders that fell outside the
    // window are cancelled and far-outside thumbnails are evicted, so cost and
    // memory stay bounded for any document size. Pages outside the window keep
    // the cheap placeholder at exact strip geometry.
    NSArray<NSNumber*>* strictlyVisiblePages = [_minimapView visiblePageIndexes];
    if (strictlyVisiblePages.count == 0) return;
    NSInteger firstVisible = strictlyVisiblePages.firstObject.integerValue;
    NSInteger lastVisible = strictlyVisiblePages.lastObject.integerValue;
    _minimapThumbnailWindow = spdf_minimap_window_for_visible_range((NSInteger)_renderedPages.count, firstVisible,
                                                                    lastVisible, _minimapThumbnailWindow);
    [self cancelQueuedMinimapThumbnailRendersOutsideWindow:_minimapThumbnailWindow];
    [self evictMinimapThumbnailsOutsideWindow:_minimapThumbnailWindow];
    NSArray<NSNumber*>* visiblePages =
        spdf_minimap_window_render_order(_minimapThumbnailWindow, firstVisible, lastVisible);
    if (visiblePages.count == 0) return;

    // Boost only the first band after a document becomes active so it isn't
    // starved behind page renders / background-tab warming; later (scroll-driven)
    // bands stay at Utility. See _minimapInitialPopulationPending.
    NSString* path = [_path copy];
    NSString* workingPath = [self activeWorkingPath]; // temp copy for read-only source
    NSUInteger generation = _renderGeneration;
    CGFloat displayScale = [self backingScale];
    if (displayScale <= 0.0) return;

    // Consume the one-shot boost only once we actually create operations, so a
    // no-op enqueue (everything already queued/cached) during a tab switch
    // doesn't waste the boost before the real population runs.
    BOOL boostInitialBand = NO;
    for (NSNumber* number in visiblePages) {
        NSInteger index = number.integerValue;
        if (index < 0 || index >= (NSInteger)_renderedPages.count) continue;
        SPDFRenderedPage* existing = _renderedPages[(NSUInteger)index];
        // Per-page render zoom so each thumbnail is crisp at its (width-capped)
        // displayed size in the strip, rather than rendering every page at the
        // widest page's tiny scale and upscaling the normal ones.
        CGFloat thumbnailZoom = [_minimapView thumbnailRenderZoomForPage:existing];
        if (thumbnailZoom <= 0.0) continue;
        if ([self minimapThumbnailImage:existing matchesZoom:thumbnailZoom displayScale:displayScale]) continue;
        if ([_queuedMinimapThumbnailPages containsObject:number]) continue;
        [_queuedMinimapThumbnailPages addObject:number];
        if (_minimapInitialPopulationPending) {
            boostInitialBand = YES;
            _minimapInitialPopulationPending = NO;
        }

        SPDFRenderOperation* operation = [SPDFRenderOperation operationWithRenderBlock:^(spdf_render_token* token) {
          @autoreleasepool {
              if (generation != self->_renderGeneration) {
                  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                    [self->_queuedMinimapThumbnailPages removeObject:number];
                  }];
                  return;
              }
              char err[512];
              spdf_document* workerDoc = [self workerDocumentForPath:workingPath
                                                          sourcePath:path
                                                               error:err
                                                         errorLength:sizeof(err)];
              if (!workerDoc) {
                  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                    [self->_queuedMinimapThumbnailPages removeObject:number];
                  }];
                  return;
              }
              SPDFRenderedPage* thumbnailPage = [self renderedPageAtIndex:index
                                                                 document:workerDoc
                                                                     zoom:thumbnailZoom
                                                             displayScale:displayScale
                                                              renderToken:token
                                                                    error:err
                                                              errorLength:sizeof(err)];
              if (!thumbnailPage && spdf_render_was_canceled(err) && spdf_zoom_profile_enabled())
                  spdf_zoom_profile_log(@"renderCanceled page=%ld site=minimapThumbnail", (long)index);
              [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                [self->_queuedMinimapThumbnailPages removeObject:number];
                if (generation != self->_renderGeneration || !self->_doc || ![self->_path isEqualToString:path] ||
                    index >= (NSInteger)self->_renderedPages.count || !thumbnailPage.image)
                    return;
                SPDFRenderedPage* page = self->_renderedPages[(NSUInteger)index];
                if ([self minimapThumbnailImage:page matchesZoom:thumbnailZoom displayScale:displayScale]) return;
                page.minimapImage = thumbnailPage.image;
                page.minimapImageZoom = thumbnailZoom;
                page.minimapImageScale = displayScale;
                // Hand the strip this LIVE page (a full-page render may have replaced
                // the object its snapshot holds) and patch just its slot -- never a
                // full updateMinimap from a completion (architecture.md 3.4).
                [self->_minimapView noteThumbnailLoadedForPage:page];
              }];
          }
        }];
        operation.queuePriority = boostInitialBand ? NSOperationQueuePriorityVeryHigh : NSOperationQueuePriorityNormal;
        operation.qualityOfService = boostInitialBand ? NSQualityOfServiceUserInitiated : NSQualityOfServiceUtility;
        [_queuedMinimapThumbnailOperations setObject:operation forKey:number];
        [_minimapQueue addOperation:operation];
    }
}

- (void)renderPageIfNeededAtIndex:(NSInteger)pageIndex {
    if (!_doc || pageIndex < 0 || pageIndex >= (NSInteger)_renderedPages.count) return;
    SPDFRenderedPage* existing = _renderedPages[(NSUInteger)pageIndex];
    CGFloat displayScale = [self backingScale];
    if ([self renderedPageImage:existing matchesZoom:_zoom displayScale:displayScale]) return;
    if (![self fullPageRenderAllowedForPage:existing zoom:_zoom displayScale:displayScale]) {
        if (_documentViewPanActive)
            [self renderLiveDocumentPanViewportCropIfDue];
        else
            [self renderVisiblePageCropsForCurrentViewportIfNeeded];
        [_pageView setNeedsDisplayInRect:[_pageView rectForPageAtIndex:pageIndex]];
        [self scheduleRenderAdoptionMaintenance];
        return;
    }

    // Never render synchronously here: this runs from scroll/page-navigation
    // callbacks, and an inline full-page render blocks input for 50-500ms.
    // Resident stale/base imagery keeps drawing until the async render lands.
    [self enqueuePageRendersForGeneration:_renderGeneration
                              pageIndexes:@[ @(pageIndex) ]
                            preferredPage:pageIndex
                        forceHighPriority:YES];
}

- (CGFloat)renderDisplayScaleForPageWidth:(CGFloat)pageWidth
                               pageHeight:(CGFloat)pageHeight
                                     zoom:(CGFloat)zoom
                             displayScale:(CGFloat)displayScale {
    displayScale = displayScale > 0.0 ? displayScale : 1.0;
    if (pageWidth <= 0.0 || pageHeight <= 0.0 || zoom <= 0.0) return 0.0;

    double requestedEffectiveZoom = (double)zoom * (double)displayScale;
    double scaledWidth = ceil((double)pageWidth * requestedEffectiveZoom) + 2.0;
    double scaledHeight = ceil((double)pageHeight * requestedEffectiveZoom) + 2.0;
    double bytes = scaledWidth * scaledHeight * 4.0;
    if (!isfinite(scaledWidth) || !isfinite(scaledHeight) || !isfinite(bytes) ||
        scaledWidth > (double)kMaxRenderedPageBitmapDimension ||
        scaledHeight > (double)kMaxRenderedPageBitmapDimension || bytes > (double)kMaxRenderedPageBitmapByteLimit)
        return 0.0;
    return displayScale;
}

- (BOOL)fullPageRenderAllowedForPage:(SPDFRenderedPage*)page zoom:(CGFloat)zoom displayScale:(CGFloat)displayScale {
    if (!page) return NO;
    return [self renderDisplayScaleForPageWidth:page.pageWidth
                                     pageHeight:page.pageHeight
                                           zoom:zoom
                                   displayScale:displayScale] > 0.0;
}

- (BOOL)viewportImage:(SPDFRenderedPage*)page
    coversPageCropRect:(NSRect)cropRect
                  zoom:(CGFloat)zoom
          displayScale:(CGFloat)displayScale {
    if (!page.viewportImage) return NO;
    if (fabs(page.viewportImageZoom - zoom) > 0.001 || fabs(page.viewportImageScale - displayScale) > 0.001) return NO;
    return NSContainsRect(NSInsetRect(page.viewportImagePageRect, -1.0, -1.0), cropRect);
}

- (NSRect)visiblePageCropRectForPageIndex:(NSInteger)pageIndex extraViewMargin:(CGFloat)extraViewMargin {
    if (!_pageScrollView || !_pageView || pageIndex < 0 || pageIndex >= (NSInteger)_renderedPages.count)
        return NSZeroRect;
    SPDFRenderedPage* page = _renderedPages[(NSUInteger)pageIndex];
    NSRect pageRect = [_pageView rectForPageAtIndex:pageIndex];
    if (NSIsEmptyRect(pageRect)) return NSZeroRect;

    NSRect visibleRect = _pageScrollView.contentView.bounds;
    visibleRect = NSInsetRect(visibleRect, -MAX(0.0, extraViewMargin), -MAX(0.0, extraViewMargin));
    NSRect intersection = NSIntersectionRect(visibleRect, pageRect);
    if (NSIsEmptyRect(intersection)) return NSZeroRect;

    CGFloat scaleX = page.pageWidth / MAX(1.0, NSWidth(pageRect));
    CGFloat scaleY = page.pageHeight / MAX(1.0, NSHeight(pageRect));
    NSRect crop = NSMakeRect((NSMinX(intersection) - NSMinX(pageRect)) * scaleX,
                             (NSMinY(intersection) - NSMinY(pageRect)) * scaleY, NSWidth(intersection) * scaleX,
                             NSHeight(intersection) * scaleY);
    crop.origin.x = MAX(0.0, MIN(crop.origin.x, page.pageWidth));
    crop.origin.y = MAX(0.0, MIN(crop.origin.y, page.pageHeight));
    crop.size.width = MAX(0.0, MIN(NSWidth(crop), page.pageWidth - NSMinX(crop)));
    crop.size.height = MAX(0.0, MIN(NSHeight(crop), page.pageHeight - NSMinY(crop)));
    return crop;
}

- (NSRect)pixelSnappedPageCropRect:(NSRect)cropRect
                              page:(SPDFRenderedPage*)page
                              zoom:(CGFloat)zoom
                      displayScale:(CGFloat)displayScale {
    if (!page || NSIsEmptyRect(cropRect) || zoom <= 0.0 || displayScale <= 0.0) return NSZeroRect;
    CGFloat renderScale = MAX(0.01, zoom * displayScale);
    CGFloat x0 = floor(NSMinX(cropRect) * renderScale) / renderScale;
    CGFloat y0 = floor(NSMinY(cropRect) * renderScale) / renderScale;
    CGFloat x1 = ceil(NSMaxX(cropRect) * renderScale) / renderScale;
    CGFloat y1 = ceil(NSMaxY(cropRect) * renderScale) / renderScale;
    x0 = MAX(0.0, MIN(x0, page.pageWidth));
    y0 = MAX(0.0, MIN(y0, page.pageHeight));
    x1 = MAX(x0, MIN(x1, page.pageWidth));
    y1 = MAX(y0, MIN(y1, page.pageHeight));
    return NSMakeRect(x0, y0, x1 - x0, y1 - y0);
}

- (void)renderVisiblePageCropsForCurrentViewportWithDisplayScale:(CGFloat)displayScale
                                 allowFullPageRenderAllowedPages:(BOOL)allowFullPageRenderAllowedPages {
    if (_windowLiveResizing) return;
    if (!_doc || !_pageScrollView || !_pageView || _renderedPages.count == 0) return;
    displayScale = MAX(0.5, displayScale);
    CGFloat backingScale = [self backingScale];
    CGFloat margin =
        MAX(NSWidth(_pageScrollView.contentView.bounds), NSHeight(_pageScrollView.contentView.bounds)) * 0.35;
    NSInteger preferredPage = -1;
    NSArray<NSNumber*>* pageIndexes = [self visibleDocumentPageIndexesWithExtraRadius:0 preferredPage:&preferredPage];
    for (NSNumber* number in pageIndexes) {
        NSInteger pageIndex = number.integerValue;
        if (pageIndex < 0 || pageIndex >= (NSInteger)_renderedPages.count) continue;
        SPDFRenderedPage* page = _renderedPages[(NSUInteger)pageIndex];
        if ([self renderedPageImage:page matchesZoom:_zoom displayScale:backingScale]) continue;
        if (!allowFullPageRenderAllowedPages && [self fullPageRenderAllowedForPage:page
                                                                              zoom:_zoom
                                                                      displayScale:backingScale])
            continue;

        NSRect cropRect = [self visiblePageCropRectForPageIndex:pageIndex extraViewMargin:margin];
        cropRect = [self pixelSnappedPageCropRect:cropRect page:page zoom:_zoom displayScale:displayScale];
        if (NSIsEmptyRect(cropRect)) continue;
        if ([self viewportImage:page coversPageCropRect:cropRect zoom:_zoom displayScale:displayScale]) continue;
        if (displayScale < backingScale && [self viewportImage:page
                                               coversPageCropRect:cropRect
                                                             zoom:_zoom
                                                     displayScale:backingScale])
            continue;

        char err[512];
        BOOL useList = ![self fullPageRenderAllowedForPage:page zoom:_zoom displayScale:backingScale];
        NSImage* image = [self renderedPageCropImageAtIndex:pageIndex
                                                   document:_doc
                                                       zoom:_zoom
                                               displayScale:displayScale
                                               pageCropRect:cropRect
                                                    useList:useList
                                                      error:err
                                                errorLength:sizeof(err)];
        if (!image) {
            _statusLabel.stringValue =
                [NSString stringWithFormat:@"Could not render page crop %ld", (long)pageIndex + 1];
            continue;
        }
        page.viewportImage = image;
        page.viewportImagePageRect = cropRect;
        page.viewportImageZoom = _zoom;
        page.viewportImageScale = displayScale;
        [_pageView setNeedsDisplayInRect:[_pageView rectForPageAtIndex:pageIndex]];
    }
}

- (void)renderVisiblePageCropsForCurrentViewportAfterLiveZoom {
    [self renderVisiblePageCropsForCurrentViewportWithDisplayScale:[self backingScale]
                                   allowFullPageRenderAllowedPages:YES];
    [self setCurrentViewportNeedsDisplay];
}

- (NSArray<NSDictionary*>*)visiblePageCropRenderTasksForDisplayScale:(CGFloat)displayScale
                                     allowFullPageRenderAllowedPages:(BOOL)allowFullPageRenderAllowedPages {
    if (_windowLiveResizing) return @[];
    if (!_doc || !_pageScrollView || !_pageView || _renderedPages.count == 0) return @[];
    displayScale = MAX(0.5, displayScale);
    CGFloat backingScale = [self backingScale];
    CGFloat margin =
        MAX(NSWidth(_pageScrollView.contentView.bounds), NSHeight(_pageScrollView.contentView.bounds)) * 0.35;
    NSInteger preferredPage = -1;
    NSArray<NSNumber*>* pageIndexes = [self visibleDocumentPageIndexesWithExtraRadius:0 preferredPage:&preferredPage];
    NSMutableArray<NSDictionary*>* tasks = [NSMutableArray arrayWithCapacity:pageIndexes.count];
    for (NSNumber* number in pageIndexes) {
        NSInteger pageIndex = number.integerValue;
        if (pageIndex < 0 || pageIndex >= (NSInteger)_renderedPages.count) continue;
        SPDFRenderedPage* page = _renderedPages[(NSUInteger)pageIndex];
        if ([self renderedPageImage:page matchesZoom:_zoom displayScale:backingScale]) continue;
        if (!allowFullPageRenderAllowedPages && [self fullPageRenderAllowedForPage:page
                                                                              zoom:_zoom
                                                                      displayScale:backingScale])
            continue;

        NSRect cropRect = [self visiblePageCropRectForPageIndex:pageIndex extraViewMargin:margin];
        cropRect = [self pixelSnappedPageCropRect:cropRect page:page zoom:_zoom displayScale:displayScale];
        if (NSIsEmptyRect(cropRect)) continue;
        if ([self viewportImage:page coversPageCropRect:cropRect zoom:_zoom displayScale:displayScale]) continue;
        if (displayScale < backingScale && [self viewportImage:page
                                               coversPageCropRect:cropRect
                                                             zoom:_zoom
                                                     displayScale:backingScale])
            continue;
        /* Computed on the main thread so the worker block does not need to touch
         * _renderedPages: the page is in the crop regime when a full-page render
         * is disallowed at the current zoom/scale. */
        BOOL useList = ![self fullPageRenderAllowedForPage:page zoom:_zoom displayScale:backingScale];
        [tasks
            addObject:@{@"page" : @(pageIndex), @"crop" : [NSValue valueWithRect:cropRect], @"useList" : @(useList)}];
    }
    return tasks;
}

- (void)queueVisiblePageCropsForCurrentViewportWithDisplayScale:(CGFloat)displayScale
                                allowFullPageRenderAllowedPages:(BOOL)allowFullPageRenderAllowedPages
                                                       sequence:(NSUInteger)sequence
                                                           path:(NSString*)path
                                               renderGeneration:(NSUInteger)renderGeneration {
    if (!_doc || !path.length) return;
    // Render the working path (temp copy for a read-only source); the staleness
    // guard below keeps comparing the SOURCE _path against the SOURCE path arg.
    NSString* workingPath = [self activeWorkingPath];
    displayScale = MAX(0.5, displayScale);
    NSArray<NSDictionary*>* tasks = [self visiblePageCropRenderTasksForDisplayScale:displayScale
                                                    allowFullPageRenderAllowedPages:allowFullPageRenderAllowedPages];
    if (tasks.count == 0) {
        if (!_liveZooming) {
            _pageView.liveZooming = NO;
            [self clearLiveZoomSeeds];
        }
        return;
    }

    CGFloat zoom = _zoom;
    NSUInteger cropRenderSequence = ++_visibleCropRenderSequence;
    /* The sequence has moved on: cookie-abort the superseded in-flight crop
     * render so its worker frees up for this fresher viewport immediately. */
    [_lastVisibleCropRenderOperation cancel];
    SPDFRenderOperation* operation = [SPDFRenderOperation operationWithRenderBlock:^(spdf_render_token* token) {
      @autoreleasepool {
          if (sequence != self->_liveZoomSequence || renderGeneration != self->_renderGeneration ||
              cropRenderSequence != self->_visibleCropRenderSequence)
              return;
          char err[512];
          spdf_document* workerDoc = [self workerDocumentForPath:workingPath
                                                      sourcePath:path
                                                           error:err
                                                     errorLength:sizeof(err)];
          NSMutableArray<NSDictionary*>* results = [NSMutableArray arrayWithCapacity:tasks.count];
          if (workerDoc) {
              for (NSDictionary* task in tasks) {
                  if (sequence != self->_liveZoomSequence || renderGeneration != self->_renderGeneration ||
                      cropRenderSequence != self->_visibleCropRenderSequence)
                      return;
                  NSInteger pageIndex = [task[@"page"] integerValue];
                  NSRect cropRect = [task[@"crop"] rectValue];
                  NSImage* image = [self renderedPageCropImageAtIndex:pageIndex
                                                             document:workerDoc
                                                                 zoom:zoom
                                                         displayScale:displayScale
                                                         pageCropRect:cropRect
                                                              useList:[task[@"useList"] boolValue]
                                                          renderToken:token
                                                                error:err
                                                          errorLength:sizeof(err)];
                  if (!image && spdf_render_was_canceled(err)) {
                      /* Canceled mid-gesture: bail without error UI; the
                       * superseding crop render repaints this viewport. */
                      if (spdf_zoom_profile_enabled())
                          spdf_zoom_profile_log(@"renderCanceled page=%ld site=visibleCrop", (long)pageIndex);
                      return;
                  }
                  if (!image) continue;
                  [results addObject:@{
                      @"page" : @(pageIndex),
                      @"crop" : [NSValue valueWithRect:cropRect],
                      @"image" : image
                  }];
              }
          }

          [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            double adoptT0 = spdf_zoom_profile_enabled() ? spdf_zoom_profile_now_ms() : 0.0;
            if (sequence != self->_liveZoomSequence || renderGeneration != self->_renderGeneration ||
                cropRenderSequence != self->_visibleCropRenderSequence || self->_liveZooming || !self->_doc ||
                ![self->_path isEqualToString:path] || fabs(zoom - self->_zoom) > 0.001 ||
                fabs(displayScale - [self backingScale]) > 0.001)
                return;
            for (NSDictionary* result in results) {
                NSInteger pageIndex = [result[@"page"] integerValue];
                if (pageIndex < 0 || pageIndex >= (NSInteger)self->_renderedPages.count) continue;
                SPDFRenderedPage* page = self->_renderedPages[(NSUInteger)pageIndex];
                page.viewportImage = result[@"image"];
                page.viewportImagePageRect = [result[@"crop"] rectValue];
                page.viewportImageZoom = zoom;
                page.viewportImageScale = displayScale;
                [self->_pageView setNeedsDisplayInRect:[self->_pageView rectForPageAtIndex:pageIndex]];
            }
            double adoptT1 = adoptT0 > 0.0 ? spdf_zoom_profile_now_ms() : 0.0;
            if (!self->_liveZooming) {
                self->_pageView.liveZooming = NO;
                [self clearLiveZoomSeeds];
            }
            [self setCurrentViewportNeedsDisplay];
            double adoptT2 = adoptT0 > 0.0 ? spdf_zoom_profile_now_ms() : 0.0;
            [self scheduleRenderAdoptionMaintenance];
            if (adoptT0 > 0.0) {
                double adoptT3 = spdf_zoom_profile_now_ms();
                double total = adoptT3 - adoptT0;
                if (total > 4.0)
                    spdf_zoom_profile_log(@"ADOPT-CROP pages=%lu img0=%p total=%.1fms assign=%.1f viewport=%.1f "
                                          @"evict=%.1f",
                                          (unsigned long)results.count,
                                          results.count ? (__bridge void*)results[0][@"image"] : NULL, total,
                                          adoptT1 - adoptT0, adoptT2 - adoptT1, adoptT3 - adoptT2);
            }
          }];
      }
    }];
    operation.queuePriority = NSOperationQueuePriorityVeryHigh;
    operation.qualityOfService = NSQualityOfServiceUserInitiated;
    _lastVisibleCropRenderOperation = operation;
    [_renderQueue addOperation:operation];
}

- (void)schedulePostLiveZoomViewportRenderForSequence:(NSUInteger)sequence
                                                 path:(NSString*)path
                                     renderGeneration:(NSUInteger)renderGeneration {
    if (!_doc || !path.length) return;
    [self setCurrentViewportNeedsDisplay];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPostLiveZoomCrispRenderDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     if (sequence != self->_liveZoomSequence || renderGeneration != self->_renderGeneration ||
                         self->_liveZooming || !self->_doc || ![self->_path isEqualToString:path])
                         return;
                     if (self->_documentViewPanActive) {
                         [self schedulePostLiveZoomViewportRenderForSequence:sequence
                                                                        path:path
                                                            renderGeneration:renderGeneration];
                         return;
                     }
                     [self queueVisiblePageCropsForCurrentViewportWithDisplayScale:[self backingScale]
                                                   allowFullPageRenderAllowedPages:YES
                                                                          sequence:sequence
                                                                              path:path
                                                                  renderGeneration:renderGeneration];
                   });
}

- (void)renderVisiblePageCropsForCurrentViewportIfNeeded {
    if (!_doc || !_path.length) return;
    [self queueVisiblePageCropsForCurrentViewportWithDisplayScale:[self backingScale]
                                  allowFullPageRenderAllowedPages:NO
                                                         sequence:_liveZoomSequence
                                                             path:[_path copy]
                                                 renderGeneration:_renderGeneration];
}

- (void)cancelCacheRenderOperations {
    [_zoomSeedRenderQueue cancelAllOperations];
    [_cacheRenderQueue cancelAllOperations];
    [_backgroundRenderQueue cancelAllOperations];
    for (NSOperation* operation in _queuedBaseRenderOperations.objectEnumerator) [operation cancel];
    for (NSOperation* operation in _queuedHighQualityRenderOperations.objectEnumerator) [operation cancel];
    [_queuedBaseRenderPages removeAllObjects];
    [_queuedBaseRenderOperations removeAllObjects];
    [_queuedHighQualityRenderPages removeAllObjects];
    [_queuedHighQualityRenderOperations removeAllObjects];
}

- (void)pauseBackgroundRenderQueuesForLiveZoom {
    if (_liveZoomQueuesPaused) return;
    _liveZoomQueuesPaused = YES;
    _renderQueue.suspended = YES;
    _zoomSeedRenderQueue.suspended = YES;
    _cacheRenderQueue.suspended = YES;
    _backgroundRenderQueue.suspended = YES;
    _minimapQueue.suspended = YES;
    [_renderQueue cancelAllOperations];
    [_zoomSeedRenderQueue cancelAllOperations];
    [_cacheRenderQueue cancelAllOperations];
    [_backgroundRenderQueue cancelAllOperations];
    _visibleCropRenderSequence++;
    for (NSOperation* operation in _queuedRenderOperations.objectEnumerator) [operation cancel];
    for (NSOperation* operation in _queuedBaseRenderOperations.objectEnumerator) [operation cancel];
    for (NSOperation* operation in _queuedHighQualityRenderOperations.objectEnumerator) [operation cancel];
    [_minimapQueue cancelAllOperations];
    [_queuedRenderPages removeAllObjects];
    [_queuedRenderOperations removeAllObjects];
    [_queuedBaseRenderPages removeAllObjects];
    [_queuedBaseRenderOperations removeAllObjects];
    [_queuedHighQualityRenderPages removeAllObjects];
    [_queuedHighQualityRenderOperations removeAllObjects];
    [_queuedMinimapThumbnailPages removeAllObjects];
}

- (void)resumeBackgroundRenderQueuesAfterLiveZoomCancelingQueuedWork:(BOOL)cancelQueuedWork {
    BOOL wasPaused = _liveZoomQueuesPaused;
    if (!wasPaused) {
        _renderQueue.suspended = NO;
        _zoomSeedRenderQueue.suspended = NO;
        _cacheRenderQueue.suspended = NO;
        _backgroundRenderQueue.suspended = NO;
        _minimapQueue.suspended = NO;
        return;
    }
    if (cancelQueuedWork) {
        _visibleCropRenderSequence++;
        [_queuedRenderPages removeAllObjects];
        [_queuedRenderOperations removeAllObjects];
        [_queuedMinimapThumbnailPages removeAllObjects];
    }
    _renderQueue.suspended = NO;
    _zoomSeedRenderQueue.suspended = NO;
    _cacheRenderQueue.suspended = NO;
    _backgroundRenderQueue.suspended = NO;
    _minimapQueue.suspended = NO;
    _liveZoomQueuesPaused = NO;
}

- (void)scheduleLiveZoomMinimapUpdate {
    if (_liveZoomMinimapUpdateScheduled) return;
    _liveZoomMinimapUpdateScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLiveZoomMinimapUpdateInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     self->_liveZoomMinimapUpdateScheduled = NO;
                     if (!self->_doc || !self->_liveZooming) return;
                     [self updateMinimap];
                   });
}

- (void)scheduleDocumentPanMaintenance {
    if (!_documentViewPanActive || _documentViewPanMaintenanceScheduled) return;
    _documentViewPanMaintenanceScheduled = YES;
    NSUInteger panGeneration = _documentViewPanCropGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kDocumentPanLiveCropRenderInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     self->_documentViewPanMaintenanceScheduled = NO;
                     if (!self->_documentViewPanActive || panGeneration != self->_documentViewPanCropGeneration) return;
                     [self renderLiveDocumentPanViewportCropIfDue];
                     // Lightweight minimap update, NOT the full updateMinimap: the
                     // full path reassigns _minimapView.pages (a copy), which
                     // invalidates the strip content cache and forces a full
                     // lockFocus rebuild on the next pan frame — the big pan stutter.
                     [self updateMinimapForScrolling];
                   });
}

- (void)renderLiveDocumentPanViewportCropIfDue {
    if (!_documentViewPanActive) return;
    if (_documentViewPanCropInFlight) return;
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (now - _lastDocumentPanLiveCropRenderTime < kDocumentPanLiveCropRenderInterval) return;
    _lastDocumentPanLiveCropRenderTime = now;

    CGFloat backingScale = [self backingScale];
    // Render the live pan crop at the display's backing scale. It used to be a
    // fixed 1x, which looked blurry upscaled on a Retina display while dragging
    // a big crop-regime page. The crop is bounded by the page's visible portion
    // plus a margin, so the bitmap stays modest. Small pages never reach here
    // (they full-page render above), so this only sharpens the big pages.
    CGFloat displayScale = backingScale;
    CGFloat margin =
        MAX(NSWidth(_pageScrollView.contentView.bounds), NSHeight(_pageScrollView.contentView.bounds)) * 0.35;
    NSInteger preferredPage = -1;
    NSArray<NSNumber*>* pageIndexes = [self visibleDocumentPageIndexesWithExtraRadius:0 preferredPage:&preferredPage];
    NSMutableArray<NSDictionary*>* tasks = [NSMutableArray array];
    for (NSNumber* number in pageIndexes) {
        NSInteger pageIndex = number.integerValue;
        if (pageIndex < 0 || pageIndex >= (NSInteger)_renderedPages.count) continue;
        SPDFRenderedPage* page = _renderedPages[(NSUInteger)pageIndex];
        if ([self renderedPageImage:page matchesZoom:_zoom displayScale:backingScale]) continue;
        if ([self fullPageRenderAllowedForPage:page zoom:_zoom displayScale:backingScale]) continue;

        NSRect cropRect = [self visiblePageCropRectForPageIndex:pageIndex extraViewMargin:margin];
        cropRect = [self pixelSnappedPageCropRect:cropRect page:page zoom:_zoom displayScale:displayScale];
        if (NSIsEmptyRect(cropRect)) continue;
        if ([self viewportImage:page coversPageCropRect:cropRect zoom:_zoom displayScale:displayScale]) continue;
        if ([self viewportImage:page coversPageCropRect:cropRect zoom:_zoom displayScale:backingScale]) continue;
        /* Computed on the main thread for the worker block; the filter above already
         * skipped every page whose full-page render is allowed, so this is the crop regime. */
        BOOL useList = ![self fullPageRenderAllowedForPage:page zoom:_zoom displayScale:backingScale];
        [tasks
            addObject:@{@"page" : @(pageIndex), @"crop" : [NSValue valueWithRect:cropRect], @"useList" : @(useList)}];
    }
    if (tasks.count == 0) return;

    _documentViewPanCropInFlight = YES;
    NSUInteger panGeneration = _documentViewPanCropGeneration;
    NSUInteger renderGeneration = _renderGeneration;
    NSString* path = [_path copy];
    NSString* workingPath = [self activeWorkingPath]; // temp copy for read-only source
    CGFloat zoom = _zoom;
    /* A new pan crop pass supersedes any still-running one: cookie-abort it. */
    [_lastPanCropRenderOperation cancel];
    SPDFRenderOperation* operation = [SPDFRenderOperation operationWithRenderBlock:^(spdf_render_token* token) {
      @autoreleasepool {
          char err[512];
          spdf_document* workerDoc = [self workerDocumentForPath:workingPath
                                                      sourcePath:path
                                                           error:err
                                                     errorLength:sizeof(err)];
          NSMutableArray<NSDictionary*>* results = [NSMutableArray arrayWithCapacity:tasks.count];
          if (workerDoc) {
              for (NSDictionary* task in tasks) {
                  NSInteger pageIndex = [task[@"page"] integerValue];
                  NSRect cropRect = [task[@"crop"] rectValue];
                  NSImage* image = [self renderedPageCropImageAtIndex:pageIndex
                                                             document:workerDoc
                                                                 zoom:zoom
                                                         displayScale:displayScale
                                                         pageCropRect:cropRect
                                                              useList:[task[@"useList"] boolValue]
                                                          renderToken:token
                                                                error:err
                                                          errorLength:sizeof(err)];
                  if (!image && spdf_render_was_canceled(err)) {
                      /* Canceled: stop rendering, but fall through to the main
                       * dispatch below so _documentViewPanCropInFlight resets. */
                      if (spdf_zoom_profile_enabled())
                          spdf_zoom_profile_log(@"renderCanceled page=%ld site=panCrop", (long)pageIndex);
                      break;
                  }
                  if (!image) continue;
                  [results addObject:@{
                      @"page" : @(pageIndex),
                      @"crop" : [NSValue valueWithRect:cropRect],
                      @"image" : image
                  }];
              }
          }

          [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            double adoptT0 = spdf_zoom_profile_enabled() ? spdf_zoom_profile_now_ms() : 0.0;
            if (panGeneration != self->_documentViewPanCropGeneration || renderGeneration != self->_renderGeneration ||
                !self->_documentViewPanActive || ![self->_path isEqualToString:path] ||
                fabs(zoom - self->_zoom) > 0.001) {
                if (panGeneration == self->_documentViewPanCropGeneration) self->_documentViewPanCropInFlight = NO;
                return;
            }
            self->_documentViewPanCropInFlight = NO;
            for (NSDictionary* result in results) {
                NSInteger pageIndex = [result[@"page"] integerValue];
                if (pageIndex < 0 || pageIndex >= (NSInteger)self->_renderedPages.count) continue;
                SPDFRenderedPage* page = self->_renderedPages[(NSUInteger)pageIndex];
                page.viewportImage = result[@"image"];
                page.viewportImagePageRect = [result[@"crop"] rectValue];
                page.viewportImageZoom = zoom;
                page.viewportImageScale = displayScale;
                [self->_pageView setNeedsDisplayInRect:[self->_pageView rectForPageAtIndex:pageIndex]];
            }
            if (self->_documentViewPanActive) [self renderLiveDocumentPanViewportCropIfDue];
            if (adoptT0 > 0.0) {
                double total = spdf_zoom_profile_now_ms() - adoptT0;
                if (total > 4.0)
                    spdf_zoom_profile_log(@"ADOPT-PANCROP pages=%lu total=%.1fms", (unsigned long)results.count, total);
            }
          }];
      }
    }];
    operation.queuePriority = NSOperationQueuePriorityNormal;
    operation.qualityOfService = NSQualityOfServiceUtility;
    _lastPanCropRenderOperation = operation;
    [_renderQueue addOperation:operation];
}

- (NSUInteger)renderedImageByteCost:(SPDFRenderedPage*)page {
    if (!page.image || page.imagePointWidth <= 0.0 || page.imagePointHeight <= 0.0) return 0;
    CGFloat scale = page.imageScale > 0.0 ? page.imageScale : [self backingScale];
    double pixels = ceil(page.imagePointWidth * scale) * ceil(page.imagePointHeight * scale);
    if (!isfinite(pixels) || pixels <= 0.0) return 0;
    double bytes = pixels * 4.0;
    if (bytes > (double)NSUIntegerMax) return NSUIntegerMax;
    return (NSUInteger)bytes;
}

- (NSUInteger)renderedViewportImageByteCost:(SPDFRenderedPage*)page {
    if (!page.viewportImage || NSIsEmptyRect(page.viewportImagePageRect) || page.viewportImageZoom <= 0.0) return 0;
    CGFloat scale = page.viewportImageScale > 0.0 ? page.viewportImageScale : [self backingScale];
    double pixels = ceil(NSWidth(page.viewportImagePageRect) * page.viewportImageZoom * scale) *
                    ceil(NSHeight(page.viewportImagePageRect) * page.viewportImageZoom * scale);
    if (!isfinite(pixels) || pixels <= 0.0) return 0;
    double bytes = pixels * 4.0;
    if (bytes > (double)NSUIntegerMax) return NSUIntegerMax;
    return (NSUInteger)bytes;
}

- (NSUInteger)renderedBaseImageByteCost:(SPDFRenderedPage*)page {
    if (!page.baseImage || page.baseImagePointWidth <= 0.0 || page.baseImagePointHeight <= 0.0) return 0;
    CGFloat scale = page.baseImageScale > 0.0 ? page.baseImageScale : kBaseZoomCacheDisplayScale;
    double pixels = ceil(page.baseImagePointWidth * scale) * ceil(page.baseImagePointHeight * scale);
    if (!isfinite(pixels) || pixels <= 0.0) return 0;
    double bytes = pixels * 4.0;
    if (bytes > (double)NSUIntegerMax) return NSUIntegerMax;
    return (NSUInteger)bytes;
}

- (NSUInteger)renderedHighQualityImageByteCost:(SPDFRenderedPage*)page {
    if (!page.highQualityImage || page.highQualityImagePointWidth <= 0.0 || page.highQualityImagePointHeight <= 0.0)
        return 0;
    CGFloat scale =
        page.highQualityImageScale > 0.0 ? page.highQualityImageScale : [self highQualityZoomCacheDisplayScale];
    double pixels = ceil(page.highQualityImagePointWidth * scale) * ceil(page.highQualityImagePointHeight * scale);
    if (!isfinite(pixels) || pixels <= 0.0) return 0;
    double bytes = pixels * 4.0;
    if (bytes > (double)NSUIntegerMax) return NSUIntegerMax;
    return (NSUInteger)bytes;
}

- (NSUInteger)estimatedRenderedImageByteCostForPage:(SPDFRenderedPage*)page
                                               zoom:(CGFloat)zoom
                                       displayScale:(CGFloat)displayScale {
    if (!page || page.pageWidth <= 0.0 || page.pageHeight <= 0.0 || zoom <= 0.0) return 0;
    displayScale = displayScale > 0.0 ? displayScale : [self backingScale];
    double pixels = ceil(page.pageWidth * zoom * displayScale) * ceil(page.pageHeight * zoom * displayScale);
    if (!isfinite(pixels) || pixels <= 0.0) return 0;
    double bytes = pixels * 4.0;
    if (bytes > (double)NSUIntegerMax) return NSUIntegerMax;
    return (NSUInteger)bytes;
}

- (BOOL)shouldKeepFullRenderedDocumentAtCurrentZoom {
    if (_renderedPages.count == 0) return NO;
    CGFloat displayScale = [self backingScale];
    NSUInteger totalBytes = 0;
    for (SPDFRenderedPage* page in _renderedPages) {
        NSUInteger bytes = [self estimatedRenderedImageByteCostForPage:page zoom:_zoom displayScale:displayScale];
        if (bytes == 0 || bytes > kRenderedImageKeepAllPerPageByteLimit) return NO;
        if (totalBytes > kRenderedImageKeepAllTotalByteLimit ||
            bytes > kRenderedImageKeepAllTotalByteLimit - totalBytes)
            return NO;
        totalBytes += bytes;
    }
    return YES;
}

- (NSInteger)backgroundRenderBatchSizeForCurrentZoom {
    if ([self shouldKeepFullRenderedDocumentAtCurrentZoom]) return (NSInteger)_renderedPages.count;
    return kBackgroundRenderBatchSize;
}

- (void)addKeepRangeToSet:(NSMutableSet<NSNumber*>*)keep center:(NSInteger)center radius:(NSInteger)radius {
    if (center < 0 || _renderedPages.count == 0) return;
    NSInteger first = MAX(0, center - radius);
    NSInteger last = MIN((NSInteger)_renderedPages.count - 1, center + radius);
    for (NSInteger i = first; i <= last; ++i) [keep addObject:@(i)];
}

- (void)evictDistantRenderedPageImages {
    SPDFScopedProfileLog spdfScopedProfile("evictDistantRenderedPageImages", 4.0);
    if (!_renderedPages.count) return;
    if ([self shouldKeepFullRenderedDocumentAtCurrentZoom]) return;

    NSUInteger totalBytes = 0;
    for (SPDFRenderedPage* page in _renderedPages)
        totalBytes += [self renderedImageByteCost:page] + [self renderedViewportImageByteCost:page];
    BOOL shouldEvictRenderedImages = totalBytes > kRenderedImageSoftByteLimit;

    NSMutableSet<NSNumber*>* keep = [NSMutableSet set];
    [self addKeepRangeToSet:keep center:_pageIndex radius:kRenderedImageKeepRadius];
    [self addKeepRangeToSet:keep center:_pageView.currentPageIndex radius:2];
    [self addKeepRangeToSet:keep center:_pageView.activeFindPageIndex radius:1];
    [self addKeepRangeToSet:keep center:_selectionPageIndex radius:1];
    [self addKeepRangeToSet:keep center:_highlightPageIndex radius:1];
    NSInteger preferredPage = -1;
    for (NSNumber* visiblePage in [self visibleDocumentPageIndexesWithExtraRadius:1 preferredPage:&preferredPage])
        [keep addObject:visiblePage];
    for (NSNumber* queuedPage in _queuedRenderPages) [keep addObject:queuedPage];
    for (NSNumber* queuedPage in _queuedHighQualityRenderPages) [keep addObject:queuedPage];
    if (_minimapVisible) {
        for (NSNumber* visibleMinimapPage in [_minimapView visiblePageIndexes]) [keep addObject:visibleMinimapPage];
    }

    NSMutableArray<NSDictionary*>* candidates = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)_renderedPages.count; ++i) {
        NSNumber* indexNumber = @(i);
        if ([keep containsObject:indexNumber]) continue;
        SPDFRenderedPage* page = _renderedPages[(NSUInteger)i];
        NSUInteger bytes = [self renderedImageByteCost:page] + [self renderedViewportImageByteCost:page];
        if (bytes == 0) continue;
        NSInteger distance = labs(i - _pageIndex);
        [candidates addObject:@{@"index" : indexNumber, @"distance" : @(distance), @"bytes" : @(bytes)}];
    }

    [candidates sortUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
      NSInteger distanceA = [a[@"distance"] integerValue];
      NSInteger distanceB = [b[@"distance"] integerValue];
      if (distanceA != distanceB) return distanceA > distanceB ? NSOrderedAscending : NSOrderedDescending;
      NSUInteger bytesA = [a[@"bytes"] unsignedIntegerValue];
      NSUInteger bytesB = [b[@"bytes"] unsignedIntegerValue];
      if (bytesA == bytesB) return NSOrderedSame;
      return bytesA > bytesB ? NSOrderedAscending : NSOrderedDescending;
    }];

    BOOL evicted = NO;
    for (NSDictionary* candidate in candidates) {
        if (!shouldEvictRenderedImages) break;
        if (totalBytes <= kRenderedImageTargetByteLimit) break;
        NSInteger index = [candidate[@"index"] integerValue];
        if (index < 0 || index >= (NSInteger)_renderedPages.count) continue;
        SPDFRenderedPage* page = _renderedPages[(NSUInteger)index];
        NSUInteger bytes = [self renderedImageByteCost:page] + [self renderedViewportImageByteCost:page];
        if (bytes == 0) continue;
        NSImage* evictedPageImage = page.image;
        NSImage* evictedViewportImage = page.viewportImage;
        page.image = nil;
        page.imagePointWidth = 0.0;
        page.imagePointHeight = 0.0;
        page.imageZoom = 0.0;
        page.imageScale = 0.0;
        page.viewportImage = nil;
        page.viewportImagePageRect = NSZeroRect;
        page.viewportImageZoom = 0.0;
        page.viewportImageScale = 0.0;
        if ((evictedPageImage && page.zoomSeedImage == evictedPageImage) ||
            (evictedViewportImage && page.zoomSeedImage == evictedViewportImage)) {
            page.zoomSeedImage = nil;
            page.zoomSeedPageRect = NSZeroRect;
            page.zoomSeedZoom = 0.0;
            page.zoomSeedScale = 0.0;
        }
        totalBytes = bytes > totalBytes ? 0 : totalBytes - bytes;
        evicted = YES;
    }

    if (evicted) {
        // Evicted pages are distant/off-screen and their image fields were nil'd
        // in place (the view holds the same page objects), so don't reassign
        // `pages` — that would invalidate the layout cache and force a full
        // redraw per eviction. A viewport repaint is enough; the minimap strip is
        // unaffected (its thumbnails are evicted separately, window-based, in
        // evictMinimapThumbnailsOutsideWindow:).
        [_pageView setNeedsDisplay:YES];
    }

    NSUInteger highQualityBytes = 0;
    for (SPDFRenderedPage* page in _renderedPages) highQualityBytes += [self renderedHighQualityImageByteCost:page];
    if (highQualityBytes > kHighQualityZoomCacheTotalByteLimit) {
        NSMutableArray<NSDictionary*>* highQualityCandidates = [NSMutableArray array];
        for (NSInteger i = 0; i < (NSInteger)_renderedPages.count; ++i) {
            NSNumber* indexNumber = @(i);
            if ([keep containsObject:indexNumber] || [_queuedHighQualityRenderPages containsObject:indexNumber])
                continue;
            SPDFRenderedPage* page = _renderedPages[(NSUInteger)i];
            NSUInteger bytes = [self renderedHighQualityImageByteCost:page];
            if (bytes == 0) continue;
            NSInteger distance = labs(i - _pageIndex);
            [highQualityCandidates addObject:@{@"index" : indexNumber, @"distance" : @(distance), @"bytes" : @(bytes)}];
        }
        [highQualityCandidates sortUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
          NSInteger distanceA = [a[@"distance"] integerValue];
          NSInteger distanceB = [b[@"distance"] integerValue];
          if (distanceA != distanceB) return distanceA > distanceB ? NSOrderedAscending : NSOrderedDescending;
          NSUInteger bytesA = [a[@"bytes"] unsignedIntegerValue];
          NSUInteger bytesB = [b[@"bytes"] unsignedIntegerValue];
          if (bytesA == bytesB) return NSOrderedSame;
          return bytesA > bytesB ? NSOrderedAscending : NSOrderedDescending;
        }];
        BOOL evictedHighQuality = NO;
        for (NSDictionary* candidate in highQualityCandidates) {
            if (highQualityBytes <= kHighQualityZoomCacheTotalByteLimit) break;
            NSInteger index = [candidate[@"index"] integerValue];
            if (index < 0 || index >= (NSInteger)_renderedPages.count) continue;
            SPDFRenderedPage* page = _renderedPages[(NSUInteger)index];
            NSUInteger bytes = [self renderedHighQualityImageByteCost:page];
            if (bytes == 0) continue;
            NSImage* evictedHighQualityImage = page.highQualityImage;
            page.highQualityImage = nil;
            page.highQualityImagePointWidth = 0.0;
            page.highQualityImagePointHeight = 0.0;
            page.highQualityImageZoom = 0.0;
            page.highQualityImageScale = 0.0;
            if (evictedHighQualityImage && page.zoomSeedImage == evictedHighQualityImage) {
                page.zoomSeedImage = nil;
                page.zoomSeedPageRect = NSZeroRect;
                page.zoomSeedZoom = 0.0;
                page.zoomSeedScale = 0.0;
            }
            highQualityBytes = bytes > highQualityBytes ? 0 : highQualityBytes - bytes;
            evictedHighQuality = YES;
        }
        if (evictedHighQuality) [self cacheActiveRenderedPagesForSelectedTab];
    }

    NSUInteger baseBytes = 0;
    for (SPDFRenderedPage* page in _renderedPages) baseBytes += [self renderedBaseImageByteCost:page];
    if (baseBytes <= kBaseZoomCacheTotalByteLimit) return;

    NSMutableArray<NSDictionary*>* baseCandidates = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)_renderedPages.count; ++i) {
        NSNumber* indexNumber = @(i);
        if ([keep containsObject:indexNumber] || [_queuedBaseRenderPages containsObject:indexNumber]) continue;
        SPDFRenderedPage* page = _renderedPages[(NSUInteger)i];
        NSUInteger bytes = [self renderedBaseImageByteCost:page];
        if (bytes == 0) continue;
        NSInteger distance = labs(i - _pageIndex);
        [baseCandidates addObject:@{@"index" : indexNumber, @"distance" : @(distance), @"bytes" : @(bytes)}];
    }
    [baseCandidates sortUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
      NSInteger distanceA = [a[@"distance"] integerValue];
      NSInteger distanceB = [b[@"distance"] integerValue];
      if (distanceA != distanceB) return distanceA > distanceB ? NSOrderedAscending : NSOrderedDescending;
      NSUInteger bytesA = [a[@"bytes"] unsignedIntegerValue];
      NSUInteger bytesB = [b[@"bytes"] unsignedIntegerValue];
      if (bytesA == bytesB) return NSOrderedSame;
      return bytesA > bytesB ? NSOrderedAscending : NSOrderedDescending;
    }];
    BOOL evictedBase = NO;
    for (NSDictionary* candidate in baseCandidates) {
        if (baseBytes <= kBaseZoomCacheTotalByteLimit) break;
        NSInteger index = [candidate[@"index"] integerValue];
        if (index < 0 || index >= (NSInteger)_renderedPages.count) continue;
        SPDFRenderedPage* page = _renderedPages[(NSUInteger)index];
        NSUInteger bytes = [self renderedBaseImageByteCost:page];
        if (bytes == 0) continue;
        NSImage* evictedBaseImage = page.baseImage;
        page.baseImage = nil;
        page.baseImagePointWidth = 0.0;
        page.baseImagePointHeight = 0.0;
        page.baseImageZoom = 0.0;
        page.baseImageScale = 0.0;
        if (page.zoomSeedImage == evictedBaseImage) {
            page.zoomSeedImage = nil;
            page.zoomSeedPageRect = NSZeroRect;
            page.zoomSeedZoom = 0.0;
            page.zoomSeedScale = 0.0;
        }
        baseBytes = bytes > baseBytes ? 0 : baseBytes - bytes;
        evictedBase = YES;
    }
    if (evictedBase) [self cacheActiveRenderedPagesForSelectedTab];
}

- (void)renderDocumentAndScrollToPage:(NSInteger)pageIndex alignTop:(BOOL)alignTop {
    [self renderDocumentAndScrollToPage:pageIndex alignTop:alignTop restoreOrigin:nil];
}

- (void)renderDocumentAndScrollToPage:(NSInteger)pageIndex
                             alignTop:(BOOL)alignTop
                        restoreOrigin:(NSValue*)restoreOrigin {
    if (!_doc || !_uiReady) return;

    [self resumeBackgroundRenderQueuesAfterLiveZoomCancelingQueuedWork:YES];
    [_window.contentView layoutSubtreeIfNeeded];
    [_renderQueue cancelAllOperations];
    [self cancelCacheRenderOperations];
    [_minimapQueue cancelAllOperations];
    [_queuedRenderPages removeAllObjects];
    [_queuedRenderOperations removeAllObjects];
    [_queuedMinimapThumbnailPages removeAllObjects];
    _visibleCropRenderSequence++;
    _renderGeneration++;
    NSUInteger generation = _renderGeneration;
    NSMutableArray<SPDFRenderedPage*>* pages = [NSMutableArray arrayWithCapacity:(NSUInteger)spdf_page_count(_doc)];
    char err[1024];
    NSInteger pageCount = spdf_page_count(_doc);
    // A re-render that keeps the view (restoreOrigin: a comment, a theme, a tab's saved place) keeps the page the zoom
    // was fitted to: refitting to the page shown changes the zoom when pages differ in size, and the origin would then
    // show another page (SPDFDocumentTab.fitPageIndex). Anything else fits the page it goes to.
    BOOL keepFit = restoreOrigin && _fitPageIndex >= 0 && _fitPageIndex < pageCount;
    _fitPageIndex = keepFit ? _fitPageIndex : MAX(0, pageIndex);
    _zoom = [self zoomForFitMode:_fitMode pageIndex:_fitPageIndex];
    pageIndex = MAX(0, MIN(pageIndex, pageCount - 1));
    double launchRenderStart = spdf_launch_profile_enabled() ? spdf_zoom_profile_now_ms() : 0.0;
    SPDFRenderedPage* preferredPage = nil;
    SPDFRenderedPage* prerendered = _launchPrerenderedFirstPage;
    _launchPrerenderedFirstPage = nil; // single-shot: launch first paint only
    if (prerendered && prerendered.pageIndex == pageIndex && prerendered.imageZoom == _zoom &&
        prerendered.imageScale == [self backingScale] && [self renderedPageMatchesReadingTheme:prerendered]) {
        err[0] = '\0';
        preferredPage = prerendered;
        spdf_launch_profile_log(@"sync preferred-page render page=%ld zoom=%.2f adopted from prerender",
                                (long)pageIndex, _zoom);
    } else if (prerendered) {
        spdf_launch_profile_log(@"prerendered page discarded page=%ld zoom=%.4f vs %.4f scale=%.1f", (long)pageIndex,
                                prerendered.imageZoom, _zoom, prerendered.imageScale);
    }
    if (!preferredPage) preferredPage = [self renderedPageAtIndex:pageIndex error:err errorLength:sizeof(err)];
    if (launchRenderStart > 0.0) {
        spdf_launch_profile_log(@"sync preferred-page render page=%ld zoom=%.2f %.1fms", (long)pageIndex, _zoom,
                                spdf_zoom_profile_now_ms() - launchRenderStart);
    }
    if (!preferredPage) {
        _statusLabel.stringValue = strstr(err, "too large")
                                       ? @""
                                       : [NSString stringWithFormat:@"Could not render page %ld", (long)pageIndex + 1];
        preferredPage = [self placeholderPageAtIndex:pageIndex document:_doc fallbackWidth:612.0 fallbackHeight:792.0];
    }
    for (NSInteger i = 0; i < pageCount; ++i) {
        SPDFRenderedPage* page = nil;
        if (i == pageIndex)
            page = preferredPage;
        else
            page = [self placeholderPageAtIndex:i
                                       document:_doc
                                  fallbackWidth:preferredPage.pageWidth
                                 fallbackHeight:preferredPage.pageHeight];
        if (!page) {
            _statusLabel.stringValue = [NSString stringWithFormat:@"Could not prepare page %ld", (long)i + 1];
            return;
        }
        [pages addObject:page];
    }
    if (launchRenderStart > 0.0) {
        spdf_launch_profile_log(@"placeholder geometry pass pages=%ld done at %.1fms", (long)pageCount,
                                spdf_zoom_profile_now_ms() - launchRenderStart);
    }

    [NSAnimationContext
        runAnimationGroup:^(NSAnimationContext* context) {
          context.duration = 0.0;
          context.allowsImplicitAnimation = NO;
          self->_renderedPages = pages;
          [self cacheActiveRenderedPagesForSelectedTab];
          self->_pageView.pages = self->_renderedPages;
          self->_pageView.currentPageIndex = self->_pageIndex;
          self->_pageView.zoom = self->_zoom;
          self->_pageView.presentationMode = self->_presentationMode;
          self->_pageView.backingScale = [self backingScale];
          self->_pageView.liveZooming = NO;
          [self clearLiveZoomSeeds];
          [self applySearchHighlightsToCurrentPage];
          [self resizeDocumentView];
          if (restoreOrigin)
              [self scrollDocumentClipViewToOrigin:[self normalizedDocumentScrollOrigin:restoreOrigin.pointValue
                                                                           forPageIndex:pageIndex]
                                            notify:NO];
          else
              [self scrollToPage:pageIndex alignTop:alignTop];
        }
        completionHandler:nil];
    NSInteger renderCenterPage = pageIndex;
    if (restoreOrigin) {
        renderCenterPage = [_pageView pageIndexForVisibleRect:_pageScrollView.contentView.bounds];
        _pageIndex = renderCenterPage;
        _pageView.currentPageIndex = _pageIndex;
        [self renderPageIfNeededAtIndex:_pageIndex];
    } else if (_pageIndex != pageIndex) {
        // We scrolled to a specific page (fit/zoom commands, navigation). The
        // scroll above runs documentScrollPositionChanged, which re-detects the
        // page from the viewport center — for a fit page shorter than the
        // viewport the next page peeks in below and the center lands on it, so
        // _pageIndex would drift one page per press (e.g. repeated Cmd+1/Cmd+4).
        // Re-pin to the page we actually navigated to so the operation is stable.
        _pageIndex = pageIndex;
        _pageView.currentPageIndex = _pageIndex;
    }
    [self renderVisiblePageCropsForCurrentViewportIfNeeded];

    [self syncToolbarState];
    [self updateControls];
    [self selectCurrentSidebarRow];
    [self updateMinimap];
    [self evictDistantRenderedPageImages];

    [self scheduleNearbyPageRendersAfterFirstPaintForGeneration:generation preferredPage:renderCenterPage];
}

- (void)resizeDocumentView {
    SPDFScopedProfileLog spdfScopedProfile("resizeDocumentView", 4.0);
    NSClipView* clipView = _pageScrollView.contentView;
    [_pageScrollView layoutSubtreeIfNeeded];
    [_pageScrollView tile];
    NSSize clipSize = [self documentClipSizeForLayout];
    _pageView.viewportWidthHint = MAX(1.0, clipSize.width);
    _pageView.viewportHeightHint = MAX(1.0, clipSize.height);
    _pageView.backingScale = [self backingScale];
    if (!_doc) {
        _pageScrollView.hasVerticalScroller = NO;
        _pageScrollView.hasHorizontalScroller = NO;
        [_documentContainer layoutSubtreeIfNeeded];
        [_pageScrollView layoutSubtreeIfNeeded];
        [_pageScrollView tile];
        clipSize = clipView.bounds.size;
        if (clipSize.width <= 1.0 || clipSize.height <= 1.0) clipSize = _pageScrollView.contentSize;
        if (clipSize.width <= 1.0 || clipSize.height <= 1.0) clipSize = _pageScrollView.frame.size;
        _pageView.viewportWidthHint = MAX(1.0, clipSize.width);
        _pageView.viewportHeightHint = MAX(1.0, clipSize.height);
        [_pageView setFrame:NSMakeRect(0.0, 0.0, MAX(1.0, clipSize.width), MAX(1.0, clipSize.height))];
        if (fabs(NSMinX(clipView.bounds)) > 0.01 || fabs(NSMinY(clipView.bounds)) > 0.01) {
            [clipView setBoundsOrigin:NSZeroPoint];
            [_pageScrollView reflectScrolledClipView:clipView];
        }
        [_pageView setNeedsDisplay:YES];
        [self updateMinimap];
        [self invalidateFindMarkers];
        return;
    }

    if (_presentationMode)
        _pageScrollView.verticalScroller = nil;
    else if (_pageScrollView.verticalScroller != _markerScroller)
        _pageScrollView.verticalScroller = _markerScroller;
    NSSize size = [_pageView documentSizeForClipSize:clipSize];
    // Both scrollers show only when there is something to scroll on their axis:
    // a document that fits the viewport at the current zoom (e.g. a single page
    // at Fit Page) shows no vertical scroller at all.
    BOOL needsVerticalScroller = !_presentationMode && size.height > clipSize.height + 0.5;
    BOOL needsHorizontalScroller = size.width > clipSize.width + 0.5;
    if (_pageScrollView.hasHorizontalScroller != needsHorizontalScroller ||
        _pageScrollView.hasVerticalScroller != needsVerticalScroller) {
        _pageScrollView.hasHorizontalScroller = needsHorizontalScroller;
        _pageScrollView.hasVerticalScroller = needsVerticalScroller;
        [_pageScrollView tile];
        clipSize = [self documentClipSizeForLayout];
        _pageView.viewportWidthHint = MAX(1.0, clipSize.width);
        _pageView.viewportHeightHint = MAX(1.0, clipSize.height);
        size = [_pageView documentSizeForClipSize:clipSize];
        needsHorizontalScroller = size.width > clipSize.width + 0.5;
        _pageScrollView.hasHorizontalScroller = needsHorizontalScroller;
        _pageScrollView.hasVerticalScroller = !_presentationMode && size.height > clipSize.height + 0.5;
    }
    if (!needsHorizontalScroller) size.width = MAX(size.width, clipSize.width);
    [_pageView setFrame:NSMakeRect(0.0, 0.0, size.width, size.height)];
    if (!needsHorizontalScroller && fabs(NSMinX(clipView.bounds)) > 0.01) {
        NSPoint origin = clipView.bounds.origin;
        origin.x = 0.0;
        [clipView setBoundsOrigin:origin];
        [_pageScrollView reflectScrolledClipView:clipView];
    }
    [_pageView setNeedsDisplay:YES];
    if (!_liveZooming) [self updateMinimap];
    [self invalidateFindMarkers];
    [self updateHorizontalScrollLockAnimated:NO];
    [self updateVerticalScrollLock];
}

- (void)resizeDocumentViewForWindowLiveResize {
    if (_doc && [self isAutoFitMode:_fitMode]) {
        CGFloat newZoom = [self zoomForFitMode:_fitMode pageIndex:_pageIndex];
        if (isfinite(newZoom) && newZoom > 0.0 && fabs(newZoom - _zoom) > 0.0001) {
            _zoom = newZoom;
            _fitPageIndex = _pageIndex;
            _pageView.zoom = _zoom;
        }
    }
    [self resizeDocumentView];
    [_pageView setNeedsDisplay:YES];
}

- (BOOL)resizeDocumentViewForLiveZoom {
    if (!_doc) {
        [self resizeDocumentView];
        return NO;
    }

    NSClipView* clipView = _pageScrollView.contentView;
    NSSize clipSize = clipView.bounds.size;
    if (clipSize.width <= 1.0 || clipSize.height <= 1.0) clipSize = [self documentClipSizeForLayout];

    _pageView.viewportWidthHint = MAX(1.0, clipSize.width);
    _pageView.viewportHeightHint = MAX(1.0, clipSize.height);
    _pageView.backingScale = [self backingScale];

    NSSize size = [_pageView documentSizeForClipSize:clipSize];
    BOOL needsHorizontalScroller = size.width > clipSize.width + 0.5;
    BOOL needsVerticalScroller = !_presentationMode && size.height > clipSize.height + 0.5;
    if (_pageScrollView.hasHorizontalScroller != needsHorizontalScroller ||
        _pageScrollView.hasVerticalScroller != needsVerticalScroller) {
        [self resizeDocumentView];
        return NO;
    }
    if (!needsHorizontalScroller) size.width = MAX(size.width, clipSize.width);

    NSRect frame = NSMakeRect(0.0, 0.0, size.width, size.height);
    if (!NSEqualRects(_pageView.frame, frame)) [_pageView setFrame:frame];
    if (!needsHorizontalScroller && fabs(NSMinX(clipView.bounds)) > 0.01) {
        NSPoint origin = clipView.bounds.origin;
        origin.x = 0.0;
        BOOL previousSuppressScrollCallbacks = _suppressScrollCallbacks;
        _suppressScrollCallbacks = YES;
        [clipView setBoundsOrigin:origin];
        [_pageScrollView reflectScrolledClipView:clipView];
        _suppressScrollCallbacks = previousSuppressScrollCallbacks;
    }
    [self updateVerticalScrollLock];  // released while live zooming, re-engaged at the end
    return YES;
}

- (void)setCurrentViewportNeedsDisplay {
    NSRect visibleRect = _pageScrollView.contentView.bounds;
    if (NSWidth(visibleRect) > 0.0 && NSHeight(visibleRect) > 0.0)
        [_pageView setNeedsDisplayInRect:visibleRect];
    else
        [_pageView setNeedsDisplay:YES];
}

- (void)showEmptyDocumentViewWithMessage:(NSString*)message {
    _pageScrollView.hidden = NO;
    _pageView.emptyMessage = message.length ? message : @"Open a document";
    _pageView.currentPageIndex = 0;
    _pageView.activeFindPageIndex = -1;
    _pageView.activeFindAlpha = 0.0;
    _minimapPrecisionViewportDragActive = NO;
    _pageView.pages = @[];
    [self setMinimapActuallyVisible:NO];
    [self resizeDocumentView];
    NSString* expectedMessage = [_pageView.emptyMessage copy];
    dispatch_async(dispatch_get_main_queue(), ^{
      if (self->_doc || ![self->_pageView.emptyMessage isEqualToString:expectedMessage]) return;
      [self->_window.contentView layoutSubtreeIfNeeded];
      [self->_documentContainer layoutSubtreeIfNeeded];
      [self->_pageScrollView layoutSubtreeIfNeeded];
      [self resizeDocumentView];
    });
}

// Horizontal scroll origin that centers a page on the document canvas midline —
// the axis every page is laid out around (see ensureLayoutCache). For a document
// whose canvas is no wider than the viewport this clamps to ~0, so normal
// documents are unaffected; when an oversized page widens the canvas, a narrow
// page is shown centered on the same axis as the wide page rather than clinging
// to the left edge.
- (CGFloat)centeredHorizontalScrollOriginXForPageRect:(NSRect)pageRect {
    NSClipView* clipView = _pageScrollView.contentView;
    CGFloat clipWidth = NSWidth(clipView.bounds);
    CGFloat maxX = MAX(0.0, NSWidth(_pageView.bounds) - clipWidth);
    return spdf_clamp_cg(NSMidX(pageRect) - clipWidth * 0.5, 0.0, maxX);
}

- (void)cancelHorizontalLockEase {
    [_horizontalLockEaseTimer invalidate];
    _horizontalLockEaseTimer = nil;
}

// Set (or clear) the horizontal scroll lock. A finite x pins the viewport's
// horizontal origin there (blocking panning, keeping pages centered); NAN frees
// horizontal scrolling. When `animated` and the viewport is far from the target
// (i.e. we are leaving a wide page that was panned off-center), ease to it.
// Pin the viewport's horizontal origin at x (min==max => no horizontal panning,
// page stays centered); NAN frees it. When `animated` and the viewport is far
// from x (leaving a wide page that was panned off-center), ease to it.
- (void)setHorizontalScrollLockX:(CGFloat)x animated:(BOOL)animated {
    if (![_pageScrollView.contentView isKindOfClass:[SPDFDocumentClipView class]]) return;
    SPDFDocumentClipView* clip = (SPDFDocumentClipView*)_pageScrollView.contentView;
    // No horizontal rubber-band while pinned, so a viewport-fit page cannot be
    // wiggled off center; restore elasticity when horizontal panning is free.
    _pageScrollView.horizontalScrollElasticity = isfinite(x) ? NSScrollElasticityNone : NSScrollElasticityAllowed;
    if (!isfinite(x)) {
        [self cancelHorizontalLockEase];
        clip.horizontalLockMinX = NAN;
        clip.horizontalLockMaxX = NAN;
        return;
    }
    CGFloat current = NSMinX(clip.bounds);
    if (!animated || fabs(current - x) <= 1.0) {
        [self cancelHorizontalLockEase];
        clip.horizontalLockMinX = x;
        clip.horizontalLockMaxX = x;
        if (fabs(current - x) > 0.01) {
            NSPoint origin = clip.bounds.origin;
            origin.x = x;
            BOOL wasSuppressing = _suppressScrollCallbacks;
            _suppressScrollCallbacks = YES;
            [clip setBoundsOrigin:origin];
            [_pageScrollView reflectScrolledClipView:clip];
            _suppressScrollCallbacks = wasSuppressing;
        }
        return;
    }
    if (_horizontalLockEaseTimer && fabs(_horizontalLockEaseTargetX - x) <= 0.5) return; // already easing there
    [self cancelHorizontalLockEase];
    _horizontalLockEaseStartX = current;
    _horizontalLockEaseTargetX = x;
    _horizontalLockEaseStartTime = spdf_zoom_profile_now_ms();
    clip.horizontalLockMinX = current; // pin throughout; each tick advances it toward the target
    clip.horizontalLockMaxX = current;
    _horizontalLockEaseTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60.0
                                                                target:self
                                                              selector:@selector(stepHorizontalLockEase:)
                                                              userInfo:nil
                                                               repeats:YES];
}

// Confine horizontal panning to [minX, maxX] (a page wider than the viewport but
// narrower than the canvas) so the page can't be scrolled off into empty canvas.
// No ease — the page is freely pannable within the range; just snap the current
// origin into it if it fell outside.
- (void)setHorizontalScrollClampMinX:(CGFloat)minX maxX:(CGFloat)maxX {
    if (![_pageScrollView.contentView isKindOfClass:[SPDFDocumentClipView class]]) return;
    SPDFDocumentClipView* clip = (SPDFDocumentClipView*)_pageScrollView.contentView;
    [self cancelHorizontalLockEase];
    _pageScrollView.horizontalScrollElasticity = NSScrollElasticityAllowed;
    clip.horizontalLockMinX = minX;
    clip.horizontalLockMaxX = MAX(minX, maxX);
    CGFloat current = NSMinX(clip.bounds);
    CGFloat clamped = spdf_clamp_cg(current, clip.horizontalLockMinX, clip.horizontalLockMaxX);
    if (fabs(clamped - current) > 0.01) {
        NSPoint origin = clip.bounds.origin;
        origin.x = clamped;
        BOOL wasSuppressing = _suppressScrollCallbacks;
        _suppressScrollCallbacks = YES;
        [clip setBoundsOrigin:origin];
        [_pageScrollView reflectScrolledClipView:clip];
        _suppressScrollCallbacks = wasSuppressing;
    }
}

- (void)stepHorizontalLockEase:(NSTimer*)timer {
    if (![_pageScrollView.contentView isKindOfClass:[SPDFDocumentClipView class]]) {
        [self cancelHorizontalLockEase];
        return;
    }
    SPDFDocumentClipView* clip = (SPDFDocumentClipView*)_pageScrollView.contentView;
    const double durationMs = 220.0;
    double p = spdf_clamp_cg((spdf_zoom_profile_now_ms() - _horizontalLockEaseStartTime) / durationMs, 0.0, 1.0);
    double eased = 1.0 - pow(1.0 - p, 3.0); // easeOutCubic
    CGFloat x = _horizontalLockEaseStartX + (_horizontalLockEaseTargetX - _horizontalLockEaseStartX) * eased;
    clip.horizontalLockMinX = x;
    clip.horizontalLockMaxX = x;
    NSPoint origin = clip.bounds.origin; // preserve the live vertical scroll position
    origin.x = x;
    BOOL wasSuppressing = _suppressScrollCallbacks;
    _suppressScrollCallbacks = YES;
    [clip setBoundsOrigin:origin];
    [_pageScrollView reflectScrolledClipView:clip];
    _suppressScrollCallbacks = wasSuppressing;
    [_pageView setNeedsDisplay:YES];
    if (p >= 1.0) {
        clip.horizontalLockMinX = _horizontalLockEaseTargetX;
        clip.horizontalLockMaxX = _horizontalLockEaseTargetX;
        [self cancelHorizontalLockEase];
    }
}

// Lock horizontal panning on pages that fit the viewport (kept centered) and
// unlock it whenever a page wider than the viewport is in view. Crossing from a
// wide page back to narrow pages eases the viewport back to center.
- (void)updateHorizontalScrollLockAnimated:(BOOL)animated {
    if (![_pageScrollView.contentView isKindOfClass:[SPDFDocumentClipView class]]) return;
    if (!_doc || _renderedPages.count == 0 || _presentationMode || _liveZooming ||
        _minimapPrecisionViewportDragActive) {
        [self setHorizontalScrollLockX:NAN animated:NO];
        return;
    }
    NSClipView* clipView = _pageScrollView.contentView;
    CGFloat clipWidth = NSWidth(clipView.bounds);
    NSRect visibleRect = clipView.bounds;
    // Decide from the CURRENT (dominant) page only. While you are mostly on a
    // page that fits the viewport it stays centered and hard-locked — even if a
    // wider page is peeking in at the edge, so there is no horizontal wiggle.
    // Horizontal panning unlocks only once a page wider than the viewport becomes
    // the dominant page. Crossing that boundary (portrait<->landscape,
    // small<->big) is the only time the viewport eases back to center.
    NSRect pageRect = [_pageView rectForPageAtIndex:[_pageView pageIndexForVisibleRect:visibleRect]];
    if (NSIsEmptyRect(pageRect)) {
        [self setHorizontalScrollLockX:NAN animated:NO];
        return;
    }
    if (NSWidth(pageRect) > clipWidth + 0.5) {
        // Page wider than the viewport: pan within the PAGE only. The canvas can be
        // far wider (a bigger page elsewhere in a mixed-size document), so clamping
        // to the canvas would let you scroll off this page into empty space.
        CGFloat maxDocX = MAX(0.0, NSWidth(_pageView.bounds) - clipWidth);
        [self setHorizontalScrollClampMinX:spdf_clamp_cg(NSMinX(pageRect), 0.0, maxDocX)
                                      maxX:spdf_clamp_cg(NSMaxX(pageRect) - clipWidth, 0.0, maxDocX)];
        return;
    }
    [self setHorizontalScrollLockX:[self centeredHorizontalScrollOriginXForPageRect:pageRect] animated:animated];
}

// Vertical mirror of the horizontal lock, for the fits-vertically case: when the
// whole document fits the viewport at the current zoom (a single page at or
// below Fit Page — the layout centers it vertically, see ensureLayoutCache),
// there is nothing to scroll, so pin y (min==max) and drop the elastic bounce.
// Presentation mode and live pinch-zoom release the lock like the horizontal one.
- (void)updateVerticalScrollLock {
    if (![_pageScrollView.contentView isKindOfClass:[SPDFDocumentClipView class]]) return;
    SPDFDocumentClipView* clip = (SPDFDocumentClipView*)_pageScrollView.contentView;
    BOOL fitsVertically = _doc && _renderedPages.count > 0 && !_presentationMode && !_liveZooming &&
                          NSHeight(_pageView.bounds) <= NSHeight(clip.bounds) + 0.5;
    _pageScrollView.verticalScrollElasticity = fitsVertically ? NSScrollElasticityNone : NSScrollElasticityAllowed;
    clip.verticalLockMinY = fitsVertically ? 0.0 : NAN;
    clip.verticalLockMaxY = fitsVertically ? 0.0 : NAN;
    if (fitsVertically && fabs(NSMinY(clip.bounds)) > 0.01) {
        BOOL wasSuppressing = _suppressScrollCallbacks;
        _suppressScrollCallbacks = YES;
        [clip setBoundsOrigin:NSMakePoint(NSMinX(clip.bounds), 0.0)];
        [_pageScrollView reflectScrolledClipView:clip];
        _suppressScrollCallbacks = wasSuppressing;
    }
}

- (NSPoint)clampedDocumentScrollOrigin:(NSPoint)origin forPageIndex:(NSInteger)pageIndex {
    NSClipView* clipView = _pageScrollView.contentView;
    if (_renderedPages.count > 0) {
        pageIndex = MAX(0, MIN(pageIndex, (NSInteger)_renderedPages.count - 1));
        NSRect pageRect = [_pageView rectForPageAtIndex:pageIndex];
        if (!NSIsEmptyRect(pageRect)) {
            CGFloat visibleWidth = NSWidth(clipView.bounds);
            if (NSWidth(pageRect) <= visibleWidth + 0.5)
                origin.x = [self centeredHorizontalScrollOriginXForPageRect:pageRect];
            else
                origin.x = spdf_clamp_cg(origin.x, NSMinX(pageRect), NSMaxX(pageRect) - visibleWidth);
        }
    }
    origin.x = spdf_clamp_cg(origin.x, 0.0, MAX(0.0, NSWidth(_pageView.bounds) - NSWidth(clipView.bounds)));
    origin.y = spdf_clamp_cg(origin.y, 0.0, MAX(0.0, NSHeight(_pageView.bounds) - NSHeight(clipView.bounds)));
    return origin;
}

- (NSPoint)clampedDocumentScrollOrigin:(NSPoint)origin {
    NSInteger pageIndex = _pageIndex;
    if (_renderedPages.count > 0 && _pageScrollView) {
        NSClipView* clipView = _pageScrollView.contentView;
        NSRect proposedVisible = NSMakeRect(origin.x, origin.y, NSWidth(clipView.bounds), NSHeight(clipView.bounds));
        pageIndex = _presentationMode ? _pageIndex : [_pageView pageIndexForVisibleRect:proposedVisible];
    }
    return [self clampedDocumentScrollOrigin:origin forPageIndex:pageIndex];
}

- (NSPoint)clampedDocumentBoundsScrollOrigin:(NSPoint)origin {
    NSClipView* clipView = _pageScrollView.contentView;
    origin.x = spdf_clamp_cg(origin.x, 0.0, MAX(0.0, NSWidth(_pageView.bounds) - NSWidth(clipView.bounds)));
    origin.y = spdf_clamp_cg(origin.y, 0.0, MAX(0.0, NSHeight(_pageView.bounds) - NSHeight(clipView.bounds)));
    return origin;
}

- (NSPoint)normalizedDocumentScrollOrigin:(NSPoint)origin forPageIndex:(NSInteger)pageIndex {
    if (_renderedPages.count == 0) return [self clampedDocumentScrollOrigin:origin forPageIndex:pageIndex];

    pageIndex = MAX(0, MIN(pageIndex, (NSInteger)_renderedPages.count - 1));
    NSClipView* clipView = _pageScrollView.contentView;
    NSRect pageRect = [_pageView rectForPageAtIndex:pageIndex];
    if (NSIsEmptyRect(pageRect)) return [self clampedDocumentScrollOrigin:origin forPageIndex:pageIndex];

    if (_presentationMode) {
        CGFloat visibleHeight = NSHeight(clipView.bounds);
        if (NSHeight(pageRect) <= visibleHeight + 0.5) {
            origin.y = [self presentationCenteredScrollOriginYForPageIndex:pageIndex];
        } else {
            origin.y = spdf_clamp_cg(origin.y, NSMinY(pageRect), NSMaxY(pageRect) - visibleHeight);
        }
    }

    CGFloat visibleWidth = NSWidth(clipView.bounds);
    if (NSWidth(pageRect) <= visibleWidth + 0.5) {
        origin.x = [self centeredHorizontalScrollOriginXForPageRect:pageRect];
    } else if (origin.x <= NSMinX(pageRect) + 2.0) {
        origin.x = MAX(0.0, NSMinX(pageRect) - kPageMargin / 2.0);
    }

    return [self clampedDocumentScrollOrigin:origin forPageIndex:pageIndex];
}

/* Vertically centers a page in the viewport. Used only in presentation mode,
 * where the document view lays out one page at a time. */
- (CGFloat)presentationCenteredScrollOriginYForPageIndex:(NSInteger)pageIndex {
    if (_renderedPages.count == 0) return 0.0;
    pageIndex = MAX(0, MIN(pageIndex, (NSInteger)_renderedPages.count - 1));
    NSClipView* clipView = _pageScrollView.contentView;
    NSRect pageRect = [self continuousDocumentRectForPageAtIndex:pageIndex];
    if (NSIsEmptyRect(pageRect)) return 0.0;
    CGFloat maxY = MAX(0.0, NSHeight(_pageView.bounds) - NSHeight(clipView.bounds));
    CGFloat y = NSMidY(pageRect) - NSHeight(clipView.bounds) * 0.5;
    return spdf_clamp_cg(y, 0.0, maxY);
}

- (void)scrollDocumentClipViewToOrigin:(NSPoint)origin pageIndexHint:(NSInteger)pageIndex notify:(BOOL)notify {
    NSClipView* clipView = _pageScrollView.contentView;
    origin = pageIndex >= 0 ? [self clampedDocumentScrollOrigin:origin forPageIndex:pageIndex]
                            : [self clampedDocumentScrollOrigin:origin];
    _updatingFromScroll = YES;
    [NSAnimationContext
        runAnimationGroup:^(NSAnimationContext* context) {
          context.duration = 0.0;
          context.allowsImplicitAnimation = NO;
          [clipView setBoundsOrigin:origin];
          [self->_pageScrollView reflectScrolledClipView:clipView];
        }
        completionHandler:nil];
    _updatingFromScroll = NO;
    if (notify) {
        [self documentScrollPositionChanged];
        [self updateMinimap];
    }
}

- (void)scrollDocumentClipViewToDocumentOrigin:(NSPoint)origin notify:(BOOL)notify {
    NSClipView* clipView = _pageScrollView.contentView;
    // Page-aware clamp (not the raw canvas clamp) so a minimap drag keeps a
    // viewport-fit page centered and only pans pages wider than the viewport.
    origin = [self clampedDocumentScrollOrigin:origin];
    BOOL wasSuppressingScrollCallbacks = _suppressScrollCallbacks;
    if (!notify) _suppressScrollCallbacks = YES;
    _updatingFromScroll = YES;
    [NSAnimationContext
        runAnimationGroup:^(NSAnimationContext* context) {
          context.duration = 0.0;
          context.allowsImplicitAnimation = NO;
          [clipView setBoundsOrigin:origin];
          [self->_pageScrollView reflectScrolledClipView:clipView];
        }
        completionHandler:nil];
    _updatingFromScroll = NO;
    _suppressScrollCallbacks = wasSuppressingScrollCallbacks;
    if (notify) {
        [self documentScrollPositionChanged];
        [self updateMinimap];
    }
}

- (void)scrollDocumentClipViewToOrigin:(NSPoint)origin notify:(BOOL)notify {
    [self scrollDocumentClipViewToOrigin:origin pageIndexHint:-1 notify:notify];
}

- (void)documentViewPanToProposedOrigin:(NSPoint)origin {
    // Page-aware clamp centers a viewport-fit page (cannot be dragged off-center)
    // and pans a wider page. notify:NO keeps the per-event work light; the
    // explicit documentScrollPositionChanged drives the coalesced minimap update
    // (a full updateMinimap per pan event would be too heavy).
    [self scrollDocumentClipViewToOrigin:origin pageIndexHint:-1 notify:NO];
    [self documentScrollPositionChanged];
}

- (void)scrollToPage:(NSInteger)pageIndex alignTop:(BOOL)alignTop {
    if (_renderedPages.count == 0) return;
    pageIndex = MAX(0, MIN(pageIndex, (NSInteger)_renderedPages.count - 1));
    NSRect pageRect = [_pageView rectForPageAtIndex:pageIndex];
    if (alignTop) {
        NSClipView* clipView = _pageScrollView.contentView;
        CGFloat x = NSWidth(pageRect) <= NSWidth(clipView.bounds) + 0.5
                        ? [self centeredHorizontalScrollOriginXForPageRect:pageRect]
                        : MAX(0, pageRect.origin.x - 12.0);
        CGFloat y = spdf_mac_fit_scroll_origin_y(NSMinY(pageRect), NSHeight(pageRect), NSHeight(clipView.bounds), 12);
        if (_presentationMode) y = [self presentationCenteredScrollOriginYForPageIndex:pageIndex];
        NSPoint point = NSMakePoint(x, y);
        [self scrollDocumentClipViewToOrigin:point notify:NO];
    } else {
        NSClipView* clipView = _pageScrollView.contentView;
        NSRect visible = clipView.bounds;
        NSPoint origin = visible.origin;
        if (_presentationMode) origin.y = [self presentationCenteredScrollOriginYForPageIndex:pageIndex];
        // A page larger than the viewport on an axis has the viewport sitting
        // INSIDE it, so both "page extends past the start" and "page extends
        // past the end" are true at once; the nudges below would then toggle the
        // view between the two edges on each call — e.g. repeated Cmd+4 (actual
        // size) flipping a wide page between its left and right sides. Only nudge
        // an axis when the page does NOT already cover the viewport there, i.e.
        // part of the page is genuinely off-screen and needs bringing in.
        BOOL pageCoversViewportX =
            NSMinX(pageRect) <= NSMinX(visible) + 0.5 && NSMaxX(pageRect) >= NSMaxX(visible) - 0.5;
        if (!pageCoversViewportX) {
            if (NSMinX(pageRect) < NSMinX(visible))
                origin.x = NSMinX(pageRect) - 12.0;
            else if (NSMaxX(pageRect) > NSMaxX(visible))
                origin.x = NSMaxX(pageRect) - NSWidth(visible) + 12.0;
        }
        BOOL pageCoversViewportY =
            NSMinY(pageRect) <= NSMinY(visible) + 0.5 && NSMaxY(pageRect) >= NSMaxY(visible) - 0.5;
        if (!_presentationMode && !pageCoversViewportY) {
            if (NSMinY(pageRect) < NSMinY(visible))
                origin.y = NSMinY(pageRect) - 12.0;
            else if (NSMaxY(pageRect) > NSMaxY(visible))
                origin.y = NSMaxY(pageRect) - NSHeight(visible) + 12.0;
        }
        [self scrollDocumentClipViewToOrigin:origin notify:NO];
    }
    [self documentScrollPositionChanged];
    [self updateMinimap];
}

- (void)stabilizeDocumentLayoutWithRestoreOrigin:(NSValue*)restoreOrigin
                                        alignTop:(BOOL)alignTop
                                      generation:(NSUInteger)generation
                                            path:(NSString*)path {
    if (!_doc || generation != _renderGeneration || ![_path isEqualToString:path]) return;

    [NSAnimationContext
        runAnimationGroup:^(NSAnimationContext* context) {
          context.duration = 0.0;
          context.allowsImplicitAnimation = NO;
          [self->_window.contentView layoutSubtreeIfNeeded];
          [self->_documentContainer layoutSubtreeIfNeeded];
          [self->_pageScrollView layoutSubtreeIfNeeded];
          [self resizeDocumentView];
          if (restoreOrigin) {
              NSPoint origin = [self normalizedDocumentScrollOrigin:restoreOrigin.pointValue
                                                       forPageIndex:self->_pageIndex];
              [self scrollDocumentClipViewToOrigin:origin notify:NO];
          } else {
              [self scrollToPage:self->_pageIndex alignTop:alignTop];
          }
          [self renderVisiblePageCropsForCurrentViewportIfNeeded];
          [self->_pageView setNeedsDisplay:YES];
          [self->_pageScrollView displayIfNeeded];
        }
        completionHandler:nil];
    [self documentScrollPositionChanged];
    [self updateMinimap];
    if (!_suppressScrollCallbacks) [self rememberActiveTabState];
}

- (NSPoint)relativeScrollPositionForPage:(NSInteger)pageIndex fromVisibleRect:(NSRect)visibleRect {
    if (_renderedPages.count == 0) return NSZeroPoint;
    pageIndex = MAX(0, MIN(pageIndex, (NSInteger)_renderedPages.count - 1));
    NSRect pageRect = [_pageView rectForPageAtIndex:pageIndex];
    if (NSIsEmptyRect(pageRect)) return NSZeroPoint;

    CGFloat maxX = MAX(1.0, NSWidth(pageRect) - NSWidth(visibleRect));
    CGFloat maxY = MAX(1.0, NSHeight(pageRect) - NSHeight(visibleRect));
    CGFloat relativeX = spdf_clamp_cg((NSMinX(visibleRect) - NSMinX(pageRect)) / maxX, 0.0, 1.0);
    CGFloat relativeY = spdf_clamp_cg((NSMinY(visibleRect) - NSMinY(pageRect)) / maxY, 0.0, 1.0);
    return NSMakePoint(relativeX, relativeY);
}

- (NSPoint)relativeScrollPositionForCurrentPage {
    return [self relativeScrollPositionForPage:_pageIndex fromVisibleRect:_pageScrollView.contentView.bounds];
}

- (void)scrollToPage:(NSInteger)pageIndex preservingRelativePosition:(NSPoint)relativePosition {
    NSRect pageRect = [_pageView rectForPageAtIndex:MAX(0, MIN(pageIndex, (NSInteger)_renderedPages.count - 1))];
    // No source page given: preserve relative Y unconditionally (same-page relayout
    // case) by passing the target's own height so the mismatch guard never fires.
    [self scrollToPage:pageIndex preservingRelativePosition:relativePosition fromPageHeight:NSHeight(pageRect)];
}

- (void)scrollToPage:(NSInteger)pageIndex
    preservingRelativePosition:(NSPoint)relativePosition
                fromPageHeight:(CGFloat)fromPageHeight {
    if (_renderedPages.count == 0) return;
    pageIndex = MAX(0, MIN(pageIndex, (NSInteger)_renderedPages.count - 1));
    NSRect pageRect = [_pageView rectForPageAtIndex:pageIndex];
    if (NSIsEmptyRect(pageRect)) return;

    NSClipView* clipView = _pageScrollView.contentView;
    CGFloat maxInPageX = MAX(0.0, NSWidth(pageRect) - NSWidth(clipView.bounds));
    CGFloat maxInPageY = MAX(0.0, NSHeight(pageRect) - NSHeight(clipView.bounds));
    CGFloat maxDocumentX = MAX(0.0, NSWidth(_pageView.bounds) - NSWidth(clipView.bounds));
    CGFloat maxDocumentY = MAX(0.0, NSHeight(_pageView.bounds) - NSHeight(clipView.bounds));
    // relativePosition.y is a 0..1 fraction of the *source* page. Mapping it onto a
    // target page much taller than the source (e.g. paging into an oversized page
    // that is many viewports tall) yanks the viewport deep into / past the page
    // instead of landing just at its top boundary. When the target is >2x the
    // source height, align its top so navigation lands predictably "just above" it.
    BOOL targetMuchTaller = fromPageHeight > 0.5 && NSHeight(pageRect) > fromPageHeight * 2.0;
    CGFloat relativeY = targetMuchTaller ? 0.0 : spdf_clamp_cg(relativePosition.y, 0.0, 1.0);
    NSPoint origin = NSMakePoint(NSMinX(pageRect) + spdf_clamp_cg(relativePosition.x, 0.0, 1.0) * maxInPageX,
                                 NSMinY(pageRect) + relativeY * maxInPageY);
    if (NSWidth(pageRect) <= NSWidth(clipView.bounds) + 0.5)
        origin.x = [self centeredHorizontalScrollOriginXForPageRect:pageRect];
    if (_presentationMode) origin.y = [self presentationCenteredScrollOriginYForPageIndex:pageIndex];
    origin.x = spdf_clamp_cg(origin.x, 0.0, maxDocumentX);
    origin.y = spdf_clamp_cg(origin.y, 0.0, maxDocumentY);

    [self scrollDocumentClipViewToOrigin:origin notify:YES];
}

- (void)goToPage:(NSInteger)pageIndex preserveSinglePagePosition:(BOOL)preserveSinglePagePosition {
    if (!_doc) return;
    NSInteger pageCount = spdf_page_count(_doc);
    if (pageCount <= 0) return;
    pageIndex = MAX(0, MIN(pageIndex, pageCount - 1));
    NSPoint relativePosition = preserveSinglePagePosition ? [self relativeScrollPositionForCurrentPage] : NSZeroPoint;
    // Source page height, captured before _pageIndex moves to the target, so
    // scrollToPage: can suppress the relative-Y remap when crossing into a page
    // of very different height (e.g. an oversized schematic page).
    CGFloat sourcePageHeight = NSHeight([_pageView rectForPageAtIndex:_pageIndex]);
    [self cancelPendingLiveZoomCompletion];

    _pageIndex = pageIndex;
    _pageView.currentPageIndex = _pageIndex;
    [self clearPageFieldFocus];
    if (_presentationMode &&
        (_fitMode == SPDFFitModeWidth || _fitMode == SPDFFitModeHeight || _fitMode == SPDFFitModePage)) {
        [self renderDocumentAndScrollToPage:_pageIndex alignTop:YES];
        [self persistActiveState];
        return;
    }
    [self renderPageIfNeededAtIndex:_pageIndex];
    [self resizeDocumentView];
    if (preserveSinglePagePosition)
        [self scrollToPage:_pageIndex preservingRelativePosition:relativePosition fromPageHeight:sourcePageHeight];
    else
        [self scrollToPage:_pageIndex alignTop:YES];
    // The navigation scroll runs documentScrollPositionChanged, which re-detects
    // _pageIndex from the *dominant* (center) visible page. When several short
    // pages fit the viewport (zoomed out so a page is shorter than the viewport),
    // that center page differs from the navigation target: paging to N-1 aligns
    // its top but leaves page N centered, so _pageIndex snapped back to N and
    // "previous page" got stuck (it only re-aligned the top, never advanced).
    // Re-assert the explicit target so repeated paging moves one page each press.
    _pageIndex = pageIndex;
    _pageView.currentPageIndex = _pageIndex;
    [self spdf_queueViewportPageRendersNow];
    [self updateControls];
    [self selectCurrentSidebarRow];
    [_pageView setNeedsDisplay:YES];
    [self persistActiveState];
}

- (CGFloat)continuousDocumentHeightForMinimap {
    if (_presentationMode) {
        CGFloat height = kPageMargin / 2.0;
        for (SPDFRenderedPage* page in _renderedPages ?: @[]) height += MAX(1.0, page.pageHeight * _zoom) + kPageGap;
        height += kPageMargin / 2.0;
        return MAX(1.0, height);
    }
    return MAX(1.0, NSHeight(_pageView.bounds));
}

- (CGFloat)continuousDocumentWidthForMinimap {
    if (_presentationMode) {
        CGFloat widest = 0.0;
        for (SPDFRenderedPage* page in _renderedPages ?: @[]) widest = MAX(widest, page.pageWidth * _zoom);
        return MAX(1.0, MAX(NSWidth(_pageView.bounds), widest + kPageMargin));
    }
    return MAX(1.0, NSWidth(_pageView.bounds));
}

- (NSRect)continuousDocumentRectForPageAtIndex:(NSInteger)pageIndex {
    if (pageIndex < 0 || pageIndex >= (NSInteger)_renderedPages.count || !_pageView) return NSZeroRect;
    if (_presentationMode) {
        CGFloat y = kPageMargin / 2.0;
        for (NSInteger i = 0; i < pageIndex; ++i) {
            SPDFRenderedPage* prev = _renderedPages[(NSUInteger)i];
            y += MAX(1.0, prev.pageHeight * _zoom) + kPageGap;
        }

        SPDFRenderedPage* page = _renderedPages[(NSUInteger)pageIndex];
        CGFloat width = MAX(1.0, page.pageWidth * _zoom);
        CGFloat height = MAX(1.0, page.pageHeight * _zoom);
        CGFloat documentWidth = [self continuousDocumentWidthForMinimap];
        CGFloat x = floor((documentWidth - width) / 2.0);
        return NSMakeRect(MAX(kPageMargin / 2.0, x), y, width, height);
    }
    return [_pageView rectForPageAtIndex:pageIndex];
}

- (NSRect)continuousDocumentVisibleRectForMinimap {
    if (_presentationMode) {
        if (_renderedPages.count == 0) return NSZeroRect;
        NSInteger pageIndex = MAX(0, MIN(_pageIndex, (NSInteger)_renderedPages.count - 1));
        NSRect pageRect = [_pageView rectForPageAtIndex:pageIndex];
        NSRect visibleRect = _pageScrollView.contentView.bounds;
        NSRect intersection = NSIntersectionRect(visibleRect, pageRect);
        NSRect minimapPageRect = [self continuousDocumentRectForPageAtIndex:pageIndex];
        if (NSIsEmptyRect(minimapPageRect)) return NSZeroRect;
        if (NSIsEmptyRect(intersection)) return minimapPageRect;

        CGFloat x0 = spdf_clamp_cg((NSMinX(intersection) - NSMinX(pageRect)) / MAX(1.0, NSWidth(pageRect)), 0.0, 1.0);
        CGFloat x1 = spdf_clamp_cg((NSMaxX(intersection) - NSMinX(pageRect)) / MAX(1.0, NSWidth(pageRect)), 0.0, 1.0);
        CGFloat y0 = spdf_clamp_cg((NSMinY(intersection) - NSMinY(pageRect)) / MAX(1.0, NSHeight(pageRect)), 0.0, 1.0);
        CGFloat y1 = spdf_clamp_cg((NSMaxY(intersection) - NSMinY(pageRect)) / MAX(1.0, NSHeight(pageRect)), 0.0, 1.0);
        return NSMakeRect(NSMinX(minimapPageRect) + x0 * NSWidth(minimapPageRect),
                          NSMinY(minimapPageRect) + y0 * NSHeight(minimapPageRect),
                          MAX(1.0, (x1 - x0) * NSWidth(minimapPageRect)),
                          MAX(1.0, (y1 - y0) * NSHeight(minimapPageRect)));
    }
    return _pageScrollView.contentView.bounds;
}

- (NSInteger)pageIndexForContinuousDocumentY:(CGFloat)y pageFraction:(CGFloat*)pageFraction {
    if (_renderedPages.count == 0) {
        if (pageFraction) *pageFraction = 0.0;
        return 0;
    }

    NSInteger closestPage = 0;
    CGFloat closestDistance = CGFLOAT_MAX;
    for (SPDFRenderedPage* page in _renderedPages) {
        NSRect pageRect = [self continuousDocumentRectForPageAtIndex:page.pageIndex];
        if (NSIsEmptyRect(pageRect)) continue;
        if (y >= NSMinY(pageRect) && y <= NSMaxY(pageRect)) {
            if (pageFraction)
                *pageFraction = spdf_clamp_cg((y - NSMinY(pageRect)) / MAX(1.0, NSHeight(pageRect)), 0.0, 1.0);
            return page.pageIndex;
        }

        CGFloat distance = MIN(fabs(y - NSMinY(pageRect)), fabs(y - NSMaxY(pageRect)));
        if (distance < closestDistance) {
            closestDistance = distance;
            closestPage = page.pageIndex;
            if (pageFraction) *pageFraction = y < NSMinY(pageRect) ? 0.0 : 1.0;
        }
    }
    return closestPage;
}

- (NSPoint)continuousDocumentPointForPage:(NSInteger)pageIndex
                          xFractionInPage:(CGFloat)xFraction
                          yFractionInPage:(CGFloat)yFraction {
    NSRect pageRect = [self continuousDocumentRectForPageAtIndex:pageIndex];
    if (NSIsEmptyRect(pageRect)) return NSZeroPoint;
    return NSMakePoint(NSMinX(pageRect) + spdf_clamp_cg(xFraction, 0.0, 1.0) * NSWidth(pageRect),
                       NSMinY(pageRect) + spdf_clamp_cg(yFraction, 0.0, 1.0) * NSHeight(pageRect));
}

- (NSArray<NSValue*>*)continuousDocumentPageRectsForMinimap {
    NSMutableArray<NSValue*>* pageRects = [NSMutableArray arrayWithCapacity:_renderedPages.count];
    for (SPDFRenderedPage* page in _renderedPages ?: @[])
        [pageRects addObject:[NSValue valueWithRect:[self continuousDocumentRectForPageAtIndex:page.pageIndex]]];
    return pageRects;
}

- (void)scrollToPage:(NSInteger)pageIndex centeredAtPageXFraction:(CGFloat)xFraction yFraction:(CGFloat)yFraction {
    if (_renderedPages.count == 0) return;
    pageIndex = MAX(0, MIN(pageIndex, (NSInteger)_renderedPages.count - 1));
    xFraction = spdf_clamp_cg(xFraction, 0.0, 1.0);
    yFraction = spdf_clamp_cg(yFraction, 0.0, 1.0);

    NSRect pageRect = [_pageView rectForPageAtIndex:pageIndex];
    if (NSIsEmptyRect(pageRect)) return;

    NSClipView* clipView = _pageScrollView.contentView;
    CGFloat maxInPageX = MAX(0.0, NSWidth(pageRect) - NSWidth(clipView.bounds));
    CGFloat maxInPageY = MAX(0.0, NSHeight(pageRect) - NSHeight(clipView.bounds));
    CGFloat maxDocumentX = MAX(0.0, NSWidth(_pageView.bounds) - NSWidth(clipView.bounds));
    CGFloat maxDocumentY = MAX(0.0, NSHeight(_pageView.bounds) - NSHeight(clipView.bounds));
    NSPoint origin = NSMakePoint(NSMinX(pageRect) + NSWidth(pageRect) * xFraction - NSWidth(clipView.bounds) * 0.5,
                                 NSMinY(pageRect) + NSHeight(pageRect) * yFraction - NSHeight(clipView.bounds) * 0.5);
    if (NSWidth(pageRect) <= NSWidth(clipView.bounds) + 0.5)
        origin.x = [self centeredHorizontalScrollOriginXForPageRect:pageRect];
    else
        origin.x = spdf_clamp_cg(origin.x, NSMinX(pageRect), NSMinX(pageRect) + maxInPageX);
    origin.x = spdf_clamp_cg(origin.x, 0.0, maxDocumentX);
    if (_presentationMode)
        origin.y = [self presentationCenteredScrollOriginYForPageIndex:pageIndex];
    else
        origin.y = spdf_clamp_cg(origin.y, NSMinY(pageRect), NSMinY(pageRect) + maxInPageY);
    origin.y = spdf_clamp_cg(origin.y, 0.0, maxDocumentY);

    [self scrollDocumentClipViewToOrigin:origin notify:YES];
}

- (void)updateMinimap {
    SPDFScopedProfileLog spdfScopedProfile("updateMinimap", 4.0);
    if (!_minimapView) return;
    if ([self isMarkdownActive]) {
        [self updateMarkdownMinimap];
        return;
    }
    BOOL liveZooming = _liveZooming;
    if (liveZooming) {
        _minimapView.liveViewportOnly = YES;
        _minimapView.currentPageIndex = _pageIndex;
        _minimapView.documentPageRects = [self continuousDocumentPageRectsForMinimap];
        _minimapView.documentVisibleRect = [self continuousDocumentVisibleRectForMinimap];
        _minimapView.documentWidth = [self continuousDocumentWidthForMinimap];
        _minimapView.documentHeight = MAX(1.0, [self continuousDocumentHeightForMinimap]);
        _minimapView.documentScale = MAX(0.01, _zoom);
        [_minimapView setNeedsDisplay:YES];
        return;
    }
    _minimapView.liveViewportOnly = NO;
    _minimapView.pages = _renderedPages ?: @[];
    _minimapView.documentPageRects = [self continuousDocumentPageRectsForMinimap];
    _minimapView.currentPageIndex = _pageIndex;
    _minimapView.documentVisibleRect = [self continuousDocumentVisibleRectForMinimap];
    _minimapView.documentWidth = [self continuousDocumentWidthForMinimap];
    _minimapView.documentHeight = MAX(1.0, [self continuousDocumentHeightForMinimap]);
    _minimapView.documentScale = MAX(0.01, _zoom);
    [_minimapView setNeedsDisplay:YES];
    if (_windowLiveResizing) return;
    [self enqueueVisibleMinimapThumbnailRenders];
}

- (void)invalidateFindMarkers {
    [_pageScrollView.verticalScroller setNeedsDisplay:YES];
    [self.activeMarkdownSession invalidateSearchScrollbarMarkers];
}

- (NSArray<NSDictionary*>*)findScrollbarMarkers {
    if ([self isMarkdownActive]) return self.activeMarkdownSession.searchScrollbarMarkers;
    if (!_doc || _findMatches.count == 0 || _renderedPages.count == 0) return @[];

    CGFloat documentHeight = MAX(1.0, [self continuousDocumentHeightForMinimap]);
    NSMutableArray<NSDictionary*>* markers = [NSMutableArray arrayWithCapacity:_findMatches.count];
    for (NSInteger i = 0; i < (NSInteger)_findMatches.count; ++i) {
        NSDictionary* match = _findMatches[(NSUInteger)i];
        NSInteger page = [match[@"page"] integerValue];
        if (page < 0 || page >= (NSInteger)_renderedPages.count) continue;

        NSRect pageRect = [self continuousDocumentRectForPageAtIndex:page];
        NSRect matchRect = [match[@"rect"] rectValue];
        if (NSIsEmptyRect(pageRect) || NSIsEmptyRect(matchRect)) continue;

        CGFloat y = NSMinY(pageRect) + NSMidY(matchRect) * _zoom;
        [markers addObject:@{
            @"fraction" : @(spdf_clamp_cg(y / documentHeight, 0.0, 1.0)),
            @"active" : @(i == _findMatchIndex)
        }];
    }
    return markers;
}

- (void)minimapViewDidRequestScrollToFraction:(CGFloat)yFraction {
    if ([self isMarkdownActive]) {
        [self markdownMinimapViewportTopFraction:yFraction
                                 documentCenterX:NSMidX(self.activeMarkdownSession.documentVisibleRect)];
        return;
    }
    if (!_doc || _renderedPages.count == 0) return;
    yFraction = spdf_clamp_cg(yFraction, 0.0, 1.0);

    NSPoint documentPoint = NSMakePoint(NSMidX([self continuousDocumentVisibleRectForMinimap]),
                                        yFraction * [self continuousDocumentHeightForMinimap]);
    [self minimapViewDidRequestCenterAtDocumentPoint:documentPoint];
}

- (void)minimapViewDidRequestViewportTopFraction:(CGFloat)yFraction {
    if ([self isMarkdownActive]) {
        [self markdownMinimapViewportTopFraction:yFraction
                                 documentCenterX:NSMidX(self.activeMarkdownSession.documentVisibleRect)];
        return;
    }
    [self minimapViewDidRequestViewportTopFraction:yFraction
                                   documentCenterX:NSMidX([self continuousDocumentVisibleRectForMinimap])];
}

- (void)minimapViewDidRequestViewportTopFraction:(CGFloat)yFraction documentCenterX:(CGFloat)documentCenterX {
    if ([self isMarkdownActive]) {
        [self markdownMinimapViewportTopFraction:yFraction documentCenterX:documentCenterX];
        return;
    }
    if (!_doc || _renderedPages.count == 0) return;
    yFraction = spdf_clamp_cg(yFraction, 0.0, 1.0);

    if (_presentationMode) {
        NSRect visibleRect = [self continuousDocumentVisibleRectForMinimap];
        CGFloat documentHeight = [self continuousDocumentHeightForMinimap];
        CGFloat documentTop = yFraction * MAX(0.0, documentHeight - NSHeight(visibleRect));
        CGFloat pageFraction = 0.0;
        NSInteger pageIndex = [self pageIndexForContinuousDocumentY:documentTop + NSHeight(visibleRect) * 0.5
                                                       pageFraction:&pageFraction];
        NSRect pageRect = [self continuousDocumentRectForPageAtIndex:pageIndex];
        CGFloat xFraction =
            !NSIsEmptyRect(pageRect) && isfinite(documentCenterX)
                ? spdf_clamp_cg((documentCenterX - NSMinX(pageRect)) / MAX(1.0, NSWidth(pageRect)), 0.0, 1.0)
                : 0.5;
        [self minimapViewDidRequestCenterOnPage:pageIndex xFractionInPage:xFraction yFractionInPage:pageFraction];
        return;
    }

    NSClipView* clipView = _pageScrollView.contentView;
    CGFloat maxY = MAX(0.0, NSHeight(_pageView.bounds) - NSHeight(clipView.bounds));
    NSPoint origin = clipView.bounds.origin;
    if (isfinite(documentCenterX)) origin.x = documentCenterX - NSWidth(clipView.bounds) * 0.5;
    origin.y = yFraction * maxY;

    NSInteger pageIndex = [_pageView
        pageIndexForVisibleRect:NSMakeRect(origin.x, origin.y, NSWidth(clipView.bounds), NSHeight(clipView.bounds))];
    pageIndex = MAX(0, MIN(pageIndex, (NSInteger)_renderedPages.count - 1));
    if (_presentationMode && pageIndex != _pageIndex) {
        _pageIndex = pageIndex;
        _pageView.currentPageIndex = _pageIndex;
        [self renderPageIfNeededAtIndex:_pageIndex];
        [self updateControls];
        [self selectCurrentSidebarRow];
    }

    if (!_presentationMode) {
        _minimapPrecisionViewportDragActive = YES;
        [self setHorizontalScrollLockX:NAN animated:NO]; // minimap positions absolutely; don't pin x
        [self scrollDocumentClipViewToDocumentOrigin:origin notify:NO];
        [self syncCurrentPageFromVisibleViewportQueueRenders:YES forceHighPriority:YES];
        [self renderVisiblePageCropsForCurrentViewportIfNeeded];
        [_pageView setNeedsDisplay:YES];
        [_pageView displayIfNeeded];
        [self updateMinimap];
    } else {
        [self scrollDocumentClipViewToOrigin:origin pageIndexHint:pageIndex notify:YES];
        [self renderVisiblePageCropsForCurrentViewportIfNeeded];
        [_pageView setNeedsDisplay:YES];
        [self rememberActiveTabState];
    }
}

// Precise viewport drag: the minimap reports the document-Y where the viewport
// TOP should land (computed through the per-page piecewise minimap<->document
// map), instead of a global scroll fraction. This is correct even when the
// document contains a huge page whose minimap slot is tiny — a small drag inside
// it still scrolls a proportionally large document region. In non-presentation
// mode the minimap's document space is exactly _pageView.bounds, so documentTopY
// is the clip-view origin Y directly.
- (void)minimapViewDidRequestViewportTopDocumentY:(CGFloat)documentTopY documentCenterX:(CGFloat)documentCenterX {
    if ([self isMarkdownActive]) {
        [self markdownMinimapViewportTopDocumentY:documentTopY documentCenterX:documentCenterX];
        return;
    }
    if (!_doc || _renderedPages.count == 0) return;

    if (_presentationMode) {
        NSRect visibleRect = [self continuousDocumentVisibleRectForMinimap];
        CGFloat pageFraction = 0.0;
        NSInteger pageIndex = [self pageIndexForContinuousDocumentY:documentTopY + NSHeight(visibleRect) * 0.5
                                                       pageFraction:&pageFraction];
        NSRect pageRect = [self continuousDocumentRectForPageAtIndex:pageIndex];
        CGFloat xFraction =
            !NSIsEmptyRect(pageRect) && isfinite(documentCenterX)
                ? spdf_clamp_cg((documentCenterX - NSMinX(pageRect)) / MAX(1.0, NSWidth(pageRect)), 0.0, 1.0)
                : 0.5;
        [self minimapViewDidRequestCenterOnPage:pageIndex xFractionInPage:xFraction yFractionInPage:pageFraction];
        return;
    }

    NSClipView* clipView = _pageScrollView.contentView;
    CGFloat maxY = MAX(0.0, NSHeight(_pageView.bounds) - NSHeight(clipView.bounds));
    NSPoint origin = clipView.bounds.origin;
    if (isfinite(documentCenterX)) origin.x = documentCenterX - NSWidth(clipView.bounds) * 0.5;
    origin.y = spdf_clamp_cg(documentTopY, 0.0, maxY);

    _minimapPrecisionViewportDragActive = YES;
    [self setHorizontalScrollLockX:NAN animated:NO]; // minimap positions absolutely; don't pin x
    [self scrollDocumentClipViewToDocumentOrigin:origin notify:NO];
    [self syncCurrentPageFromVisibleViewportQueueRenders:YES forceHighPriority:YES];
    [self renderVisiblePageCropsForCurrentViewportIfNeeded];
    [_pageView setNeedsDisplay:YES];
    [_pageView displayIfNeeded];
    [self updateMinimap];
}

- (void)minimapViewDidFinishViewportDrag {
    _minimapPrecisionViewportDragActive = NO;
    if ([self isMarkdownActive]) {
        [self rememberActiveTabState];
        return;
    }
    if (!_doc || _renderedPages.count == 0) return;
    [self documentScrollPositionChanged];
    [self rememberActiveTabState];
}

- (void)minimapViewDidRequestScrollToPage:(NSInteger)pageIndex yFractionInPage:(CGFloat)yFraction {
    [self minimapViewDidRequestCenterOnPage:pageIndex xFractionInPage:0.5 yFractionInPage:yFraction];
}

- (void)minimapViewDidRequestCenterAtDocumentPoint:(NSPoint)documentPoint {
    if ([self isMarkdownActive]) {
        [self markdownMinimapCenterAtDocumentPoint:documentPoint];
        return;
    }
    if (!_doc || _renderedPages.count == 0) return;

    if (!_presentationMode) {
        NSClipView* clipView = _pageScrollView.contentView;
        NSPoint origin = NSMakePoint(documentPoint.x - NSWidth(clipView.bounds) * 0.5,
                                     documentPoint.y - NSHeight(clipView.bounds) * 0.5);
        CGFloat maxX = MAX(0.0, NSWidth(_pageView.bounds) - NSWidth(clipView.bounds));
        CGFloat maxY = MAX(0.0, NSHeight(_pageView.bounds) - NSHeight(clipView.bounds));
        origin.x = spdf_clamp_cg(origin.x, 0.0, maxX);
        origin.y = spdf_clamp_cg(origin.y, 0.0, maxY);

        [self scrollDocumentClipViewToOrigin:origin notify:YES];
        [self rememberActiveTabState];
        return;
    }

    CGFloat yFraction = 0.0;
    NSInteger pageIndex = [self pageIndexForContinuousDocumentY:documentPoint.y pageFraction:&yFraction];
    NSRect pageRect = [self continuousDocumentRectForPageAtIndex:pageIndex];
    CGFloat xFraction =
        NSIsEmptyRect(pageRect)
            ? 0.5
            : spdf_clamp_cg((documentPoint.x - NSMinX(pageRect)) / MAX(1.0, NSWidth(pageRect)), 0.0, 1.0);
    [self minimapViewDidRequestCenterOnPage:pageIndex xFractionInPage:xFraction yFractionInPage:yFraction];
}

- (void)minimapViewDidRequestCenterOnPage:(NSInteger)pageIndex
                          xFractionInPage:(CGFloat)xFraction
                          yFractionInPage:(CGFloat)yFraction {
    if ([self isMarkdownActive]) {
        [self markdownMinimapCenterOnPage:pageIndex xFractionInPage:xFraction yFractionInPage:yFraction];
        return;
    }
    if (!_doc || pageIndex < 0 || pageIndex >= (NSInteger)_renderedPages.count) return;
    xFraction = spdf_clamp_cg(xFraction, 0.0, 1.0);
    yFraction = spdf_clamp_cg(yFraction, 0.0, 1.0);
    NSPoint documentPoint = [self continuousDocumentPointForPage:pageIndex
                                                 xFractionInPage:xFraction
                                                 yFractionInPage:yFraction];
    if (!_presentationMode) {
        [self minimapViewDidRequestCenterAtDocumentPoint:documentPoint];
        return;
    }
    [self cancelPendingLiveZoomCompletion];
    _pageIndex = pageIndex;
    _pageView.currentPageIndex = _pageIndex;
    [self renderPageIfNeededAtIndex:_pageIndex];
    [self resizeDocumentView];
    [self scrollToPage:_pageIndex centeredAtPageXFraction:xFraction yFraction:yFraction];
    [self updateControls];
    [self selectCurrentSidebarRow];
    [self updateMinimap];
    [self persistActiveState];
}

- (NSPoint)pageViewPointForMinimapDocumentPoint:(NSPoint)documentPoint {
    if (_presentationMode) {
        CGFloat yFraction = 0.0;
        NSInteger pageIndex = [self pageIndexForContinuousDocumentY:documentPoint.y pageFraction:&yFraction];
        if (pageIndex != _pageIndex) {
            [self cancelPendingLiveZoomCompletion];
            _pageIndex = pageIndex;
            _pageView.currentPageIndex = _pageIndex;
            [self renderPageIfNeededAtIndex:_pageIndex];
            [self resizeDocumentView];
            [self updateControls];
            [self selectCurrentSidebarRow];
        }

        NSRect minimapPageRect = [self continuousDocumentRectForPageAtIndex:pageIndex];
        NSRect pageRect = [_pageView rectForPageAtIndex:pageIndex];
        if (!NSIsEmptyRect(minimapPageRect) && !NSIsEmptyRect(pageRect)) {
            CGFloat xFraction = spdf_clamp_cg(
                (documentPoint.x - NSMinX(minimapPageRect)) / MAX(1.0, NSWidth(minimapPageRect)), 0.0, 1.0);
            return NSMakePoint(NSMinX(pageRect) + xFraction * NSWidth(pageRect),
                               NSMinY(pageRect) + spdf_clamp_cg(yFraction, 0.0, 1.0) * NSHeight(pageRect));
        }
    }
    return documentPoint;
}

- (NSPoint)windowPointForMinimapDocumentPoint:(NSPoint)documentPoint {
    NSPoint pageViewPoint = [self pageViewPointForMinimapDocumentPoint:documentPoint];
    return [_pageView convertPoint:pageViewPoint toView:nil];
}

- (void)minimapViewDidReceiveScrollWheel:(NSEvent*)event {
    if ([self isMarkdownActive]) {
        [self markdownMinimapReceiveScrollWheel:event];
        return;
    }
    if (!_pageScrollView) return;
    [_pageScrollView scrollWheel:event];
}

- (void)minimapViewDidReceiveZoomScrollWheel:(NSEvent*)event documentPoint:(NSPoint)documentPoint {
    if ([self isMarkdownActive]) {
        [self markdownMinimapReceiveZoomScrollWheel:event documentPoint:documentPoint];
        return;
    }
    if (!_pageView) return;
    [self zoomWithScrollWheelEvent:event centeredAtWindowPoint:[self windowPointForMinimapDocumentPoint:documentPoint]];
}

- (void)minimapViewDidReceiveMagnify:(NSEvent*)event documentPoint:(NSPoint)documentPoint {
    [self minimapViewDidReceiveMagnifyDelta:event.magnification documentPoint:documentPoint];
}

- (void)minimapViewDidReceiveMagnifyDelta:(CGFloat)delta documentPoint:(NSPoint)documentPoint {
    if ([self isMarkdownActive]) {
        [self markdownMinimapReceiveMagnifyDelta:delta documentPoint:documentPoint];
        return;
    }
    if (!_pageView) return;
    [self zoomWithMagnifyDelta:delta centeredAtWindowPoint:[self windowPointForMinimapDocumentPoint:documentPoint]];
}

- (void)rememberActiveTabFindState {
    if (_selectedTabIndex < 0 || _selectedTabIndex >= (NSInteger)_tabs.count) return;
    SPDFDocumentTab* tab = _tabs[(NSUInteger)_selectedTabIndex];
    tab.searchText = _searchField.stringValue ?: @"";
    tab.searchRegex = _findRegexCheckbox.state == NSControlStateValueOn;
    tab.searchRegexMultiline = _findRegexMultiline;
    tab.findMatchIndex = _findMatchIndex;
}

- (void)rememberActiveTabState {
    if (_selectedTabIndex < 0 || _selectedTabIndex >= (NSInteger)_tabs.count) return;
    if ([self isMarkdownActive]) {
        [self rememberActiveMarkdownStateForTab:_tabs[(NSUInteger)_selectedTabIndex]];
        return;
    }
    if (!_doc || !_path.length) return;
    SPDFDocumentTab* tab = _tabs[(NSUInteger)_selectedTabIndex];
    tab.path = _path;
    tab.title = spdf_display_name_for_path(_path) ?: tab.title;
    tab.pageIndex = _pageIndex;
    tab.zoom = _zoom;
    tab.customZoom = _rememberedCustomZoom > 0 ? _rememberedCustomZoom : _zoom;
    tab.fitMode = _fitMode;
    tab.fitPageIndex = _fitPageIndex;
    tab.showSidebar = _sidebarPreferredVisible;
    tab.showMinimap = _minimapPreferredVisible;
    tab.hasMinimapPreference = YES;
    [self cacheActiveRenderedPagesForSelectedTab];
    tab.scrollOrigin = [self normalizedDocumentScrollOrigin:_pageScrollView.contentView.bounds.origin
                                               forPageIndex:_pageIndex];
    tab.hasScrollOrigin = YES;
    [self rememberActiveTabFindState];
    [self saveDocumentStateForTab:tab];
}

- (void)persistActiveState {
    SPDFScopedProfileLog spdfScopedProfile("persistActiveState", 4.0);
    [self rememberActiveTabState];
    [self savePersistentState];
}

- (NSInteger)indexOfTabForPath:(NSString*)path {
    NSString* standardized = path.stringByStandardizingPath;
    for (NSInteger i = 0; i < (NSInteger)_tabs.count; ++i) {
        NSString* tabPath = _tabs[(NSUInteger)i].path.stringByStandardizingPath;
        if ([tabPath isEqualToString:standardized]) return i;
    }
    return -1;
}

- (NSArray<NSString*>*)openTabPaths {
    NSMutableArray<NSString*>* paths = [NSMutableArray arrayWithCapacity:_tabs.count];
    for (SPDFDocumentTab* tab in _tabs) [paths addObject:tab.path ?: @""];
    return paths;
}

- (SPDFDocumentTab*)selectedTab {
    if (_selectedTabIndex < 0 || _selectedTabIndex >= (NSInteger)_tabs.count) return nil;
    return _tabs[(NSUInteger)_selectedTabIndex];
}

- (NSDictionary*)fileAttributesForPath:(NSString*)path {
    if (!path.length) return nil;
    return [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
}

- (void)recordFileAttributes:(NSDictionary*)attributes forTab:(SPDFDocumentTab*)tab {
    tab.cachedModificationDate = attributes[NSFileModificationDate];
    tab.cachedFileSize = [attributes[NSFileSize] unsignedLongLongValue];
}

#pragma mark - Read-only shadow copy

// Persistent directory for read-only render copies. Subdirectory of
// -supportDirectory (NOT NSTemporaryDirectory, which the OS purges): the copy
// must survive quit so session restore reopens the same copy without reading the
// source.
- (NSString*)readOnlyCopiesDirectory {
    NSString* dir = [[self supportDirectory] stringByAppendingPathComponent:@"ReadOnlyCopies"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

// Read-only detection on the SOURCE path via a BARE lstat() — SILENT (no macOS
// "access data from other apps" prompt), unlike -isWritableFileAtPath: (which is
// access(W_OK), a write-intent check that DOES prompt on a source from another
// app's container). Read-only iff the process cannot write per st_mode/uid/gid.
// A missing/non-regular path returns NO (handled by the missing-file UI), so it
// is not mistaken for read-only. KEEP -isWritableFileAtPath: only in the
// user-initiated Save-As gate (-activePDFNeedsSaveAsBeforeModificationWithReason:),
// where a prompt is acceptable.
- (BOOL)sourcePathIsReadOnly:(NSString*)path {
    struct stat st;
    if (!spdf_bare_lstat(path, &st)) return NO;
    return spdf_stat_is_read_only(&st);
}

// Source attributes for a read-only SOURCE via a bare lstat — SILENT. Returns
// the (NSFileSize, NSFileModificationDate) shape used everywhere for cache
// coherency and copy-reuse comparison, without the prompting
// -attributesOfItemAtPath:. nil when the path cannot be stat'd as a regular file.
- (NSDictionary*)readOnlySourceAttributesForPath:(NSString*)path {
    return spdf_bare_lstat_attributes(path);
}

// One-stop source-attribute resolution that NEVER prompts for a read-only
// source: a single bare lstat() determines read-only and (when read-only) yields
// the (size, mtime) attributes silently; only a writable source falls through to
// the richer -attributesOfItemAtPath:. Writes the resolved read-only flag into
// `tab` (so the orange dot stays current). Returns nil for a missing/unreadable
// path (caller surfaces the missing-file UI). This is the single source touch
// for a read-only tab on every open/refresh path: a bare lstat, nothing more.
- (NSDictionary*)sourceAttributesForTab:(SPDFDocumentTab*)tab path:(NSString*)path {
    struct stat st;
    if (spdf_bare_lstat(path, &st)) {
        if (spdf_stat_is_read_only(&st)) {
            if (tab) tab.readOnly = YES;
            NSTimeInterval mtime =
                (NSTimeInterval)st.st_mtimespec.tv_sec + (NSTimeInterval)st.st_mtimespec.tv_nsec / 1e9;
            return @{
                NSFileSize : @((unsigned long long)st.st_size),
                NSFileModificationDate : [NSDate dateWithTimeIntervalSince1970:mtime]
            };
        }
        if (tab) tab.readOnly = NO;
    }
    // Writable (or could-not-lstat): unchanged behavior — full attributes.
    return [self fileAttributesForPath:path];
}

// Deterministic copy filename bound to the standardized source path so an
// unchanged source reclaims the same copy across relaunch (and the orphan sweep
// can match it). Distinct sources -> distinct copies (no worker-cache collision).
// Uses a SHA-256 digest of the standardized path (NOT NSString -hash, which is
// not stable across launches/OS versions and is collision-prone) so a fresh
// open of an unchanged source reclaims the same copy and the digest is stable.
- (NSString*)readOnlyCopyFileNameForSourcePath:(NSString*)sourcePath {
    NSString* standardized = sourcePath.stringByStandardizingPath ?: sourcePath;
    NSData* bytes = [standardized dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, digest);
    // 16 bytes (128 bits) of the digest is collision-resistant for this use.
    NSMutableString* hex = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < 16; ++i) [hex appendFormat:@"%02x", digest[i]];
    NSString* ext = sourcePath.pathExtension.length ? sourcePath.pathExtension : @"pdf";
    return [NSString stringWithFormat:@"ro-%@.%@", hex, ext];
}

// Ensure the tab has a read-only render copy of its (read-only) SOURCE and
// return the copy path; returns the source path for writable files (no copy).
//
// `attributes` MUST be the SOURCE's (NSFileSize, NSFileModificationDate) — for a
// read-only source callers pass the bare-lstat attributes (silent), never
// -attributesOfItemAtPath: on the source. Change detection compares those
// full source/copy fingerprints against the stat the copy reflects. The copy is
// refreshed from the source CONTENT only when it is missing or the source
// changed; that content read is the ONE place the macOS prompt may appear. An
// unchanged source reopens the existing copy with no content read.
- (NSString*)ensureWorkingPathForTab:(SPDFDocumentTab*)tab
                          sourcePath:(NSString*)sourcePath
                          attributes:(NSDictionary*)attributes {
    // Main-thread callers: resolve AND apply the binding to the tab in one step.
    SPDFReadOnlyCopyResolution resolution = [self resolveWorkingPathForTab:tab
                                                                sourcePath:sourcePath
                                                                attributes:attributes];
    [self applyReadOnlyCopyResolution:resolution toTab:tab];
    return resolution.workingPath ?: sourcePath;
}

// Resolve the read-only render copy for `tab`'s source WITHOUT mutating the tab.
// The (possibly slow / prompting) source content read + copy write happen here so
// they can run off-main; the tab's nonatomic binding fields are then applied via
// -applyReadOnlyCopyResolution:toTab: ON THE MAIN THREAD (see the deferred cloud
// open path). `attributes` MUST be the SOURCE's stat (bare-lstat for a read-only
// source — never the prompting -attributesOfItemAtPath:). The reads of
// tab.workingPath/copiedSource* below are change-detection inputs; in the deferred
// cloud path the tab is a single token-serialized restored tab not yet bound to a
// copy, so they are stable for the duration of the resolve.
- (SPDFReadOnlyCopyResolution)resolveWorkingPathForTab:(SPDFDocumentTab*)tab
                                            sourcePath:(NSString*)sourcePath
                                            attributes:(NSDictionary*)attributes {
    SPDFReadOnlyCopyResolution resolution = {nil, 0, nil, NO, nil};
    if (!tab || !sourcePath.length) {
        resolution.workingPath = sourcePath;
        return resolution;
    }
    if (![self sourcePathIsReadOnly:sourcePath]) {
        // Writable: drop any stale copy binding, render straight from the source.
        if (tab.workingPath.length) {
            [NSFileManager.defaultManager removeItemAtPath:tab.workingPath error:nil];
        }
        resolution.workingPath = sourcePath;
        return resolution;
    }

    NSString* copyPath = tab.workingPath.length ? tab.workingPath : [[self readOnlyCopiesDirectory]
        stringByAppendingPathComponent:[self readOnlyCopyFileNameForSourcePath:sourcePath]];
    // Migrating legacy metadata must not cause a new source read on launch or
    // speculative preload. Actual consultation can renew this unproven copy.
    if (!tab.readOnlyCopyBinding.count && SPDFReuseLegacyReadOnlyCopy(copyPath, tab.copiedSourceFileSize,
        tab.copiedSourceModificationDate, attributes, _startupDocumentWorkInProgress || tab != [self selectedTab]))
        return {copyPath, tab.copiedSourceFileSize, tab.copiedSourceModificationDate, YES, nil};
    return SPDFResolveReadOnlyCopy(sourcePath, copyPath, tab.readOnlyCopyBinding, ^{
        [self ensureSecurityAccessForPath:sourcePath];
    });
}

// Apply a resolved read-only copy binding to the tab. MUST run on the main thread
// (tab.workingPath/copiedSource* are nonatomic main-thread state). hasCopyBinding
// records the stat the app-owned copy reflects; otherwise the binding is cleared
// and rendering uses the source path directly (writable source / read-write
// fallback).
- (void)applyReadOnlyCopyResolution:(SPDFReadOnlyCopyResolution)resolution toTab:(SPDFDocumentTab*)tab {
    if (!tab) return;
    // A renewed copy may represent a same-size/date source replacement; the
    // page cache's older size/date key alone cannot safely reuse its document.
    if (tab.cachedDocument && ![tab.readOnlyCopyBinding isEqual:resolution.fingerprintBinding] &&
        (tab.readOnlyCopyBinding.count || resolution.fingerprintBinding.count)) [self discardCachedRuntimeForTab:tab];
    if (resolution.hasCopyBinding) {
        tab.workingPath = resolution.workingPath;
        tab.copiedSourceFileSize = resolution.fileSize;
        tab.copiedSourceModificationDate = resolution.modificationDate;
        tab.readOnlyCopyBinding = resolution.fingerprintBinding;
    } else {
        tab.workingPath = nil;
        tab.copiedSourceFileSize = 0;
        tab.copiedSourceModificationDate = nil;
        tab.readOnlyCopyBinding = nil;
    }
}

// Render/read path for the ACTIVE document: the temp copy when the active source
// is read-only, else the source. Consumed only by document-open/render workers.
- (NSString*)activeWorkingPath {
    return _workingPath.length ? _workingPath : _path;
}

// Launch-time sweep: delete any file in ReadOnlyCopies not referenced by a
// workingPath on a LIVE tab across all windows. Deferred until after tabs are
// restored and the post-first-paint catch-up save (see
// -resumePersistentStateSavesAfterLaunch) so it never races copy (re)creation
// nor reads a stale on-disk session. The referenced set is built on the main
// thread from in-memory tabs; only the directory enumeration + removal runs
// off-main. A recency backstop skips files touched in the last 60s as defense
// against any copy created concurrently. The directory may not exist yet on a
// fresh install — guarded.
- (void)sweepOrphanedReadOnlyCopies {
    // Build the referenced set from live tabs on the main thread (tab arrays are
    // main-thread state).
    NSMutableSet<NSString*>* referenced = [NSMutableSet set];
    for (ShenzhenMacDelegate* controller in gSPDFWindowControllers ?: @[]) {
        for (SPDFDocumentTab* tab in controller->_tabs) {
            NSString* wp = tab.workingPath;
            if (wp.length) [referenced addObject:wp.lastPathComponent];
        }
    }

    NSString* dir = [self readOnlyCopiesDirectory];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      @autoreleasepool {
          NSFileManager* fm = NSFileManager.defaultManager;
          NSArray<NSString*>* contents = [fm contentsOfDirectoryAtPath:dir error:nil];
          if (contents.count == 0) return;
          NSDate* recencyCutoff = [NSDate dateWithTimeIntervalSinceNow:-60.0];
          for (NSString* name in contents) {
              if ([referenced containsObject:name]) continue;
              NSString* full = [dir stringByAppendingPathComponent:name];
              // Skip a copy created/modified during this launch (not yet bound
              // to a live tab) so a concurrent open is never swept.
              NSDate* modified = [fm attributesOfItemAtPath:full error:nil][NSFileModificationDate];
              if (modified && [modified compare:recencyCutoff] == NSOrderedDescending) continue;
              [fm removeItemAtPath:full error:nil];
          }
      }
    });
}

// Delete a tab's read-only temp copy unless another tab — in ANY window — still
// references the same copy file (shared read-only source). The copy filename is
// deterministic by standardized source path, so the same ro-<sha>.pdf is shared
// across windows that open the same source; the shared-use scan must therefore
// cover every window's tabs (mirroring -sweepOrphanedReadOnlyCopies), not just
// this window's. Used both when a tab is deliberately closed and when Save-As
// converts it to a writable file. excludeTab is the tab being closed/converted
// (skipped during the scan, since its own binding is being torn down).
- (void)deleteReadOnlyCopyIfUnsharedForTab:(SPDFDocumentTab*)excludeTab {
    NSString* copyPath = excludeTab.workingPath;
    if (!copyPath.length) return;
    for (ShenzhenMacDelegate* controller in gSPDFWindowControllers ?: @[]) {
        for (SPDFDocumentTab* other in controller->_tabs) {
            if (other == excludeTab) continue;
            if ([other.workingPath isEqualToString:copyPath]) return; // still in use
        }
    }
    [NSFileManager.defaultManager removeItemAtPath:copyPath error:nil];
}

// Called right after one of our own in-place saves to _path (comment add/edit/
// delete). Re-records the on-disk mtime/size into the active tab's cache so the
// auto-reload watcher sees disk == cache and does not treat our write as an
// external change. Save-as, rotate, and OCR already refresh the cache via their
// own loadSelectedTab / saveActiveDocumentToPath paths.
- (void)refreshActiveTabCachedFileAttributesAfterSelfSave {
    SPDFDocumentTab* tab = [self selectedTab];
    if (!tab || !_path.length) return;
    if (![tab.path.stringByStandardizingPath isEqualToString:_path.stringByStandardizingPath]) return;
    NSDictionary* attributes = [self fileAttributesForPath:_path];
    if (attributes) [self recordFileAttributes:attributes forTab:tab];
}

- (BOOL)fileAttributes:(NSDictionary*)lhs matchFileAttributes:(NSDictionary*)rhs {
    if (!lhs || !rhs) return NO;
    NSDate* lhsModificationDate = lhs[NSFileModificationDate];
    NSDate* rhsModificationDate = rhs[NSFileModificationDate];
    unsigned long long lhsFileSize = [lhs[NSFileSize] unsignedLongLongValue];
    unsigned long long rhsFileSize = [rhs[NSFileSize] unsignedLongLongValue];
    return lhsModificationDate && [lhsModificationDate isEqualToDate:rhsModificationDate] && lhsFileSize == rhsFileSize;
}

- (BOOL)tab:(SPDFDocumentTab*)tab cacheMatchesFileAttributes:(NSDictionary*)attributes {
    if (!tab.cachedDocument || !attributes) return NO;
    NSDate* modificationDate = attributes[NSFileModificationDate];
    unsigned long long fileSize = [attributes[NSFileSize] unsignedLongLongValue];
    return tab.cachedModificationDate && [tab.cachedModificationDate isEqualToDate:modificationDate] &&
           tab.cachedFileSize == fileSize;
}

#pragma mark - Auto-reload on disk change

// Lazily install / re-point the watcher onto the active tab's file. Called from
// the tab-activation paths (loadSelectedTab tails) and on tab switch. Nothing
// is created until a document is actually active, so launch's critical path
// never installs a watcher or stats inactive tabs.
- (void)repointActiveFileWatcher {
    SPDFDocumentTab* tab = [self selectedTab];
    NSString* path = tab.path;
    // Only watch a live, on-disk document. _doc is the rendered-document handle,
    // NULL for Markdown -- which is why Markdown never reloaded on a disk change.
    if ((!_doc && !self.isMarkdownActive) || !path.length || tab.missingFile) {
        [self teardownActiveFileWatcher];
        return;
    }
    if (!_activeFileWatcher) {
        _activeFileWatcher = [[SPDFMacFileWatcher alloc] init];
        __weak ShenzhenMacDelegate* weakSelf = self;
        _activeFileWatcher.changeHandler = ^(NSString* changedPath) {
          [weakSelf activeFileWatcherDidReportChangeForPath:changedPath];
        };
    }
    // Read-only source: change detection runs via the poll-only watcher — a plain
    // NSTimer that NEVER opens an FSEvents stream nor an O_EVTONLY vnode fd on the
    // source (either would prompt). It only nudges the owner, which then does a
    // bare lstat() (silent) to detect a real change. Writable sources keep the
    // FSEvents/vnode event watch unchanged.
    BOOL pollOnly = tab.readOnly || [self sourcePathIsReadOnly:path];
    [_activeFileWatcher watchPath:path pollOnly:pollOnly];
}

- (void)teardownActiveFileWatcher {
    [_activeFileWatcher stop];
}

// Watcher callback (main thread, debounced). Authoritative check: only reload
// when the on-disk mtime/size actually differ from the active tab's cached
// values, so our own writes (which update the cache) never self-trigger.
- (void)activeFileWatcherDidReportChangeForPath:(NSString*)changedPath {
    if (_reloadInProgress) return;
    SPDFDocumentTab* tab = [self selectedTab];
    if (!tab || !tab.path.length) return;
    // Ensure the event still refers to the currently active tab (a tab switch
    // between the event and the debounce fire re-points the watcher, but guard
    // anyway).
    if (![tab.path.stringByStandardizingPath isEqualToString:changedPath.stringByStandardizingPath]) return;
    if (tab.missingFile) return;

    // Read-only source: detect changes with a BARE lstat (silent) — never the
    // prompting -attributesOfItemAtPath:. Writable sources keep NSFileManager.
    NSDictionary* attributes =
        tab.readOnly ? [self readOnlySourceAttributesForPath:tab.path] : [self fileAttributesForPath:tab.path];
    if (!attributes) {
        // File temporarily absent (atomic replace in flight) or genuinely gone.
        // Retry briefly before surfacing the missing-file UI.
        [self collectionRecordObservedChangeAtPath:tab.path];
        [self handleActiveTabFileTemporarilyMissing:tab path:[tab.path copy] attempt:0];
        return;
    }

    // For a read-only tab the authoritative "did the source change" comparison is
    // fresh source-lstat vs the stat the copy reflects (copiedSource*) — the
    // source stat captured when the copy was last (re)created. (cachedModification
    // Date/cachedFileSize also hold the source stat for a read-only tab, but
    // copiedSource* is the canonical baseline.) A match means no change.
    BOOL unchanged;
    if (tab.readOnly) {
        unchanged = [self fileAttributes:attributes
                     matchFileAttributes:@{
                         NSFileModificationDate : tab.copiedSourceModificationDate ?: [NSDate distantPast],
                         NSFileSize : @(tab.copiedSourceFileSize)
                     }];
    } else {
        // Cache match => no real change (covers our own saves, which refresh the
        // cache).
        unchanged = [self fileAttributes:attributes
                     matchFileAttributes:@{
                         NSFileModificationDate : tab.cachedModificationDate ?: [NSDate distantPast],
                         NSFileSize : @(tab.cachedFileSize)
                     }];
    }
    if (unchanged) {
        // Re-point the watcher in case an atomic replace swapped the inode
        // (writable only; the poll-only read-only watcher has no inode binding).
        if (!tab.readOnly) [_activeFileWatcher watchPath:tab.path];
        return;
    }

    [self collectionRecordObservedChangeAtPath:tab.path];
    // Changed: reload. For a read-only tab this re-runs loadSelectedTab, which
    // recreates the copy from the new source content (the one allowed prompt) via
    // -ensureWorkingPathForTab: and re-renders the open document.
    [self reloadSelectedTabFromDiskChange];
}

- (void)handleActiveTabFileTemporarilyMissing:(SPDFDocumentTab*)tab path:(NSString*)path attempt:(NSInteger)attempt {
    static const NSInteger kMaxMissingRetries = 5; // ~5 * 0.25s = ~1.25s grace
    if (![tab.path.stringByStandardizingPath isEqualToString:path.stringByStandardizingPath]) return;
    // Read-only source: probe with a bare lstat (silent), compare against the
    // stat the copy reflects; writable keeps NSFileManager + the cached stat.
    NSDictionary* attributes =
        tab.readOnly ? [self readOnlySourceAttributesForPath:path] : [self fileAttributesForPath:path];
    if (attributes) {
        // Reappeared (atomic replace landed). Re-point and reload if changed.
        if (!tab.readOnly) [_activeFileWatcher watchPath:path];
        NSDictionary* baseline =
            tab.readOnly ? @{
                NSFileModificationDate : tab.copiedSourceModificationDate ?: [NSDate distantPast],
                NSFileSize : @(tab.copiedSourceFileSize)
            }
                         : @{
                               NSFileModificationDate : tab.cachedModificationDate ?: [NSDate distantPast],
                               NSFileSize : @(tab.cachedFileSize)
                           };
        if (![self fileAttributes:attributes matchFileAttributes:baseline]) {
            [self reloadSelectedTabFromDiskChange];
        }
        return;
    }
    if (attempt >= kMaxMissingRetries) {
        // Stayed gone: fall through to the existing missing-file presentation by
        // discarding the cache and re-running the load, which detects the
        // absence and shows the standard "File moved or deleted" UI.
        [self reloadSelectedTabFromDiskChange];
        return;
    }
    __weak ShenzhenMacDelegate* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [weakSelf handleActiveTabFileTemporarilyMissing:tab path:path attempt:attempt + 1];
    });
}

// Reload the active document in place, preserving the user's view (page, zoom,
// fit mode, scroll origin, search). Reuses rememberActiveTabState (capture) +
// loadSelectedTab (reopen + restore). loadSelectedTab clamps the page index to
// the new page count and re-records the on-disk attributes, so the refreshed
// cache will match disk and not immediately re-trigger.
// All non-active tabs are not watched continuously. When the window regains key
// focus, check each tab once against its cached mtime/size and reload/refresh
// any that changed. Cheap: a single stat per tab, only the active tab reopens
// here (inactive tabs simply drop their stale cache so the next switch reopens).
- (void)checkAllTabsForExternalChangesOnFocus {
    if (_reloadInProgress) return;
    if (_selectedTabIndex < 0 || _selectedTabIndex >= (NSInteger)_tabs.count) return;
    SPDFDocumentTab* activeTab = [self selectedTab];

    for (SPDFDocumentTab* tab in _tabs) {
        if (!tab.path.length || tab.missingFile) continue;
        // Read-only source: detect changes with a BARE lstat (silent), compared
        // against the stat the copy reflects (copiedSource*). Never stat the
        // SOURCE via the prompting -attributesOfItemAtPath:.
        if (tab.readOnly) {
            // A read-only tab with no copy binding yet has nothing to compare;
            // it stats fresh (via bare lstat) on first activation.
            if (!tab.copiedSourceModificationDate && tab.copiedSourceFileSize == 0) continue;
            NSDictionary* attributes = [self readOnlySourceAttributesForPath:tab.path];
            if (!attributes) continue; // transient; reappearance handled on next focus
            BOOL matches = [self fileAttributes:attributes
                            matchFileAttributes:@{
                                NSFileModificationDate : tab.copiedSourceModificationDate ?: [NSDate distantPast],
                                NSFileSize : @(tab.copiedSourceFileSize)
                            }];
            if (matches) continue;
            [self collectionRecordObservedChangeAtPath:tab.path];
            // Source changed: the active tab reloads (recreates the copy from the
            // new content + re-renders); an inactive tab drops its cache so the
            // next activation reopens and refreshes the copy via loadSelectedTab.
            if (tab == activeTab)
                [self reloadSelectedTabFromDiskChange];
            else
                [self discardCachedRuntimeForTab:tab];
            continue;
        }
        // Only meaningful for tabs we have a cached snapshot for; a tab never
        // opened has no cache to compare and will stat fresh on first switch.
        if (!tab.cachedModificationDate && tab.cachedFileSize == 0) continue;
        NSDictionary* attributes = [self fileAttributesForPath:tab.path];
        if (!attributes) continue; // transient; active tab covered by its watcher
        BOOL matches = [self fileAttributes:attributes
                        matchFileAttributes:@{
                            NSFileModificationDate : tab.cachedModificationDate ?: [NSDate distantPast],
                            NSFileSize : @(tab.cachedFileSize)
                        }];
        if (matches) continue;
        [self collectionRecordObservedChangeAtPath:tab.path];

        if (tab == activeTab) {
            [self reloadSelectedTabFromDiskChange];
        } else {
            // Drop the stale cached document so the next activation reopens from
            // disk and restores saved state via the normal loadSelectedTab path.
            [self discardCachedRuntimeForTab:tab];
        }
    }
}

- (BOOL)ensureCachedRenderedPagesForTab:(SPDFDocumentTab*)tab preferredPage:(NSInteger)preferredPage {
    if (!tab.cachedDocument) return NO;
    NSInteger pageCount = spdf_page_count(tab.cachedDocument);
    if (pageCount <= 0) return NO;
    if (tab.cachedRenderedPages.count == (NSUInteger)pageCount) return YES;

    [self primePageGeometryCacheForDocument:tab.cachedDocument
                          pageGeometryState:[self pageGeometryStateForPath:tab.path]
                                   fileSize:tab.cachedFileSize
                           modificationDate:tab.cachedModificationDate];

    preferredPage = MAX(0, MIN(preferredPage, pageCount - 1));
    char err[256];
    float fallbackWidth = 1.0;
    float fallbackHeight = 1.0;
    spdf_page_size(tab.cachedDocument, (int)preferredPage, &fallbackWidth, &fallbackHeight, err, sizeof(err));
    NSMutableArray<SPDFRenderedPage*>* pages = [NSMutableArray arrayWithCapacity:(NSUInteger)pageCount];
    for (NSInteger pageIndex = 0; pageIndex < pageCount; ++pageIndex) {
        SPDFRenderedPage* page = [self placeholderPageAtIndex:pageIndex
                                                     document:tab.cachedDocument
                                                fallbackWidth:MAX(1.0f, fallbackWidth)
                                               fallbackHeight:MAX(1.0f, fallbackHeight)];
        if (!page) return NO;
        [pages addObject:page];
    }
    tab.cachedRenderedPages = pages;
    return YES;
}

// Debounced follow-up for completed page renders. A burst of finishing prefetch
// renders would otherwise each run an O(total-pages) eviction sweep and a full
// minimap rebuild on the main thread — the page-to-page scroll stutter. Run that
// once per ~80ms instead, and only rebuild the minimap when not actively
// scrolling (the scroll path drives the minimap itself; a full updateMinimap
// mid-scroll would throw away and rebuild the strip cache).
- (void)scheduleRenderAdoptionMaintenance {
    if (_renderAdoptionMaintenanceScheduled) return;
    _renderAdoptionMaintenanceScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      self->_renderAdoptionMaintenanceScheduled = NO;
      if (!self->_doc) return;
      // Eviction only — NOT updateMinimap. A completed full-page render never
      // changes a minimap THUMBNAIL (those are patched separately as they load),
      // so the full updateMinimap here was pointless; worse, its "idle" guard
      // false-positives during a scroll stall (no scroll events => generation
      // frozen => looks idle), firing a strip-cache rebuild mid-scroll. That
      // rebuild was the stutter, and it fed back into the next stall.
      [self evictDistantRenderedPageImages];
    });
}

- (void)cacheActiveRenderedPagesForSelectedTab {
    SPDFScopedProfileLog spdfScopedProfile("cacheActiveRenderedPages", 4.0);
    SPDFDocumentTab* tab = [self selectedTab];
    if (!tab || tab.cachedDocument != _doc ||
        ![_path.stringByStandardizingPath isEqualToString:tab.path.stringByStandardizingPath])
        return;
    tab.cachedRenderedPages = _renderedPages;
}

- (void)clearActiveMetadata {
    if (!_activeMetadataBorrowed) {
        spdf_free_outline(&_outline);
        spdf_free_comments(&_comments);
    }
    memset(&_outline, 0, sizeof(_outline));
    memset(&_comments, 0, sizeof(_comments));
    _activeMetadataBorrowed = NO;
    _activeMetadataTab = nil;
}

- (void)adoptCachedMetadataForTab:(SPDFDocumentTab*)tab {
    [self clearActiveMetadata];
    if (!tab) return;
    if (tab.cachedOutlineLoaded) _outline = tab.cachedOutline;
    if (tab.cachedCommentsLoaded) _comments = tab.cachedComments;
    _activeMetadataBorrowed = YES;
    _activeMetadataTab = tab;
}

- (void)loadInitialSidebarMetadataForSelectedTabIfNeeded {
    SPDFDocumentTab* tab = [self selectedTab];
    if (!_doc || !tab) return;

    // Synchronously load the outline/comments before the first frame so the
    // sidebar is in its final state (shown/hidden, with content) when the launch
    // frame paints — instead of popping in once the async metadata load lands.
    // The window-first launch shows a bare window early, so `!_window.visible` is
    // no longer a reliable "first frame" signal; `_startupDocumentWorkInProgress`
    // is true exactly while the launch document is loading, which is the case we
    // want to preload for (covers both restored open docs and a new document).
    BOOL preloadForFirstFrame = (_startupDocumentWorkInProgress || !_window.visible) && _sidebarPreferredVisible;
    // The launch prerender loaded these off-main while the window was being
    // built; adopt them rather than repeating the work on the main thread. The
    // document check keeps a multi-file launch from handing one file's outline
    // to another file's tab.
    if (_launchPrerenderedMetadataDocument && _launchPrerenderedMetadataDocument == _doc) {
        if (_launchPrerenderedOutlineLoaded && !tab.cachedOutlineLoaded) {
            [tab replaceCachedOutline:_launchPrerenderedOutline loaded:YES];
            memset(&_launchPrerenderedOutline, 0, sizeof(_launchPrerenderedOutline));
            _launchPrerenderedOutlineLoaded = NO;
        }
        if (_launchPrerenderedCommentsLoaded && !tab.cachedCommentsLoaded) {
            [tab replaceCachedComments:_launchPrerenderedComments loaded:YES];
            memset(&_launchPrerenderedComments, 0, sizeof(_launchPrerenderedComments));
            _launchPrerenderedCommentsLoaded = NO;
        }
        [self releaseLaunchPrerenderedMetadata];
    }
    if (preloadForFirstFrame && !tab.cachedOutlineLoaded) {
        spdf_outline outline;
        memset(&outline, 0, sizeof(outline));
        char err[1024];
        BOOL ok = spdf_load_outline(_doc, &outline, err, sizeof(err));
        if (ok) {
            [tab replaceCachedOutline:outline loaded:YES];
        } else {
            spdf_free_outline(&outline);
            spdf_outline emptyOutline;
            memset(&emptyOutline, 0, sizeof(emptyOutline));
            [tab replaceCachedOutline:emptyOutline loaded:YES];
        }
    }
    if (preloadForFirstFrame && !tab.cachedCommentsLoaded) {
        spdf_comments comments;
        memset(&comments, 0, sizeof(comments));
        char err[1024];
        BOOL ok = spdf_load_comments(_doc, &comments, err, sizeof(err));
        if (ok) {
            [tab replaceCachedComments:comments loaded:YES];
        } else {
            spdf_free_comments(&comments);
            spdf_comments emptyComments;
            memset(&emptyComments, 0, sizeof(emptyComments));
            [tab replaceCachedComments:emptyComments loaded:YES];
        }
    }
    [self adoptCachedMetadataForTab:tab];
}

- (void)discardCachedRuntimeForTab:(SPDFDocumentTab*)tab {
    if (!tab) return;
    if (_activeMetadataTab == tab) [self clearActiveMetadata];
    if (_doc == tab.cachedDocument) _doc = NULL;
    [tab clearCachedRuntime];
}

- (void)closeActiveDocumentIfUnowned {
    if (!_doc) return;
    for (SPDFDocumentTab* tab in _tabs) {
        if (tab.cachedDocument == _doc) {
            _doc = NULL;
            return;
        }
    }
    spdf_close(_doc);
    _doc = NULL;
}

- (void)cancelInactiveTabPreloads {
    [_inactiveTabPreloadQueue cancelAllOperations];
    [_preloadingPaths removeAllObjects];
    [_preloadTokens removeAllObjects];
    [_preloadResults removeAllObjects];
}

- (BOOL)preloadToken:(NSString*)token isCurrentForPath:(NSString*)standardizedPath {
    return token.length > 0 && [(_preloadTokens[standardizedPath] ?: @"") isEqualToString:token];
}

- (void)finishPreloadForPath:(NSString*)standardizedPath token:(NSString*)token {
    if (![self preloadToken:token isCurrentForPath:standardizedPath]) return;
    [_preloadTokens removeObjectForKey:standardizedPath];
    [_preloadingPaths removeObject:standardizedPath];
    [_preloadResults removeObjectForKey:standardizedPath];
}

- (void)showUnavailableSelectedTab:(SPDFDocumentTab*)tab
                              path:(NSString*)path
                           message:(NSString*)message
                     showOpenError:(BOOL)showOpenError
                             error:(const char*)err {
    if ([self collectionRestoreMissingTab:tab path:path]) return;
    [self discardCachedRuntimeForTab:tab];
    _doc = NULL;
    [self clearActiveMetadata];
    [self prepareSelectedTabViewState:tab path:path];
    _pageIndex = 0;
    _renderGeneration++;
    [_renderedPages removeAllObjects];
    [self replaceDocumentViewForTabSwitch];
    [self rebuildSidebar];
    [self showEmptyDocumentViewWithMessage:message];
    _window.title = [NSString
        stringWithFormat:@"%@ - %@ - Shenzhen PDF", [self displayNameForPathConsideringOpenTabs:path], message];
    _statusLabel.stringValue = [message stringByAppendingString:@"."];
    [self updateTabStrip];
    [self updateControls];
    [self clearToolbarFieldFocusForTabSwitch];
    // No live source: release its watcher until the next consultation.
    [self teardownActiveFileWatcher];
    [self savePersistentState];
    BOOL recoveryAvailable = [self collectionPresentMissingPath:path];
    if (showOpenError && !recoveryAvailable) {
        [self showError:@"Could not open document"
                 detail:[NSString stringWithUTF8String:err && *err ? err : "Unknown error"]];
    }
}

- (SPDFDocumentTab*)tabForStandardizedPath:(NSString*)standardizedPath index:(NSInteger*)indexOut {
    for (NSInteger i = 0; i < (NSInteger)_tabs.count; ++i) {
        SPDFDocumentTab* tab = _tabs[(NSUInteger)i];
        if ([tab.path.stringByStandardizingPath isEqualToString:standardizedPath]) {
            if (indexOut) *indexOut = i;
            return tab;
        }
    }
    if (indexOut) *indexOut = -1;
    return nil;
}

- (NSString*)displayNameForPathConsideringOpenTabs:(NSString*)path {
    if (!path.length) return @"";
    for (SPDFDocumentTab* tab in _tabs) if ([tab.path isEqual:path] && (tab.collectionVersionLabel.length || spdf_tab_display_name(tab))) return tab.collectionVersionLabel.length ? tab.collectionVersionLabel : spdf_tab_display_name(tab);
    NSString* standardized = path.stringByStandardizingPath;
    NSArray<NSString*>* paths = [self openTabPaths];
    NSArray<NSString*>* names = spdf_disambiguated_display_names_for_paths(paths);
    for (NSUInteger i = 0; i < paths.count && i < names.count; ++i) {
        if ([paths[i].stringByStandardizingPath isEqualToString:standardized] && names[i].length) return names[i];
    }
    return spdf_display_name_for_path(path);
}

- (void)updateTabStrip {
    [self normalizeTabGroups];
    _tabStrip.emptyGroups = [self emptyTabGroups]; _tabStrip.tabs = _tabs;
    _tabStrip.selectedIndex = _selectedTabIndex;
    [self updateTabStripFrame];
}

- (void)updateTabStripFrame {
    if (!_tabStrip || !_window) return;
    BOOL fullScreen = (_window.styleMask & NSWindowStyleMaskFullScreen) == NSWindowStyleMaskFullScreen;
    CGFloat leadingInset = fullScreen ? 16.0 : 138.0;
    NSButton* zoomButton = fullScreen ? nil : [_window standardWindowButton:NSWindowZoomButton];
    if (zoomButton && _tabStrip.window) {
        NSRect buttonWindowRect = [zoomButton convertRect:zoomButton.bounds toView:nil];
        NSRect buttonRect = [_tabStrip convertRect:buttonWindowRect fromView:nil];
        if (NSMaxX(buttonRect) > 30.0 && NSMaxX(buttonRect) < NSWidth(_tabStrip.bounds) / 2.0)
            leadingInset = NSMaxX(buttonRect) + 18.0;
    }
    _tabStrip.reservedLeadingInset = leadingInset;
    [_tabStrip setNeedsDisplay:YES];
}

- (BOOL)eventHitsStandardWindowButton:(NSEvent*)event {
    if (!_window || !event) return NO;
    for (NSNumber* buttonType in @[ @(NSWindowCloseButton), @(NSWindowMiniaturizeButton), @(NSWindowZoomButton) ]) {
        NSButton* button = [_window standardWindowButton:(NSWindowButton)buttonType.integerValue];
        if (!button || button.hidden || !button.enabled) continue;
        NSRect buttonRect = [button convertRect:button.bounds toView:nil];
        buttonRect = NSInsetRect(buttonRect, -8.0, -8.0);
        if (NSPointInRect(event.locationInWindow, buttonRect)) return YES;
    }
    return NO;
}

- (BOOL)eventHitsTopChromeResizeCorner:(NSEvent*)event {
    if (!_window || !event) return NO;
    NSView* contentView = _window.contentView;
    if (!contentView) return NO;
    NSPoint point = [contentView convertPoint:event.locationInWindow fromView:nil];
    NSRect bounds = contentView.bounds;
    CGFloat corner = kTopChromeResizeCornerSize;
    if (NSWidth(bounds) < corner * 3.0 || NSHeight(bounds) < corner * 3.0) return NO;
    BOOL nearTop = point.y >= NSMaxY(bounds) - corner && point.y <= NSMaxY(bounds) + 1.0;
    if (!nearTop) return NO;
    return point.x <= NSMinX(bounds) + corner || point.x >= NSMaxX(bounds) - corner;
}

- (void)performTopChromeWindowDragWithEvent:(NSEvent*)event {
    [self dismissTabHoverPanel];
    [(SPDFWindow*)_window handleChromeMouseDown:event];
}

- (void)preloadInactiveTabsWithCompletion:(dispatch_block_t)completion {
    NSArray<NSNumber*>* order = [_launchWorkCoordinator orderedInactiveIndexesForIdentifiers:_tabs
                                                                               selectedIndex:_selectedTabIndex];
    NSOperation* previousOperation = nil;
    for (NSNumber* index in order) {
        NSInteger i = index.integerValue;
        SPDFDocumentTab* tab = _tabs[(NSUInteger)i];
        NSString* path = [tab.path copy];
        if (!path.length) continue;
        if (SPDFIsRenderedTextDocumentPath(path)) continue;
        NSString* standardized = [path.stringByStandardizingPath copy];
        if ([_preloadingPaths containsObject:standardized]) continue;

        BOOL readOnly = [self sourcePathIsReadOnly:path];
        NSDictionary* attributes = [self sourceAttributesForTab:tab path:path];
        if (!attributes) {
            [self discardCachedRuntimeForTab:tab];
            tab.missingFile = YES;
            tab.missingMessage = @"File moved or deleted";
            continue;
        }
        NSString* workingPath = [self ensureWorkingPathForTab:tab sourcePath:path attributes:attributes];
        if ([self tab:tab cacheMatchesFileAttributes:attributes]) {
            tab.missingFile = NO;
            tab.missingMessage = @"";
            continue;
        }

        if (tab.cachedDocument) [self collectionRecordObservedChangeAtPath:path];
        [_preloadingPaths addObject:standardized];
        NSString* preloadToken = NSUUID.UUID.UUIDString;
        _preloadTokens[standardized] = preloadToken;
        SPDFMacInactivePreload* preloadResult = [SPDFMacInactivePreload new];
        _preloadResults[standardized] = preloadResult;
        NSInteger preferredPage = MAX(0, tab.pageIndex);
        NSInteger fitPage = spdf_tab_fit_page_index(tab, preferredPage, NSIntegerMax);
        SPDFFitMode fitMode = tab.fitMode;
        CGFloat fallbackZoom = tab.customZoom > 0 ? tab.customZoom : (tab.zoom > 0 ? tab.zoom : 1.0);
        NSSize clipSize = [self documentClipSizeForLayout];
        CGFloat displayScale = [self backingScale];
        NSDictionary* pageGeometryState = [self pageGeometryStateForPath:path];

        NSDictionary* capturedReadOnlyAttributes = readOnly ? attributes : nil;
        __block __weak SPDFRenderOperation* weakOperation = nil;
        SPDFRenderOperation* operation = [SPDFRenderOperation operationWithRenderBlock:^(spdf_render_token* token) {
          @autoreleasepool {
              if (weakOperation.cancelled || ![preloadResult workerMayBeginOpen]) {
                  [preloadResult workerFinishedWithoutDocument];
                  return;
              }
              NSDictionary* operationAttributes = readOnly ? capturedReadOnlyAttributes
                                                           : [NSFileManager.defaultManager attributesOfItemAtPath:path
                                                                                                            error:nil];
              if (!operationAttributes) {
                  [preloadResult workerFinishedWithoutDocument];
                  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                    if (![self preloadToken:preloadToken isCurrentForPath:standardized]) return;
                    [self finishPreloadForPath:standardized token:preloadToken];
                    NSInteger tabIndex = -1;
                    SPDFDocumentTab* currentTab = [self tabForStandardizedPath:standardized index:&tabIndex];
                    if (!currentTab || tabIndex == self->_selectedTabIndex) return;
                    [self discardCachedRuntimeForTab:currentTab];
                    currentTab.missingFile = YES;
                    currentTab.missingMessage = @"File moved or deleted";
                    [self updateTabStrip];
                  }];
                  return;
              }
              if (weakOperation.cancelled) {
                  [preloadResult workerFinishedWithoutDocument];
                  return;
              }

              char err[1024];
              spdf_open_status openStatus = SPDF_OPEN_ERROR;
              spdf_document* doc = [self openSpdfDocumentAtPath:workingPath
                                                     sourcePath:path
                                                         status:&openStatus
                                                          error:err
                                                    errorLength:sizeof(err)];
              if (weakOperation.cancelled && doc) {
                  if (![preloadResult workerFinishedCancelledDocument:doc attributes:operationAttributes])
                      spdf_close(doc);
                  return;
              }
              if (!doc) {
                  [preloadResult workerFinishedWithoutDocument];
                  if (openStatus == SPDF_OPEN_PASSWORD_REQUIRED || openStatus == SPDF_OPEN_BAD_PASSWORD) {
                      [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                        if ([self preloadToken:preloadToken isCurrentForPath:standardized])
                            [self finishPreloadForPath:standardized token:preloadToken];
                      }];
                      return;
                  }
                  NSString* message = @"Could not open document";
                  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                    if (![self preloadToken:preloadToken isCurrentForPath:standardized]) return;
                    [self finishPreloadForPath:standardized token:preloadToken];
                    NSInteger tabIndex = -1;
                    SPDFDocumentTab* currentTab = [self tabForStandardizedPath:standardized index:&tabIndex];
                    if (!currentTab || tabIndex == self->_selectedTabIndex) return;
                    [self discardCachedRuntimeForTab:currentTab];
                    currentTab.missingFile = NO;
                    currentTab.missingMessage = message;
                    [self updateTabStrip];
                  }];
                  return;
              }
              if (![preloadResult workerMayContinueWithDocument:doc attributes:operationAttributes]) {
                  [preloadResult workerFinishedWithPages:nil];
                  return;
              }
              if (weakOperation.cancelled) {
                  if (![preloadResult workerFinishedCancelledDocument:doc attributes:operationAttributes])
                      spdf_close(doc);
                  return;
              }
              [self primePageGeometryCacheForDocument:doc
                                    pageGeometryState:pageGeometryState
                                             fileSize:spdf_file_size_from_attributes(operationAttributes)
                                     modificationDate:spdf_file_modification_date_from_attributes(operationAttributes)];
              if (weakOperation.cancelled) {
                  if (![preloadResult workerFinishedCancelledDocument:doc attributes:operationAttributes])
                      spdf_close(doc);
                  return;
              }

              NSInteger pageCount = spdf_page_count(doc);
              if (pageCount <= 0) {
                  spdf_close(doc);
                  [preloadResult workerFinishedWithoutDocument];
                  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                    if (![self preloadToken:preloadToken isCurrentForPath:standardized]) return;
                    [self finishPreloadForPath:standardized token:preloadToken];
                    NSInteger tabIndex = -1;
                    SPDFDocumentTab* currentTab = [self tabForStandardizedPath:standardized index:&tabIndex];
                    if (!currentTab || tabIndex == self->_selectedTabIndex) return;
                    [self discardCachedRuntimeForTab:currentTab];
                    currentTab.missingFile = NO;
                    currentTab.missingMessage = @"Could not open document";
                    [self updateTabStrip];
                  }];
                  return;
              }

              NSInteger pageIndex = MAX(0, MIN(preferredPage, pageCount - 1));
              float pageWidth = 0;
              float pageHeight = 0;
              spdf_page_size(doc, (int)pageIndex, &pageWidth, &pageHeight, err, sizeof(err));
              CGFloat fallbackWidth = pageWidth > 0 ? pageWidth : 1.0;
              CGFloat fallbackHeight = pageHeight > 0 ? pageHeight : 1.0;
              NSMutableArray<SPDFRenderedPage*>* pages = [NSMutableArray arrayWithCapacity:(NSUInteger)pageCount];
              for (NSInteger page = 0; page < pageCount; ++page) {
                  if (weakOperation.cancelled) {
                      if (![preloadResult workerFinishedCancelledDocument:doc attributes:operationAttributes])
                          spdf_close(doc);
                      return;
                  }
                  SPDFRenderedPage* renderedPage = [self placeholderPageAtIndex:page
                                                                       document:doc
                                                                  fallbackWidth:fallbackWidth
                                                                 fallbackHeight:fallbackHeight];
                  if (!renderedPage) {
                      if (![preloadResult workerFinishedCancelledDocument:doc attributes:operationAttributes])
                          spdf_close(doc);
                      [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                        if (![self preloadToken:preloadToken isCurrentForPath:standardized]) return;
                        [self finishPreloadForPath:standardized token:preloadToken];
                        [self updateTabStrip];
                      }];
                      return;
                  }
                  [pages addObject:renderedPage];
              }

              if (weakOperation.cancelled) {
                  if (![preloadResult workerFinishedCancelledDocument:doc attributes:operationAttributes])
                      spdf_close(doc);
                  return;
              }
              float fitWidth = pageWidth, fitHeight = pageHeight; // the zoom it will show: spdf_tab_fit_page_index
              if (fitPage != pageIndex && fitPage < pageCount)
                  spdf_page_size(doc, (int)fitPage, &fitWidth, &fitHeight, err, sizeof(err));
              CGFloat zoom = [self zoomForFitMode:fitMode
                                         pageSize:NSMakeSize(fitWidth, fitHeight)
                                         clipSize:clipSize
                                     fallbackZoom:fallbackZoom];
              err[0] = '\0';
              SPDFRenderedPage* preferredRenderedPage = [self renderedPageAtIndex:pageIndex
                                                                         document:doc
                                                                             zoom:zoom
                                                                     displayScale:displayScale
                                                                      renderToken:token
                                                                            error:err
                                                                      errorLength:sizeof(err)];
              if (weakOperation.cancelled || spdf_render_was_canceled(err)) {
                  if (![preloadResult workerFinishedCancelledDocument:doc attributes:operationAttributes])
                      spdf_close(doc);
                  return;
              }
              if (preferredRenderedPage) {
                  SPDFRenderedPage* old = pages[(NSUInteger)pageIndex];
                  preferredRenderedPage.highlights = old.highlights ?: @[];
                  preferredRenderedPage.selectionRects = old.selectionRects ?: @[];
                  [pages replaceObjectAtIndex:(NSUInteger)pageIndex withObject:preferredRenderedPage];
              }

              [preloadResult workerFinishedWithPages:pages];
              [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                if (![self preloadToken:preloadToken isCurrentForPath:standardized]) {
                    return;
                }
                [self finishPreloadForPath:standardized token:preloadToken];
                NSDictionary* completedAttributes = nil;
                NSArray* completedPages = nil;
                spdf_document* completedDocument =
                    (spdf_document*)[preloadResult takeBackgroundDocumentWithAttributes:&completedAttributes
                                                                                  pages:&completedPages];
                if (!completedDocument) return;
                NSInteger tabIndex = -1;
                SPDFDocumentTab* currentTab = [self tabForStandardizedPath:standardized index:&tabIndex];
                if (!currentTab || tabIndex == self->_selectedTabIndex) {
                    spdf_close(completedDocument);
                    return;
                }
                NSDictionary* cacheCheckAttributes =
                    readOnly ? capturedReadOnlyAttributes : [self fileAttributesForPath:currentTab.path];
                if (![self fileAttributes:completedAttributes matchFileAttributes:cacheCheckAttributes]) {
                    spdf_close(completedDocument);
                    return;
                }
                [self discardCachedRuntimeForTab:currentTab];
                currentTab.cachedDocument = completedDocument;
                [self collectionDidOpenPath:currentTab.path]; [self aiDocumentDidOpen:currentTab.path];
                currentTab.cachedRenderedPages = [completedPages mutableCopy];
                [self recordFileAttributes:completedAttributes forTab:currentTab];
                currentTab.missingFile = NO;
                currentTab.missingMessage = @"";
                currentTab.title = spdf_display_name_for_path(currentTab.path);
                [self updateTabStrip];
              }];
          }
        }];
        weakOperation = operation;
        preloadResult.operation = operation;
        if (previousOperation) [operation addDependency:previousOperation];
        [_inactiveTabPreloadQueue addOperation:operation];
        previousOperation = operation;
    }
    if (completion) {
        NSBlockOperation* completionOperation = [NSBlockOperation blockOperationWithBlock:^{
          [[NSOperationQueue mainQueue] addOperationWithBlock:completion];
        }];
        if (previousOperation) [completionOperation addDependency:previousOperation];
        [_inactiveTabPreloadQueue addOperation:completionOperation];
    }
    [self updateTabStrip];
}

// Reload comments synchronously from the in-memory document after a local
// mutation (add/edit/delete). The active _doc already holds the saved
// annotation, so reading it directly is both correct and immediate. Going
// through loadCommentsForCurrentDocumentAsync here would leave the new comment
// out of the sidebar and hover overlay: it short-circuits on the now-stale
// cachedCommentsLoaded fast path, and even when forced async its result is
// dropped by the render-generation guard once the follow-up render bumps the
// generation. Background renders use per-thread worker documents, so the main
// thread owns _doc exclusively and this load is race-free.
- (void)reloadCommentsFromActiveDocument {
    SPDFDocumentTab* tab = [self selectedTab];
    if (!_doc || !tab) return;
    spdf_comments comments;
    memset(&comments, 0, sizeof(comments));
    char err[1024];
    if (spdf_load_comments(_doc, &comments, err, sizeof(err))) {
        [tab replaceCachedComments:comments loaded:YES];
    } else {
        spdf_free_comments(&comments);
        spdf_comments emptyComments;
        memset(&emptyComments, 0, sizeof(emptyComments));
        [tab replaceCachedComments:emptyComments loaded:YES];
    }
    [self adoptCachedMetadataForTab:tab];
    [self rebuildSidebar];
    // Annotation edits can change what stext extracts (e.g. FreeText contents),
    // so the cursor-region caches rebuild lazily from the updated document.
    [self invalidateCursorRegionCache];
    [_pageView setNeedsDisplay:YES];
}

- (void)loadCommentsForCurrentDocumentAsync {
    if (!_doc || !_path.length) return;
    SPDFDocumentTab* tab = [self selectedTab];
    if (tab.cachedCommentsLoaded) {
        [self adoptCachedMetadataForTab:tab];
        [self rebuildSidebar];
        [_pageView setNeedsDisplay:YES];
        return;
    }

    NSString* workingPath = [self activeWorkingPath]; // temp copy for read-only source
    NSString* standardizedPath = [_path.stringByStandardizingPath copy];
    NSUInteger generation = _renderGeneration;
    [_preloadQueue addOperationWithBlock:^{
      @autoreleasepool {
          __block spdf_comments comments;
          memset(&comments, 0, sizeof(comments));
          char err[1024];
          spdf_document* doc = [self openSpdfDocumentAtPath:workingPath
                                                 sourcePath:standardizedPath
                                                     status:NULL
                                                      error:err
                                                errorLength:sizeof(err)];
          BOOL ok = doc && spdf_load_comments(doc, &comments, err, sizeof(err));
          if (doc) spdf_close(doc);

          [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            SPDFDocumentTab* currentTab = [self selectedTab];
            if (generation != self->_renderGeneration || !self->_doc ||
                ![self->_path.stringByStandardizingPath isEqualToString:standardizedPath] || currentTab != tab) {
                spdf_free_comments(&comments);
                return;
            }
            if (ok) {
                [tab replaceCachedComments:comments loaded:YES];
            } else {
                spdf_free_comments(&comments);
                spdf_comments emptyComments;
                memset(&emptyComments, 0, sizeof(emptyComments));
                [tab replaceCachedComments:emptyComments loaded:YES];
            }
            [self adoptCachedMetadataForTab:tab];
            [self rebuildSidebar];
            [self->_pageView setNeedsDisplay:YES];
          }];
      }
    }];
}

- (void)loadOutlineForCurrentDocumentAsync {
    if (!_doc || !_path.length) return;
    SPDFDocumentTab* tab = [self selectedTab];
    if (tab.cachedOutlineLoaded) {
        [self adoptCachedMetadataForTab:tab];
        [self rebuildSidebar];
        return;
    }

    NSString* workingPath = [self activeWorkingPath]; // temp copy for read-only source
    NSString* standardizedPath = [_path.stringByStandardizingPath copy];
    NSUInteger generation = _renderGeneration;
    [_preloadQueue addOperationWithBlock:^{
      @autoreleasepool {
          __block spdf_outline outline;
          memset(&outline, 0, sizeof(outline));
          char err[1024];
          spdf_document* doc = [self openSpdfDocumentAtPath:workingPath
                                                 sourcePath:standardizedPath
                                                     status:NULL
                                                      error:err
                                                errorLength:sizeof(err)];
          BOOL ok = doc && spdf_load_outline(doc, &outline, err, sizeof(err));
          if (doc) spdf_close(doc);

          [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            SPDFDocumentTab* currentTab = [self selectedTab];
            if (generation != self->_renderGeneration || !self->_doc ||
                ![self->_path.stringByStandardizingPath isEqualToString:standardizedPath] || currentTab != tab) {
                spdf_free_outline(&outline);
                return;
            }
            if (ok) {
                [tab replaceCachedOutline:outline loaded:YES];
            } else {
                spdf_free_outline(&outline);
                spdf_outline emptyOutline;
                memset(&emptyOutline, 0, sizeof(emptyOutline));
                [tab replaceCachedOutline:emptyOutline loaded:YES];
            }
            [self adoptCachedMetadataForTab:tab];
            [self rebuildSidebar];
          }];
      }
    }];
}

- (void)schedulePostFirstPaintWorkForGeneration:(NSUInteger)generation
                                           path:(NSString*)path
                            savedFindMatchIndex:(NSInteger)savedFindMatchIndex
                                  restoreSearch:(BOOL)restoreSearch
                            preferredRenderPage:(NSInteger)preferredRenderPage {
    [self spdf_scheduleIdlePostFirstPaintWorkForGeneration:generation
                                                      path:path
                                       savedFindMatchIndex:savedFindMatchIndex
                                             restoreSearch:restoreSearch
                                       preferredRenderPage:preferredRenderPage];
}

- (NSArray<NSDictionary*>*)commentAnnotationsForPage:(NSInteger)pageIndex {
    if (_comments.count <= 0) return @[];
    NSMutableArray<NSDictionary*>* comments = [NSMutableArray array];
    for (int i = 0; i < _comments.count; ++i) {
        spdf_comment_item item = _comments.items[i];
        if (item.page_index != pageIndex) continue;
        CGFloat width = item.bounds.x1 - item.bounds.x0;
        CGFloat height = item.bounds.y1 - item.bounds.y0;
        if (width <= 0 || height <= 0) continue;
        NSString* author = item.author && *item.author ? [NSString stringWithUTF8String:item.author] : @"";
        NSString* type = item.type && *item.type ? [NSString stringWithUTF8String:item.type] : @"Comment";
        NSString* text = item.text && *item.text ? [NSString stringWithUTF8String:item.text] : type;
        NSString* title = author.length ? [NSString stringWithFormat:@"%@ - %@", author, type] : type;
        [comments addObject:@{
            @"title" : title,
            @"author" : author,
            @"text" : text,
            @"commentIndex" : @(item.index),
            @"bounds" : [NSValue valueWithRect:NSMakeRect(item.bounds.x0, item.bounds.y0, width, height)]
        }];
    }
    return comments;
}

- (void)documentViewHoverComment:(NSDictionary*)comment atWindowPoint:(NSPoint)windowPoint {
    NSString* title = comment[@"title"] ?: @"Comment";
    NSString* text = comment[@"text"] ?: @"";
    NSString* message = text.length ? [NSString stringWithFormat:@"%@\n%@", title, text] : title;
    if (!_commentPanel) {
        _commentPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 320, 88)
                                                   styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
        _commentPanel.releasedWhenClosed = NO;
        _commentPanel.hidesOnDeactivate = YES;
        _commentPanel.hasShadow = YES;
        _commentPanel.opaque = NO;
        _commentPanel.backgroundColor = NSColor.clearColor;

        NSVisualEffectView* bubble = [[NSVisualEffectView alloc] initWithFrame:_commentPanel.contentView.bounds];
        bubble.translatesAutoresizingMaskIntoConstraints = NO;
        bubble.material = NSVisualEffectMaterialPopover;
        bubble.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        bubble.state = NSVisualEffectStateActive;
        bubble.wantsLayer = YES;
        bubble.layer.cornerRadius = 9.0;
        bubble.layer.masksToBounds = YES;
        _commentPanel.contentView = bubble;

        _commentLabel = [NSTextField wrappingLabelWithString:@""];
        _commentLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _commentLabel.font = [NSFont systemFontOfSize:12];
        _commentLabel.textColor = SPDFCollectionColor(@"text");
        [bubble addSubview:_commentLabel];
        [NSLayoutConstraint activateConstraints:@[
            [_commentLabel.leadingAnchor constraintEqualToAnchor:bubble.leadingAnchor constant:10],
            [_commentLabel.trailingAnchor constraintEqualToAnchor:bubble.trailingAnchor constant:-10],
            [_commentLabel.topAnchor constraintEqualToAnchor:bubble.topAnchor constant:8],
            [_commentLabel.bottomAnchor constraintEqualToAnchor:bubble.bottomAnchor constant:-8]
        ]];
    }

    _commentLabel.stringValue = message;
    CGFloat width = 340.0;
    NSRect textRect = [message boundingRectWithSize:NSMakeSize(width - 20.0, 220.0)
                                            options:NSStringDrawingUsesLineFragmentOrigin
                                         attributes:@{NSFontAttributeName : _commentLabel.font}];
    CGFloat height = MIN(230.0, MAX(38.0, ceil(NSHeight(textRect)) + 20.0));
    NSRect cursorScreen = [_window convertRectToScreen:NSMakeRect(windowPoint.x, windowPoint.y, 1, 1)];
    NSRect frame =
        NSMakeRect(floor(NSMinX(cursorScreen) + 14.0), floor(NSMinY(cursorScreen) - height - 12.0), width, height);
    [_commentPanel setFrame:frame display:NO];
    if (_commentPanel.parentWindow != _window) [_window addChildWindow:_commentPanel ordered:NSWindowAbove];
    // Same hover rule as the tab-strip bubble: never orderFront: a child window
    // from a hover path (it re-stacks the parent group). Order relative to the
    // parent so the bubble shows without changing window order.
    [_commentPanel orderWindow:NSWindowAbove relativeTo:_window.windowNumber];
}

- (void)documentViewEndHoverComment {
    [_commentPanel orderOut:nil];
}

- (NSPoint)visibleCenterWindowPoint {
    NSRect visible = _pageScrollView.contentView.bounds;
    NSPoint centerInPageView = NSMakePoint(NSMidX(visible), NSMidY(visible));
    return [_pageView convertPoint:centerInPageView toView:nil];
}

- (NSPoint)pagePointForViewPoint:(NSPoint)viewPoint pageRect:(NSRect)pageRect page:(SPDFRenderedPage*)page {
    CGFloat scaleX = NSWidth(pageRect) / MAX(1.0, page.pageWidth);
    CGFloat scaleY = NSHeight(pageRect) / MAX(1.0, page.pageHeight);
    return NSMakePoint((viewPoint.x - NSMinX(pageRect)) / MAX(0.001, scaleX),
                       (viewPoint.y - NSMinY(pageRect)) / MAX(0.001, scaleY));
}

- (NSPoint)viewPointForPagePoint:(NSPoint)pagePoint pageRect:(NSRect)pageRect page:(SPDFRenderedPage*)page {
    CGFloat scaleX = NSWidth(pageRect) / MAX(1.0, page.pageWidth);
    CGFloat scaleY = NSHeight(pageRect) / MAX(1.0, page.pageHeight);
    return NSMakePoint(NSMinX(pageRect) + pagePoint.x * scaleX, NSMinY(pageRect) + pagePoint.y * scaleY);
}

- (SPDFPageAnchor)pageAnchorForWindowPoint:(NSPoint)windowPoint {
    SPDFPageAnchor anchor;
    memset(&anchor, 0, sizeof(anchor));
    anchor.pageIndex = -1;
    if (!_doc || _renderedPages.count == 0) return anchor;

    NSClipView* clipView = _pageScrollView.contentView;
    NSPoint viewPoint = [_pageView convertPoint:windowPoint fromView:nil];
    NSInteger pageIndex = -1;
    NSPoint pagePoint = NSZeroPoint;
    if ([_pageView point:viewPoint fallsInPage:&pageIndex pagePoint:&pagePoint]) {
        anchor.pageIndex = pageIndex;
        anchor.pagePoint = pagePoint;
        anchor.offsetInViewport =
            NSMakePoint(viewPoint.x - NSMinX(clipView.bounds), viewPoint.y - NSMinY(clipView.bounds));
        anchor.valid = YES;
        return anchor;
    }

    // Cursor outside any page (margins/gutter): anchor at the cursor clamped
    // to the nearest page so zoom still converges toward the pointer. Scroll
    // clamping keeps a smaller-than-viewport document centered regardless.
    NSRect visible = clipView.bounds;
    pageIndex = _presentationMode ? _pageIndex : [_pageView pageIndexForVisibleRect:visible];
    pageIndex = MAX(0, MIN(pageIndex, (NSInteger)_renderedPages.count - 1));
    NSRect pageRect = [_pageView rectForPageAtIndex:pageIndex];
    if (NSIsEmptyRect(pageRect)) return anchor;
    SPDFRenderedPage* page = _renderedPages[(NSUInteger)pageIndex];
    NSPoint clamped = NSMakePoint(spdf_clamp_cg(viewPoint.x, NSMinX(pageRect), NSMaxX(pageRect)),
                                  spdf_clamp_cg(viewPoint.y, NSMinY(pageRect), NSMaxY(pageRect)));
    anchor.pageIndex = pageIndex;
    anchor.pagePoint = [self pagePointForViewPoint:clamped pageRect:pageRect page:page];
    anchor.offsetInViewport = NSMakePoint(clamped.x - NSMinX(visible), clamped.y - NSMinY(visible));
    anchor.valid = YES;
    return anchor;
}

- (SPDFPageAnchor)liveZoomAnchorForWindowPoint:(NSPoint)windowPoint {
    if (!_liveZoomAnchorValid) return [self pageAnchorForWindowPoint:windowPoint];
    SPDFPageAnchor anchor;
    memset(&anchor, 0, sizeof(anchor));
    anchor.pageIndex = _liveZoomAnchorPageIndex;
    anchor.pagePoint = _liveZoomAnchorPagePoint;
    anchor.offsetInViewport = _liveZoomAnchorOffsetInViewport;
    anchor.valid = YES;
    return anchor;
}

- (void)scrollToPageAnchor:(SPDFPageAnchor)anchor notify:(BOOL)notify {
    if (!anchor.valid || anchor.pageIndex < 0 || anchor.pageIndex >= (NSInteger)_renderedPages.count) return;
    NSRect pageRect = [_pageView rectForPageAtIndex:anchor.pageIndex];
    if (NSIsEmptyRect(pageRect)) return;
    SPDFRenderedPage* page = _renderedPages[(NSUInteger)anchor.pageIndex];
    NSPoint viewPoint = [self viewPointForPagePoint:anchor.pagePoint pageRect:pageRect page:page];
    NSPoint origin = NSMakePoint(viewPoint.x - anchor.offsetInViewport.x, viewPoint.y - anchor.offsetInViewport.y);
    [self scrollDocumentClipViewToOrigin:[self clampedDocumentScrollOrigin:origin forPageIndex:anchor.pageIndex]
                                  notify:notify];
}

- (BOOL)zoomWithScrollWheelEvent:(NSEvent*)event centeredAtWindowPoint:(NSPoint)windowPoint {
    if ([self isMarkdownActive]) return [self markdownZoomWithScrollWheelEvent:event centeredAtWindowPoint:windowPoint];
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if (!(flags & (NSEventModifierFlagCommand | NSEventModifierFlagControl))) return NO;

    CGFloat delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY;
    CGFloat factor = pow(1.00135, delta);
    [self beginLiveZoomByFactor:factor centeredAtWindowPoint:windowPoint];
    return YES;
}

- (void)zoomWithMagnifyEvent:(NSEvent*)event centeredAtWindowPoint:(NSPoint)windowPoint {
    [self zoomWithMagnifyDelta:event.magnification centeredAtWindowPoint:windowPoint];
}

- (void)zoomWithMagnifyDelta:(CGFloat)delta centeredAtWindowPoint:(NSPoint)windowPoint {
    if ([self isMarkdownActive]) {
        [self markdownZoomWithMagnifyDelta:delta centeredAtWindowPoint:windowPoint];
        return;
    }
    [self beginLiveZoomByFactor:1.0 + delta * 0.82 centeredAtWindowPoint:windowPoint];
}

- (void)zoomByFactor:(CGFloat)factor centeredAtWindowPoint:(NSPoint)windowPoint {
    if (!_doc || factor <= 0) return;
    [self beginLiveZoomByFactor:factor centeredAtWindowPoint:windowPoint];
}

- (void)setZoomWithoutRendering:(CGFloat)newZoom centeredAtWindowPoint:(NSPoint)windowPoint {
    if (!_doc) return;
    CGFloat oldZoom = _zoom > 0 ? _zoom : 1.0;
    CGFloat clampedZoom = MAX(kMinZoom, MIN(kMaxZoom, newZoom));
    if (fabs(clampedZoom - oldZoom) < 0.0001) return;

    SPDFPageAnchor anchor =
        _liveZooming ? [self liveZoomAnchorForWindowPoint:windowPoint] : [self pageAnchorForWindowPoint:windowPoint];
    _zoom = clampedZoom;
    _rememberedCustomZoom = _zoom;
    _pageView.backingScale = [self backingScale];
    _pageView.zoom = _zoom;
    _pageView.liveZooming = _liveZooming;
    double t0 = spdf_zoom_profile_enabled() ? spdf_zoom_profile_now_ms() : 0.0;
    if (_liveZooming)
        [self resizeDocumentViewForLiveZoom];
    else
        [self resizeDocumentView];
    double t1 = spdf_zoom_profile_enabled() ? spdf_zoom_profile_now_ms() : 0.0;
    BOOL previousSuppressScrollCallbacks = _suppressScrollCallbacks;
    if (_liveZooming) _suppressScrollCallbacks = YES;
    [self scrollToPageAnchor:anchor notify:NO];
    _suppressScrollCallbacks = previousSuppressScrollCallbacks;
    double t2 = spdf_zoom_profile_enabled() ? spdf_zoom_profile_now_ms() : 0.0;

    if (!_liveZooming) {
        [self syncToolbarState];
        [self updateControls];
    }
    [self setCurrentViewportNeedsDisplay];
    if (_liveZooming)
        [self scheduleLiveZoomMinimapUpdate];
    else
        [self updateMinimap];
    if (spdf_zoom_profile_enabled()) {
        double t3 = spdf_zoom_profile_now_ms();
        if (t3 - t0 > 1.0)
            spdf_zoom_profile_log(@"setZoomWithoutRendering resize=%.2f scroll=%.2f tail=%.2f", t1 - t0, t2 - t1,
                                  t3 - t2);
    }
}

- (void)renderDocumentPreservingScrollPosition {
    if (!_doc) return;
    NSClipView* clipView = _pageScrollView.contentView;
    NSPoint origin = clipView.bounds.origin;
    [self renderDocumentAndScrollToPage:_pageIndex alignTop:NO restoreOrigin:[NSValue valueWithPoint:origin]];
}

- (void)finishLiveZoom:(NSTimer*)timer {
    NSUInteger sequence = [timer.userInfo unsignedIntegerValue];
    _zoomFinishTimer = nil;
    if (sequence != _liveZoomSequence) return;
    if (_documentViewPanActive) {
        _zoomFinishTimer = [NSTimer scheduledTimerWithTimeInterval:kLiveZoomFinishWhilePanningDelay
                                                            target:self
                                                          selector:@selector(finishLiveZoom:)
                                                          userInfo:@(sequence)
                                                           repeats:NO];
        return;
    }
    SPDFPageAnchor finishAnchor;
    memset(&finishAnchor, 0, sizeof(finishAnchor));
    if (_liveZoomAnchorValid) {
        finishAnchor.pageIndex = _liveZoomAnchorPageIndex;
        finishAnchor.pagePoint = _liveZoomAnchorPagePoint;
        finishAnchor.offsetInViewport = _liveZoomAnchorOffsetInViewport;
        finishAnchor.valid = YES;
    }
    BOOL presentationZoom = _presentationMode;
    NSInteger preservedPageIndex = _pageIndex;
    double profileStart = spdf_zoom_profile_enabled() ? spdf_zoom_profile_now_ms() : 0.0;
    _liveZooming = NO;
    _liveZoomAnchorValid = NO;
    [self resumeBackgroundRenderQueuesAfterLiveZoomCancelingQueuedWork:YES];
    if (_doc) {
        _documentViewPanCropGeneration++;
        _documentViewPanCropInFlight = NO;
        NSUInteger postZoomRenderGeneration = _renderGeneration;
        NSString* path = [_path copy];
        BOOL previousSuppressScrollCallbacks = _suppressScrollCallbacks;
        _suppressScrollCallbacks = YES;
        [self resizeDocumentView];
        if (presentationZoom && preservedPageIndex >= 0 && preservedPageIndex < (NSInteger)_renderedPages.count) {
            _pageIndex = preservedPageIndex;
            _pageView.currentPageIndex = _pageIndex;
        }
        if (finishAnchor.valid) [self scrollToPageAnchor:finishAnchor notify:NO];
        _suppressScrollCallbacks = previousSuppressScrollCallbacks;
        [self syncToolbarState];
        [self updateControls];
        if (!presentationZoom) [self syncCurrentPageFromVisibleViewportQueueRenders:NO forceHighPriority:YES];
        if (_documentViewPanActive)
            [self setCurrentViewportNeedsDisplay];
        else
            [self schedulePostLiveZoomViewportRenderForSequence:sequence
                                                           path:path
                                               renderGeneration:postZoomRenderGeneration];
        [self updateMinimap];
        [self rememberActiveTabState];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPostLiveZoomBackgroundRenderDelay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                         if (sequence != self->_liveZoomSequence ||
                             postZoomRenderGeneration != self->_renderGeneration || self->_liveZooming || !self->_doc ||
                             ![self->_path isEqualToString:path])
                             return;
                         [self enqueueZoomSeedCachesForGeneration:self->_renderGeneration
                                                    preferredPage:self->_pageIndex
                                                 includeWholeBase:NO];
                         NSArray<NSNumber*>* pages = [self currentPageNeighborhoodIndexes];
                         [self enqueuePageRendersForGeneration:self->_renderGeneration
                                                   pageIndexes:pages
                                                 preferredPage:self->_pageIndex
                                             forceHighPriority:NO];
                       });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLiveZoomStateSaveDelay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                         if (sequence != self->_liveZoomSequence || self->_liveZooming || !self->_doc ||
                             ![self->_path isEqualToString:path])
                             return;
                         [self savePersistentState];
                       });
    } else {
        _pageView.liveZooming = NO;
        [self clearLiveZoomSeeds];
    }
    if (spdf_zoom_profile_enabled())
        spdf_zoom_profile_log(@"finishLiveZoom zoom=%.3f total=%.2fms", _zoom,
                              spdf_zoom_profile_now_ms() - profileStart);
}

- (void)beginLiveZoomByFactor:(CGFloat)factor centeredAtWindowPoint:(NSPoint)windowPoint {
    if (!_doc || factor <= 0) return;
    CGFloat targetZoom = MAX(kMinZoom, MIN(kMaxZoom, _zoom * factor));
    if (fabs(targetZoom - _zoom) < 0.0001) return;
    double profileStart = spdf_zoom_profile_enabled() ? spdf_zoom_profile_now_ms() : 0.0;
    double profilePause = 0.0, profileAnchor = 0.0, profileSeeds = 0.0, profileSetZoom = 0.0;
    _fitMode = SPDFFitModeCustom;
    _documentViewPanCropGeneration++;
    _documentViewPanCropInFlight = NO;
    BOOL wasLiveZooming = _liveZooming;
    if (!wasLiveZooming) {
        _liveZoomSequence++;
        _liveZooming = YES;
        _pageView.liveZooming = YES;
        double t0 = spdf_zoom_profile_enabled() ? spdf_zoom_profile_now_ms() : 0.0;
        [self pauseBackgroundRenderQueuesForLiveZoom];
        double t1 = spdf_zoom_profile_enabled() ? spdf_zoom_profile_now_ms() : 0.0;
        SPDFPageAnchor anchor = [self pageAnchorForWindowPoint:windowPoint];
        double t2 = spdf_zoom_profile_enabled() ? spdf_zoom_profile_now_ms() : 0.0;
        _liveZoomAnchorPageIndex = anchor.pageIndex;
        _liveZoomAnchorPagePoint = anchor.pagePoint;
        _liveZoomAnchorOffsetInViewport = anchor.offsetInViewport;
        _liveZoomAnchorValid = anchor.valid;
        NSArray<NSNumber*>* seedPages = [self liveZoomSeedPageIndexesForAnchorPage:anchor.pageIndex];
        [self prepareLiveZoomSeedsForPageIndexes:seedPages];
        double t3 = spdf_zoom_profile_enabled() ? spdf_zoom_profile_now_ms() : 0.0;
        profilePause = t1 - t0;
        profileAnchor = t2 - t1;
        profileSeeds = t3 - t2;
    } else {
        _liveZoomSequence++;
        _liveZooming = YES;
        _pageView.liveZooming = YES;
    }
    [_zoomFinishTimer invalidate];
    double tz = spdf_zoom_profile_enabled() ? spdf_zoom_profile_now_ms() : 0.0;
    // Release the horizontal lock for the duration of the zoom: a lock value
    // computed for the old (smaller) canvas would pin origin.x and drag the
    // cursor-anchored zoom toward the left as the canvas grows. resizeDocumentView
    // re-establishes the correct lock when the gesture settles.
    [self setHorizontalScrollLockX:NAN animated:NO];
    [self setZoomWithoutRendering:targetZoom centeredAtWindowPoint:windowPoint];
    if (spdf_zoom_profile_enabled()) {
        profileSetZoom = spdf_zoom_profile_now_ms() - tz;
        double total = spdf_zoom_profile_now_ms() - profileStart;
        if (total > 1.0 || !wasLiveZooming)
            spdf_zoom_profile_log(
                @"beginLiveZoom new=%d zoom=%.3f->%.3f total=%.2fms pause=%.2f anchor=%.2f seeds=%.2f setZoom=%.2f",
                !wasLiveZooming, _zoom / MAX(0.0001, factor), _zoom, total, profilePause, profileAnchor, profileSeeds,
                profileSetZoom);
    }
    _zoomFinishTimer = [NSTimer scheduledTimerWithTimeInterval:kLiveZoomFinishDelay
                                                        target:self
                                                      selector:@selector(finishLiveZoom:)
                                                      userInfo:@(_liveZoomSequence)
                                                       repeats:NO];
}

- (void)cancelPendingLiveZoomCompletion {
    if (!_liveZooming && !_zoomFinishTimer) return;
    [_zoomFinishTimer invalidate];
    _zoomFinishTimer = nil;
    _liveZoomSequence++;
    _liveZooming = NO;
    _liveZoomAnchorValid = NO;
    _pageView.liveZooming = NO;
    [self clearLiveZoomSeeds];
    [self resumeBackgroundRenderQueuesAfterLiveZoomCancelingQueuedWork:YES];
    _liveZoomMinimapUpdateScheduled = NO;
    _documentViewPanCropGeneration++;
    _documentViewPanCropInFlight = NO;
    _documentViewPanMaintenanceScheduled = NO;
}

- (BOOL)pathIsInTemporaryLocation:(NSString*)path {
    if (!path.length) return NO;
    NSString* standardized = path.stringByStandardizingPath.stringByResolvingSymlinksInPath;
    NSMutableArray<NSString*>* roots = [NSMutableArray arrayWithArray:@[
        NSTemporaryDirectory() ?: @"", @"/tmp", @"/private/tmp", @"/var/tmp", @"/private/var/tmp", @"/var/folders",
        @"/private/var/folders"
    ]];
    for (NSString* root in roots) {
        if (root.length == 0) continue;
        NSString* standardizedRoot = root.stringByStandardizingPath.stringByResolvingSymlinksInPath;
        if (standardizedRoot.length == 0) continue;
        if (![standardizedRoot hasSuffix:@"/"]) standardizedRoot = [standardizedRoot stringByAppendingString:@"/"];
        if ([standardized hasPrefix:standardizedRoot]) return YES;
    }
    return NO;
}

- (BOOL)activePDFNeedsSaveAsBeforeModificationWithReason:(NSString**)reasonOut {
    if (!_doc || !_path.length || ![_path.pathExtension.lowercaseString isEqualToString:@"pdf"]) return NO;
    NSFileManager* fm = NSFileManager.defaultManager;
    NSString* directory = _path.stringByDeletingLastPathComponent;
    if ([self pathIsInTemporaryLocation:_path]) {
        if (reasonOut) *reasonOut = @"This PDF is in a temporary folder.";
        return YES;
    }
    if (![fm isWritableFileAtPath:_path]) {
        if (reasonOut) *reasonOut = @"This PDF is read-only.";
        return YES;
    }
    if (directory.length && ![fm isWritableFileAtPath:directory]) {
        if (reasonOut) *reasonOut = @"This PDF's folder is read-only.";
        return YES;
    }
    return NO;
}

- (BOOL)saveActiveDocumentToPath:(NSString*)destinationPath statusMessage:(NSString*)statusMessage {
    if (!_doc || !destinationPath.length || ![destinationPath.pathExtension.lowercaseString isEqualToString:@"pdf"]) {
        NSBeep();
        return NO;
    }

    if ([NSFileManager.defaultManager fileExistsAtPath:destinationPath] &&
        ![self collectionProtectPath:destinationPath operation:@"saving"]) return NO;
    char err[1024];
    if (!spdf_save_document(_doc, destinationPath.fileSystemRepresentation, err, sizeof(err))) {
        [self showError:@"Could not save document"
                 detail:[NSString stringWithUTF8String:err[0] ? err : "Unknown error"]];
        return NO;
    }

    _path = [destinationPath copy];
    // Read-only shadow copy: Save-As writes a real, writable file. The temp-copy
    // proxy drops away — the saved doc is a normal writable tab from here on.
    _workingPath = _path;
    SPDFDocumentTab* tab = [self selectedTab];
    if (tab) {
        tab.path = _path;
        tab.title = spdf_display_name_for_path(_path);
        tab.missingFile = NO;
        tab.missingMessage = @"";
        // Delete the old read-only proxy only if no sibling tab still views the
        // same shared copy (otherwise it would strand them into a re-copy/prompt).
        [self deleteReadOnlyCopyIfUnsharedForTab:tab];
        tab.workingPath = nil;
        tab.copiedSourceFileSize = 0;
        tab.copiedSourceModificationDate = nil;
        tab.readOnlyCopyBinding = nil;
        tab.readOnly = [self sourcePathIsReadOnly:_path];
        tab.cachedDocument = _doc;
        tab.cachedRenderedPages = _renderedPages;
        NSDictionary* attributes = [self fileAttributesForPath:_path];
        if (attributes) [self recordFileAttributes:attributes forTab:tab];
        [self saveDocumentStateForTab:tab];
    }
    [self rememberRecentlyOpenedPath:_path];
    [self collectionDidSavePath:_path];
    [self updateTabStrip];
    [self updateControls];
    [self savePersistentState];
    _statusLabel.stringValue = statusMessage.length ? statusMessage : @"Document saved.";
    return YES;
}

- (BOOL)saveActiveDocumentAsWithPanelTitle:(NSString*)panelTitle statusMessage:(NSString*)statusMessage {
    if (!_doc || !_path.length || ![_path.pathExtension.lowercaseString isEqualToString:@"pdf"]) {
        NSBeep();
        return NO;
    }

    NSSavePanel* panel = [NSSavePanel savePanel];
    panel.title = panelTitle.length ? panelTitle : @"Save PDF As";
    panel.canCreateDirectories = YES;
    panel.nameFieldStringValue = _path.lastPathComponent.length ? _path.lastPathComponent : @"Untitled.pdf";
    if (@available(macOS 11.0, *))
        panel.allowedContentTypes = @[ UTTypePDF ];
    else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        panel.allowedFileTypes = @[ @"pdf" ];
#pragma clang diagnostic pop
    }
    NSURL* directoryURL = _path.stringByDeletingLastPathComponent.length
                              ? [NSURL fileURLWithPath:_path.stringByDeletingLastPathComponent]
                              : nil;
    if (directoryURL) panel.directoryURL = directoryURL;
    if ([panel runModal] != NSModalResponseOK) return NO;
    return [self saveActiveDocumentToPath:panel.URL.path statusMessage:statusMessage ?: @"Document saved."];
}

- (BOOL)ensureActivePDFCanBeModifiedForOperation:(NSString*)operationName {
    // A Collection backup is never written: the edit goes to a writable copy, as for a read-only file.
    if (SPDFMacPathIsCollectionArchive(_path)) return [self moveActivePDFToWritableCopyForOperation:operationName];
    if (spdf_is_password_protected(_doc)) {
        BOOL annotationOperation =
            [operationName rangeOfString:@"comment" options:NSCaseInsensitiveSearch].location != NSNotFound;
        int requiredPermission = annotationOperation ? 'n' : 'e';
        if (!spdf_has_permission(_doc, requiredPermission)) {
            [self showError:@"Operation is not allowed"
                     detail:[NSString stringWithFormat:@"This PDF's user permissions do not allow %@. Open it with the "
                                                       @"owner password to continue.",
                                                       operationName ?: @"this modification"]];
            return NO;
        }
    }
    if (![self activePDFNeedsSaveAsBeforeModificationWithReason:NULL])
        return [self collectionProtectPath:_path operation:operationName];
    return [self moveActivePDFToWritableCopyForOperation:operationName]; // never asks (SPDFMacWritableCopy.mm)
}

- (void)activateCachedSelectedTab:(SPDFDocumentTab*)tab
                             path:(NSString*)path
                       attributes:(NSDictionary*)attributes
              savedFindMatchIndex:(NSInteger)savedFindMatchIndex {
    _doc = tab.cachedDocument;
    if (!_doc || ![self ensureCachedRenderedPagesForTab:tab preferredPage:tab.pageIndex]) return;

    tab.missingFile = NO;
    tab.missingMessage = @"";
    [self collectionDidOpenPath:path]; [self aiDocumentDidOpen:path];
    [self recordFileAttributes:attributes forTab:tab];
    NSInteger pageCount = spdf_page_count(_doc);
    [self applySinglePageMinimapDefaultToTab:tab pageCount:pageCount];
    [self prepareSelectedTabViewState:tab path:path];
    [self loadInitialSidebarMetadataForSelectedTabIfNeeded];
    _pageIndex = MAX(0, MIN(tab.pageIndex, pageCount - 1));
    _fitPageIndex = spdf_tab_fit_page_index(tab, _pageIndex, pageCount);
    _fitMode = tab.fitMode;
    _rememberedCustomZoom = tab.customZoom > 0 ? tab.customZoom : (tab.zoom > 0 ? tab.zoom : 1.0);
    _zoom = [self zoomForFitMode:_fitMode pageIndex:_fitPageIndex];
    _renderGeneration++;
    // Bumping the generation invalidates any minimap thumbnail renders that were
    // enqueued for the outgoing tab (or earlier in this switch) — their
    // completion blocks bail on the generation check. Cancel and clear them now,
    // exactly like renderDocumentAndScrollToPage: does, so the post-switch
    // minimap enqueue below creates a fresh band at THIS generation. Otherwise
    // those stale pages stay marked "already queued", the immediate enqueue is a
    // no-op, and the strip only fills in on a later deferred pass (~300ms+),
    // which reads as the minimap loading slowly on tab switch.
    [_minimapQueue cancelAllOperations];
    [_queuedMinimapThumbnailPages removeAllObjects];

    _renderedPages = tab.cachedRenderedPages;
    _pageScrollView.hidden = NO;
    _pageView.emptyMessage = @"Open a document";
    _pageView.pages = _renderedPages;
    _pageView.currentPageIndex = _pageIndex;
    _pageView.zoom = _zoom;
    _pageView.presentationMode = _presentationMode;
    _pageView.backingScale = [self backingScale];
    if (_presentationMode)
        _pageScrollView.verticalScroller = nil;
    else if (_pageScrollView.verticalScroller != _markerScroller)
        _pageScrollView.verticalScroller = _markerScroller;
    _pageScrollView.hasVerticalScroller = !_presentationMode;
    _minimapInitialPopulationPending = YES;
    BOOL previousSuppressViewportRerender = _suppressViewportRerender;
    _suppressViewportRerender = YES;
    [self setMinimapActuallyVisible:_minimapPreferredVisible];
    tab.title = spdf_display_name_for_path(_path);

    [self rebuildSidebar];
    _suppressViewportRerender = previousSuppressViewportRerender;
    [self updateTabStrip];

    NSClipView* clipView = _pageScrollView.contentView;
    BOOL previousPostsBoundsChangedNotifications = clipView.postsBoundsChangedNotifications;
    BOOL previousSuppressScrollCallbacks = _suppressScrollCallbacks;
    _suppressScrollCallbacks = YES;
    clipView.postsBoundsChangedNotifications = NO;
    NSValue* restoreOrigin = tab.hasScrollOrigin ? [NSValue valueWithPoint:tab.scrollOrigin] : nil;
    NSUInteger layoutGeneration = _renderGeneration;
    NSString* layoutPath = [_path copy];

    [NSAnimationContext
        runAnimationGroup:^(NSAnimationContext* context) {
          context.duration = 0.0;
          context.allowsImplicitAnimation = NO;
          [self->_window.contentView layoutSubtreeIfNeeded];
          [self->_documentContainer layoutSubtreeIfNeeded];
          [self resizeDocumentView];
          // The fit-mode zoom computed at adoption (above) used the OUTGOING
          // tab's clip width — the sidebar/minimap chrome for THIS tab is only
          // applied just before this animation group, and the page tiling
          // happens in resizeDocumentView right above. Reconcile the auto-fit
          // zoom against the now-final clip size, exactly like
          // resizeDocumentViewForWindowLiveResize does; otherwise the popup
          // reads "Fit Page" while the rendered zoom is stale. Custom/Actual
          // don't depend on clip width, so they're left untouched.
          if ([self isAutoFitMode:self->_fitMode]) {
              CGFloat fit = [self zoomForFitMode:self->_fitMode pageIndex:self->_fitPageIndex];
              if (isfinite(fit) && fit > 0.0 && fabs(fit - self->_zoom) > 0.0001) {
                  self->_zoom = fit;
                  self->_pageView.zoom = self->_zoom;
                  [self resizeDocumentView];
              }
          }
          if (restoreOrigin)
              [self scrollDocumentClipViewToOrigin:[self normalizedDocumentScrollOrigin:restoreOrigin.pointValue
                                                                           forPageIndex:self->_pageIndex]
                                            notify:NO];
          else
              [self scrollToPage:self->_pageIndex alignTop:YES];
          [self->_pageView setNeedsDisplay:YES];
        }
        completionHandler:nil];

    clipView.postsBoundsChangedNotifications = previousPostsBoundsChangedNotifications;
    _suppressScrollCallbacks = previousSuppressScrollCallbacks;
    [self documentScrollPositionChanged];
    [self syncToolbarState];
    [self updateControls];
    [self selectCurrentSidebarRow];
    [self updateMinimap];
    [self enqueuePageRendersForGeneration:layoutGeneration
                              pageIndexes:@[ @(_pageIndex) ]
                            preferredPage:_pageIndex
                        forceHighPriority:YES];
    [self schedulePostFirstPaintWorkForGeneration:layoutGeneration
                                             path:layoutPath
                              savedFindMatchIndex:savedFindMatchIndex
                                    restoreSearch:_searchField.stringValue.length > 0
                              preferredRenderPage:_pageIndex];
    [self clearToolbarFieldFocusForTabSwitch];
    [self repointActiveFileWatcher];
    [self savePersistentState];
}

// Cloud/network-backed paths can stall stat/open on the provider's cache
// revalidation (DriveFS after its TTL takes ~1s). File-provider mounts live
// under ~/Library/CloudStorage/; anything not on apfs/hfs (smbfs, nfs,
// macfuse, ...) gets the same treatment. Local disks must return NO so the
// launch path stays byte-identical for them.
- (BOOL)pathIsOnCloudStorage:(NSString*)path {
    if (!path.length) return NO;
    NSString* standardized = path.stringByStandardizingPath ?: path;
    if ([standardized rangeOfString:@"/CloudStorage/"].location != NSNotFound) return YES;
    struct statfs fs;
    if (statfs(standardized.fileSystemRepresentation, &fs) != 0) return NO;
    return strcasecmp(fs.f_fstypename, "apfs") != 0 && strcasecmp(fs.f_fstypename, "hfs") != 0;
}

- (void)dismissPendingPasswordPrompt {
    self.pendingPasswordPromptToken = nil;
    SPDFPasswordSheetController* controller = self.passwordSheetController;
    self.passwordSheetController = nil;
    [controller cancel];
}

- (void)promptForPasswordForTab:(SPDFDocumentTab*)tab
                       openPath:(NSString*)openPath
                     sourcePath:(NSString*)sourcePath
                     attributes:(NSDictionary*)attributes
            savedFindMatchIndex:(NSInteger)savedFindMatchIndex {
    if (!tab || !openPath.length || !sourcePath.length || !_window) return;
    [self dismissPendingPasswordPrompt];

    tab.missingFile = NO;
    tab.missingMessage = @"Password required";
    [self showUnavailableSelectedTab:tab path:sourcePath message:tab.missingMessage showOpenError:NO error:NULL];

    NSString* token = NSUUID.UUID.UUIDString;
    self.pendingPasswordPromptToken = token;
    NSString* standardizedSource = sourcePath.stringByStandardizingPath;
    NSString* sourceIdentityToken =
        [SPDFPasswordCredentialStore.sharedStore sourceIdentityTokenForSourcePath:sourcePath];
    __weak ShenzhenMacDelegate* weakSelf = self;
    SPDFPasswordSheetController* controller = [[SPDFPasswordSheetController alloc] initWithParentWindow:_window
        displayName:[self displayNameForPathConsideringOpenTabs:sourcePath]
        attemptHandler:^(SPDFPasswordCredential* credential, SPDFPasswordAttemptCompletion completion) {
          dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @autoreleasepool {
                char err[1024];
                spdf_open_status status = SPDF_OPEN_ERROR;
                spdf_document* document =
                    SPDFOpenDocumentWithCredential(openPath, credential, &status, NULL, err, sizeof(err));
                NSString* detail =
                    status == SPDF_OPEN_ERROR
                        ? ([NSString stringWithUTF8String:err[0] ? err : "The PDF could not be opened."] ?: @"")
                        : nil;
                dispatch_async(dispatch_get_main_queue(), ^{
                  ShenzhenMacDelegate* self = weakSelf;
                  if (!self || ![self.pendingPasswordPromptToken isEqualToString:token] || [self selectedTab] != tab ||
                      ![tab.path.stringByStandardizingPath isEqualToString:standardizedSource]) {
                      if (document) spdf_close(document);
                      return;
                  }
                  NSString* currentIdentityToken =
                      [SPDFPasswordCredentialStore.sharedStore sourceIdentityTokenForSourcePath:sourcePath];
                  if (![currentIdentityToken isEqualToString:sourceIdentityToken]) {
                      if (document) spdf_close(document);
                      completion(SPDFPasswordAttemptFailed, @"The PDF changed on disk. Try again.");
                      return;
                  }
                  if (!document) {
                      completion(
                          status == SPDF_OPEN_BAD_PASSWORD ? SPDFPasswordAttemptIncorrect : SPDFPasswordAttemptFailed,
                          detail);
                      return;
                  }
                  [SPDFPasswordCredentialStore.sharedStore setCredential:credential forSourcePath:sourcePath];
                  [self collectionRememberPasswordForPath:sourcePath];
                  objc_setAssociatedObject(tab, &kSPDFPasswordPromptClosesNewTabKey, @NO,
                                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                  completion(SPDFPasswordAttemptSucceeded, nil);
                  dispatch_async(dispatch_get_main_queue(), ^{
                    ShenzhenMacDelegate* strongSelf = weakSelf;
                    if (!strongSelf || ![strongSelf.pendingPasswordPromptToken isEqualToString:token] ||
                        [strongSelf selectedTab] != tab) {
                        spdf_close(document);
                        return;
                    }
                    strongSelf.pendingPasswordPromptToken = nil;
                    strongSelf.passwordSheetController = nil;
                    [strongSelf presentOpenedDocument:document
                                               forTab:tab
                                                 path:sourcePath
                                           attributes:attributes
                                  savedFindMatchIndex:savedFindMatchIndex];
                  });
                });
            }
          });
        }
        cancelHandler:^{
          ShenzhenMacDelegate* self = weakSelf;
          if (!self || ![self.pendingPasswordPromptToken isEqualToString:token]) return;
          self.pendingPasswordPromptToken = nil;
          self.passwordSheetController = nil;
          if ([self selectedTab] != tab) return;
          if ([objc_getAssociatedObject(tab, &kSPDFPasswordPromptClosesNewTabKey) boolValue]) {
              NSInteger tabIndex = [self->_tabs indexOfObjectIdenticalTo:tab];
              if (tabIndex != NSNotFound) [self closeTabAtIndex:tabIndex];
          }
        }];
    self.passwordSheetController = controller;
    [controller begin];
}

// Launch-only fast path for a cloud-backed restored active tab: put up the
// full chrome (tabs, toolbar, sidebar, empty document area) so the window
// paints immediately, then stat+open off the main thread and finish the
// normal loadSelectedTab restore when it lands. Caller already ran the
// cancellation/closeActiveDocumentIfUnowned preamble of loadSelectedTab.
- (void)deferCloudBackedOpenForSelectedTab:(SPDFDocumentTab*)tab
                                      path:(NSString*)path
                       savedFindMatchIndex:(NSInteger)savedFindMatchIndex {
    [self discardCachedRuntimeForTab:tab];
    _doc = NULL;
    [self clearActiveMetadata];
    [self prepareSelectedTabViewState:tab path:path];
    _pageIndex = 0;
    _renderGeneration++;
    [_renderedPages removeAllObjects];
    [self replaceDocumentViewForTabSwitch];
    [self rebuildSidebar];
    [self showEmptyDocumentViewWithMessage:@"Opening..."];
    _window.title = [NSString stringWithFormat:@"%@ - Shenzhen PDF", [self displayNameForPathConsideringOpenTabs:path]];
    _statusLabel.stringValue = @"Opening...";
    [self updateTabStrip];
    [self updateControls];
    [self clearToolbarFieldFocusForTabSwitch];

    // Read-only shadow copy: resolve read-only via a BARE lstat (silent) on the
    // main thread — this both sets tab.readOnly (so the tab-strip draw never races
    // the background write) and yields the source attributes for a read-only tab
    // WITHOUT a prompting -attributesOfItemAtPath:. For a read-only source the
    // captured attributes are reused off-main so the worker performs zero source
    // touch; the copy binding (workingPath/copiedSource*) is written off-main and
    // re-read into _workingPath when -finishDeferredCloudOpenWithToken: lands.
    BOOL readOnly = [self sourcePathIsReadOnly:path];
    NSDictionary* roSourceAttributes = readOnly ? [self readOnlySourceAttributesForPath:path] : nil;
    tab.readOnly = readOnly;

    NSString* token = NSUUID.UUID.UUIDString;
    _pendingDeferredCloudOpenToken = token;
    NSString* standardizedPath = [path.stringByStandardizingPath copy];
    spdf_launch_profile_log(@"cloud-deferred open scheduled %@", path.lastPathComponent);
    // Not on _preloadQueue: its operations get cancelAllOperations'd (palette
    // search, tab close), which would strand the placeholder forever.
    __weak __typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      @autoreleasepool {
          double openStart = spdf_launch_profile_enabled() ? spdf_zoom_profile_now_ms() : 0.0;
          // Read-only: reuse the main-thread bare-lstat attributes (zero source
          // touch). Writable: stat the source off-main as before.
          NSDictionary* attributes =
              readOnly ? roSourceAttributes : [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
          char err[1024];
          err[0] = '\0';
          // Read-only shadow copy: resolve+open the temp copy (refreshing it from
          // the source only when missing/changed) so a read-only cloud source is
          // not read on open. The resolve (content read + copy write) runs here
          // off-main, but the tab's nonatomic binding fields are NOT mutated here:
          // the resolution is applied on the MAIN thread in
          // finishDeferredCloudOpenWithToken: (which then re-reads it into
          // _workingPath via prepareSelectedTabViewState). Mirrors the main-thread
          // mutation discipline of every other ensureWorkingPathForTab: caller.
          SPDFReadOnlyCopyResolution resolution = {nil, 0, nil, NO, nil};
          NSString* openPath = path;
          if (attributes) {
              resolution = [self resolveWorkingPathForTab:tab sourcePath:path attributes:attributes];
              openPath = resolution.workingPath ?: path;
          }
          spdf_open_status openStatus = SPDF_OPEN_ERROR;
          spdf_document* newDoc = attributes ? [self openSpdfDocumentAtPath:openPath
                                                                 sourcePath:path
                                                                     status:&openStatus
                                                                      error:err
                                                                errorLength:sizeof(err)]
                                             : NULL;
          if (openStart > 0.0) {
              spdf_launch_profile_log(@"cloud-deferred stat+spdf_open %@ ok=%d %.1fms", path.lastPathComponent,
                                      newDoc != NULL, spdf_zoom_profile_now_ms() - openStart);
          }
          NSString* openError = [NSString stringWithUTF8String:err[0] ? err : "Unknown error"] ?: @"Unknown error";
          dispatch_async(dispatch_get_main_queue(), ^{
            __strong __typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) {
                if (newDoc) spdf_close(newDoc);
                return;
            }
            [strongSelf finishDeferredCloudOpenWithToken:token
                                        standardizedPath:standardizedPath
                                                document:newDoc
                                              attributes:attributes
                                              resolution:resolution
                                               openError:openError
                                              openStatus:openStatus
                                     savedFindMatchIndex:savedFindMatchIndex];
          });
      }
    });
}

- (void)finishDeferredCloudOpenWithToken:(NSString*)token
                        standardizedPath:(NSString*)standardizedPath
                                document:(spdf_document*)newDoc
                              attributes:(NSDictionary*)attributes
                              resolution:(SPDFReadOnlyCopyResolution)resolution
                               openError:(NSString*)openError
                              openStatus:(spdf_open_status)openStatus
                     savedFindMatchIndex:(NSInteger)savedFindMatchIndex {
    // Stale if anything loaded since the deferral (tab switch, new open,
    // close, reload): loadSelectedTab clears the token on entry.
    if (!_pendingDeferredCloudOpenToken.length || ![_pendingDeferredCloudOpenToken isEqualToString:token]) {
        if (newDoc) spdf_close(newDoc);
        return;
    }
    _pendingDeferredCloudOpenToken = nil;
    SPDFDocumentTab* tab = [self selectedTab];
    if (!tab || _doc || ![tab.path.stringByStandardizingPath isEqualToString:standardizedPath]) {
        if (newDoc) spdf_close(newDoc);
        return;
    }
    // Apply the read-only copy binding resolved off-main now that we are on the
    // main thread and have confirmed this tab is still the live target.
    [self applyReadOnlyCopyResolution:resolution toTab:tab];
    NSString* path = [tab.path copy];
    NSString* openPath = resolution.workingPath.length ? resolution.workingPath : path;
    spdf_launch_profile_log(@"cloud-deferred open landing %@", path.lastPathComponent);
    if (!attributes) {
        if (newDoc) spdf_close(newDoc);
        tab.missingFile = YES;
        tab.missingMessage = @"File moved or deleted";
        [self showUnavailableSelectedTab:tab path:path message:tab.missingMessage showOpenError:NO error:NULL];
        return;
    }
    if (!newDoc) {
        if (openStatus == SPDF_OPEN_PASSWORD_REQUIRED || openStatus == SPDF_OPEN_BAD_PASSWORD) {
            [self promptForPasswordForTab:tab
                                 openPath:openPath
                               sourcePath:path
                               attributes:attributes
                      savedFindMatchIndex:savedFindMatchIndex];
            return;
        }
        NSString* message = @"Could not open document";
        tab.missingFile = NO;
        tab.missingMessage = message;
        [self showUnavailableSelectedTab:tab path:path message:message showOpenError:YES error:openError.UTF8String];
        return;
    }
    [self presentOpenedDocument:newDoc
                         forTab:tab
                           path:path
                     attributes:attributes
            savedFindMatchIndex:savedFindMatchIndex];
}

- (void)loadSelectedTab {
    if (_selectedTabIndex < 0 || _selectedTabIndex >= (NSInteger)_tabs.count) return;
    SPDFDocumentTab* tab = _tabs[(NSUInteger)_selectedTabIndex];
    if (!tab.path.length) return;
    NSString* path = [tab.path copy];
    [self collectionPrepareForTabPath:path];
    NSString* standardizedPath = path.stringByStandardizingPath;
    SPDFMacInactivePreload* selectedPreload = _preloadResults[standardizedPath];
    if (selectedPreload && ![selectedPreload claimForForeground]) selectedPreload = nil;
    [selectedPreload.operation cancel];
    [self cancelInactiveTabPreloads];
    // Any new load supersedes a pending deferred cloud open; its completion
    // sees a stale token and abandons silently.
    _pendingDeferredCloudOpenToken = nil;
    [self dismissPendingPasswordPrompt];
    [self cancelDocumentTransientInteraction];
    [self clearToolbarFieldFocusForTabSwitch];
    [self.tabLifecycle recordActivationOfIdentifier:tab]; [_launchWorkCoordinator recordActivationOfIdentifier:tab];
    [self activityTabDidLoad:tab]; // last opened, and the tab in front (SPDFMacDocumentActivityIntegration.h)
    NSInteger savedFindMatchIndex = tab.findMatchIndex;
    [_renderQueue cancelAllOperations];
    [self cancelCacheRenderOperations];
    [_minimapQueue cancelAllOperations];
    [_queuedRenderPages removeAllObjects];
    [_queuedRenderOperations removeAllObjects];
    [_queuedMinimapThumbnailPages removeAllObjects];

    [self deactivateActiveMarkdownView];
    [self closeActiveDocumentIfUnowned];

    if (SPDFIsRenderedTextDocumentPath(path)) {
        [self loadSelectedMarkdownTab:tab];
        return;
    }

    // Launch only: a restored active tab on cloud storage (DriveFS & co.) can
    // stall stat+open for ~1s on cache revalidation. Show the full window
    // immediately and complete the identical restore when the background open
    // lands. Local documents keep the exact synchronous path below.
    if (_startupDocumentWorkInProgress && !tab.cachedDocument && [self pathIsOnCloudStorage:path]) {
        [self deferCloudBackedOpenForSelectedTab:tab path:path savedFindMatchIndex:savedFindMatchIndex];
        return;
    }

    // Read-only shadow copy: source attributes come from a BARE lstat (silent)
    // when the source is read-only — never the prompting -attributesOfItemAtPath:.
    // This single lstat also sets tab.readOnly (the dot). A writable source keeps
    // the unchanged full-attributes path. At launch/restore for a persisted
    // read-only tab whose copy exists, this lstat is the ONLY source touch; the
    // copy is opened below and reused unless the lstat shows the source changed.
    double launchStatStart = spdf_launch_profile_enabled() ? spdf_zoom_profile_now_ms() : 0.0;
    NSDictionary* attributes = [self sourceAttributesForTab:tab path:path];
    if (launchStatStart > 0.0) {
        spdf_launch_profile_log(@"sourceAttributes %@ %.1fms", path.lastPathComponent,
                                spdf_zoom_profile_now_ms() - launchStatStart);
    }
    if (!attributes) {
        tab.missingFile = YES;
        tab.missingMessage = @"File moved or deleted";
        [self showUnavailableSelectedTab:tab path:path message:tab.missingMessage showOpenError:NO error:NULL];
        return;
    }
    // workingPath is the temp render copy for a read-only source (created/refreshed
    // from the source content only when missing or the bare-lstat shows a change),
    // the source itself otherwise. Render/open use workingPath; path (== source)
    // stays the identity everywhere else.
    NSDictionary* previousCopyBinding = tab.readOnlyCopyBinding;
    NSString* workingPath = [self ensureWorkingPathForTab:tab sourcePath:path attributes:attributes];
    BOOL renewedCopy = (previousCopyBinding.count || tab.readOnlyCopyBinding.count) &&
        ![previousCopyBinding isEqual:tab.readOnlyCopyBinding];
    if (renewedCopy) {
        [selectedPreload discardForegroundDocumentWithHandler:^(void* stale) { if (stale) spdf_close((spdf_document*)stale); }];
        selectedPreload = nil;
    }

    if ([self tab:tab cacheMatchesFileAttributes:attributes]) {
        [self activateCachedSelectedTab:tab path:path attributes:attributes savedFindMatchIndex:savedFindMatchIndex];
        return;
    }

    if (tab.cachedDocument) [self collectionRecordObservedChangeAtPath:path];
    [self discardCachedRuntimeForTab:tab];
    [self clearActiveMetadata];

    char err[1024];
    err[0] = '\0';
    NSDictionary* preloadedAttributes = nil;
    spdf_document* newDoc = (spdf_document*)[selectedPreload takeForegroundDocumentWithAttributes:&preloadedAttributes];
    if (newDoc && ![self fileAttributes:preloadedAttributes matchFileAttributes:attributes]) {
        spdf_close(newDoc);
        newDoc = NULL;
    }
    if (newDoc) spdf_launch_profile_log(@"spdf_open %@ adopted from inactive preload", path.lastPathComponent);
    if (!newDoc && !renewedCopy) newDoc = [self takeLaunchPrerenderedDocumentForPath:workingPath attributes:attributes];
    if (newDoc) spdf_launch_profile_log(@"spdf_open %@ adopted from prerender", path.lastPathComponent);
    spdf_open_status openStatus = SPDF_OPEN_OK;
    if (!newDoc) {
        double launchOpenStart = spdf_launch_profile_enabled() ? spdf_zoom_profile_now_ms() : 0.0;
        newDoc = [self openSpdfDocumentAtPath:workingPath
                                   sourcePath:path
                                       status:&openStatus
                                        error:err
                                  errorLength:sizeof(err)];
        if (launchOpenStart > 0.0) {
            spdf_launch_profile_log(@"spdf_open %@ %.1fms", path.lastPathComponent,
                                    spdf_zoom_profile_now_ms() - launchOpenStart);
        }
    }
    if (!newDoc) {
        if (openStatus == SPDF_OPEN_PASSWORD_REQUIRED || openStatus == SPDF_OPEN_BAD_PASSWORD) {
            [self promptForPasswordForTab:tab
                                 openPath:workingPath
                               sourcePath:path
                               attributes:attributes
                      savedFindMatchIndex:savedFindMatchIndex];
            return;
        }
        NSString* message = @"Could not open document";
        tab.missingFile = NO;
        tab.missingMessage = message;
        [self showUnavailableSelectedTab:tab path:path message:message showOpenError:YES error:err];
        return;
    }

    [self presentOpenedDocument:newDoc
                         forTab:tab
                           path:path
                     attributes:attributes
            savedFindMatchIndex:savedFindMatchIndex];
}

// Tail of loadSelectedTab once the document handle exists: identical for the
// synchronous path and the deferred cloud-open completion.
- (void)presentOpenedDocument:(spdf_document*)newDoc
                       forTab:(SPDFDocumentTab*)tab
                         path:(NSString*)path
                   attributes:(NSDictionary*)attributes
          savedFindMatchIndex:(NSInteger)savedFindMatchIndex {
    tab.missingFile = NO;
    tab.missingMessage = @"";
    objc_setAssociatedObject(tab, &kSPDFPasswordPromptClosesNewTabKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    tab.cachedDocument = newDoc;
    [self collectionDidOpenPath:path]; [self aiDocumentDidOpen:path];
    [self recordFileAttributes:attributes forTab:tab];
    [self primePageGeometryCacheForDocument:newDoc
                          pageGeometryState:[self pageGeometryStateForPath:path]
                                   fileSize:spdf_file_size_from_attributes(attributes)
                           modificationDate:spdf_file_modification_date_from_attributes(attributes)];
    _doc = newDoc;
    NSInteger pageCount = spdf_page_count(_doc);
    [self applySinglePageMinimapDefaultToTab:tab pageCount:pageCount];
    [self prepareSelectedTabViewState:tab path:path];
    {
        SPDFScopedLaunchPhaseLog launchPhase("loadInitialSidebarMetadata");
        [self loadInitialSidebarMetadataForSelectedTabIfNeeded];
    }
    _pageIndex = MAX(0, MIN(tab.pageIndex, pageCount - 1));
    _fitPageIndex = spdf_tab_fit_page_index(tab, _pageIndex, pageCount);
    _renderGeneration++;
    _rememberedCustomZoom = tab.customZoom > 0 ? tab.customZoom : (tab.zoom > 0 ? tab.zoom : 1.0);
    _fitMode = tab.fitMode;
    _zoom = [self zoomForFitMode:_fitMode pageIndex:_fitPageIndex];

    _statusLabel.stringValue = @"Opening...";
    NSClipView* clipView = _pageScrollView.contentView;
    BOOL previousHidden = _pageScrollView.hidden;
    BOOL previousPostsBoundsChangedNotifications = clipView.postsBoundsChangedNotifications;
    BOOL previousSuppressScrollCallbacks = _suppressScrollCallbacks;
    _suppressScrollCallbacks = YES;
    _pageScrollView.hidden = YES;
    clipView.postsBoundsChangedNotifications = NO;
    [self replaceDocumentViewForTabSwitch];
    _pageView.emptyMessage = @"Open a document";
    if (_presentationMode)
        _pageScrollView.verticalScroller = nil;
    else if (_pageScrollView.verticalScroller != _markerScroller)
        _pageScrollView.verticalScroller = _markerScroller;
    _pageScrollView.hasVerticalScroller = !_presentationMode;
    _minimapInitialPopulationPending = YES;
    BOOL previousSuppressViewportRerender = _suppressViewportRerender;
    _suppressViewportRerender = YES;
    [self setMinimapActuallyVisible:_minimapPreferredVisible];
    tab.title = spdf_display_name_for_path(_path);

    {
        SPDFScopedLaunchPhaseLog launchPhase("rebuildSidebar");
        [self rebuildSidebar];
    }
    [self updateTabStrip];
    _suppressViewportRerender = previousSuppressViewportRerender;
    NSValue* restoreOrigin = tab.hasScrollOrigin ? [NSValue valueWithPoint:tab.scrollOrigin] : nil;
    {
        SPDFScopedLaunchPhaseLog launchPhase("renderDocumentAndScrollToPage(first)");
        [self renderDocumentAndScrollToPage:_pageIndex alignTop:YES restoreOrigin:restoreOrigin];
    }
    NSUInteger layoutGeneration = _renderGeneration;
    NSString* layoutPath = [_path copy];
    clipView.postsBoundsChangedNotifications = previousPostsBoundsChangedNotifications;
    _pageScrollView.hidden = previousHidden;
    [self stabilizeDocumentLayoutWithRestoreOrigin:restoreOrigin
                                          alignTop:YES
                                        generation:layoutGeneration
                                              path:layoutPath];
    _suppressScrollCallbacks = previousSuppressScrollCallbacks;
    [self stabilizeDocumentLayoutWithRestoreOrigin:restoreOrigin
                                          alignTop:YES
                                        generation:layoutGeneration
                                              path:layoutPath];
    // Once more after the run loop has laid the window out, unless the view moved since: a page turned right after
    // the switch (this pass can come tens of ms later on a busy machine) is where the person is, not the tab's place.
    NSPoint settledOrigin = _pageScrollView.contentView.bounds.origin;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!NSEqualPoints(self->_pageScrollView.contentView.bounds.origin, settledOrigin)) return;
      [self stabilizeDocumentLayoutWithRestoreOrigin:restoreOrigin
                                            alignTop:YES
                                          generation:layoutGeneration
                                                path:layoutPath];
    });
    [self schedulePostFirstPaintWorkForGeneration:layoutGeneration
                                             path:layoutPath
                              savedFindMatchIndex:savedFindMatchIndex
                                    restoreSearch:_searchField.stringValue.length > 0
                              preferredRenderPage:_pageIndex];
    [self clearToolbarFieldFocusForTabSwitch];
    [self repointActiveFileWatcher];
    [self savePersistentState];
}

- (SPDFDocumentTab*)newTabForPath:(NSString*)path {
    SPDFDocumentTab* tab = [[SPDFDocumentTab alloc] init];
    tab.path = [path copy];
    tab.title = spdf_display_name_for_path(path);
    [self seedNewTabFromDocumentMemory:tab];
    tab.zoom = 1.0;
    tab.customZoom = 1.0;
    tab.fitMode = SPDFFitModePage;
    tab.searchText = @"";
    tab.searchRegex = NO;
    tab.searchRegexMultiline = YES;
    tab.findMatchIndex = -1;
    // A freshly opened document follows the "Open New Documents with Side
    // Panel/Map" defaults. We deliberately do NOT restore the document's
    // previously remembered panel state here: per-document panel memory is only
    // honored for session restore (a tab that was open at quit, see
    // -loadSessionWindowState:). The defaults are still narrowed afterwards by
    // the single-page minimap rule (-applySinglePageMinimapDefaultToTab:) and by
    // the no-chapters/no-comments side-panel gate in -rebuildSidebar.
    tab.showSidebar = _defaultSidebarVisibleForNewDocuments;
    tab.showMinimap = _defaultMinimapVisibleForNewDocuments;
    objc_setAssociatedObject(tab, &kSPDFPasswordPromptClosesNewTabKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return tab;
}

- (SPDFDocumentTab*)tabSnapshotForDragAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_tabs.count) return nil;
    [self rememberActiveTabState];
    return spdf_copy_document_tab(_tabs[(NSUInteger)index]);
}

- (void)insertDraggedTab:(SPDFDocumentTab*)tab atIndex:(NSInteger)index {
    if (!tab.path.length) return;
    NSInteger existing = [self indexOfTabForPath:tab.path];
    if (existing >= 0) {
        [self selectTabAtIndex:existing];
        return;
    }
    tab.title = tab.title.length ? tab.title : spdf_display_name_for_path(tab.path);
    [self rememberActiveTabState];
    index = MAX(0, MIN(index, (NSInteger)_tabs.count));
    [_tabs insertObject:tab atIndex:(NSUInteger)index];
    _selectedTabIndex = index;
    [self normalizeTabGroups];
    [self activateSelectedTabGroup];
    [self loadSelectedTab];
    if ([self hasActiveDocument] && _path.length > 0) [self rememberRecentlyOpenedPath:_path];
    [self savePersistentState];
    [self focusActiveDocumentViewAfterTabSelection];
}

- (void)selectTabAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_tabs.count) return;
    if (index != _selectedTabIndex || [self hasActiveDocument])
        spdf_tab_groups_activate(_tabs, _tabs[(NSUInteger)index]);
    [self updateTabStrip];
    if (index == _selectedTabIndex && [self hasActiveDocument]) {
        // A stranded Loading markdown session still counts as an active
        // document: re-kick it instead of early-returning into the strand.
        [self ensureActiveMarkdownTabHasContent];
        // Re-clicking the active tab still plants keyboard focus on the document.
        [self focusActiveDocumentViewAfterTabSelection];
        if (_tabs[(NSUInteger)index].group) [self savePersistentState];
        [_tabStrip revealSelectedTab]; return;
    }
    [self clearToolbarFieldFocusForTabSwitch];
    [self rememberActiveTabState];
    [self notePreviousTabTransitionFrom:[self selectedTab] to:_tabs[(NSUInteger)index]];
    _selectedTabIndex = index;
    [self normalizeTabGroups];
    [self loadSelectedTab];
    [self savePersistentState];
    [self focusActiveDocumentViewAfterTabSelection]; [_tabStrip revealSelectedTab];
}

- (void)closeTabAtIndex:(NSInteger)index {
    [self closeTabAtIndex:index preferMostRecentActive:NO];
}

- (void)closeTabAtIndex:(NSInteger)index preferMostRecentActive:(BOOL)preferMostRecentActive {
    if (index < 0 || index >= (NSInteger)_tabs.count) return;
    BOOL closingActive = index == _selectedTabIndex;
    if (closingActive) [self cancelDocumentTransientInteraction];
    SPDFDocumentTab* closingTab = _tabs[(NSUInteger)index];
    if (closingActive) [self rememberActiveTabState];
    [self updatePreviousTabSnapshotForTab:closingTab];
    if (_selectedTabIndex >= 0 && _selectedTabIndex < (NSInteger)_tabs.count)
        [self.tabLifecycle recordActivationOfIdentifier:_tabs[(NSUInteger)_selectedTabIndex]];
    SPDFDocumentTab* replacementTab = [self.tabLifecycle removeIdentifier:closingTab
                                                   fromOrderedIdentifiers:[_tabs copy]
                                                   preferMostRecentActive:preferMostRecentActive];
    if (closingActive && replacementTab) [self notePreviousTabTransitionFrom:closingTab to:replacementTab];
    NSString* closedPath = [closingTab.path copy];
    [self collectionClearObservedChangeAtPath:closedPath];
    // Read-only shadow copy: a deliberately-closed tab's private temp copy is
    // deleted here (NOT in -discardCachedRuntimeForTab:, which runs on reopen).
    // Skip if another tab in this window still uses the same copy (shared
    // read-only source); the launch orphan sweep is the cross-window backstop.
    [self deleteReadOnlyCopyIfUnsharedForTab:closingTab];
    [self rememberClosedDocumentPath:closedPath];
    [_preloadingPaths removeObject:closedPath.stringByStandardizingPath];
    [_preloadTokens removeObjectForKey:closedPath.stringByStandardizingPath];
    [self discardCachedRuntimeForTab:closingTab];
    [_tabs removeObjectAtIndex:(NSUInteger)index];
    if (!closingActive && index < _selectedTabIndex) _selectedTabIndex--;

    if (_tabs.count == 0) {
        BOOL shouldCloseThisWindow = ![self emptyTabGroups].count && [self hasOtherShenzhenWindows];
        [self clearToolbarFieldFocusForTabSwitch];
        _selectedTabIndex = -1;
        [self cancelInactiveTabPreloads];
        [self clearActiveMetadata];
        [self teardownActiveFileWatcher];
        [self deactivateActiveMarkdownView];
        [self closeActiveDocumentIfUnowned];
        _path = nil;
        _workingPath = nil; // keep working/source paths in sync when the doc clears
        _pageIndex = 0;
        _selectedText = nil;
        _searchField.stringValue = @"";
        _findRegexCheckbox.state = NSControlStateValueOff;
        _findRegexMultiline = YES;
        [self clearFindResults];
        _renderGeneration++;
        [_renderedPages removeAllObjects];
        [self rebuildSidebar];
        if (shouldCloseThisWindow) {
            _suppressSessionWriteOnTerminate = YES;
            _terminateOnlyThisProcess = YES;
            [self hideWindowsForQuit];
            [self removeSessionStateForCurrentWindow];
            dispatch_async(dispatch_get_main_queue(), ^{
              [NSApp terminate:self];
            });
            return;
        }
        [self showEmptyDocumentViewWithMessage:@"Open a document"];
        _window.title = @"Shenzhen PDF";
        _statusLabel.stringValue = @"Ready";
        [self updateTabStrip];
        [self updateControls];
        [self clearToolbarFieldFocusForTabSwitch];
        [self savePersistentState];
        return;
    }

    if (closingActive) {
        NSInteger replacementIndex = [_tabs indexOfObjectIdenticalTo:replacementTab];
        _selectedTabIndex = replacementIndex == NSNotFound ? MIN(index, (NSInteger)_tabs.count - 1) : replacementIndex;
        [self normalizeTabGroups];
        [self activateSelectedTabGroup];
        [self loadSelectedTab];
        [self focusActiveDocumentViewAfterTabSelection];
    } else {
        [self updateTabStrip];
        [self scheduleNearbyPageRendersAfterFirstPaintForGeneration:_renderGeneration preferredPage:_pageIndex];
        [self savePersistentState];
    }
}

- (void)moveTabFromIndex:(NSInteger)fromIndex toIndex:(NSInteger)toIndex {
    NSInteger count = (NSInteger)_tabs.count;
    if (fromIndex < 0 || fromIndex >= count || toIndex < 0 || toIndex >= count || fromIndex == toIndex) return;

    SPDFDocumentTab* tab = _tabs[(NSUInteger)fromIndex];
    [_tabs removeObjectAtIndex:(NSUInteger)fromIndex];
    [_tabs insertObject:tab atIndex:(NSUInteger)toIndex];

    if (_selectedTabIndex == fromIndex) {
        _selectedTabIndex = toIndex;
    } else if (fromIndex < _selectedTabIndex && _selectedTabIndex <= toIndex) {
        _selectedTabIndex--;
    } else if (toIndex <= _selectedTabIndex && _selectedTabIndex < fromIndex) {
        _selectedTabIndex++;
    }

    [self updateTabStrip];
    [self savePersistentState];
}

- (void)newTabRequested:(id)sender { [self openDocument:sender]; }

// Most-recent persisted Recently Opened path (index 0 is newest) that isn't
// already open in a tab, or nil. Used as the Reopen Last Closed fallback after a
// relaunch, when the in-session closed stack is empty.
- (NSString*)firstRecentlyOpenedPathNotOpen {
    for (NSString* path in _recentlyOpenedPaths) {
        if (path.length && [self indexOfTabForPath:path] < 0) return path;
    }
    return nil;
}

- (void)reopenLastClosedDocument:(id)sender {
    (void)sender;
    // Prefer the in-session stack of explicitly closed documents.
    while (_closedDocumentPaths.count > 0) {
        NSString* path = _closedDocumentPaths.lastObject;
        [_closedDocumentPaths removeLastObject];
        if (path.length) {
            [self openPath:path];
            return;
        }
    }
    // The closed stack is in-memory only, so after relaunch it is empty. Fall
    // back to the persisted Recently Opened list (newest first), reopening the
    // first entry that isn't already open. Repeated presses walk down the list.
    NSString* fallback = [self firstRecentlyOpenedPathNotOpen];
    if (fallback.length) [self openPath:fallback];
}

- (CGFloat)minimumSidebarWidthForCurrentContent {
    return [self hasSearchSidebar] ? kSearchSidebarMinWidth : kMinSidebarWidth;
}

- (CGFloat)maximumSidebarWidthForCurrentContent {
    CGFloat containerWidth = _splitView ? NSWidth(_splitView.bounds) : 0.0;
    return MAX([self minimumSidebarWidthForCurrentContent], spdf_max_sidebar_width_for_container(containerWidth));
}

- (CGFloat)clampedSidebarWidth {
    CGFloat minWidth = [self minimumSidebarWidthForCurrentContent];
    CGFloat maxWidth = [self maximumSidebarWidthForCurrentContent];
    if (!isfinite(_sidebarWidth) || _sidebarWidth < kMinSidebarWidth || _sidebarWidth > kMaxSidebarWidth)
        return spdf_clamp_cg(kDefaultSidebarWidth, minWidth, maxWidth);
    return spdf_clamp_cg(_sidebarWidth, minWidth, maxWidth);
}

- (BOOL)currentSidebarFrameIsPersistable {
    if (!_splitView || !_sidebarContainer) return NO;
    CGFloat width = NSWidth(_sidebarContainer.frame);
    CGFloat minWidth = [self minimumSidebarWidthForCurrentContent];
    CGFloat maxWidth = [self maximumSidebarWidthForCurrentContent];
    return isfinite(width) && width >= minWidth - 1.0 && width <= maxWidth + 1.0;
}

- (void)normalizeSidebarModeControlWidths {
    if (!_sidebarVisible || !_sidebarContainer || !_sidebarModeControl) return;
    CGFloat controlWidth = NSWidth(_sidebarContainer.bounds) - 16.0;
    if (!isfinite(controlWidth) || controlWidth < 160.0) controlWidth = [self clampedSidebarWidth] - 16.0;
    NSInteger segmentCount = MAX(1, _sidebarModeControl.segmentCount);
    CGFloat minSegmentWidth = segmentCount >= 3 ? 66.0 : 78.0;
    CGFloat segmentWidth = floor(MAX(minSegmentWidth, controlWidth / (CGFloat)segmentCount));
    for (NSInteger segment = 0; segment < segmentCount; ++segment)
        [_sidebarModeControl setWidth:segmentWidth forSegment:segment];
    [_sidebarModeControl invalidateIntrinsicContentSize];
    [_sidebarModeControl setNeedsLayout:YES];
}

- (void)restoreSidebarWidth {
    if (!_splitView || !_sidebarContainer || !_sidebarVisible || _splitView.subviews.count < 2) return;
    CGFloat effectiveWidth = [self clampedSidebarWidth];
    _restoringSidebarLayout = YES;
    _sidebarContainer.hidden = NO;
    _sidebarDividerView.hidden = NO;
    [_splitView layoutSubtreeIfNeeded];
    [_splitView setPosition:effectiveWidth ofDividerAtIndex:0];
    [_splitView layoutSubtreeIfNeeded];
    [self normalizeSidebarModeControlWidths];
    _restoringSidebarLayout = NO;
}

- (void)setWorkspaceSidebarVisibleWithoutPolicy:(BOOL)visible {
    if (!_splitView || !_sidebarContainer || !_documentContainer) return;
    if (![_splitView.subviews containsObject:_sidebarContainer])
        [_splitView addSubview:_sidebarContainer positioned:NSWindowBelow relativeTo:_splitView.subviews.firstObject];
    _sidebarContainer.hidden = NO;
    if (visible == _sidebarVisible) {
        _sidebarDividerView.hidden = !visible;
        [self syncToolbarState];
        [self updateControls];
        return;
    }

    _restoringSidebarLayout = YES;
    if (visible) {
        _sidebarVisible = YES;
        _sidebarDividerView.hidden = NO;
        [_splitView layoutSubtreeIfNeeded];
        [_splitView setPosition:[self clampedSidebarWidth] ofDividerAtIndex:0];
        [_splitView layoutSubtreeIfNeeded];
        [self normalizeSidebarModeControlWidths];
    } else {
        if (_allowSidebarWidthPersistence && [self currentSidebarFrameIsPersistable])
            _sidebarWidth = spdf_sane_sidebar_width(NSWidth(_sidebarContainer.frame), NSWidth(_splitView.bounds));
        _sidebarVisible = NO;
        _sidebarDividerView.hidden = YES;
        [_splitView layoutSubtreeIfNeeded];
        if (_splitView.subviews.count >= 2) [_splitView setPosition:0.0 ofDividerAtIndex:0];
    }
    [_splitView layoutSubtreeIfNeeded];
    _restoringSidebarLayout = NO;
    [_splitView layoutSubtreeIfNeeded];
    [self relayoutDocumentForViewportChange];
    [self syncToolbarState];
    [self updateControls];
}

- (void)setWorkspaceMapVisibleWithoutPolicy:(BOOL)visible {
    if (!_minimapView || !_minimapWidthConstraint || !_minimapDividerView) {
        [self syncToolbarState];
        return;
    }
    BOOL actualVisible = visible && [self hasActiveDocument];
    BOOL constraintsMatch = actualVisible
                                ? (!_pageScrollFullWidthConstraint.active && _pageScrollToMinimapConstraint.active)
                                : (_pageScrollFullWidthConstraint.active && !_pageScrollToMinimapConstraint.active);
    if (actualVisible == _minimapVisible && _minimapWidthConstraint.constant == (actualVisible ? _minimapWidth : 0.0) &&
        constraintsMatch) {
        [self syncToolbarState];
        return;
    }
    _minimapVisible = actualVisible;
    _minimapView.hidden = !actualVisible;
    _minimapDividerView.hidden = !actualVisible;
    _minimapWidthConstraint.constant = actualVisible ? _minimapWidth : 0.0;
    _minimapDividerWidthConstraint.constant = actualVisible ? SPDFPaneDividerHitWidth : 0.0;
    if (actualVisible) {
        _pageScrollFullWidthConstraint.active = NO;
        _pageScrollToMinimapConstraint.active = YES;
    } else {
        _pageScrollToMinimapConstraint.active = NO;
        _pageScrollFullWidthConstraint.active = YES;
    }
    // Launch fast path (prototype): during buildWindow (_uiReady == NO, no
    // document, window not yet displayable) only the constraint/hidden state
    // above matters. The synchronous layout + viewport relayout below would
    // be redone from scratch by the first document layout or by
    // showEmptyDocumentViewWithMessage before anything is visible, so solving
    // the intermediate no-document layout here is pure launch overhead.
    if (!_uiReady && !_doc) {
        [self syncToolbarState];
        return;
    }
    [_documentContainer layoutSubtreeIfNeeded];
    [self relayoutDocumentForViewportChange];
    [self updateMinimap];
    if (actualVisible && _doc) {
        if (!_suppressViewportRerender) [self renderPageIfNeededAtIndex:_pageIndex];
        [self enqueueZoomSeedCachesForGeneration:_renderGeneration preferredPage:_pageIndex includeWholeBase:NO];
        [self enqueueNearbyPageRendersForGeneration:_renderGeneration preferredPage:_pageIndex];
    }
    [self syncToolbarState];
}

- (void)sidebarDividerDraggedByDeltaX:(CGFloat)deltaX {
    if (!_splitView || !_sidebarContainer || !_sidebarVisible || _splitView.subviews.count < 2) return;
    CGFloat currentWidth = NSWidth(_sidebarContainer.frame);
    if (!isfinite(currentWidth) || currentWidth <= 0.0) currentWidth = [self clampedSidebarWidth];
    _sidebarWidth = spdf_clamp_cg(currentWidth + deltaX, [self minimumSidebarWidthForCurrentContent],
                                  [self maximumSidebarWidthForCurrentContent]);
    [_splitView setPosition:_sidebarWidth ofDividerAtIndex:0];
    [_splitView layoutSubtreeIfNeeded];
}

- (void)sidebarDividerDidFinishDragging {
    if (!_sidebarVisible) return;
    if ([self currentSidebarFrameIsPersistable])
        _sidebarWidth = spdf_sane_sidebar_width(NSWidth(_sidebarContainer.frame), NSWidth(_splitView.bounds));
    [self savePersistentState];
}

- (void)minimapDividerDraggedByDeltaX:(CGFloat)deltaX {
    if (!_minimapPreferredVisible || !_minimapVisible) return;
    CGFloat maxWidth = MAX(120.0, MIN(320.0, NSWidth(_documentContainer.bounds) * 0.35));
    _minimapWidth = spdf_clamp_cg(_minimapWidth - deltaX, 72.0, maxWidth);
    _minimapWidthConstraint.constant = _minimapWidth;
    [_documentContainer layoutSubtreeIfNeeded];
    [self syncWorkspaceChrome];
    [self resizeDocumentView];
    [self renderVisiblePageCropsForCurrentViewportIfNeeded];
    [_pageView setNeedsDisplay:YES];
    [self updateMinimap];
}

- (void)minimapDividerDidFinishDragging {
    [self savePersistentState];
    if (_doc && (_fitMode == SPDFFitModeWidth || _fitMode == SPDFFitModeHeight || _fitMode == SPDFFitModePage))
        [self renderDocumentAndScrollToPage:_pageIndex alignTop:NO];
}

- (NSRect)splitView:(NSSplitView*)splitView
       effectiveRect:(NSRect)proposedEffectiveRect
        forDrawnRect:(NSRect)drawnRect
    ofDividerAtIndex:(NSInteger)dividerIndex {
    if (splitView == _splitView && dividerIndex == 0 && _sidebarVisible) {
        CGFloat centerX = NSMidX(drawnRect);
        return NSMakeRect(floor(centerX - kSidebarDividerWidth / 2.0), 0.0, kSidebarDividerWidth,
                          NSHeight(splitView.bounds));
    }
    return proposedEffectiveRect;
}

- (CGFloat)splitView:(NSSplitView*)splitView
    constrainMinCoordinate:(CGFloat)proposedMinimumPosition
               ofSubviewAt:(NSInteger)dividerIndex {
    (void)proposedMinimumPosition;
    (void)dividerIndex;
    if (splitView == _splitView) return _sidebarVisible ? [self minimumSidebarWidthForCurrentContent] : 0.0;
    return proposedMinimumPosition;
}

- (CGFloat)splitView:(NSSplitView*)splitView
    constrainMaxCoordinate:(CGFloat)proposedMaximumPosition
               ofSubviewAt:(NSInteger)dividerIndex {
    (void)proposedMaximumPosition;
    (void)dividerIndex;
    if (splitView == _splitView) return [self maximumSidebarWidthForCurrentContent];
    return proposedMaximumPosition;
}

- (BOOL)splitView:(NSSplitView*)splitView shouldAdjustSizeOfSubview:(NSView*)view {
    if (splitView == _splitView) return view == _documentContainer || [_documentContainer isDescendantOf:view];
    return YES;
}

- (void)splitViewDidResizeSubviews:(NSNotification*)notification {
    if (notification.object != _splitView || !_sidebarVisible) return;
    [self syncWorkspaceChrome];
    [self normalizeSidebarModeControlWidths];
    [self syncSidebarTableColumnWidth];
    if (_sidebarModeControl.spdf_selectedSidebarMode == SPDFSidebarModeSearch && _sidebarItems.count > 0)
        [_sidebarTable
            noteHeightOfRowsWithIndexesChanged:[NSIndexSet
                                                   indexSetWithIndexesInRange:NSMakeRange(0, _sidebarItems.count)]];
    if (_restoringSidebarLayout || !_allowSidebarWidthPersistence || _windowLiveResizing || [self workspacePanelPolicyIsApplying]) return;
    if ([self hasActiveDocument]) [self relayoutDocumentForViewportChange];
    if ((NSEvent.pressedMouseButtons & 1) == 0) return;
    CGFloat width = NSWidth(_sidebarContainer.frame);
    if ([self currentSidebarFrameIsPersistable])
        _sidebarWidth = spdf_sane_sidebar_width(width, NSWidth(_splitView.bounds));
}

- (BOOL)hasSearchSidebar {
    return [self hasActiveDocument] &&
           (_searchField.stringValue.length > 0 || _findSearchInProgress || _findMatches.count > 0);
}

- (NSString*)sidebarFilterTextForCurrentMode {
    if (_sidebarModeControl.spdf_selectedSidebarMode == SPDFSidebarModeSearch) return @"";
    if (_sidebarModeControl.spdf_selectedSidebarMode == SPDFSidebarModeComments) return _commentFilterText ?: @"";
    return _chapterFilterText ?: @"";
}

- (void)setSidebarFilterTextForCurrentMode:(NSString*)filter {
    filter = filter ?: @"";
    if (_sidebarModeControl.spdf_selectedSidebarMode == SPDFSidebarModeSearch) return;
    if (_sidebarModeControl.spdf_selectedSidebarMode == SPDFSidebarModeComments)
        _commentFilterText = [filter copy];
    else
        _chapterFilterText = [filter copy];
}

- (void)syncSidebarFilterField {
    if (!_sidebarFilterField) return;
    BOOL comments = _sidebarModeControl.spdf_selectedSidebarMode == SPDFSidebarModeComments;
    BOOL search = _sidebarModeControl.spdf_selectedSidebarMode == SPDFSidebarModeSearch;
    _sidebarFilterField.hidden = search;
    _sidebarFilterTopConstraint.active = !search;
    _sidebarScrollBelowFilterConstraint.active = !search;
    _sidebarScrollBelowModeConstraint.active = search;
    _updatingSidebarFilterField = YES;
    _sidebarFilterField.placeholderString = comments ? @"Filter Comments" : @"Filter Chapters";
    _sidebarFilterField.stringValue = [self sidebarFilterTextForCurrentMode];
    _sidebarFilterField.enabled = !search;
    _updatingSidebarFilterField = NO;
    [self syncWorkspaceChrome];
}

- (void)syncSidebarTableColumnWidth {
    if (!_sidebarTable || _sidebarTable.tableColumns.count == 0) return;
    if (SPDFSidebarFitTableToViewport(_sidebarTable)) {
        // Comment rows wrap to the column width, so their heights change with it.
        NSMutableIndexSet* commentRows = [NSMutableIndexSet indexSet];
        for (NSUInteger i = 0; i < _sidebarItems.count; ++i)
            if ([_sidebarItems[(NSUInteger)i][@"kind"] isEqualToString:@"comment"]) [commentRows addIndex:i];
        if (commentRows.count > 0) [_sidebarTable noteHeightOfRowsWithIndexesChanged:commentRows];
    }
}

- (BOOL)sidebarSearchText:(NSString*)text matchesFilter:(NSString*)filter {
    if (filter.length == 0) return YES;
    if (text.length == 0) return NO;
    return [text rangeOfString:filter options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location !=
           NSNotFound;
}

- (NSString*)chapterTitleForPage:(NSInteger)pageIndex {
    if (_outline.count <= 0) return @"";
    NSString* title = @"";
    NSInteger bestPage = -1;
    NSInteger bestLevel = -1;
    for (int i = 0; i < _outline.count; ++i) {
        spdf_outline_item item = _outline.items[i];
        if (item.page_index < 0 || item.page_index > pageIndex) continue;
        if (item.page_index < bestPage) continue;
        NSInteger level = MAX(0, item.level);
        if (item.page_index == bestPage && level < bestLevel) continue;
        bestPage = item.page_index;
        bestLevel = level;
        title = item.title && *item.title ? [NSString stringWithUTF8String:item.title] : @"Untitled";
    }
    return title.length ? title : @"Document";
}

- (void)rebuildSidebar {
    [self syncSidebarNavigationAvailability];
    if ([self showSidebarWorkspacePanel] || [self collectionShowSelectedHistoryPanel]) return;
    if ([self isMarkdownActive]) {
        [self rebuildMarkdownSidebar];
        return;
    }
    [_sidebarItems removeAllObjects];
    BOOL hasChapters = _outline.count > 0 || [self aiGeneratedChapterRows].count > 0;
    BOOL hasComments = _comments.count > 0;
    BOOL hasSearch = [self hasSearchSidebar];
    BOOL hasSidebar = _sidebarModeControl != nil;

    if (_sidebarModeControl.spdf_selectedSidebarMode == SPDFSidebarModeSearch && !hasSearch)
        _sidebarModeControl.spdf_selectedSidebarMode =
            hasChapters ? SPDFSidebarModeChapters : (hasComments ? SPDFSidebarModeComments : SPDFSidebarModeChapters);
    else if (_sidebarModeControl.spdf_selectedSidebarMode == SPDFSidebarModeComments && !hasComments)
        _sidebarModeControl.spdf_selectedSidebarMode =
            hasChapters ? SPDFSidebarModeChapters : (hasSearch ? SPDFSidebarModeSearch : SPDFSidebarModeChapters);
    else if (_sidebarModeControl.spdf_selectedSidebarMode == SPDFSidebarModeChapters && !hasChapters)
        _sidebarModeControl.spdf_selectedSidebarMode =
            hasComments ? SPDFSidebarModeComments : (hasSearch ? SPDFSidebarModeSearch : SPDFSidebarModeChapters);
    else if (hasChapters && !hasComments && !hasSearch)
        _sidebarModeControl.spdf_selectedSidebarMode = SPDFSidebarModeChapters;
    else if (!hasChapters && hasComments && !hasSearch)
        _sidebarModeControl.spdf_selectedSidebarMode = SPDFSidebarModeComments;
    else if (!hasChapters && !hasComments && hasSearch)
        _sidebarModeControl.spdf_selectedSidebarMode = SPDFSidebarModeSearch;
    else if (!hasChapters && !hasComments && !hasSearch)
        _sidebarModeControl.spdf_selectedSidebarMode = SPDFSidebarModeChapters;

    [self syncSidebarFilterField];
    NSString* filter = [self sidebarFilterTextForCurrentMode];
    if (hasSidebar) {
        if (_sidebarModeControl.spdf_selectedSidebarMode == SPDFSidebarModeSearch && hasSearch) {
            [self rebuildSearchSidebarItems];
        } else if (_sidebarModeControl.spdf_selectedSidebarMode == SPDFSidebarModeComments && hasComments) {
            for (int i = 0; i < _comments.count; ++i) {
                spdf_comment_item item = _comments.items[i];
                NSString* type = item.type && *item.type ? [NSString stringWithUTF8String:item.type] : @"Comment";
                NSString* author = item.author && *item.author ? [NSString stringWithUTF8String:item.author] : @"";
                NSString* text = item.text && *item.text ? [NSString stringWithUTF8String:item.text] : @"";
                NSString* title = text.length ? text : type;
                if (author.length) title = [NSString stringWithFormat:@"%@: %@", author, title];
                NSString* haystack = [NSString
                    stringWithFormat:@"%@ %@ %@ p.%d", title ?: @"", author ?: @"", type ?: @"", item.page_index + 1];
                if (![self sidebarSearchText:haystack matchesFilter:filter]) continue;
                CGFloat width = item.bounds.x1 - item.bounds.x0;
                CGFloat height = item.bounds.y1 - item.bounds.y0;
                NSMutableDictionary* sidebarItem = [@{
                    @"title" : title ?: @"Comment",
                    @"page" : @(item.page_index),
                    @"level" : @0,
                    @"kind" : @"comment",
                    @"commentIndex" : @(item.index)
                } mutableCopy];
                if (width > 0 && height > 0) {
                    sidebarItem[@"bounds"] =
                        [NSValue valueWithRect:NSMakeRect(item.bounds.x0, item.bounds.y0, width, height)];
                }
                [_sidebarItems addObject:sidebarItem];
            }
        } else if (hasChapters) {
            [self appendAIGeneratedChaptersMatchingFilter:filter];
            for (int i = 0; i < _outline.count; ++i) {
                spdf_outline_item item = _outline.items[i];
                NSString* title = item.title ? [NSString stringWithUTF8String:item.title] : @"Untitled";
                if (![self sidebarSearchText:title matchesFilter:filter]) continue;
                [_sidebarItems addObject:@{
                    @"title" : title ?: @"Untitled",
                    @"page" : @(item.page_index),
                    @"level" : @(MAX(0, item.level)),
                    @"kind" : @"chapter"
                }];
            }
        }
    }
    BOOL showingSearchSidebar = hasSidebar && _sidebarModeControl.spdf_selectedSidebarMode == SPDFSidebarModeSearch && hasSearch;
    [self syncSidebarTableColumnWidth];
    [self applyChapterNestingAndReload];
    if (_sidebarItems.count > 0)
        [_sidebarTable
            noteHeightOfRowsWithIndexesChanged:[NSIndexSet
                                                   indexSetWithIndexesInRange:NSMakeRange(0, _sidebarItems.count)]];
    if (showingSearchSidebar && _findMatches.count == 0) {
        NSClipView* clipView = _sidebarTable.enclosingScrollView.contentView;
        [clipView scrollToPoint:NSZeroPoint];
        [_sidebarTable.enclosingScrollView reflectScrolledClipView:clipView];
    }
    [self setSidebarActuallyVisible:hasSidebar && _sidebarPreferredVisible];
    if (hasSidebar && _sidebarVisible) [self restoreSidebarWidth];
    if (!hasSidebar) return;
    [self syncSidebarTableColumnWidth];
    if (_sidebarItems.count > 0)
        [_sidebarTable
            noteHeightOfRowsWithIndexesChanged:[NSIndexSet
                                                   indexSetWithIndexesInRange:NSMakeRange(0, _sidebarItems.count)]];
    if (showingSearchSidebar && _findMatches.count == 0) {
        NSClipView* clipView = _sidebarTable.enclosingScrollView.contentView;
        [clipView scrollToPoint:NSZeroPoint];
        [_sidebarTable.enclosingScrollView reflectScrolledClipView:clipView];
    }
    [self selectCurrentSidebarRow];
}
- (void)sidebarModeChanged:(id)sender {
    (void)sender; [self rememberSidebarWorkspaceMode]; [self collectionRememberSidebarMode];
    [self syncSidebarFilterField];
    [self rebuildSidebar];
}

- (void)showSearchSidebarForFind {
    if (![self hasActiveDocument] || ![self hasSearchSidebar]) return;
    [self syncSidebarModeControlSegmentsForSearchAvailability:YES];
    _sidebarModeControl.spdf_selectedSidebarMode = SPDFSidebarModeSearch;
    _sidebarPreferredVisible = YES;
    [self rememberSidebarWorkspaceMode]; [self rebuildSidebar];
}

- (void)goToAdjacentPagePreservingRelativePosition:(NSInteger)delta {
    if (!_doc || delta == 0) return;
    NSInteger pageCount = spdf_page_count(_doc);
    if (pageCount <= 0) return;
    NSInteger target = MAX(0, MIN(_pageIndex + delta, pageCount - 1));
    if (target == _pageIndex) return;
    [self goToPage:target preserveSinglePagePosition:YES];
}

- (void)clipViewBoundsChanged:(NSNotification*)notification {
    (void)notification;
    if (_suppressScrollCallbacks) return;
    [self documentScrollPositionChanged];
}

- (void)documentScrollPositionChanged {
    if ([self isMarkdownActive]) {
        [self markdownDocumentScrollPositionChanged];
        return;
    }
    SPDFScopedProfileLog spdfScopedProfile("scrollPosChanged", 4.0);
    if (_suppressScrollCallbacks) return;
    _viewportMovementGeneration++;
    if (_renderedPages.count == 0) {
        [self updateMinimap];
        return;
    }
    if (_liveZooming) {
        [self setCurrentViewportNeedsDisplay];
        [self updateMinimap];
        return;
    }
    if (_minimapPrecisionViewportDragActive) {
        [self syncCurrentPageFromVisibleViewportQueueRenders:YES forceHighPriority:YES];
        [self renderVisiblePageCropsForCurrentViewportIfNeeded];
        [_pageView setNeedsDisplay:YES];
        [_pageView displayIfNeeded];
        [self updateMinimap];
        return;
    }
    if (_presentationMode) {
        [self updateMinimap];
        return;
    }
    if (!_updatingFromScroll) {
        NSInteger visiblePage = [_pageView pageIndexForVisibleRect:_pageScrollView.contentView.bounds];
        if (visiblePage != _pageIndex) {
            _pageIndex = visiblePage;
            _pageView.currentPageIndex = _pageIndex;
            [self clearPageFieldFocus];
            // Keep only the cheap page-indicator update on the scroll frame; defer
            // the heavy zoom-seed/neighbour-render/control/sidebar work off-frame
            // so crossing a page boundary doesn't stutter.
            [self updatePageIndicatorControls];
            [self schedulePageChangeFollowUp];
        }
    }
    [self updateHorizontalScrollLockAnimated:YES];
    BOOL panning = _documentViewPanActive;
    if (panning) {
        [self setCurrentViewportNeedsDisplay];
        [self updateMinimapViewportIndicator];
        [self scheduleDocumentPanMaintenance];
        return;
    }
    if (_liveZooming) {
        [_pageView setNeedsDisplay:YES];
        [self updateMinimap];
        return;
    }
    // Move the lightweight viewport indicator every event so it tracks the
    // scroll smoothly; the heavier crop/render/evict maintenance below stays
    // coalesced.
    [self updateMinimapViewportIndicator];
    // Trackpad scrolling delivers up to 120 events/s; doing crop checks, a
    // full minimap rebuild, and cache eviction per event saturates the main
    // thread and drops input. Coalesce that maintenance to display cadence.
    [self scheduleScrollViewportMaintenance];
}

- (void)scheduleScrollViewportMaintenance {
    if (_scrollMaintenanceScheduled) return;
    _scrollMaintenanceScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.033 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      self->_scrollMaintenanceScheduled = NO;
      if (!self->_doc) return;
      if (self->_liveZooming || self->_documentViewPanActive || self->_minimapPrecisionViewportDragActive) return;
      self->_scrollMaintenanceTickCount++;
      // Every tick (≈33ms): keep the visible viewport crisp and the minimap
      // indicator tracking. These touch only the visible set, so they're cheap.
      [self renderVisiblePageCropsForCurrentViewportIfNeeded];
      // A page taller than several viewports (e.g. an oversized schematic page)
      // keeps _pageIndex pinned across many scroll ticks, so the neighbor
      // full-page scheduling in documentScrollPositionChanged never re-fires and
      // the normal pages above/below it stay blank. The crop pass above only
      // covers crop-regime pages, so schedule full-page renders for the current
      // visible set here too (deduped via _queuedRenderOperations).
      [self queueVisibleDocumentPageRendersForCurrentViewportForceHighPriority:NO];
      [self updateMinimapForScrolling];
      // Heavier passes — the zoom-scaled neighbourhood prefetch, the padded
      // minimap-thumbnail band, and the O(total-pages) eviction sweep — don't
      // need per-frame cadence; running them every tick saturated the main thread
      // and dropped frames on large documents. Coalesce to ≈200ms (every 6th
      // tick, starting on the first so prefetch still kicks in promptly).
      if (self->_scrollMaintenanceTickCount % 6 == 1) {
          [self enqueueCurrentPageNeighborhoodRendersForGeneration:self->_renderGeneration
                                                     preferredPage:self->_pageIndex
                                                 forceHighPriority:NO];
          [self enqueueVisibleMinimapThumbnailRenders];
          [self evictDistantRenderedPageImages];
      }
      NSUInteger generation = ++self->_scrollIdleMinimapRefreshGeneration;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != self->_scrollIdleMinimapRefreshGeneration || !self->_doc || self->_liveZooming) return;
        [self updateMinimap];
        [self spdf_queueViewportPageRendersNow]; // settled: no more queueing behind the one-wide queue
        // Warm the zoom-seed caches once scrolling has settled (not per page
        // crossing) so a subsequent zoom is still instant without stuttering the
        // scroll.
        [self enqueueZoomSeedCachesForGeneration:self->_renderGeneration
                                   preferredPage:self->_pageIndex
                                includeWholeBase:NO];
      });
    });
}

// Minimap refresh for active scrolling: moves the viewport indicator over the
// cached content strip instead of rebuilding the whole strip per update.
// Per-scroll-event update of only the minimap viewport indicator. The strip
// geometry (page rects, thumbnails, document height) changes only on
// layout/zoom, so refreshing just the visible rect on every scroll event lets
// the indicator track the scroll at display rate — without rebuilding the
// page-rect array each frame. The fuller updateMinimapForScrolling still runs on
// the coalesced maintenance tick to keep the rest in sync.
- (void)updateMinimapViewportIndicator {
    if (!_minimapView) return;
    _minimapView.liveViewportOnly = YES;
    _minimapView.currentPageIndex = _pageIndex;
    _minimapView.documentVisibleRect = [self continuousDocumentVisibleRectForMinimap];
    [_minimapView setNeedsDisplay:YES];
}

- (void)updateMinimapForScrolling {
    if (!_minimapView) return;
    _minimapView.liveViewportOnly = YES;
    _minimapView.currentPageIndex = _pageIndex;
    _minimapView.documentPageRects = [self continuousDocumentPageRectsForMinimap];
    _minimapView.documentVisibleRect = [self continuousDocumentVisibleRectForMinimap];
    _minimapView.documentWidth = [self continuousDocumentWidthForMinimap];
    _minimapView.documentHeight = MAX(1.0, [self continuousDocumentHeightForMinimap]);
    _minimapView.documentScale = MAX(0.01, _zoom);
    [_minimapView setNeedsDisplay:YES];
}

- (NSInteger)documentViewCurrentPageIndex {
    return _pageIndex;
}

- (BOOL)documentArrowKeyDown:(NSEvent*)event {
    if ([self firstResponderIsEditingText]) return NO;
    if ([self isMarkdownActive]) return [self markdownArrowKeyDown:event];
    if (!_doc) return NO;
    if (_presentationMode && event.keyCode == 53) {
        [self leavePresentationModeAndExitFullScreen:YES sender:nil];
        return YES;
    }
    if (event.keyCode == 53) return [self documentEscapeKeyDown:event];
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;

    BOOL space = event.keyCode == 49;
    BOOL left = event.keyCode == 123;
    BOOL right = event.keyCode == 124;
    BOOL down = event.keyCode == 125;
    BOOL up = event.keyCode == 126;
    BOOL home = event.keyCode == 115;
    BOOL end = event.keyCode == 119;
    BOOL pageUp = event.keyCode == 116;
    BOOL pageDown = event.keyCode == 121;
    BOOL returnKey = event.keyCode == 36 || event.keyCode == 76;
    BOOL deleteKey = event.keyCode == 51;
    BOOL shift = (flags & NSEventModifierFlagShift) != 0;
    BOOL anyArrow = left || right || up || down;
    BOOL cmdOrCtrl = (flags & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) != 0;
    BOOL option = (flags & NSEventModifierFlagOption) != 0;

    // Cmd/Ctrl + Up/Down pages through the document (preserving zoom + relative
    // position); Cmd/Ctrl + Left/Right switches tabs. Cancel any in-flight smooth
    // scroll first so the motions never fight. (These mirror the Go To menu key
    // equivalents, which fire first; this is the fallback when a menu item is
    // disabled.)
    if (cmdOrCtrl && !option && anyArrow) {
        [self stopKeyboardScrollAnimation];
        if (left)
            [self selectPreviousTab:nil];
        else if (right)
            [self selectNextTab:nil];
        else if (up)
            [self previousPage:nil];
        else
            [self nextPage:nil];
        return YES;
    }
    // Option + Left/Right forces a page change (previous/next), in either mode.
    // Option + Up/Down (first/last page) falls through to the Go To menu equivalents.
    if (option && !cmdOrCtrl && (left || right)) {
        [self stopKeyboardScrollAnimation];
        if (left)
            [self previousPage:nil];
        else
            [self nextPage:nil];
        return YES;
    }
    // Any other Cmd/Ctrl/Option combination falls through to the system default
    // (Option+Up/Down reach firstPage:/lastPage: via the Go To menu equivalents).
    if (flags & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption)) {
        return NO;
    }

    if (_presentationMode && home) {
        [self firstPage:nil];
        return YES;
    }
    if (_presentationMode && end) {
        [self lastPage:nil];
        return YES;
    }
    if (_presentationMode && (space || returnKey)) {
        [self nextPage:nil];
        return YES;
    }
    if (_presentationMode && deleteKey) {
        [self previousPage:nil];
        return YES;
    }
    if (!left && !right && !down && !up && !pageUp && !pageDown) return NO;

    if (!_presentationMode && shift && (left || right || up || down)) {
        [self goToAdjacentPagePreservingRelativePosition:(left || up) ? -1 : 1];
        return YES;
    }

    if (_presentationMode) {
        if (left || up || pageUp)
            [self previousPage:nil];
        else
            [self nextPage:nil];
        return YES;
    }

    if (pageUp || pageDown) {
        [self stopKeyboardScrollAnimation];
        return NO; // unchanged: fall through to default page-up/down handling
    }

    // Continuous mode: plain left/right is context dependent.
    //  - If the page content fits horizontally in the viewport (no horizontal
    //    scroll range), left/right navigate pages while preserving zoom +
    //    relative position, as before.
    //  - If zoomed in so content is wider than the viewport, left/right smooth
    //    scroll horizontally inside the page (same velocity ramp as up/down).
    if (left || right) {
        if ([self keyboardScrollHorizontallyNavigable]) {
            [self beginOrSustainKeyboardScrollInDirection:right ? 1.0 : -1.0
                                                     axis:1
                                                  keyCode:event.keyCode
                                                 isRepeat:event.isARepeat];
            return YES;
        }
        [self stopKeyboardScrollAnimation];
        [self goToAdjacentPagePreservingRelativePosition:left ? -1 : 1];
        return YES;
    }

    // Smooth up/down scroll. Up arrow scrolls toward the document top (negative
    // origin.y), down toward the bottom. A single tap kicks a small impulse then
    // settles; holding accelerates toward the cap with no mid-hold stop because a
    // keyUp monitor (not auto-repeat timing) decides when the hold ends.
    [self beginOrSustainKeyboardScrollInDirection:up ? -1.0 : 1.0
                                             axis:0
                                          keyCode:event.keyCode
                                         isRepeat:event.isARepeat];
    return YES;
}

// Horizontal navigability for the left/right keys: true only when the CURRENT
// page's displayed width exceeds the viewport. Using the whole document-view
// width was wrong — in a document that contains one very wide page (e.g. a
// schematic), the document bounds are wider than the viewport for EVERY page,
// so left/right would horizontal-scroll into empty margins instead of changing
// pages. Keying off the current page makes left/right behave consistently: they
// change pages whenever the page in view fits, and scroll horizontally only when
// that page itself is zoomed wider than the viewport.
- (BOOL)keyboardScrollHorizontallyNavigable {
    if (!_pageScrollView || !_pageView || _renderedPages.count == 0) return NO;
    NSClipView* clipView = _pageScrollView.contentView;
    NSInteger pageIndex = MAX(0, MIN(_pageIndex, (NSInteger)_renderedPages.count - 1));
    NSRect pageRect = [_pageView rectForPageAtIndex:pageIndex];
    if (NSIsEmptyRect(pageRect)) return NO;
    return NSWidth(pageRect) - NSWidth(clipView.bounds) > 0.5;
}

// Tunables for smooth keyboard scrolling. Cap is a comfortable max; the ramp
// eases velocity toward target each tick so a hold accelerates smoothly to the
// cap. Hold is driven by real key release (a keyUp monitor sets _keyScrollKeyDown
// false), so there is no mid-hold stall from auto-repeat gaps. The idle timeout
// is only a safety net: if a keyUp is ever missed, an event silence this long
// treats the key as released. A single tap kicks a minimum impulse so even an
// immediate release produces a small finite move comparable to the old discrete
// hop (~54pt), then decelerates to a stop.
static const CGFloat kKeyScrollMaxVelocity = 2200.0;     // pt/s cap
static const CGFloat kKeyScrollAccelEase = 0.115;        // per-tick ease toward target (~60fps)
static const CGFloat kKeyScrollDecelEase = 0.30;         // per-tick ease toward 0 on release
static const CGFloat kKeyScrollMinVelocity = 30.0;       // pt/s; below this when decaying, stop
static const CGFloat kKeyScrollTapImpulse = 950.0;       // pt/s kick on a fresh press (tap distance)
static const NSTimeInterval kKeyScrollIdleTimeout = 1.0; // s of event silence => assume keyUp missed
static const NSTimeInterval kKeyScrollTickInterval = 1.0 / 60.0;

// Scroll extent along the active axis (height for vertical, width for horizontal).
- (CGFloat)keyScrollMaxOffsetForAxis:(NSInteger)axis clip:(NSClipView*)clipView {
    if ([self isMarkdownActive]) {
        NSRect visible = self.activeMarkdownSession.documentVisibleRect;
        NSSize canvas = self.activeMarkdownSession.documentCanvasSize;
        return axis == 1 ? MAX(0.0, canvas.width - NSWidth(visible)) : MAX(0.0, canvas.height - NSHeight(visible));
    }
    if (axis == 1) return MAX(0.0, NSWidth(_pageView.bounds) - NSWidth(clipView.bounds));
    return MAX(0.0, NSHeight(_pageView.bounds) - NSHeight(clipView.bounds));
}

- (void)beginOrSustainKeyboardScrollInDirection:(CGFloat)direction
                                           axis:(NSInteger)axis
                                        keyCode:(unsigned short)keyCode
                                       isRepeat:(BOOL)isRepeat {
    BOOL markdown = [self isMarkdownActive];
    if ((!markdown && (!_doc || !_pageScrollView)) || (markdown && !self.activeMarkdownSession)) return;
    // No scroll range on this axis: behave like before (do nothing).
    NSClipView* clipView = markdown ? nil : _pageScrollView.contentView;
    if ([self keyScrollMaxOffsetForAxis:axis clip:clipView] <= 0.5) {
        [self stopKeyboardScrollAnimation];
        return;
    }

    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    _keyScrollLastEventTime = now;

    BOOL axisChanged = (axis != _keyScrollAxis);
    BOOL reversed = (direction != _keyScrollDirection);
    if ((axisChanged || reversed) && _keyScrollDirection != 0.0) {
        // Direction or axis changed mid-scroll: drop momentum so the switch is crisp.
        _keyScrollVelocity = 0.0;
    }
    _keyScrollAxis = axis;
    _keyScrollDirection = direction;

    // Mark the key held; its keyUp (via the monitor) clears this. Auto-repeats are
    // only a keep-alive: they refresh the event time above but otherwise do not
    // affect the ramp, so acceleration builds continuously for the whole hold.
    _keyScrollKeyDown = YES;
    _keyScrollKeyCode = keyCode;

    // Fresh press (not an OS auto-repeat): kick a minimum impulse immediately so
    // that even a tap released before the first timer tick produces a small finite
    // move comparable to the old discrete hop. Repeats must not re-kick or they
    // would cap the velocity each repeat and stall acceleration.
    if (!isRepeat && fabs(_keyScrollVelocity) < kKeyScrollTapImpulse) {
        _keyScrollVelocity = direction * kKeyScrollTapImpulse;
    }

    if (!_keyScrollTimer) {
        _keyScrollLastTickTime = now;
        _keyScrollTimer = [NSTimer scheduledTimerWithTimeInterval:kKeyScrollTickInterval
                                                           target:self
                                                         selector:@selector(stepKeyboardScroll:)
                                                         userInfo:nil
                                                          repeats:YES];
    }
    [self installKeyScrollKeyUpMonitor];
}

- (void)stepKeyboardScroll:(NSTimer*)timer {
    (void)timer;
    BOOL markdown = [self isMarkdownActive];
    if ((!markdown && (!_doc || !_pageScrollView)) || (markdown && !self.activeMarkdownSession)) {
        [self stopKeyboardScrollAnimation];
        return;
    }

    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    NSTimeInterval dt = now - _keyScrollLastTickTime;
    if (dt <= 0.0 || dt > 0.25) dt = kKeyScrollTickInterval; // clamp stalls
    _keyScrollLastTickTime = now;

    // Held = the key is physically down (per keyDown/keyUp), with a safety net:
    // if a keyUp was somehow missed, a long event silence forces release.
    BOOL held =
        _keyScrollKeyDown && _keyScrollDirection != 0.0 && (now - _keyScrollLastEventTime) <= kKeyScrollIdleTimeout;

    CGFloat target = held ? _keyScrollDirection * kKeyScrollMaxVelocity : 0.0;
    CGFloat ease = held ? kKeyScrollAccelEase : kKeyScrollDecelEase;
    _keyScrollVelocity += (target - _keyScrollVelocity) * ease;

    // Settle: not held and effectively stopped.
    if (!held && fabs(_keyScrollVelocity) < kKeyScrollMinVelocity) {
        _keyScrollVelocity = 0.0;
        [self stopKeyboardScrollAnimation];
        [self rememberActiveTabState];
        return;
    }

    NSClipView* clipView = markdown ? nil : _pageScrollView.contentView;
    NSInteger axis = _keyScrollAxis;
    CGFloat maxOffset = [self keyScrollMaxOffsetForAxis:axis clip:clipView];
    NSPoint origin = markdown ? self.activeMarkdownSession.documentVisibleRect.origin : clipView.bounds.origin;
    CGFloat before = (axis == 1) ? origin.x : origin.y;
    CGFloat moved = before + _keyScrollVelocity * dt;
    moved = spdf_clamp_cg(moved, 0.0, maxOffset);
    if (axis == 1)
        origin.x = moved;
    else
        origin.y = moved;
    if (markdown) {
        NSPoint current = self.activeMarkdownSession.documentVisibleRect.origin;
        [self.activeMarkdownSession scrollByDocumentDeltaX:origin.x - current.x deltaY:origin.y - current.y];
    } else {
        [self scrollDocumentClipViewToOrigin:origin notify:YES];
    }

    // Hit an edge with no movement: stop (kill residual velocity at the bounds).
    NSPoint afterOrigin = markdown ? self.activeMarkdownSession.documentVisibleRect.origin : clipView.bounds.origin;
    CGFloat after = (axis == 1) ? afterOrigin.x : afterOrigin.y;
    if (fabs(after - before) < 0.01 &&
        ((_keyScrollVelocity < 0 && before <= 0.01) || (_keyScrollVelocity > 0 && before >= maxOffset - 0.01))) {
        _keyScrollVelocity = 0.0;
        [self stopKeyboardScrollAnimation];
        [self rememberActiveTabState];
    }
}

// Local keyUp monitor: active only while a keyboard scroll runs. When the held
// arrow's keyUp arrives, clear _keyScrollKeyDown so the tick decelerates to a
// stop. Releasing one arrow while a different one is now held (fast re-press to
// the other direction) must not cancel the new hold, so we only react to the
// keyCode we are currently tracking.
- (void)installKeyScrollKeyUpMonitor {
    if (_keyScrollKeyUpMonitor) return;
    __weak ShenzhenMacDelegate* weakSelf = self;
    _keyScrollKeyUpMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyUp
                                                                   handler:^NSEvent*(NSEvent* ev) {
                                                                     ShenzhenMacDelegate* strongSelf = weakSelf;
                                                                     if (!strongSelf) return ev;
                                                                     if (ev.keyCode == strongSelf->_keyScrollKeyCode &&
                                                                         strongSelf->_keyScrollKeyDown) {
                                                                         strongSelf->_keyScrollKeyDown = NO;
                                                                     }
                                                                     return ev;
                                                                   }];
}

- (void)removeKeyScrollKeyUpMonitor {
    if (!_keyScrollKeyUpMonitor) return;
    [NSEvent removeMonitor:_keyScrollKeyUpMonitor];
    _keyScrollKeyUpMonitor = nil;
}

- (void)stopKeyboardScrollAnimation {
    if (_keyScrollTimer) {
        [_keyScrollTimer invalidate];
        _keyScrollTimer = nil;
    }
    [self removeKeyScrollKeyUpMonitor];
    _keyScrollVelocity = 0.0;
    _keyScrollDirection = 0.0;
    _keyScrollAxis = 0;
    _keyScrollKeyDown = NO;
    _keyScrollKeyCode = 0;
}

- (BOOL)scrollViewShouldTurnWheelIntoPageChange:(NSEvent*)event {
    if ([self isMarkdownActive]) return NO;
    if (!_doc) return NO;
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if (flags & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption)) return NO;
    return _presentationMode;
}

- (BOOL)isAutoFitMode:(SPDFFitMode)fitMode {
    return fitMode == SPDFFitModeWidth || fitMode == SPDFFitModeHeight || fitMode == SPDFFitModePage;
}

- (void)relayoutDocumentForViewportChange {
    if ([self isMarkdownActive]) {
        [self relayoutActiveMarkdownForViewportChange];
        return;
    }
    if (!_doc) {
        [self resizeDocumentView];
        return;
    }
    if (!_suppressViewportRerender && [self isAutoFitMode:_fitMode] && _renderedPages.count > 0) {
        NSPoint relativePosition = [self relativeScrollPositionForCurrentPage];
        [self renderDocumentAndScrollToPage:_pageIndex alignTop:NO];
        [self scrollToPage:_pageIndex preservingRelativePosition:relativePosition];
        return;
    }
    [self resizeDocumentView];
    [self renderVisiblePageCropsForCurrentViewportIfNeeded];
    [_pageView setNeedsDisplay:YES];
}

- (NSMenuItem*)fitModePopupItemForMode:(SPDFFitMode)mode {
    for (NSMenuItem* item in _fitModePopup.itemArray)
        if (item.tag == mode) return item;
    return nil;
}

- (void)syncToolbarState {
    SPDFScopedProfileLog spdfScopedProfile("syncToolbarState", 4.0);
    CGFloat customZoom =
        _fitMode == SPDFFitModeCustom ? _zoom : (_rememberedCustomZoom > 0 ? _rememberedCustomZoom : _zoom);
    NSString* zoomTitle = [NSString stringWithFormat:@"%.0f%%", customZoom * 100.0];
    BOOL showCustomZoom = fabs(customZoom - 1.0) > 0.0049;
    NSMenuItem* actualItem = [self fitModePopupItemForMode:SPDFFitModeActual];
    if (actualItem) actualItem.title = @"100%";
    NSMenuItem* customItem = [self fitModePopupItemForMode:SPDFFitModeCustom];
    if (showCustomZoom) {
        if (!customItem) {
            NSInteger actualIndex = actualItem ? [_fitModePopup indexOfItem:actualItem] : -1;
            NSInteger insertIndex = actualIndex >= 0 ? actualIndex + 1 : 0;
            [_fitModePopup insertItemWithTitle:zoomTitle atIndex:insertIndex];
            customItem = [_fitModePopup itemAtIndex:insertIndex];
            customItem.tag = SPDFFitModeCustom;
        }
        customItem.title = zoomTitle;
    } else if (customItem) {
        NSInteger customIndex = [_fitModePopup indexOfItem:customItem];
        if (customIndex >= 0) [_fitModePopup removeItemAtIndex:customIndex];
    }
    NSMenuItem* selectedFitItem = [self fitModePopupItemForMode:_fitMode];
    if (!selectedFitItem && _fitMode == SPDFFitModeCustom) selectedFitItem = actualItem;
    spdf_fit_popup_select_and_size(_fitModePopup, selectedFitItem);
    [self styleToolbarPanelButton:_sidebarToggleButton
                            title:@"Side Panel"
                           active:_sidebarVisible
                          tooltip:_sidebarVisible ? @"Hide the side panel" : @"Show the side panel"];
    [self styleToolbarPanelButton:_minimapToggleButton
                            title:@"Map"
                           active:_minimapVisible
                          tooltip:_minimapVisible ? @"Hide the minimap" : @"Show the minimap"];
    _tabStrip.emptyGroups = [self emptyTabGroups]; _tabStrip.tabs = _tabs;
    _tabStrip.selectedIndex = _selectedTabIndex;
    [self updateToolbarOverflow];
}

// Cheap subset of updateControls run synchronously on a page crossing so the
// page number / nav buttons stay responsive; the full updateControls (title,
// toolbar, status, find controls) is deferred to the page-change follow-up.
- (void)updatePageIndicatorControls {
    NSInteger pageCount = spdf_page_count(_doc);
    BOOL hasDoc = _doc != NULL;
    [_pageSegments setEnabled:hasDoc && _pageIndex > 0 forSegment:0];
    [_pageSegments setEnabled:hasDoc && _pageIndex + 1 < pageCount forSegment:1];
    _pageField.stringValue = hasDoc ? [NSString stringWithFormat:@"%ld", (long)_pageIndex + 1] : @"";
    [self syncWorkspaceChrome];
}

// Coalesced off-frame follow-up for a page change. The instant a scroll crosses
// a page boundary we only update the cheap page indicator; the heavier work
// (zoom-seed caches with their O(n) byte accounting, ±2 neighbour renders, full
// control refresh, sidebar selection) runs here ~1 frame later, and only once
// per burst no matter how many boundaries a fast scroll crosses.
- (void)schedulePageChangeFollowUp {
    if (_pageChangeFollowUpScheduled) return;
    _pageChangeFollowUpScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 / 60.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      self->_pageChangeFollowUpScheduled = NO;
      if (!self->_doc || self->_renderedPages.count == 0 || self->_liveZooming) return;
      NSInteger page = self->_pageIndex;
      // Note: the zoom-seed (high-quality + base) caches are NOT warmed here — they
      // are speculative pre-rendering for zoom, their enqueue does O(total-pages)
      // byte-cost sums, and the HQ renders contend for CPU. Warming them on every
      // page crossing was the residual page-switch stutter; they're deferred to
      // scroll-idle (scheduleScrollViewportMaintenance's idle tail) instead.
      [self enqueueCurrentPageNeighborhoodRendersForGeneration:self->_renderGeneration
                                                 preferredPage:page
                                             forceHighPriority:NO];
      [self updateControls];
      [self selectCurrentSidebarRow];
    });
}

- (void)updateControls {
    SPDFScopedProfileLog spdfScopedProfile("updateControls", 4.0);
    if ([self isMarkdownActive]) {
        [self updateControlsForActiveMarkdown];
        return;
    }
    NSInteger pageCount = spdf_page_count(_doc);
    BOOL hasDoc = _doc != NULL;
    [self updatePageIndicatorControls];
    _sidebarToggleButton.enabled = _sidebarModeControl != nil;
    _pageField.enabled = hasDoc;
    [_zoomSegments setEnabled:hasDoc forSegment:0];
    [_zoomSegments setEnabled:hasDoc forSegment:1];
    _fitModePopup.enabled = hasDoc;
    _searchField.enabled = hasDoc;
    _findRegexCheckbox.enabled = hasDoc;
    _ocrButton.enabled = hasDoc && SPDFOCRPathSupported(_path);
    [self updateTranslateCommandEnablement];
    _minimapToggleButton.enabled = hasDoc;
    [self updateFindControls];
    _pageCountLabel.stringValue = [NSString stringWithFormat:@"/ %ld", (long)pageCount];
    [self syncToolbarState]; // ends with this sync's updateToolbarOverflow pass

    if (hasDoc) {
        NSString* displayName = _path.length ? [self displayNameForPathConsideringOpenTabs:_path]
                                             : [NSString stringWithUTF8String:spdf_title(_doc)];
        _window.title = [NSString stringWithFormat:@"%@ - Shenzhen PDF", displayName];
        _statusLabel.stringValue = [NSString
            stringWithFormat:@"Page %ld of %ld    Zoom %.0f%%", (long)_pageIndex + 1, (long)pageCount, _zoom * 100.0];
    }
}

- (void)selectCurrentSidebarRow {
    SPDFScopedProfileLog spdfScopedProfile("selectCurrentSidebarRow", 4.0);
    if (![self hasActiveDocument] || _updatingSelection) return;
    _updatingSelection = YES;
    NSInteger match = -1;
    if (_sidebarModeControl.spdf_selectedSidebarMode == SPDFSidebarModeSearch && _findMatchIndex >= 0) {
        for (NSInteger i = 0; i < _sidebarItems.count; ++i) {
            NSDictionary* item = _sidebarItems[(NSUInteger)i];
            if (![item[@"kind"] isEqualToString:@"findResult"]) continue;
            if ([item[@"findIndex"] integerValue] == _findMatchIndex) {
                match = i;
                break;
            }
        }
    } else if ([self isMarkdownActive]) {
        NSDictionary* current = [self currentMarkdownChapterItem];
        NSRange currentRange = [current[@"range"] rangeValue];
        for (NSInteger i = 0; current && i < _sidebarItems.count; ++i) {
            NSDictionary* item = _sidebarItems[(NSUInteger)i];
            if ([item[@"kind"] isEqualToString:@"chapter"] &&
                NSEqualRanges([item[@"range"] rangeValue], currentRange)) {
                match = i;
                break;
            }
        }
    } else {
        for (NSInteger i = 0; i < _sidebarItems.count; ++i) {
            NSInteger page = [_sidebarItems[(NSUInteger)i][@"page"] integerValue];
            if (page == _pageIndex) {
                match = i;
                break;
            }
        }
    }
    if (match >= 0) {
        [_sidebarTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)match] byExtendingSelection:NO];
        [_sidebarTable scrollRowToVisible:match];
    } else {
        [_sidebarTable deselectAll:nil];
    }
    _updatingSelection = NO;
}

- (void)clearFindResults {
    [self setFindFailureMessage:nil];
    [_findQueue cancelAllOperations];
    [self cancelProgressiveFind];
    _findGeneration++;
    [_findFlashTimer invalidate];
    _findFlashTimer = nil;
    _pageView.activeFindPageIndex = -1;
    _pageView.activeFindAlpha = 0.0;
    [_findHighlights removeAllObjects];
    [_findMatches removeAllObjects];
    _findMatchIndex = -1;
    _findSearchInProgress = NO;
    [self applySearchHighlightsToCurrentPage];
    [self updateFindControls];
    [self rebuildSidebar];
}

- (NSArray<NSValue*>*)highlightRectsForPage:(NSInteger)pageIndex {
    if (!_doc || _searchField.stringValue.length == 0) return @[];
    char err[1024];
    spdf_rect rects[256];
    int count = spdf_search_page_rects_options(_doc, (int)pageIndex, _searchField.stringValue.UTF8String,
                                               _findRegexCheckbox.state == NSControlStateValueOn, _findRegexMultiline,
                                               rects, 256, err, sizeof(err));
    if (count <= 0) return @[];

    NSMutableArray<NSValue*>* values = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
    for (int i = 0; i < count; ++i) {
        NSRect r = NSMakeRect(rects[i].x0, rects[i].y0, rects[i].x1 - rects[i].x0, rects[i].y1 - rects[i].y0);
        [values addObject:[NSValue valueWithRect:r]];
    }
    return values;
}

- (void)applySearchHighlightsToCurrentPage {
    SPDFScopedProfileLog spdfScopedProfile("applySearchHighlights", 4.0);
    for (SPDFRenderedPage* page in _renderedPages) page.highlights = _findHighlights[@(page.pageIndex)] ?: @[];
    _pageView.pages = _renderedPages;
    [_pageView setNeedsDisplay:YES];
    [self updateMinimap];
    [self invalidateFindMarkers];
}

// Index into _findMatches of the match closest to the current viewport:
// nearest by page distance from the visible page range, tie-broken by vertical
// distance from the viewport center (see spdf_nearest_find_match_index).
// Returns -1 when it cannot be computed (no matches / no layout yet), in which
// case the caller falls back to the first match.
- (NSInteger)nearestFindMatchIndexToCurrentViewport {
    NSInteger count = (NSInteger)_findMatches.count;
    if (!_doc || count == 0 || !_pageView || _renderedPages.count == 0) return -1;
    NSRect visibleRect = _pageScrollView.contentView.bounds;
    if (NSIsEmptyRect(visibleRect)) return -1;

    // Visible page range: pages are laid out top-to-bottom in increasing Y, so
    // scan with an early break (same invariant as pageIndexForVisibleRect:).
    NSInteger firstVisible = -1;
    NSInteger lastVisible = -1;
    for (NSInteger i = 0; i < (NSInteger)_renderedPages.count; ++i) {
        NSRect pageRect = [_pageView rectForPageAtIndex:i];
        if (NSIsEmptyRect(pageRect)) continue;
        if (NSMinY(pageRect) > NSMaxY(visibleRect)) break;
        if (NSMaxY(pageRect) < NSMinY(visibleRect)) continue;
        if (firstVisible < 0) firstVisible = i;
        lastVisible = i;
    }
    if (firstVisible < 0) {
        firstVisible = _pageIndex;
        lastVisible = _pageIndex;
    }

    NSInteger* pages = (NSInteger*)malloc(sizeof(NSInteger) * (size_t)count);
    CGFloat* centers = (CGFloat*)malloc(sizeof(CGFloat) * (size_t)count);
    if (!pages || !centers) {
        free(pages);
        free(centers);
        return -1;
    }
    for (NSInteger i = 0; i < count; ++i) {
        NSDictionary* match = _findMatches[(NSUInteger)i];
        NSInteger page = [match[@"page"] integerValue];
        NSRect matchRect = [match[@"rect"] rectValue];
        NSRect pageRect = [_pageView rectForPageAtIndex:page];
        pages[i] = page;
        // Same page-to-view mapping as scrollToPageRect:pageIndex:.
        centers[i] = NSMinY(pageRect) + NSMidY(matchRect) * _zoom;
    }
    NSInteger nearest =
        spdf_nearest_find_match_index(pages, centers, count, firstVisible, lastVisible, NSMidY(visibleRect));
    free(pages);
    free(centers);
    return nearest;
}

- (void)startFindForCurrentQuery {
    [self startFindForCurrentQueryResetSavedIndex:YES revealMatch:YES];
}


- (void)startFindForCurrentQueryResetSavedIndex:(BOOL)resetSavedIndex revealMatch:(BOOL)revealMatch {
    [self startFindForCurrentQueryResetSavedIndex:resetSavedIndex revealMatch:revealMatch publicationAllowed:nil];
}

- (void)scrollToFindMatch:(NSDictionary*)match {
    if (!_doc || !match) return;
    NSInteger page = [match[@"page"] integerValue];
    NSRect matchRect = [match[@"rect"] rectValue];
    [self scrollToPageRect:matchRect pageIndex:page];
}

- (void)scrollToPageRect:(NSRect)targetRect pageIndex:(NSInteger)page {
    if (!_doc) return;
    page = MAX(0, MIN(page, spdf_page_count(_doc) - 1));
    NSRect pageRect = [_pageView rectForPageAtIndex:page];
    NSRect matchRect = targetRect;
    if (NSIsEmptyRect(pageRect) || NSIsEmptyRect(matchRect)) {
        [self scrollToPage:page alignTop:YES];
        return;
    }

    NSRect viewRect =
        NSMakeRect(pageRect.origin.x + matchRect.origin.x * _zoom, pageRect.origin.y + matchRect.origin.y * _zoom,
                   matchRect.size.width * _zoom, matchRect.size.height * _zoom);
    NSClipView* clipView = _pageScrollView.contentView;
    NSRect visibleRect = clipView.bounds;
    NSPoint origin =
        NSMakePoint(NSMidX(viewRect) - NSWidth(visibleRect) * 0.5, NSMidY(viewRect) - NSHeight(visibleRect) * 0.5);
    BOOL fullPageHeightFits = _presentationMode && NSHeight(pageRect) <= NSHeight(visibleRect) + 0.5;
    if (fullPageHeightFits) {
        BOOL pageAlreadyVisible =
            NSMinY(pageRect) >= NSMinY(visibleRect) - 0.5 && NSMaxY(pageRect) <= NSMaxY(visibleRect) + 0.5;
        origin.y = pageAlreadyVisible ? NSMinY(visibleRect) : NSMidY(pageRect) - NSHeight(visibleRect) * 0.5;
        BOOL matchAlreadyVisible =
            NSMinX(viewRect) >= NSMinX(visibleRect) - 0.5 && NSMaxX(viewRect) <= NSMaxX(visibleRect) + 0.5;
        if (matchAlreadyVisible) origin.x = NSMinX(visibleRect);
    }
    [self scrollDocumentClipViewToOrigin:origin notify:NO];
    [self renderVisiblePageCropsForCurrentViewportIfNeeded];
    [_pageView setNeedsDisplay:YES];
    [self updateMinimap];
}

- (void)stepFindFlash:(NSTimer*)timer {
    (void)timer;
    NSTimeInterval elapsed = NSDate.timeIntervalSinceReferenceDate - _findFlashStartTime;
    CGFloat alpha = 0.0;
    if (elapsed < 0.10)
        alpha = (CGFloat)(elapsed / 0.10);
    else if (elapsed < 0.18)
        alpha = (CGFloat)(1.0 - (elapsed - 0.10) / 0.08);
    else if (elapsed < 0.26)
        alpha = (CGFloat)((elapsed - 0.18) / 0.08);
    else if (elapsed < 1.26)
        alpha = 1.0;
    else if (elapsed < 1.51)
        alpha = (CGFloat)(1.0 - (elapsed - 1.26) / 0.25);
    else {
        [_findFlashTimer invalidate];
        _findFlashTimer = nil;
        _pageView.activeFindPageIndex = -1;
        _pageView.activeFindAlpha = 0.0;
        [_pageView setNeedsDisplay:YES];
        return;
    }

    _pageView.activeFindAlpha = spdf_clamp_cg(alpha, 0.0, 1.0);
    [_pageView setNeedsDisplayInRect:[_pageView rectForPageAtIndex:_pageView.activeFindPageIndex]];
}

- (void)flashPageRect:(NSRect)targetRect pageIndex:(NSInteger)pageIndex {
    if (!_doc || NSIsEmptyRect(targetRect)) return;
    [_findFlashTimer invalidate];
    _pageView.activeFindPageIndex = MAX(0, MIN(pageIndex, spdf_page_count(_doc) - 1));
    _pageView.activeFindRect = targetRect;
    _pageView.activeFindAlpha = 0.0;
    _findFlashStartTime = NSDate.timeIntervalSinceReferenceDate;
    _findFlashTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60.0
                                                       target:self
                                                     selector:@selector(stepFindFlash:)
                                                     userInfo:nil
                                                      repeats:YES];
    [self stepFindFlash:_findFlashTimer];
}

- (void)flashFindMatch:(NSDictionary*)match {
    if (!match) return;
    [self flashPageRect:[match[@"rect"] rectValue] pageIndex:[match[@"page"] integerValue]];
}

- (void)jumpToFindMatchAtIndex:(NSInteger)index {
    if (!_doc || index < 0 || index >= (NSInteger)_findMatches.count) return;
    _findMatchIndex = index;
    NSDictionary* match = _findMatches[(NSUInteger)index];
    NSInteger page = [match[@"page"] integerValue];
    _pageIndex = MAX(0, MIN(page, spdf_page_count(_doc) - 1));
    _pageView.currentPageIndex = _pageIndex;
    [self renderPageIfNeededAtIndex:_pageIndex];
    [self applySearchHighlightsToCurrentPage];
    [self resizeDocumentView];
    [self scrollToFindMatch:match];
    [self flashFindMatch:match];
    [self updateControls];
    [self selectCurrentSidebarRow];
    [self updateFindControls];
    [self rememberActiveTabFindState];
    _statusLabel.stringValue =
        [NSString stringWithFormat:@"Match %ld of %ld", (long)_findMatchIndex + 1, (long)_findMatches.count];
}

- (BOOL)documentViewSelectionChangedOnPage:(NSInteger)pageIndex from:(NSPoint)start to:(NSPoint)end {
    return [self documentViewSelectionChangedOnPage:pageIndex
                                               from:start
                                                 to:end
                                        granularity:SPDFMacSelectionGranularityRange];
}

- (BOOL)documentViewSelectionChangedOnPage:(NSInteger)pageIndex
                                      from:(NSPoint)start
                                        to:(NSPoint)end
                               granularity:(SPDFMacSelectionGranularity)granularity {
    if (!_doc || pageIndex < 0 || pageIndex >= (NSInteger)_renderedPages.count) return NO;
    SPDFMacSelectionResult* selection = spdf_mac_select_text(_doc, pageIndex, granularity, start, end);
    for (SPDFRenderedPage* page in _renderedPages) page.selectionRects = @[];
    if (selection.hasSelection) {
        _renderedPages[(NSUInteger)pageIndex].selectionRects = selection.rects;
        _selectionPageIndex = pageIndex;
        _selectedText = selection.text;
    } else {
        _selectionPageIndex = -1;
        _selectedText = nil;
    }
    _pageView.pages = _renderedPages;
    [_pageView setNeedsDisplay:YES];
    [self updateMinimap];
    return selection.hasSelection;
}

- (void)documentViewDidBeginPan {
    [self stopKeyboardScrollAnimation];
    if (!_liveZooming) [self cancelPendingLiveZoomCompletion];
    _viewportMovementGeneration++;
    _documentViewPanActive = YES;
    _documentViewPanCropInFlight = NO;
    _documentViewPanMaintenanceScheduled = NO;
    _documentViewPanCropGeneration++;
    _lastDocumentPanLiveCropRenderTime = 0.0;
}

- (void)documentViewDidFinishPanMotion {
    if (!_documentViewPanActive) return;
    _documentViewPanActive = NO;
    _documentViewPanCropGeneration++;
    _documentViewPanCropInFlight = NO;
    _documentViewPanMaintenanceScheduled = NO;
    _lastDocumentPanLiveCropRenderTime = 0.0;
    if (_liveZooming) {
        [_zoomFinishTimer invalidate];
        _zoomFinishTimer = [NSTimer scheduledTimerWithTimeInterval:0.02
                                                            target:self
                                                          selector:@selector(finishLiveZoom:)
                                                          userInfo:@(_liveZoomSequence)
                                                           repeats:NO];
        [self setCurrentViewportNeedsDisplay];
    } else
        [self renderVisiblePageCropsForCurrentViewportIfNeeded];
    [_pageView setNeedsDisplay:YES];
    [self updateMinimap];
    [self evictDistantRenderedPageImages];
    if (!_suppressScrollCallbacks) [self rememberActiveTabState];
}

- (void)cancelDocumentTransientInteraction {
    [self stopKeyboardScrollAnimation];
    _viewportMovementGeneration++;
    _documentViewPanActive = NO;
    _documentViewPanCropGeneration++;
    _documentViewPanCropInFlight = NO;
    _documentViewPanMaintenanceScheduled = NO;
    _lastDocumentPanLiveCropRenderTime = 0.0;
    [_zoomFinishTimer invalidate];
    _zoomFinishTimer = nil;
    _liveZoomSequence++;
    _liveZooming = NO;
    _liveZoomAnchorValid = NO;
    _pageView.liveZooming = NO;
    [self clearLiveZoomSeeds];
    [self resumeBackgroundRenderQueuesAfterLiveZoomCancelingQueuedWork:YES];
    _liveZoomMinimapUpdateScheduled = NO;
    [_pageView cancelTransientInteraction];
}

- (void)copySelection:(id)sender {
    (void)sender;
    if ([self isMarkdownActive]) {
        // Image-aware copy: see the canvas (Copy) category for the contract.
        NSString* (^collapse)(NSString*) = nil;
        if (_collapseWhitespaceWhenCopyingText)
            collapse = ^NSString*(NSString* text) { return SPDFTextByCollapsingWhitespace(text); };
        if (![self.activeMarkdownSession copySelectionToPasteboard:NSPasteboard.generalPasteboard
                                                plainTextTransform:collapse])
            NSBeep();
        return;
    }
    if (_selectedText.length == 0) {
        NSBeep();
        return;
    }
    NSPasteboard* pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    NSString* text = _collapseWhitespaceWhenCopyingText ? SPDFTextByCollapsingWhitespace(_selectedText) : _selectedText;
    [pasteboard setString:text ?: @"" forType:NSPasteboardTypeString];
    _statusLabel.stringValue = @"Selected text copied.";
}

- (NSString*)trimmedSelectedTextForCommand {
    NSString* selected = [self isMarkdownActive] ? [self markdownSelectedText] : (_selectedText ?: @"");
    return [selected stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

- (NSString*)shortSelectedTextForMenuTitle {
    return SPDFMenuSelectionPreview([self isMarkdownActive] ? [self markdownSelectedText] : _selectedText);
}

- (void)searchSelectedTextInBrowser:(id)sender {
    (void)sender;
    NSString* query = SPDFTextByCollapsingWhitespace([self trimmedSelectedTextForCommand]);
    if (query.length == 0) {
        NSBeep();
        return;
    }

    if (SPDFPerformSystemTextSearchService(query)) {
        _statusLabel.stringValue = @"Opened selected text in browser search.";
        return;
    }

    NSString* error = nil;
    if (SPDFSearchWithSafariDefaultEngine(query, &error)) {
        _statusLabel.stringValue = @"Opened selected text in browser search.";
        return;
    }

    [self showError:@"Could not search the selected text"
             detail:error.length ? error : @"macOS did not accept a system text-search request."];
}

- (NSTextView*)translationTextViewEditable:(BOOL)editable {
    NSTextView* textView = [[NSTextView alloc] initWithFrame:NSZeroRect];
    textView.font = [NSFont systemFontOfSize:13.0];
    textView.editable = editable;
    textView.selectable = YES;
    textView.verticallyResizable = YES;
    textView.horizontallyResizable = NO;
    textView.textContainer.widthTracksTextView = YES;
    textView.autoresizingMask = NSViewWidthSizable;
    return textView;
}

- (NSScrollView*)scrollViewForTranslationTextView:(NSTextView**)textViewOut editable:(BOOL)editable {
    NSScrollView* scroll = [[NSScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = NO;
    scroll.borderType = NSBezelBorder;
    NSTextView* textView = [self translationTextViewEditable:editable];
    scroll.documentView = textView;
    if (textViewOut) *textViewOut = textView;
    return scroll;
}

- (void)buildSelectionTranslationPanelIfNeeded {
    if (_selectionTranslationPanel) return;

    _selectionTranslationPanel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 680, 540)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    _selectionTranslationPanel.title = @"Translate Selection";
    _selectionTranslationPanel.releasedWhenClosed = NO;

    NSView* content = [[NSView alloc] initWithFrame:_selectionTranslationPanel.contentView.bounds];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    _selectionTranslationPanel.contentView = content;

    NSTextField* fromLabel = [NSTextField labelWithString:@"From"];
    fromLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:fromLabel];
    _selectionTranslationSourcePopup = [[NSPopUpButton alloc] init];
    _selectionTranslationSourcePopup.translatesAutoresizingMaskIntoConstraints = NO;
    _selectionTranslationSourcePopup.target = self;
    _selectionTranslationSourcePopup.action = @selector(selectionTranslationLanguageChanged:);
    [content addSubview:_selectionTranslationSourcePopup];

    NSTextField* toLabel = [NSTextField labelWithString:@"To"];
    toLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:toLabel];
    _selectionTranslationTargetPopup = [[NSPopUpButton alloc] init];
    _selectionTranslationTargetPopup.translatesAutoresizingMaskIntoConstraints = NO;
    _selectionTranslationTargetPopup.target = self;
    _selectionTranslationTargetPopup.action = @selector(selectionTranslationLanguageChanged:);
    [content addSubview:_selectionTranslationTargetPopup];

    _selectionTranslationButton = [NSButton buttonWithTitle:@"Translate"
                                                     target:self
                                                     action:@selector(runSelectionTranslationFromPanel:)];
    _selectionTranslationButton.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:_selectionTranslationButton];

    NSTextField* inputLabel = [NSTextField labelWithString:@"Input"];
    inputLabel.translatesAutoresizingMaskIntoConstraints = NO;
    inputLabel.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightSemibold];
    [content addSubview:inputLabel];
    NSTextView* inputTextView = nil;
    NSScrollView* inputScroll = [self scrollViewForTranslationTextView:&inputTextView editable:YES];
    _selectionTranslationInputView = inputTextView;
    [content addSubview:inputScroll];

    NSTextField* outputLabel = [NSTextField labelWithString:@"Translation"];
    outputLabel.translatesAutoresizingMaskIntoConstraints = NO;
    outputLabel.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightSemibold];
    [content addSubview:outputLabel];
    NSTextView* outputTextView = nil;
    NSScrollView* outputScroll = [self scrollViewForTranslationTextView:&outputTextView editable:YES];
    _selectionTranslationOutputView = outputTextView;
    [content addSubview:outputScroll];

    _selectionTranslationStatusLabel = [NSTextField labelWithString:@""];
    _selectionTranslationStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _selectionTranslationStatusLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [content addSubview:_selectionTranslationStatusLabel];

    [NSLayoutConstraint activateConstraints:@[
        [fromLabel.topAnchor constraintEqualToAnchor:content.topAnchor constant:14],
        [fromLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [_selectionTranslationSourcePopup.centerYAnchor constraintEqualToAnchor:fromLabel.centerYAnchor],
        [_selectionTranslationSourcePopup.leadingAnchor constraintEqualToAnchor:fromLabel.trailingAnchor constant:8],
        [_selectionTranslationSourcePopup.widthAnchor constraintEqualToConstant:190],
        [toLabel.centerYAnchor constraintEqualToAnchor:fromLabel.centerYAnchor],
        [toLabel.leadingAnchor constraintEqualToAnchor:_selectionTranslationSourcePopup.trailingAnchor constant:16],
        [_selectionTranslationTargetPopup.centerYAnchor constraintEqualToAnchor:fromLabel.centerYAnchor],
        [_selectionTranslationTargetPopup.leadingAnchor constraintEqualToAnchor:toLabel.trailingAnchor constant:8],
        [_selectionTranslationTargetPopup.widthAnchor constraintEqualToConstant:190],
        [_selectionTranslationButton.centerYAnchor constraintEqualToAnchor:fromLabel.centerYAnchor],
        [_selectionTranslationButton.leadingAnchor
            constraintGreaterThanOrEqualToAnchor:_selectionTranslationTargetPopup.trailingAnchor
                                        constant:12],
        [_selectionTranslationButton.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [inputLabel.topAnchor constraintEqualToAnchor:fromLabel.bottomAnchor constant:16],
        [inputLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [inputLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [inputScroll.topAnchor constraintEqualToAnchor:inputLabel.bottomAnchor constant:6],
        [inputScroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [inputScroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [inputScroll.heightAnchor constraintGreaterThanOrEqualToConstant:150],
        [outputLabel.topAnchor constraintEqualToAnchor:inputScroll.bottomAnchor constant:12],
        [outputLabel.leadingAnchor constraintEqualToAnchor:inputLabel.leadingAnchor],
        [outputLabel.trailingAnchor constraintEqualToAnchor:inputLabel.trailingAnchor],
        [outputScroll.topAnchor constraintEqualToAnchor:outputLabel.bottomAnchor constant:6],
        [outputScroll.leadingAnchor constraintEqualToAnchor:inputScroll.leadingAnchor],
        [outputScroll.trailingAnchor constraintEqualToAnchor:inputScroll.trailingAnchor],
        [outputScroll.heightAnchor constraintEqualToAnchor:inputScroll.heightAnchor],
        [_selectionTranslationStatusLabel.topAnchor constraintEqualToAnchor:outputScroll.bottomAnchor constant:10],
        [_selectionTranslationStatusLabel.leadingAnchor constraintEqualToAnchor:inputScroll.leadingAnchor],
        [_selectionTranslationStatusLabel.trailingAnchor constraintEqualToAnchor:inputScroll.trailingAnchor],
        [_selectionTranslationStatusLabel.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-14]
    ]];
}

- (void)syncSelectionTranslationLanguagePopups {
    [self populateTranslationLanguagePopup:_selectionTranslationSourcePopup
                              selectedCode:_translationSourceLanguage ?: @"zh"];
    [self populateTranslationLanguagePopup:_selectionTranslationTargetPopup
                              selectedCode:_translationTargetLanguage ?: @"en"];
}

- (void)selectionTranslationLanguageChanged:(id)sender {
    (void)sender;
    _translationSourceLanguage = [self selectedTranslationLanguageCodeFromPopup:_selectionTranslationSourcePopup
                                                                       fallback:@"zh"];
    _translationTargetLanguage = [self selectedTranslationLanguageCodeFromPopup:_selectionTranslationTargetPopup
                                                                       fallback:@"en"];
    [self savePersistentState];
}

- (void)showSelectionTranslationPanel:(id)sender {
    (void)sender;
    NSString* selected = SPDFTextByCollapsingWhitespace([self trimmedSelectedTextForCommand]);
    if (selected.length == 0) {
        NSBeep();
        return;
    }

    [self buildSelectionTranslationPanelIfNeeded];
    [self syncSelectionTranslationLanguagePopups];
    _selectionTranslationInputView.string = selected;
    _selectionTranslationOutputView.string = @"";
    _selectionTranslationStatusLabel.stringValue = @"Preparing translation...";
    _selectionTranslationButton.enabled = !_translationRunning && !_translationInstallRunning;
    [_selectionTranslationPanel center];
    [_selectionTranslationPanel makeKeyAndOrderFront:nil];
    [_selectionTranslationPanel makeFirstResponder:_selectionTranslationInputView];
    [self runSelectionTranslationFromPanel:nil];
}

- (void)finishSelectionTranslationWithGeneration:(NSUInteger)generation
                                          output:(NSString*)output
                                           error:(NSString*)error {
    if (generation != _selectionTranslationGeneration) return;
    _translationRunning = NO;
    _translationCancelRequested = NO;
    _selectionTranslationButton.enabled = YES;
    [self updateTranslateCommandEnablement];
    if (error.length) {
        _selectionTranslationStatusLabel.stringValue = error;
        _statusLabel.stringValue = @"Selection translation failed.";
        return;
    }
    _selectionTranslationOutputView.string = output ?: @"";
    _selectionTranslationStatusLabel.stringValue = @"Translation complete.";
    _statusLabel.stringValue = @"Selection translated.";
}

- (void)runSelectionTranslationWithText:(NSString*)text
                         sourceLanguage:(NSString*)sourceLanguage
                         targetLanguage:(NSString*)targetLanguage
                       offeredInstaller:(BOOL)offeredInstaller {
    NSUInteger generation = ++_selectionTranslationGeneration;
    NSString* tool = [self argosToolPath];
    if (!tool.length || (!spdf_mac_tool_venv_has_tool(@"argos-translate") &&
                         !spdf_mac_tool_install_attempted())) {
        [self promptToInstallArgosAndContinueSelectionText:text
                                            sourceLanguage:sourceLanguage
                                            targetLanguage:targetLanguage];
        return;
    }

    _translationRunning = YES;
    _translationCancelRequested = NO;
    _selectionTranslationButton.enabled = NO;
    _translateButton.enabled = NO;
    _selectionTranslationStatusLabel.stringValue = @"Translating locally with Argos...";
    _statusLabel.stringValue = @"Translating selection...";

    __weak ShenzhenMacDelegate* weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      NSString* translated = nil;
      NSString* failure = nil;
      BOOL ok = [self runArgosToolSynchronously:tool
                                 sourceLanguage:sourceLanguage
                                 targetLanguage:targetLanguage
                                          input:text
                                         output:&translated
                                          error:&failure];
      dispatch_async(dispatch_get_main_queue(), ^{
        ShenzhenMacDelegate* strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf->_selectionTranslationGeneration) return;
        if (!ok) {
            strongSelf->_translationRunning = NO;
            strongSelf->_selectionTranslationButton.enabled = YES;
            [strongSelf updateTranslateCommandEnablement];
            if (!offeredInstaller && failure.length) {
                [strongSelf runArgosPackageInstallForSelectionFromLanguage:sourceLanguage
                                                                toLanguage:targetLanguage
                                                                      text:text];
                return;
            }
            [strongSelf finishSelectionTranslationWithGeneration:generation
                                                          output:nil
                                                           error:failure.length ? failure : @"Translation failed."];
            return;
        }
        [strongSelf finishSelectionTranslationWithGeneration:generation output:translated ?: @"" error:nil];
      });
    });
}

- (void)runSelectionTranslationFromPanel:(id)sender {
    (void)sender;
    [self selectionTranslationLanguageChanged:nil];
    NSString* source = _translationSourceLanguage ?: @"zh";
    NSString* target = _translationTargetLanguage ?: @"en";
    NSString* text = [_selectionTranslationInputView.string ?: @""
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (text.length == 0) {
        _selectionTranslationStatusLabel.stringValue = @"Input text is empty.";
        NSBeep();
        return;
    }
    if ([source isEqualToString:target]) {
        _selectionTranslationStatusLabel.stringValue = @"Choose different source and target languages.";
        NSBeep();
        return;
    }
    if (_translationRunning || _translationInstallRunning) {
        _selectionTranslationStatusLabel.stringValue = @"A translation task is already running.";
        return;
    }
    _selectionTranslationOutputView.string = @"";
    [self runSelectionTranslationWithText:text sourceLanguage:source targetLanguage:target offeredInstaller:NO];
}

- (void)runArgosPackageInstallForSelectionFromLanguage:(NSString*)sourceLanguage
                                            toLanguage:(NSString*)targetLanguage
                                                  text:(NSString*)text {
    NSString* packageTool = [self argospmToolPath];
    if (!packageTool.length) {
        [self finishSelectionTranslationWithGeneration:_selectionTranslationGeneration
                                                output:nil
                                                 error:@"Argos package manager was not found."];
        return;
    }

    NSString* packageName = [NSString stringWithFormat:@"translate-%@_%@", sourceLanguage, targetLanguage];
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"Install Argos language package?";
    alert.informativeText = [NSString stringWithFormat:@"The offline %@ to %@ package may be missing. Shenzhen PDF can "
                                                       @"ask argospm to install %@, then continue translation.",
                                                       sourceLanguage, targetLanguage, packageName];
    [alert addButtonWithTitle:@"Install"];
    [alert addButtonWithTitle:@"Cancel"];
    alert.alertStyle = NSAlertStyleInformational;
    if ([alert runModal] != NSAlertFirstButtonReturn) {
        _selectionTranslationStatusLabel.stringValue = @"Translation package is required.";
        return;
    }

    NSTask* task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:packageTool];
    task.arguments = @[ @"install", packageName ];
    task.environment = [self taskEnvironmentWithToolPaths:@[ packageTool ]];

    __weak ShenzhenMacDelegate* weakSelf = self;
    [self runTranslationInstallTask:task
                              title:@"Installing Translation Package"
                            heading:[NSString stringWithFormat:@"Installing %@", packageName]
                         initialLog:[NSString stringWithFormat:@"Running argospm install %@...\n", packageName]
                         completion:^(NSTask* finishedTask, NSString* output) {
                           (void)output;
                           ShenzhenMacDelegate* strongSelf = weakSelf;
                           if (!strongSelf) return;
                           strongSelf->_translationInstallRunning = NO;
                           [strongSelf updateTranslateCommandEnablement];
                           if (finishedTask.terminationStatus == 0) {
                               [strongSelf appendTranslationInstallLog:@"\nArgos language package installed.\n"];
                               [strongSelf->_translationInstallPanel orderOut:nil];
                               [strongSelf runSelectionTranslationWithText:text
                                                            sourceLanguage:sourceLanguage
                                                            targetLanguage:targetLanguage
                                                          offeredInstaller:YES];
                           } else {
                               [strongSelf appendTranslationInstallLog:
                                               @"\nArgos language package installation failed. The log above can be "
                                               @"selected and copied.\n"];
                               strongSelf->_selectionTranslationStatusLabel.stringValue =
                                   @"Translation package installation failed.";
                           }
                         }];
}

// Hover cursor hit-testing runs on every mouse-move, so it never queries the
// core: per-page text-line and link rects (page space, zoom-independent) are
// built ONCE per page on a background queue - including text-URL detection,
// which builds the page's stext and would stall the main thread for hundreds
// of ms on dense pages - and cached until the document's content changes.
// A page whose cache is still building resolves to "none" (arrow) and the
// cursor corrects itself when the build lands (refreshCursorForMouseLocation).
static const CGFloat kSPDFCursorLinkHitPadding = 2.0; // matches spdf_link_at_point's text-URL slop
static const int kSPDFCursorRegionMaxLinkRects = 512;

- (SPDFCursorRegionKind)documentViewCursorRegionAtPageIndex:(NSInteger)pageIndex pagePoint:(NSPoint)pagePoint {
    if (!_doc || pageIndex < 0) return SPDFCursorRegionNone;
    NSDictionary* regions = _cursorRegionCache[@(pageIndex)];
    if (!regions) {
        [self buildCursorRegionsForPageIfNeeded:pageIndex];
        return SPDFCursorRegionNone;
    }
    return spdf_cursor_region_at_point(pagePoint, regions[@"links"], regions[@"text"], kSPDFCursorLinkHitPadding);
}

- (void)invalidateCursorRegionCache {
    _cursorRegionGeneration++;
    [_cursorRegionCache removeAllObjects];
    [_cursorRegionPagesBuilding removeAllObjects];
}

- (void)buildCursorRegionsForPageIfNeeded:(NSInteger)pageIndex {
    NSNumber* number = @(pageIndex);
    if (_cursorRegionCache[number] || [_cursorRegionPagesBuilding containsObject:number]) return;
    NSString* path = [self activeWorkingPath];
    NSString* sourcePath = [_path copy];
    if (!path.length || !sourcePath.length) return;
    [_cursorRegionPagesBuilding addObject:number];
    NSUInteger generation = _cursorRegionGeneration;
    [_cursorRegionQueue addOperationWithBlock:^{
      @autoreleasepool {
          char err[1024];
          NSMutableArray<NSValue*>* textValues = [NSMutableArray array];
          NSMutableArray<NSValue*>* linkValues = [NSMutableArray array];
          spdf_document* workerDoc = generation == self->_cursorRegionGeneration
                                         ? [self workerDocumentForPath:path
                                                            sourcePath:sourcePath
                                                                 error:err
                                                           errorLength:sizeof(err)]
                                         : NULL;
          if (workerDoc) {
              spdf_text_lines lines;
              memset(&lines, 0, sizeof(lines));
              if (spdf_extract_page_text_lines(workerDoc, (int)pageIndex, &lines, err, sizeof(err))) {
                  for (int i = 0; i < lines.count; ++i) {
                      if (!lines.items[i].text || !*lines.items[i].text) continue;
                      NSRect r = NSMakeRect(lines.items[i].bounds.x0, lines.items[i].bounds.y0,
                                            lines.items[i].bounds.x1 - lines.items[i].bounds.x0,
                                            lines.items[i].bounds.y1 - lines.items[i].bounds.y0);
                      if (NSIsEmptyRect(r)) continue;
                      [textValues addObject:[NSValue valueWithRect:r]];
                  }
                  spdf_free_text_lines(&lines);
              }
              spdf_rect rects[kSPDFCursorRegionMaxLinkRects];
              int count = spdf_page_link_rects(workerDoc, (int)pageIndex, /*detect_text_links=*/1, rects,
                                               kSPDFCursorRegionMaxLinkRects, err, sizeof(err));
              for (int i = 0; i < count; ++i) {
                  NSRect r = NSMakeRect(rects[i].x0, rects[i].y0, rects[i].x1 - rects[i].x0, rects[i].y1 - rects[i].y0);
                  if (NSIsEmptyRect(r)) continue;
                  [linkValues addObject:[NSValue valueWithRect:r]];
              }
          }
          [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            [self->_cursorRegionPagesBuilding removeObject:number];
            if (generation != self->_cursorRegionGeneration || !self->_doc) return;
            // Failures (unreadable file, out-of-range page) cache empty region
            // arrays: the cursor shows the arrow there and, unlike retrying,
            // mouse moves cannot re-kick a doomed build every event.
            self->_cursorRegionCache[number] = @{@"links" : linkValues, @"text" : textValues};
            [self->_pageView refreshCursorForMouseLocation];
          }];
      }
    }];
}

- (BOOL)documentViewOpenLinkAtPageIndex:(NSInteger)pageIndex pagePoint:(NSPoint)pagePoint {
    if (!_doc) return NO;

    char err[512];
    spdf_link_target target;
    // A click actually follows the link, so do the full check including
    // plain-text URL detection (detect_text_links=1).
    int hit = spdf_link_at_point(_doc, (int)pageIndex, (float)pagePoint.x, (float)pagePoint.y, &target,
                                 /*detect_text_links=*/1, err, sizeof(err));
    if (hit <= 0) return NO;

    if (target.kind == SPDF_LINK_URI && target.uri) {
        NSString* uri = [NSString stringWithUTF8String:target.uri];
        NSURL* url = [NSURL URLWithString:uri];
        if ((!url || url.scheme.length == 0) && uri.length > 0) url = [NSURL fileURLWithPath:uri];
        if (url && spdf_is_allowed_external_url(url))
            [[NSWorkspace sharedWorkspace] openURL:url];
        else
            NSBeep();
        spdf_free_link_target(&target);
        return YES;
    }

    if (target.kind == SPDF_LINK_INTERNAL && target.page_index >= 0) {
        NSInteger targetPage = target.page_index;
        // A destination's own offset down the target page is honored; a link
        // that names only a page arrives at that page's start. Top-aligned,
        // never centered: centering the destination hung half a viewport of the
        // PRECEDING page above it (see SPDFMacLinkNavigation.mm).
        BOOL hasDestinationY = isfinite(target.x) && isfinite(target.y);
        _pageIndex = MAX(0, MIN(targetPage, spdf_page_count(_doc) - 1));
        _pageView.currentPageIndex = _pageIndex;
        [self renderPageIfNeededAtIndex:_pageIndex];
        [self resizeDocumentView];
        [self scrollToLinkDestinationOnPage:_pageIndex pageY:hasDestinationY ? (CGFloat)target.y : 0.0];
        [self updateControls];
        [self selectCurrentSidebarRow];
        [self persistActiveState];
        spdf_free_link_target(&target);
        return YES;
    }

    spdf_free_link_target(&target);
    return NO;
}

- (NSArray<NSValue*>*)currentSelectionRects {
    if (_selectionPageIndex < 0 || _selectionPageIndex >= (NSInteger)_renderedPages.count) return @[];
    return _renderedPages[(NSUInteger)_selectionPageIndex].selectionRects ?: @[];
}

- (NSString*)trimmedLanguageCode:(NSString*)code {
    NSString* trimmed =
        [[code ?: @"" lowercaseString] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableString* sanitized = [NSMutableString string];
    NSCharacterSet* allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz-_"];
    for (NSUInteger i = 0; i < trimmed.length; ++i) {
        unichar ch = [trimmed characterAtIndex:i];
        if ([allowed characterIsMember:ch]) [sanitized appendFormat:@"%C", ch];
    }
    return sanitized;
}

- (NSString*)translationSuffixForTargetLanguage:(NSString*)targetLanguage {
    NSString* language = [self trimmedLanguageCode:targetLanguage];
    if ([language isEqualToString:@"en"]) return @"english";
    if (!language.length) return @"translated";
    return language;
}

- (NSString*)translatedOutputPathForPath:(NSString*)path targetLanguage:(NSString*)targetLanguage {
    NSString* dir = path.stringByDeletingLastPathComponent;
    NSString* stem = path.stringByDeletingPathExtension.lastPathComponent;
    NSString* suffix = [self translationSuffixForTargetLanguage:targetLanguage];
    return [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_%@.pdf", stem, suffix]];
}

- (void)populateTranslationLanguagePopup:(NSPopUpButton*)popup selectedCode:(NSString*)selectedCode {
    [popup removeAllItems];
    NSString* selected = [self trimmedLanguageCode:selectedCode];
    BOOL selectedExists = NO;
    for (NSDictionary<NSString*, NSString*>* language in spdf_translation_languages()) {
        NSString* code = language[@"code"] ?: @"";
        NSString* name = language[@"name"] ?: code;
        [popup addItemWithTitle:[NSString stringWithFormat:@"%@ (%@)", name, code]];
        popup.lastItem.representedObject = code;
        if ([code isEqualToString:selected]) selectedExists = YES;
    }
    if (selected.length && !selectedExists) {
        [popup addItemWithTitle:[NSString stringWithFormat:@"Custom (%@)", selected]];
        popup.lastItem.representedObject = selected;
    }
    NSInteger index = 0;
    for (NSInteger i = 0; i < popup.numberOfItems; ++i) {
        NSString* code = popup.itemArray[(NSUInteger)i].representedObject;
        if ([code isKindOfClass:NSString.class] && [code isEqualToString:selected]) {
            index = i;
            break;
        }
    }
    [popup selectItemAtIndex:index];
}

- (NSString*)selectedTranslationLanguageCodeFromPopup:(NSPopUpButton*)popup fallback:(NSString*)fallback {
    NSString* code = popup.selectedItem.representedObject;
    if (![code isKindOfClass:NSString.class] || !code.length) code = fallback;
    return [self trimmedLanguageCode:code];
}

- (NSDictionary*)promptForTranslationOptionsUsingSelection:(BOOL)usingSelection {
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = usingSelection ? @"Translate Selection" : @"Translate Document";
    alert.informativeText =
        @"Choose an offline Argos language package. Missing packages can be downloaded automatically.";
    [alert addButtonWithTitle:@"Translate"];
    [alert addButtonWithTitle:@"Cancel"];

    NSView* accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 390, 78)];
    NSTextField* sourceLabel = [NSTextField labelWithString:@"From"];
    sourceLabel.frame = NSMakeRect(0, 48, 72, 22);
    NSPopUpButton* sourcePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(84, 44, 250, 26) pullsDown:NO];
    [self populateTranslationLanguagePopup:sourcePopup selectedCode:_translationSourceLanguage ?: @"zh"];
    NSTextField* targetLabel = [NSTextField labelWithString:@"To"];
    targetLabel.frame = NSMakeRect(0, 14, 72, 22);
    NSPopUpButton* targetPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(84, 10, 250, 26) pullsDown:NO];
    [self populateTranslationLanguagePopup:targetPopup selectedCode:_translationTargetLanguage ?: @"en"];
    for (NSView* view in @[ sourceLabel, sourcePopup, targetLabel, targetPopup ]) [accessory addSubview:view];
    alert.accessoryView = accessory;

    if ([alert runModal] != NSAlertFirstButtonReturn) return nil;

    NSString* source = [self selectedTranslationLanguageCodeFromPopup:sourcePopup fallback:@"zh"];
    NSString* target = [self selectedTranslationLanguageCodeFromPopup:targetPopup fallback:@"en"];
    if (!source.length || !target.length) {
        [self showError:@"Translation needs language codes" detail:@"Choose source and target languages for Argos."];
        return nil;
    }
    if ([source isEqualToString:target]) {
        [self showError:@"Translation needs different languages" detail:@"The source and target language codes match."];
        return nil;
    }

    _translationSourceLanguage = source;
    _translationTargetLanguage = target;
    [self savePersistentState];
    return @{@"source" : source, @"target" : target};
}

- (NSString*)currentTextForTranslationUsingSelection:(BOOL*)usingSelection error:(NSString**)errorOut {
    _pendingTranslationItems = nil;
    _pendingTranslationChapters = nil;
    // The picker translates the whole document, whatever is selected.
    BOOL hasSelection = ![self localTranslationRequest] && _selectedText.length > 0 && _selectionPageIndex >= 0 && [self currentSelectionRects].count > 0;
    if (hasSelection) {
        NSRect bounds = NSZeroRect;
        BOOL hasBounds = NO;
        for (NSValue* value in [self currentSelectionRects]) {
            NSRect rect = value.rectValue;
            bounds = hasBounds ? NSUnionRect(bounds, rect) : rect;
            hasBounds = YES;
        }
        if (!hasBounds) {
            if (errorOut) *errorOut = @"Could not locate the selected text on the page.";
            return nil;
        }
        _pendingTranslationItems = @[ @{
            @"page" : @(_selectionPageIndex),
            @"rect" : [NSValue valueWithRect:bounds],
            @"font" : @(MAX(8.0, MIN(18.0, NSHeight(bounds) * 0.8)))
        } ];
        if (usingSelection) *usingSelection = YES;
        return SPDFTextByCollapsingWhitespace(_selectedText);
    }

    if (usingSelection) *usingSelection = NO;
    if (!_doc) {
        if (errorOut) *errorOut = @"No document is open.";
        return nil;
    }

    NSMutableArray<NSDictionary*>* items = [NSMutableArray array];
    NSMutableString* text = [NSMutableString string];
    char err[1024];
    int pageCount = spdf_page_count(_doc);
    for (int page = 0; page < pageCount; ++page) {
        spdf_text_lines lines;
        memset(&lines, 0, sizeof(lines));
        if (!spdf_extract_page_text_lines(_doc, page, &lines, err, sizeof(err))) {
            if (errorOut)
                *errorOut = [NSString stringWithFormat:@"Could not extract text from page %d: %s", page + 1,
                                                       err[0] ? err : "Unknown error"];
            return nil;
        }
        for (int i = 0; i < lines.count; ++i) {
            const char* lineText = lines.items[i].text;
            if (!lineText || !*lineText) continue;
            NSString* sourceLine = SPDFTextByCollapsingWhitespace([NSString stringWithUTF8String:lineText] ?: @"");
            if (sourceLine.length == 0) continue;
            NSRect rect = NSMakeRect(lines.items[i].bounds.x0, lines.items[i].bounds.y0,
                                     lines.items[i].bounds.x1 - lines.items[i].bounds.x0,
                                     lines.items[i].bounds.y1 - lines.items[i].bounds.y0);
            [items addObject:@{
                @"page" : @(page),
                @"rect" : [NSValue valueWithRect:rect],
                @"font" : @(lines.items[i].font_size)
            }];
            [text appendString:sourceLine];
            [text appendString:@"\n"];
        }
        spdf_free_text_lines(&lines);
    }

    if (items.count == 0 || text.length == 0) {
        // Not a hard failure: chapters and comments can still be translatable.
        // The caller shows this message only when they turn out empty too.
        if (errorOut) *errorOut = @"No selectable document text was found. Run OCR first, then translate.";
        _pendingTranslationItems = @[];
        return @"";
    }
    _pendingTranslationItems = items;
    return text;
}

- (NSString*)currentCommentAuthor {
    NSString* author = [_commentAuthor stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (author.length > 0) return author;
    NSString* fallback = NSFullUserName();
    if (fallback.length == 0) fallback = NSUserName();
    return fallback ?: @"";
}

- (NSDictionary*)promptForCommentEditorWithTitle:(NSString*)title
                                     buttonTitle:(NSString*)buttonTitle
                                          author:(NSString*)author
                                            text:(NSString*)text {
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = title ?: @"Comment";
    alert.informativeText = @"Edit the comment author and text.";
    [alert addButtonWithTitle:buttonTitle ?: @"Save"];
    [alert addButtonWithTitle:@"Cancel"];

    NSView* accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 420, 188)];
    NSTextField* authorLabel = [NSTextField labelWithString:@"Author"];
    authorLabel.frame = NSMakeRect(0, 164, 420, 18);
    NSTextField* authorField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 136, 420, 24)];
    authorField.stringValue = author ?: @"";

    NSTextField* commentLabel = [NSTextField labelWithString:@"Comment"];
    commentLabel.frame = NSMakeRect(0, 112, 420, 18);
    NSScrollView* scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 420, 108)];
    scroll.hasVerticalScroller = YES;
    NSTextView* textView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 420, 108)];
    textView.string = text ?: @"";
    textView.font = [NSFont systemFontOfSize:13.0];
    textView.verticallyResizable = YES;
    textView.horizontallyResizable = NO;
    textView.textContainer.widthTracksTextView = YES;
    scroll.documentView = textView;

    [accessory addSubview:authorLabel];
    [accessory addSubview:authorField];
    [accessory addSubview:commentLabel];
    [accessory addSubview:scroll];
    alert.accessoryView = accessory;
    NSRange commentRange = NSMakeRange(0, textView.string.length);
    [textView setSelectedRange:commentRange];
    [alert.window setInitialFirstResponder:textView];
    [alert.window makeFirstResponder:textView];
    dispatch_async(dispatch_get_main_queue(), ^{
      [alert.window makeFirstResponder:textView];
      [textView setSelectedRange:commentRange];
    });
    if ([alert runModal] != NSAlertFirstButtonReturn) return nil;

    NSString* trimmedText =
        [textView.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString* trimmedAuthor =
        [authorField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmedText.length == 0) return nil;
    return @{@"author" : trimmedAuthor ?: @"", @"text" : trimmedText};
}

- (NSString*)promptForCommentTextWithDefault:(NSString*)defaultText {
    NSDictionary* result = [self promptForCommentEditorWithTitle:@"Add Comment"
                                                     buttonTitle:@"Add"
                                                          author:[self currentCommentAuthor]
                                                            text:defaultText ?: @""];
    if (result[@"author"]) {
        _commentAuthor = result[@"author"];
        [self savePersistentState];
    }
    return result[@"text"];
}

- (void)addComment:(id)sender {
    (void)sender;
    if (!_doc || !_path.length) {
        NSBeep();
        return;
    }
    if (![self ensureActivePDFCanBeModifiedForOperation:@"adding a comment"]) return;

    BOOL hasSelection = _selectedText.length > 0 && _selectionPageIndex >= 0 && [self currentSelectionRects].count > 0;
    NSInteger pageIndex = hasSelection ? _selectionPageIndex : _contextPageIndex;
    if (pageIndex < 0 || pageIndex >= (NSInteger)_renderedPages.count) {
        NSBeep();
        return;
    }

    NSString* comment = [self promptForCommentTextWithDefault:hasSelection ? _selectedText : @""];
    if (!comment) return;
    comment = [comment stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (comment.length == 0) {
        NSBeep();
        return;
    }

    char err[1024];
    BOOL ok = NO;
    if (hasSelection) {
        NSArray<NSValue*>* values = [self currentSelectionRects];
        int count = (int)MIN((NSUInteger)256, values.count);
        spdf_rect rects[256];
        for (int i = 0; i < count; ++i) {
            NSRect r = values[(NSUInteger)i].rectValue;
            rects[i].x0 = NSMinX(r);
            rects[i].y0 = NSMinY(r);
            rects[i].x1 = NSMaxX(r);
            rects[i].y1 = NSMaxY(r);
        }
        ok = spdf_add_highlight_comment(_doc, (int)pageIndex, rects, count, comment.UTF8String,
                                        [self currentCommentAuthor].UTF8String, err, sizeof(err));
    } else {
        ok = spdf_add_text_comment(_doc, (int)pageIndex, (float)_contextPagePoint.x, (float)_contextPagePoint.y,
                                   comment.UTF8String, [self currentCommentAuthor].UTF8String, err, sizeof(err));
    }
    if (ok) ok = spdf_save_document(_doc, _path.fileSystemRepresentation, err, sizeof(err));
    if (ok) [self collectionDidSavePath:_path];
    if (!ok) {
        [self showError:@"Could not add comment" detail:[NSString stringWithUTF8String:err[0] ? err : "Unknown error"]];
        return;
    }
    // Refresh cached mtime/size so the active-file watcher treats this as our
    // own write and does not self-trigger a reload.
    [self refreshActiveTabCachedFileAttributesAfterSelfSave];

    _statusLabel.stringValue = @"Comment added.";
    [self reloadCommentsFromActiveDocument];
    [self renderDocumentAndScrollToPage:_pageIndex
                               alignTop:NO
                          restoreOrigin:[NSValue valueWithPoint:_pageScrollView.contentView.bounds.origin]];
}

- (void)setCommentAuthor:(id)sender {
    (void)sender;
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"Set Author for Comments";
    alert.informativeText = @"New comments will use this author.";
    [alert addButtonWithTitle:@"Save"];
    [alert addButtonWithTitle:@"Cancel"];
    NSTextField* field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 360, 24)];
    field.stringValue = [self currentCommentAuthor];
    alert.accessoryView = field;
    [_window makeFirstResponder:field];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    _commentAuthor =
        [field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    [self savePersistentState];
    _statusLabel.stringValue = _commentAuthor.length ? @"Comment author saved." : @"Comment author reset.";
}

- (spdf_comment_item*)commentItemForIndex:(NSInteger)commentIndex {
    if (commentIndex < 0) return NULL;
    for (int i = 0; i < _comments.count; ++i) {
        if (_comments.items[i].index == commentIndex) return &_comments.items[i];
    }
    return NULL;
}

- (NSNumber*)commentIndexForSidebarRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)_sidebarItems.count) return nil;
    NSDictionary* item = _sidebarItems[(NSUInteger)row];
    if (![item[@"kind"] isEqualToString:@"comment"]) return nil;
    NSNumber* commentIndex = item[@"commentIndex"];
    return [commentIndex isKindOfClass:NSNumber.class] ? commentIndex : nil;
}

- (NSInteger)commentIndexForSidebarContextRow {
    NSNumber* commentIndex = [self commentIndexForSidebarRow:_sidebarTable.clickedRow];
    return commentIndex ? commentIndex.integerValue : -1;
}

- (NSInteger)commentIndexAtPageIndex:(NSInteger)pageIndex pagePoint:(NSPoint)pagePoint {
    if (pageIndex < 0) return -1;
    for (NSDictionary* comment in [self commentAnnotationsForPage:pageIndex]) {
        NSValue* boundsValue = comment[@"bounds"];
        if (!boundsValue) continue;
        NSRect bounds = NSInsetRect(boundsValue.rectValue, -3.0, -3.0);
        if (NSPointInRect(pagePoint, bounds)) return [comment[@"commentIndex"] integerValue];
    }
    return -1;
}

- (NSInteger)commentIndexForEditAction:(id)sender {
    if ([sender isKindOfClass:NSMenuItem.class]) {
        id represented = ((NSMenuItem*)sender).representedObject;
        if ([represented isKindOfClass:NSNumber.class]) return [represented integerValue];
    }
    NSInteger sidebarIndex = [self commentIndexForSidebarContextRow];
    if (sidebarIndex >= 0) return sidebarIndex;
    return _contextCommentIndex;
}

- (void)editComment:(id)sender {
    (void)sender;
    if (!_doc || !_path.length) return;
    if (![self ensureActivePDFCanBeModifiedForOperation:@"editing a comment"]) return;

    NSInteger commentIndex = [self commentIndexForEditAction:sender];
    spdf_comment_item* item = [self commentItemForIndex:commentIndex];
    if (!item) {
        NSBeep();
        return;
    }

    NSString* author =
        item->author && *item->author ? [NSString stringWithUTF8String:item->author] : [self currentCommentAuthor];
    NSString* text = item->text && *item->text ? [NSString stringWithUTF8String:item->text] : @"";
    NSDictionary* result = [self promptForCommentEditorWithTitle:@"Edit Comment"
                                                     buttonTitle:@"Save"
                                                          author:author
                                                            text:text];
    if (!result) return;

    _commentAuthor = result[@"author"] ?: @"";
    char err[1024];
    BOOL ok = spdf_update_comment(_doc, (int)commentIndex, [result[@"text"] UTF8String], [result[@"author"] UTF8String],
                                  err, sizeof(err));
    if (ok) ok = spdf_save_document(_doc, _path.fileSystemRepresentation, err, sizeof(err));
    if (ok) [self collectionDidSavePath:_path];
    if (!ok) {
        [self showError:@"Could not edit comment"
                 detail:[NSString stringWithUTF8String:err[0] ? err : "Unknown error"]];
        return;
    }
    [self refreshActiveTabCachedFileAttributesAfterSelfSave];

    [self savePersistentState];
    _statusLabel.stringValue = @"Comment updated.";
    [self reloadCommentsFromActiveDocument];
    [self renderDocumentAndScrollToPage:_pageIndex
                               alignTop:NO
                          restoreOrigin:[NSValue valueWithPoint:_pageScrollView.contentView.bounds.origin]];
}

- (void)deleteComment:(id)sender {
    if (!_doc || !_path.length) return;
    if (![self ensureActivePDFCanBeModifiedForOperation:@"deleting a comment"]) return;

    NSInteger commentIndex = [self commentIndexForEditAction:sender];
    spdf_comment_item* item = [self commentItemForIndex:commentIndex];
    if (!item) {
        NSBeep();
        return;
    }

    NSString* text = item->text && *item->text ? [NSString stringWithUTF8String:item->text] : @"";
    NSString* detail = @"This will permanently remove the comment from the PDF.";
    if (text.length > 0) {
        NSString* preview = text.length > 180 ? [[text substringToIndex:180] stringByAppendingString:@"..."] : text;
        detail = [NSString stringWithFormat:@"%@\n\n%@", detail, preview];
    }

    NSAlert* alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = @"Delete Comment?";
    alert.informativeText = detail;
    [alert addButtonWithTitle:@"Delete"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    [self documentViewEndHoverComment];
    NSValue* restoreOrigin = [NSValue valueWithPoint:_pageScrollView.contentView.bounds.origin];
    char err[1024];
    BOOL ok = spdf_delete_comment(_doc, (int)commentIndex, err, sizeof(err));
    if (ok) ok = spdf_save_document(_doc, _path.fileSystemRepresentation, err, sizeof(err));
    if (ok) [self collectionDidSavePath:_path];
    if (!ok) {
        [self showError:@"Could not delete comment"
                 detail:[NSString stringWithUTF8String:err[0] ? err : "Unknown error"]];
        return;
    }
    [self refreshActiveTabCachedFileAttributesAfterSelfSave];

    _statusLabel.stringValue = @"Comment deleted.";
    [self reloadCommentsFromActiveDocument];
    [self renderDocumentAndScrollToPage:_pageIndex alignTop:NO restoreOrigin:restoreOrigin];
}

- (NSString*)shortProvenanceForPath:(NSString*)path {
    return spdf_palette_location_label(path, NSHomeDirectory(), SPDFMacStateDirectoryPath());
}

- (NSArray<NSString*>*)labelsFromString:(NSString*)text {
    NSMutableArray<NSString*>* labels = [NSMutableArray array];
    NSCharacterSet* separators = [NSCharacterSet characterSetWithCharactersInString:@",;"];
    for (NSString* raw in [text componentsSeparatedByCharactersInSet:separators]) {
        NSString* label = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (label.length > 0 && ![labels containsObject:label]) [labels addObject:label];
    }
    return labels;
}

- (NSDictionary*)promptForFavoriteWithDefaultName:(NSString*)defaultName title:(NSString*)title {
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = title;
    alert.informativeText = @"Name this favorite so it is easier to find from the command palette.";
    [alert addButtonWithTitle:@"Save"];
    [alert addButtonWithTitle:@"Cancel"];

    NSStackView* stack = [[NSStackView alloc] initWithFrame:NSMakeRect(0, 0, 360, 74)];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.spacing = 6.0;

    NSTextField* nameField = [[NSTextField alloc] init];
    nameField.stringValue = defaultName ?: @"";
    nameField.placeholderString = @"Favorite name";
    NSTextField* labelField = [[NSTextField alloc] init];
    labelField.placeholderString = @"Optional search labels, separated by commas";
    [stack addArrangedSubview:nameField];
    [stack addArrangedSubview:labelField];
    alert.accessoryView = stack;

    if ([alert runModal] != NSAlertFirstButtonReturn) return nil;
    NSString* name =
        [nameField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!name.length) name = defaultName ?: @"Favorite";
    NSArray<NSString*>* labels = [self labelsFromString:labelField.stringValue ?: @""];
    return @{@"name" : name, @"labels" : labels};
}

- (void)favoriteCurrentPage:(id)sender {
    (void)sender;
    if (!_doc || !_path.length) return;
    NSString* displayName = spdf_display_name_for_path(_path);
    NSString* defaultName = [NSString stringWithFormat:@"%@ p.%ld", displayName, (long)_pageIndex + 1];
    NSDictionary* metadata = [self promptForFavoriteWithDefaultName:defaultName title:@"Favorite Current Page"];
    if (!metadata) return;
    NSMutableDictionary* fav = [@{
        @"type" : @"page",
        @"path" : _path,
        @"title" : displayName,
        @"page" : @(_pageIndex),
        @"name" : metadata[@"name"],
        @"labels" : metadata[@"labels"],
        @"created" : @((long)NSDate.date.timeIntervalSince1970)
    } mutableCopy];
    NSIndexSet* dupes = [_favorites indexesOfObjectsPassingTest:^BOOL(NSDictionary* obj, NSUInteger idx, BOOL* stop) {
      (void)idx;
      (void)stop;
      return [obj[@"path"] isEqualToString:_path] && [obj[@"type"] isEqualToString:@"page"] &&
             [obj[@"page"] integerValue] == _pageIndex;
    }];
    if (dupes.count) [_favorites removeObjectsAtIndexes:dupes];
    [_favorites addObject:fav];
    [self savePersistentState];
    _statusLabel.stringValue = @"Page added to favorites.";
}

- (void)favoriteCurrentDocument:(id)sender {
    (void)sender;
    if (!_doc || !_path.length) return;
    NSString* displayName = spdf_display_name_for_path(_path);
    NSDictionary* metadata = [self promptForFavoriteWithDefaultName:displayName title:@"Favorite Current Document"];
    if (!metadata) return;
    NSMutableDictionary* fav = [@{
        @"type" : @"document",
        @"path" : _path,
        @"title" : displayName,
        @"page" : @0,
        @"name" : metadata[@"name"],
        @"labels" : metadata[@"labels"],
        @"created" : @((long)NSDate.date.timeIntervalSince1970)
    } mutableCopy];
    NSIndexSet* dupes = [_favorites indexesOfObjectsPassingTest:^BOOL(NSDictionary* obj, NSUInteger idx, BOOL* stop) {
      (void)idx;
      (void)stop;
      return [obj[@"path"] isEqualToString:_path] && [obj[@"type"] isEqualToString:@"document"];
    }];
    if (dupes.count) [_favorites removeObjectsAtIndexes:dupes];
    [_favorites addObject:fav];
    [self savePersistentState];
    _statusLabel.stringValue = @"Document added to favorites.";
}

- (void)showFavoritesPalette:(id)sender {
    (void)sender;
    _paletteMode = 1;
    [self showPaletteWithTitle:@"Command"];
}

- (void)focusFind:(id)sender {
    (void)sender;
    // Cmd+F with a live text selection searches for it immediately (the query
    // stays selected in the field, so typing replaces it, like in a browser).
    NSString* selection = SPDFTextByCollapsingWhitespace([self trimmedSelectedTextForCommand]);
    if (selection.length > 0 && ![selection isEqualToString:_searchField.stringValue]) {
        [self startSearchForText:selection];
        return;
    }
    [self revealWorkspaceFind];
    [_window makeFirstResponder:_searchField];
    [_searchField selectText:nil];
}

// Cmd+V (or Edit > Paste) with no editable field focused searches for the
// clipboard text, or opens pasted files/images. A focused field editor sits earlier
// in the responder chain and handles paste: itself, so this only runs for the
// document viewer.
- (void)paste:(id)sender {
    (void)sender;
    if (_presentationMode) return;
    if ([self pasteClipboardDocument:NSPasteboard.generalPasteboard]) return;
    if (![self hasActiveDocument] || !_searchField) return;
    NSString* clip = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
    NSString* query = SPDFTextByCollapsingWhitespace(
        [clip stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]);
    if (query.length == 0) return;
    [self startSearchForText:query];
}

- (void)startSearchForText:(NSString*)query {
    [self revealWorkspaceFind];
    [_window makeFirstResponder:_searchField];
    _searchField.stringValue = query;
    [_searchField selectText:nil];
    [self startFindForCurrentQueryResetSavedIndex:YES revealMatch:YES];
}

- (void)toggleFindRegex:(id)sender {
    (void)sender;
    [self rememberActiveTabFindState];
    [self startFindForCurrentQuery];
}

- (void)toggleFindRegexMultiline:(id)sender {
    (void)sender;
    _findRegexMultiline = !_findRegexMultiline;
    [self rememberActiveTabFindState];
    [self startFindForCurrentQuery];
}

- (void)toggleCollapseWhitespaceWhenCopyingText:(id)sender {
    (void)sender;
    _collapseWhitespaceWhenCopyingText = !_collapseWhitespaceWhenCopyingText;
    [self savePersistentState];
}

- (void)togglePreventSleepInPresentation:(id)sender {
    (void)sender;
    _preventSleepInPresentation = !_preventSleepInPresentation;
    if (_presentationMode) {
        if (_preventSleepInPresentation)
            [self beginPresentationSleepActivityIfNeeded];
        else
            [self endPresentationSleepActivity];
    }
    [self savePersistentState];
}

- (void)openAccessibilitySettings {
    NSURL* url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"];
    if (url) [NSWorkspace.sharedWorkspace openURL:url];
}

- (void)clearPageFieldFocus {
    if (_window.firstResponder == _pageField || _window.firstResponder == _pageField.currentEditor ||
        _pageField.currentEditor)
        [_window makeFirstResponder:[self activeDocumentKeyView]];
}

- (void)clearToolbarFieldFocusForTabSwitch {
    if (!_window) return;
    BOOL toolbarHasFocus = _window.firstResponder == _pageField || _window.firstResponder == _searchField ||
                           _window.firstResponder == _pageField.currentEditor ||
                           _window.firstResponder == _searchField.currentEditor || _pageField.currentEditor ||
                           _searchField.currentEditor;
    if (toolbarHasFocus) [_pageField abortEditing];
    NSResponder* target = [self activeDocumentKeyView];
    if (target) [_window makeFirstResponder:target];
    if (_pageField.currentEditor) [_pageField abortEditing];
}

// The view keyboard input belongs to for the ACTIVE tab: the markdown page
// canvas when a markdown tab is showing (its keyDown routes through the same
// type-to-search entry as the PDF views), else the PDF page view.
- (NSView*)activeDocumentKeyView {
    NSView* root = [self isMarkdownActive] ? self.activeMarkdownSession.rootView : nil;
    for (NSView* subview in root.subviews) {
        NSView* canvas = [subview isKindOfClass:NSScrollView.class] ? [(NSScrollView*)subview documentView] : nil;
        if (canvas.acceptsFirstResponder) return canvas;
    }
    return _pageView ? (NSView*)_pageView : (NSView*)_pageScrollView;
}

// Tab-activation focus chokepoint: after selecting a tab (strip click — even on
// the already-selected tab — Cmd+number, reorder, overflow menu, dragged-tab
// drop, closing onto a neighbor) typing must search the document immediately.
// The claim is guarded (see SPDFTabStripView): only passive focus holders give
// way, so a deliberately focused find/page/sidebar-filter editor keeps typing.
- (void)focusActiveDocumentViewAfterTabSelection {
    if (_presentationMode) return;
    NSMutableArray<NSResponder*>* parked = [NSMutableArray arrayWithCapacity:2];
    if (_pageView) [parked addObject:_pageView];
    if (_pageScrollView) [parked addObject:_pageScrollView];
    [SPDFTabStripView claimFocusOnDocumentKeyView:[self activeDocumentKeyView]
                                           window:_window
                                         tabStrip:_tabStrip
                                 parkedResponders:parked];
}

- (void)showFindPalette:(id)sender {
    [self focusFind:sender];
}

- (void)collectPaletteMenuCommandsFromMenu:(NSMenu*)menu
                                menuTitles:(NSArray<NSString*>*)menuTitles
                                      into:(NSMutableArray<NSDictionary*>*)commands {
    // Lazily-populated submenus (Recently Opened) fill themselves in
    // menuNeedsUpdate:, which AppKit calls right before showing them; do the
    // same so the palette sees the live items.
    if ([menu.delegate respondsToSelector:@selector(menuNeedsUpdate:)]) [menu.delegate menuNeedsUpdate:menu];
    for (NSMenuItem* item in menu.itemArray) {
        if (item.separatorItem || item.hidden) continue;
        if (item.hasSubmenu) {
            NSString* component = item.submenu.title.length ? item.submenu.title : item.title;
            [self collectPaletteMenuCommandsFromMenu:item.submenu
                                          menuTitles:[menuTitles arrayByAddingObject:component ?: @""]
                                                into:commands];
            continue;
        }
        SEL action = item.action;
        if (!action || item.title.length == 0) continue;
        // The palette is itself the favorites search; a row that reopens it
        // would be a no-op loop.
        if (action == @selector(showFavoritesPalette:)) continue;
        // Same validation the menu system runs before display: resolve the
        // target through the responder chain and let it validate (which also
        // refreshes toggle titles and checkmarks). Disabled commands are
        // hidden, matching how the palette omits empty groups.
        id target = [NSApp targetForAction:action to:item.target from:item];
        BOOL enabled;
        if ([target respondsToSelector:@selector(validateMenuItem:)])
            enabled = [(id<NSMenuItemValidation>)target validateMenuItem:item];
        else if ([target respondsToSelector:@selector(validateUserInterfaceItem:)])
            enabled = [(id<NSUserInterfaceValidations>)target validateUserInterfaceItem:item];
        else
            enabled = [target respondsToSelector:action];
        if (!enabled) continue;
        NSString* title = item.state == NSControlStateValueOn
                              ? [NSString stringWithFormat:@"\u2713 %@", item.title] // mirrors the menu checkmark
                              : item.title;
        NSString* breadcrumb = spdf_palette_menu_breadcrumb(menuTitles, item.title);
        NSString* shortcut =
            spdf_palette_key_equivalent_display_string(item.keyEquivalent, item.keyEquivalentModifierMask);
        [commands addObject:@{
            @"kind" : @"menuCommand",
            @"title" : title ?: @"",
            @"subtitle" : shortcut.length ? [NSString stringWithFormat:@"%@ \u2014 %@", breadcrumb, shortcut]
                                          : breadcrumb,
            @"breadcrumb" : breadcrumb,
            @"selector" : NSStringFromSelector(action),
            @"menuItem" : item
        }];
    }
}

// Snapshot of every command reachable through the menu bar, enumerated fresh
// each time the palette opens so dynamic items (toggles, Recently Opened,
// window list) reflect current state. Enumeration is on-open only; keystroke
// refreshes just filter the snapshot. The snapshot is dropped when the
// palette closes: NSMenuItem retains its target, so holding items past close
// would keep window controllers alive.
- (NSArray<NSDictionary*>*)paletteMenuCommandCandidates {
    NSMutableArray<NSDictionary*>* commands = [NSMutableArray array];
    if (NSApp.mainMenu) [self collectPaletteMenuCommandsFromMenu:NSApp.mainMenu menuTitles:@[] into:commands];
    return commands;
}

- (NSArray<NSDictionary*>*)favoriteResultsForQuery:(NSString*)query prefix:(NSString*)prefix {
    NSMutableArray<NSDictionary*>* results = [NSMutableArray array];
    NSString* lowerQuery = query.lowercaseString ?: @"";
    for (NSDictionary* fav in _favorites) {
        NSArray* labels = [fav[@"labels"] isKindOfClass:NSArray.class] ? fav[@"labels"] : @[];
        NSString* labelText = [labels componentsJoinedByString:@" "];
        NSString* haystack = [[NSString stringWithFormat:@"%@ %@ %@ %@", fav[@"name"] ?: @"", fav[@"title"] ?: @"",
                                                         fav[@"path"] ?: @"", labelText ?: @""] lowercaseString];
        if (lowerQuery.length == 0 || [haystack containsString:lowerQuery]) {
            NSString* subtitle = [self shortProvenanceForPath:fav[@"path"] ?: @""];
            if (labels.count > 0)
                subtitle = [subtitle stringByAppendingFormat:@" - %@", [labels componentsJoinedByString:@", "]];
            if (prefix.length) subtitle = [NSString stringWithFormat:@"%@ - %@", prefix, subtitle];
            NSString* title = spdf_display_label_without_extension(fav[@"name"] ?: fav[@"title"] ?: @"Favorite");
            [results addObject:@{
                @"kind" : @"favorite",
                @"title" : title,
                @"subtitle" : subtitle,
                @"path" : fav[@"path"] ?: @"",
                @"page" : fav[@"page"] ?: @0,
                @"favorite" : fav
            }];
        }
    }
    return results;
}

// One palette candidate per open tab in every window of this process, in window
// then tab order. The tab in front here is marked _current: with nothing typed
// the open-documents group lists places to switch to, and that is not one.
- (NSArray<NSDictionary*>*)openDocumentPaletteCandidates {
    NSMutableArray<NSDictionary*>* candidates = [NSMutableArray array];
    for (ShenzhenMacDelegate* controller in gSPDFWindowControllers ?: @[]) {
        for (SPDFDocumentTab* tab in controller->_tabs) {
            if (!tab.path.length) continue;
            NSMutableDictionary* candidate = [[controller paletteCandidateForTab:tab] mutableCopy];
            if (controller == self && tab == [self selectedTab]) candidate[@"_current"] = @YES;
            [candidates addObject:candidate];
        }
    }
    return candidates;
}

- (NSArray<NSValue*>*)rangesOfPaletteQuery:(NSString*)query inString:(NSString*)text limit:(NSUInteger)limit {
    if (query.length == 0 || text.length == 0) return @[];
    NSMutableArray<NSValue*>* ranges = [NSMutableArray array];
    NSRange searchRange = NSMakeRange(0, text.length);
    while (searchRange.length > 0 && (limit == 0 || ranges.count < limit)) {
        NSRange found = [text rangeOfString:query
                                    options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch
                                      range:searchRange];
        if (found.location == NSNotFound || found.length == 0) break;
        [ranges addObject:[NSValue valueWithRange:found]];
        NSUInteger nextLocation = NSMaxRange(found);
        if (nextLocation >= text.length) break;
        searchRange = NSMakeRange(nextLocation, text.length - nextLocation);
    }
    return ranges;
}

- (NSRange)paletteSnippetRangeInLine:(NSString*)line matchRange:(NSRange)matchRange {
    if (line.length == 0 || matchRange.location == NSNotFound) return NSMakeRange(0, 0);

    NSMutableArray<NSValue*>* words = [NSMutableArray array];
    [line
        enumerateSubstringsInRange:NSMakeRange(0, line.length)
                           options:NSStringEnumerationByWords
                        usingBlock:^(NSString* substring, NSRange substringRange, NSRange enclosingRange, BOOL* stop) {
                          (void)substring;
                          (void)enclosingRange;
                          (void)stop;
                          [words addObject:[NSValue valueWithRange:substringRange]];
                        }];

    NSInteger firstWord = -1;
    NSInteger lastWord = -1;
    for (NSInteger i = 0; i < (NSInteger)words.count; ++i) {
        NSRange wordRange = words[(NSUInteger)i].rangeValue;
        if (NSIntersectionRange(wordRange, matchRange).length == 0) continue;
        if (firstWord < 0) firstWord = i;
        lastWord = i;
    }

    NSRange snippetRange = NSMakeRange(0, 0);
    if (firstWord >= 0 && lastWord >= firstWord) {
        NSInteger startWord = MAX(0, firstWord - 2);
        NSInteger endWord = MIN((NSInteger)words.count - 1, lastWord + 2);
        NSRange startRange = words[(NSUInteger)startWord].rangeValue;
        NSRange endRange = words[(NSUInteger)endWord].rangeValue;
        snippetRange = NSMakeRange(startRange.location, NSMaxRange(endRange) - startRange.location);
    } else {
        NSUInteger start = matchRange.location;
        NSUInteger end = MIN(line.length, NSMaxRange(matchRange));
        NSUInteger before = MIN((NSUInteger)24, start);
        NSUInteger after = MIN((NSUInteger)24, line.length - end);
        snippetRange = NSMakeRange(start - before, before + matchRange.length + after);
    }

    NSCharacterSet* trim = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    while (snippetRange.length > 0 && [trim characterIsMember:[line characterAtIndex:snippetRange.location]]) {
        snippetRange.location++;
        snippetRange.length--;
    }
    while (snippetRange.length > 0 && [trim characterIsMember:[line characterAtIndex:NSMaxRange(snippetRange) - 1]]) {
        snippetRange.length--;
    }
    return snippetRange;
}

- (NSString*)paletteContextForQuery:(NSString*)query
                           document:(spdf_document*)doc
                               page:(NSInteger)page
                           hitCount:(NSInteger)hitCount {
    if (!doc || query.length == 0 || hitCount <= 0) return @"";

    NSMutableArray<NSString*>* snippets = [NSMutableArray array];
    NSInteger observedMatches = 0;
    char err[512];
    spdf_text_lines lines;
    memset(&lines, 0, sizeof(lines));
    if (!spdf_extract_page_text_lines(doc, (int)page, &lines, err, sizeof(err))) return @"";

    for (int i = 0; i < lines.count; ++i) {
        if (snippets.count >= 3 && observedMatches >= hitCount) break;
        const char* rawLine = lines.items[i].text;
        if (!rawLine || !*rawLine) continue;
        NSString* line = [NSString stringWithUTF8String:rawLine] ?: @"";
        if (line.length == 0) continue;
        for (NSValue* value in [self rangesOfPaletteQuery:query inString:line limit:0]) {
            observedMatches++;
            if (snippets.count < 3) {
                NSRange snippetRange = [self paletteSnippetRangeInLine:line matchRange:value.rangeValue];
                NSString* snippet = snippetRange.length > 0 ? [line substringWithRange:snippetRange] : line;
                snippet = [snippet stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (snippet.length > 0) [snippets addObject:snippet];
            }
            if (snippets.count >= 3 && observedMatches >= hitCount) break;
        }
    }
    spdf_free_text_lines(&lines);

    if (snippets.count == 0) return @"";
    NSMutableString* context = [[snippets componentsJoinedByString:@" | "] mutableCopy];
    if (hitCount > (NSInteger)snippets.count) [context appendString:@" ..."];
    return context;
}

- (NSAttributedString*)paletteContextAttributedString:(NSString*)context query:(NSString*)query {
    NSString* text = context ?: @"";
    NSDictionary* baseAttributes = @{
        NSFontAttributeName : [NSFont systemFontOfSize:11.0],
        NSForegroundColorAttributeName : SPDFCollectionColor(@"secondary")
    };
    NSMutableAttributedString* attributed = [[NSMutableAttributedString alloc] initWithString:text
                                                                                   attributes:baseAttributes];
    NSDictionary* matchAttributes = @{
        NSFontAttributeName : [NSFont systemFontOfSize:11.0 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName : SPDFCollectionColor(@"text")
    };
    for (NSValue* value in [self rangesOfPaletteQuery:query inString:text limit:0])
        [attributed addAttributes:matchAttributes range:value.rangeValue];
    return attributed;
}

- (NSAttributedString*)paletteFindTitleAttributedStringForResult:(NSDictionary*)result {
    NSString* text = result[@"title"] ?: @"";
    NSDictionary* baseAttributes =
        @{NSFontAttributeName : [NSFont systemFontOfSize:13.0], NSForegroundColorAttributeName : SPDFCollectionColor(@"text")};
    NSMutableAttributedString* attributed = [[NSMutableAttributedString alloc] initWithString:text
                                                                                   attributes:baseAttributes];
    NSUInteger boldLength = [result[@"titleBoldLength"] respondsToSelector:@selector(unsignedIntegerValue)]
                                ? [result[@"titleBoldLength"] unsignedIntegerValue]
                                : 0;
    boldLength = MIN(boldLength, text.length);
    if (boldLength > 0) {
        [attributed addAttribute:NSFontAttributeName
                           value:[NSFont boldSystemFontOfSize:13.0]
                           range:NSMakeRange(0, boldLength)];
    }
    return attributed;
}

- (void)previousPage:(id)sender {
    (void)sender;
    if ([self isMarkdownActive]) {
        [self markdownPreviousPage];
        return;
    }
    if (!_doc || _pageIndex <= 0) return;
    // Drives the Go To menu's Previous Page (Option+Left) and the Cmd+Up /
    // Option+Left keyboard paths. Outside presentation mode, preserve zoom +
    // relative position via goToAdjacentPagePreservingRelativePosition:.
    // Presentation mode keeps align-top paging as before.
    if (_presentationMode)
        [self goToPage:_pageIndex - 1 preserveSinglePagePosition:NO];
    else
        [self goToAdjacentPagePreservingRelativePosition:-1];
}

- (void)nextPage:(id)sender {
    (void)sender;
    if ([self isMarkdownActive]) {
        [self markdownNextPage];
        return;
    }
    if (!_doc || _pageIndex + 1 >= spdf_page_count(_doc)) return;
    if (_presentationMode)
        [self goToPage:_pageIndex + 1 preserveSinglePagePosition:NO];
    else
        [self goToAdjacentPagePreservingRelativePosition:1];
}

- (void)firstPage:(id)sender {
    (void)sender;
    if ([self isMarkdownActive])
        [self markdownFirstPage];
    else if (_doc)
        [self goToPage:0 preserveSinglePagePosition:NO];
}

- (void)lastPage:(id)sender {
    (void)sender;
    if ([self isMarkdownActive])
        [self markdownLastPage];
    else if (_doc)
        [self goToPage:spdf_page_count(_doc) - 1 preserveSinglePagePosition:NO];
}

- (void)returnToPreviousTab:(id)sender {
    (void)sender;
    [self rememberActiveTabState];
    SPDFMacPreviousTabActivation* target = [self takePreviousTabActivationFromCurrent:[self selectedTab] openTabs:_tabs];
    if (!target) return;
    if (target.existingIndex >= 0) [self selectTabAtIndex:target.existingIndex];
    else if (target.tabToReopen) [self insertDraggedTab:target.tabToReopen atIndex:target.insertionIndex];
}

- (void)selectPreviousTab:(id)sender {
    (void)sender;
    if (_tabs.count < 2) return;
    NSInteger target = _selectedTabIndex - 1;
    if (target < 0) target = (NSInteger)_tabs.count - 1; // wrap to the last tab
    [self selectTabAtIndex:target];
}

- (void)selectNextTab:(id)sender {
    (void)sender;
    if (_tabs.count < 2) return;
    NSInteger target = _selectedTabIndex + 1;
    if (target >= (NSInteger)_tabs.count) target = 0; // wrap to the first tab
    [self selectTabAtIndex:target];
}

- (void)focusPageField:(id)sender {
    (void)sender;
    [_window makeFirstResponder:_pageField];
}

- (void)pageFieldChanged:(id)sender {
    (void)sender;
    if ([self isMarkdownActive]) {
        [self markdownGoToPage:_pageField.integerValue - 1];
        return;
    }
    if (!_doc) return;
    NSInteger requested = _pageField.integerValue - 1;
    NSInteger pageCount = spdf_page_count(_doc);
    requested = MAX(0, MIN(requested, pageCount - 1));
    [self goToPage:requested preserveSinglePagePosition:_presentationMode];
}

- (void)zoomIn:(id)sender {
    (void)sender;
    if ([self isMarkdownActive]) {
        [self markdownZoomByFactor:1.20];
        return;
    }
    [self zoomByFactor:1.20 centeredAtWindowPoint:[self visibleCenterWindowPoint]];
}

- (void)zoomOut:(id)sender {
    (void)sender;
    if ([self isMarkdownActive]) {
        [self markdownZoomByFactor:1.0 / 1.20];
        return;
    }
    [self zoomByFactor:1.0 / 1.20 centeredAtWindowPoint:[self visibleCenterWindowPoint]];
}

- (void)rememberCurrentZoomForCustomReturn {
    if (_fitMode == SPDFFitModeCustom && _zoom > 0) _rememberedCustomZoom = _zoom;
}

- (void)actualSize:(id)sender {
    (void)sender;
    if ([self isMarkdownActive]) {
        [self markdownApplyFitMode:SPDFFitModeActual];
        return;
    }
    if (!_doc) return;
    [self rememberCurrentZoomForCustomReturn];
    _fitMode = SPDFFitModeActual;
    [self renderDocumentAndScrollToPage:_pageIndex alignTop:NO];
    [self persistActiveState];
}

- (void)fitWidth:(id)sender {
    (void)sender;
    if ([self isMarkdownActive]) {
        [self markdownApplyFitMode:SPDFFitModeWidth];
        return;
    }
    if (!_doc) return;
    [self rememberCurrentZoomForCustomReturn];
    _fitMode = SPDFFitModeWidth;
    [self renderDocumentAndScrollToPage:_pageIndex alignTop:NO];
    [self persistActiveState];
}

- (void)fitHeight:(id)sender {
    (void)sender;
    if ([self isMarkdownActive]) {
        [self markdownApplyFitMode:SPDFFitModeHeight];
        return;
    }
    if (!_doc) return;
    [self rememberCurrentZoomForCustomReturn];
    _fitMode = SPDFFitModeHeight;
    [self renderDocumentAndScrollToPage:_pageIndex alignTop:YES];
    [self persistActiveState];
}

- (void)fitPage:(id)sender {
    (void)sender;
    if ([self isMarkdownActive]) {
        [self markdownApplyFitMode:SPDFFitModePage];
        return;
    }
    if (!_doc) return;
    [self rememberCurrentZoomForCustomReturn];
    _fitMode = SPDFFitModePage;
    [self renderDocumentAndScrollToPage:_pageIndex alignTop:YES];
    [self persistActiveState];
}

- (void)fitModePopupChanged:(id)sender {
    (void)sender;
    NSInteger selectedTag = _fitModePopup.selectedItem.tag;
    SPDFFitMode selected = (SPDFFitMode)MAX(0, MIN(4, selectedTag));
    if ([self isMarkdownActive]) {
        [self markdownApplyFitMode:selected];
    } else if (_doc) {
        if (selected == SPDFFitModeCustom)
            _zoom = MAX(kMinZoom, MIN(kMaxZoom, _rememberedCustomZoom > 0 ? _rememberedCustomZoom : _zoom));
        else
            [self rememberCurrentZoomForCustomReturn];
        _fitMode = selected;
        [self renderDocumentAndScrollToPage:_pageIndex alignTop:NO];
        [self persistActiveState];
    } else {
        _fitMode = selected;
    }
}

- (void)toggleSidebar:(id)sender {
    (void)sender;
    BOOL canShowSidebar = _sidebarModeControl != nil;
    if (!_sidebarVisible && !canShowSidebar) {
        [self syncToolbarState];
        [self updateControls];
        return;
    }
    _sidebarPreferredVisible = !_sidebarVisible;
    if (_sidebarPreferredVisible) [self prioritizeWorkspaceSidebar];
    [self rebuildSidebar];
    [self persistActiveState];
}

- (void)toggleSidebarMode:(SPDFSidebarMode)mode {
    if (![self hasActiveDocument]) return;
    BOOL hasItems = NO;
    if ([self isMarkdownActive]) {
        hasItems = mode == SPDFSidebarModeChapters ? [self markdownHasChapters]
                                                   : (mode == SPDFSidebarModeSearch && [self markdownHasSearchSidebar]);
    } else {
        hasItems = mode == SPDFSidebarModeChapters
                       ? _outline.count > 0
                       : (mode == SPDFSidebarModeComments ? _comments.count > 0 : [self hasSearchSidebar]);
    }
    if (!hasItems) return;
    BOOL sameVisibleMode = _sidebarVisible && _sidebarModeControl.spdf_selectedSidebarMode == mode;
    _sidebarPreferredVisible = !sameVisibleMode;
    if (_sidebarPreferredVisible) { [self prioritizeWorkspaceSidebar]; _sidebarModeControl.spdf_selectedSidebarMode = mode; }
    [self rememberSidebarWorkspaceMode]; [self rebuildSidebar];
    [self persistActiveState];
}

- (void)toggleChaptersPanel:(id)sender {
    (void)sender;
    [self toggleSidebarMode:SPDFSidebarModeChapters];
}

- (void)toggleCommentsPanel:(id)sender {
    (void)sender;
    [self toggleSidebarMode:SPDFSidebarModeComments];
}

- (void)toggleMinimap:(id)sender {
    (void)sender;
    _minimapPreferredVisible = !_minimapVisible;
    if (_minimapPreferredVisible) [self prioritizeWorkspaceMap];
    [self setMinimapActuallyVisible:_minimapPreferredVisible];
    [self persistActiveState];
}

- (BOOL)windowIsFullScreen {
    return (_window.styleMask & NSWindowStyleMaskFullScreen) != 0;
}

- (NSRect)presentationScreenFrame {
    NSScreen* screen = _window.screen ?: NSScreen.mainScreen;
    return screen ? screen.frame : _window.frame;
}

- (void)enterPresentationWindowChrome {
    if (_presentationUsingBorderlessWindow || !_window) return;
    if ([self windowIsFullScreen]) {
        [_window makeKeyAndOrderFront:nil];
        [_window makeMainWindow];
        [NSApp activateIgnoringOtherApps:YES];
        return;
    }

    _presentationPreviousWindowFrame = _window.frame;
    _presentationPreviousWindowStyleMask = _window.styleMask;
    _presentationPreviousWindowLevel = _window.level;
    _presentationPreviousCollectionBehavior = _window.collectionBehavior;
    _presentationPreviousTitleVisibility = _window.titleVisibility;
    _presentationPreviousTitlebarAppearsTransparent = _window.titlebarAppearsTransparent;
    _presentationPreviousMovable = _window.movable;
    _presentationPreviousMovableByWindowBackground = _window.movableByWindowBackground;
    _presentationPreviousHasShadow = _window.hasShadow;

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext* context) {
      context.duration = 0.0;
      _window.styleMask = NSWindowStyleMaskBorderless;
      _window.titleVisibility = NSWindowTitleHidden;
      _window.titlebarAppearsTransparent = YES;
      _window.movable = NO;
      _window.movableByWindowBackground = NO;
      _window.hasShadow = NO;
      _window.level = NSPopUpMenuWindowLevel;
      _window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                   NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorStationary;
      [_window setFrame:[self presentationScreenFrame] display:YES animate:NO];
    }];
    [_window makeKeyAndOrderFront:nil];
    [_window makeMainWindow];
    [NSApp activateIgnoringOtherApps:YES];
    _presentationUsingBorderlessWindow = YES;
}

- (void)restorePresentationWindowChrome {
    if (!_presentationUsingBorderlessWindow || !_window) return;

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext* context) {
      context.duration = 0.0;
      _window.level = _presentationPreviousWindowLevel;
      _window.collectionBehavior = _presentationPreviousCollectionBehavior;
      _window.styleMask = _presentationPreviousWindowStyleMask;
      _window.titleVisibility = _presentationPreviousTitleVisibility;
      _window.titlebarAppearsTransparent = _presentationPreviousTitlebarAppearsTransparent;
      _window.movable = _presentationPreviousMovable;
      _window.movableByWindowBackground = _presentationPreviousMovableByWindowBackground;
      _window.hasShadow = _presentationPreviousHasShadow;
      [_window setFrame:_presentationPreviousWindowFrame display:YES animate:NO];
    }];
    _presentationUsingBorderlessWindow = NO;
    [_window makeKeyAndOrderFront:nil];
    [_window makeMainWindow];
}

- (void)installPresentationEventMonitor {
    if (_presentationEventMonitor) return;
    __weak ShenzhenMacDelegate* weakSelf = self;
    NSEventMask mask = NSEventMaskKeyDown;
    if (!_presentationEventMonitor) {
        _presentationEventMonitor =
            [NSEvent addLocalMonitorForEventsMatchingMask:mask
                                                  handler:^NSEvent*(NSEvent* event) {
                                                    ShenzhenMacDelegate* strongSelf = weakSelf;
                                                    if (!strongSelf || !strongSelf->_presentationMode ||
                                                        ![strongSelf hasActiveDocument])
                                                        return event;
                                                    if (event.window && event.window != strongSelf->_window)
                                                        return event;

                                                    if ([strongSelf handlePresentationEvent:event]) return nil;

                                                    return event;
                                                  }];
    }
}

- (void)removePresentationEventMonitor {
    if (_presentationEventMonitor) {
        [NSEvent removeMonitor:_presentationEventMonitor];
        _presentationEventMonitor = nil;
    }
    if (_presentationGlobalEventMonitor) {
        [NSEvent removeMonitor:_presentationGlobalEventMonitor];
        _presentationGlobalEventMonitor = nil;
    }
}

- (void)applyPresentationChrome {
    BOOL presentation = _presentationMode;
    [self dismissTabHoverPanel];
    _tabStrip.hidden = presentation;
    _toolbar.hidden = presentation;
    _tabStripHeightConstraint.constant = presentation ? 0.0 : kTabStripHeight;
    _toolbarHeightConstraint.constant = presentation ? 0.0 : 36.0;
    [self syncWorkspaceChrome];
    _pageView.presentationMode = presentation;
    if ([self isMarkdownActive]) [self.activeMarkdownSession setPresentationMode:presentation];
    if (presentation) {
        _pageScrollView.hasVerticalScroller = NO;
        _pageScrollView.verticalScroller = nil;
        if (!_presentationOverlayView) {
            _presentationOverlayView = [[SPDFPresentationOverlayView alloc] initWithFrame:_window.contentView.bounds];
            _presentationOverlayView.reader = self;
            _presentationOverlayView.translatesAutoresizingMaskIntoConstraints = NO;
            _presentationOverlayView.wantsLayer = YES;
            _presentationOverlayView.layer.backgroundColor = NSColor.clearColor.CGColor;
            [_window.contentView addSubview:_presentationOverlayView positioned:NSWindowAbove relativeTo:nil];
            [NSLayoutConstraint activateConstraints:@[
                [_presentationOverlayView.leadingAnchor constraintEqualToAnchor:_window.contentView.leadingAnchor],
                [_presentationOverlayView.trailingAnchor constraintEqualToAnchor:_window.contentView.trailingAnchor],
                [_presentationOverlayView.topAnchor constraintEqualToAnchor:_window.contentView.topAnchor],
                [_presentationOverlayView.bottomAnchor constraintEqualToAnchor:_window.contentView.bottomAnchor],
            ]];
        }
        _presentationOverlayView.hidden = NO;
    } else {
        _pageScrollView.verticalScroller = _markerScroller;
        _pageScrollView.hasVerticalScroller = YES;
        _markerScroller.hidden = NO;
        [_presentationOverlayView removeFromSuperview];
        _presentationOverlayView = nil;
    }
    _pageScrollView.autohidesScrollers = presentation;
    if (presentation) {
        _pageScrollView.backgroundColor = NSColor.blackColor;
        _pageScrollView.contentView.backgroundColor = NSColor.blackColor;
    } else {
        [self applyReadingThemeToDocumentViewport];
    }
    [_window.contentView layoutSubtreeIfNeeded];
    if (presentation && _presentationOverlayView) [_window makeFirstResponder:_presentationOverlayView];
}

- (void)beginPresentationSleepActivityIfNeeded {
    if (_presentationSleepActivityToken) return;
    NSActivityOptions options =
        NSActivityIdleSystemSleepDisabled | NSActivityIdleDisplaySleepDisabled | NSActivityUserInitiated;
    _presentationSleepActivityToken =
        [[NSProcessInfo processInfo] beginActivityWithOptions:options reason:@"ShenzhenPDF presentation mode"];
}

- (void)endPresentationSleepActivity {
    if (!_presentationSleepActivityToken) return;
    [[NSProcessInfo processInfo] endActivity:_presentationSleepActivityToken];
    _presentationSleepActivityToken = nil;
}

- (void)enterPresentationMode:(id)sender {
    if (![self hasActiveDocument] || _presentationMode) return;

    BOOL markdown = [self isMarkdownActive];
    [self stopKeyboardScrollAnimation];
    [self rememberCurrentZoomForCustomReturn];
    _presentationPreviousFitMode = _fitMode;
    _presentationPreviousSidebarPreferredVisible = _sidebarPreferredVisible;
    _presentationPreviousMinimapPreferredVisible = _minimapPreferredVisible;
    _presentationEnteredFullScreen = NO;
    _presentationMode = YES;
    _lastPresentationEventTimestamp = 0;
    _lastPresentationEventType = (NSEventType)0;
    _lastPresentationEventKeyCode = -1;
    _lastPresentationEventButtonNumber = -1;

    [self enterPresentationWindowChrome];
    _sidebarPreferredVisible = NO;
    _minimapPreferredVisible = NO;
    _fitMode = SPDFFitModePage;
    if (!markdown) _pageView.currentPageIndex = _pageIndex;
    [self applyPresentationChrome];
    if (markdown) [self.activeMarkdownSession applyFitMode:SPDFMacMarkdownPageFitPage];
    [self rebuildSidebar];
    [self setMinimapActuallyVisible:NO];
    [self installPresentationEventMonitor];
    [NSApp activateIgnoringOtherApps:YES];
    [_window orderFrontRegardless];
    [_window makeKeyWindow];
    [_window makeMainWindow];
    [_window
        makeFirstResponder:_presentationOverlayView ?: (markdown ? self.activeMarkdownSession.rootView : _pageView)];
    if (markdown)
        [self.activeMarkdownSession goToPageAtIndex:_pageIndex];
    else
        [self renderDocumentAndScrollToPage:_pageIndex alignTop:YES];
    if (_preventSleepInPresentation) [self beginPresentationSleepActivityIfNeeded];
}

- (void)leavePresentationModeAndExitFullScreen:(BOOL)exitFullScreen sender:(id)sender {
    if (!_presentationMode) return;
    [self endPresentationSleepActivity];

    BOOL markdown = [self isMarkdownActive];
    BOOL shouldExitFullScreen = exitFullScreen && _presentationEnteredFullScreen && [self windowIsFullScreen];
    _presentationMode = NO;
    _presentationEnteredFullScreen = NO;
    [self removePresentationEventMonitor];
    _sidebarPreferredVisible = _presentationPreviousSidebarPreferredVisible;
    _minimapPreferredVisible = _presentationPreviousMinimapPreferredVisible;
    _fitMode = _presentationPreviousFitMode;
    if (!markdown) _pageView.currentPageIndex = _pageIndex;
    [self applyPresentationChrome];
    [self restorePresentationWindowChrome];
    [self rebuildSidebar];
    [self setMinimapActuallyVisible:_minimapPreferredVisible];
    if (markdown) {
        [self markdownApplyFitMode:_presentationPreviousFitMode];
        [self.activeMarkdownSession goToPageAtIndex:_pageIndex];
    } else if (_doc)
        [self renderDocumentAndScrollToPage:_pageIndex alignTop:NO];
    [self persistActiveState];
    if (shouldExitFullScreen) [_window toggleFullScreen:sender];
}

- (void)togglePresentation:(id)sender {
    if (_presentationMode)
        [self leavePresentationModeAndExitFullScreen:YES sender:sender];
    else
        [self enterPresentationMode:sender];
}

- (void)toggleFullScreen:(id)sender {
    if (_presentationMode)
        [self leavePresentationModeAndExitFullScreen:YES sender:sender];
    else
        [_window toggleFullScreen:sender];
}

- (void)performWindowArrangementAction:(SEL)action sender:(id)sender {
    if (action == @selector(fillWindow:))
        [self fillWindow:sender];
    else if (action == @selector(centerWindowInScreen:))
        [self centerWindowInScreen:sender];
    else if (action == @selector(moveWindowToLeftHalf:))
        [self moveWindowToLeftHalf:sender];
    else if (action == @selector(moveWindowToRightHalf:))
        [self moveWindowToRightHalf:sender];
    else if (action == @selector(moveWindowToTopHalf:))
        [self moveWindowToTopHalf:sender];
    else if (action == @selector(moveWindowToBottomHalf:))
        [self moveWindowToBottomHalf:sender];
}

- (void)drainPendingWindowArrangementAction {
    if (_pendingWindowArrangementAction == NULL || [self windowIsFullScreen]) return;
    SEL action = _pendingWindowArrangementAction;
    _pendingWindowArrangementAction = NULL;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!self->_window || self->_presentationMode || [self windowIsFullScreen]) return;
      [self performWindowArrangementAction:action sender:nil];
    });
}

- (BOOL)deferWindowArrangementActionIfNeeded:(SEL)action sender:(id)sender {
    if (!_window || _presentationMode) return YES;
    if (![self windowIsFullScreen]) return NO;

    BOOL alreadyWaitingForExit = _pendingWindowArrangementAction != NULL;
    _pendingWindowArrangementAction = action;
    if (!alreadyWaitingForExit) [_window toggleFullScreen:sender];
    return YES;
}

- (BOOL)firstResponderIsEditingText {
    if (!_window) return NO;
    NSResponder* responder = _window.firstResponder;
    if (!responder) return NO;
    if ([responder isKindOfClass:NSText.class] || [responder isKindOfClass:NSTextView.class]) return YES;
    if ([responder isKindOfClass:NSControl.class] && [(NSControl*)responder currentEditor]) return YES;
    return NO;
}

- (BOOL)handleWindowArrangementShortcutEvent:(NSEvent*)event {
    if (!_window || _presentationMode) return NO;
    SPDFWindowArrangementShortcut shortcut = spdf_window_arrangement_shortcut_for_event(event);
    if (shortcut == SPDFWindowArrangementShortcutNone) return NO;
    if ([self firstResponderIsEditingText]) return NO;
    SEL action = spdf_window_arrangement_selector_for_shortcut(shortcut);

    if (action == NULL) return NO;
    [self performWindowArrangementAction:action sender:nil];
    return YES;
}

- (void)installWindowArrangementShortcutMonitor {
    if (_windowArrangementShortcutMonitor) return;
    __weak ShenzhenMacDelegate* weakSelf = self;
    _windowArrangementShortcutMonitor = [NSEvent
        addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                     handler:^NSEvent*(NSEvent* event) {
                                       ShenzhenMacDelegate* strongSelf = weakSelf;
                                       if (!strongSelf || !strongSelf->_window) return event;
                                       if (event.window && event.window != strongSelf->_window) return event;
                                       if (!event.window && !strongSelf->_window.isKeyWindow) return event;
                                       return [strongSelf handleWindowArrangementShortcutEvent:event] ? nil : event;
                                     }];
}

- (void)removeWindowArrangementShortcutMonitor {
    if (!_windowArrangementShortcutMonitor) return;
    [NSEvent removeMonitor:_windowArrangementShortcutMonitor];
    _windowArrangementShortcutMonitor = nil;
}

- (void)menuNeedsUpdate:(NSMenu*)menu {
    if (menu == _recentlyOpenedMenu) [self rebuildRecentlyOpenedMenu];
}

- (void)menuWillOpen:(NSMenu*)menu {
    if (menu != _windowMenu || !_window || _windowMenuTemporarilyEnabledMovable) return;
    _windowMenuPreviousMovable = _window.movable;
    _window.movable = YES;
    _windowMenuTemporarilyEnabledMovable = YES;
}

- (void)menuDidClose:(NSMenu*)menu {
    if (menu != _windowMenu || !_windowMenuTemporarilyEnabledMovable) return;
    if (_window) _window.movable = _windowMenuPreviousMovable;
    _windowMenuTemporarilyEnabledMovable = NO;
}

- (NSRect)visibleFrameForWindowActions {
    NSScreen* screen = _window.screen ?: NSScreen.mainScreen;
    return screen ? screen.visibleFrame : NSMakeRect(0, 0, 1120, 800);
}

- (void)setWindowFrameForWindowAction:(NSRect)frame {
    if (!_window || _presentationMode || [self windowIsFullScreen]) return;
    [_window setFrame:frame display:YES animate:YES];
    [self savePersistentState];
}

- (void)fillWindow:(id)sender {
    if ([self deferWindowArrangementActionIfNeeded:_cmd sender:sender]) return;
    [self setWindowFrameForWindowAction:[self visibleFrameForWindowActions]];
}

- (void)centerWindowInScreen:(id)sender {
    if ([self deferWindowArrangementActionIfNeeded:_cmd sender:sender]) return;
    NSRect visible = [self visibleFrameForWindowActions];
    NSRect frame = _window.frame;
    frame.size.width = MIN(NSWidth(frame), NSWidth(visible));
    frame.size.height = MIN(NSHeight(frame), NSHeight(visible));
    frame.origin.x = floor(NSMidX(visible) - NSWidth(frame) * 0.5);
    frame.origin.y = floor(NSMidY(visible) - NSHeight(frame) * 0.5);
    [self setWindowFrameForWindowAction:frame];
}

- (void)moveWindowToLeftHalf:(id)sender {
    if ([self deferWindowArrangementActionIfNeeded:_cmd sender:sender]) return;
    NSRect visible = [self visibleFrameForWindowActions];
    [self setWindowFrameForWindowAction:NSMakeRect(NSMinX(visible), NSMinY(visible), floor(NSWidth(visible) * 0.5),
                                                   NSHeight(visible))];
}

- (void)moveWindowToRightHalf:(id)sender {
    if ([self deferWindowArrangementActionIfNeeded:_cmd sender:sender]) return;
    NSRect visible = [self visibleFrameForWindowActions];
    CGFloat width = floor(NSWidth(visible) * 0.5);
    [self setWindowFrameForWindowAction:NSMakeRect(NSMaxX(visible) - width, NSMinY(visible), width, NSHeight(visible))];
}

- (void)moveWindowToTopHalf:(id)sender {
    if ([self deferWindowArrangementActionIfNeeded:_cmd sender:sender]) return;
    NSRect visible = [self visibleFrameForWindowActions];
    CGFloat height = floor(NSHeight(visible) * 0.5);
    [self
        setWindowFrameForWindowAction:NSMakeRect(NSMinX(visible), NSMaxY(visible) - height, NSWidth(visible), height)];
}

- (void)moveWindowToBottomHalf:(id)sender {
    if ([self deferWindowArrangementActionIfNeeded:_cmd sender:sender]) return;
    NSRect visible = [self visibleFrameForWindowActions];
    CGFloat height = floor(NSHeight(visible) * 0.5);
    [self setWindowFrameForWindowAction:NSMakeRect(NSMinX(visible), NSMinY(visible), NSWidth(visible), height)];
}

- (NSString*)ocrToolPath {
    return [self executablePathForTool:@"ocrmypdf"
                            candidates:@[
                                @"/opt/homebrew/bin/ocrmypdf", @"/usr/local/bin/ocrmypdf", @"/opt/local/bin/ocrmypdf",
                                @"/usr/bin/ocrmypdf"
                            ]];
}

- (NSString*)tesseractToolPath {
    return [self executablePathForTool:@"tesseract"
                            candidates:@[
                                @"/opt/homebrew/bin/tesseract", @"/usr/local/bin/tesseract",
                                @"/opt/local/bin/tesseract", @"/usr/bin/tesseract"
                            ]];
}

- (NSString*)argosToolPath {
    NSString* userPath = [NSHomeDirectory() stringByAppendingPathComponent:@".local/bin/argos-translate"];
    return [self
        executablePathForTool:@"argos-translate"
                   candidates:@[ @"/opt/homebrew/bin/argos-translate", @"/usr/local/bin/argos-translate", userPath ]];
}

- (NSString*)argospmToolPath {
    NSString* userPath = [NSHomeDirectory() stringByAppendingPathComponent:@".local/bin/argospm"];
    return [self executablePathForTool:@"argospm"
                            candidates:@[ @"/opt/homebrew/bin/argospm", @"/usr/local/bin/argospm", userPath ]];
}

- (NSString*)executablePathForTool:(NSString*)tool candidates:(NSArray<NSString*>*)candidates {
    NSFileManager* fm = NSFileManager.defaultManager;
    // The app's own virtualenv is tried before anything on PATH: it is the one
    // install whose Python cannot be a different machine's (SPDFMacToolEnvironment.h).
    for (NSString* path in spdf_mac_tool_candidate_paths(tool, candidates))
        if ([fm isExecutableFileAtPath:path]) return path;

    NSString* pathEnv = NSProcessInfo.processInfo.environment[@"PATH"] ?: @"";
    for (NSString* dir in [pathEnv componentsSeparatedByString:@":"]) {
        if (dir.length == 0) continue;
        NSString* path = [dir stringByAppendingPathComponent:tool];
        if ([fm isExecutableFileAtPath:path]) return path;
    }
    return nil;
}

- (NSString*)argosInstallScript {
    return spdf_mac_tool_argos_install_script();
}

- (void)showTranslationProgressWithTitle:(NSString*)title totalUnits:(double)totalUnits {
    if (!_translationProgressPanel) {
        _translationProgressPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 460, 156)
                                                               styleMask:NSWindowStyleMaskTitled
                                                                 backing:NSBackingStoreBuffered
                                                                   defer:NO];
        _translationProgressPanel.releasedWhenClosed = NO;

        NSView* content = [[NSView alloc] initWithFrame:_translationProgressPanel.contentView.bounds];
        content.translatesAutoresizingMaskIntoConstraints = NO;
        _translationProgressPanel.contentView = content;

        _translationProgressTitleLabel = [NSTextField labelWithString:@""];
        _translationProgressTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _translationProgressTitleLabel.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
        [content addSubview:_translationProgressTitleLabel];

        _translationProgressDetailLabel = [NSTextField labelWithString:@""];
        _translationProgressDetailLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _translationProgressDetailLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [content addSubview:_translationProgressDetailLabel];

        _translationProgressIndicator = [[NSProgressIndicator alloc] init];
        _translationProgressIndicator.translatesAutoresizingMaskIntoConstraints = NO;
        _translationProgressIndicator.style = NSProgressIndicatorStyleBar;
        _translationProgressIndicator.indeterminate = NO;
        _translationProgressIndicator.minValue = 0.0;
        [content addSubview:_translationProgressIndicator];

        _translationProgressCancelButton = [NSButton buttonWithTitle:@"Cancel"
                                                              target:self
                                                              action:@selector(cancelTranslation:)];
        _translationProgressCancelButton.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:_translationProgressCancelButton];

        [NSLayoutConstraint activateConstraints:@[
            [_translationProgressTitleLabel.topAnchor constraintEqualToAnchor:content.topAnchor constant:16],
            [_translationProgressTitleLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:18],
            [_translationProgressTitleLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-18],
            [_translationProgressDetailLabel.topAnchor
                constraintEqualToAnchor:_translationProgressTitleLabel.bottomAnchor
                               constant:8],
            [_translationProgressDetailLabel.leadingAnchor
                constraintEqualToAnchor:_translationProgressTitleLabel.leadingAnchor],
            [_translationProgressDetailLabel.trailingAnchor
                constraintEqualToAnchor:_translationProgressTitleLabel.trailingAnchor],
            [_translationProgressIndicator.topAnchor
                constraintEqualToAnchor:_translationProgressDetailLabel.bottomAnchor
                               constant:14],
            [_translationProgressIndicator.leadingAnchor
                constraintEqualToAnchor:_translationProgressTitleLabel.leadingAnchor],
            [_translationProgressIndicator.trailingAnchor
                constraintEqualToAnchor:_translationProgressTitleLabel.trailingAnchor],
            [_translationProgressCancelButton.topAnchor
                constraintEqualToAnchor:_translationProgressIndicator.bottomAnchor
                               constant:16],
            [_translationProgressCancelButton.trailingAnchor
                constraintEqualToAnchor:_translationProgressTitleLabel.trailingAnchor]
        ]];
    }

    _translationProgressPanel.title = @"Translating";
    _translationProgressTitleLabel.stringValue = title.length ? title : @"Translating with Argos";
    _translationProgressDetailLabel.stringValue = @"Preparing text...";
    _translationProgressIndicator.indeterminate = totalUnits <= 0.0;
    _translationProgressIndicator.minValue = 0.0;
    _translationProgressIndicator.maxValue = MAX(1.0, totalUnits);
    _translationProgressIndicator.doubleValue = 0.0;
    _translationProgressCancelButton.enabled = YES;
    if (_translationProgressIndicator.indeterminate)
        [_translationProgressIndicator startAnimation:nil];
    else
        [_translationProgressIndicator stopAnimation:nil];
    [_translationProgressPanel center];
    [_translationProgressPanel makeKeyAndOrderFront:nil];
}

- (void)updateTranslationProgress:(double)value detail:(NSString*)detail {
    if (!_translationProgressPanel) return;
    if (!_translationProgressIndicator.indeterminate)
        _translationProgressIndicator.doubleValue =
            spdf_clamp_cg(value, _translationProgressIndicator.minValue, _translationProgressIndicator.maxValue);
    if (detail.length) {
        _translationProgressDetailLabel.stringValue = detail;
        _statusLabel.stringValue = detail;
    }
}

- (void)finishTranslationProgressWithDetail:(NSString*)detail keepVisible:(BOOL)keepVisible {
    @synchronized(self) {
        _translationTask = nil;
    }
    [_translationProgressIndicator stopAnimation:nil];
    _translationProgressCancelButton.enabled = NO;
    if (detail.length) _translationProgressDetailLabel.stringValue = detail;
    if (!keepVisible) [_translationProgressPanel orderOut:nil];
}

- (void)cancelTranslation:(id)sender {
    (void)sender;
    _translationCancelRequested = YES;
    _translationProgressCancelButton.enabled = NO;
    _translationProgressDetailLabel.stringValue = @"Canceling translation...";
    _statusLabel.stringValue = @"Canceling translation...";
    @synchronized(self) {
        [_translationTask terminate];
    }
}

static NSString* SPDFLastMeaningfulOCRLine(NSString* text) {
    if (!text.length) return @"";
    NSArray<NSString*>* lines = [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    for (NSString* line in lines.reverseObjectEnumerator) {
        NSString* trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length > 0) return trimmed;
    }
    return @"";
}

- (void)showOCRProgressWithDetail:(NSString*)detail {
    if (!_ocrProgressPanel) {
        _ocrProgressPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 460, 132)
                                                       styleMask:NSWindowStyleMaskTitled
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];
        _ocrProgressPanel.releasedWhenClosed = NO;

        NSView* content = [[NSView alloc] initWithFrame:_ocrProgressPanel.contentView.bounds];
        content.translatesAutoresizingMaskIntoConstraints = NO;
        _ocrProgressPanel.contentView = content;

        _ocrProgressTitleLabel = [NSTextField labelWithString:@""];
        _ocrProgressTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _ocrProgressTitleLabel.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
        [content addSubview:_ocrProgressTitleLabel];

        _ocrProgressDetailLabel = [NSTextField labelWithString:@""];
        _ocrProgressDetailLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _ocrProgressDetailLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [content addSubview:_ocrProgressDetailLabel];

        _ocrProgressIndicator = [[NSProgressIndicator alloc] init];
        _ocrProgressIndicator.translatesAutoresizingMaskIntoConstraints = NO;
        _ocrProgressIndicator.style = NSProgressIndicatorStyleBar;
        _ocrProgressIndicator.indeterminate = YES;
        [content addSubview:_ocrProgressIndicator];

        [NSLayoutConstraint activateConstraints:@[
            [_ocrProgressTitleLabel.topAnchor constraintEqualToAnchor:content.topAnchor constant:16],
            [_ocrProgressTitleLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:18],
            [_ocrProgressTitleLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-18],
            [_ocrProgressDetailLabel.topAnchor constraintEqualToAnchor:_ocrProgressTitleLabel.bottomAnchor constant:8],
            [_ocrProgressDetailLabel.leadingAnchor constraintEqualToAnchor:_ocrProgressTitleLabel.leadingAnchor],
            [_ocrProgressDetailLabel.trailingAnchor constraintEqualToAnchor:_ocrProgressTitleLabel.trailingAnchor],
            [_ocrProgressIndicator.topAnchor constraintEqualToAnchor:_ocrProgressDetailLabel.bottomAnchor constant:14],
            [_ocrProgressIndicator.leadingAnchor constraintEqualToAnchor:_ocrProgressTitleLabel.leadingAnchor],
            [_ocrProgressIndicator.trailingAnchor constraintEqualToAnchor:_ocrProgressTitleLabel.trailingAnchor]
        ]];
    }

    _ocrProgressPanel.title = @"OCR";
    _ocrProgressTitleLabel.stringValue = @"Running OCR";
    _ocrProgressDetailLabel.stringValue = detail.length ? detail : @"Preparing OCR...";
    [_ocrProgressIndicator startAnimation:nil];
    [_ocrProgressPanel center];
    [_ocrProgressPanel makeKeyAndOrderFront:nil];
}

- (void)updateOCRProgressDetail:(NSString*)detail {
    if (!_ocrProgressPanel || !detail.length) return;
    _ocrProgressDetailLabel.stringValue = detail;
    _statusLabel.stringValue = detail;
}

- (void)finishOCRProgressWithDetail:(NSString*)detail {
    [_ocrProgressIndicator stopAnimation:nil];
    if (detail.length) _ocrProgressDetailLabel.stringValue = detail;
    [_ocrProgressPanel orderOut:nil];
}

- (void)appendTranslationInstallLog:(NSString*)text {
    if (!_translationInstallLog || text.length == 0) return;
    NSTextStorage* storage = _translationInstallLog.textStorage;
    NSDictionary* attrs = @{
        NSForegroundColorAttributeName : SPDFCollectionColor(@"text"),
        NSFontAttributeName : _translationInstallLog.font
            ?: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular]
    };
    [storage appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:attrs]];
    [_translationInstallLog scrollRangeToVisible:NSMakeRange(storage.length, 0)];
}

- (void)showTranslationInstallPanelWithTitle:(NSString*)title heading:(NSString*)heading {
    if (!_translationInstallPanel) {
        _translationInstallPanel =
            [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 640, 360)
                                       styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                         backing:NSBackingStoreBuffered
                                           defer:NO];
        _translationInstallPanel.releasedWhenClosed = NO;

        NSView* content = [[NSView alloc] initWithFrame:_translationInstallPanel.contentView.bounds];
        content.translatesAutoresizingMaskIntoConstraints = NO;
        _translationInstallPanel.contentView = content;

        _translationInstallTitleLabel = [NSTextField labelWithString:@""];
        _translationInstallTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _translationInstallTitleLabel.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
        [content addSubview:_translationInstallTitleLabel];

        _translationInstallProgress = [[NSProgressIndicator alloc] init];
        _translationInstallProgress.translatesAutoresizingMaskIntoConstraints = NO;
        _translationInstallProgress.indeterminate = YES;
        _translationInstallProgress.style = NSProgressIndicatorStyleBar;
        [content addSubview:_translationInstallProgress];

        NSScrollView* scroll = [[NSScrollView alloc] init];
        scroll.translatesAutoresizingMaskIntoConstraints = NO;
        scroll.hasVerticalScroller = YES;
        [content addSubview:scroll];

        _translationInstallLog = [[NSTextView alloc] init];
        _translationInstallLog.editable = NO;
        _translationInstallLog.selectable = YES;
        _translationInstallLog.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
        _translationInstallLog.drawsBackground = YES;
        _translationInstallLog.backgroundColor = SPDFCollectionColor(@"window");
        _translationInstallLog.textColor = SPDFCollectionColor(@"text");
        scroll.documentView = _translationInstallLog;

        [NSLayoutConstraint activateConstraints:@[
            [_translationInstallTitleLabel.topAnchor constraintEqualToAnchor:content.topAnchor constant:14],
            [_translationInstallTitleLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14],
            [_translationInstallTitleLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-14],
            [_translationInstallProgress.topAnchor constraintEqualToAnchor:_translationInstallTitleLabel.bottomAnchor
                                                                  constant:10],
            [_translationInstallProgress.leadingAnchor
                constraintEqualToAnchor:_translationInstallTitleLabel.leadingAnchor],
            [_translationInstallProgress.trailingAnchor
                constraintEqualToAnchor:_translationInstallTitleLabel.trailingAnchor],
            [scroll.topAnchor constraintEqualToAnchor:_translationInstallProgress.bottomAnchor constant:12],
            [scroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14],
            [scroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-14],
            [scroll.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-14]
        ]];
    }

    _translationInstallPanel.title = title.length ? title : @"Installing Translation Support";
    _translationInstallTitleLabel.stringValue = heading.length ? heading : @"Installing Argos Translate";
    [_translationInstallPanel center];
    [_translationInstallPanel makeKeyAndOrderFront:nil];
    [_translationInstallProgress startAnimation:nil];
}

- (void)runTranslationInstallTask:(NSTask*)task
                            title:(NSString*)title
                          heading:(NSString*)heading
                       initialLog:(NSString*)initialLog
                       completion:(void (^)(NSTask* finishedTask, NSString* output))completion {
    if (_translationInstallRunning) {
        [_translationInstallPanel makeKeyAndOrderFront:nil];
        return;
    }

    _translationInstallRunning = YES;
    _translateButton.enabled = NO;
    _statusLabel.stringValue = title.length ? title : @"Installing translation support...";
    [self showTranslationInstallPanelWithTitle:title heading:heading];
    _translationInstallLog.string = @"";
    [self appendTranslationInstallLog:initialLog.length ? initialLog : @"Preparing translation installer...\n"];

    NSPipe* pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    _translationInstallTask = task;
    __block NSMutableData* outputData = [NSMutableData data];
    void (^completionCopy)(NSTask*, NSString*) = [completion copy];
    __weak ShenzhenMacDelegate* weakSelf = self;

    pipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle* handle) {
      NSData* chunk = handle.availableData;
      if (chunk.length == 0) {
          handle.readabilityHandler = nil;
          return;
      }
      @synchronized(outputData) {
          [outputData appendData:chunk];
      }
      NSString* text = [[NSString alloc] initWithData:chunk encoding:NSUTF8StringEncoding] ?: @"";
      dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf appendTranslationInstallLog:text];
      });
    };

    task.terminationHandler = ^(NSTask* finishedTask) {
      pipe.fileHandleForReading.readabilityHandler = nil;
      NSData* tail = pipe.fileHandleForReading.readDataToEndOfFile;
      if (tail.length > 0) {
          @synchronized(outputData) {
              [outputData appendData:tail];
          }
      }
      NSData* data = nil;
      @synchronized(outputData) {
          data = [outputData copy];
      }
      NSString* output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
      dispatch_async(dispatch_get_main_queue(), ^{
        ShenzhenMacDelegate* strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_translationInstallRunning = NO;
        strongSelf->_translationInstallTask = nil;
        [strongSelf->_translationInstallProgress stopAnimation:nil];
        [strongSelf updateTranslateCommandEnablement];
        if (completionCopy) completionCopy(finishedTask, output);
      });
    };

    NSError* launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        _translationInstallRunning = NO;
        _translationInstallTask = nil;
        [_translationInstallProgress stopAnimation:nil];
        [self updateTranslateCommandEnablement];
        NSString* detail = launchError.localizedDescription ?: @"Could not start installer.";
        [self appendTranslationInstallLog:[NSString stringWithFormat:@"\n%@\n", detail]];
        _statusLabel.stringValue = @"Translation installer could not start.";
    }
}

- (void)runArgosPackageInstallFromLanguage:(NSString*)sourceLanguage
                                toLanguage:(NSString*)targetLanguage
                                sourceText:(NSString*)sourceText
                                outputPath:(NSString*)outputPath {
    NSString* packageTool = [self argospmToolPath];
    if (!packageTool.length) {
        [self showError:@"Argos package manager not found"
                 detail:@"Install Argos Translate and the required offline "
                        @"language package, then try again."];
        return;
    }

    NSString* packageName = [NSString stringWithFormat:@"translate-%@_%@", sourceLanguage, targetLanguage];
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"Install Argos language package?";
    alert.informativeText = [NSString stringWithFormat:@"The offline %@ to %@ package may be "
                                                       @"missing. Shenzhen PDF can ask argospm to "
                                                       @"install %@, then continue translation.",
                                                       sourceLanguage, targetLanguage, packageName];
    [alert addButtonWithTitle:@"Install"];
    [alert addButtonWithTitle:@"Cancel"];
    alert.alertStyle = NSAlertStyleInformational;
    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    NSTask* task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:packageTool];
    task.arguments = @[ @"install", packageName ];
    task.environment = [self taskEnvironmentWithToolPaths:@[ packageTool ]];

    __weak ShenzhenMacDelegate* weakSelf = self;
    [self runTranslationInstallTask:task
                              title:@"Installing Translation Package"
                            heading:[NSString stringWithFormat:@"Installing %@", packageName]
                         initialLog:[NSString stringWithFormat:@"Running argospm install %@...\n", packageName]
                         completion:^(NSTask* finishedTask, NSString* output) {
                           ShenzhenMacDelegate* strongSelf = weakSelf;
                           if (!strongSelf) return;
                           strongSelf->_translationInstallRunning = NO;
                           [strongSelf updateTranslateCommandEnablement];
                           if (finishedTask.terminationStatus == 0) {
                               [strongSelf appendTranslationInstallLog:@"\nArgos language package installed.\n"];
                               [strongSelf->_translationInstallPanel orderOut:nil];
                               [strongSelf runArgosTranslationWithTool:[strongSelf argosToolPath]
                                                            sourceText:sourceText
                                                        sourceLanguage:sourceLanguage
                                                        targetLanguage:targetLanguage
                                                            outputPath:outputPath
                                                      offeredInstaller:YES];
                           } else {
                               (void)output;
                               [strongSelf appendTranslationInstallLog:
                                               @"\nArgos language package installation failed. The log above can be "
                                               @"selected and copied.\n"];
                               strongSelf->_statusLabel.stringValue = @"Translation package installation failed.";
                           }
                         }];
}

static BOOL SPDFIsArgosDiagnosticLine(NSString* line, BOOL previousLineWasDiagnostic) {
    NSString* trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([trimmed rangeOfString:@"WARNING: Language "].location != NSNotFound &&
        [trimmed rangeOfString:@" package "].location != NSNotFound &&
        [trimmed rangeOfString:@" expects "].location != NSNotFound) {
        return YES;
    }
    if (previousLineWasDiagnostic &&
        ([trimmed isEqualToString:@"added"] || [trimmed hasPrefix:@"which has been added"])) {
        return YES;
    }
    return NO;
}

static NSString* SPDFStringByRemovingArgosDiagnostics(NSString* output) {
    if (!output.length) return output ?: @"";
    NSArray<NSString*>* lines = [output componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    NSMutableArray<NSString*>* kept = [NSMutableArray arrayWithCapacity:lines.count];
    BOOL previousLineWasDiagnostic = NO;
    BOOL removedAny = NO;
    for (NSString* line in lines) {
        BOOL diagnostic = SPDFIsArgosDiagnosticLine(line, previousLineWasDiagnostic);
        if (diagnostic) {
            previousLineWasDiagnostic = YES;
            removedAny = YES;
            continue;
        }
        previousLineWasDiagnostic = NO;
        [kept addObject:line];
    }
    if (!removedAny) return output;
    return [kept componentsJoinedByString:@"\n"];
}

// Human-readable scope of a translation batch for progress and error text:
// "page 3" / "pages 3-5" for body blocks, and naming chapters/comments when
// the batch (also) carries outline-title or comment items.
static NSString* SPDFTranslationBatchScope(NSArray<NSDictionary*>* items, NSUInteger start, NSUInteger end) {
    BOOL hasOutline = NO;
    BOOL hasComment = NO;
    NSInteger firstPage = -1;
    NSInteger lastPage = -1;
    for (NSUInteger i = start; i < end && i < items.count; ++i) {
        NSString* kind = items[i][@"kind"];
        if ([kind isEqualToString:@"outline"]) {
            hasOutline = YES;
        } else if ([kind isEqualToString:@"comment"]) {
            hasComment = YES;
        } else {
            NSInteger page = [items[i][@"page"] integerValue];
            if (firstPage < 0) firstPage = page;
            lastPage = page;
        }
    }
    NSString* pages = nil;
    if (firstPage >= 0) {
        pages = firstPage == lastPage
                    ? [NSString stringWithFormat:@"page %ld", (long)firstPage + 1]
                    : [NSString stringWithFormat:@"pages %ld-%ld", (long)firstPage + 1, (long)lastPage + 1];
    }
    NSString* extras = nil;
    if (hasOutline && hasComment)
        extras = @"chapters and comments";
    else if (hasOutline)
        extras = @"chapter titles";
    else if (hasComment)
        extras = @"comments";
    if (pages && extras) return [NSString stringWithFormat:@"%@ and %@", pages, extras];
    return pages ?: extras ?: @"text";
}

- (BOOL)runArgosToolSynchronously:(NSString*)tool
                   sourceLanguage:(NSString*)sourceLanguage
                   targetLanguage:(NSString*)targetLanguage
                            input:(NSString*)input
                           output:(NSString**)outputOut
                            error:(NSString**)errorOut {
    if (outputOut) *outputOut = nil;
    if (errorOut) *errorOut = nil;
    if (_translationCancelRequested) {
        if (errorOut) *errorOut = @"Translation canceled.";
        return NO;
    }
    NSTask* task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:tool];
    task.arguments = @[ @"--from-lang", sourceLanguage, @"--to-lang", targetLanguage ];
    task.environment = [self taskEnvironmentWithToolPaths:@[ tool ]];
    NSPipe* inputPipe = [NSPipe pipe];
    NSPipe* outputPipe = [NSPipe pipe];
    NSPipe* errorPipe = [NSPipe pipe];
    task.standardInput = inputPipe;
    task.standardOutput = outputPipe;
    task.standardError = errorPipe;

    NSError* launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        if (errorOut) *errorOut = launchError.localizedDescription ?: @"Could not start Argos Translate.";
        return NO;
    }
    @synchronized(self) {
        _translationTask = task;
    }

    NSData* inputData = [input dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    @try {
        [inputPipe.fileHandleForWriting writeData:inputData];
    } @catch (NSException* exception) {
        (void)exception;
    }
    [inputPipe.fileHandleForWriting closeFile];

    __block NSData* errorData = nil;
    dispatch_group_t readGroup = dispatch_group_create();
    dispatch_group_enter(readGroup);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      errorData = [errorPipe.fileHandleForReading readDataToEndOfFile];
      dispatch_group_leave(readGroup);
    });
    NSData* outputData = [outputPipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    dispatch_group_wait(readGroup, DISPATCH_TIME_FOREVER);
    @synchronized(self) {
        if (_translationTask == task) _translationTask = nil;
    }
    NSString* output = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding] ?: @"";
    NSString* errorOutput = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding] ?: @"";
    if (_translationCancelRequested) {
        if (errorOut) *errorOut = @"Translation canceled.";
        return NO;
    }
    if (task.terminationStatus != 0) {
        NSString* failure = errorOutput.length ? errorOutput : output;
        if (errorOut) *errorOut = failure.length ? failure : @"Argos Translate exited with an error.";
        return NO;
    }
    output = SPDFStringByRemovingArgosDiagnostics(output);
    if (outputOut) *outputOut = output;
    return YES;
}

- (void)runArgosTranslationWithTool:(NSString*)tool
                         sourceText:(NSString*)sourceText
                     sourceLanguage:(NSString*)sourceLanguage
                     targetLanguage:(NSString*)targetLanguage
                         outputPath:(NSString*)outputPath
                   offeredInstaller:(BOOL)offeredInstaller {
    if (!tool.length || (!spdf_mac_tool_venv_has_tool(@"argos-translate") &&
                         !spdf_mac_tool_install_attempted())) {
        [self promptToInstallArgosAndContinueWithSourceText:sourceText
                                             sourceLanguage:sourceLanguage
                                             targetLanguage:targetLanguage
                                                 outputPath:outputPath];
        return;
    }

    _translationRunning = YES;
    _translationCancelRequested = NO;
    _translateButton.enabled = NO;
    _statusLabel.stringValue = @"Translating with Argos...";
    NSString* besidePath = [_path copy];
    // A Markdown, text or EPUB document was translated as a PDF made from it: said so when it is done.
    BOOL fromRendition = _translatingMadePDF;

    NSArray<NSDictionary*>* items = [_pendingTranslationItems copy] ?: @[];
    NSUInteger totalUnits = MAX((NSUInteger)1, items.count);
    [self showTranslationProgressWithTitle:@"Translating with Argos" totalUnits:(double)totalUnits];
    [self updateTranslationProgress:0.0 detail:@"Preparing translation..."];
    NSArray<NSString*>* sourceLines =
        [sourceText componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    __weak ShenzhenMacDelegate* weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      NSMutableArray<NSString*>* translatedLines = [NSMutableArray arrayWithCapacity:MAX((NSUInteger)1, items.count)];
      for (NSUInteger i = 0; i < MAX((NSUInteger)1, items.count); ++i) [translatedLines addObject:@""];
      NSString* failure = nil;

      if (items.count <= 1) {
          NSString* translated = nil;
          dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf updateTranslationProgress:0.0 detail:@"Translating selected text..."];
          });
          if (![self runArgosToolSynchronously:tool
                                sourceLanguage:sourceLanguage
                                targetLanguage:targetLanguage
                                         input:sourceText
                                        output:&translated
                                         error:&failure]) {
              translated = nil;
          }
          if (translated) translatedLines[0] = translated;
          if (!failure.length) {
              dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf updateTranslationProgress:1.0 detail:@"Writing translated PDF..."];
              });
          }
      } else {
          NSUInteger start = 0;
          NSUInteger translatedCount = 0;
          // Each Argos spawn costs seconds of model loading, so batch whole
          // pages together (up to a line budget) instead of one spawn per
          // page. Batches end on page boundaries so any line-count drift in
          // Argos output never leaks past the batch's last page.
          const NSUInteger batchLineBudget = 100;
          while (start < items.count && !failure.length) {
              if (self->_translationCancelRequested) {
                  failure = @"Translation canceled.";
                  break;
              }
              NSInteger page = [items[start][@"page"] integerValue];
              NSUInteger end = start + 1;
              while (end < items.count && [items[end][@"page"] integerValue] == page) end++;
              while (end < items.count && end - start < batchLineBudget) {
                  NSInteger nextPage = [items[end][@"page"] integerValue];
                  NSUInteger nextEnd = end + 1;
                  while (nextEnd < items.count && [items[nextEnd][@"page"] integerValue] == nextPage) nextEnd++;
                  if (nextEnd - start > batchLineBudget) break;
                  end = nextEnd;
              }
              NSString* scope = SPDFTranslationBatchScope(items, start, end);
              dispatch_async(dispatch_get_main_queue(), ^{
                NSString* detail =
                    [NSString stringWithFormat:@"Translating %@ (%lu of %lu text items)...", scope,
                                               (unsigned long)translatedCount, (unsigned long)items.count];
                [weakSelf updateTranslationProgress:(double)translatedCount detail:detail];
              });

              NSMutableString* pageInput = [NSMutableString string];
              for (NSUInteger i = start; i < end; ++i) {
                  NSString* line = i < sourceLines.count ? sourceLines[i] : @"";
                  [pageInput appendString:line ?: @""];
                  [pageInput appendString:@"\n"];
              }

              NSString* translated = nil;
              if (![self runArgosToolSynchronously:tool
                                    sourceLanguage:sourceLanguage
                                    targetLanguage:targetLanguage
                                             input:pageInput
                                            output:&translated
                                             error:&failure]) {
                  if (failure.length && ![failure isEqualToString:@"Translation canceled."]) {
                      NSString* prefix = scope.length > 1 ? [[[scope substringToIndex:1] uppercaseString]
                                                                stringByAppendingString:[scope substringFromIndex:1]]
                                                          : scope;
                      failure = [NSString stringWithFormat:@"%@: %@", prefix, failure];
                  }
                  break;
              }
              NSArray<NSString*>* pageOutput =
                  [translated componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
              for (NSUInteger i = start; i < end; ++i) {
                  NSUInteger local = i - start;
                  NSString* line = local < pageOutput.count ? pageOutput[local] : @"";
                  translatedLines[i] = line.length ? line : @" ";
              }
              if (pageOutput.count > end - start) {
                  // Join with spaces, not newlines: the combined output is
                  // rejoined with "\n" and resplit per line when writing the
                  // PDF, so embedded newlines here would shift every later
                  // line onto the wrong overlay.
                  NSMutableString* tail = [translatedLines[end - 1] mutableCopy];
                  for (NSUInteger i = end - start; i < pageOutput.count; ++i) {
                      NSString* extra = pageOutput[i];
                      if (!extra.length) continue;
                      if (tail.length) [tail appendString:@" "];
                      [tail appendString:extra];
                  }
                  translatedLines[end - 1] = [tail stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
              }
              translatedCount = end;
              dispatch_async(dispatch_get_main_queue(), ^{
                NSString* detail =
                    [NSString stringWithFormat:@"Translated %@ (%lu of %lu text items)...", scope,
                                               (unsigned long)translatedCount, (unsigned long)items.count];
                [weakSelf updateTranslationProgress:(double)translatedCount detail:detail];
              });
              start = end;
          }
      }

      NSString* output = failure.length ? @"" : [translatedLines componentsJoinedByString:@"\n"];
      dispatch_async(dispatch_get_main_queue(), ^{
        ShenzhenMacDelegate* strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_translationRunning = NO;
        [strongSelf updateTranslateCommandEnablement];
        if (failure.length) {
            [strongSelf finishTranslationProgressWithDetail:failure keepVisible:NO];
            if ([failure isEqualToString:@"Translation canceled."]) {
                strongSelf->_statusLabel.stringValue = @"Translation canceled.";
                return;
            }
            // Only offer the language-package installer for missing-package
            // errors; anything else (crashes, bad toolchain, ...) must show
            // the real error instead of hiding it behind an install prompt.
            BOOL missingPackage = [failure rangeOfString:@"is not an installed language"].location != NSNotFound ||
                                  [failure rangeOfString:@"No package"].location != NSNotFound;
            if (!offeredInstaller && missingPackage) {
                [strongSelf runArgosPackageInstallFromLanguage:sourceLanguage
                                                    toLanguage:targetLanguage
                                                    sourceText:sourceText
                                                    outputPath:outputPath];
                return;
            }
            NSString* detail = failure.length > 1200 ? [failure substringToIndex:1200] : failure;
            [strongSelf showError:@"Translation failed" detail:detail.length ? detail : @"Argos exited with an error."];
            strongSelf->_statusLabel.stringValue = @"Translation failed.";
            return;
        }

        NSError* writeError = nil;
        strongSelf->_pendingTranslationItems = items;
        if (![strongSelf writeTranslatedPDFWithText:output
                                         sourcePath:strongSelf->_path
                                         outputPath:outputPath
                                              error:&writeError]) {
            [strongSelf showError:@"Could not save translation" detail:writeError.localizedDescription ?: @""];
            [strongSelf finishTranslationProgressWithDetail:@"Could not save translated PDF." keepVisible:NO];
            strongSelf->_statusLabel.stringValue = @"Translation was not saved.";
            return;
        }

        [strongSelf finishTranslationProgressWithDetail:@"Translation complete." keepVisible:NO];
        [strongSelf openTranslation:outputPath besidePath:besidePath];
        strongSelf->_statusLabel.stringValue =
            [NSString stringWithFormat:fromRendition ? @"Translation saved as a PDF: %@" : @"Translation saved: %@",
                                       outputPath.lastPathComponent];
      });
    });
}

- (void)promptToInstallArgosAndContinueWithSourceText:(NSString*)sourceText
                                       sourceLanguage:(NSString*)sourceLanguage
                                       targetLanguage:(NSString*)targetLanguage
                                           outputPath:(NSString*)outputPath {
    if (_translationInstallRunning) return;

    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"Install Argos Translate?";
    alert.informativeText = @"Shenzhen PDF uses Argos Translate locally for offline translation. "
                            @"Install it, then continue translation.";
    [alert addButtonWithTitle:@"Install"];
    [alert addButtonWithTitle:@"Cancel"];
    alert.alertStyle = NSAlertStyleInformational;
    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    NSTask* task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/bash"];
    // Not `-lc`: a login shell would source the dotfiles whose conda/pyenv hook
    // is exactly what made this install differ between machines.
    task.arguments = @[ @"-c", [self argosInstallScript] ];
    task.environment = [self taskEnvironmentWithToolPaths:@[]];
    spdf_mac_tool_note_install_attempt();

    __weak ShenzhenMacDelegate* weakSelf = self;
    [self runTranslationInstallTask:task
                              title:@"Installing Translation Support"
                            heading:@"Installing Argos Translate"
                         initialLog:@"Preparing Argos Translate installer...\n"
                         completion:^(NSTask* finishedTask, NSString* output) {
                           (void)output;
                           ShenzhenMacDelegate* strongSelf = weakSelf;
                           if (!strongSelf) return;
                           strongSelf->_translationInstallRunning = NO;
                           [strongSelf updateTranslateCommandEnablement];
                           NSString* tool = [strongSelf argosToolPath];
                           if (finishedTask.terminationStatus == 0 && tool.length) {
                               [strongSelf appendTranslationInstallLog:@"\nArgos Translate installed.\n"];
                               [strongSelf->_translationInstallPanel orderOut:nil];
                               [strongSelf runArgosTranslationWithTool:tool
                                                            sourceText:sourceText
                                                        sourceLanguage:sourceLanguage
                                                        targetLanguage:targetLanguage
                                                            outputPath:outputPath
                                                      offeredInstaller:NO];
                           } else {
                               [strongSelf appendTranslationInstallLog:
                                               @"\nArgos Translate installation failed. The log above can be selected "
                                               @"and copied.\n"];
                               strongSelf->_statusLabel.stringValue = @"Argos installation failed.";
                           }
                         }];
}
- (void)translateDocumentLocally:(id)sender {
    // From the picker (SPDFMacTranslationChoice.h): the whole document into its language, named "<name> (<Language>)".
    NSDictionary* request = [self localTranslationRequest];
    if (![self beginTranslateCommandForSender:sender]) {
        [self clearLocalTranslationRequest];
        return;
    }
    // A Markdown or EPUB document is translated as a PDF made from it; this runs again once that is open, with the
    // request still there.
    if ([self beginWholeDocumentTranslationForMarkdown] || [self beginNativeDocumentTranslation]) return;
    [self clearLocalTranslationRequest];
    _translatingMadePDF = [request[@"madePDF"] boolValue];
    if (request) {
        // The document itself is only read: a read-only one stays where it is. Only its permissions can refuse.
        if (spdf_is_password_protected(_doc) && !spdf_has_permission(_doc, 'e')) {
            [self showError:@"Operation is not allowed"
                     detail:@"This PDF's user permissions do not allow translation. Open it with the owner password to "
                            @"continue."];
            return;
        }
    } else if (![self ensureActivePDFCanBeModifiedForOperation:@"translation"]) {
        return;
    }

    BOOL usingSelection = NO;
    NSString* textError = nil;
    NSString* sourceText = [self currentTextForTranslationUsingSelection:&usingSelection error:&textError];
    if (!sourceText) {
        [self showError:@"Could not prepare translation" detail:textError ?: @"No text is available to translate."];
        return;
    }
    // sourceText can be empty here (no selectable body text): chapter titles
    // and comments may still be translatable, so keep going until the
    // per-item filter below has seen them too.

    NSDictionary* options = nil;
    if (request) {
        NSString* target = request[@"target"];
        NSString* source = [self localTranslationSourceForText:sourceText target:target];
        if (!source) {
            [self showError:@"Nothing to translate"
                     detail:[NSString stringWithFormat:@"This document already seems to be in %@.", request[@"language"]]];
            return;
        }
        _translationSourceLanguage = source;
        _translationTargetLanguage = target;
        [self savePersistentState];
        options = @{@"source" : source, @"target" : target};
    } else {
        options = [self promptForTranslationOptionsUsingSelection:usingSelection];
    }
    if (!options) return;

    NSString* sourceLanguage = options[@"source"];
    NSString* targetLanguage = options[@"target"];
    if (!usingSelection) {
        spdf_translation_script sourceScript = spdf_translation_script_for_language(sourceLanguage.UTF8String);
        spdf_translation_script targetScript = spdf_translation_script_for_language(targetLanguage.UTF8String);
        sourceText = [self sourceTextByKeepingTranslatableLines:sourceText
                                                   sourceScript:sourceScript
                                                   targetScript:targetScript];
        sourceText = [self sourceTextByAppendingOutlineAndCommentItems:sourceText
                                                          sourceScript:sourceScript
                                                          targetScript:targetScript];
        if (sourceText.length == 0 || _pendingTranslationItems.count == 0) {
            [self showError:@"Nothing to translate"
                     detail:textError
                                ?: @"No text block, chapter title or comment in this document needs "
                                   @"translation for the selected languages."];
            return;
        }
    }
    NSString* outputPath = request ? [self localTranslationOutputPathInDirectory:[self localTranslationDirectory]
                                                                         request:request]
                                   : [self translatedOutputPathForPath:_path targetLanguage:targetLanguage];
    [self runArgosTranslationWithTool:[self argosToolPath]
                           sourceText:sourceText
                       sourceLanguage:sourceLanguage
                       targetLanguage:targetLanguage
                           outputPath:outputPath
                     offeredInstaller:NO];
}

- (void)appendOCRInstallLog:(NSString*)text {
    if (!_ocrInstallLog || text.length == 0) return;
    NSTextStorage* storage = _ocrInstallLog.textStorage;
    NSDictionary* attrs = @{
        NSForegroundColorAttributeName : SPDFCollectionColor(@"text"),
        NSFontAttributeName : _ocrInstallLog.font ?: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular]
    };
    [storage appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:attrs]];
    [_ocrInstallLog scrollRangeToVisible:NSMakeRange(storage.length, 0)];
}

- (void)showOCRInstallPanel {
    if (!_ocrInstallPanel) {
        _ocrInstallPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 640, 360)
                                                      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                        backing:NSBackingStoreBuffered
                                                          defer:NO];
        _ocrInstallPanel.title = @"Installing OCR";
        _ocrInstallPanel.releasedWhenClosed = NO;

        NSView* content = [[NSView alloc] initWithFrame:_ocrInstallPanel.contentView.bounds];
        content.translatesAutoresizingMaskIntoConstraints = NO;
        _ocrInstallPanel.contentView = content;

        NSTextField* title = [NSTextField labelWithString:@"Installing OCRmyPDF, Tesseract, and language data"];
        title.translatesAutoresizingMaskIntoConstraints = NO;
        title.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
        [content addSubview:title];

        _ocrInstallProgress = [[NSProgressIndicator alloc] init];
        _ocrInstallProgress.translatesAutoresizingMaskIntoConstraints = NO;
        _ocrInstallProgress.indeterminate = YES;
        _ocrInstallProgress.style = NSProgressIndicatorStyleBar;
        [content addSubview:_ocrInstallProgress];

        NSScrollView* scroll = [[NSScrollView alloc] init];
        scroll.translatesAutoresizingMaskIntoConstraints = NO;
        scroll.hasVerticalScroller = YES;
        [content addSubview:scroll];

        _ocrInstallLog = [[NSTextView alloc] init];
        _ocrInstallLog.editable = NO;
        _ocrInstallLog.selectable = YES;
        _ocrInstallLog.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
        _ocrInstallLog.drawsBackground = YES;
        _ocrInstallLog.backgroundColor = SPDFCollectionColor(@"window");
        _ocrInstallLog.textColor = SPDFCollectionColor(@"text");
        scroll.documentView = _ocrInstallLog;

        [NSLayoutConstraint activateConstraints:@[
            [title.topAnchor constraintEqualToAnchor:content.topAnchor constant:14],
            [title.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14],
            [title.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-14],
            [_ocrInstallProgress.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:10],
            [_ocrInstallProgress.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
            [_ocrInstallProgress.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
            [scroll.topAnchor constraintEqualToAnchor:_ocrInstallProgress.bottomAnchor constant:12],
            [scroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14],
            [scroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-14],
            [scroll.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-14]
        ]];
    }

    [_ocrInstallPanel center];
    [_ocrInstallPanel makeKeyAndOrderFront:nil];
    [_ocrInstallProgress startAnimation:nil];
}

- (NSDictionary<NSString*, NSString*>*)promptForOCRLanguage {
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"Choose OCR language";
    alert.informativeText = @"Choose the language data Tesseract should use for this PDF.";
    [alert addButtonWithTitle:@"Run OCR"];
    [alert addButtonWithTitle:@"Cancel"];
    alert.alertStyle = NSAlertStyleInformational;

    NSPopUpButton* popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 320, 28) pullsDown:NO];
    for (NSDictionary<NSString*, NSString*>* language in spdf_ocr_languages()) {
        [popup addItemWithTitle:language[@"name"]];
        popup.lastItem.representedObject = language;
    }
    alert.accessoryView = popup;
    if ([alert runModal] != NSAlertFirstButtonReturn) return nil;
    NSDictionary<NSString*, NSString*>* selected = popup.selectedItem.representedObject;
    return selected[@"code"].length ? selected : nil;
}

- (NSString*)customTessdataParentPath {
    return [[self supportDirectory] stringByAppendingPathComponent:@"tesseract"];
}

- (BOOL)customTessdataHasOCRLanguage:(NSString*)language {
    NSString* tessdataDir = [[self customTessdataParentPath] stringByAppendingPathComponent:@"tessdata"];
    for (NSString* component in spdf_ocr_language_components(language)) {
        NSString* traineddata =
            [tessdataDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.traineddata", component]];
        if (![NSFileManager.defaultManager fileExistsAtPath:traineddata]) return NO;
    }
    return spdf_ocr_language_components(language).count > 0;
}

- (BOOL)tesseractPath:(NSString*)tesseract hasOCRLanguage:(NSString*)language {
    NSArray<NSString*>* required = spdf_ocr_language_components(language);
    if (required.count == 0) return NO;

    NSTask* task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:tesseract];
    task.arguments = @[ @"--list-langs" ];
    task.environment = [self taskEnvironmentWithToolPaths:@[ tesseract ]];
    NSPipe* pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    NSError* error = nil;
    if ([task launchAndReturnError:&error]) {
        [task waitUntilExit];
        NSData* data = pipe.fileHandleForReading.readDataToEndOfFile;
        NSString* output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        NSMutableSet<NSString*>* available = [NSMutableSet set];
        for (NSString* line in [output componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            NSString* trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (trimmed.length) [available addObject:trimmed];
        }
        BOOL hasAll = YES;
        for (NSString* component in required) {
            if (![available containsObject:component]) {
                hasAll = NO;
                break;
            }
        }
        if (hasAll) return YES;
    }

    return [self customTessdataHasOCRLanguage:language];
}

- (NSDictionary<NSString*, NSString*>*)ocrTaskEnvironmentWithTool:(NSString*)tool
                                                        tesseract:(NSString*)tesseract
                                                         language:(NSString*)language {
    NSMutableDictionary<NSString*, NSString*>* extra = [NSMutableDictionary dictionary];
    if ([self customTessdataHasOCRLanguage:language]) extra[@"TESSDATA_PREFIX"] = [self customTessdataParentPath];
    return [self taskEnvironmentWithToolPaths:@[ tool ?: @"", tesseract ?: @"" ] extra:extra];
}

- (void)installOCRAndRunAfterwardsWithLanguage:(NSString*)language displayName:(NSString*)displayName {
    if (_ocrInstallRunning) {
        [_ocrInstallPanel makeKeyAndOrderFront:nil];
        return;
    }

    _ocrInstallRunning = YES;
    spdf_mac_tool_note_install_attempt();
    _ocrButton.enabled = NO;
    [self showOCRInstallPanel];
    _ocrInstallLog.string = @"";
    [self appendOCRInstallLog:[NSString stringWithFormat:@"Preparing OCR installer for %@...\n", displayName]];

    NSTask* task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/bash"];
    // No login shell, same reason as the Argos installer above.
    task.arguments = @[ @"-c", [self ocrInstallScriptForLanguage:language] ];
    task.environment = [self taskEnvironmentWithToolPaths:@[]];
    NSPipe* pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    _ocrInstallTask = task;

    __weak ShenzhenMacDelegate* weakSelf = self;
    pipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle* handle) {
      NSData* chunk = handle.availableData;
      if (chunk.length == 0) {
          handle.readabilityHandler = nil;
          return;
      }
      NSString* text = [[NSString alloc] initWithData:chunk encoding:NSUTF8StringEncoding] ?: @"";
      dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf appendOCRInstallLog:text];
      });
    };

    task.terminationHandler = ^(NSTask* finishedTask) {
      pipe.fileHandleForReading.readabilityHandler = nil;
      dispatch_async(dispatch_get_main_queue(), ^{
        ShenzhenMacDelegate* strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_ocrInstallRunning = NO;
        strongSelf->_ocrInstallTask = nil;
        [strongSelf->_ocrInstallProgress stopAnimation:nil];
        strongSelf->_ocrButton.enabled =
            strongSelf->_doc != NULL && SPDFOCRPathSupported(strongSelf->_path);
        NSString* tool = [strongSelf ocrToolPath];
        NSString* tesseract = [strongSelf tesseractToolPath];
        if (finishedTask.terminationStatus == 0 && tool.length && tesseract.length &&
            [strongSelf tesseractPath:tesseract hasOCRLanguage:language]) {
            [strongSelf appendOCRInstallLog:@"\nOCR tools installed.\n"];
            [strongSelf->_ocrInstallPanel orderOut:nil];
            [strongSelf runOCRWithLanguage:language displayName:displayName];
        } else {
            [strongSelf
                appendOCRInstallLog:
                    @"\nOCR installation failed or the selected language data is still missing. The log above can "
                     "be selected and copied.\n"];
            strongSelf->_statusLabel.stringValue = @"OCR installation failed.";
        }
      });
    };

    NSError* error = nil;
    if (![task launchAndReturnError:&error]) {
        _ocrInstallRunning = NO;
        _ocrInstallTask = nil;
        [_ocrInstallProgress stopAnimation:nil];
        _ocrButton.enabled = _doc != NULL && SPDFOCRPathSupported(_path);
        [self showError:@"Could not start OCR installer" detail:error.localizedDescription ?: @""];
    }
}

- (NSString*)backupPathForPDFPath:(NSString*)path {
    NSString* dir = path.stringByDeletingLastPathComponent;
    NSString* stem = path.stringByDeletingPathExtension.lastPathComponent;
    NSString* ext = path.pathExtension.length ? path.pathExtension : @"pdf";
    NSFileManager* fm = NSFileManager.defaultManager;
    NSString* candidate = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_backup.%@", stem, ext]];
    NSInteger index = 2;
    while ([fm fileExistsAtPath:candidate]) {
        candidate = [dir
            stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_backup_%ld.%@", stem, (long)index, ext]];
        index++;
    }
    return candidate;
}

- (NSInteger)currentPageIndexFromCounterForMutation {
    NSInteger pageCount = _doc ? spdf_page_count(_doc) : 0;
    if (pageCount <= 0) return 0;

    NSInteger pageIndex = MAX(0, MIN(_pageIndex, pageCount - 1));
    NSInteger counterPageIndex = _pageField.stringValue.integerValue - 1;
    if (counterPageIndex >= 0 && counterPageIndex < pageCount) pageIndex = counterPageIndex;
    return pageIndex;
}

// Strip the entire text layer (e.g. a wrong OCR layer) so the document can be
// re-OCR'd. Backs the original up, asks for confirmation first.
- (void)deleteAllTextFromDocument:(id)sender {
    (void)sender;
    if (!_doc || !_path.length || ![_path.pathExtension.lowercaseString isEqualToString:@"pdf"]) {
        NSBeep();
        return;
    }

    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"Delete all text from this document?";
    alert.informativeText = @"This removes the entire text layer (for example a wrong OCR layer) from every page, "
                            @"keeping images and graphics. A backup copy is saved next to the original first, so you "
                            @"can re-run OCR afterwards.";
    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:@"Delete Text"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    if (![self ensureActivePDFCanBeModifiedForOperation:@"removing the text"]) return;

    [self cancelDocumentTransientInteraction];
    NSInteger pageIndex = [self currentPageIndexFromCounterForMutation];
    [self clearPageFieldFocus];

    // Backup the original before touching it.
    NSString* backupPath = [self backupPathForPDFPath:_path];
    NSError* copyError = nil;
    if (![NSFileManager.defaultManager copyItemAtPath:_path toPath:backupPath error:&copyError]) {
        [self showError:@"Could not back up the document"
                 detail:copyError.localizedDescription.length ? copyError.localizedDescription
                                                              : @"The text was not removed."];
        return;
    }

    char err[1024];
    if (!spdf_delete_all_text(_doc, _path.fileSystemRepresentation, err, sizeof(err))) {
        [self discardCachedRuntimeForTab:[self selectedTab]];
        [self loadSelectedTab];
        [self showError:@"Could not delete text" detail:[NSString stringWithUTF8String:err[0] ? err : "Unknown error"]];
        return;
    }

    [_renderQueue cancelAllOperations];
    [self cancelCacheRenderOperations];
    [_minimapQueue cancelAllOperations];
    [_queuedRenderPages removeAllObjects];
    [_queuedRenderOperations removeAllObjects];
    [_queuedMinimapThumbnailPages removeAllObjects];
    _renderGeneration++;
    if (_selectedTabIndex >= 0 && _selectedTabIndex < (NSInteger)_tabs.count) {
        SPDFDocumentTab* tab = _tabs[(NSUInteger)_selectedTabIndex];
        tab.pageIndex = pageIndex;
        [self discardCachedRuntimeForTab:tab];
    }
    _pageIndex = pageIndex;
    [self loadSelectedTab];
    _statusLabel.stringValue =
        [NSString stringWithFormat:@"All text removed. Backup saved as %@.", backupPath.lastPathComponent];
}

- (void)runOCRTaskWithTool:(NSString*)tool
                 tesseract:(NSString*)tesseract
                  language:(NSString*)language
               displayName:(NSString*)displayName
              originalPath:(NSString*)originalPath
                   tmpPath:(NSString*)tmp
                backupPath:(NSString*)backupPath
              originalPage:(NSInteger)originalPage
             sourceHasText:(BOOL)sourceHasText
                  forceOCR:(BOOL)forceOCR
                      jobs:(NSInteger)jobs {
    NSArray<NSString*>* args =
        spdf_mac_ocr_arguments(language, originalPath, tmp, jobs, sourceHasText, forceOCR);
    NSString* runningDetail =
        forceOCR
            ? [NSString stringWithFormat:@"Retrying OCR (%@) with forced image pass...", displayName ?: language]
            : [NSString stringWithFormat:@"OCR running (%@) with %ld workers...", displayName ?: language, (long)jobs];
    _ocrButton.enabled = NO;
    _statusLabel.stringValue = runningDetail;
    [self showOCRProgressWithDetail:runningDetail];

    // ocrmypdf needs a Noto face to DRAW the text it recognises; fetch any that
    // is missing in the background (see SPDFMacOCRInstall.h) without delaying
    // this run by a download.
    [self ensureOCRFontsForLanguage:language];
    NSTask* task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:tool];
    task.arguments = args;
    task.environment = [self ocrTaskEnvironmentWithTool:tool tesseract:tesseract language:language];
    NSPipe* pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    __block NSMutableData* outputData = [NSMutableData data];
    __weak ShenzhenMacDelegate* weakSelf = self;
    pipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle* handle) {
      NSData* chunk = handle.availableData;
      if (chunk.length > 0) {
          @synchronized(outputData) {
              [outputData appendData:chunk];
          }
          NSString* chunkText = [[NSString alloc] initWithData:chunk encoding:NSUTF8StringEncoding] ?: @"";
          NSString* detail = SPDFLastMeaningfulOCRLine(chunkText);
          if (detail.length) {
              dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf updateOCRProgressDetail:detail];
              });
          }
      } else {
          handle.readabilityHandler = nil;
      }
    };

    task.terminationHandler = ^(NSTask* finishedTask) {
      pipe.fileHandleForReading.readabilityHandler = nil;
      NSData* tail = pipe.fileHandleForReading.readDataToEndOfFile;
      if (tail.length > 0) {
          @synchronized(outputData) {
              [outputData appendData:tail];
          }
      }
      NSData* data = nil;
      @synchronized(outputData) {
          data = [outputData copy];
      }
      NSString* output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
      dispatch_async(dispatch_get_main_queue(), ^{
        ShenzhenMacDelegate* strongSelf = weakSelf;
        if (!strongSelf) return;
        if (finishedTask.terminationStatus != 0) {
            [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
            // ocrmypdf can refuse a file outright and name the flag that would
            // have worked. Take its advice once instead of reporting defeat.
            if (spdf_mac_ocr_failure_wants_forced_pass(output) && !sourceHasText && !forceOCR) {
                [strongSelf updateOCRProgressDetail:@"OCRmyPDF refused this PDF. Retrying with forced image OCR..."];
                [strongSelf runOCRTaskWithTool:tool
                                     tesseract:tesseract
                                      language:language
                                   displayName:displayName
                                  originalPath:originalPath
                                       tmpPath:tmp
                                    backupPath:backupPath
                                  originalPage:originalPage
                                 sourceHasText:sourceHasText
                                      forceOCR:YES
                                          jobs:jobs];
                return;
            }
            strongSelf->_ocrButton.enabled =
                strongSelf->_doc != NULL && SPDFOCRPathSupported(strongSelf->_path);
            [strongSelf finishOCRProgressWithDetail:@"OCR failed."];
            [strongSelf showError:@"OCR failed" detail:spdf_mac_ocr_human_readable_failure(output)];
            strongSelf->_statusLabel.stringValue = @"OCR failed.";
            return;
        }

        NSString* validationError = nil;
        NSInteger outputHasText = [strongSelf selectableTextStateForPDFAtPath:tmp errorMessage:&validationError];
        // ocrmypdf skips any page with no raster image ("page has no images -
        // skipping all processing"), so a scan-cover, vector-body datasheet comes
        // back with text on page 1 and none on 2..8 -- which the old "any text at
        // all?" check called a success. A page left empty means a partial pass.
        BOOL partial = outputHasText > 0 && [strongSelf ocrOutputIsPartialAtPath:tmp];
        if ((outputHasText <= 0 || partial) && !sourceHasText && !forceOCR) {
            [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
            [strongSelf updateOCRProgressDetail:partial
                                              ? @"Some pages were skipped. Retrying with forced image OCR..."
                                              : @"No text found yet. Retrying with forced image OCR..."];
            [strongSelf runOCRTaskWithTool:tool
                                 tesseract:tesseract
                                  language:language
                               displayName:displayName
                              originalPath:originalPath
                                   tmpPath:tmp
                                backupPath:backupPath
                              originalPage:originalPage
                             sourceHasText:sourceHasText
                                  forceOCR:YES
                                      jobs:jobs];
            return;
        }
        if (outputHasText <= 0) {
            [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
            strongSelf->_ocrButton.enabled =
                strongSelf->_doc != NULL && SPDFOCRPathSupported(strongSelf->_path);
            [strongSelf finishOCRProgressWithDetail:@"OCR produced no selectable text."];
            NSString* detail =
                outputHasText < 0
                    ? (validationError ?: @"Could not inspect OCR output.")
                    : @"OCRmyPDF completed, but Shenzhen PDF could not find selectable text in the output "
                      @"PDF. The original file was left unchanged.";
            [strongSelf showError:@"OCR produced no selectable text" detail:detail];
            strongSelf->_statusLabel.stringValue = @"OCR produced no selectable text.";
            return;
        }

        if (![strongSelf collectionProtectPath:originalPath operation:@"installing OCR output"]) {
            [strongSelf finishOCRProgressWithDetail:@"OCR output was not installed."];
            [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
            return;
        }
        [strongSelf->_renderQueue cancelAllOperations];
        [strongSelf cancelCacheRenderOperations];
        [strongSelf->_minimapQueue cancelAllOperations];
        [strongSelf->_queuedRenderPages removeAllObjects];
        [strongSelf->_queuedRenderOperations removeAllObjects];
        [strongSelf->_queuedMinimapThumbnailPages removeAllObjects];
        strongSelf->_renderGeneration++;
        [strongSelf discardCachedRuntimeForTab:[strongSelf selectedTab]];
        [strongSelf clearActiveMetadata];
        [strongSelf closeActiveDocumentIfUnowned];
        NSError* moveError = nil;
        NSURL* resultingURL = nil;
        if (![NSFileManager.defaultManager replaceItemAtURL:[NSURL fileURLWithPath:originalPath]
                                              withItemAtURL:[NSURL fileURLWithPath:tmp]
                                             backupItemName:nil
                                                    options:0
                                           resultingItemURL:&resultingURL
                                                      error:&moveError]) {
            [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
            [strongSelf finishOCRProgressWithDetail:@"Could not save OCR output."];
            [strongSelf showError:@"Could not save OCR output" detail:moveError.localizedDescription ?: @""];
            strongSelf->_statusLabel.stringValue = @"OCR output was not installed.";
            [strongSelf loadSelectedTab];
            return;
        }

        if (strongSelf->_selectedTabIndex >= 0 && strongSelf->_selectedTabIndex < (NSInteger)strongSelf->_tabs.count) {
            SPDFDocumentTab* tab = strongSelf->_tabs[(NSUInteger)strongSelf->_selectedTabIndex];
            tab.pageIndex = originalPage;
        }
        [strongSelf collectionDidSavePath:originalPath];
        [strongSelf loadSelectedTab];
        strongSelf->_ocrButton.enabled =
            strongSelf->_doc != NULL && SPDFOCRPathSupported(strongSelf->_path);
        if (backupPath.length)
            strongSelf->_statusLabel.stringValue =
                [NSString stringWithFormat:@"OCR complete. Backup: %@", backupPath.lastPathComponent];
        else
            strongSelf->_statusLabel.stringValue = @"OCR complete.";
        [strongSelf finishOCRProgressWithDetail:strongSelf->_statusLabel.stringValue];
      });
    };

    NSError* launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        _ocrButton.enabled = YES;
        [self finishOCRProgressWithDetail:@"Could not start OCR."];
        [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
        [self showError:@"Could not start OCR" detail:launchError.localizedDescription ?: @""];
    }
}

- (void)runOCRWithLanguage:(NSString*)language displayName:(NSString*)displayName {
    if ([self beginImageOCRWithLanguage:language displayName:displayName]) return;
    if (!_doc || !_path.length || ![_path.pathExtension.lowercaseString isEqualToString:@"pdf"]) {
        NSBeep();
        return;
    }
    if (spdf_is_password_protected(_doc)) {
        [self showError:@"OCR is unavailable for password-protected PDFs"
                 detail:@"To OCR this document, intentionally create and open an unprotected copy first. Shenzhen PDF "
                        @"will not decrypt a protected PDF into a temporary file or silently replace it with an "
                        @"unprotected result."];
        return;
    }
    if (![self ensureActivePDFCanBeModifiedForOperation:@"OCR"]) return;

    NSString* tool = [self ocrToolPath];
    NSString* tesseract = [self tesseractToolPath];
    BOOL languageReady = tesseract.length && [self tesseractPath:tesseract hasOCRLanguage:language];
    // ocrmypdf is never installed globally, so the environment holding it is
    // part of what "OCR is installed" means. A machine that cannot build one is
    // asked once and then left alone with whatever it already has.
    BOOL environmentMissing = !spdf_mac_tool_venv_has_tool(@"ocrmypdf") && !spdf_mac_tool_install_attempted();
    BOOL supportMissing = !tool.length || !tesseract.length || environmentMissing;
    if (supportMissing || !languageReady) {
        NSAlert* alert = [[NSAlert alloc] init];
        alert.messageText = supportMissing ? @"Install OCR support?" : @"Install OCR language data?";
        alert.informativeText = [NSString
            stringWithFormat:@"Shenzhen PDF can install OCRmyPDF, Tesseract, and the %@ traineddata, then continue OCR "
                             @"automatically when installation finishes.",
                             displayName.length ? displayName : language];
        [alert addButtonWithTitle:@"Install"];
        [alert addButtonWithTitle:@"Cancel"];
        alert.alertStyle = NSAlertStyleInformational;
        if ([alert runModal] == NSAlertFirstButtonReturn)
            [self installOCRAndRunAfterwardsWithLanguage:language displayName:displayName];
        return;
    }

    char err[1024];
    BOOL imageBacked = spdf_mac_ocr_document_is_image_backed(_doc);
    int hasText = spdf_document_has_text(_doc, 0, err, sizeof(err));
    if (hasText < 0) {
        [self showError:@"Could not inspect document text"
                 detail:[NSString stringWithUTF8String:err[0] ? err : "Unknown error"]];
        return;
    }

    NSString* backupPath = nil;
    if (hasText > 0) {
        NSAlert* alert = [[NSAlert alloc] init];
        alert.messageText = @"This PDF already contains selectable text.";
        alert.informativeText = @"Shenzhen PDF will make a backup of the original file before OCR replaces it.";
        [alert addButtonWithTitle:@"OCR and Backup"];
        [alert addButtonWithTitle:@"Cancel"];
        alert.alertStyle = NSAlertStyleWarning;
        if ([alert runModal] != NSAlertFirstButtonReturn) return;

        backupPath = [self backupPathForPDFPath:_path];
        NSError* copyError = nil;
        if (![NSFileManager.defaultManager copyItemAtPath:_path toPath:backupPath error:&copyError]) {
            [self showError:@"Could not create OCR backup" detail:copyError.localizedDescription ?: @""];
            return;
        }
    }

    NSString* originalPath = [_path copy];
    NSInteger originalPage = _pageIndex;
    NSString* dir = originalPath.stringByDeletingLastPathComponent;
    NSString* tmp = [dir
        stringByAppendingPathComponent:[NSString stringWithFormat:@".%@.ocr-%@.pdf", originalPath.lastPathComponent,
                                                                  NSUUID.UUID.UUIDString]];
    NSInteger jobs = MAX(1, NSProcessInfo.processInfo.activeProcessorCount);
    [self runOCRTaskWithTool:tool
                   tesseract:tesseract
                    language:language
                 displayName:displayName
                originalPath:originalPath
                     tmpPath:tmp
                  backupPath:backupPath
                originalPage:originalPage
               sourceHasText:hasText > 0 && !imageBacked
                    forceOCR:imageBacked
                        jobs:jobs];
}

- (SPDFPrintScalingAccessoryController*)
    attachPrintScalingAccessoryToOperation:(NSPrintOperation*)operation
                           updatePrintView:(void (^)(SPDFPrintScalingMode mode, CGFloat customScale))updatePrintView {
    SPDFPrintScalingAccessoryController* accessory =
        [[SPDFPrintScalingAccessoryController alloc] initWithScalingMode:_printScalingMode
                                                             customScale:_printCustomScale];
    __weak ShenzhenMacDelegate* weakSelf = self;
    accessory.changeHandler = ^(SPDFPrintScalingMode mode, CGFloat customScale) {
      if (updatePrintView) updatePrintView(mode, customScale);
      ShenzhenMacDelegate* strongSelf = weakSelf;
      if (!strongSelf) return;
      strongSelf->_printScalingMode = mode;
      strongSelf->_printCustomScale = customScale;
      [strongSelf savePersistentState];
    };
    if (updatePrintView) updatePrintView(accessory.scalingMode, accessory.customScale);
    NSPrintPanel* printPanel = operation.printPanel;
    printPanel.options =
        printPanel.options | NSPrintPanelShowsPreview | NSPrintPanelShowsPaperSize | NSPrintPanelShowsOrientation;
    [printPanel addAccessoryController:accessory];
    objc_setAssociatedObject(operation, @selector(attachPrintScalingAccessoryToOperation:updatePrintView:), accessory,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return accessory;
}

- (void)printDocument:(id)sender {
    (void)sender;
    if ([self isMarkdownActive]) {
        [self printActiveMarkdown];
        return;
    }
    if (!_doc) {
        NSBeep();
        return;
    }
    if (!spdf_has_permission(_doc, 'p')) {
        [self showError:@"Printing is not allowed" detail:@"This PDF's permissions do not allow printing."];
        return;
    }

    NSPrintInfo* info = [NSPrintInfo.sharedPrintInfo copy];
    info.horizontalPagination = NSPrintingPaginationModeClip;
    info.verticalPagination = NSPrintingPaginationModeClip;
    info.horizontallyCentered = YES;
    info.verticallyCentered = YES;

    if (!spdf_is_password_protected(_doc) && [_path.pathExtension.lowercaseString isEqualToString:@"pdf"]) {
        // Read-only shadow copy: PDFKit reads the file CONTENT here, which would
        // trigger the macOS prompt for a read-only source. Read the working path
        // (temp copy when read-only) instead; the source stays the identity.
        NSURL* url = [NSURL fileURLWithPath:[self activeWorkingPath]];
        PDFDocument* pdfDocument = [[PDFDocument alloc] initWithURL:url];
        if (pdfDocument && pdfDocument.pageCount > 0) {
            if (!pdfDocument.allowsPrinting) {
                [self showError:@"Printing is not allowed" detail:@"This PDF's permissions do not allow printing."];
                return;
            }

            NSSize paper = info.paperSize;
            SPDFPDFKitPrintView* pdfPrintView = [[SPDFPDFKitPrintView alloc]
                initWithFrame:NSMakeRect(0, 0, paper.width, paper.height * MAX(1, (NSInteger)pdfDocument.pageCount))];
            pdfPrintView.pdfDocument = pdfDocument;
            NSPrintOperation* operation = [NSPrintOperation printOperationWithView:pdfPrintView printInfo:info];
            [self attachPrintScalingAccessoryToOperation:operation
                                         updatePrintView:^(SPDFPrintScalingMode mode, CGFloat customScale) {
                                           pdfPrintView.scalingMode = mode;
                                           pdfPrintView.customScale = customScale;
                                           [pdfPrintView setNeedsDisplay:YES];
                                         }];
            operation.jobTitle = _path.lastPathComponent ?: @"Shenzhen PDF";
            operation.showsPrintPanel = YES;
            operation.showsProgressPanel = YES;
            [operation runOperationModalForWindow:_window delegate:nil didRunSelector:NULL contextInfo:NULL];
            [self evictDistantRenderedPageImages];
            return;
        }
    }

    NSSize paper = info.paperSize;
    NSInteger pageCount = spdf_page_count(_doc);
    SPDFPrintView* printView =
        [[SPDFPrintView alloc] initWithFrame:NSMakeRect(0, 0, paper.width, paper.height * MAX(1, pageCount))];
    printView.document = _doc;
    printView.pageCount = pageCount;
    printView.targetDPI = spdf_has_permission(_doc, 'h') ? 1200.0 : 150.0;
    printView.fallbackPages = _renderedPages;

    NSPrintOperation* operation = [NSPrintOperation printOperationWithView:printView printInfo:info];
    [self attachPrintScalingAccessoryToOperation:operation
                                 updatePrintView:^(SPDFPrintScalingMode mode, CGFloat customScale) {
                                   printView.scalingMode = mode;
                                   printView.customScale = customScale;
                                   [printView setNeedsDisplay:YES];
                                 }];
    operation.jobTitle = _path.lastPathComponent ?: @"Shenzhen PDF";
    operation.showsPrintPanel = YES;
    operation.showsProgressPanel = YES;
    [operation runOperationModalForWindow:_window delegate:nil didRunSelector:NULL contextInfo:NULL];
    [self evictDistantRenderedPageImages];
}

- (void)showDefaultPDFReaderStatus:(NSString*)message detail:(NSString*)detail {
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = message;
    alert.informativeText = detail ?: @"";
    alert.alertStyle = NSAlertStyleInformational;
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}

- (void)promptToMakeDefaultPDFReaderFromLaunch:(BOOL)fromLaunch {
    if (SPDFMacIsDefaultPDFReader()) {
        if (fromLaunch) {
            _defaultReaderPromptDismissed = YES;
            [self savePersistentState];
        } else {
            [self showDefaultPDFReaderStatus:@"Shenzhen PDF is already the default PDF reader." detail:@""];
        }
        return;
    }

    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"Make Shenzhen PDF your default PDF reader?";
    alert.informativeText = @"PDF files opened from Finder will open in Shenzhen PDF.";
    alert.alertStyle = NSAlertStyleInformational;
    [alert addButtonWithTitle:@"Make Default"];
    [alert addButtonWithTitle:@"Not Now"];

    [NSApp activateIgnoringOtherApps:YES];
    NSModalResponse response = [alert runModal];
    if (fromLaunch) {
        _defaultReaderPromptDismissed = YES;
        [self savePersistentState];
    }
    if (response != NSAlertFirstButtonReturn) return;

    NSError* error = nil;
    if (SPDFMacMakeDefaultPDFReader(&error)) {
        [self showDefaultPDFReaderStatus:@"Shenzhen PDF is now the default PDF reader."
                                  detail:@"Future PDF files opened from Finder should open in Shenzhen PDF."];
        return;
    }
    [self showError:@"Could not set the default PDF reader"
             detail:error.localizedRecoverySuggestion ?: error.localizedDescription ?: @""];
}

- (void)promptToMakeDefaultPDFReaderIfNeededOnLaunch {
    if (_defaultReaderPromptDismissed || self.detachedTabLaunch) return;
    [self promptToMakeDefaultPDFReaderFromLaunch:YES];
}

- (void)openFullDiskAccessSettings {
    NSURL* url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"];
    if (url) [NSWorkspace.sharedWorkspace openURL:url];
}

- (void)presentFullDiskAccessPromptFromLaunch:(BOOL)fromLaunch {
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"Grant Full Disk Access";
    alert.informativeText =
        @"Give Shenzhen PDF Full Disk Access so it can open PDFs from any folder "
        @"(Downloads, Documents, iCloud Drive, Google Drive, etc.) without macOS asking for permission each time.\n\n"
        @"In the window that opens, enable Shenzhen PDF under Full Disk Access, then relaunch the app.";
    [alert addButtonWithTitle:@"Open Settings"];
    [alert addButtonWithTitle:fromLaunch ? @"Not Now" : @"Cancel"];
    NSModalResponse response = [alert runModal];
    if (response == NSAlertFirstButtonReturn) [self openFullDiskAccessSettings];
    if (fromLaunch) {
        // Ask at most once; the menu item remains for later. Persist regardless
        // of the choice so launches never nag again.
        _fullDiskAccessPromptDismissed = YES;
        [self savePersistentState];
    }
}

- (void)grantFullDiskAccess:(id)sender {
    (void)sender;
    [self presentFullDiskAccessPromptFromLaunch:NO];
}

#pragma mark - Permissions setup wizard

// Build one permission row: name, one-line why, and an "Open Settings" button.
// Returns the container view.
- (NSView*)permissionsWizardRowWithName:(NSString*)name why:(NSString*)why settingsAction:(SEL)settingsAction {
    NSView* row = [[NSView alloc] initWithFrame:NSZeroRect];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField* nameLabel = [NSTextField labelWithString:name];
    nameLabel.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightSemibold];
    nameLabel.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField* whyLabel = [NSTextField wrappingLabelWithString:why];
    whyLabel.font = [NSFont systemFontOfSize:11.5];
    whyLabel.textColor = SPDFCollectionColor(@"secondary");
    whyLabel.translatesAutoresizingMaskIntoConstraints = NO;

    NSButton* openButton = [NSButton buttonWithTitle:@"Open Settings" target:self action:settingsAction];
    openButton.bezelStyle = NSBezelStyleRounded;
    openButton.font = [NSFont systemFontOfSize:12.0];
    openButton.translatesAutoresizingMaskIntoConstraints = NO;
    [openButton setContentHuggingPriority:NSLayoutPriorityRequired
                           forOrientation:NSLayoutConstraintOrientationHorizontal];

    for (NSView* v in @[ nameLabel, whyLabel, openButton ]) [row addSubview:v];

    [NSLayoutConstraint activateConstraints:@[
        [nameLabel.topAnchor constraintEqualToAnchor:row.topAnchor],
        [nameLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],

        [whyLabel.topAnchor constraintEqualToAnchor:nameLabel.bottomAnchor constant:3.0],
        [whyLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [whyLabel.trailingAnchor constraintEqualToAnchor:openButton.leadingAnchor constant:-12.0],

        [openButton.topAnchor constraintGreaterThanOrEqualToAnchor:whyLabel.topAnchor],
        [openButton.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [openButton.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],

        [whyLabel.bottomAnchor constraintLessThanOrEqualToAnchor:row.bottomAnchor],
    ]];

    return row;
}

- (void)showPermissionsWizard:(id)sender {
    (void)sender;
    if (!_permissionsWizardPanel) {
        _permissionsWizardPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0.0, 0.0, 460.0, 420.0)
                                                             styleMask:NSWindowStyleMaskTitled
                                                               backing:NSBackingStoreBuffered
                                                                 defer:NO];
        _permissionsWizardPanel.title = @"ShenzhenPDF Permissions";
        _permissionsWizardPanel.releasedWhenClosed = NO;
        _permissionsWizardPanel.floatingPanel = YES;
        _permissionsWizardPanel.hidesOnDeactivate = NO;
        _permissionsWizardPanel.level = NSModalPanelWindowLevel;
        _permissionsWizardPanel.collectionBehavior =
            NSWindowCollectionBehaviorMoveToActiveSpace | NSWindowCollectionBehaviorFullScreenAuxiliary;
        NSView* content = [[NSView alloc] initWithFrame:_permissionsWizardPanel.contentView.bounds];
        _permissionsWizardPanel.contentView = content;

        NSTextField* titleLabel = [NSTextField labelWithString:@"ShenzhenPDF Permissions"];
        titleLabel.font = [NSFont systemFontOfSize:18.0 weight:NSFontWeightSemibold];
        titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

        NSTextField* introLabel = [NSTextField
            wrappingLabelWithString:@"Granting these once lets ShenzhenPDF open PDFs from any location and zoom "
                                    @"unfocused windows without repeated macOS prompts."];
        introLabel.font = [NSFont systemFontOfSize:12.0];
        introLabel.textColor = SPDFCollectionColor(@"secondary");
        introLabel.translatesAutoresizingMaskIntoConstraints = NO;

        NSView* axRow = [self
            permissionsWizardRowWithName:@"Accessibility (trackpad zoom)"
                                     why:@"Zoom an unfocused ShenzhenPDF window with a trackpad pinch while another "
                                         @"app "
                                         @"is in front. Grant this here to enable the feature; it takes effect after "
                                         @"the next app switch or relaunch."
                          settingsAction:@selector(openAccessibilitySettings)];

        NSView* fdaRow = [self
            permissionsWizardRowWithName:@"Full Disk Access"
                                     why:@"Open PDFs from any folder, and from other apps' data (e.g. files saved by "
                                         @"Messages/WeChat/Mail), without per-folder prompts. Quit and reopen "
                                         @"ShenzhenPDF after granting this for it to take effect."
                          settingsAction:@selector(openFullDiskAccessSettings)];

        NSBox* separator = [[NSBox alloc] initWithFrame:NSZeroRect];
        separator.boxType = NSBoxSeparator;
        separator.translatesAutoresizingMaskIntoConstraints = NO;

        NSTextField* noteLabel = [NSTextField
            wrappingLabelWithString:@"Some permissions only take full effect after you quit and reopen ShenzhenPDF. "
                                    @"If a “data from other apps” prompt still appears, granting Full Disk Access "
                                    @"above resolves it."];
        noteLabel.font = [NSFont systemFontOfSize:11.0];
        noteLabel.textColor = SPDFCollectionColor(@"secondary");
        noteLabel.translatesAutoresizingMaskIntoConstraints = NO;

        NSButton* doneButton = [NSButton buttonWithTitle:@"Done" target:self action:@selector(permissionsWizardDone:)];
        doneButton.bezelStyle = NSBezelStyleRounded;
        doneButton.keyEquivalent = @"\r";
        doneButton.translatesAutoresizingMaskIntoConstraints = NO;

        for (NSView* v in @[ titleLabel, introLabel, axRow, fdaRow, separator, noteLabel, doneButton ])
            [content addSubview:v];

        [NSLayoutConstraint activateConstraints:@[
            [titleLabel.topAnchor constraintEqualToAnchor:content.topAnchor constant:22.0],
            [titleLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24.0],
            [titleLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-24.0],

            [introLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:8.0],
            [introLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24.0],
            [introLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-24.0],

            [axRow.topAnchor constraintEqualToAnchor:introLabel.bottomAnchor constant:20.0],
            [axRow.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24.0],
            [axRow.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-24.0],

            [fdaRow.topAnchor constraintEqualToAnchor:axRow.bottomAnchor constant:18.0],
            [fdaRow.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24.0],
            [fdaRow.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-24.0],

            [separator.topAnchor constraintEqualToAnchor:fdaRow.bottomAnchor constant:18.0],
            [separator.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24.0],
            [separator.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-24.0],

            [noteLabel.topAnchor constraintEqualToAnchor:separator.bottomAnchor constant:12.0],
            [noteLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24.0],
            [noteLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-24.0],

            [doneButton.topAnchor constraintGreaterThanOrEqualToAnchor:noteLabel.bottomAnchor constant:16.0],
            [doneButton.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-24.0],
            [doneButton.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-18.0],
            [doneButton.widthAnchor constraintGreaterThanOrEqualToConstant:86.0],
        ]];
    }

    if (_permissionsWizardPanel.parentWindow != _window) {
        [_permissionsWizardPanel.parentWindow removeChildWindow:_permissionsWizardPanel];
        if (_window) [_window addChildWindow:_permissionsWizardPanel ordered:NSWindowAbove];
    }

    if (_window) {
        NSRect windowFrame = _window.frame;
        NSRect panelFrame = _permissionsWizardPanel.frame;
        panelFrame.origin.x = NSMidX(windowFrame) - NSWidth(panelFrame) * 0.5;
        panelFrame.origin.y = NSMidY(windowFrame) - NSHeight(panelFrame) * 0.5;
        [_permissionsWizardPanel setFrame:panelFrame display:NO];
    } else {
        [_permissionsWizardPanel center];
    }

    [NSApp activateIgnoringOtherApps:YES];
    [_permissionsWizardPanel orderFrontRegardless];
    [_permissionsWizardPanel makeKeyAndOrderFront:nil];
}

// "Done" dismisses the wizard. On first launch the shortcut-help panel is held
// back until the wizard is gone (see the post-first-paint block) so permissions
// is the first thing the user sets; reveal it now. The wizard is a child window
// with no close box, so a plain orderOut is the dismissal — there is no close
// notification to hook, hence this direct action.
- (void)permissionsWizardDone:(id)sender {
    (void)sender;
    [_permissionsWizardPanel orderOut:nil];
    if (!_pendingShortcutHelpAfterPermissions) return;
    _pendingShortcutHelpAfterPermissions = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
      [self showShortcutHelp:nil];
    });
}

// First-launch auto-show: replaces the old standalone Full Disk Access prompt so
// the user is guided through every permission in one place, and only ever once.
// Runs in the deferred post-first-paint block, never on the launch critical path.
- (BOOL)showPermissionsWizardOnFirstLaunchIfNeeded {
    if (_permissionsWizardShown || self.detachedTabLaunch) return NO;
    _permissionsWizardShown = YES;
    [self savePersistentState];
    [self showPermissionsWizard:nil];
    return YES;
}

- (void)makeDefaultPDFReader:(id)sender {
    (void)sender;
    [self promptToMakeDefaultPDFReaderFromLaunch:NO];
}

- (void)showContextMenuForDocumentView:(NSView*)view event:(NSEvent*)event {
    NSMenu* menu = [self contextMenuForDocumentView:view event:event];
    [NSMenu popUpContextMenu:menu withEvent:event forView:view];
}

- (void)unimplementedMenuItem:(id)sender {
    (void)sender;
    NSBeep();
    _statusLabel.stringValue = @"This Shenzhen PDF command is listed but not implemented yet.";
}

- (void)openSettingsFile:(id)sender {
    NSMenuItem* item = [NSMenuItem new];
    item.representedObject = @"settings.yaml";
    [self openStateFile:item];
}

- (void)openStateFile:(id)sender {
    [self savePersistentState];
    NSString* name = [sender respondsToSelector:@selector(representedObject)] ? [sender representedObject] : nil;
    if (![name isKindOfClass:NSString.class] || name.length == 0) name = @"settings.yaml";
    NSString* path = [self pathForStateFile:name];
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
        id empty = [name isEqualToString:@"favorites.yaml"] ? @[] : @{};
        [self writeStateObject:empty toFile:name];
    }
    NSURL* url = [NSURL fileURLWithPath:path];
    if (![NSWorkspace.sharedWorkspace openURL:url]) {
        NSBeep();
        _statusLabel.stringValue = [NSString stringWithFormat:@"Could not open %@.", name];
    }
}

- (void)revealSettingsFolder:(id)sender {
    (void)sender;
    [self showPathInFolder:[self supportDirectory]];
}

- (void)toggleDefaultSidebarForNewDocuments:(id)sender {
    (void)sender;
    _defaultSidebarVisibleForNewDocuments = !_defaultSidebarVisibleForNewDocuments;
    [self savePersistentState];
}

- (void)toggleDefaultMinimapForNewDocuments:(id)sender {
    (void)sender;
    _defaultMinimapVisibleForNewDocuments = !_defaultMinimapVisibleForNewDocuments;
    [self savePersistentState];
}

- (void)toggleSearchJumpsToNearestResult:(id)sender {
    (void)sender;
    _searchJumpsToNearestResult = !_searchJumpsToNearestResult;
    [self savePersistentState];
}

- (void)findNext:(id)sender {
    (void)sender;
    [self findFromCurrentForward:YES];
}

- (void)findPrevious:(id)sender {
    (void)sender;
    [self findFromCurrentForward:NO];
}

- (void)findFromCurrentForward:(BOOL)forward {
    if ([self isMarkdownActive]) {
        if (_searchField.stringValue.length == 0) return;
        if (self.activeMarkdownSession.searchMatches.count == 0)
            [self startFindForCurrentQuery];
        else
            [self moveMarkdownFindForward:forward];
        return;
    }
    if (!_doc || _searchField.stringValue.length == 0) return;

    if (_findMatches.count == 0) {
        [self startFindForCurrentQuery];
        return;
    }
    NSInteger next = _findMatchIndex;
    if (next < 0)
        next = forward ? 0 : (NSInteger)_findMatches.count - 1;
    else
        next = (next + (forward ? 1 : -1) + (NSInteger)_findMatches.count) % (NSInteger)_findMatches.count;
    [self jumpToFindMatchAtIndex:next];
}

- (void)controlTextDidChange:(NSNotification*)notification {
    if (notification.object == _searchField) {
        [self startFindForCurrentQuery];
    } else if (notification.object == _sidebarFilterField) {
        if (_updatingSidebarFilterField) return;
        [self setSidebarFilterTextForCurrentMode:_sidebarFilterField.stringValue ?: @""];
        [self rebuildSidebar];
    } else if (notification.object == _paletteSearchField) {
        _paletteFavoritePendingDelete = nil;
        [self refreshPaletteResults];
    } else if (notification.object == _shortcutHelpSearchField) {
        [self refreshShortcutHelpRows];
    }
}

- (BOOL)control:(NSControl*)control textView:(NSTextView*)textView doCommandBySelector:(SEL)commandSelector {
    (void)textView;
    if (control == _sidebarFilterField && commandSelector == @selector(cancelOperation:)) {
        [self dismissSidebarFilterField]; return YES;
    }
    if (control == _searchField) {
        if (commandSelector == @selector(cancelOperation:)) {
            [self dismissWorkspaceFind];
            return YES;
        }
        if (commandSelector == @selector(insertNewline:) ||
            commandSelector == @selector(insertNewlineIgnoringFieldEditor:)) {
            BOOL shift = (NSApp.currentEvent.modifierFlags & (NSEventModifierFlagShift | NSEventModifierFlagCommand)) != 0;
            if (_findMatches.count > 0)
                [self findFromCurrentForward:!shift];
            else
                [self startFindForCurrentQuery];
            return YES;
        }
        return NO;
    }
    if (control == _pageField) {
        if (commandSelector == @selector(cancelOperation:)) {
            // Escape cancels the page-number edit without committing the typed
            // value (abortEditing first so the focus change cannot fire the
            // field's action), returns focus to the document, and clears the
            // active search like Escape everywhere else in the viewer.
            [_pageField abortEditing];
            [_window makeFirstResponder:[self activeDocumentKeyView]];
            [self documentEscapeKeyDown:NSApp.currentEvent];
            return YES;
        }
        return NO;
    }
    if (control == _shortcutHelpSearchField) {
        if (commandSelector == @selector(cancelOperation:)) {
            [self closeShortcutHelp:control];
            return YES;
        }
        return NO;
    }
    if (control != _paletteSearchField) return NO;
    if (commandSelector == @selector(moveDown:)) {
        [self paletteMoveSelection:1];
        return YES;
    }
    if (commandSelector == @selector(moveUp:)) {
        [self paletteMoveSelection:-1];
        return YES;
    }
    if (commandSelector == @selector(insertNewline:) ||
        commandSelector == @selector(insertNewlineIgnoringFieldEditor:)) {
        [self activatePaletteSelection:control];
        return YES;
    }
    if (commandSelector == @selector(cancelOperation:)) {
        [self closePalette:control];
        return YES;
    }
    return NO;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView*)tableView {
    if (tableView == _paletteTable) return (NSInteger)_paletteResults.count;
    if (tableView == _shortcutHelpTable) return (NSInteger)_shortcutHelpRows.count;
    return (NSInteger)_sidebarItems.count;
}

// Height of a comment sidebar row: the wrapped annotation text (capped at
// kSidebarCommentMaxLines) plus kSidebarCommentVerticalPadding above and below.
// Single-line comments fall back to the standard row height so they read just
// like chapter rows.
- (CGFloat)sidebarCommentRowHeightForText:(id)text {
    NSString* string = [text isKindOfClass:NSString.class] ? text : @"";
    CGFloat columnWidth = _sidebarTable.tableColumns.firstObject.width;
    if (!isfinite(columnWidth) || columnWidth <= 0.0) columnWidth = NSWidth(_sidebarTable.bounds);
    // 8pt leading + 6pt trailing inset, matching the SidebarCell text constraints.
    CGFloat available = MAX(40.0, columnWidth - 14.0);
    NSFont* font = [NSFont systemFontOfSize:13];
    NSMutableParagraphStyle* paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.lineBreakMode = NSLineBreakByWordWrapping;
    NSRect rect =
        [string boundingRectWithSize:NSMakeSize(available, CGFLOAT_MAX)
                             options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                          attributes:@{NSFontAttributeName : font, NSParagraphStyleAttributeName : paragraph}];
    CGFloat lineHeight = ceil(font.ascender - font.descender + font.leading);
    CGFloat textHeight = MIN(ceil(NSHeight(rect)), lineHeight * (CGFloat)kSidebarCommentMaxLines);
    return MAX(_sidebarTable.rowHeight, textHeight + 2.0 * kSidebarCommentVerticalPadding);
}

- (CGFloat)tableView:(NSTableView*)tableView heightOfRow:(NSInteger)row {
    if (tableView == _shortcutHelpTable) {
        if (row < 0 || row >= (NSInteger)_shortcutHelpRows.count) return 48.0;
        return SPDFShortcutHelpRowHeight(_shortcutHelpRows[(NSUInteger)row]);
    }
    if (tableView != _paletteTable) {
        if (row >= 0 && row < (NSInteger)_sidebarItems.count) {
            NSDictionary* item = _sidebarItems[(NSUInteger)row];
            NSString* kind = item[@"kind"];
            if ([kind isEqualToString:@"findResult"] || [kind isEqualToString:@"findDivider"])
                return SPDFSidebarFindRowHeight(item);
            if ([kind isEqualToString:@"findStatus"]) {
                CGFloat visibleHeight = NSHeight(tableView.enclosingScrollView.contentView.bounds);
                return MAX(36.0, floor(visibleHeight));
            }
            if ([kind isEqualToString:@"comment"]) return [self sidebarCommentRowHeightForText:item[@"title"]];
        }
        return _sidebarTable.rowHeight;
    }
    return [self paletteHeightForRow:row];
}

- (NSIndexSet*)tableView:(NSTableView*)tableView
    selectionIndexesForProposedSelection:(NSIndexSet*)proposedSelectionIndexes {
    if (tableView == _shortcutHelpTable) return [NSIndexSet indexSet];
    if (tableView == _sidebarTable) {
        NSMutableIndexSet* filtered = [NSMutableIndexSet indexSet];
        [proposedSelectionIndexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL* stop) {
          (void)stop;
          if (idx >= self->_sidebarItems.count) return;
          NSString* kind = self->_sidebarItems[idx][@"kind"];
          if ([kind isEqualToString:@"findDivider"] || [kind isEqualToString:@"findStatus"]) return;
          [filtered addIndex:idx];
        }];
        return filtered;
    }
    if (tableView != _paletteTable) return proposedSelectionIndexes;
    NSMutableIndexSet* filtered = [NSMutableIndexSet indexSet];
    [proposedSelectionIndexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL* stop) {
      (void)stop;
      if (idx < self->_paletteResults.count && [self isSelectablePaletteResult:self->_paletteResults[idx]])
          [filtered addIndex:idx];
    }];
    return filtered;
}

- (NSView*)tableView:(NSTableView*)tableView viewForTableColumn:(NSTableColumn*)tableColumn row:(NSInteger)row {
    if (tableView == _shortcutHelpTable) {
        if (row < 0 || row >= (NSInteger)_shortcutHelpRows.count) return nil;
        return SPDFShortcutHelpRowView(_shortcutHelpRows[(NSUInteger)row]);
    }

    if (tableView == _paletteTable) return [self workspacePaletteViewForRow:row];

    if (row < 0 || row >= (NSInteger)_sidebarItems.count) return nil;

    NSDictionary* item = _sidebarItems[(NSUInteger)row];
    NSString* kind = item[@"kind"];
    if ([kind isEqualToString:@"findDivider"] || [kind isEqualToString:@"findStatus"] ||
        [kind isEqualToString:@"findResult"]) {
        NSArray<NSValue*>* matches = [kind isEqualToString:@"findResult"]
            ? [self rangesOfPaletteQuery:item[@"query"] ?: @"" inString:item[@"title"] ?: @"" limit:0] : @[];
        return SPDFSidebarFindCell(tableView,item,matches);
    }

    NSTableCellView* cell = [self sidebarCellForTableView:tableView];

    // Cells are reused across comment and chapter rows, so set the line behavior
    // every time. Comments wrap to a few lines (the row is sized to match in
    // -sidebarCommentRowHeightForText:); chapters stay a single truncated line.
    if ([item[@"kind"] isEqualToString:@"comment"]) {
        cell.textField.lineBreakMode = NSLineBreakByWordWrapping;
        cell.textField.maximumNumberOfLines = kSidebarCommentMaxLines;
        cell.textField.cell.usesSingleLineMode = NO;
    } else {
        cell.textField.lineBreakMode = NSLineBreakByTruncatingTail;
        cell.textField.maximumNumberOfLines = 1;
        cell.textField.cell.usesSingleLineMode = YES;
    }

    [self styleSidebarCell:cell item:item];
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification*)notification {
    if (notification.object == _paletteTable) return;
    if (_updatingSelection) return;
    if (_sidebarTable.clickedRow >= 0) return;
    [self activateSidebarRow:notification.object];
}

- (void)activateSidebarRow:(id)sender {
    (void)sender;
    if (![self hasActiveDocument]) return;
    if (_updatingSelection) return;
    NSInteger row = _sidebarTable.clickedRow >= 0 ? _sidebarTable.clickedRow : _sidebarTable.selectedRow;
    if (row < 0 || row >= (NSInteger)_sidebarItems.count) return;
    NSDictionary* item = _sidebarItems[(NSUInteger)row];
    if ([self isMarkdownActive]) {
        [self activateMarkdownSidebarItem:item];
        return;
    }
    NSString* kind = item[@"kind"];
    if ([kind isEqualToString:@"findResult"]) {
        NSInteger findIndex = [item[@"findIndex"] integerValue];
        [self jumpToFindMatchAtIndex:findIndex];
        return;
    }
    if ([kind isEqualToString:@"findDivider"] || [kind isEqualToString:@"findStatus"]) return;
    NSInteger page = [item[@"page"] integerValue];
    if (page < 0) return;

    _pageIndex = MAX(0, MIN(page, spdf_page_count(_doc) - 1));
    _pageView.currentPageIndex = _pageIndex;
    [self renderPageIfNeededAtIndex:_pageIndex];
    [self resizeDocumentView];

    NSValue* boundsValue = item[@"bounds"];
    if ([kind isEqualToString:@"comment"] && boundsValue) {
        NSRect bounds = [boundsValue rectValue];
        [self scrollToPageRect:bounds pageIndex:_pageIndex];
        [self flashPageRect:bounds pageIndex:_pageIndex];
    } else {
        [self scrollToPage:_pageIndex alignTop:YES];
    }
    [self updateControls];
}

- (BOOL)validateMenuItem:(NSMenuItem*)menuItem {
    SEL action = menuItem.action;
    BOOL hasDoc = [self hasActiveDocument];
    BOOL markdown = [self isMarkdownActive];
    if (action == @selector(showCollectionManager:) || action == @selector(showCollectionHistory:) ||
        action == @selector(showCollectionPreviousVersion:) || action == @selector(showCollectionRecovery:)) return YES;
    if (action == @selector(closeDocument:))
        return [self aiChatWindow].isKeyWindow || spdf_mac_tab_close_action_enabled((NSInteger)_tabs.count, _selectedTabIndex, hasDoc);
    if (action == @selector(paste:))
        return !_presentationMode && (SPDFClipboardHasDocument(NSPasteboard.generalPasteboard) ||
               (hasDoc && [NSPasteboard.generalPasteboard canReadObjectForClasses:@[ NSString.class ] options:@{}]));
    if (action == @selector(openDocument:) || action == @selector(openPathPrompt:) || action == @selector(newTabRequested:) ||
        action == NSSelectorFromString(@"createEmptyTabGroupFromPlus:") ||
        action == @selector(showUnifiedSettings:) || action == @selector(showAIChats:) ||
        action == @selector(toggleFullScreen:) || action == @selector(showFavoritesPalette:) ||
        action == @selector(showFindPalette:) || action == @selector(focusFind:) ||
        action == @selector(setCommentAuthor:) || action == @selector(openRecentDocument:) ||
        action == @selector(openSettingsFile:) || action == @selector(openStateFile:) ||
        action == @selector(revealSettingsFolder:) || action == @selector(showShortcutHelp:) ||
        action == @selector(makeDefaultPDFReader:) || action == @selector(showPermissionsWizard:) ||
        action == @selector(showAboutPanel:) || action == @selector(checkForUpdates:))
        return YES;
    if (action == @selector(toggleAutomaticUpdateChecks:)) {
        menuItem.state = _autoUpdateEnabled ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (action == @selector(toggleDefaultSidebarForNewDocuments:)) {
        menuItem.state = _defaultSidebarVisibleForNewDocuments ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (action == @selector(toggleDefaultMinimapForNewDocuments:)) {
        menuItem.state = _defaultMinimapVisibleForNewDocuments ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (action == @selector(toggleDefaultImageColors:)) {
        menuItem.state = _darkThemePreservesImagesDefault ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (action == @selector(toggleDarkThemePreservesImages:)) {
        menuItem.state = !_darkThemePreservesImages ? NSControlStateValueOn : NSControlStateValueOff;
        return [self hasActiveDocument];
    }
    if (action == @selector(toggleReadingTheme:)) {
        menuItem.title = self.readingThemeToggleTitle;
        return YES;
    }
    if (action == @selector(toggleSearchJumpsToNearestResult:)) {
        menuItem.state = _searchJumpsToNearestResult ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (action == @selector(fillWindow:) || action == @selector(centerWindowInScreen:) ||
        action == @selector(moveWindowToLeftHalf:) || action == @selector(moveWindowToRightHalf:) ||
        action == @selector(moveWindowToTopHalf:) || action == @selector(moveWindowToBottomHalf:))
        return _window != nil && !_presentationMode && ![self firstResponderIsEditingText];
    if (action == @selector(returnToPreviousTab:))
        return [self hasPreviousTabTargetFromCurrent:[self selectedTab]];
    if (action == @selector(reopenLastClosedDocument:))
        return _closedDocumentPaths.count > 0 || [self firstRecentlyOpenedPathNotOpen].length > 0;
    if (action == @selector(toggleSidebar:)) {
        menuItem.title = _sidebarVisible ? @"Hide Side Panel" : @"Show Side Panel";
        menuItem.state = _sidebarVisible ? NSControlStateValueOn : NSControlStateValueOff;
        return _sidebarModeControl != nil;
    }
    if (action == @selector(toggleChaptersPanel:) || action == @selector(toggleCommentsPanel:)) {
        BOOL chapters = action == @selector(toggleChaptersPanel:);
        BOOL hasItems = chapters ? (markdown ? [self markdownHasChapters] : _outline.count > 0)
                                 : (!markdown && _comments.count > 0);
        NSString* panelName = chapters ? @"Chapters Panel" : @"Comments Panel";
        BOOL selectedVisible = _sidebarVisible && _sidebarModeControl.spdf_selectedSidebarMode ==
                                                      (chapters ? SPDFSidebarModeChapters : SPDFSidebarModeComments);
        menuItem.title = [NSString stringWithFormat:@"%@ %@", selectedVisible ? @"Hide" : @"Show", panelName];
        menuItem.state = selectedVisible ? NSControlStateValueOn : NSControlStateValueOff;
        return hasDoc && hasItems;
    }
    if (action == @selector(togglePresentation:)) {
        // "(F5)" advertises the second shortcut; ⇧⌘F shows in the key column.
        menuItem.title = _presentationMode ? @"Exit Presentation Mode (F5)" : @"Presentation Mode (F5)";
        menuItem.state = _presentationMode ? NSControlStateValueOn : NSControlStateValueOff;
        return hasDoc;
    }
    if (action == @selector(toggleMinimap:)) {
        menuItem.title = _minimapVisible ? @"Hide Minimap" : @"Show Minimap";
        menuItem.state = _minimapVisible ? NSControlStateValueOn : NSControlStateValueOff;
        return hasDoc;
    }
    if (action == @selector(toggleFindRegexMultiline:)) {
        menuItem.state = _findRegexMultiline ? NSControlStateValueOn : NSControlStateValueOff;
        return !markdown;
    }
    if (action == @selector(toggleCollapseWhitespaceWhenCopyingText:)) {
        menuItem.state = _collapseWhitespaceWhenCopyingText ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (action == @selector(togglePreventSleepInPresentation:)) {
        menuItem.state = _preventSleepInPresentation ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (action == @selector(searchSelectedTextInBrowser:))
        return
            [self trimmedSelectedTextForCommand].length > 0;
    if (action == @selector(showSelectionTranslationPanel:))
        return spdf_translation_selection_enabled([self translationContext]);
    if (action == @selector(copySelection:))
        return [self trimmedSelectedTextForCommand].length > 0 ||
               (markdown && [self.activeMarkdownSession selectionContainsImage]);
    if (action == @selector(addComment:)) return !markdown && hasDoc && (_selectedText.length > 0 || _contextPageIndex >= 0);
    if (action == @selector(editComment:)) return !markdown && hasDoc && [self commentIndexForEditAction:menuItem] >= 0;
    if (action == @selector(deleteComment:)) return !markdown && hasDoc && [self commentIndexForEditAction:menuItem] >= 0;
    if (action == @selector(rotateClockwise:) || action == @selector(rotateAnticlockwise:))
        return [self canRotateActivePage];
    if (action == @selector(ocrDocument:)) return hasDoc && SPDFOCRPathSupported(_path);
    if (action == @selector(deleteAllTextFromDocument:))
        return hasDoc && [_path.pathExtension.lowercaseString isEqualToString:@"pdf"];
    if (action == @selector(translateDocument:)) {
        spdf_translation_context context = [self translationContext];
        return spdf_translation_command_enabled(context);
    }
    if (action == @selector(saveDocumentAs:))
        return markdown || (hasDoc && SPDFOCRPathSupported(_path));
    if (action == @selector(showInFolder:)) return hasDoc && _path.length > 0;
    if (action == @selector(copyCurrentDocumentPath:)) return hasDoc && _path.length > 0;
    if (action == @selector(copyCurrentDocumentFile:)) return hasDoc && _path.length > 0;
    if (action == @selector(copyCurrentPageAsPDF:)) return [self canCopyCurrentPageAsPDF];
    if (action == @selector(copyCurrentPageImage:)) return [self canCopyCurrentPageImage];
    if (action == @selector(showProperties:)) return [self selectedTab].path.length > 0;
    if (!hasDoc) return action == @selector(unimplementedMenuItem:);

    if (action == @selector(fitWidth:))
        menuItem.state = _fitMode == SPDFFitModeWidth ? NSControlStateValueOn : NSControlStateValueOff;
    else if (action == @selector(fitHeight:))
        menuItem.state = _fitMode == SPDFFitModeHeight ? NSControlStateValueOn : NSControlStateValueOff;
    else if (action == @selector(fitPage:))
        menuItem.state = _fitMode == SPDFFitModePage ? NSControlStateValueOn : NSControlStateValueOff;
    else if (action == @selector(actualSize:))
        menuItem.state = _fitMode == SPDFFitModeActual ? NSControlStateValueOn : NSControlStateValueOff;

    return YES;
}

- (void)showError:(NSString*)message detail:(NSString*)detail {
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = message;
    alert.informativeText = detail ?: @"";
    alert.alertStyle = NSAlertStyleWarning;
    [alert runModal];
}

@end
int main(int argc, const char* argv[]) {
    @autoreleasepool {
        // Anchor the whole timeline on the kernel spawn time, so every later
        // line's absolute "@" stamp can be read as time-since-spawn without the
        // harness having to record the spawn itself.
        spdf_launch_profile_log(@"main enter (spawn @%.1f, +%.1fms)", spdf_process_spawn_time_ms(),
                                spdf_zoom_profile_now_ms() - spdf_process_spawn_time_ms());
        for (int i = 1; i < argc; ++i) {
            if (strcmp(argv[i], "--collection-companion") == 0) return SPDFRunCollectionCompanion();
            if (strcmp(argv[i], "--agent-command") == 0)
                return SPDFMacRunAgentCommand(i + 1 < argc ? argv[i + 1] : NULL);
            if (strcmp(argv[i], "--version") == 0) {
                NSDictionary* info = NSBundle.mainBundle.infoDictionary;
                NSString* shortVersion = info[@"CFBundleShortVersionString"] ?: @"";
                NSString* build = info[(NSString*)kCFBundleVersionKey] ?: @"";
                printf("Shenzhen PDF portable mac %s-%s\n", shortVersion.UTF8String, build.UTF8String);
                return 0;
            }
            // Atomic-swap helper: run from the CURRENT trusted in-place binary,
            // entirely as a Foundation-only function, and return BEFORE any
            // AppKit delegate / NSApplication is constructed.
            if (strcmp(argv[i], "--post-update") == 0 && i + 2 < argc) {
                NSString* staged = [NSString stringWithUTF8String:argv[i + 1]];
                NSString* target = [NSString stringWithUTF8String:argv[i + 2]];
                return spdf_run_post_update_helper(staged, target);
            }
        }
        ShenzhenMacDelegate* delegate = [[ShenzhenMacDelegate alloc] init];
        for (int i = 1; i < argc; ++i) {
            if (strcmp(argv[i], "--detached-tab") == 0) {
                delegate.detachedTabLaunch = YES;
                continue;
            }
            if (strcmp(argv[i], "--restore-window") == 0 && i + 1 < argc) {
                delegate.restoreWindowID = [NSString stringWithUTF8String:argv[++i]];
                continue;
            }
            if (argv[i][0] != '-') {
                delegate.initialPath = [NSString stringWithUTF8String:argv[i]];
                break;
            }
        }
        // Migrate any JSON state files to YAML before the first state read
        // (the prerender below peeks at session.yaml).
        [delegate migrateStateFilesIfNeeded];

        // Start the document prerender before NSApplication init so the
        // background open/render overlaps AppKit startup and window build.
        [delegate startLaunchPrerender];
        spdf_mac_prefetch_launch_state();

        NSApplication* app = [NSApplication sharedApplication];
        spdf_launch_profile_log(@"NSApplication sharedApplication done");
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
