#import "markdown/SPDFTextDocumentFormats.h"
#import "SPDFMacCollectionWindowPrivate.h"
#import "SPDFMacMarkdownPrinting.h"
#import "markdown/SPDFMarkdownDocument.h"
#import "SPDFMacCollectionThumbnail.h"
#import "SPDFMacCollectionThumbnailDelivery.h"
#import "SPDFMacCollectionThumbnailLoader.h"
#import "SPDFMacCollectionAvailability.h"
#import "SPDFMacPassword.h"
#import "SPDFMacCollectionCompanion.h"

// Every Collection window is a new companion process, and its thumbnails used to live only in that process's memory:
// each opening rendered every page it showed again, and so did scrolling past the cache's ~77 entries. They are kept
// on disk now (SPDFMacCollectionThumbnailLoader), read and decoded off the main thread, rendered only when missing.
@implementation SPDFMacCollectionWindow (Thumbnails)
- (void)initializeThumbnails {
    SPDFCollectionThumbnailLoader* loader = [[SPDFCollectionThumbnailLoader alloc]
        initWithDirectory:SPDFCollectionThumbnailDirectory()];
    self.thumbnails = loader;
    self.thumbnailCache = loader.memory; self.pendingThumbnails = loader.pending;
    self.thumbnailQueue = loader.renderQueue;
    __weak SPDFMacCollectionWindow* weakSelf = self;
    loader.deliver = ^(NSString* key, NSImage* image, NSString* failure) {
        SPDFMacCollectionWindow* owner = weakSelf;
        if (owner) SPDFCollectionDeliverThumbnail(owner.table,owner.rows.count,key,image,failure);
    };
    loader.visibleKeysProvider = ^NSArray<NSString*>*{ return [weakSelf visibleThumbnailKeys]; };
    NSClipView* clip = self.listScroll.contentView; clip.postsBoundsChangedNotifications = YES;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(thumbnailViewportChanged:)
        name:NSViewBoundsDidChangeNotification object:clip];
}
// The rows on screen, top to bottom. A cell AppKit prepared off screen before its pixels came shows them on arrival.
- (NSArray<NSString*>*)visibleThumbnailKeys {
    NSMutableArray* keys = [NSMutableArray array];
    NSRange visible = [self.table rowsInRect:self.table.visibleRect];
    if (visible.location == NSNotFound) return keys;
    NSUInteger end = MIN(NSMaxRange(visible),self.rows.count);
    for (NSUInteger index = visible.location; index < end; index++) {
        NSView* cell = [self.table viewAtColumn:0 row:(NSInteger)index makeIfNecessary:NO];
        for (NSImageView* child in cell.subviews) {
            if (![child isKindOfClass:NSImageView.class] || !child.identifier) continue;
            [keys addObject:child.identifier];
            NSImage* cached = [self.thumbnailCache objectForKey:child.identifier];
            if (cached && child.image != cached) child.image = cached;
        }
    }
    return keys;
}
- (void)thumbnailViewportChanged:(NSNotification*)notification {
    (void)notification; [self.thumbnails setVisibleKeys:[self visibleThumbnailKeys]];
}
// A row scrolled out of the table: its render, if it has not started, waits until the row is back.
- (void)tableView:(NSTableView*)tableView didRemoveRowView:(NSTableRowView*)rowView forRow:(NSInteger)row {
    (void)tableView; (void)row;
    for (NSView* cell in rowView.subviews) for (NSView* child in cell.subviews)
        if ([child isKindOfClass:NSImageView.class] && child.identifier) [self.thumbnails forgetKey:child.identifier];
}
- (void)cancelThumbnails { [self.thumbnails cancelQueued]; }
- (void)requestThumbnail:(NSDictionary*)row key:(NSString*)key {
    SPDFMacCollectionStore* store = self.store;
    CGFloat scale = MAX(1,self.window.backingScaleFactor);
    NSInteger page = [row[@"selectedPage"] integerValue];
    [self.thumbnails requestKey:key scale:scale diskKey:^NSString*{
        // Only what this row may show: a missing history or an unavailable original is never looked up.
        if ([row[@"version"][@"id"] length] || SPDFCollectionOriginalAvailable(row[@"document"]))
            return SPDFCollectionThumbnailDiskKey(row,page,scale);
        return nil;
    } render:^NSImage*(BOOL* persist, NSString** failureOut) {
        NSDictionary* version = row[@"version"];
        NSError* error = nil;
        NSURL* URL = nil;
        if (version[@"id"]) {
            URL = [store materializeVersionID:version[@"id"] documentID:row[@"document"][@"id"] error:&error];
        } else if (SPDFCollectionOriginalAvailable(row[@"document"])) {
            // Imported entries may have no snapshot yet. Preview their original
            // only when its row is requested, on this serial background queue.
            URL = [NSURL fileURLWithPath:row[@"document"][@"path"]];
        }
        // Never substitute today's original for a missing historical version.
        NSImage* image = nil;
        if (URL && SPDFIsRenderedTextDocumentPath(URL.path)) {
            SPDFMarkdownDocument* markdown = [SPDFMarkdownDocument documentWithURL:URL options:nil error:&error];
            SPDFMarkdownPageConfiguration* config = markdown.authoredPageConfiguration ?: [SPDFMarkdownPageConfiguration A4PortraitConfiguration];
            SPDFMarkdownPaginationPlan* plan = [markdown paginationPlanForConfiguration:config];
            // Twice the well's pixels, scaled down: text stays a texture rather than turning to noise.
            CGFloat fit = MIN(kSPDFCollectionThumbnailPoints.width/config.paperSize.width,
                              kSPDFCollectionThumbnailPoints.height/config.paperSize.height) * scale * 2;
            NSBitmapImageRep* bitmap = [SPDFMacMarkdownPrintAdapter imageRepForPageAtIndex:MIN(MAX(0,page-1),(NSInteger)plan.pages.count-1)
                paginationPlan:plan attributedString:markdown.renderedDocument.attributedString scale:fit];
            image = SPDFCollectionThumbnailFromPixels(bitmap.CGImage,scale);
        } else if (URL && ![URL.pathExtension.lowercaseString isEqual:@"pdf"]) {
            CGFloat side = MAX(kSPDFCollectionThumbnailPoints.width,kSPDFCollectionThumbnailPoints.height) * scale;
            image = SPDFCollectionThumbnailFromPixels([SPDFCollectionImageThumbnail(URL,page,side)
                CGImageForProposedRect:NULL context:nil hints:nil],scale);
        } else if (URL) {
            // The well in pixels: PDFKit draws at least that many, and the scaler brings them down to exactly it.
            NSSize box = NSMakeSize(kSPDFCollectionThumbnailPoints.width*scale,kSPDFCollectionThumbnailPoints.height*scale);
            NSImage* rendered = SPDFCollectionPDFThumbnail(URL,page,box,^(PDFDocument* pdf) {
                // A password opened it: these pixels stay in this window's memory, never on disk.
                *persist = NO;
                // Resolve lazily: standalone Collection UI tests need no core/password runtime.
                SPDFPasswordCredentialStore* credentials = [NSClassFromString(@"SPDFPasswordCredentialStore") sharedStore];
                for (NSString* path in @[URL.path,row[@"document"][@"path"] ?: @""]) {
                    SPDFPasswordCredential* credential = [credentials credentialForSourcePath:path];
                    [credential withUTF8Password:^(const char* password) {
                        [pdf unlockWithPassword:[NSString stringWithUTF8String:password]];
                    }];
                    if (!pdf.isLocked) break;
                }
                if (pdf.isLocked) {
                    SPDFCollectionCompanionRuntime* runtime=[NSClassFromString(@"SPDFCollectionCompanionRuntime") activeRuntime];
                    SPDFPasswordCredential* credential=[runtime credentialForPaths:@[URL.path,row[@"document"][@"path"] ?: @""]];
                    [credential withUTF8Password:^(const char* password) {
                        [pdf unlockWithPassword:[NSString stringWithUTF8String:password]];
                    }];
                }
            },&error);
            image = SPDFCollectionThumbnailFromPixels([rendered CGImageForProposedRect:NULL context:nil hints:nil],scale);
        }
        if (failureOut) *failureOut = version[@"id"] ? error.localizedDescription :
            @"Original preview unavailable; open the original document to check access.";
        return image;
    }];
}
@end
