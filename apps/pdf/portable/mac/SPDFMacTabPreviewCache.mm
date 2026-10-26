#import "SPDFMacTabPreviewCache.h"

#import <AppKit/AppKit.h>

#include <sys/stat.h>

NSSize SPDFTabPreviewPointSize(NSSize pageSize, CGFloat maxPoints) {
    if (!(pageSize.width > 0) || !(pageSize.height > 0) || !isfinite(pageSize.width) || !isfinite(pageSize.height))
        return NSZeroSize;
    CGFloat scale = maxPoints / MAX(pageSize.width, pageSize.height);
    // A strip of a page (a receipt, a banner) keeps a visible short side.
    return NSMakeSize(MAX(24.0, round(pageSize.width * scale)), MAX(24.0, round(pageSize.height * scale)));
}

static CGColorSpaceRef CopyRGBSpace(CGImageRef source) {
    CGColorSpaceRef space = source ? CGImageGetColorSpace(source) : NULL;
    if (space && CGColorSpaceGetModel(space) == kCGColorSpaceModelRGB) return CGColorSpaceRetain(space);
    return CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
}

CGImageRef SPDFTabPreviewCreateThumbnail(CGImageRef source, size_t width, size_t height) {
    if (!source || !width || !height) return NULL;
    CGColorSpaceRef space = CopyRGBSpace(source);
    // Opaque, native byte order: the layer composites it without blending and
    // without a conversion pass.
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, 0, space,
                                                 kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    if (!context) return NULL;
    CGContextSetRGBFillColor(context, 1, 1, 1, 1);
    CGContextFillRect(context, CGRectMake(0, 0, width, height));
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), source);
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return image;
}

CGImageRef SPDFTabPreviewCreateImageFromRGBA(const unsigned char* rgba, int width, int height, int stride) {
    if (!rgba || width <= 0 || height <= 0 || stride < width * 4) return NULL;
    CFDataRef data = CFDataCreate(NULL, rgba, (CFIndex)stride * height);
    if (!data) return NULL;
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CFRelease(data);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef image = CGImageCreate((size_t)width, (size_t)height, 8, 32, (size_t)stride, space,
                                     kCGImageAlphaLast | kCGBitmapByteOrder32Big, provider, NULL, false,
                                     kCGRenderingIntentDefault);
    CGColorSpaceRelease(space);
    CGDataProviderRelease(provider);
    return image;
}

static void ReleaseRep(void* info, const void* data, size_t size) {
    (void)data, (void)size;
    CFRelease(info);
}

CGImageRef SPDFTabPreviewCreateImageReadingRep(NSBitmapImageRep* rep) {
    if (!rep || rep.isPlanar || rep.bitsPerSample != 8 || !rep.bitmapData ||
        (rep.samplesPerPixel != 4 && rep.samplesPerPixel != 3) || rep.bitsPerPixel != 32)
        return NULL;
    NSBitmapFormat format = rep.bitmapFormat;
    CGBitmapInfo info = kCGBitmapByteOrder32Big;
    if (format & (NSBitmapFormatFloatingPointSamples | NSBitmapFormatSixteenBitLittleEndian |
                  NSBitmapFormatThirtyTwoBitLittleEndian | NSBitmapFormatSixteenBitBigEndian |
                  NSBitmapFormatThirtyTwoBitBigEndian))
        return NULL;
    BOOL first = (format & NSBitmapFormatAlphaFirst) != 0;
    BOOL premultiplied = !(format & NSBitmapFormatAlphaNonpremultiplied);
    if (!rep.hasAlpha) info |= first ? kCGImageAlphaNoneSkipFirst : kCGImageAlphaNoneSkipLast;
    else if (first) info |= premultiplied ? kCGImageAlphaPremultipliedFirst : kCGImageAlphaFirst;
    else info |= premultiplied ? kCGImageAlphaPremultipliedLast : kCGImageAlphaLast;
    CGColorSpaceRef space = [rep.colorSpaceName isEqualToString:NSCalibratedRGBColorSpace]
        ? CGColorSpaceCreateWithName(kCGColorSpaceSRGB) : CGColorSpaceCreateDeviceRGB();
    size_t length = (size_t)rep.bytesPerRow * (size_t)rep.pixelsHigh;
    CGDataProviderRef provider = CGDataProviderCreateWithData((__bridge_retained void*)rep, rep.bitmapData, length,
                                                              ReleaseRep);
    CGImageRef image = CGImageCreate((size_t)rep.pixelsWide, (size_t)rep.pixelsHigh, 8, 32, (size_t)rep.bytesPerRow,
                                     space, info, provider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(space);
    return image;
}

NSString* SPDFTabPreviewFileStamp(NSString* path) {
    struct stat info;
    if (!path.length || lstat(path.fileSystemRepresentation, &info) != 0) return nil;
    return [NSString stringWithFormat:@"%lld:%ld.%09ld", (long long)info.st_size, (long)info.st_mtimespec.tv_sec,
                                      (long)info.st_mtimespec.tv_nsec];
}

@implementation SPDFTabPreviewEntry {
    CGImageRef _image;
    NSSize _pointSize;
    NSInteger _pageIndex;
}
- (instancetype)initWithImage:(CGImageRef)image pointSize:(NSSize)pointSize pageIndex:(NSInteger)pageIndex {
    if ((self = [super init])) {
        _image = CGImageRetain(image);
        _pointSize = pointSize;
        _pageIndex = pageIndex;
    }
    return self;
}
- (void)dealloc { CGImageRelease(_image); }
- (CGImageRef)image { return _image; }
- (NSSize)pointSize { return _pointSize; }
- (NSInteger)pageIndex { return _pageIndex; }
- (size_t)byteCount { return _image ? CGImageGetBytesPerRow(_image) * CGImageGetHeight(_image) : 0; }
@end

@implementation SPDFTabPreviewCache {
    NSMapTable<id, SPDFTabPreviewEntry*>* _entries;
    uint64_t _clock;
    size_t _budget;
}
- (instancetype)initWithByteBudget:(size_t)budget {
    if ((self = [super init])) {
        _entries = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory |
                                                      NSPointerFunctionsObjectPointerPersonality
                                         valueOptions:NSPointerFunctionsStrongMemory];
        _budget = budget;
    }
    return self;
}
- (size_t)byteBudget { return _budget; }
- (SPDFTabPreviewEntry*)entryForTab:(id)tab {
    SPDFTabPreviewEntry* entry = tab ? [_entries objectForKey:tab] : nil;
    entry.lastUse = ++_clock;
    return entry;
}
- (void)setEntry:(SPDFTabPreviewEntry*)entry forTab:(id)tab {
    if (!tab || !entry) return;
    entry.lastUse = ++_clock;
    [_entries setObject:entry forKey:tab];
    // Tens of entries at most: a scan is cheaper than keeping a list in order.
    while (self.byteCount > _budget && _entries.count > 1) {
        id oldest = nil;
        uint64_t oldestUse = UINT64_MAX;
        for (id key in _entries) {
            SPDFTabPreviewEntry* candidate = [_entries objectForKey:key];
            if (candidate != entry && candidate.lastUse < oldestUse) {
                oldest = key;
                oldestUse = candidate.lastUse;
            }
        }
        if (!oldest) break;
        [_entries removeObjectForKey:oldest];
    }
}
- (void)removeEntryForTab:(id)tab {
    if (tab) [_entries removeObjectForKey:tab];
}
- (void)removeAllEntries { [_entries removeAllObjects]; }
// By key: an entry whose tab has gone is skipped even before the table purges it.
- (size_t)byteCount {
    size_t total = 0;
    for (id key in _entries) total += [_entries objectForKey:key].byteCount;
    return total;
}
- (NSUInteger)count {
    NSUInteger count = 0;
    for (id key in _entries) count += [_entries objectForKey:key] != nil;
    return count;
}
@end
