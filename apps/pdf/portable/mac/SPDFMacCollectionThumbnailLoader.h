#pragma once
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// Collection list thumbnails, kept on disk so a window opened again (a new companion process every time) shows them
// at once instead of rendering every page again. Keys name a saved version (immutable) or an original's size and
// modification time, plus the page and the pixel size, so a changed document simply misses and is rendered afresh.
//
//   memory   NSCache by row key, cost = pixel bytes                                     main thread reads
//   disk     ~/Library/Caches/ShenzhenPDF/collection-thumbnails (SPDF_STATE_DIR/Caches/... for private state), JPEG,
//            least recently used trimmed past kSPDFCollectionThumbnailDiskBudget       read and decoded off main
//   render   one serial utility worker, which takes the visible rows first, top to bottom; a row that scrolled
//            away before its turn is dropped and asked again when it comes back
@interface SPDFCollectionThumbnailLoader : NSObject
- (instancetype)initWithDirectory:(nullable NSURL*)directory;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) NSCache<NSString*, NSImage*>* memory;
@property(nonatomic, readonly) NSMutableSet<NSString*>* pending; // main thread
@property(nonatomic, readonly) NSOperationQueue* renderQueue;
@property(nonatomic, readonly, nullable) NSURL* directory;
// Renders started since construction (not disk hits): tests and probes count regeneration with it.
@property(nonatomic, readonly) NSUInteger renderCount;
// Main thread, once per finished key: an image, or nil with the reason it has none.
@property(nonatomic, copy, nullable) void (^deliver)(NSString* key, NSImage* _Nullable image,
                                                     NSString* _Nullable failure);
// Main thread. diskKey runs off the main thread (it may stat an original) and returns nil for "never on disk";
// render runs on the worker and clears *persist for pixels that must stay in memory (a password-protected PDF).
- (void)requestKey:(NSString*)key scale:(CGFloat)scale diskKey:(NSString* _Nullable (^)(void))diskKey
            render:(NSImage* _Nullable (^)(BOOL* persist, NSString* _Nullable* _Nullable failure))render;
// Main thread: the rows on screen, top to bottom. Their renders go first. visibleKeysProvider is asked again whenever a
// render is queued, so rows the table laid out since the last scroll count too.
- (void)setVisibleKeys:(NSArray<NSString*>*)keys;
@property(nonatomic, copy, nullable) NSArray<NSString*>* (^visibleKeysProvider)(void);
// Main thread: the row left the table. A render not started yet is dropped.
- (void)forgetKey:(NSString*)key;
// Main thread: the window closed. Nothing queued starts; the render under way finishes on its own.
- (void)cancelQueued;
@end

static const unsigned long long kSPDFCollectionThumbnailDiskBudget = 64ull * 1024 * 1024;
NSURL* _Nullable SPDFCollectionThumbnailDirectory(void);
// JPEG bytes of an opaque thumbnail, and back to an image of `scale` pixels per point, decoded now.
NSData* _Nullable SPDFCollectionThumbnailEncode(NSImage* image);
NSImage* _Nullable SPDFCollectionThumbnailDecode(NSData* data, CGFloat scale);

NS_ASSUME_NONNULL_END
