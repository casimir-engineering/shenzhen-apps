#import "SPDFMacMarkdownSessionPrivate.h"

#import "SPDFMacMarkdownSessionImageLoader.h"
#import "SPDFMacMarkdownRemoteImagePolicy.h"
#import "markdown/SPDFMarkdownResources.h"

// The remote-image half of the session: lazy, active-tab-only downloads.
//
// The engine renders remote https images purely from the preloaded byte map in
// its render options, so parse/render/pagination never block on the network.
// This category walks the parsed model for https image targets whenever an
// ACTIVE session installs a render (initial load, reactivation of a cached
// session, language/font rerenders), asks the loader to resolve them —
// in-memory map first, then the shared LRU disk cache, and only then the
// network (4 concurrent, 20 MB / 20 s / image-content-type caps) — and answers
// each coalesced arrival batch with exactly one viewport-preserving rerender.
// Inactive and never-activated sessions never reach this code path, so
// background tabs cost no network traffic.

static void SPDFMacMarkdownCollectRemoteImageTargets(NSArray<SPDFMarkdownBlock*>* blocks,
                                                     NSMutableOrderedSet<NSString*>* targets) {
    for (SPDFMarkdownBlock* block in blocks) {
        for (SPDFMarkdownInlineRun* run in block.runs) {
            if (!(run.traits & SPDFMarkdownInlineTraitImage)) continue;
            NSString* key = SPDFMarkdownRemoteImageKeyForTarget(run.destination ?: @"");
            if (key) [targets addObject:key];
        }
        SPDFMacMarkdownCollectRemoteImageTargets(block.children, targets);
    }
}

@implementation SPDFMacMarkdownSession (RemoteImages)

- (void)installRemoteImageLoader:(SPDFMacMarkdownSessionImageLoader*)loader {
    _imageLoader = loader;
    __weak SPDFMacMarkdownSession* weakSelf = self;
    loader.imagesUpdatedHandler = ^{
      SPDFMacMarkdownSession* strongSelf = weakSelf;
      if (!strongSelf || !strongSelf->_active || !strongSelf.document) return;
      [strongSelf rerenderDocumentWithStatus:@"Markdown images updated."];
    };
}

- (SPDFMacMarkdownSessionImageLoader*)remoteImageLoader {
    if (!_imageLoader) [self installRemoteImageLoader:[SPDFMacMarkdownSessionImageLoader new]];
    return _imageLoader;
}

// A document someone else sent shows remote images as their alt text and never fetches them
// (SPDFMacMarkdownRemoteImagePolicy.h). Decided per render from the file itself, so removing the quarantine
// attribute or moving the file out of Friends' received folder takes effect at the next render.
- (BOOL)remoteImagesWithheld {
    return SPDFMacMarkdownRemoteImagesWithheld(self.documentURL, SPDFMacMarkdownFriendsReceivedDirectory());
}

- (void)applyRemoteImageState:(SPDFMarkdownRenderOptions*)options {
    options.remoteImagesWithheld = [self remoteImagesWithheld];
    if (!_imageLoader) return;
    options.remoteImageData = _imageLoader.loadedImageData;
    options.failedRemoteImageTargets = _imageLoader.failedTargets;
}

- (void)startRemoteImageFetchesIfNeeded {
    if (!_active || !self.document || [self remoteImagesWithheld]) return;
    NSMutableOrderedSet<NSString*>* targets = [NSMutableOrderedSet orderedSet];
    SPDFMacMarkdownCollectRemoteImageTargets(self.document.model.blocks, targets);
    if (!targets.count) return;  // never create a loader for a document without remote images
    [[self remoteImageLoader] requestTargets:targets.array];
}

- (void)cancelQueuedRemoteImageFetches {
    [_imageLoader cancelQueuedRequests];
}

@end
