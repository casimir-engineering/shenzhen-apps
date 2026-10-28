// Where a link opens (a section, a heading), the download's progress bar, notes and alerts (SPDFMacRemoteLinks.h).

#import "SPDFMacRemoteLinksPrivate.h"
#import "SPDFMacAIToolsReader.h"
#import "SPDFMacDocumentOpening.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacMarkdownSession.h"
#import "markdown/SPDFMarkdownRenderer.h"
#import "markdown/SPDFTextDocumentFormats.h"
#import "SPDFMacQuitFinishing.h"
#import "SPDFMacRemoteDownload.h"
#import "SPDFMacSupport.h"
#import "SPDFMacViewportRenderPriority.h"
#import <objc/runtime.h>

#include <vector>

#include "spdf_destination.h"
#include "spdf_link.h"
#include "spdf_progressive.h"

@implementation SPDFMacRemoteProgressBar
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [[NSColor.separatorColor colorWithAlphaComponent:0.35] setFill];
    NSRectFillUsingOperation(self.bounds, NSCompositingOperationSourceOver);
    NSRect done = self.bounds;
    done.size.width = round(done.size.width * MAX(0.0, MIN(1.0, self.fraction)));
    [NSColor.controlAccentColor setFill];
    NSRectFill(done);
}
- (NSView*)hitTest:(NSPoint)point {
    (void)point;
    return nil; // never in the way of a click on the page under it
}
@end


static NSString* SPDFMacFormatBytes(int64_t bytes) {
    return [NSByteCountFormatter stringFromByteCount:bytes countStyle:NSByteCountFormatterCountStyleFile];
}

@implementation ShenzhenMacDelegate (SPDFMacRemoteLinkViews)

#pragma mark - Opening at a section or heading

- (void)setRemoteTarget:(NSString*)name path:(NSString*)path {
    SPDFMacRemoteLinksState* state = [self remoteLinksState];
    SPDFMacRemoteTarget* target = [SPDFMacRemoteTarget new];
    target.path = path;
    target.name = name;
    target.deadline = CFAbsoluteTimeGetCurrent() + 10.0;
    state.targets[path] = target;
    if (!state.targetTimer) {
        __weak ShenzhenMacDelegate* weakSelf = self;
        state.targetTimer = [NSTimer scheduledTimerWithTimeInterval:0.15 repeats:YES block:^(NSTimer* timer) {
            ShenzhenMacDelegate* reader = weakSelf;
            if (!reader) [timer invalidate];
            else [reader resolveRemoteTargets];
        }];
    }
}

- (void)resolveRemoteTargets {
    SPDFMacRemoteLinksState* state = [self remoteLinksState];
    for (SPDFMacRemoteTarget* target in state.targets.allValues)
        if ([self resolveRemoteTarget:target]) [state.targets removeObjectForKey:target.path];
    if (!state.targets.count) {
        [state.targetTimer invalidate];
        state.targetTimer = nil;
    }
}

// YES once the target is reached, or known not to be in the document (then a short note says so).
- (BOOL)resolveRemoteTarget:(SPDFMacRemoteTarget*)target {
    BOOL downloading = [self remoteLinkIsDownloadingPath:target.path];
    if (!downloading && CFAbsoluteTimeGetCurrent() > target.deadline) return YES; // its tab never came forward
    if (![[self selectedTab].path isEqualToString:target.path] || !_uiReady) return NO;
    if (downloading) target.deadline = CFAbsoluteTimeGetCurrent() + 10.0;
    NSMutableArray<NSString*>* titles = [NSMutableArray array];
    NSMutableArray<NSNumber*>* pages = [NSMutableArray array];
    SPDFMacMarkdownSession* session = [self isMarkdownActive] ? [self activeMarkdownSession] : nil;
    if ([self isMarkdownActive]) {
        // A Markdown file rereads itself as it streams in, each time keeping the viewport it had when the reread
        // began: the heading is looked up once the last reread is done, or that reread puts the view back.
        if (downloading || ![session isNavigationReady]) return NO;
        for (SPDFMarkdownRenderedHeading* heading in session.renderedDocument.headings) [titles addObject:heading.title];
    } else {
        if (!_doc) return NO;
        spdf_outline outline;
        char err[256];
        if (spdf_load_outline(_doc, &outline, err, sizeof(err))) {
            for (int i = 0; i < outline.count; ++i) {
                [titles addObject:@(outline.items[i].title ?: "")];
                [pages addObject:@(outline.items[i].page_index)];
            }
            spdf_free_outline(&outline);
        } else if (downloading) {
            return NO; // the outline has not arrived yet
        }
    }
    std::vector<const char*> utf8;
    for (NSString* title in titles) utf8.push_back(title.UTF8String);
    int found = spdf_link_match_title(target.name.UTF8String, utf8.data(), (int)utf8.size());
    if (found >= 0 && session) {
        [session scrollToHeadingAnchor:titles[(NSUInteger)found]];
        return YES;
    }
    if (found >= 0 && pages[(NSUInteger)found].integerValue >= 0) {
        [self aiNavigateDocument:target.path page:pages[(NSUInteger)found].integerValue + 1];
        return YES;
    }
    // A PDF's named destination: the id a website may link to (#nameddest=...).
    int page = session ? -1 : spdf_named_destination_page(_doc, target.name.UTF8String);
    if (page >= 0) {
        [self aiNavigateDocument:target.path page:page + 1];
        return YES;
    }
    if (downloading) return NO; // it may be in what has not arrived
    [self showRemoteNote:[NSString stringWithFormat:@"Couldn\u2019t find \u201c%@\u201d in this document.", target.name]
                  sticky:NO];
    return YES;
}

- (void)updateRemoteLinkIndicator {
    SPDFMacRemoteLinksState* state = [self remoteLinksState];
    SPDFMacRemoteLinkJob* job = state.jobs[[self selectedTab].path ?: @""];
    SPDFMacRemoteDownload* download = job.download;
    // Before its tab can open (the first bytes of a PDF, the whole of an EPUB or an image) a note says the click
    // was heard and how far the download is.
    SPDFMacRemoteDownload* waiting = nil;
    for (SPDFMacRemoteLinkJob* other in state.jobs.allValues)
        if (!other.opened && !other.download.finished) waiting = other.download;
    if (waiting && _uiReady) {
        NSString* name = waiting.path.lastPathComponent;
        [self showRemoteNote:waiting.length > 0 ? [NSString stringWithFormat:@"Downloading %@ \u2013 %@ of %@", name,
                                                     SPDFMacFormatBytes(waiting.received),
                                                     SPDFMacFormatBytes(waiting.length)]
                                                : [NSString stringWithFormat:@"Downloading %@\u2026", name]
                      sticky:YES];
    } else if (state.noteSticky) {
        [self hideRemoteNote];
    }
    BOOL show = download && !download.finished && download.length > 0 && _pageScrollView;
    if (!show) {
        [state.bar removeFromSuperview];
        return;
    }
    if (!state.bar) state.bar = [[SPDFMacRemoteProgressBar alloc] initWithFrame:NSZeroRect];
    if (state.bar.superview != _pageScrollView) {
        [state.bar removeFromSuperview];
        NSRect bounds = _pageScrollView.bounds;
        state.bar.frame = NSMakeRect(0, _pageScrollView.isFlipped ? 0 : NSMaxY(bounds) - 3, bounds.size.width, 3);
        state.bar.autoresizingMask = NSViewWidthSizable | (_pageScrollView.isFlipped ? NSViewMaxYMargin : NSViewMinYMargin);
        [_pageScrollView addSubview:state.bar positioned:NSWindowAbove relativeTo:nil];
    }
    state.bar.fraction = (double)download.received / (double)download.length;
    [state.bar setNeedsDisplay:YES];
}

// A short line in a rounded box under the toolbar, over the page: kept while `sticky`, else gone after five seconds.
- (void)showRemoteNote:(NSString*)text sticky:(BOOL)sticky {
    SPDFMacRemoteLinksState* state = [self remoteLinksState];
    if (!_documentContainer || !_toolbar) return;
    if (!state.note) {
        NSTextField* label = [NSTextField labelWithString:@""];
        label.font = [NSFont systemFontOfSize:12];
        label.textColor = NSColor.labelColor;
        label.lineBreakMode = NSLineBreakByTruncatingMiddle;
        label.translatesAutoresizingMaskIntoConstraints = NO;
        NSVisualEffectView* box = [NSVisualEffectView new];
        box.material = NSVisualEffectMaterialPopover;
        box.state = NSVisualEffectStateActive;
        box.wantsLayer = YES;
        box.layer.cornerRadius = 8;
        box.layer.borderWidth = 1;
        box.layer.borderColor = NSColor.separatorColor.CGColor;
        box.translatesAutoresizingMaskIntoConstraints = NO;
        [box addSubview:label];
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:12],
            [label.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-12],
            [label.topAnchor constraintEqualToAnchor:box.topAnchor constant:7],
            [label.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-7],
        ]];
        state.note = box;
        state.noteLabel = label;
    }
    if (state.note.superview != _documentContainer) {
        [state.note removeFromSuperview];
        [_documentContainer addSubview:state.note positioned:NSWindowAbove relativeTo:nil];
        [NSLayoutConstraint activateConstraints:@[
            [state.note.topAnchor constraintEqualToAnchor:_toolbar.bottomAnchor constant:12],
            [state.note.centerXAnchor constraintEqualToAnchor:_documentContainer.centerXAnchor],
            [state.note.widthAnchor constraintLessThanOrEqualToAnchor:_documentContainer.widthAnchor constant:-32],
        ]];
    }
    state.noteLabel.stringValue = text;
    state.noteSticky = sticky;
    [state.noteTimer invalidate];
    state.noteTimer = nil;
    if (!sticky) {
        __weak ShenzhenMacDelegate* weakSelf = self;
        state.noteTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:NO block:^(NSTimer* timer) {
            (void)timer;
            [weakSelf hideRemoteNote];
        }];
    }
}

- (void)hideRemoteNote {
    SPDFMacRemoteLinksState* state = [self remoteLinksState];
    [state.noteTimer invalidate];
    state.noteTimer = nil;
    state.noteSticky = NO;
    [state.note removeFromSuperview];
}

#pragma mark - Alerts

- (void)showRemoteLinkAlert:(NSString*)title message:(NSString*)message {
    NSAlert* alert = [NSAlert new];
    alert.messageText = title;
    alert.informativeText = message;
    [alert addButtonWithTitle:@"OK"];
    if (_window.isVisible) [alert beginSheetModalForWindow:_window completionHandler:nil];
    else [alert runModal];
}

@end
