// Tab hover thumbnails: what each tab's preview is made from, when it is made,
// and the budget it is kept in. See SPDFMacTabHoverPreview.h.
//
// Nothing here runs at launch. The first viewport render only schedules one
// timer; the cache, its queues and its observers exist from the first time the
// pointer enters the tab bar, or 5 s after the first page painted, whichever
// comes first. From then on a thumbnail is scaled, on a utility queue, from
// whole-page pixels the reader already holds: the page of every tab shown since
// launch, and of every inactive tab once the reader's own preload has rendered
// it. That happens 0.4 s after a page settles, after a tab switch, when the
// preload finishes and when the app goes to the background. On hover, a
// thumbnail that no longer matches (another page, a turn, an edit, a reload,
// the reading theme) is remade at once from those pixels; a tab with none yet
// (hovered before the preload reached it) shows its title alone and its page
// fades in when a render from its file lands, about 0.1 s later.
//
// A text tab (Markdown, plain text, code) gets its current page as the reader
// lays it out: drawn from the tab's live layout once it has been shown, from
// its file before that (SPDFMacTabHoverPreviewText.h). Every other document
// the reader opens (images, Office files, EPUB, XPS) has pages like a PDF and
// goes the PDF way.
#import "SPDFMacTabHoverPreviewIntegration.h"
#import "SPDFMacLaunchPrerenderPrivate.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacTabPreviewCache.h"
#import "SPDFMacTabHoverPreviewText.h"
#import "SPDFMacMarkdownSessionPrivate.h"
#import "markdown/SPDFTextDocumentFormats.h"
#import <objc/runtime.h>
#include <sys/stat.h>

static const NSTimeInterval kPreviewSettleDelay = 0.4;
static const NSTimeInterval kPreviewIdleArmDelay = 5.0;

@interface SPDFTabHoverPreviewState : NSObject
@property(nonatomic, strong) SPDFTabPreviewCache* cache;
@property(nonatomic, strong) dispatch_queue_t scaleQueue;
@property(nonatomic, strong) dispatch_queue_t fileQueue;
@property(nonatomic, strong) dispatch_source_t memoryPressure;
@property(nonatomic, strong) id resignObserver;
@property(nonatomic) BOOL armed;
@property(nonatomic) BOOL idleArmScheduled;
@property(nonatomic) BOOL prepareScheduled;
// Tabs with a thumbnail being made, and who is waiting for it.
@property(nonatomic, strong) NSMapTable<SPDFDocumentTab*, NSMutableArray*>* pending;
// Files that could not be rendered (locked, unreadable), by stamp: not retried until they change.
@property(nonatomic, strong) NSMutableSet<NSString*>* failedStamps;
@property(nonatomic) CGFloat lastScale;
@end
@implementation SPDFTabHoverPreviewState
@end

// What a tab's thumbnail is made from right now, read on the main thread.
@interface SPDFTabPreviewSourceInfo : NSObject
@property(nonatomic) NSInteger pageIndex;
@property(nonatomic) NSSize pageSize;     // zero when the page is not laid out in memory
@property(nonatomic, strong) NSImage* image; // whole-page pixels in memory, or nil
@property(nonatomic) unsigned renderFlags;
@property(nonatomic, copy) NSString* fileStamp;
// A text tab: how it is laid out now, and that layout in memory when the tab
// has one that matches (the plan and the text it draws), else nil.
@property(nonatomic) BOOL text;
@property(nonatomic) SPDFTabPreviewTextLayout textLayout;
@property(nonatomic, strong) SPDFMarkdownPaginationPlan* textPlan;
@property(nonatomic, strong) NSAttributedString* textString;
@end
@implementation SPDFTabPreviewSourceInfo
@end

static char kStateKey;

static unsigned long long SPDFTabPreviewTextFileSize(NSString* path) {
    struct stat info;
    return path.length && lstat(path.fileSystemRepresentation, &info) == 0 ? (unsigned long long)info.st_size : ULLONG_MAX;
}

static NSBitmapImageRep* BitmapRep(NSImage* image) {
    for (NSImageRep* rep in image.representations)
        if ([rep isKindOfClass:NSBitmapImageRep.class]) return (NSBitmapImageRep*)rep;
    return nil;
}

@implementation ShenzhenMacDelegate (TabHoverPreview)

- (SPDFTabHoverPreviewState*)spdf_tabPreviewState {
    SPDFTabHoverPreviewState* state = objc_getAssociatedObject(self, &kStateKey);
    if (!state) {
        state = [SPDFTabHoverPreviewState new];
        objc_setAssociatedObject(self, &kStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

- (SPDFTabPreviewCache*)spdf_tabPreviewCache { return [self spdf_tabPreviewState].cache; }

- (void)spdf_armTabHoverPreviews {
    SPDFTabHoverPreviewState* state = [self spdf_tabPreviewState];
    if (state.armed) return;
    state.armed = YES;
    state.cache = [[SPDFTabPreviewCache alloc] initWithByteBudget:kSPDFTabPreviewByteBudget];
    state.scaleQueue = dispatch_queue_create("ShenzhenPDF.tab-preview.scale",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    state.fileQueue = dispatch_queue_create("ShenzhenPDF.tab-preview.file",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    state.pending = [NSMapTable weakToStrongObjectsMapTable];
    state.failedStamps = [NSMutableSet set];
    state.lastScale = _window.backingScaleFactor ?: 2.0;
    // Thumbnails are a convenience: under memory pressure they all go, and
    // come back from the page pixels or the files when next wanted.
    __weak SPDFTabHoverPreviewState* weakState = state;
    state.memoryPressure = dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
        DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL, dispatch_get_main_queue());
    dispatch_source_set_event_handler(state.memoryPressure, ^{ [weakState.cache removeAllEntries]; });
    dispatch_resume(state.memoryPressure);
    __weak ShenzhenMacDelegate* weakSelf = self;
    state.resignObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:NSApplicationDidResignActiveNotification object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification* note) { (void)note; [weakSelf spdf_prepareTabHoverPreviews]; }];
}

- (void)spdf_noteTabHoverPreviewSourcesChanged {
    SPDFTabHoverPreviewState* state = [self spdf_tabPreviewState];
    if (!state.armed) {
        if (state.idleArmScheduled) return;
        state.idleArmScheduled = YES;
        __weak ShenzhenMacDelegate* weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPreviewIdleArmDelay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [weakSelf spdf_armTabHoverPreviews];
            [weakSelf spdf_prepareTabHoverPreviews];
        });
        return;
    }
    if (state.prepareScheduled) return;
    state.prepareScheduled = YES;
    __weak ShenzhenMacDelegate* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPreviewSettleDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ShenzhenMacDelegate* strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf spdf_tabPreviewState].prepareScheduled = NO;
        [strongSelf spdf_prepareTabHoverPreviews];
    });
}

- (void)tabHoverPreviewsWillBeNeeded {
    [self spdf_armTabHoverPreviews];
    // After this event: the hover it carries shows its label first.
    __weak ShenzhenMacDelegate* weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf spdf_prepareTabHoverPreviews]; });
}

// The reading-theme flags a page of this tab is rendered with: the theme is
// the reader's, keeping image colors is each document's own choice.
- (unsigned)spdf_previewRenderFlagsForTab:(SPDFDocumentTab*)tab {
    unsigned flags = [self readingThemeRenderFlags];
    if (!(flags & SPDF_RENDER_DARK_THEME) || tab == [self selectedTab]) return flags;
    return SPDF_RENDER_DARK_THEME | (tab.preservesImageColors ? SPDF_RENDER_PRESERVE_IMAGES : 0u);
}

// The page a tab shows and the best whole-page pixels of it in memory: for
// the selected tab the live view, for another tab what it held when left.
// A text tab's page: the reader's own layout of it when it has one in the
// theme, type size and paper it would show now, else its file and that layout.
- (SPDFTabPreviewSourceInfo*)spdf_textPreviewSourceForTab:(SPDFDocumentTab*)tab {
    SPDFTabPreviewSourceInfo* info = [SPDFTabPreviewSourceInfo new];
    info.text = YES;
    SPDFTabPreviewTextLayout layout = {self.markdownThemeVariant, tab.preservesImageColors, _markdownFontScale,
                                       tab.markdownLandscape};
    info.textLayout = layout;
    info.renderFlags = (unsigned)layout.variant;
    info.fileStamp = SPDFTabPreviewTextStamp(tab.path, layout);
    SPDFMacMarkdownSession* session = tab.cachedMarkdownSession;
    BOOL live = session && session == [self activeMarkdownSession] && tab == [self selectedTab];
    info.pageIndex = MAX(0, live ? session.currentPageIndex : tab.pageIndex);
    SPDFMarkdownPaginationPlan* plan = session.paginationPlan;
    NSAttributedString* string = session.renderedDocument.attributedString;
    SPDFMarkdownPageConfiguration* paper = plan.configuration;
    BOOL turned = paper.paperSize.width > paper.paperSize.height;
    if (plan.pages.count && string && paper.themeVariant == layout.variant &&
        session.fontScale == SPDFMacMarkdownClampFontScale(layout.fontScale) && turned == layout.landscape &&
        (layout.variant != SPDFMarkdownThemeVariantDark || paper.preservesImageColors == layout.preservesImageColors)) {
        info.textPlan = plan;
        info.textString = string;
        info.pageSize = paper.paperSize;
    }
    return info;
}

- (SPDFTabPreviewSourceInfo*)spdf_previewSourceForTab:(SPDFDocumentTab*)tab {
    if (!tab.path.length || tab.missingFile) return nil;
    if (SPDFIsRenderedTextDocumentPath(tab.path)) return [self spdf_textPreviewSourceForTab:tab];
    BOOL selected = tab == [self selectedTab] && _doc;
    SPDFTabPreviewSourceInfo* info = [SPDFTabPreviewSourceInfo new];
    NSArray<SPDFRenderedPage*>* pages = selected ? _renderedPages : tab.cachedRenderedPages;
    info.pageIndex = MAX(0, selected ? _pageIndex : tab.pageIndex);
    info.fileStamp = SPDFTabPreviewFileStamp(tab.path);
    info.renderFlags = [self spdf_previewRenderFlagsForTab:tab];
    SPDFRenderedPage* page = info.pageIndex < (NSInteger)pages.count ? pages[(NSUInteger)info.pageIndex] : nil;
    BOOL dark = (info.renderFlags & SPDF_RENDER_DARK_THEME) != 0;
    BOOL themed = page.imageDarkTheme == dark &&
                  (!dark || page.imagePreservesImageColors == ((info.renderFlags & SPDF_RENDER_PRESERVE_IMAGES) != 0));
    if (page && page.pageWidth > 0 && page.pageHeight > 0 && themed) {
        info.pageSize = NSMakeSize(page.pageWidth, page.pageHeight);
        // The smallest whole-page render at least as wide as the thumbnail is
        // the cheapest to scale and loses nothing; else the widest there is.
        NSInteger wanted = (NSInteger)ceil(SPDFTabPreviewPointSize(info.pageSize, kSPDFTabPreviewMaxPoints).width *
                                           [self spdf_tabPreviewState].lastScale);
        NSImage* best = nil;
        NSInteger bestWidth = 0;
        for (NSImage* image in @[ page.image ?: NSNull.null, page.highQualityImage ?: NSNull.null,
                                  page.baseImage ?: NSNull.null, page.minimapImage ?: NSNull.null ]) {
            if (![image isKindOfClass:NSImage.class]) continue;
            NSInteger width = BitmapRep(image).pixelsWide;
            if (width <= 0) continue;
            BOOL better = !best || (bestWidth < wanted ? width > bestWidth : (width >= wanted && width < bestWidth));
            if (better) { best = image; bestWidth = width; }
        }
        info.image = best;
    }
    return info;
}

// Whether `entry` shows what `info` describes. Pixels in memory decide when
// there are some: the same image, or one of the same page in the same file.
- (BOOL)spdf_previewEntry:(SPDFTabPreviewEntry*)entry matches:(SPDFTabPreviewSourceInfo*)info exact:(BOOL*)exact {
    if (exact) *exact = NO;
    if (!entry || !info || entry.pageIndex != info.pageIndex || entry.renderFlags != info.renderFlags) return NO;
    if (!info.fileStamp || ![entry.fileStamp isEqualToString:info.fileStamp]) return NO;
    id live = info.image ?: info.textPlan;
    if (!live) {
        if (exact) *exact = YES;
        return YES;
    }
    if (!NSEqualSizes(entry.pageSize, info.pageSize)) return NO;
    if (exact) *exact = entry.source == live;
    return YES;
}

- (SPDFTabPreviewEntry*)spdf_previewEntryFromImage:(CGImageRef)source info:(SPDFTabPreviewSourceInfo*)info
                                             scale:(CGFloat)scale {
    NSSize points = SPDFTabPreviewPointSize(info.pageSize, kSPDFTabPreviewMaxPoints);
    CGImageRef thumbnail = SPDFTabPreviewCreateThumbnail(source, (size_t)lround(points.width * scale),
                                                         (size_t)lround(points.height * scale));
    if (!thumbnail) return nil;
    SPDFTabPreviewEntry* entry = [[SPDFTabPreviewEntry alloc] initWithImage:thumbnail pointSize:points
                                                                  pageIndex:info.pageIndex];
    CGImageRelease(thumbnail);
    entry.pageSize = info.pageSize;
    entry.renderFlags = info.renderFlags;
    entry.fileStamp = info.fileStamp;
    entry.source = info.image;
    return entry;
}

// A text tab's page drawn from its layout in memory. Any thread.
static SPDFTabPreviewEntry* TextEntryFromLayout(SPDFTabPreviewSourceInfo* info, CGFloat scale) {
    SPDFTabPreviewEntry* entry = SPDFTabPreviewEntryForTextPage(info.textPlan, info.textString, info.pageIndex, scale);
    entry.renderFlags = info.renderFlags;
    entry.fileStamp = info.fileStamp;
    entry.source = info.textPlan;
    return entry;
}

- (void)spdf_finishPreview:(SPDFTabPreviewEntry*)entry forTab:(SPDFDocumentTab*)tab {
    SPDFTabHoverPreviewState* state = [self spdf_tabPreviewState];
    NSArray* waiters = [state.pending objectForKey:tab];
    [state.pending removeObjectForKey:tab];
    if (!entry) return;
    [state.cache setEntry:entry forTab:tab];
    for (void (^ready)(id<SPDFTabHoverPreview>) in waiters) ready(entry);
}

- (BOOL)spdf_beginPreviewForTab:(SPDFDocumentTab*)tab ready:(void (^)(id<SPDFTabHoverPreview>))ready {
    SPDFTabHoverPreviewState* state = [self spdf_tabPreviewState];
    NSMutableArray* waiters = [state.pending objectForKey:tab];
    BOOL running = waiters != nil;
    if (!waiters) [state.pending setObject:(waiters = [NSMutableArray array]) forKey:tab];
    if (ready) [waiters addObject:[ready copy]];
    return !running;
}

// Scales in-memory page pixels off the main thread.
- (void)spdf_scalePreviewForTab:(SPDFDocumentTab*)tab info:(SPDFTabPreviewSourceInfo*)info
                          ready:(void (^)(id<SPDFTabHoverPreview>))ready {
    SPDFTabHoverPreviewState* state = [self spdf_tabPreviewState];
    if (![self spdf_beginPreviewForTab:tab ready:ready]) return;
    if (info.textPlan) {
        CGFloat scale = state.lastScale;
        __weak ShenzhenMacDelegate* weakSelf = self;
        dispatch_async(state.scaleQueue, ^{
            SPDFTabPreviewEntry* entry = TextEntryFromLayout(info, scale);
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf spdf_finishPreview:entry forTab:tab]; });
        });
        return;
    }
    CGImageRef source = SPDFTabPreviewCreateImageReadingRep(BitmapRep(info.image));
    if (!source) {
        [self spdf_finishPreview:nil forTab:tab];
        return;
    }
    CGFloat scale = state.lastScale;
    __weak ShenzhenMacDelegate* weakSelf = self;
    dispatch_async(state.scaleQueue, ^{
        SPDFTabPreviewEntry* entry = [weakSelf spdf_previewEntryFromImage:source info:info scale:scale];
        CGImageRelease(source);
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf spdf_finishPreview:entry forTab:tab]; });
    });
}

// Renders a tab's page from its file, for a tab not shown since launch. The
// same rules as the launch prerender: never a cloud file (it would download),
// never a read-only source except through its current private copy (reading
// the source could prompt), never Markdown (laid out on the main thread).
- (void)spdf_renderPreviewFromFileForTab:(SPDFDocumentTab*)tab info:(SPDFTabPreviewSourceInfo*)info
                                  ready:(void (^)(id<SPDFTabHoverPreview>))ready {
    SPDFTabHoverPreviewState* state = [self spdf_tabPreviewState];
    if (!info.fileStamp || [state.failedStamps containsObject:info.fileStamp]) return;
    if (info.text) {
        [self spdf_renderTextPreviewFromFileForTab:tab info:info ready:ready];
        return;
    }
    NSString* source = tab.path;
    NSString* opened = source;
    if (tab.readOnly) {
        opened = tab.workingPath;
        NSString* copy = tab.copiedSourceModificationDate ? [NSString stringWithFormat:@"%llu:",
            tab.copiedSourceFileSize] : nil;
        if (!opened.length || !copy || ![info.fileStamp hasPrefix:copy]) return;
    }
    if (![self spdf_beginPreviewForTab:tab ready:ready]) return;
    CGFloat scale = state.lastScale;
    NSInteger pageIndex = info.pageIndex;
    unsigned flags = info.renderFlags;
    NSString* stamp = info.fileStamp;
    __weak ShenzhenMacDelegate* weakSelf = self;
    dispatch_async(state.fileQueue, ^{
        ShenzhenMacDelegate* strongSelf = weakSelf;
        SPDFTabPreviewEntry* entry = nil;
        if (strongSelf && ![strongSelf pathIsOnCloudStorage:source]) {
            char err[512] = {0};
            // No stored password: a locked file gets its thumbnail once it has
            // been opened and shown, never a Keychain read in the background.
            [strongSelf ensureSecurityAccessForPath:source];
            if (![opened isEqualToString:source]) [strongSelf ensureSecurityAccessForPath:opened];
            spdf_document* doc = spdf_open(opened.fileSystemRepresentation, err, sizeof(err));
            int count = doc ? spdf_page_count(doc) : 0;
            int page = (int)MIN(pageIndex, (NSInteger)count - 1);
            float width = 0, height = 0;
            if (count > 0 && spdf_page_size(doc, page, &width, &height, err, sizeof(err)) && width > 0) {
                NSSize points = SPDFTabPreviewPointSize(NSMakeSize(width, height), kSPDFTabPreviewMaxPoints);
                spdf_bitmap bitmap = {};
                if (spdf_render_page_rgba_opts(doc, page, (float)(points.width * scale / width), flags, NULL,
                                               &bitmap, err, sizeof(err))) {
                    CGImageRef image = SPDFTabPreviewCreateImageFromRGBA(bitmap.rgba, bitmap.width, bitmap.height,
                                                                         bitmap.stride);
                    spdf_free_bitmap(&bitmap);
                    if (image) {
                        entry = [[SPDFTabPreviewEntry alloc] initWithImage:image pointSize:points pageIndex:page];
                        entry.pageSize = NSMakeSize(width, height);
                        entry.renderFlags = flags;
                        entry.fileStamp = stamp;
                        CGImageRelease(image);
                    }
                }
            }
            if (doc) spdf_close(doc);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            ShenzhenMacDelegate* mainSelf = weakSelf;
            if (!entry) [[mainSelf spdf_tabPreviewState].failedStamps addObject:stamp];
            [mainSelf spdf_finishPreview:entry forTab:tab];
        });
    });
}

// A text tab not shown since launch: laid out from its file, on the file
// queue, under the layout the reader would give it. Never a cloud file.
- (void)spdf_renderTextPreviewFromFileForTab:(SPDFDocumentTab*)tab info:(SPDFTabPreviewSourceInfo*)info
                                       ready:(void (^)(id<SPDFTabHoverPreview>))ready {
    SPDFTabHoverPreviewState* state = [self spdf_tabPreviewState];
    NSString* path = tab.path;
    if ([self pathIsOnCloudStorage:path] || ![self spdf_beginPreviewForTab:tab ready:ready]) return;
    [self ensureSecurityAccessForPath:path];
    CGFloat scale = state.lastScale;
    NSInteger pageIndex = info.pageIndex;
    SPDFTabPreviewTextLayout layout = info.textLayout;
    unsigned flags = info.renderFlags;
    NSString* stamp = info.fileStamp;
    __weak ShenzhenMacDelegate* weakSelf = self;
    dispatch_async(state.fileQueue, ^{
        SPDFTabPreviewEntry* entry = SPDFTabPreviewEntryForTextFile(path, pageIndex, layout, scale);
        entry.renderFlags = flags;
        entry.fileStamp = stamp;
        dispatch_async(dispatch_get_main_queue(), ^{
            ShenzhenMacDelegate* mainSelf = weakSelf;
            if (!entry) [[mainSelf spdf_tabPreviewState].failedStamps addObject:stamp];
            [mainSelf spdf_finishPreview:entry forTab:tab];
        });
    });
}

- (void)spdf_prepareTabHoverPreviews {
    SPDFTabHoverPreviewState* state = [self spdf_tabPreviewState];
    if (!state.armed) return;
    state.lastScale = _window.backingScaleFactor ?: state.lastScale;
    // Most recently viewed first: those are the ones a reader goes back to,
    // and the budget keeps them when it cannot keep every tab.
    NSArray<SPDFDocumentTab*>* tabs = [_tabs sortedArrayUsingComparator:^NSComparisonResult(SPDFDocumentTab* a,
                                                                                            SPDFDocumentTab* b) {
        return a.lastViewedAt > b.lastViewedAt ? NSOrderedAscending
             : a.lastViewedAt < b.lastViewedAt ? NSOrderedDescending : NSOrderedSame;
    }];
    for (SPDFDocumentTab* tab in tabs) {
        if ([state.pending objectForKey:tab]) continue;
        SPDFTabPreviewSourceInfo* info = [self spdf_previewSourceForTab:tab];
        if (!info) continue;
        BOOL exact = NO;
        if ([self spdf_previewEntry:[state.cache entryForTab:tab] matches:info exact:&exact] && exact) continue;
        // A tab with no page in memory yet is left to the reader's own preload
        // of inactive tabs, which calls back here when it is done; a hover
        // before then renders that one tab from its file.
        if (info.image || info.textPlan) [self spdf_scalePreviewForTab:tab info:info ready:nil];
        // A text tab has no preload: a short one is laid out from its file now.
        else if (info.text && SPDFTabPreviewTextFileSize(tab.path) <= kSPDFTabPreviewTextPrepareMaxBytes)
            [self spdf_renderPreviewFromFileForTab:tab info:info ready:nil];
    }
}

- (id<SPDFTabHoverPreview>)tabHoverPreviewForTab:(SPDFDocumentTab*)tab backingScale:(CGFloat)scale
                                           ready:(void (^)(id<SPDFTabHoverPreview>))ready {
    [self spdf_armTabHoverPreviews];
    SPDFTabHoverPreviewState* state = [self spdf_tabPreviewState];
    if (scale > 0 && scale != state.lastScale) {
        state.lastScale = scale;
        [state.cache removeAllEntries];
    }
    SPDFTabPreviewSourceInfo* info = [self spdf_previewSourceForTab:tab];
    if (!info) return nil;
    SPDFTabPreviewEntry* entry = [state.cache entryForTab:tab];
    BOOL exact = NO;
    if ([self spdf_previewEntry:entry matches:info exact:&exact]) {
        // The same page from a newer render (a zoom, a sharper pass): show this
        // one now and swap in the remake when it lands, a few ms later.
        if (!exact) [self spdf_scalePreviewForTab:tab info:info ready:ready];
        return entry;
    }
    if (info.image) {
        // Another page, a turn or an edit since it was made, with the page's
        // pixels in memory: remade here, so the title never shows a stale page
        // or waits for one (about a millisecond from a near-size render).
        CGImageRef source = SPDFTabPreviewCreateImageReadingRep(BitmapRep(info.image));
        entry = source ? [self spdf_previewEntryFromImage:source info:info scale:state.lastScale] : nil;
        if (source) CGImageRelease(source);
        if (entry) [state.cache setEntry:entry forTab:tab];
        return entry;
    }
    if (info.textPlan) {
        // Another page or a new layout of a text tab shown since launch: drawn
        // here from that layout, as the reader draws it.
        entry = TextEntryFromLayout(info, state.lastScale);
        if (entry) [state.cache setEntry:entry forTab:tab];
        return entry;
    }
    [state.cache removeEntryForTab:tab];
    [self spdf_renderPreviewFromFileForTab:tab info:info ready:ready];
    return nil;
}

@end
