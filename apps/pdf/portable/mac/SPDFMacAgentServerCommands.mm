// What a reader process answers on the szpdf channel (SPDFMacAgentServer.h): its windows and documents, opening a
// document (in the background unless asked to the front), a picture of one of its windows, and a nudge that a
// document's comments changed on disk.
#import "SPDFMacAgentServer.h"
#import "SPDFMacBackgroundOpening.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacMarkdownSession.h"
#import "SPDFMacModels.h"
#import "SPDFMacPaletteActivation.h"
#import "markdown/SPDFMarkdownRenderer.h"

#include <vector>

#include "spdf_destination.h"
#include "spdf_link.h"
#include "spdf_outline.h"

@interface ShenzhenMacDelegate (SPDFMacAgentServerHost)
- (void)goToPage:(NSInteger)page preserveSinglePagePosition:(BOOL)preserve;
- (void)openPaths:(NSArray<NSString*>*)paths;
- (void)reloadSelectedTabFromDiskChange;
@end

static NSString* ISODate(NSDate* date) {
    static NSISO8601DateFormatter* formatter;
    if (!formatter) formatter = [NSISO8601DateFormatter new];
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

- (NSDictionary*)agentWindowState {
    NSMutableArray* documents = [NSMutableArray array];
    SPDFDocumentTab* selected = [self selectedTab];
    for (SPDFDocumentTab* tab in _tabs) {
        if (!tab.path.length) continue;
        NSDate* disk = [NSFileManager.defaultManager attributesOfItemAtPath:tab.path error:nil][NSFileModificationDate];
        NSMutableDictionary* document = [@{@"path" : tab.path, @"selected" : @(tab == selected)} mutableCopy];
        if (tab == selected) [document addEntriesFromDictionary:[self agentWhereIs]];
        else document[@"page"] = @(tab.pageIndex + 1);
        if (tab.contentLoadedAt) document[@"reloadedAt"] = ISODate(tab.contentLoadedAt);
        if (tab.cachedModificationDate) document[@"loadedFileModified"] = ISODate(tab.cachedModificationDate);
        if (disk) document[@"fileModified"] = ISODate(disk);
        if (disk && tab.cachedModificationDate)
            document[@"upToDate"] = @([disk isEqualToDate:tab.cachedModificationDate]);
        [documents addObject:document];
    }
    NSRect frame = _window.frame;
    return @{
        @"windowId" : @(_window.windowNumber),
        @"title" : _window.title ?: @"",
        @"visible" : @(_window.visible),
        @"onScreen" : @((_window.occlusionState & NSWindowOcclusionStateVisible) != 0),
        @"minimized" : @(_window.miniaturized),
        @"key" : @(_window.keyWindow),
        @"frame" : @[ @(frame.origin.x), @(frame.origin.y), @(frame.size.width), @(frame.size.height) ],
        @"documents" : documents,
    };
}

#pragma mark - Opening

- (void)agentOpen:(NSDictionary*)request reply:(void (^)(NSDictionary*))reply {
    NSString* path = request[@"path"];
    BOOL directory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory] || directory) {
        reply(@{@"opened" : @NO, @"error" : [NSString stringWithFormat:@"No document at %@.", path]});
        return;
    }
    [self openPaths:@[ path ]];
    if ([request[@"front"] boolValue]) spdf_mac_bring_window_to_front(_window);
    else spdf_mac_show_window_in_background(_window);
    if (!_window || (!_window.visible && !_window.miniaturized)) {
        reply(@{@"opened" : @NO, @"error" : @"ShenzhenPDF could not show a window for this document."});
        return;
    }
    if (![Standard([self selectedTab].path) isEqualToString:Standard(path)]) {
        reply(@{@"opened" : @NO, @"windowId" : @(_window.windowNumber), @"error" : @"The document did not open."});
        return;
    }
    BOOL wait = [request[@"wait"] boolValue] || request[@"page"] || request[@"heading"];
    if (!wait) {
        reply([self agentOpenResult:path error:nil]);
        return;
    }
    [self agentFinishOpen:request reply:reply deadline:[NSDate dateWithTimeIntervalSinceNow:20] navigated:NO];
}

- (NSDictionary*)agentOpenResult:(NSString*)path error:(NSString*)error {
    NSMutableDictionary* result = [@{@"opened" : @YES, @"path" : path, @"windowId" : @(_window.windowNumber),
                                     @"front" : @(NSApp.isActive && _window.keyWindow),
                                     @"minimized" : @(_window.miniaturized)} mutableCopy];
    [result addEntriesFromDictionary:[self agentWhereIs]];
    if (error) result[@"error"] = error;
    return result;
}

// Waits (in the run loop's common modes, so a modal panel does not stall it) until the document is ready, then goes
// to the page or heading asked for and answers from where the reader then is.
- (void)agentFinishOpen:(NSDictionary*)request reply:(void (^)(NSDictionary*))reply deadline:(NSDate*)deadline
              navigated:(BOOL)navigated {
    NSString* path = request[@"path"];
    if (![Standard([self selectedTab].path) isEqualToString:Standard(path)]) {
        reply(@{@"opened" : @NO, @"error" : @"Another document was shown before this one finished opening."});
        return;
    }
    SPDFMacMarkdownSession* session = [self isMarkdownActive] ? [self activeMarkdownSession] : nil;
    if (session.state == SPDFMacMarkdownSessionFailed) {
        reply(@{@"opened" : @NO, @"windowId" : @(_window.windowNumber), @"error" : @"The document could not be read."});
        return;
    }
    BOOL ready = session ? session.isNavigationReady : _doc != NULL;
    if (ready && navigated) {
        reply([self agentOpenResult:path error:nil]);
        return;
    }
    if (ready) {
        NSString* missing = [self agentGoTo:request];
        if (missing) {
            reply([self agentOpenResult:path error:missing]);
            return;
        }
        navigated = YES;
    } else if (deadline.timeIntervalSinceNow <= 0) {
        reply(@{@"opened" : @YES, @"windowId" : @(_window.windowNumber),
                @"error" : @"The document is still loading after 20 seconds."});
        return;
    }
    __weak ShenzhenMacDelegate* weakSelf = self;
    CFRunLoopTimerRef timer = CFRunLoopTimerCreateWithHandler(
        NULL, CFAbsoluteTimeGetCurrent() + (navigated ? 0.15 : 0.05), 0, 0, 0, ^(CFRunLoopTimerRef t) {
          (void)t;
          ShenzhenMacDelegate* reader = weakSelf;
          if (!reader) reply(@{@"opened" : @NO, @"error" : @"The window closed."});
          else [reader agentFinishOpen:request reply:reply deadline:deadline navigated:navigated];
        });
    CFRunLoopAddTimer(CFRunLoopGetMain(), timer, kCFRunLoopCommonModes);
    CFRelease(timer);
}

// Goes to the page or heading asked for. A message when it is not in the document, else nil.
- (NSString*)agentGoTo:(NSDictionary*)request {
    SPDFMacMarkdownSession* session = [self isMarkdownActive] ? [self activeMarkdownSession] : nil;
    if (request[@"page"]) {
        NSInteger page = [request[@"page"] integerValue] - 1;
        NSInteger count = session ? (NSInteger)session.pageCount : spdf_page_count(_doc);
        if (page >= count) return [NSString stringWithFormat:@"The document has %ld pages.", (long)count];
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
    std::vector<const char*> utf8;
    for (NSString* title in titles) utf8.push_back(title.UTF8String);
    int found = spdf_link_match_title(wanted.UTF8String, utf8.data(), (int)utf8.size());
    if (found >= 0 && session) [session revealRange:ranges[(NSUInteger)found].rangeValue];
    else if (found >= 0 && pages[(size_t)found] >= 0) [self goToPage:pages[(size_t)found] preserveSinglePagePosition:NO];
    else if (!session && _doc && spdf_named_destination_page(_doc, wanted.UTF8String) >= 0)
        [self goToPage:spdf_named_destination_page(_doc, wanted.UTF8String) preserveSinglePagePosition:NO];
    else return [NSString stringWithFormat:@"No heading matches “%@”.", wanted];
    return nil;
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
        reply(@{@"opened" : @NO, @"quitting" : @YES, @"error" : @"ShenzhenPDF is quitting."});
        return;
    }
    if ([command isEqual:@"comments-changed"]) {
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
    // open: the window already showing the document, else the one in front, else the first.
    ShenzhenMacDelegate* target = nil;
    for (ShenzhenMacDelegate* reader in readers)
        if (!target && [reader indexOfTabForPath:request[@"path"]] >= 0) target = reader;
    for (ShenzhenMacDelegate* reader in readers)
        if (!target && reader->_window.keyWindow) target = reader;
    [target ?: readers.firstObject agentOpen:request reply:reply];
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
    NSData* png = [picture representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    NSError* error = nil;
    if (![png writeToFile:request[@"output"] options:NSDataWritingAtomic error:&error])
        return @{@"error" : error.localizedDescription ?: @"Could not write the picture."};
    return @{@"path" : request[@"output"], @"windowId" : @(number), @"width" : @(picture.pixelsWide),
             @"height" : @(picture.pixelsHigh), @"visible" : @(window.visible)};
}

@end
