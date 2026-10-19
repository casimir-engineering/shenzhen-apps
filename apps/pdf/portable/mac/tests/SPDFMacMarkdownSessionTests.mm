#import <AppKit/AppKit.h>

#import "../SPDFMacMarkdownSession.h"
#import "../SPDFMacMarkdownPageCanvasPrivate.h"
#import "../SPDFMacMarkdownPagedView.h"
#import "../markdown/SPDFMarkdown.h"

#include <assert.h>
#include <stdio.h>

static BOOL ColorMatchesHex(NSColor* color, unsigned int hex) {
    NSColor* sRGB = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!sRGB) return NO;
    return fabs(sRGB.redComponent - ((hex >> 16) & 0xff) / 255.0) < 0.002 &&
           fabs(sRGB.greenComponent - ((hex >> 8) & 0xff) / 255.0) < 0.002 &&
           fabs(sRGB.blueComponent - (hex & 0xff) / 255.0) < 0.002;
}

static NSColor* BodyColorOfSession(SPDFMacMarkdownSession* session, NSString* probe) {
    NSRange range = [session.renderedDocument.attributedString.string rangeOfString:probe];
    if (range.location == NSNotFound) return nil;
    return [session.renderedDocument.attributedString attribute:NSForegroundColorAttributeName
                                                        atIndex:range.location
                                                 effectiveRange:nil];
}

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

@interface SPDFMacMarkdownSession (SPDFMacMarkdownSessionTests)
- (void)applyLanguageIdentifier:(NSString*)identifier toCodeBlock:(NSUInteger)blockIndex;
@end

int main(void) {
    @autoreleasepool {
        (void)NSApplication.sharedApplication;
        NSString* path = WriteMarkdown(@"# Introduction\nAlpha beta alpha.\n\n# Finish\nOmega.\n\n"
                                        "```unknown\nlet value = 1\n```\n");
        NSView* host = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 640, 480)];
        dispatch_queue_t sessionQueue = dispatch_queue_create("markdown.session.test", DISPATCH_QUEUE_CONCURRENT);
        SPDFMacMarkdownSession* session =
            [[SPDFMacMarkdownSession alloc] initWithDocumentURL:[NSURL fileURLWithPath:path]];
        NSObject* reader = [NSObject new];
        session.reader = (id<SPDFMacUIReader>)reader;
        assert(session.reader == (id<SPDFMacUIReader>)reader);
        __block BOOL loaded = NO;
        [session activateInHostView:host
                          workQueue:sessionQueue
                       scrollOrigin:NSZeroPoint
                      selectedRange:NSMakeRange(0, 0)
                          pageIndex:0
                               zoom:1.0
                            fitMode:SPDFMacMarkdownPageFitPage
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
        assert(session.state == SPDFMacMarkdownSessionReady);
        assert(session.pageCount > 0);
        assert([session.renderedDocument.attributedString.string containsString:@"Alpha beta alpha"]);

        __block NSUInteger count = NSNotFound;
        __block NSInteger index = -1;
        session.searchUpdateHandler = ^(NSUInteger resultCount, NSInteger resultIndex, BOOL searching) {
          if (!searching) {
              count = resultCount;
              index = resultIndex;
          }
        };
        [session searchForQuery:@"alpha" preferredIndex:0];
        assert(SpinUntil(
            ^BOOL {
              return count != NSNotFound;
            },
            5.0));
        assert(count == 2 && index == 0);
        [session moveToNextMatch:YES];
        assert(session.currentMatchIndex == 1);
        assert([session scrollToHeadingAnchor:@"finish"]);
        SPDFMacMarkdownPagedView* pagedView = nil;
        for (NSView* view in session.rootView.subviews)
            if ([view isKindOfClass:SPDFMacMarkdownPagedView.class]) pagedView = (id)view;
        assert(pagedView != nil);
        assert(pagedView.reader == session.reader);
        assert(session.visibleAttributedLocation == pagedView.visibleAttributedLocation);
        assert(session.visibleAttributedLocation != NSNotFound);
        NSObject* replacementReader = [NSObject new];
        session.reader = (id<SPDFMacUIReader>)replacementReader;
        assert(pagedView.reader == (id<SPDFMacUIReader>)replacementReader);
        pagedView.selectedRange = NSMakeRange(0, 5);
        assert([session.selectedText isEqualToString:@"Intro"]);

        // A language rerender must not invalidate an overlapping Find. Suspending
        // the shared worker queue makes the overlap deterministic and reproduces
        // the old shared-generation failure every time.
        __block BOOL overlapSearchFinished = NO;
        __block BOOL overlapRenderFinished = NO;
        session.searchUpdateHandler = ^(NSUInteger resultCount, NSInteger resultIndex, BOOL searching) {
          (void)resultIndex;
          if (!searching && resultCount == 2) overlapSearchFinished = YES;
        };
        session.statusHandler = ^(NSString* status) {
          if ([status isEqualToString:@"Code language updated."]) overlapRenderFinished = YES;
        };
        NSUInteger codeBlock = session.document.model.codeFences.firstObject.blockIndex;
        dispatch_suspend(sessionQueue);
        [session searchForQuery:@"alpha" preferredIndex:0];
        [session applyLanguageIdentifier:@"python" toCodeBlock:codeBlock];
        dispatch_resume(sessionQueue);
        assert(SpinUntil(
            ^BOOL {
              return overlapSearchFinished && overlapRenderFinished;
            },
            5.0));
        assert(session.searchMatches.count == 2);

        // Replacing an in-flight search must only publish the latest query.
        __block NSUInteger latestCount = NSNotFound;
        session.searchUpdateHandler = ^(NSUInteger resultCount, NSInteger resultIndex, BOOL searching) {
          (void)resultIndex;
          if (!searching) latestCount = resultCount;
        };
        dispatch_suspend(sessionQueue);
        [session searchForQuery:@"alpha" preferredIndex:0];
        [session searchForQuery:@"omega" preferredIndex:0];
        dispatch_resume(sessionQueue);
        assert(SpinUntil(
            ^BOOL {
              return latestCount == 1;
            },
            5.0));
        assert(session.searchMatches.count == 1);

        // Replacing a queued language render must not let its stale completion
        // overwrite the newer override.
        __block NSUInteger renderCompletions = 0;
        session.statusHandler = ^(NSString* status) {
          if ([status isEqualToString:@"Code language updated."]) renderCompletions++;
        };
        dispatch_suspend(sessionQueue);
        [session applyLanguageIdentifier:@"python" toCodeBlock:codeBlock];
        [session applyLanguageIdentifier:@"swift" toCodeBlock:codeBlock];
        dispatch_resume(sessionQueue);
        assert(SpinUntil(
            ^BOOL {
              return renderCompletions == 1;
            },
            5.0));
        SPDFMarkdownRenderedBlock* renderedCode = [session.renderedDocument renderedBlockWithIndex:codeBlock];
        NSString* language = [session.renderedDocument.attributedString attribute:SPDFMarkdownCodeLanguageAttribute
                                                                          atIndex:renderedCode.attributedRange.location
                                                                   effectiveRange:nil];
        assert([language isEqualToString:@"swift"]);
        SPDFMacMarkdownPagedView* replacedPagedView = nil;
        for (NSView* view in session.rootView.subviews)
            if ([view isKindOfClass:SPDFMacMarkdownPagedView.class]) replacedPagedView = (id)view;
        assert(replacedPagedView != nil && replacedPagedView != pagedView);
        assert(replacedPagedView.reader == session.reader);

        // applyFontScale: rerenders with scaled typography, preserves the
        // current custom zoom, survives a later language rerender, clamps to
        // [0.5, 3.0], and no-ops on an equal value.
        NSRange bodyRange = [session.renderedDocument.attributedString.string rangeOfString:@"Alpha beta alpha"];
        assert(bodyRange.location != NSNotFound);
        NSFont* baseFont = [session.renderedDocument.attributedString attribute:NSFontAttributeName
                                                                        atIndex:bodyRange.location
                                                                 effectiveRange:nil];
        assert(baseFont != nil && session.fontScale == 1.0);
        // Drain the earlier installs' queued viewport restores before adopting
        // a custom zoom so they cannot overwrite it.
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        [session setZoom:1.6];
        assert(session.fitMode == SPDFMacMarkdownPageFitCustom);
        __block NSUInteger fontScaleRenders = 0, installedRenders = 0; session.renderInstalledHandler = ^{ installedRenders++; };
        session.statusHandler = ^(NSString* status) {
          if ([status isEqualToString:@"Text size updated."]) fontScaleRenders++;
        };
        [session applyFontScale:1.5];
        assert(session.fontScale == 1.5);
        assert(SpinUntil(
            ^BOOL {
              return fontScaleRenders == 1;
            },
            5.0));
        assert(installedRenders == 1); NSRange scaledRange = [session.renderedDocument.attributedString.string rangeOfString:@"Alpha beta alpha"];
        assert(scaledRange.location != NSNotFound);
        NSFont* scaledFont = [session.renderedDocument.attributedString attribute:NSFontAttributeName
                                                                          atIndex:scaledRange.location
                                                                   effectiveRange:nil];
        assert(fabs(scaledFont.pointSize - baseFont.pointSize * 1.5) < 0.01);
        assert(SpinUntil(
            ^BOOL {
              return session.fitMode == SPDFMacMarkdownPageFitCustom && fabs(session.zoom - 1.6) < 0.01;
            },
            5.0));

        // A language rerender after the scale change keeps the scaled fonts.
        __block NSUInteger scaledLanguageRenders = 0;
        session.statusHandler = ^(NSString* status) {
          if ([status isEqualToString:@"Code language updated."]) scaledLanguageRenders++;
        };
        [session applyLanguageIdentifier:@"python" toCodeBlock:codeBlock];
        assert(SpinUntil(
            ^BOOL {
              return scaledLanguageRenders == 1;
            },
            5.0));
        NSRange rescaledRange = [session.renderedDocument.attributedString.string rangeOfString:@"Alpha beta alpha"];
        NSFont* rescaledFont = [session.renderedDocument.attributedString attribute:NSFontAttributeName
                                                                            atIndex:rescaledRange.location
                                                                     effectiveRange:nil];
        assert(fabs(rescaledFont.pointSize - baseFont.pointSize * 1.5) < 0.01);
        SPDFMarkdownRenderedBlock* rescaledCode = [session.renderedDocument renderedBlockWithIndex:codeBlock];
        NSString* rescaledLanguage =
            [session.renderedDocument.attributedString attribute:SPDFMarkdownCodeLanguageAttribute
                                                         atIndex:rescaledCode.attributedRange.location
                                                  effectiveRange:nil];
        assert([rescaledLanguage isEqualToString:@"python"]);

        // Clamping, then equal-value applications must not rerender.
        session.statusHandler = ^(NSString* status) {
          if ([status isEqualToString:@"Text size updated."]) fontScaleRenders++;
        };
        [session applyFontScale:10.0];
        assert(session.fontScale == 3.0);
        assert(SpinUntil(
            ^BOOL {
              return fontScaleRenders == 2;
            },
            5.0));
        SPDFMarkdownRenderedDocument* renderedBeforeNoop = session.renderedDocument;
        [session applyFontScale:3.0];
        [session applyFontScale:47.0]; // clamps to the same 3.0
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
        assert(fontScaleRenders == 2 && session.renderedDocument == renderedBeforeNoop);

        // Print/export consumes the live screen plan: same A4 page geometry,
        // the reserved language-control band, and the current scaled rendition
        // with its language override.
        SPDFMarkdownPaginationPlan* exportPlan = session.paginationPlan;
        assert(exportPlan != nil && exportPlan.configuration.includesCodeLanguageControlSpacing);
        assert(NSEqualSizes(exportPlan.configuration.paperSize,
                            SPDFMarkdownPageConfiguration.A4PortraitConfiguration.paperSize));
        SPDFMarkdownPaginationItem* exportCodeItem = nil;
        SPDFMarkdownPaginationItem* exportParagraphItem = nil;
        for (SPDFMarkdownPaginationItem* item in exportPlan.items) {
            if (item.kind == SPDFMarkdownBlockKindCode) exportCodeItem = item;
            if (item.kind == SPDFMarkdownBlockKindParagraph && !exportParagraphItem) exportParagraphItem = item;
        }
        assert(exportCodeItem != nil && exportCodeItem.lines.firstObject.attributedRange.length == 0 &&
               fabs(exportCodeItem.lines.firstObject.height - 48.0) < 0.001);
        // The plan tracks the scaled rendition (3.0 here): line heights exceed
        // anything an unscaled render would measure.
        assert(exportParagraphItem != nil &&
               exportParagraphItem.lines.firstObject.height > baseFont.pointSize * 2.0);
        NSRange exportCodeRange = [session.renderedDocument renderedBlockWithIndex:codeBlock].attributedRange;
        NSString* exportLanguage =
            [session.renderedDocument.attributedString attribute:SPDFMarkdownCodeLanguageAttribute
                                                         atIndex:exportCodeRange.location
                                                  effectiveRange:nil];
        assert([exportLanguage isEqualToString:@"python"]);
        for (SPDFMarkdownPage* exportPage in exportPlan.pages)
            for (SPDFMarkdownPageFragment* fragment in exportPage.fragments)
                assert(NSMaxRange(fragment.attributedRange) <= session.renderedDocument.attributedString.length);

        // applyThemeVariant: mirrors applyFontScale: exactly — one viewport-
        // preserving rerender for the active session (Obsidian palette in the
        // rendered string AND the plan configuration), a no-op on equal
        // values, and a silent catch-up rerender on activation when the theme
        // changed while the session was inactive.
        assert(session.themeVariant == SPDFMarkdownThemeVariantLight &&
               session.paginationPlan.configuration.themeVariant == SPDFMarkdownThemeVariantLight &&
               ColorMatchesHex(BodyColorOfSession(session, @"Alpha beta alpha"), 0x1F2328));
        __block NSUInteger themeRenders = 0;
        session.statusHandler = ^(NSString* status) {
          if ([status isEqualToString:@"Reading theme updated."]) themeRenders++;
        };
        [session applyThemeVariant:SPDFMarkdownThemeVariantDark];
        assert(session.themeVariant == SPDFMarkdownThemeVariantDark);
        assert(SpinUntil(
            ^BOOL {
              return themeRenders == 1;
            },
            5.0));
        assert(ColorMatchesHex(BodyColorOfSession(session, @"Alpha beta alpha"), 0xDCDDDE));
        assert(session.paginationPlan.configuration.themeVariant == SPDFMarkdownThemeVariantDark);
        // The theme rerender preserves the custom viewport and the language
        // override, like every other viewport-preserving rerender.
        assert(SpinUntil(
            ^BOOL {
              return session.fitMode == SPDFMacMarkdownPageFitCustom && fabs(session.zoom - 1.6) < 0.01;
            },
            5.0));
        SPDFMarkdownRenderedDocument* themedBeforeNoop = session.renderedDocument;
        [session applyThemeVariant:SPDFMarkdownThemeVariantDark]; // equal value: no rerender
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
        assert(themeRenders == 1 && session.renderedDocument == themedBeforeNoop);
        // Theme changed while deactivated: adopted silently, rendered on the
        // next activation (the fontScale catch-up mechanism).
        [session deactivate];
        [session applyThemeVariant:SPDFMarkdownThemeVariantLight];
        assert(session.renderedDocument == themedBeforeNoop); // no render while inactive
        __block BOOL reactivated = NO;
        [session activateInHostView:host
                          workQueue:sessionQueue
                       scrollOrigin:NSZeroPoint
                      selectedRange:NSMakeRange(0, 0)
                          pageIndex:0
                               zoom:1.6
                            fitMode:SPDFMacMarkdownPageFitCustom
                             anchor:nil
                         completion:^(BOOL success, NSError* error) {
                           assert(success && !error);
                           reactivated = YES;
                         }];
        assert(SpinUntil(
            ^BOOL {
              return reactivated && ColorMatchesHex(BodyColorOfSession(session, @"Alpha beta alpha"), 0x1F2328) &&
                     session.paginationPlan.configuration.themeVariant == SPDFMarkdownThemeVariantLight;
            },
            5.0));
        assert(themeRenders == 1); // the catch-up rerender reports no status

        // A session created dark renders dark from the first pass, and the
        // live canvas swaps the light drop shadow for the dark paper + border.
        SPDFMacMarkdownSession* darkSession =
            [[SPDFMacMarkdownSession alloc] initWithDocumentURL:[NSURL fileURLWithPath:path]
                                                      fontScale:1.0
                                                   themeVariant:SPDFMarkdownThemeVariantDark];
        __block BOOL darkLoaded = NO;
        [darkSession activateInHostView:host
                              workQueue:sessionQueue
                           scrollOrigin:NSZeroPoint
                          selectedRange:NSMakeRange(0, 0)
                              pageIndex:0
                                   zoom:1.0
                                fitMode:SPDFMacMarkdownPageFitPage
                                 anchor:nil
                             completion:^(BOOL success, NSError* error) {
                               assert(success && !error);
                               darkLoaded = YES;
                             }];
        assert(SpinUntil(
            ^BOOL {
              return darkLoaded;
            },
            5.0));
        assert(darkSession.themeVariant == SPDFMarkdownThemeVariantDark);
        assert(ColorMatchesHex(BodyColorOfSession(darkSession, @"Alpha beta alpha"), 0xDCDDDE));
        SPDFMacMarkdownPagedView* darkPagedView = nil;
        for (NSView* view in darkSession.rootView.subviews)
            if ([view isKindOfClass:SPDFMacMarkdownPagedView.class]) darkPagedView = (id)view;
        SPDFMacMarkdownPageCanvas* darkCanvas = (SPDFMacMarkdownPageCanvas*)darkPagedView.documentView;
        assert([darkCanvas isKindOfClass:SPDFMacMarkdownPageCanvas.class]);
        assert(!darkCanvas.drawsPaperShadow && ColorMatchesHex(darkCanvas.paperFillColor, 0x1E1E1E));
        [darkSession deactivate];
        // The light canvas keeps the classic white sheet + shadow.
        SPDFMacMarkdownPagedView* lightPagedView = nil;
        for (NSView* view in session.rootView.subviews)
            if ([view isKindOfClass:SPDFMacMarkdownPagedView.class]) lightPagedView = (id)view;
        SPDFMacMarkdownPageCanvas* lightCanvas = (SPDFMacMarkdownPageCanvas*)lightPagedView.documentView;
        assert(lightCanvas.drawsPaperShadow && ColorMatchesHex(lightCanvas.paperFillColor, 0xFFFFFF));

        // A session created with an initial font scale renders scaled from the
        // first pass, and a pending anchor no longer discards the restored zoom.
        SPDFMacMarkdownSession* scaledSession =
            [[SPDFMacMarkdownSession alloc] initWithDocumentURL:[NSURL fileURLWithPath:path] fontScale:2.0];
        __block BOOL scaledLoaded = NO;
        [scaledSession activateInHostView:host
                                workQueue:sessionQueue
                             scrollOrigin:NSZeroPoint
                            selectedRange:NSMakeRange(0, 0)
                                pageIndex:0
                                     zoom:1.4
                                  fitMode:SPDFMacMarkdownPageFitCustom
                                   anchor:@"finish"
                               completion:^(BOOL success, NSError* error) {
                                 assert(success && !error);
                                 scaledLoaded = YES;
                               }];
        assert(SpinUntil(
            ^BOOL {
              return scaledLoaded;
            },
            5.0));
        assert(scaledSession.fontScale == 2.0);
        NSRange scaledBodyRange =
            [scaledSession.renderedDocument.attributedString.string rangeOfString:@"Alpha beta alpha"];
        NSFont* initialScaledFont = [scaledSession.renderedDocument.attributedString attribute:NSFontAttributeName
                                                                                       atIndex:scaledBodyRange.location
                                                                                effectiveRange:nil];
        assert(fabs(initialScaledFont.pointSize - baseFont.pointSize * 2.0) < 0.01);
        assert(SpinUntil(
            ^BOOL {
              return scaledSession.fitMode == SPDFMacMarkdownPageFitCustom && fabs(scaledSession.zoom - 1.4) < 0.01;
            },
            5.0));
        [scaledSession deactivate];
        assert(scaledSession.rootView.superview == nil);

        // Block the worker before activation, switch away, then release it.
        // The stale completion must never attach or call back.
        dispatch_queue_t blockedQueue = dispatch_queue_create("markdown.stale.test", DISPATCH_QUEUE_SERIAL);
        dispatch_semaphore_t gate = dispatch_semaphore_create(0);
        dispatch_async(blockedQueue, ^{
          dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER);
        });
        SPDFMacMarkdownSession* stale =
            [[SPDFMacMarkdownSession alloc] initWithDocumentURL:[NSURL fileURLWithPath:path]];
        __block BOOL staleCompletion = NO;
        [stale activateInHostView:host
                        workQueue:blockedQueue
                     scrollOrigin:NSZeroPoint
                    selectedRange:NSMakeRange(0, 0)
                        pageIndex:0
                             zoom:1.0
                          fitMode:SPDFMacMarkdownPageFitPage
                           anchor:nil
                       completion:^(BOOL success, NSError* error) {
                         (void)success;
                         (void)error;
                         staleCompletion = YES;
                       }];
        [stale deactivate];
        dispatch_semaphore_signal(gate);
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
        assert(!staleCompletion);
        assert(stale.rootView.superview == nil);

        // Deactivated mid-parse, then re-activated: the session must restart
        // the pipeline and reach Ready (the deactivation dropped the first
        // load's completion for good).
        __block BOOL staleReloaded = NO;
        [stale activateInHostView:host
                        workQueue:sessionQueue
                     scrollOrigin:NSZeroPoint
                    selectedRange:NSMakeRange(0, 0)
                        pageIndex:0
                             zoom:1.0
                          fitMode:SPDFMacMarkdownPageFitPage
                           anchor:nil
                       completion:^(BOOL success, NSError* error) {
                         assert(success && !error);
                         staleReloaded = YES;
                       }];
        assert(SpinUntil(
            ^BOOL {
              return staleReloaded;
            },
            5.0));
        assert(stale.state == SPDFMacMarkdownSessionReady && stale.renderedDocument != nil && stale.pageCount > 0);
        assert(!staleCompletion); // the first activation's completion stays dropped
        [stale deactivate];

        // Regression: a cancelAllOperations landing while the session stays
        // active (SPDFDocumentTab.clearCachedRuntime cancels the very object
        // the reader is displaying) used to strand the tab on the "Loading
        // Markdown..." placeholder forever — the generation bump dropped the
        // parse completion and nothing ever re-kicked the pipeline. The active
        // session must self-heal to Ready and fire its activation completion
        // exactly once.
        dispatch_queue_t healQueue = dispatch_queue_create("markdown.heal.test", DISPATCH_QUEUE_SERIAL);
        SPDFMacMarkdownSession* healed =
            [[SPDFMacMarkdownSession alloc] initWithDocumentURL:[NSURL fileURLWithPath:path]];
        __block NSUInteger healedCompletions = 0;
        dispatch_suspend(healQueue);
        [healed activateInHostView:host
                         workQueue:healQueue
                      scrollOrigin:NSZeroPoint
                     selectedRange:NSMakeRange(0, 0)
                         pageIndex:0
                              zoom:1.0
                           fitMode:SPDFMacMarkdownPageFitPage
                            anchor:nil
                        completion:^(BOOL success, NSError* error) {
                          assert(success && !error);
                          healedCompletions++;
                        }];
        assert(healed.state == SPDFMacMarkdownSessionLoading);
        [healed cancelAllOperations]; // drops the still-queued initial parse
        dispatch_resume(healQueue);
        assert(SpinUntil(
            ^BOOL {
              return healed.state == SPDFMacMarkdownSessionReady;
            },
            5.0));
        assert(healed.renderedDocument != nil && healed.pageCount > 0);
        assert(healedCompletions == 1);

        // A cancel on a Ready active session must not reparse or replace the
        // installed render.
        SPDFMarkdownRenderedDocument* healedRendered = healed.renderedDocument;
        [healed cancelAllOperations];
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
        assert(healed.state == SPDFMacMarkdownSessionReady && healed.renderedDocument == healedRendered);

        // Re-activating a Ready session reinstalls the SAME rendered document:
        // no second parse or render pass.
        [healed deactivate];
        __block BOOL healedReactivated = NO;
        [healed activateInHostView:host
                         workQueue:healQueue
                      scrollOrigin:NSZeroPoint
                     selectedRange:NSMakeRange(0, 0)
                         pageIndex:0
                              zoom:1.0
                           fitMode:SPDFMacMarkdownPageFitPage
                            anchor:nil
                        completion:^(BOOL success, NSError* error) {
                          assert(success && !error);
                          healedReactivated = YES;
                        }];
        assert(healedReactivated); // the cached-document fast path is synchronous
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
        assert(healed.renderedDocument == healedRendered);
        [healed deactivate];

        // Activating again while the initial parse is in flight must not
        // cancel and restart it. Gate the serial queue directly behind the
        // first parse: a restarted parse could never run, so reaching Ready
        // proves the FIRST parse's completion still installed (a cancel would
        // have generation-dropped it, stranding the session at Loading).
        dispatch_queue_t gateQueue = dispatch_queue_create("markdown.gate.test", DISPATCH_QUEUE_SERIAL);
        dispatch_semaphore_t parseGate = dispatch_semaphore_create(0);
        SPDFMacMarkdownSession* inflight =
            [[SPDFMacMarkdownSession alloc] initWithDocumentURL:[NSURL fileURLWithPath:path]];
        __block NSUInteger inflightCompletions = 0;
        void (^inflightCompletion)(BOOL, NSError*) = ^(BOOL success, NSError* error) {
          assert(success && !error);
          inflightCompletions++;
        };
        dispatch_suspend(gateQueue);
        [inflight activateInHostView:host
                           workQueue:gateQueue
                        scrollOrigin:NSZeroPoint
                       selectedRange:NSMakeRange(0, 0)
                           pageIndex:0
                                zoom:1.0
                             fitMode:SPDFMacMarkdownPageFitPage
                              anchor:nil
                          completion:inflightCompletion];
        dispatch_async(gateQueue, ^{
          dispatch_semaphore_wait(parseGate, DISPATCH_TIME_FOREVER);
        });
        [inflight activateInHostView:host
                           workQueue:gateQueue
                        scrollOrigin:NSZeroPoint
                       selectedRange:NSMakeRange(0, 0)
                           pageIndex:0
                                zoom:1.0
                             fitMode:SPDFMacMarkdownPageFitPage
                              anchor:nil
                          completion:inflightCompletion];
        dispatch_resume(gateQueue);
        assert(SpinUntil(
            ^BOOL {
              return inflight.state == SPDFMacMarkdownSessionReady;
            },
            5.0));
        assert(inflight.pageCount > 0);
        assert(inflightCompletions == 1); // only the latest activation reports
        dispatch_semaphore_signal(parseGate);
        [inflight deactivate];

        // Launch shape: a cancel that lands BEFORE the session's first
        // activation (a restored tab's cached-runtime sweep can cancel a
        // session that was never shown) arms no self-heal — and must not: the
        // session is not on screen, so healing must stay a no-op. The later
        // first activation must still run the full pipeline to Ready with
        // exactly one completion.
        SPDFMacMarkdownSession* preCancelled =
            [[SPDFMacMarkdownSession alloc] initWithDocumentURL:[NSURL fileURLWithPath:path]];
        [preCancelled cancelAllOperations];
        [preCancelled ensureActiveSessionHasContent]; // inactive: must not start a load
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        assert(preCancelled.state == SPDFMacMarkdownSessionIdle && preCancelled.renderedDocument == nil);
        __block NSUInteger preCancelledCompletions = 0;
        [preCancelled activateInHostView:host
                               workQueue:sessionQueue
                            scrollOrigin:NSZeroPoint
                           selectedRange:NSMakeRange(0, 0)
                               pageIndex:0
                                    zoom:1.0
                                 fitMode:SPDFMacMarkdownPageFitPage
                                  anchor:nil
                              completion:^(BOOL success, NSError* error) {
                                assert(success && !error);
                                preCancelledCompletions++;
                              }];
        assert(SpinUntil(
            ^BOOL {
              return preCancelled.state == SPDFMacMarkdownSessionReady;
            },
            5.0));
        assert(preCancelled.pageCount > 0 && preCancelledCompletions == 1);
        [preCancelled deactivate];

        // Integration shape of the launch strand: the restore selects the tab
        // (initial parse in flight) and an immediate re-open of the same path
        // arrives. The re-open's cached-runtime sweep cancels the very session
        // on screen, then the open early-returns because the selected tab
        // already counts as an active document — its backstop now calls
        // ensureActiveSessionHasContent, which must restart the dropped load.
        // Once Ready, further backstop passes must not re-render or re-report.
        dispatch_queue_t reopenQueue = dispatch_queue_create("markdown.reopen.test", DISPATCH_QUEUE_SERIAL);
        SPDFMacMarkdownSession* reopened =
            [[SPDFMacMarkdownSession alloc] initWithDocumentURL:[NSURL fileURLWithPath:path]];
        __block NSUInteger reopenedCompletions = 0;
        dispatch_suspend(reopenQueue);
        [reopened activateInHostView:host
                           workQueue:reopenQueue
                        scrollOrigin:NSZeroPoint
                       selectedRange:NSMakeRange(0, 0)
                           pageIndex:0
                                zoom:1.0
                             fitMode:SPDFMacMarkdownPageFitPage
                              anchor:nil
                          completion:^(BOOL success, NSError* error) {
                            assert(success && !error);
                            reopenedCompletions++;
                          }];
        assert(reopened.state == SPDFMacMarkdownSessionLoading);
        [reopened cancelAllOperations];           // the re-open's cache sweep
        [reopened ensureActiveSessionHasContent]; // the openPaths early-return backstop
        dispatch_resume(reopenQueue);
        assert(SpinUntil(
            ^BOOL {
              return reopened.state == SPDFMacMarkdownSessionReady;
            },
            5.0));
        assert(reopened.renderedDocument != nil && reopened.pageCount > 0);
        assert(reopenedCompletions == 1); // sync backstop + cancel's async heal restart ONE load
        SPDFMarkdownRenderedDocument* reopenedRendered = reopened.renderedDocument;
        [reopened ensureActiveSessionHasContent];
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
        assert(reopened.renderedDocument == reopenedRendered && reopenedCompletions == 1);
        [reopened deactivate];

        [session deactivate];
        assert(session.rootView.superview == nil);
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        puts("SPDFMacMarkdownSessionTests passed");
    }
    return 0;
}
