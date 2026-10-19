#import <AppKit/AppKit.h>

#import "../SPDFMacMarkdownMinimapModel.h"
#import "../SPDFMacMarkdownPagedView.h"
#import "../SPDFMacMarkdownSession.h"
#import "../markdown/SPDFMarkdown.h"

#include <assert.h>
#include <stdio.h>

// Find parity between the Markdown session and the PDF reader: nearest-match
// selection, centered reveal with the flash envelope, reveal gating, minimap
// highlight publication, scrollbar markers, regex, and re-render re-search.

static BOOL SpinUntil(BOOL (^condition)(void), NSTimeInterval timeout) {
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!condition() && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return condition();
}

static NSString* WriteMarkdown(NSString* text) {
    NSString* path = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"md"]];
    assert([text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    return path;
}

int main(void) {
    @autoreleasepool {
        (void)NSApplication.sharedApplication;
        // Three matches spread top / middle / bottom across several A4 pages.
        NSMutableString* source = [NSMutableString stringWithString:@"# Top\ntarget alpha one.\n\n"];
        for (NSUInteger i = 0; i < 80; ++i) [source appendString:@"Upper filler paragraph line.\n\n"];
        [source appendString:@"Middle target alpha two.\n\n"];
        for (NSUInteger i = 0; i < 80; ++i) [source appendString:@"Lower filler paragraph line.\n\n"];
        [source appendString:@"# Bottom\ntarget alpha three.\n"];
        NSString* path = WriteMarkdown(source);
        NSView* host = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 640, 480)];
        dispatch_queue_t sessionQueue = dispatch_queue_create("markdown.session.find.test", DISPATCH_QUEUE_CONCURRENT);
        SPDFMacMarkdownSession* session =
            [[SPDFMacMarkdownSession alloc] initWithDocumentURL:[NSURL fileURLWithPath:path]];
        __block BOOL loaded = NO;
        [session activateInHostView:host
                          workQueue:sessionQueue
                       scrollOrigin:NSZeroPoint
                      selectedRange:NSMakeRange(0, 0)
                          pageIndex:0
                               zoom:1.0
                            fitMode:SPDFMacMarkdownPageFitWidth
                             anchor:nil
                         completion:^(BOOL success, NSError* error) {
                           assert(success && !error);
                           loaded = YES;
                         }];
        assert(SpinUntil(
            ^BOOL {
              return loaded;
            },
            5.0));
        assert(session.pageCount >= 3);
        // Drain the install's queued viewport restore before scrolling around.
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        SPDFMacMarkdownPagedView* pagedView = nil;
        for (NSView* view in session.rootView.subviews)
            if ([view isKindOfClass:SPDFMacMarkdownPagedView.class]) pagedView = (id)view;
        assert(pagedView != nil);
        assert([pagedView.verticalScroller isKindOfClass:SPDFFindMarkerScroller.class]);

        // Nearest-match: from the last page, a fresh search with no explicit
        // target selects the bottom match instead of match #1.
        [session goToPageAtIndex:(NSInteger)session.pageCount - 1];
        __block NSUInteger nearCount = NSNotFound;
        __block NSInteger nearIndex = -1;
        session.searchUpdateHandler = ^(NSUInteger resultCount, NSInteger resultIndex, BOOL searching) {
          if (!searching) {
              nearCount = resultCount;
              nearIndex = resultIndex;
          }
        };
        [session searchForQuery:@"target alpha" regex:NO preferredIndex:-1 jumpToNearest:YES reveal:YES];
        assert(SpinUntil(
            ^BOOL {
              return nearCount != NSNotFound;
            },
            5.0));
        assert(nearCount == 3 && nearIndex == 2 && session.currentMatchIndex == 2);

        // The session publishes minimap highlights and PDF-shaped scrollbar
        // markers ({fraction, active}, ascending, active at the current match).
        NSUInteger publishedHighlights = 0;
        for (SPDFRenderedPage* page in session.minimapModel.pages) publishedHighlights += page.highlights.count;
        assert(publishedHighlights == 3);
        NSArray<NSDictionary*>* markers = [session searchScrollbarMarkers];
        assert(markers.count == 3);
        for (NSUInteger i = 0; i < markers.count; ++i) {
            double fraction = [markers[i][@"fraction"] doubleValue];
            assert(fraction >= 0.0 && fraction <= 1.0);
            if (i) assert(fraction > [markers[i - 1][@"fraction"] doubleValue]);
            assert([markers[i][@"active"] boolValue] == (i == 2));
        }

        // An index jump centers the match (PDF's scrollToPageRect) and arms the
        // flash envelope on the paged view; the handler reports index-only moves.
        __block NSInteger jumpedIndex = -1;
        __block NSUInteger jumpedCount = 0;
        session.matchIndexChangedHandler = ^(NSInteger currentIndex, NSUInteger total) {
          jumpedIndex = currentIndex;
          jumpedCount = total;
        };
        [session goToSearchMatchAtIndex:1];
        assert(jumpedIndex == 1 && jumpedCount == 3 && session.currentMatchIndex == 1);
        NSRange middleRange = session.searchMatches[1].range;
        assert(NSEqualRanges(pagedView.activeSearchRange, middleRange));
        NSRect middleRect = [pagedView firstRectForRange:middleRange];
        assert(!NSIsEmptyRect(middleRect));
        assert(fabs(NSMidY(middleRect) - NSMidY(pagedView.documentVisibleRect)) < 3.0);
        assert(SpinUntil(
            ^BOOL {
              return pagedView.activeSearchRange.length == 0; // flash envelope ends after ~1.51s
            },
            4.0));

        // reveal:NO keeps the viewport still and never arms the flash.
        [session goToPageAtIndex:0];
        NSPoint originBeforeSilentSearch = pagedView.contentView.bounds.origin;
        __block NSUInteger silentCount = NSNotFound;
        session.searchUpdateHandler = ^(NSUInteger resultCount, NSInteger resultIndex, BOOL searching) {
          (void)resultIndex;
          if (!searching) silentCount = resultCount;
        };
        [session searchForQuery:@"target alpha" regex:NO preferredIndex:-1 jumpToNearest:YES reveal:NO];
        assert(SpinUntil(
            ^BOOL {
              return silentCount != NSNotFound;
            },
            5.0));
        assert(silentCount == 3 && session.currentMatchIndex == 0);
        assert(NSEqualPoints(pagedView.contentView.bounds.origin, originBeforeSilentSearch));
        assert(pagedView.activeSearchRange.length == 0);

        // Regex search matches through the session; an invalid pattern reports
        // an error description with zero matches.
        __block NSUInteger regexCount = NSNotFound;
        session.searchUpdateHandler = ^(NSUInteger resultCount, NSInteger resultIndex, BOOL searching) {
          (void)resultIndex;
          if (!searching) regexCount = resultCount;
        };
        [session searchForQuery:@"tar\\w+ alpha" regex:YES preferredIndex:0 jumpToNearest:NO reveal:NO];
        assert(SpinUntil(
            ^BOOL {
              return regexCount != NSNotFound;
            },
            5.0));
        assert(regexCount == 3 && session.searchErrorDescription == nil);
        regexCount = NSNotFound;
        [session searchForQuery:@"([" regex:YES preferredIndex:0 jumpToNearest:NO reveal:NO];
        assert(SpinUntil(
            ^BOOL {
              return regexCount != NSNotFound;
            },
            5.0));
        assert(regexCount == 0 && session.searchErrorDescription.length > 0);

        // A font-scale re-render re-runs the live search against the fresh
        // attributed string, preserving the current match index.
        __block NSUInteger rerenderCount = NSNotFound;
        session.searchUpdateHandler = ^(NSUInteger resultCount, NSInteger resultIndex, BOOL searching) {
          (void)resultIndex;
          if (!searching) rerenderCount = resultCount;
        };
        [session searchForQuery:@"target alpha" regex:NO preferredIndex:1 jumpToNearest:NO reveal:NO];
        assert(SpinUntil(
            ^BOOL {
              return rerenderCount == 3;
            },
            5.0));
        NSString* stringBeforeRerender = session.renderedDocument.attributedString.string;
        rerenderCount = NSNotFound;
        [session applyFontScale:1.5];
        assert(SpinUntil(
            ^BOOL {
              return rerenderCount == 3;
            },
            5.0));
        assert(session.renderedDocument.attributedString.string != stringBeforeRerender);
        assert(session.currentMatchIndex == 1);
        for (SPDFMarkdownSearchMatch* match in session.searchMatches)
            assert([[session.renderedDocument.attributedString.string substringWithRange:match.range]
                isEqualToString:@"target alpha"]);

        // Re-render installs a fresh paged view; inspect the live publication surface.
        for (NSView* view in session.rootView.subviews)
            if ([view isKindOfClass:SPDFMacMarkdownPagedView.class]) pagedView=(id)view;
        // Citation publication is revalidated after extraction, before highlight or reveal.
        for (NSString* mode in @[@"complete",@"manual-page",@"cancel"]) {
            [session clearSearch]; [session goToPageAtIndex:0];
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
            NSInteger expectedPage=session.currentPageIndex;
            NSProgress* progress=[NSProgress progressWithTotalUnitCount:1];
            __block BOOL finished=NO;
            session.searchUpdateHandler=^(NSUInteger count,NSInteger index,BOOL searching){
                (void)count;(void)index;if(!searching)finished=YES;
            };
            dispatch_suspend(sessionQueue);
            [session searchForQuery:@"target alpha" regex:NO preferredIndex:0 jumpToNearest:NO reveal:YES
                publicationAllowed:^BOOL { return !progress.cancelled && session.currentPageIndex==expectedPage; }];
            assert([[session valueForKey:@"activeSearchQuery"] length]==0); // automatic reflow cannot replay an uncommitted citation
            if([mode isEqual:@"cancel"]) [progress cancel];
            if([mode isEqual:@"manual-page"]) [session goToPageAtIndex:session.pageCount-1];
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
            NSPoint interveningOrigin=pagedView.contentView.bounds.origin;
            dispatch_resume(sessionQueue);
            assert(SpinUntil(^BOOL{return finished;},5));
            if([mode isEqual:@"complete"]) assert(session.searchMatches.count==3 && pagedView.searchRanges.count==3);
            else {
                assert(session.searchMatches.count==0 && pagedView.searchRanges.count==0);
                assert(NSEqualPoints(interveningOrigin,pagedView.contentView.bounds.origin));
            }
        }

        [session deactivate];
        assert(session.rootView.superview == nil);
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        puts("SPDFMacMarkdownSessionFindTests passed");
    }
    return 0;
}
