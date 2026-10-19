#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^SPDFMacMarkdownImageFetchCompletion)(NSData* _Nullable data);
// Seam for tests and alternative transports: given an https URL, deliver the
// raw image bytes (nil on failure) on any queue. The default fetcher is an
// NSURLSession with an ephemeral configuration (no cookies, no credentials,
// no shared URL cache), a fixed User-Agent, a ~20s request timeout, a 20 MB
// per-image cap, an image/* content-type requirement, and redirects
// restricted to https.
typedef void (^SPDFMacMarkdownImageFetcher)(NSURL* URL, SPDFMacMarkdownImageFetchCompletion completion);

// Session-side download coordinator for remote Markdown images. The engine
// never touches the network: this loader fetches bytes lazily (only when the
// owning session asks, i.e. when its document is the active tab), remembers
// them in memory for the session's rerenders, persists them in the shared
// LRU disk cache so a URL is downloaded at most once across sessions and
// launches, and coalesces arrivals into batched update notifications.
//
// Main-thread confined: every public method and property must be used from
// the main thread, and both handlers are invoked there.
@interface SPDFMacMarkdownSessionImageLoader : NSObject

// Test seam; nil (the default) uses the shared NSURLSession fetcher.
@property(nonatomic, copy, nullable) SPDFMacMarkdownImageFetcher fetcher;
// Coalesced notification that loadedImageData/failedTargets changed: fired at
// most once per coalescing interval while downloads are landing, and once
// more when the outstanding batch completes.
@property(nonatomic, copy, nullable) void (^imagesUpdatedHandler)(void);
@property(nonatomic) NSTimeInterval coalescingInterval;  // default 0.3s

// Raw bytes per remote key (SPDFMarkdownRemoteImageKeyForTarget output),
// ready to feed into SPDFMarkdownRenderOptions.remoteImageData.
@property(nonatomic, readonly, copy) NSDictionary<NSString*, NSData*>* loadedImageData;
@property(nonatomic, readonly, copy) NSSet<NSString*>* failedTargets;
@property(nonatomic, readonly) NSUInteger outstandingRequestCount;
// Number of times the network fetcher was actually invoked (disk-cache hits
// and repeated requests never re-fetch).
@property(nonatomic, readonly) NSUInteger networkFetchCount;

- (instancetype)init;
// Tests pass their own directory; nil uses the shared markdown-images cache.
- (instancetype)initWithCacheDirectory:(nullable NSURL*)cacheDirectory NS_DESIGNATED_INITIALIZER;

// Requests each remote key at most once for the lifetime of the loader:
// already-loaded, already-failed and in-flight targets are ignored. Bytes are
// served from the disk cache when present; only true misses hit the fetcher,
// at most 4 concurrently.
- (void)requestTargets:(NSArray<NSString*>*)targets;
// Drops requests still waiting for a download slot (they may be requested
// again later). Downloads already in flight are left to finish so their bytes
// still reach the caches and are never re-downloaded.
- (void)cancelQueuedRequests;

@end

NS_ASSUME_NONNULL_END
