#import "SPDFMacCollectionThumbnailLoader.h"
#import "SPDFMacMarkdownCache.h"
#import <ImageIO/ImageIO.h>
#include <atomic>

NSURL* SPDFCollectionThumbnailDirectory(void) {
    // Private state (experiments, probes) keeps its thumbnails beside it, never in the user's cache.
    NSString* state = NSProcessInfo.processInfo.environment[@"SPDF_STATE_DIR"];
    if (state.length)
        return [NSURL fileURLWithPath:[state stringByAppendingPathComponent:@"Caches/collection-thumbnails"]
                          isDirectory:YES];
    NSURL* caches = [NSFileManager.defaultManager URLForDirectory:NSCachesDirectory inDomain:NSUserDomainMask
                                                appropriateForURL:nil create:NO error:nil];
    return [[caches URLByAppendingPathComponent:@"ShenzhenPDF" isDirectory:YES]
        URLByAppendingPathComponent:@"collection-thumbnails" isDirectory:YES];
}

NSData* SPDFCollectionThumbnailEncode(NSImage* image) {
    CGImageRef pixels = [image CGImageForProposedRect:NULL context:nil hints:nil];
    if (!pixels) return nil;
    NSMutableData* data = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data,
                                                                         CFSTR("public.jpeg"), 1, NULL);
    if (!destination) return nil;
    // 130 x 176 px at 2x: about 9 KB a page, so 300 documents take under 3 MB.
    CGImageDestinationAddImage(destination, pixels, (__bridge CFDictionaryRef)@{
        (__bridge NSString*)kCGImageDestinationLossyCompressionQuality : @0.85});
    BOOL written = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    return written ? data : nil;
}

NSImage* SPDFCollectionThumbnailDecode(NSData* data, CGFloat scale) {
    CGImageSourceRef source = data.length ? CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL) : NULL;
    if (!source) return nil;
    // Decoded here, on the disk queue, so drawing the cell never decodes JPEG on the main thread.
    CGImageRef pixels = CGImageSourceCreateImageAtIndex(source, 0, (__bridge CFDictionaryRef)@{
        (__bridge NSString*)kCGImageSourceShouldCacheImmediately : @YES});
    CFRelease(source);
    if (!pixels) return nil;
    CGFloat points = scale > 0 ? scale : 1;
    NSImage* image = [[NSImage alloc] initWithCGImage:pixels size:NSMakeSize(CGImageGetWidth(pixels) / points,
                                                                              CGImageGetHeight(pixels) / points)];
    CGImageRelease(pixels);
    return image;
}

static NSUInteger PixelBytes(NSImage* image) {
    CGImageRef pixels = [image CGImageForProposedRect:NULL context:nil hints:nil];
    return pixels ? CGImageGetBytesPerRow(pixels) * CGImageGetHeight(pixels) : 4 * 260 * 300;
}

@interface SPDFCollectionThumbnailJob : NSObject
@property(nonatomic, copy) NSString* key;
@property(nonatomic, copy) NSString* diskKey;
@property(nonatomic, copy) NSImage* (^render)(BOOL*, NSString**);
@end
@implementation SPDFCollectionThumbnailJob
@end

@implementation SPDFCollectionThumbnailLoader {
    dispatch_queue_t _diskQueue;
    // Guarded by @synchronized(_jobs): queued renders in request order, the rows on screen, the render under way.
    NSMutableArray<SPDFCollectionThumbnailJob*>* _jobs;
    NSArray<NSString*>* _visible;
    NSString* _rendering;
    BOOL _draining, _trimmed;
    std::atomic<NSUInteger> _renders;
}
- (instancetype)initWithDirectory:(NSURL*)directory {
    if (!(self = [super init])) return nil;
    _directory = directory;
    // About 260 thumbnails at 2x: more than a 256-document Collection scrolled end to end.
    _memory = [NSCache new]; _memory.totalCostLimit = 24 * 1024 * 1024;
    _pending = [NSMutableSet set];
    _renderQueue = [NSOperationQueue new]; _renderQueue.maxConcurrentOperationCount = 1;
    _renderQueue.qualityOfService = NSQualityOfServiceUtility;
    _diskQueue = dispatch_queue_create("engineering.casimir.collection.thumbnail-disk",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    _jobs = [NSMutableArray array]; _visible = @[];
    return self;
}
- (NSUInteger)renderCount { return _renders.load(); }
- (void)requestKey:(NSString*)key scale:(CGFloat)scale diskKey:(NSString* (^)(void))diskKey
            render:(NSImage* (^)(BOOL*, NSString**))render {
    if ([_memory objectForKey:key] || [_pending containsObject:key]) return;
    [_pending addObject:key];
    NSURL* directory = _directory;
    __weak SPDFCollectionThumbnailLoader* weakSelf = self;
    dispatch_async(_diskQueue, ^{
        @autoreleasepool {
            NSString* stored = diskKey();
            NSData* data = directory && stored ? spdf_mac_markdown_image_cache_read(directory, stored) : nil;
            NSImage* image = data ? SPDFCollectionThumbnailDecode(data, scale) : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                SPDFCollectionThumbnailLoader* loader = weakSelf;
                if (image) { [loader finishKey:key image:image failure:nil]; return; }
                // Forgotten while it was being looked up: the row is gone, and asks again if it comes back.
                if (!loader || ![loader.pending containsObject:key]) return;
                SPDFCollectionThumbnailJob* job = [SPDFCollectionThumbnailJob new];
                job.key = key; job.diskKey = stored; job.render = render;
                [loader enqueue:job];
            });
        }
    });
}
- (void)finishKey:(NSString*)key image:(NSImage*)image failure:(NSString*)failure {
    [_pending removeObject:key];
    if (image) [_memory setObject:image forKey:key cost:PixelBytes(image)];
    if (_deliver) _deliver(key, image, failure);
}
- (void)enqueue:(SPDFCollectionThumbnailJob*)job {
    if (_visibleKeysProvider) [self setVisibleKeys:_visibleKeysProvider() ?: @[]];
    @synchronized(_jobs) {
        // A row that left and came back while its first lookup was still on the disk queue asks twice.
        if ([_rendering isEqualToString:job.key]) return;
        for (SPDFCollectionThumbnailJob* queued in _jobs) if ([queued.key isEqualToString:job.key]) return;
        [_jobs addObject:job];
        if (_draining) return;
        _draining = YES;
    }
    __weak SPDFCollectionThumbnailLoader* weakSelf = self;
    [_renderQueue addOperationWithBlock:^{ [weakSelf drain]; }];
}
- (SPDFCollectionThumbnailJob*)takeNextJob {
    @synchronized(_jobs) {
        SPDFCollectionThumbnailJob* next = nil;
        for (NSString* key in _visible) {
            for (SPDFCollectionThumbnailJob* job in _jobs) if ([job.key isEqualToString:key]) { next = job; break; }
            if (next) break;
        }
        // Rows AppKit prepared just off screen: the most recent first, they are nearest to where the list is going.
        if (!next) next = _jobs.lastObject;
        if (next) [_jobs removeObjectIdenticalTo:next]; else _draining = NO;
        _rendering = next.key;
        return next;
    }
}
- (void)drain {
    SPDFCollectionThumbnailJob* job;
    while ((job = [self takeNextJob])) @autoreleasepool {
        _renders++;
        BOOL persist = YES; NSString* failure = nil;
        NSImage* image = job.render(&persist, &failure);
        NSString* key = job.key;
        __weak SPDFCollectionThumbnailLoader* weakSelf = self;
        // Kept and shown even if its row left meanwhile: the pixels are paid for.
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf finishKey:key image:image failure:failure]; });
        @synchronized(_jobs) { _rendering = nil; }
        if (!image || !persist || !job.diskKey || !_directory) continue;
        NSData* bytes = SPDFCollectionThumbnailEncode(image);
        if (bytes) spdf_mac_markdown_image_cache_write(_directory, job.diskKey, bytes);
        BOOL trim = NO;
        @synchronized(_jobs) { trim = !_trimmed; _trimmed = YES; }
        // Once a window's life, after its first new thumbnail, in the background.
        NSURL* directory = _directory;
        if (trim) dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
            spdf_mac_markdown_image_cache_trim(directory, kSPDFCollectionThumbnailDiskBudget);
        });
    }
}
- (void)setVisibleKeys:(NSArray<NSString*>*)keys {
    @synchronized(_jobs) { _visible = [keys copy]; }
}
- (void)forgetKey:(NSString*)key {
    if (![_pending containsObject:key]) return;
    @synchronized(_jobs) {
        if ([_rendering isEqualToString:key]) return; // finishing; it is delivered and cached as usual
        for (SPDFCollectionThumbnailJob* job in [_jobs copy])
            if ([job.key isEqualToString:key]) [_jobs removeObject:job];
    }
    [_pending removeObject:key];
}
- (void)cancelQueued {
    NSString* rendering;
    @synchronized(_jobs) { [_jobs removeAllObjects]; rendering = _rendering; }
    // Lookups still on the disk queue come back to a key no longer pending, and stop there.
    [_pending removeAllObjects];
    if (rendering) [_pending addObject:rendering];
}
@end
