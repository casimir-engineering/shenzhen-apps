// The szpdf commands about tabs (SPDFMacAgentServer.h): what each tab shows for `state`, reading a document again,
// closing tabs an agent opened, and waiting for the next change to a document's comments. None of them orders a
// window in or asks to activate the app.
#import "SPDFMacAgentServer.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacMarkdownSession.h"
#import "SPDFMacModels.h"
#import "SPDFMacSzpdfHeadingMatch.h"
#import "SPDFMacSzpdfInternal.h"
#import "markdown/SPDFMarkdownPaginator.h"
#import "markdown/SPDFMarkdownRenderer.h"

#include "spdf_outline.h"

@interface ShenzhenMacDelegate (SPDFMacAgentServerTabsHost)
- (NSInteger)indexOfTabForPath:(NSString*)path;
- (void)closeTabAtIndex:(NSInteger)index;
- (void)discardCachedRuntimeForTab:(SPDFDocumentTab*)tab;
- (BOOL)hasActiveDocument;
@end

static NSString* ISODate(NSDate* date) {
    static NSISO8601DateFormatter* formatter;
    if (!formatter) {
        formatter = [NSISO8601DateFormatter new];
        formatter.timeZone = NSTimeZone.localTimeZone;
    }
    return date ? [formatter stringFromDate:date] : nil;
}

static NSString* Standard(NSString* path) { return path.stringByResolvingSymlinksInPath.stringByStandardizingPath; }

// The heading path at `page` (from 0), from titles, levels and pages in document order.
static NSDictionary* HeadingAt(NSArray<NSString*>* titles, NSArray<NSNumber*>* levels, NSArray<NSNumber*>* pages,
                               NSInteger page) {
    NSArray* rows = SPDFMacSzpdfHeadingRows(titles, levels);
    NSArray* path = @[];
    for (NSUInteger i = 0; i < rows.count; i++)
        if (pages[i].integerValue <= page) path = rows[i][@"path"];
    return @{@"headingPath" : path, @"heading" : path.lastObject ?: NSNull.null};
}

@implementation ShenzhenMacDelegate (SPDFMacAgentServerTabs)

// Where a tab that is not in front is: from its kept Markdown layout or PDF outline, when it has been read.
- (NSDictionary*)agentWhereIsTab:(SPDFDocumentTab*)tab {
    NSMutableArray *titles = [NSMutableArray array], *levels = [NSMutableArray array], *pages = [NSMutableArray array];
    NSInteger count = 0;
    SPDFMacMarkdownSession* session = tab.cachedMarkdownSession;
    SPDFMarkdownPaginationPlan* plan = session.paginationPlan;
    if (plan && session.renderedDocument) {
        // A tab in the background keeps its layout but not its view: the plan answers.
        count = (NSInteger)plan.pages.count;
        for (SPDFMarkdownRenderedHeading* heading in session.renderedDocument.headings) {
            [titles addObject:heading.title ?: @""];
            [levels addObject:@(heading.level)];
            [pages addObject:@([plan firstPageIndexIntersectingRange:heading.attributedRange])];
        }
    } else if (tab.cachedDocument) {
        count = spdf_page_count(tab.cachedDocument);
        spdf_outline outline = tab.cachedOutline;
        for (int i = 0; tab.cachedOutlineLoaded && i < outline.count; i++) {
            [titles addObject:@(outline.items[i].title ?: "")];
            [levels addObject:@(outline.items[i].level)];
            [pages addObject:@(outline.items[i].page_index)];
        }
    } else {
        return @{@"pageCount" : NSNull.null, @"heading" : NSNull.null, @"headingPath" : NSNull.null};
    }
    NSMutableDictionary* where = [HeadingAt(titles, levels, pages, tab.pageIndex) mutableCopy];
    where[@"pageCount"] = @(count);
    return where;
}

- (NSDictionary*)agentWindowState {
    NSMutableArray* documents = [NSMutableArray array];
    SPDFDocumentTab* selected = [self selectedTab];
    for (SPDFDocumentTab* tab in _tabs) {
        if (!tab.path.length) continue;
        NSDate* disk = [NSFileManager.defaultManager attributesOfItemAtPath:tab.path error:nil][NSFileModificationDate];
        BOOL loaded = tab.contentLoadedAt != nil || (tab == selected && [self hasActiveDocument]);
        NSMutableDictionary* document = [@{@"path" : tab.path, @"selected" : @(tab == selected), @"loaded" : @(loaded),
                                           @"page" : @(tab.pageIndex + 1), @"fileModified" : ISODate(disk) ?: NSNull.null,
                                           @"reloadedAt" : NSNull.null, @"loadedFileModified" : NSNull.null,
                                           @"upToDate" : NSNull.null, @"pageCount" : NSNull.null,
                                           @"heading" : NSNull.null, @"headingPath" : NSNull.null} mutableCopy];
        if (loaded) {
            [document addEntriesFromDictionary:tab == selected ? [self agentWhereIs] : [self agentWhereIsTab:tab]];
            if (!document[@"heading"]) document[@"heading"] = NSNull.null;
            if (tab.contentLoadedAt) document[@"reloadedAt"] = ISODate(tab.contentLoadedAt);
            if (tab.cachedModificationDate) document[@"loadedFileModified"] = ISODate(tab.cachedModificationDate);
            if (disk && tab.cachedModificationDate)
                document[@"upToDate"] = @([disk isEqualToDate:tab.cachedModificationDate]);
        }
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

#pragma mark - Reload

- (void)agentReload:(NSDictionary*)request reply:(void (^)(NSDictionary*))reply {
    NSString* path = request[@"path"];
    NSInteger index = [self indexOfTabForPath:path];
    if (index < 0) {
        reply(@{@"errorCode" : @"not-open", @"error" : @"The document is not open in ShenzhenPDF."});
        return;
    }
    SPDFDocumentTab* tab = _tabs[(NSUInteger)index];
    if (tab != [self selectedTab]) {
        // Not in front: what it kept is dropped, and the file is read when its tab is next shown.
        [self discardCachedRuntimeForTab:tab];
        NSDate* disk = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFileModificationDate];
        reply(@{@"path" : path, @"reloaded" : @YES, @"rendered" : @NO, @"selected" : @NO,
                @"windowId" : @(_window.windowNumber), @"fileModified" : ISODate(disk) ?: NSNull.null,
                @"pageCount" : NSNull.null, @"note" : @"The tab is not in front: it is read again when it is shown."});
        return;
    }
    id previous = [self agentReloadSelected];
    NSMutableDictionary* pending = [@{@"path" : path, @"reloaded" : @YES} mutableCopy];
    if (previous) pending[@"previousRender"] = previous;
    NSTimeInterval timeout = request[@"timeout"] ? [request[@"timeout"] doubleValue] : 30;
    [self agentFinishOpen:pending
                    reply:^(NSDictionary* answer) {
                      NSMutableDictionary* result = [answer mutableCopy];
                      [result removeObjectForKey:@"opened"];
                      result[@"selected"] = @YES;
                      reply(result);
                    }
                 deadline:[NSDate dateWithTimeIntervalSinceNow:timeout]
                navigated:YES];
}

#pragma mark - Close

+ (void)agentClose:(NSDictionary*)request readers:(NSArray<ShenzhenMacDelegate*>*)readers
             reply:(void (^)(NSDictionary*))reply {
    NSMutableArray *closed = [NSMutableArray array], *windows = [NSMutableArray array];
    for (ShenzhenMacDelegate* reader in readers) {
        if (request[@"windowId"] && reader->_window.windowNumber != [request[@"windowId"] integerValue]) continue;
        NSMutableArray<SPDFDocumentTab*>* doomed = [NSMutableArray array];
        for (SPDFDocumentTab* tab in reader->_tabs)
            if (request[@"windowId"] || [Standard(tab.path) isEqualToString:Standard(request[@"path"])])
                [doomed addObject:tab];
        for (SPDFDocumentTab* tab in doomed)
            if (tab.unsavedPastedImage) {
                reply(@{@"errorCode" : @"unsaved-changes",
                        @"error" : @"A tab there holds a pasted image that is not saved; nothing was closed."});
                return;
            }
        if (!doomed.count) continue;
        [windows addObject:@(reader->_window.windowNumber)];
        // Background tabs first, then the one in front, so no tab about to close is loaded as its replacement.
        SPDFDocumentTab* selected = [reader selectedTab];
        [doomed sortUsingComparator:^NSComparisonResult(SPDFDocumentTab* a, SPDFDocumentTab* b) {
          return (NSComparisonResult)((a == selected) - (b == selected));
        }];
        for (SPDFDocumentTab* tab in doomed) {
            NSUInteger index = [reader->_tabs indexOfObjectIdenticalTo:tab];
            if (index == NSNotFound) continue;
            [closed addObject:tab.path ?: @""];
            [reader closeTabAtIndex:(NSInteger)index];
        }
    }
    reply(@{@"closed" : closed, @"windowIds" : windows});
}

#pragma mark - Waiting for comments

// Event-driven: file system events on the document's comments (SPDFMacSzpdfWatchComments), nothing polls. The answer
// goes back on the socket when something changes or the time is up.
+ (void)agentWatchComments:(NSDictionary*)request reply:(void (^)(NSDictionary*))reply {
    NSDate* since = request[@"since"] ? SPDFMacSzpdfParseISODate(request[@"since"]) : nil;
    NSTimeInterval timeout = request[@"timeout"] ? [request[@"timeout"] doubleValue] : 600;
    SPDFMacSzpdfWatchComments(request[@"path"], since, timeout, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
                              ^(NSDictionary* answer) { reply(answer); });
}

@end
