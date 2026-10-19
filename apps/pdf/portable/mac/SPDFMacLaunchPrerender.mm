#import <Cocoa/Cocoa.h>

#import "SPDFMacLaunchPrerenderPrivate.h"
#import "SPDFMacMarkdownRouting.h"
#import "SPDFMacModels.h"
#import "SPDFMacSupport.h"

#include "shenzhen_pdf_core.h"

// ---- Launch prerender (prototype) -----------------------------------------
// Started from main() before NSApplication init. A background worker opens the
// document the launch sequence will select (restored active tab, or the
// CLI/Finder-opened file) and, when the restore zoom is viewport-independent
// (Custom/Actual fit), renders the preferred page through the exact same
// renderedPageAtIndex: path the synchronous first paint uses. loadSelectedTab
// adopts the open document and renderDocumentAndScrollToPage adopts the bitmap
// only on exact (path, size, mtime, page, zoom, scale) match. If foreground
// loading arrives first, it either cancels before the worker claims spdf_open
// or takes ownership of that one in-flight open; a second competing open is
// never started.
@interface SPDFLaunchPrerenderResult : NSObject
@property(nonatomic) spdf_document* doc;
@property(nonatomic, strong) SPDFRenderedPage* page;
@property(nonatomic, copy) NSString* path;
// The path the worker was ASKED to prewarm, standardized, before any read-only
// shadow-copy redirection. nil when the target was guessed from session.yaml;
// set when the launch named a document outright (argv, or the openFiles: Apple
// Event). Only an outright named target can be compared against a later
// retarget, and only it is certain enough to justify prewarming metadata.
@property(nonatomic, copy) NSString* requestedPath;
@property(nonatomic) unsigned long long fileSize;
@property(nonatomic, strong) NSDate* modificationDate;
// Sidebar metadata loaded on the worker while the main thread builds the
// window. Owned by the result until adopted or discarded.
@property(nonatomic) spdf_outline outline;
@property(nonatomic) BOOL outlineLoaded;
@property(nonatomic) spdf_comments comments;
@property(nonatomic) BOOL commentsLoaded;
@property(nonatomic, strong) SPDFMacLaunchPrerenderOwnership* ownership;
@property(nonatomic, strong) dispatch_group_t group;
@end
@implementation SPDFLaunchPrerenderResult
@end

static SPDFLaunchPrerenderResult* gSPDFLaunchPrerender;

// Backing scale of the main display without touching AppKit (the worker runs
// before/while NSApplication initializes). Adoption later compares against
// the real window backingScale, so a wrong guess only skips the fast path.
static CGFloat spdf_launch_prerender_display_scale(void) {
    CGDirectDisplayID display = CGMainDisplayID();
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display);
    if (!mode) return 0.0;
    size_t pixelWidth = CGDisplayModeGetPixelWidth(mode);
    CGDisplayModeRelease(mode);
    double pointWidth = CGDisplayBounds(display).size.width;
    if (pointWidth <= 0.0 || pixelWidth == 0) return 0.0;
    return (CGFloat)((double)pixelWidth / pointWidth);
}

// Free prerendered sidebar metadata that was never adopted. Callers hold
// @synchronized(result).
static void spdf_release_prerender_metadata(SPDFLaunchPrerenderResult* result) {
    if (result.outlineLoaded) {
        spdf_outline outline = result.outline;
        spdf_free_outline(&outline);
        result.outline = outline;
        result.outlineLoaded = NO;
    }
    if (result.commentsLoaded) {
        spdf_comments comments = result.comments;
        spdf_free_comments(&comments);
        result.comments = comments;
        result.commentsLoaded = NO;
    }
}

// Discard a never-adopted prerender without blocking the main thread.
void spdf_discard_launch_prerender(void) {
    SPDFLaunchPrerenderResult* result = gSPDFLaunchPrerender;
    gSPDFLaunchPrerender = nil;
    if (!result) return;
    [result.ownership abandon];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      dispatch_group_wait(result.group, DISPATCH_TIME_FOREVER);
      @synchronized(result) {
          spdf_release_prerender_metadata(result);
          if (result.doc) {
              spdf_close(result.doc);
              result.doc = NULL;
          }
      }
    });
}

@implementation ShenzhenMacDelegate (LaunchPrerender)

- (void)startLaunchPrerender {
    if (self.detachedTabLaunch) return;
    if (getenv("SPDF_DISABLE_LAUNCH_PRERENDER")) return;
    // The prerender runs before loadPersistentState, so read the reading theme
    // here: the prerendered page is stamped with it and is only adopted when it
    // matches the live one, so a dark session would otherwise throw its own
    // first paint away. settings.yaml is small and loadPersistentState reads it
    // again moments later from a warm page cache.
    {
        NSDictionary* raw = [self stateObjectFromFile:@"settings.yaml"];
        NSDictionary* settings = [raw isKindOfClass:[NSDictionary class]] ? raw : nil;
        _darkReadingTheme = [settings[@"markdownTheme"] isEqual:@"dark"];
        NSNumber* preservesImages = settings[@"darkThemePreservesImages"];
        // Per-document now, but no tab exists yet: speculate with the launch
        // default. A restored document that stored the other choice makes the
        // prerendered page fail adoption (see renderDocumentAndScrollToPage:)
        // and it is rendered normally instead -- never shown miscolored.
        _darkThemePreservesImagesDefault = preservesImages ? preservesImages.boolValue : YES;
        _darkThemePreservesImages = _darkThemePreservesImagesDefault;
        NSNumber* sidebarVisible = settings[@"defaultSidebarVisibleForNewDocuments"];
        _launchPrerenderSidebarExpected = sidebarVisible ? sidebarVisible.boolValue : YES;
    }
    [self beginLaunchPrerenderForNamedPath:self.initialPath.length > 0 ? self.initialPath.stringByStandardizingPath
                                                                       : nil];
}

// A Finder double-click (or `open file.pdf`) does NOT put the document in argv:
// LaunchServices delivers it as an odoc Apple Event, which AppKit dispatches to
// -application:openFiles: after main() has already started the prerender and
// before -applicationDidFinishLaunching. Until this retarget, the single most
// common launch of all had the prerender speculating on the PREVIOUS session's
// document, so its whole speculative open was thrown away ("launch prerender
// discarded (mismatch)") and the real document was opened cold on the main
// thread. Retargeting here still leaves the worker the whole buildMenu +
// buildWindow stretch to work in.
- (void)retargetLaunchPrerenderToOpenedPath:(NSString*)path {
    if (self.detachedTabLaunch || _uiReady || path.length == 0) return;
    if (getenv("SPDF_DISABLE_LAUNCH_PRERENDER")) return;
    NSString* standardized = path.stringByStandardizingPath;
    SPDFLaunchPrerenderResult* existing = gSPDFLaunchPrerender;
    if (existing.requestedPath.length > 0 && [existing.requestedPath isEqualToString:standardized]) return;
    spdf_discard_launch_prerender();
    [self beginLaunchPrerenderForNamedPath:standardized];
}

// namedPath: the document the launch named outright (argv or openFiles:), or
// nil to speculate on session.yaml's selected tab.
- (void)beginLaunchPrerenderForNamedPath:(NSString*)namedPath {
    NSString* initialPath = [namedPath copy];
    // Prewarm the sidebar metadata off-main for BOTH a named target and a
    // session guess. A wrong session guess is never adopted — the identity check
    // in -takeLaunchPrerenderedDocumentForPath: frees the metadata on mismatch —
    // so there is no correctness cost; the only cost is wasted work, and both
    // waste paths are bounded. (1) A foreground claim that lands mid-load waits
    // for the same outline/comments the main thread would otherwise load
    // synchronously; for the document that is actually adopted that is never
    // worse than the main-thread load it replaces. (2) A retarget (a Finder odoc
    // replacing the session guess, which abandons this worker ~70ms in) wastes
    // whatever the abandoned worker had loaded; the ownership.abandoned re-checks
    // in the metadata loop below trim that when the abandon lands between steps,
    // and the residual runs off-main without delaying the retargeted document's
    // first paint (see the loop for the full argument).
    BOOL prewarmMetadata = _launchPrerenderSidebarExpected;
    NSString* restoreWindowID = [self.restoreWindowID copy];
    SPDFLaunchPrerenderResult* result = [[SPDFLaunchPrerenderResult alloc] init];
    result.ownership = [[SPDFMacLaunchPrerenderOwnership alloc] init];
    result.group = dispatch_group_create();
    result.requestedPath = initialPath;
    gSPDFLaunchPrerender = result;
    dispatch_group_async(result.group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      NSString* path = nil;
      NSInteger pageIndex = 0;
      double predictedZoom = 0.0; // 0 = open-only prewarm (no page render)
      // Read-only shadow copy: when the restored source is read-only, prerender
      // must open the persisted temp copy (never the source) to avoid the macOS
      // access prompt at launch. These mirror the tab's persisted fields.
      NSString* persistedWorkingPath = nil;
      unsigned long long persistedCopyFileSize = 0;
      double persistedCopyModifiedAt = 0.0;
      if (initialPath.length > 0) {
          // CLI/Finder open: that file becomes the selected tab. Its zoom is
          // viewport-dependent (fit mode), so prewarm the open only.
          path = initialPath.stringByStandardizingPath;
      } else {
          // Peek at session.yaml the same way loadPersistentState resolves the
          // restored window and selected tab.
          NSData* data = [NSData dataWithContentsOfFile:[self pathForStateFile:@"session.yaml"]];
          NSDictionary* session = spdf_state_object_from_yaml_data(data);
          if (![session isKindOfClass:NSDictionary.class]) session = nil;
          NSArray* rawWindows = [session[@"windows"] isKindOfClass:NSArray.class] ? session[@"windows"] : @[];
          NSDictionary* windowState = nil;
          NSMutableArray<NSDictionary*>* windows = [NSMutableArray array];
          for (NSDictionary* window in rawWindows) {
              if (![window isKindOfClass:NSDictionary.class]) continue;
              NSArray* rawTabs = [window[@"tabs"] isKindOfClass:NSArray.class] ? window[@"tabs"] : @[];
              NSMutableArray* tabs = [NSMutableArray array];
              for (NSDictionary* tab in rawTabs) {
                  if (![tab isKindOfClass:NSDictionary.class]) continue;
                  NSString* tabPath = [tab[@"path"] isKindOfClass:NSString.class] ? tab[@"path"] : nil;
                  if (tabPath.length > 0) [tabs addObject:tab];
              }
              if (tabs.count == 0) continue;
              NSMutableDictionary* copy = [window mutableCopy];
              copy[@"tabs"] = tabs;
              [windows addObject:copy];
          }
          if (restoreWindowID.length > 0) {
              for (NSDictionary* candidate in windows) {
                  if ([candidate[@"id"] isKindOfClass:NSString.class] &&
                      [candidate[@"id"] isEqualToString:restoreWindowID]) {
                      windowState = candidate;
                      break;
                  }
              }
          } else {
              // Same window loadPersistentState will restore: the focused one.
              NSUInteger focused = spdf_session_focused_window_index(windows);
              if (focused != NSNotFound) windowState = windows[focused];
          }
          NSArray* tabs = [windowState[@"tabs"] isKindOfClass:NSArray.class] ? windowState[@"tabs"] : @[];
          if (tabs.count > 0) {
              NSInteger selected = MIN(MAX(0, [windowState[@"selectedTab"] integerValue]), (NSInteger)tabs.count - 1);
              NSDictionary* tab = tabs[(NSUInteger)selected];
              path = [tab[@"path"] isKindOfClass:NSString.class] ? tab[@"path"] : nil;
              if ([tab[@"workingPath"] isKindOfClass:NSString.class] && [tab[@"workingPath"] length] > 0)
                  persistedWorkingPath = tab[@"workingPath"];
              persistedCopyFileSize = (unsigned long long)[tab[@"roCopyFileSize"] unsignedLongLongValue];
              persistedCopyModifiedAt = [tab[@"roCopyModifiedAt"] doubleValue];
              pageIndex = MAX(0, [tab[@"page"] integerValue]);
              // Replicates loadSelectedTab zoom selection exactly for the two
              // viewport-independent fit modes; other modes stay open-only.
              NSInteger fitMode = [tab[@"fitMode"] integerValue];
              if (fitMode == SPDFFitModeCustom) {
                  double customZoom = [tab[@"customZoom"] doubleValue];
                  double zoom = [tab[@"zoom"] doubleValue];
                  double remembered = customZoom > 0 ? customZoom : (zoom > 0 ? zoom : 1.0);
                  predictedZoom = MAX(kMinZoom, MIN(kMaxZoom, remembered));
              } else if (fitMode == SPDFFitModeActual) {
                  predictedZoom = 1.0;
              }
          }
      }
      // DriveFS/cloud/network paths are handled by the launch-only deferred
      // cloud open (loadSelectedTab); do not race a second synchronous open
      // against it. Same predicate as that deferral (CloudStorage file
      // providers plus any non-apfs/hfs mount).
      if (path.length == 0 || SPDFIsRenderedTextDocumentPath(path) || [self pathIsOnCloudStorage:path]) {
          [result.ownership workerDidFinish];
          return;
      }
      // Read-only shadow copy: the source read-only check + change detection use a
      // BARE lstat (silent) — never the prompting -attributesOfItemAtPath:. For a
      // read-only source, open the persisted temp copy when it exists and the
      // bare-lstat (mtime,size) matches the persisted copy stat; otherwise skip
      // prerender so loadSelectedTab (re)creates the copy on the main thread (the
      // single prompt site). The prerender identity (openedPath) is the copy, and
      // the attributes are the bare-lstat source attributes — exactly what
      // loadSelectedTab passes for adoption. Writable sources keep -attributesOf.
      NSString* openedPath = path;
      NSDictionary* attributes = nil;
      if ([self sourcePathIsReadOnly:path]) {
          attributes = [self readOnlySourceAttributesForPath:path];
          BOOL canUseCopy = attributes && persistedWorkingPath.length &&
                            [NSFileManager.defaultManager fileExistsAtPath:persistedWorkingPath] &&
                            persistedCopyModifiedAt > 0.0 &&
                            persistedCopyFileSize == spdf_file_size_from_attributes(attributes);
          if (canUseCopy) {
              NSDate* sourceModified = spdf_file_modification_date_from_attributes(attributes);
              NSDate* persistedModified = [NSDate dateWithTimeIntervalSince1970:persistedCopyModifiedAt];
              canUseCopy = sourceModified && [persistedModified isEqualToDate:sourceModified];
          }
          if (!canUseCopy) {
              [result.ownership workerDidFinish];
              return;
          }
          openedPath = persistedWorkingPath;
      } else {
          attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
          if (!attributes) {
              [result.ownership workerDidFinish];
              return;
          }
      }
      if (![result.ownership workerMayBeginOpen]) {
          [result.ownership workerDidFinish];
          return;
      }
      double openStart = spdf_launch_profile_enabled() ? spdf_zoom_profile_now_ms() : 0.0;
      char err[1024];
      spdf_document* doc = [self openSpdfDocumentAtPath:openedPath
                                             sourcePath:path
                                                 status:NULL
                                                  error:err
                                            errorLength:sizeof(err)];
      if (openStart > 0.0) {
          spdf_launch_profile_log(@"prerender spdf_open %@ %.1fms [bg]", path.lastPathComponent,
                                  spdf_zoom_profile_now_ms() - openStart);
      }
      // Sidebar metadata, off-main. -loadInitialSidebarMetadataForSelectedTabIfNeeded
      // otherwise runs both of these synchronously before the first frame, and
      // spdf_load_comments walks EVERY page of the document to collect
      // annotations — the single most expensive item on the pre-paint main
      // thread for a long document. This stays inside the "Opening" ownership
      // phase deliberately: a foreground claim that lands mid-load waits for
      // this exact work instead of racing it, and for the adopted document
      // waiting is never worse than doing it on the main thread, the only
      // alternative.
      //
      // A session guess is speculative, so a retarget can abandon this worker
      // while the load is in flight (see -beginLaunchPrerenderForNamedPath:); the
      // load would then be wasted work. Re-read ownership.abandoned before each
      // step so an abandon that lands between steps skips the rest — most often
      // the per-page spdf_load_comments walk, the expensive one. spdf_load_comments
      // is not itself cancelable (no fz_cookie for annotation collection), so an
      // abandon that lands after the walk has already started cannot stop it: it
      // runs to completion on this QOS_USER_INITIATED background thread. That
      // residual is acceptable — it is one document's metadata (bounded, not
      // unbounded), and being off-main it does not delay the retargeted
      // document's first paint (measured: no regression versus a clean launch of
      // the same document). For a named target abandoned is never set mid-load —
      // a mid-Opening foreground claim takes WaitForOwnedResult, not abandon — so
      // these checks are free there.
      spdf_outline prewarmedOutline;
      spdf_comments prewarmedComments;
      memset(&prewarmedOutline, 0, sizeof(prewarmedOutline));
      memset(&prewarmedComments, 0, sizeof(prewarmedComments));
      BOOL loadedOutline = NO;
      BOOL loadedComments = NO;
      if (doc && prewarmMetadata && !result.ownership.abandoned) {
          double metadataStart = spdf_launch_profile_enabled() ? spdf_zoom_profile_now_ms() : 0.0;
          if (!spdf_load_outline(doc, &prewarmedOutline, err, sizeof(err))) {
              spdf_free_outline(&prewarmedOutline);
              memset(&prewarmedOutline, 0, sizeof(prewarmedOutline));
          }
          loadedOutline = YES;
          if (!result.ownership.abandoned) {
              if (!spdf_load_comments(doc, &prewarmedComments, err, sizeof(err))) {
                  spdf_free_comments(&prewarmedComments);
                  memset(&prewarmedComments, 0, sizeof(prewarmedComments));
              }
              loadedComments = YES;
          }
          if (metadataStart > 0.0) {
              spdf_launch_profile_log(@"prerender metadata %@ %.1fms%@ [bg]", path.lastPathComponent,
                                      spdf_zoom_profile_now_ms() - metadataStart,
                                      loadedComments ? @"" : @" (abandoned before comments)");
          }
      }
      SPDFRenderedPage* rendered = nil;
      if (doc && predictedZoom > 0.0 && [result.ownership workerMayBeginRender]) {
          NSInteger pageCount = spdf_page_count(doc);
          pageIndex = MAX(0, MIN(pageIndex, pageCount - 1));
          CGFloat displayScale = spdf_launch_prerender_display_scale();
          if (displayScale > 0.0) {
              double renderStart = spdf_launch_profile_enabled() ? spdf_zoom_profile_now_ms() : 0.0;
              rendered = [self renderedPageAtIndex:pageIndex
                                          document:doc
                                              zoom:predictedZoom
                                      displayScale:displayScale
                                             error:err
                                       errorLength:sizeof(err)];
              if (renderStart > 0.0) {
                  spdf_launch_profile_log(@"prerender page=%ld zoom=%.2f %.1fms [bg]", (long)pageIndex, predictedZoom,
                                          spdf_zoom_profile_now_ms() - renderStart);
              }
          }
      }
      @synchronized(result) {
          if (result.ownership.abandoned) {
              if (loadedOutline) spdf_free_outline(&prewarmedOutline);
              if (loadedComments) spdf_free_comments(&prewarmedComments);
              if (doc) spdf_close(doc);
          } else {
              result.doc = doc;
              result.page = rendered;
              result.outline = prewarmedOutline;
              result.outlineLoaded = loadedOutline;
              result.comments = prewarmedComments;
              result.commentsLoaded = loadedComments;
              // Identity is the path actually opened (temp copy for a read-only
              // source) so loadSelectedTab's workingPath-keyed adoption matches.
              // The stat is the source stat: full attributes for writable tabs,
              // the bare-lstat source attributes for read-only tabs — exactly what
              // loadSelectedTab passes for adoption.
              result.path = spdf_mac_normalized_launch_path(openedPath);
              result.fileSize = spdf_file_size_from_attributes(attributes);
              result.modificationDate = spdf_file_modification_date_from_attributes(attributes);
          }
      }
      [result.ownership workerDidFinish];
    });
}

// Called once from loadSelectedTab. Claims or cancels the speculative open,
// returns its document on an exact identity match, and leaves the optional page
// for renderDocumentAndScrollToPage to validate independently.
- (spdf_document*)takeLaunchPrerenderedDocumentForPath:(NSString*)path attributes:(NSDictionary*)attributes {
    SPDFLaunchPrerenderResult* result = gSPDFLaunchPrerender;
    if (!result) return NULL;
    SPDFMacLaunchPrerenderForegroundAction action = [result.ownership claimForForeground];
    if (action == SPDFMacLaunchPrerenderForegroundActionUnavailable) return NULL;
    if (action == SPDFMacLaunchPrerenderForegroundActionOpenInForeground) {
        gSPDFLaunchPrerender = nil;
        spdf_launch_profile_log(@"launch prerender yielded immediately; foreground owns open");
        return NULL;
    }
    if (action == SPDFMacLaunchPrerenderForegroundActionWaitForOwnedResult) {
        spdf_launch_profile_log(@"launch prerender open already running; foreground adopts its result");
        dispatch_group_wait(result.group, DISPATCH_TIME_FOREVER);
    }
    gSPDFLaunchPrerender = nil;
    [result.ownership markConsumed];
    NSDate* modificationDate = spdf_file_modification_date_from_attributes(attributes);
    BOOL match = result.doc &&
                 spdf_mac_launch_file_identity_matches(result.path, result.fileSize, result.modificationDate, path,
                                                       spdf_file_size_from_attributes(attributes), modificationDate);
    if (!match) {
        spdf_release_prerender_metadata(result);
        if (result.doc) spdf_close(result.doc); // worker is done; single-owner again
        spdf_launch_profile_log(@"launch prerender discarded (mismatch)");
        return NULL;
    }
    _launchPrerenderedFirstPage = result.page;
    // Take ownership of the prewarmed metadata; the result must not free it.
    [self releaseLaunchPrerenderedMetadata];
    if (result.outlineLoaded) {
        _launchPrerenderedOutline = result.outline;
        _launchPrerenderedOutlineLoaded = YES;
        result.outlineLoaded = NO;
    }
    if (result.commentsLoaded) {
        _launchPrerenderedComments = result.comments;
        _launchPrerenderedCommentsLoaded = YES;
        result.commentsLoaded = NO;
    }
    if (_launchPrerenderedOutlineLoaded || _launchPrerenderedCommentsLoaded)
        _launchPrerenderedMetadataDocument = result.doc;
    return result.doc;
}

// Free any prewarmed metadata still held here (never adopted by a tab).
- (void)releaseLaunchPrerenderedMetadata {
    _launchPrerenderedMetadataDocument = NULL;
    if (_launchPrerenderedOutlineLoaded) {
        spdf_free_outline(&_launchPrerenderedOutline);
        memset(&_launchPrerenderedOutline, 0, sizeof(_launchPrerenderedOutline));
        _launchPrerenderedOutlineLoaded = NO;
    }
    if (_launchPrerenderedCommentsLoaded) {
        spdf_free_comments(&_launchPrerenderedComments);
        memset(&_launchPrerenderedComments, 0, sizeof(_launchPrerenderedComments));
        _launchPrerenderedCommentsLoaded = NO;
    }
}

@end
