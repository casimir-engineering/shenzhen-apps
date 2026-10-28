// szpdf: links (SPDFMacRemoteLinks.h).

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

@implementation SPDFMacRemoteLinkJob
@end

@implementation SPDFMacRemoteTarget
@end

@implementation SPDFMacRemoteLinksState
- (void)remoteDownloadDidProgress:(SPDFMacRemoteDownload*)download {
    [self.reader remoteLinkProgress:download];
}
- (void)remoteDownloadDidFinish:(SPDFMacRemoteDownload*)download {
    [self.reader remoteLinkFinished:download];
}
@end

static char kRemoteLinksStateKey;

static NSString* SPDFMacLinksRoot(void) {
    return [spdf_mac_support_directory() stringByAppendingPathComponent:@"Links"];
}

@implementation ShenzhenMacDelegate (SPDFMacRemoteLinks)

// A tab of the restored session whose download stopped when the app quit carries on once the window is up.
+ (void)load {
    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidFinishLaunchingNotification
                                                    object:nil
                                                     queue:nil
                                                usingBlock:^(NSNotification* note) {
                                                    (void)note;
                                                    spdf_mac_after_first_paint(^{
                                                        id reader = NSApp.delegate;
                                                        if ([reader isKindOfClass:ShenzhenMacDelegate.class])
                                                            [reader resumeRemoteLinksOfRestoredTabs];
                                                    });
                                                }];
}

- (SPDFMacRemoteLinksState*)remoteLinksState {
    SPDFMacRemoteLinksState* state = objc_getAssociatedObject(self, &kRemoteLinksStateKey);
    if (!state) {
        state = [SPDFMacRemoteLinksState new];
        state.reader = self;
        state.jobs = [NSMutableDictionary dictionary];
        state.targets = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(self, &kRemoteLinksStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

- (BOOL)remoteLinkIsDownloadingPath:(NSString*)path {
    SPDFMacRemoteLinksState* state = objc_getAssociatedObject(self, &kRemoteLinksStateKey);
    SPDFMacRemoteDownload* download = path.length ? state.jobs[path].download : nil;
    return download && !download.finished;
}

#pragma mark - A link arrives

- (NSArray<NSURL*>*)openRemoteLinksAmongURLs:(NSArray<NSURL*>*)urls {
    NSMutableArray<NSURL*>* others = [NSMutableArray array];
    for (NSURL* url in urls) {
        if (![url isKindOfClass:NSURL.class] || ![url.scheme.lowercaseString isEqualToString:@"szpdf"]) {
            if (url) [others addObject:url];
            continue;
        }
        NSString* text = url.absoluteString;
        spdf_link link;
        spdf_link_status status = spdf_link_parse(text.UTF8String, &link);
        char relative[1024];
        if (status == SPDF_LINK_OK && !spdf_link_cache_relative_path(&link, relative, sizeof(relative)))
            status = SPDF_LINK_TOO_LONG;
        if (status != SPDF_LINK_OK) {
            NSString* message = @(spdf_link_refusal_message(status));
            spdf_mac_after_first_paint(^{
                [self activateWindowForExternalOpen];
                [self showRemoteLinkAlert:@"Couldn\u2019t open this link" message:message];
            });
            continue;
        }
        NSURL* address = [NSURL URLWithString:@(link.url)];
        NSString* path = [SPDFMacLinksRoot() stringByAppendingPathComponent:@(relative)];
        if (!address) continue;
        NSString* name = link.heading[0] ? @(link.heading) : link.section[0] ? @(link.section) : nil;
        if (name.length) [self setRemoteTarget:name path:path];
        else [[self remoteLinksState].targets removeObjectForKey:path];
        [self openRemoteDocumentAt:address path:path page:link.page];
    }
    return others;
}

- (void)openRemoteDocumentAt:(NSURL*)address path:(NSString*)path page:(NSInteger)page {
    SPDFMacRemoteLinksState* state = [self remoteLinksState];
    SPDFMacRemoteLinkJob* job = state.jobs[path];
    NSNumber* pageNumber = page > 0 ? @(page) : nil;
    // Already downloading: the link was clicked again. Its tab comes forward, at its page.
    if (job && !job.download.finished) {
        if (page > 0) job.page = page;
        spdf_mac_after_first_paint(^{
            if (job.opened) [self showDocumentAtPath:path page:pageNumber];
            else [self activateWindowForExternalOpen];
        });
        return;
    }
    // Downloaded before: it opens from the app's storage, the same tab if it is open.
    if ([NSFileManager.defaultManager fileExistsAtPath:path] && ![SPDFMacRemoteDownload fileIsPartial:path]) {
        spdf_mac_after_first_paint(^{
            [self showDocumentAtPath:path page:pageNumber];
        });
        return;
    }
    [job.download detach]; // a download that stopped part way lets go of the file before this one carries it on
    job = [SPDFMacRemoteLinkJob new];
    job.page = page;
    job.opened = [self indexOfTabForPath:path] >= 0;
    job.reloadWhenReadable = job.opened;
    job.download = [[SPDFMacRemoteDownload alloc] initWithURL:address path:path];
    job.download.delegate = state;
    state.jobs[path] = job;
    [job.download start];
    spdf_mac_after_first_paint(^{
        [self activateWindowForExternalOpen];
        if (job.opened) [self showDocumentAtPath:path page:pageNumber];
        else [self updateRemoteLinkIndicator];
    });
}

- (void)resumeRemoteLinksOfRestoredTabs {
    NSString* root = [SPDFMacLinksRoot() stringByAppendingString:@"/"];
    for (SPDFDocumentTab* tab in [_tabs copy]) {
        NSString* path = tab.path;
        if (![path hasPrefix:root] || [self remoteLinkIsDownloadingPath:path]) continue;
        NSURL* address = [SPDFMacRemoteDownload sourceURLOfPartialFile:path];
        if (!address) continue;
        SPDFMacRemoteLinkJob* job = [SPDFMacRemoteLinkJob new];
        job.opened = YES;
        job.reloadWhenReadable = YES;
        job.download = [[SPDFMacRemoteDownload alloc] initWithURL:address path:path];
        job.download.delegate = [self remoteLinksState];
        [self remoteLinksState].jobs[path] = job;
        [job.download start];
    }
}

#pragma mark - While it downloads

- (void)remoteLinkProgress:(SPDFMacRemoteDownload*)download {
    SPDFMacRemoteLinkJob* job = [self remoteLinksState].jobs[download.path];
    if (!job || job.download != download) return;
    if (job.reloadWhenReadable && download.length > 0) {
        // A restored tab opened the partial file as a plain one: reopen it through the download.
        job.reloadWhenReadable = NO;
        [self reopenTabsAtPath:download.path];
    }
    if (!job.opened) [self tryOpeningRemoteDocument:job];
    if ([self remoteLinksState].targets[download.path]) [self resolveRemoteTargets];
    if ([[self selectedTab].path isEqualToString:download.path] && _doc) {
        // Every page the viewport still lacks tries again with the bytes that just arrived; the strip's thumbnails
        // only once the viewport is drawn, so they never take bandwidth from the page being read.
        [self spdf_queueViewportPageRendersNow];
        if ([self remoteLinkViewportIsDrawn]) [self enqueueVisibleMinimapThumbnailRenders];
    }
    [self updateRemoteLinkIndicator];
}

- (BOOL)remoteLinkViewportIsDrawn {
    NSInteger preferred = -1;
    for (NSNumber* index in [self visibleDocumentPageIndexesWithExtraRadius:0 preferredPage:&preferred]) {
        NSUInteger i = index.unsignedIntegerValue;
        if (i < _renderedPages.count && !_renderedPages[i].image && !_renderedPages[i].viewportImage) return NO;
    }
    return YES;
}

// Opens the document off the main thread to learn whether it opens yet and whether the page the link asked for can
// be drawn. The tab opens once it can (the first thing the reader sees is that page), or once the document has been
// openable for a second and a half without it (the reader sees the document arriving rather than nothing).
- (void)tryOpeningRemoteDocument:(SPDFMacRemoteLinkJob*)job {
    SPDFMacRemoteDownload* download = job.download;
    if (job.opened || job.attempting || !_uiReady || !_window) return;
    if (download.finished) {
        if (download.failure == SPDFMacRemoteDownloadFailureNone) [self openRemoteLinkTab:job];
        return;
    }
    // Markdown and text show what has arrived, and grow as the rest comes; other documents that are not PDFs open
    // once they are complete, as do PDFs whose size the server did not say.
    if (![download.path.pathExtension.lowercaseString isEqualToString:@"pdf"]) {
        if (SPDFIsRenderedTextDocumentPath(download.path) && download.received > 0) [self openRemoteLinkTab:job];
        return;
    }
    if (download.length <= 0 || download.received == job.triedAt) return;
    job.attempting = YES;
    job.triedAt = download.received;
    NSString* path = download.path;
    int page = (int)MAX(0, job.page - 1);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char err[512];
        BOOL opens = NO, drawn = NO;
        NSMutableArray<NSNumber*>* pageOffsets = [NSMutableArray array];
        spdf_document* doc = spdf_open(path.fileSystemRepresentation, err, sizeof(err));
        if (doc) {
            opens = YES;
            std::vector<int64_t> offsets((size_t)MAX(0, spdf_page_count(doc)));
            int found = offsets.empty() ? 0 : spdf_progressive_page_offsets(doc, offsets.data(), (int)offsets.size());
            for (int i = 0; i < found; ++i) [pageOffsets addObject:@(offsets[(size_t)i])];
            spdf_bitmap bitmap;
            drawn = spdf_render_page_rgba(doc, MIN(page, MAX(0, spdf_page_count(doc) - 1)), 0.05f, &bitmap, err,
                                          sizeof(err));
            if (drawn) spdf_free_bitmap(&bitmap);
            spdf_close(doc);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            job.attempting = NO;
            if (job.opened || job.download.finished) return;
            if (opens && !job.openableSince) job.openableSince = CFAbsoluteTimeGetCurrent();
            if (drawn || (opens && CFAbsoluteTimeGetCurrent() - job.openableSince > 1.5)) {
                // With the first page up, the page objects come next, so a jump anywhere is a few round trips.
                if (pageOffsets.count) [job.download prefetchOffsets:pageOffsets];
                [self openRemoteLinkTab:job];
            }
        });
    });
}

- (void)openRemoteLinkTab:(SPDFMacRemoteLinkJob*)job {
    if (job.opened) return;
    job.opened = YES;
    [self showDocumentAtPath:job.download.path page:job.page > 0 ? @(job.page) : nil];
    [self updateRemoteLinkIndicator];
}

#pragma mark - When it ends

- (void)remoteLinkFinished:(SPDFMacRemoteDownload*)download {
    SPDFMacRemoteLinksState* state = [self remoteLinksState];
    SPDFMacRemoteLinkJob* job = state.jobs[download.path];
    if (!job || job.download != download) return;
    if (download.failure == SPDFMacRemoteDownloadFailureNone) {
        [state.jobs removeObjectForKey:download.path];
        // From here it is an ordinary document: open it if its tab is not up yet, otherwise reopen the tab so the
        // outline, search and the Collection see the whole file. A tab at the back reopens when it is next shown.
        if (!job.opened) {
            job.opened = YES;
            spdf_mac_after_first_paint(^{
                [self showDocumentAtPath:download.path page:job.page > 0 ? @(job.page) : nil];
            });
        } else {
            [self reopenTabsAtPath:download.path];
        }
        [self updateRemoteLinkIndicator];
        return;
    }
    // A stopped download keeps its job (and what arrived) so clicking the link again carries it on.
    [self updateRemoteLinkIndicator];
    NSString* host = download.url.host ?: @"the website";
    NSString* message;
    switch (download.failure) {
    case SPDFMacRemoteDownloadFailureCertificate:
        message = [NSString stringWithFormat:@"ShenzhenPDF couldn\u2019t make a secure connection to %@, so it didn\u2019t "
                                             @"download the document.", host];
        break;
    case SPDFMacRemoteDownloadFailureNotFound:
        message = [NSString stringWithFormat:@"%@ says there\u2019s no document at this address. The link may be out "
                                             @"of date.", host];
        break;
    case SPDFMacRemoteDownloadFailureForbidden:
        message = [NSString stringWithFormat:@"%@ didn\u2019t allow the download. The document may need you to sign in "
                                             @"on the website first.", host];
        break;
    case SPDFMacRemoteDownloadFailureServer:
        message = [NSString stringWithFormat:@"%@ couldn\u2019t send the document right now (error %ld). Try the link "
                                             @"again later.", host, (long)download.httpStatus];
        break;
    case SPDFMacRemoteDownloadFailureNotPDF:
        message = @"The link leads to something that isn\u2019t a PDF, so ShenzhenPDF can\u2019t show it.";
        break;
    case SPDFMacRemoteDownloadFailureInsecureRedirect:
        message = [NSString stringWithFormat:@"%@ sent the download on to an address that isn\u2019t secure (https), "
                                             @"so ShenzhenPDF stopped it.", host];
        break;
    case SPDFMacRemoteDownloadFailureTooLarge:
        message = @"The document is larger than 2 GB, too large to open from a link.";
        break;
    case SPDFMacRemoteDownloadFailureDisk:
        message = @"ShenzhenPDF couldn\u2019t save the document on this Mac. Check that the disk has free space, then "
                  @"open the link again.";
        break;
    default:
        message = job.opened ? [NSString stringWithFormat:@"The download from %@ stopped part way. Check your internet "
                                                          @"connection, then open the link again to finish it.", host]
                             : [NSString stringWithFormat:@"ShenzhenPDF couldn\u2019t reach %@. Check your internet "
                                                          @"connection, then open the link again.", host];
        break;
    }
    if (download.failure != SPDFMacRemoteDownloadFailureNetwork && download.failure != SPDFMacRemoteDownloadFailureDisk)
        [state.jobs removeObjectForKey:download.path];
    spdf_mac_after_first_paint(^{
        [self updateRemoteLinkIndicator];
        [self showRemoteLinkAlert:job.opened ? @"The document didn\u2019t finish downloading"
                                             : @"Couldn\u2019t open the linked document"
                          message:message];
    });
}

- (void)reopenTabsAtPath:(NSString*)path {
    for (SPDFDocumentTab* tab in _tabs) {
        if (![tab.path isEqualToString:path]) continue;
        if (tab == [self selectedTab] && !_reloadInProgress && SPDFIsRenderedTextDocumentPath(path)) {
            // A whole reopen rather than the watcher's reread in place, which leaves the chapters sidebar with the
            // headings of the first part that arrived.
            [self rememberActiveTabState];
            [self discardCachedRuntimeForTab:tab];
            [self loadSelectedTab];
        } else if (tab == [self selectedTab] && !_reloadInProgress) {
            [self reloadSelectedTabFromDiskChange];
        } else {
            [self discardCachedRuntimeForTab:tab];
        }
    }
}

@end
