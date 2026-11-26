// When Fill & Sign's and Annotate's changes to a PDF reach its file.
//
// A change is written into the document in memory and shown in the next frame (SPDFMacFillShowFirst.h). The file
// used to be saved right after, in the same turn: 6 to 85 ms on an 11 MB datasheet, and up to 270 ms for the first
// save after opening, which reads every object of the file first. A key or click that came meanwhile waited, so five
// quick Backspaces or a run of nudges stalled on every one. Now the save is owed (spdf_deferred_save.h) and written
// once the changes rest: 0.35 s after the last one, 1 s after the first at the latest, and never while a mouse
// button is down or a key is waiting (2 s at the very latest). The objects the first save would read are read
// beforehand, in steps of a few milliseconds while Fill & Sign or Annotate shows and nothing else is happening.
//
// Whatever reads the file or lets the document go writes the owed save first, so nobody ever sees the file without a
// change that is on screen:
//   - a worker reading the file (a page or a crop rendered, a search, a cursor map, an export) asks for the path with
//     -activeWorkingPath, which writes it (-fillPathAfterPendingSave:);
//   - leaving the document (another tab, Close, Quit, a rename) goes through -rememberActiveTabState, which writes it
//     (-fillSignFlushEdits);
//   - every request over the agent channel (szpdf) writes it before it is handled and before it is answered, and
//     szpdf's own readings of a file ask the running readers first;
//   - a menu command writes it before it runs, except Annotate's own edits (Undo, Delete, the Image menu...);
//   - and spdf_close writes it, should a document go any other way.
// A kill -9 loses the changes of the last half second or so, never a part of one (each save is atomic).
#import "SPDFMacFillSaving.h"

#import "SPDFMacAnnotateIntegrationPrivate.h"
#import "SPDFMacEditedPageThumbnails.h"
#import "SPDFMacFillControllerPrivate.h"
#import "SPDFMacFillShowFirst.h"
#import "SPDFMacViewportRenderPriority.h"

#include "spdf_deferred_save.h"

#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static const NSTimeInterval kSPDFFillSaveRest = 0.35;    // after the last change
static const NSTimeInterval kSPDFFillSaveLatest = 1.0;   // after the first change not yet saved
static const NSTimeInterval kSPDFFillSaveNoLater = 2.0;  // even while the pointer is held or keys keep coming

@interface SPDFFillSaveState : NSObject
@property(nonatomic, strong) NSMutableIndexSet* pages;  // changed since the last save, to draw again after it
@property(nonatomic) spdf_document* doc;                 // the document that owes the save (the active one)
@property(nonatomic) CFTimeInterval firstChange, lastChange;
@property(nonatomic, strong) NSTimer* timer;
@property(nonatomic) BOOL saving;
@property(nonatomic) spdf_document* preparedDoc;  // read ahead (or being read) for its first save
@property(nonatomic, strong) NSTimer* prepareTimer;
@property(nonatomic, strong) id menuObserver;
@property(nonatomic, strong) id viewportObserver;
@property(nonatomic, strong) NSMutableIndexSet* placeholdersRedrawn;  // since they were last shown from memory
@property(nonatomic, copy) NSString* collectionPath;  // a Collection version owed once the saves stop
@property(nonatomic, strong) NSTimer* collectionTimer;
@end
@implementation SPDFFillSaveState
@end

static char kSPDFFillSaveStateKey;

// Implemented by the coordinator and Fill & Sign's integration.
@interface ShenzhenMacDelegate (SPDFMacFillSavingReader)
- (CGFloat)backingScale;
- (void)showError:(NSString*)message detail:(NSString*)detail;
- (void)refreshActiveTabCachedFileAttributesAfterSelfSave;
- (void)cacheActiveRenderedPagesForSelectedTab;
- (void)fillCollectionCatchUp:(NSString*)path;
- (SPDFRenderedPage*)renderedPageAtIndex:(NSInteger)pageIndex
                                document:(spdf_document*)doc
                                    zoom:(CGFloat)zoom
                            displayScale:(CGFloat)displayScale
                                   error:(char*)err
                             errorLength:(size_t)errLen;
@end

// Annotate's own menu commands (Undo, Redo, Cut, Delete, the Image and Colors menus) change the document in memory and
// owe their save like a key does; the File ones, and every other menu command, may read the file.
static BOOL SPDFFillMenuItemReadsFile(NSMenuItem* item) {
    if (![NSStringFromClass([item.target class]) hasPrefix:@"SPDFAnnotate"]) return YES;
    id payload = item.representedObject;
    return [payload isKindOfClass:[NSString class]] &&
           ([payload hasPrefix:@"file."] || [payload isEqual:@"selection.copy_to_file"]);
}

@implementation ShenzhenMacDelegate (SPDFMacFillSaving)

- (SPDFFillSaveState*)fillSaveState {
    SPDFFillSaveState* state = objc_getAssociatedObject(self, &kSPDFFillSaveStateKey);
    if (!state) {
        state = [SPDFFillSaveState new];
        state.pages = [NSMutableIndexSet indexSet];
        state.placeholdersRedrawn = [NSMutableIndexSet indexSet];
        objc_setAssociatedObject(self, &kSPDFFillSaveStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

#pragma mark - Owing and writing

- (void)fillScheduleSaveOfPages:(NSIndexSet*)pages {
    if (!_doc || !_path.length) return;
    SPDFFillSaveState* state = [self fillSaveState];
    if (state.doc && state.doc != _doc) [self fillWritePendingSave];  // not expected: another document still owes one
    if (!spdf_defer_save(_doc, _path.fileSystemRepresentation)) {
        [self showError:@"Couldn't save what you filled in" detail:@"Out of memory."];
        return;
    }
    [state.pages addIndexes:pages];
    [state.placeholdersRedrawn removeIndexes:pages];
    state.doc = _doc;
    CFTimeInterval now = CACurrentMediaTime();
    if (!state.firstChange) state.firstChange = now;
    state.lastChange = now;
    if (!state.viewportObserver && _pageScrollView.contentView) {
        __weak ShenzhenMacDelegate* weakSelf = self;
        state.viewportObserver = [NSNotificationCenter.defaultCenter addObserverForName:NSViewBoundsDidChangeNotification
                                                                                 object:_pageScrollView.contentView
                                                                                  queue:nil
                                                                             usingBlock:^(NSNotification* note) {
                                                                               (void)note;
                                                                               [weakSelf fillViewportChangedWhileSaveOwed];
                                                                             }];
    }
    if (!state.menuObserver) {
        __weak ShenzhenMacDelegate* weakSelf = self;
        state.menuObserver = [NSNotificationCenter.defaultCenter addObserverForName:NSMenuWillSendActionNotification
                                                                             object:nil queue:nil
                                                                         usingBlock:^(NSNotification* note) {
                                                                           if (SPDFFillMenuItemReadsFile(note.userInfo[@"MenuItem"]))
                                                                               [weakSelf fillWritePendingSave];
                                                                         }];
    }
    [self fillArmSaveTimerAt:MIN(now + kSPDFFillSaveRest, state.firstChange + kSPDFFillSaveLatest)];
}

- (void)fillArmSaveTimerAt:(CFTimeInterval)when {
    SPDFFillSaveState* state = [self fillSaveState];
    [state.timer invalidate];
    __weak ShenzhenMacDelegate* weakSelf = self;
    state.timer = [NSTimer timerWithTimeInterval:MAX(0.0, when - CACurrentMediaTime()) repeats:NO
                                           block:^(NSTimer* timer) {
                                             (void)timer;
                                             [weakSelf fillSaveTimerFired];
                                           }];
    [NSRunLoop.mainRunLoop addTimer:state.timer forMode:NSRunLoopCommonModes];
}

- (void)fillSaveTimerFired {
    SPDFFillSaveState* state = [self fillSaveState];
    state.timer = nil;
    if (!state.doc) return;
    // A drag going on, or a key or click waiting to be handled: they go first.
    CFTimeInterval now = CACurrentMediaTime();
    NSEvent* waiting = [NSApp nextEventMatchingMask:NSEventMaskKeyDown | NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown
                                          untilDate:nil inMode:NSDefaultRunLoopMode dequeue:NO];
    if ((NSEvent.pressedMouseButtons || waiting) && now < state.firstChange + kSPDFFillSaveNoLater) {
        [self fillArmSaveTimerAt:now + 0.1];
        return;
    }
    [self fillWritePendingSave];
}

// Writes the save; the pages changed since the last one, to draw again (nil when nothing was written).
- (NSIndexSet*)fillSavePendingNow:(BOOL*)ok {
    SPDFFillSaveState* state = [self fillSaveState];
    *ok = YES;
    if (!state.doc || state.saving || [self existingFillController].busy) return nil;  // a change saves it after
    spdf_document* doc = state.doc;
    NSIndexSet* pages = [state.pages copy];
    [state.timer invalidate];
    state.timer = nil;
    [state.pages removeAllIndexes];
    state.doc = NULL;
    state.firstChange = 0;
    // A document already let go wrote its save as it closed (spdf_close).
    if (doc != _doc || !spdf_deferred_save_path(doc)) return nil;
    char err[1024] = {0};
    state.saving = YES;
    *ok = spdf_save_deferred(doc, err, sizeof(err));
    state.saving = NO;
    if (!*ok) {
        [self fillForgetShownPages:nil];
        [self showError:@"Couldn't save what you filled in" detail:@(err)];
        return nil;
    }
    [self refreshActiveTabCachedFileAttributesAfterSelfSave];
    return pages;
}

- (BOOL)fillWritePendingSave {
    BOOL ok;
    NSIndexSet* pages = [self fillSavePendingNow:&ok];
    if (pages) [self fillRedrawSavedPages:pages];
    return ok;
}

- (NSString*)fillPathAfterPendingSave:(NSString*)path {
    if (!NSThread.isMainThread) return path;
    SPDFFillSaveState* state = objc_getAssociatedObject(self, &kSPDFFillSaveStateKey);
    if (!state.doc) return path;
    BOOL ok;
    NSIndexSet* pages = [self fillSavePendingNow:&ok];
    if (pages.count) [self fillRedrawBeforeNextFrame:pages];  // asked for in the middle of the reader's own work
    return path;
}

// Drawn at the end of this turn, before the window's frame is committed (Core Animation's commit observer runs at
// order 2000000): out of whatever reader method asked, yet never a frame late.
- (void)fillRedrawBeforeNextFrame:(NSIndexSet*)pages {
    __weak ShenzhenMacDelegate* weakSelf = self;
    CFRunLoopObserverRef observer = CFRunLoopObserverCreateWithHandler(
        NULL, kCFRunLoopBeforeWaiting | kCFRunLoopExit, false, 1000, ^(CFRunLoopObserverRef me, CFRunLoopActivity activity) {
          (void)activity;
          CFRunLoopRemoveObserver(CFRunLoopGetMain(), me, kCFRunLoopCommonModes);
          [weakSelf fillRedrawSavedPages:pages];
        });
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, kCFRunLoopCommonModes);
    CFRelease(observer);
}

// The view scrolled or zoomed while a save is owed. A page shown from memory only in part (a high zoom) shows the rest
// of itself from its small picture until sharp crops come, and that picture still had the change missing: it is drawn
// again from memory now, inside the scroll, before the scroll's frame is drawn (the crops for the new part in view
// come from the file, which -activeWorkingPath saves first). The page objects change in place: nothing the reader
// may be going through is replaced.
- (void)fillViewportChangedWhileSaveOwed {
    SPDFFillSaveState* state = objc_getAssociatedObject(self, &kSPDFFillSaveStateKey);
    if (!state.doc || state.doc != _doc || [self existingFillController].busy) return;
    [state.pages enumerateIndexesUsingBlock:^(NSUInteger index, BOOL* stop) {
      (void)stop;
      if (index >= self->_renderedPages.count || ![self fillPageShownInView:index] ||
          [state.placeholdersRedrawn containsIndex:index])
          return;
      [state.placeholdersRedrawn addIndex:index];
      [self fillRedrawPlaceholderOfPage:self->_renderedPages[index] display:NO];
    }];
    _pageView.needsDisplay = YES;
}

#pragma mark - After the save

- (void)fillRedrawSavedPages:(NSIndexSet*)pages {
    if (!_doc) return;
    NSIndexSet* redrawn = [[self fillSaveState].placeholdersRedrawn copy];  // drawn from memory in a scroll already
    [[self fillSaveState].placeholdersRedrawn removeIndexes:pages];
    [self invalidateCursorRegionCache];
    // The changed pages in view were drawn from the document in memory and shown before the save
    // (SPDFMacFillShowFirst.h); the others are drawn again now, and the sharper viewport tiles follow from the saved
    // file.
    __block BOOL needsFullRender = NO;
    CGFloat scale = [self backingScale];
    NSInteger preferred = -1;
    NSArray<NSNumber*>* visible = [self visibleDocumentPageIndexesWithExtraRadius:0 preferredPage:&preferred];
    [pages enumerateIndexesUsingBlock:^(NSUInteger index, BOOL* stop) {
      (void)stop;
      if (index >= self->_renderedPages.count) return;
      SPDFRenderedPage* old = self->_renderedPages[index];
      if ([self fillPageShownWhole:index]) return;  // drawn whole from memory before the save (SPDFMacFillShowFirst.h)
      // A page not drawn yet and not in view renders from the saved file when shown.
      if (!old.image && !old.viewportImage && ![visible containsObject:@(index)]) return;
      if (![self fullPageRenderAllowedForPage:old zoom:self->_zoom displayScale:scale]) {
          if ([self fillPageShownInView:index]) {  // its part in view is drawn; the sharper crops follow below
              if (![redrawn containsIndex:index]) [self fillRedrawPlaceholderOfPage:old display:YES];
              return;
          }
          needsFullRender = YES;
          return;
      }
      char renderErr[512];
      SPDFRenderedPage* page = [self renderedPageAtIndex:(NSInteger)index document:self->_doc zoom:self->_zoom
                                            displayScale:scale error:renderErr errorLength:sizeof(renderErr)];
      if (!page) {
          needsFullRender = YES;
          return;
      }
      page.highlights = old.highlights ?: @[];
      page.selectionRects = old.selectionRects ?: @[];
      [self copyMinimapThumbnailFromPage:old toPage:page];
      [self->_renderedPages replaceObjectAtIndex:index withObject:page];
      [self->_pageView refreshRenderedPages:self->_renderedPages changedPageIndex:(NSInteger)index];
    }];
    [self fillForgetShownPages:pages];
    if (needsFullRender) {
        [self rerenderDocumentAfterEditOfPages:pages
                                 restoreOrigin:[NSValue valueWithPoint:_pageScrollView.contentView.bounds.origin]];
    } else {
        [self refreshMinimapThumbnailsOfEditedPages:pages];
        [self cacheActiveRenderedPagesForSelectedTab];
        [self renderVisiblePageCropsForCurrentViewportIfNeeded];
    }
    // Collection keeps one version per burst of filling, not one per field. (A cancel by selector with a nil object
    // cancelled nothing, since each request carried its path: a version was kept 5 s after every save.)
    SPDFFillSaveState* state = [self fillSaveState];
    NSString* path = [_path copy];
    if (state.collectionPath && ![state.collectionPath isEqual:path]) [self fillCollectionCatchUp:state.collectionPath];
    [state.collectionTimer invalidate];
    state.collectionPath = path;
    __weak ShenzhenMacDelegate* weakSelf = self;
    state.collectionTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:NO block:^(NSTimer* timer) {
      (void)timer;
      ShenzhenMacDelegate* me = weakSelf;
      SPDFFillSaveState* current = me ? [me fillSaveState] : nil;
      NSString* caught = current.collectionPath;
      current.collectionPath = nil;
      current.collectionTimer = nil;
      if (caught) [me fillCollectionCatchUp:caught];
    }];
}

// Past the part in view, a page at a high zoom shows its small picture (the minimap's) until the sharp crops come from
// the file; that picture still had the change missing, so a scroll right after the save showed a deleted object there.
// It is drawn again from memory now (a few milliseconds at that size).
- (void)fillRedrawPlaceholderOfPage:(SPDFRenderedPage*)page display:(BOOL)display {
    if (!page.minimapImage || page.minimapImageZoom <= 0 || page.minimapImageScale <= 0) return;
    char err[512];
    SPDFRenderedPage* small = [self renderedPageAtIndex:page.pageIndex document:_doc zoom:page.minimapImageZoom
                                           displayScale:page.minimapImageScale error:err errorLength:sizeof(err)];
    if (!small.image) return;
    page.minimapImage = small.image;
    if (display) [_pageView refreshRenderedPages:_renderedPages changedPageIndex:page.pageIndex];
}

#pragma mark - Reading ahead for the first save

- (void)fillPrepareSaveWhenIdle {
    SPDFFillSaveState* state = [self fillSaveState];
    if (!_doc || state.preparedDoc == _doc || ![[self existingFillController] isShowing]) return;
    [state.prepareTimer invalidate];
    state.preparedDoc = _doc;
    __weak ShenzhenMacDelegate* weakSelf = self;
    // Default mode only: nothing is read during a drag, a menu or a live resize.
    state.prepareTimer = [NSTimer scheduledTimerWithTimeInterval:0.012 repeats:YES block:^(NSTimer* timer) {
      ShenzhenMacDelegate* me = weakSelf;
      SPDFFillSaveState* current = me ? [me fillSaveState] : nil;
      spdf_document* doc = current.preparedDoc;
      if (!me || !doc || doc != me->_doc) {  // another document now: it is prepared when Fill & Sign shows on it
          [timer invalidate];
          if (current) current.preparedDoc = NULL;
          return;
      }
      CFTimeInterval until = CACurrentMediaTime() + 0.003;
      BOOL done = NO;
      while (!done && CACurrentMediaTime() < until) done = spdf_prepare_save_step(doc, 64);
      if (!done) return;
      [timer invalidate];
      current.preparedDoc = NULL;  // read: a later start finds it marked checked and stops at once
    }];
}

@end
