// What a reader process answers on the szpdf channel (SPDFMacAgentServer.h): its windows and documents, opening a
// document (in the background unless asked to the front), a picture of one of its windows, and a nudge that a
// document's comments changed on disk.
#import "SPDFMacAgentServer.h"
#import "SPDFMacBackgroundOpening.h"
#import "SPDFMacDocumentVersionsIntegration.h"
#import "SPDFMacCollectionCompare.h"
#import "SPDFMacMarkdownComments.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacMarkdownSession.h"
#import "SPDFMacModels.h"
#import "SPDFMacPaletteActivation.h"
#import "SPDFMacSzpdfHeadingMatch.h"
#import "markdown/SPDFMarkdownRenderer.h"
#import <PDFKit/PDFKit.h>

#include <vector>

#include "spdf_destination.h"
#include "spdf_outline.h"

@interface ShenzhenMacDelegate (SPDFMacAgentServerHost)
- (void)goToPage:(NSInteger)page preserveSinglePagePosition:(BOOL)preserve;
- (void)openPaths:(NSArray<NSString*>*)paths;
- (void)reloadSelectedTabFromDiskChange;
@end

static NSString* ISODate(NSDate* date) {
    static NSISO8601DateFormatter* formatter;
    if (!formatter) {
        formatter = [NSISO8601DateFormatter new];
        formatter.timeZone = NSTimeZone.localTimeZone;
    }
    return date ? [formatter stringFromDate:date] : nil;
}

static NSString* Standard(NSString* path) {
    return path.stringByResolvingSymlinksInPath.stringByStandardizingPath;
}

// Outermost first: the headings the reader is under, each the last of its level at or before `position` (a page, or
// for Markdown a character of the rendered text).
static NSArray<NSString*>* HeadingPath(NSArray<NSString*>* titles, const std::vector<NSInteger>& levels,
                                       const std::vector<NSInteger>& pages, NSInteger position) {
    NSMutableArray<NSString*>* path = [NSMutableArray array];
    std::vector<NSInteger> pathLevels;
    for (NSUInteger i = 0; i < titles.count; i++) {
        if (pages[i] > position) break;
        while (!pathLevels.empty() && pathLevels.back() >= levels[i]) {
            pathLevels.pop_back();
            [path removeLastObject];
        }
        pathLevels.push_back(levels[i]);
        [path addObject:titles[i]];
    }
    return path;
}

@implementation ShenzhenMacDelegate (SPDFMacAgentServer)

#pragma mark - Where the reader is

// Titles, levels and 0-based pages of the active document's headings (Markdown) or outline (PDF).
- (void)agentHeadings:(NSMutableArray<NSString*>*)titles levels:(std::vector<NSInteger>&)levels
                pages:(std::vector<NSInteger>&)pages ranges:(NSMutableArray<NSValue*>*)ranges {
    SPDFMacMarkdownSession* session = [self isMarkdownActive] ? [self activeMarkdownSession] : nil;
    if (session) {
        if (!session.isNavigationReady) return;
        for (SPDFMarkdownRenderedHeading* heading in session.renderedDocument.headings) {
            [titles addObject:heading.title ?: @""];
            levels.push_back((NSInteger)heading.level);
            pages.push_back((NSInteger)[session pageIndexForRange:heading.attributedRange]);
            [ranges addObject:[NSValue valueWithRange:heading.attributedRange]];
        }
        return;
    }
    if (!_doc) return;
    spdf_outline outline;
    char err[256];
    if (!spdf_load_outline(_doc, &outline, err, sizeof(err))) return;
    for (int i = 0; i < outline.count; ++i) {
        [titles addObject:@(outline.items[i].title ?: "")];
        levels.push_back(outline.items[i].level);
        pages.push_back(outline.items[i].page_index);
        [ranges addObject:[NSValue valueWithRange:NSMakeRange(NSNotFound, 0)]];
    }
    spdf_free_outline(&outline);
}

- (NSInteger)agentCurrentPageIndex {
    SPDFMacMarkdownSession* session = [self isMarkdownActive] ? [self activeMarkdownSession] : nil;
    return session ? session.currentPageIndex : _pageIndex;
}

- (NSDictionary*)agentWhereIs {
    NSMutableArray<NSString*>* titles = [NSMutableArray array];
    NSMutableArray<NSValue*>* ranges = [NSMutableArray array];
    std::vector<NSInteger> levels, pages;
    [self agentHeadings:titles levels:levels pages:pages ranges:ranges];
    NSInteger page = [self agentCurrentPageIndex];
    SPDFMacMarkdownSession* session = [self isMarkdownActive] ? [self activeMarkdownSession] : nil;
    NSArray* path = HeadingPath(titles, levels, pages, page);
    if (session.isNavigationReady) {
        // Markdown knows the first character in view: the heading is the last one starting at or above it.
        std::vector<NSInteger> starts;
        for (NSValue* range in ranges) starts.push_back((NSInteger)range.rangeValue.location);
        path = HeadingPath(titles, levels, starts, (NSInteger)session.visibleAttributedLocation);
    }
    NSInteger count = session ? (NSInteger)session.pageCount : (_doc ? spdf_page_count(_doc) : 0);
    NSMutableDictionary* where = [@{@"page" : @(page + 1), @"pageCount" : @(count), @"headingPath" : path} mutableCopy];
    if (path.count) where[@"heading"] = path.lastObject;
    return where;
}

#pragma mark - Opening

- (void)agentOpen:(NSDictionary*)request reply:(void (^)(NSDictionary*))reply {
    NSString* path = request[@"path"];
    BOOL directory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory] || directory) {
        reply(@{@"opened" : @NO, @"errorCode" : @"not-found", @"error" : [NSString stringWithFormat:@"No document at %@.", path]});
        return;
    }
    BOOL wasShowing = [Standard([self selectedTab].path) isEqualToString:Standard(path)];
    [self openPaths:@[ path ]];
    if ([request[@"front"] boolValue]) spdf_mac_bring_window_to_front(_window);
    else spdf_mac_show_window_in_background(_window);
    if (!_window || (!_window.visible && !_window.miniaturized)) {
        reply(@{@"opened" : @NO, @"errorCode" : @"failed",
                @"error" : @"ShenzhenPDF could not show a window for this document."});
        return;
    }
    if (![Standard([self selectedTab].path) isEqualToString:Standard(path)]) {
        reply(@{@"opened" : @NO, @"windowId" : @(_window.windowNumber), @"errorCode" : @"load-failed",
                @"error" : @"The document did not open."});
        return;
    }
    id previous = nil;
    if ([request[@"reload"] boolValue] && wasShowing) previous = [self agentReloadSelected];
    BOOL wait = [request[@"wait"] boolValue] || [request[@"reload"] boolValue] || request[@"page"] || request[@"heading"];
    if (!wait) {
        reply([self agentOpenResult:path error:nil]);
        return;
    }
    NSMutableDictionary* pending = [request mutableCopy];
    if (previous) pending[@"previousRender"] = previous;
    if ([request[@"reload"] boolValue]) pending[@"reloaded"] = @YES;
    NSTimeInterval timeout = request[@"timeout"] ? [request[@"timeout"] doubleValue] : 20;
    [self agentFinishOpen:pending reply:reply deadline:[NSDate dateWithTimeIntervalSinceNow:timeout] navigated:NO];
}

// Reads the selected tab's file again; answers what the wait must see replaced (a Markdown document's render; a PDF
// reloads at once).
- (id)agentReloadSelected {
    SPDFMacMarkdownSession* session = [self isMarkdownActive] ? [self activeMarkdownSession] : nil;
    id previous = session.renderedDocument ?: NSNull.null;
    [self reloadSelectedTabFromDiskChange];
    return session ? previous : nil;
}

// The layout is final and the first visible page is drawn: a Markdown session laid out (after the reload asked for,
// if any) and drawn once, or a PDF's page in view rendered.
- (BOOL)agentRendered:(NSDictionary*)request {
    SPDFMacMarkdownSession* session = [self isMarkdownActive] ? [self activeMarkdownSession] : nil;
    if (session) {
        id previous = request[@"previousRender"];
        if (session.state != SPDFMacMarkdownSessionReady || !session.isNavigationReady || !session.paginationPlan ||
            (previous && (id)session.renderedDocument == previous))
            return NO;
        [_window displayIfNeeded];
        return YES;
    }
    return _doc && _pageIndex >= 0 && _pageIndex < (NSInteger)_renderedPages.count &&
           _renderedPages[(NSUInteger)_pageIndex].image != nil;
}

- (NSDictionary*)agentOpenResult:(NSString*)path error:(NSDictionary*)error {
    NSMutableDictionary* result = [@{@"opened" : @YES, @"path" : path, @"windowId" : @(_window.windowNumber),
                                     @"front" : @(NSApp.isActive && _window.keyWindow),
                                     @"minimized" : @(_window.miniaturized)} mutableCopy];
    [result addEntriesFromDictionary:[self agentWhereIs]];
    NSDate* disk = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFileModificationDate];
    if (disk) result[@"fileModified"] = ISODate(disk);
    if (error) [result addEntriesFromDictionary:error];
    return result;
}

// Waits (in the run loop's common modes, so a modal panel does not stall it) until the document is laid out, then
// goes to the page or heading asked for, and answers once that is drawn.
- (void)agentFinishOpen:(NSDictionary*)request reply:(void (^)(NSDictionary*))reply deadline:(NSDate*)deadline
              navigated:(BOOL)navigated {
    NSString* path = request[@"path"];
    if (![Standard([self selectedTab].path) isEqualToString:Standard(path)]) {
        reply(@{@"opened" : @NO, @"errorCode" : @"failed",
                @"error" : @"Another document was shown before this one finished opening."});
        return;
    }
    SPDFMacMarkdownSession* session = [self isMarkdownActive] ? [self activeMarkdownSession] : nil;
    if (session.state == SPDFMacMarkdownSessionFailed) {
        reply(@{@"opened" : @NO, @"windowId" : @(_window.windowNumber), @"errorCode" : @"load-failed",
                @"error" : @"The document could not be read."});
        return;
    }
    BOOL laidOut = session ? session.isNavigationReady && (!request[@"previousRender"] ||
                                                           (id)session.renderedDocument != request[@"previousRender"])
                           : _doc != NULL;
    if (laidOut && !navigated) {
        NSDictionary* missing = [self agentGoTo:request];
        if (missing) {
            reply([self agentOpenResult:path error:missing]);
            return;
        }
        navigated = YES;
    }
    if (navigated && [self agentRendered:request]) {
        NSMutableDictionary* result = [[self agentOpenResult:path error:nil] mutableCopy];
        result[@"rendered"] = @YES;
        if (request[@"reloaded"]) result[@"reloaded"] = @YES;
        reply(result);
        return;
    }
    if (deadline.timeIntervalSinceNow <= 0) {
        NSMutableDictionary* result = [[self agentOpenResult:path error:@{
            @"errorCode" : @"timeout", @"error" : @"The document is still loading."}] mutableCopy];
        result[@"rendered"] = @NO;
        reply(result);
        return;
    }
    __weak ShenzhenMacDelegate* weakSelf = self;
    CFRunLoopTimerRef timer = CFRunLoopTimerCreateWithHandler(
        NULL, CFAbsoluteTimeGetCurrent() + (navigated ? 0.1 : 0.05), 0, 0, 0, ^(CFRunLoopTimerRef t) {
          (void)t;
          ShenzhenMacDelegate* reader = weakSelf;
          if (!reader) reply(@{@"opened" : @NO, @"errorCode" : @"failed", @"error" : @"The window closed."});
          else [reader agentFinishOpen:request reply:reply deadline:deadline navigated:navigated];
        });
    CFRunLoopAddTimer(CFRunLoopGetMain(), timer, kCFRunLoopCommonModes);
    CFRelease(timer);
}

// Goes to the page or heading asked for. An error (errorCode, error, and the headings it could mean) when it is not in
// the document, else nil.
- (NSDictionary*)agentGoTo:(NSDictionary*)request {
    SPDFMacMarkdownSession* session = [self isMarkdownActive] ? [self activeMarkdownSession] : nil;
    if (request[@"page"]) {
        NSInteger page = [request[@"page"] integerValue] - 1;
        NSInteger count = session ? (NSInteger)session.pageCount : spdf_page_count(_doc);
        if (page >= count)
            return @{@"errorCode" : @"page-out-of-range",
                     @"error" : [NSString stringWithFormat:@"The document has %ld pages.", (long)count]};
        if (session) [self markdownGoToPage:page];
        else [self goToPage:page preserveSinglePagePosition:NO];
        return nil;
    }
    NSString* wanted = request[@"heading"];
    if (!wanted.length) return nil;
    NSMutableArray<NSString*>* titles = [NSMutableArray array];
    NSMutableArray<NSValue*>* ranges = [NSMutableArray array];
    std::vector<NSInteger> levels, pages;
    [self agentHeadings:titles levels:levels pages:pages ranges:ranges];
    NSMutableArray* levelNumbers = [NSMutableArray array];
    for (NSInteger level : levels) [levelNumbers addObject:@(level)];
    NSMutableArray* rows = [NSMutableArray array];
    NSArray* base = SPDFMacSzpdfHeadingRows(titles, levelNumbers);
    for (NSUInteger i = 0; i < base.count; i++) {
        NSMutableDictionary* row = [base[i] mutableCopy];
        row[@"page"] = @(pages[i] + 1);
        [rows addObject:row];
    }
    NSDictionary* match = SPDFMacSzpdfMatchHeading(rows, wanted);
    if (match[@"index"]) {
        NSUInteger found = [match[@"index"] unsignedIntegerValue];
        if (session) [session revealRange:ranges[found].rangeValue];
        else if (pages[found] >= 0) [self goToPage:pages[found] preserveSinglePagePosition:NO];
        return nil;
    }
    if (!session && _doc && spdf_named_destination_page(_doc, wanted.UTF8String) >= 0) {
        [self goToPage:spdf_named_destination_page(_doc, wanted.UTF8String) preserveSinglePagePosition:NO];
        return nil;
    }
    return match;
}

#pragma mark - Versions

// The versions hooks (SPDFMacDocumentVersionsIntegration.h). The comparison window opens without coming forward
// unless asked to the front (SPDFMacComparisonSetOpensInBackground): never ordered in front of the other apps'
// windows, not even for a frame. With `wait`, the answer comes once both versions are laid out.
- (void)agentVersion:(NSDictionary*)request reply:(void (^)(NSDictionary*))reply {
    NSString* path = request[@"path"];
    NSString* action = request[@"action"];
    NSError* error = nil;
    if ([action isEqual:@"list"]) {
        reply(@{@"path" : path, @"versions" : [self versionsListForPath:path]});
        return;
    }
    if ([action isEqual:@"new"]) {
        NSDictionary* version = [self versionsCreateForPath:path carry:request[@"carry"] error:&error];
        reply(version ? @{@"path" : path, @"version" : version}
                      : @{@"error" : error.localizedDescription ?: @"The version could not be made."});
        return;
    }
    BOOL front = [request[@"front"] boolValue];
    NSSet* before = [NSSet setWithArray:NSApp.windows];
    SPDFMacComparisonSetOpensInBackground(!front);
    BOOL shown = [self versionsCompareForPath:path from:[request[@"older"] integerValue]
                                           to:[request[@"newer"] integerValue] error:&error];
    SPDFMacComparisonSetOpensInBackground(NO);
    if (!shown) {
        reply(@{@"opened" : @NO, @"error" : error.localizedDescription ?: @"The versions could not be compared."});
        return;
    }
    NSWindow* comparison = nil;
    for (NSWindow* window in NSApp.windows)
        if (![before containsObject:window] && window.visible) comparison = window;
    if (front) spdf_mac_bring_window_to_front(comparison ?: _window);
    NSMutableDictionary* answer = [@{@"opened" : @(comparison != nil), @"windowId" : @(comparison.windowNumber),
                                     @"older" : request[@"older"], @"newer" : request[@"newer"],
                                     @"front" : @(front), @"loaded" : @NO} mutableCopy];
    if (![request[@"wait"] boolValue] || !comparison) {
        reply(answer);
        return;
    }
    __block id observer = nil;
    __block BOOL done = NO;
    void (^finish)(NSDictionary*) = ^(NSDictionary* info) {
      if (done) return;
      done = YES;
      if (observer) [NSNotificationCenter.defaultCenter removeObserver:observer];
      answer[@"loaded"] = @(info != nil);
      if (info[@"changes"]) answer[@"changes"] = info[@"changes"];
      if (info[@"error"]) answer[@"error"] = info[@"error"];
      if (!info) answer[@"error"] = @"The comparison is still being prepared after 60 seconds.";
      reply(answer);
    };
    observer = [NSNotificationCenter.defaultCenter addObserverForName:SPDFMacComparisonDidFinishLoadingNotification
                                                               object:comparison queue:nil
                                                           usingBlock:^(NSNotification* note) { finish(note.userInfo); }];
    CFRunLoopTimerRef timer = CFRunLoopTimerCreateWithHandler(NULL, CFAbsoluteTimeGetCurrent() + 60, 0, 0, 0,
                                                              ^(CFRunLoopTimerRef t) { (void)t; finish(nil); });
    CFRunLoopAddTimer(CFRunLoopGetMain(), timer, kCFRunLoopCommonModes);
    CFRelease(timer);
}

#pragma mark - Requests

+ (void)agentServerHandleRequest:(NSDictionary*)request reply:(void (^)(NSDictionary*))reply {
    NSString* command = request[@"command"];
    NSArray<ShenzhenMacDelegate*>* readers = SPDFMacAllWindowControllers();
    BOOL quitting = !readers.count;
    for (ShenzhenMacDelegate* reader in readers) quitting |= !reader->_uiReady || !reader->_window;
    if ([command isEqual:@"state"]) {
        NSMutableArray* windows = [NSMutableArray array];
        for (ShenzhenMacDelegate* reader in readers)
            if (reader->_window) [windows addObject:[reader agentWindowState]];
        reply(@{@"active" : @(NSApp.isActive), @"quitting" : @(quitting), @"windows" : windows});
        return;
    }
    if ([command isEqual:@"screenshot"]) {
        reply([self agentScreenshot:request]);
        return;
    }
    if (quitting) {
        reply(@{@"opened" : @NO, @"quitting" : @YES, @"errorCode" : @"quitting", @"error" : @"ShenzhenPDF is quitting."});
        return;
    }
    if ([command isEqual:@"close"]) {
        [self agentClose:request readers:readers reply:reply];
        return;
    }
    if ([command isEqual:@"watch-comments"]) {
        [self agentWatchComments:request reply:reply];
        return;
    }
    if ([command isEqual:@"comments-changed"]) {
        // szpdf wrote them in its own process: Collection keeps the document with them (SPDFMacMarkdownComments.h).
        [NSNotificationCenter.defaultCenter postNotificationName:SPDFMarkdownCommentsDidChangeNotification
                                                          object:Standard(request[@"path"])];
        NSUInteger refreshed = 0;
        for (ShenzhenMacDelegate* reader in readers) {
            if (![Standard([reader selectedTab].path) isEqualToString:Standard(request[@"path"])]) continue;
            if ([reader isMarkdownActive]) [reader rebuildSidebar];
            else [reader reloadSelectedTabFromDiskChange];
            refreshed++;
        }
        reply(@{@"refreshed" : @(refreshed)});
        return;
    }
    // open and version: the window already showing the document, else the one in front, else the first.
    ShenzhenMacDelegate* target = nil;
    for (ShenzhenMacDelegate* reader in readers)
        if (!target && [reader indexOfTabForPath:request[@"path"]] >= 0) target = reader;
    for (ShenzhenMacDelegate* reader in readers)
        if (!target && reader->_window.keyWindow) target = reader;
    target = target ?: readers.firstObject;
    if ([command isEqual:@"version"]) [target agentVersion:request reply:reply];
    else if ([command isEqual:@"reload"]) [target agentReload:request reply:reply];
    else [target agentOpen:request reply:reply];
}

// PDFKit views (the version comparison) draw their pages in tiled layers that a view's own drawing leaves out: their
// visible pages are drawn into the picture where the view shows them.
static void DrawPDFViews(NSView* view, NSView* root) {
    if ([view isKindOfClass:PDFView.class]) {
        PDFView* pdf = (PDFView*)view;
        NSRect visible = [root convertRect:pdf.visibleRect fromView:pdf];
        for (PDFPage* page in pdf.visiblePages) {
            NSRect box = [page boundsForBox:pdf.displayBox];
            NSRect onScreen = [root convertRect:[pdf convertRect:box fromPage:page] fromView:pdf];
            if (NSIsEmptyRect(onScreen) || NSIsEmptyRect(box)) continue;
            CGContextRef context = NSGraphicsContext.currentContext.CGContext;
            CGContextSaveGState(context);
            CGContextClipToRect(context, NSIntersectionRect(onScreen, visible));
            CGContextSetRGBFillColor(context, 1, 1, 1, 1);
            CGContextFillRect(context, onScreen);
            CGContextTranslateCTM(context, NSMinX(onScreen), NSMinY(onScreen));
            CGContextScaleCTM(context, NSWidth(onScreen) / NSWidth(box), NSHeight(onScreen) / NSHeight(box));
            CGContextTranslateCTM(context, -NSMinX(box), -NSMinY(box));
            [page drawWithBox:pdf.displayBox toContext:context];
            CGContextRestoreGState(context);
        }
        return;
    }
    for (NSView* child in view.subviews)
        if (!child.hidden) DrawPDFViews(child, root);
}

// The window draws itself into a picture: nothing is captured from the screen, so it works for a window behind
// others or off screen, and needs no Screen Recording permission.
+ (NSDictionary*)agentScreenshot:(NSDictionary*)request {
    NSInteger number = [request[@"windowId"] integerValue];
    NSWindow* window = nil;
    for (NSWindow* candidate in NSApp.windows)
        if (candidate.windowNumber == number) window = candidate;
    if (!window) return @{@"error" : @"No such window in this process."};
    NSView* view = window.contentView.superview ?: window.contentView;
    NSRect bounds = view.bounds;
    NSBitmapImageRep* picture = [view bitmapImageRepForCachingDisplayInRect:bounds];
    if (!picture) return @{@"error" : @"The window has nothing to draw."};
    [view cacheDisplayInRect:bounds toBitmapImageRep:picture];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:picture];
    DrawPDFViews(view, view);
    [NSGraphicsContext restoreGraphicsState];
    NSData* png = [picture representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    NSError* error = nil;
    if (![png writeToFile:request[@"output"] options:NSDataWritingAtomic error:&error])
        return @{@"error" : error.localizedDescription ?: @"Could not write the picture."};
    return @{@"path" : request[@"output"], @"windowId" : @(number), @"width" : @(picture.pixelsWide),
             @"height" : @(picture.pixelsHigh), @"visible" : @(window.visible)};
}

@end
