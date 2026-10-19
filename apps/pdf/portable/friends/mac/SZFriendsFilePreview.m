// SZFriendsFilePreviewView: the picture at a transfer card's leading edge (PROTOCOL.md § Thumbnails).
//
// The helper's preview of the file when the item carries one, shown before the file is accepted, on both sides; the
// file type's own icon otherwise, drawn here from file.type_identifier. WHY the checks below although the helper wrote
// the PNG: a view loads exactly one thing, the preview in the helper's own thumbnails directory, never the file
// itself or anything else a friend sent, so a path that is not that (a mistake anywhere upstream) shows the type icon.

#import "mac/SZFriendsHelperFiles.h"
#import "mac/SZFriendsItemViewsInternal.h"

#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// The longest side a preview takes on the card. The helper's are at most 192 px, so 64 pt stays sharp at 2x and 3x.
// The same 64 pt in both apps (PROTOCOL.md § Thumbnails, What views get; the GTK views' preview limit), so one offer
// card is the same size in ShenzhenPDF and Shenzhen Files; a 96 pt box made it half as tall again in one of them.
static const CGFloat SZFPreviewBox = 64;
static const NSInteger SZFPreviewMaxPixels = 192; // PROTOCOL.md type.thumbnail: 1 to 192
// The helper's previews are uncompressed PNGs of at most 192 × 192 (about 148 KB); anything far larger is not one.
static const off_t SZFPreviewFileLimit = 1 << 20;
static const NSSize SZFTypeIconSlot = {28, 34};

CGImageRef SZFriendsCopyThumbnailImage(NSString *path, NSInteger width, NSInteger height) {
    // Directly in the helper's thumbnails directory, a regular file reached without a link (SZFriendsHelperFiles.h).
    if (width < 1 || height < 1 || width > SZFPreviewMaxPixels || height > SZFPreviewMaxPixels ||
        !SZFriendsIsHelperFile(path ?: @"", @"thumbnails"))
        return NULL;
    NSData *data = SZFriendsReadRegularFile(path, SZFPreviewFileLimit);
    // A PNG whose IHDR is exactly the size the snapshot laid out, or nothing: the card never jumps to another shape,
    // and nothing of another size is decoded.
    NSInteger declaredWidth = 0, declaredHeight = 0;
    BOOL isPNG = NO;
    if (!data || !SZFriendsDeclaredImageSize(data, &declaredWidth, &declaredHeight, &isPNG) || !isPNG ||
        declaredWidth != width || declaredHeight != height)
        return NULL;
    NSDictionary *sourceOptions = @{(id)kCGImageSourceShouldCache : @NO};
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data,
                                                          (__bridge CFDictionaryRef)sourceOptions);
    if (!source) return NULL;
    // Decoded here, off the main thread, rather than when it is first drawn.
    NSDictionary *imageOptions = @{(id)kCGImageSourceShouldCacheImmediately : @YES};
    CGImageRef image = NULL;
    if ([(__bridge NSString *)CGImageSourceGetType(source) isEqualToString:UTTypePNG.identifier] &&
        CGImageSourceGetCount(source) == 1)
        image = CGImageSourceCreateImageAtIndex(source, 0, (__bridge CFDictionaryRef)imageOptions);
    CFRelease(source);
    if (image && ((NSInteger)CGImageGetWidth(image) != width || (NSInteger)CGImageGetHeight(image) != height)) {
        CGImageRelease(image);
        image = NULL;
    }
    return image;
}

// Decoded previews by path and size: reopening a conversation shows them at once.
static NSCache<NSString *, NSImage *> *SZFPreviewImages(void) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.countLimit = 200;
    });
    return cache;
}

// One serial queue, off the main thread: a history of many files lays out at once and fills in its pictures.
static dispatch_queue_t SZFPreviewQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("szfriends.views.previews",
                                      dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                                              QOS_CLASS_UTILITY, 0));
    });
    return queue;
}

@implementation SZFriendsFilePreviewView {
    NSString *_key;     // path and size of the preview asked for; nil without one
    NSString *_kindLabel;
    NSSize _previewSize;
    NSUInteger _generation;
}

- (BOOL)isFlipped {
    return YES;
}

- (BOOL)isAccessibilityElement {
    return NO; // the item's accessibility label already names the file
}

- (NSSize)size {
    if (_state == SZFriendsPreviewTypeIcon) return SZFTypeIconSlot;
    return NSMakeSize(SZFPreviewBox, _previewSize.height);
}

- (void)applyFile:(NSDictionary *)file thumbnail:(NSDictionary *)thumbnail {
    _kindLabel = SZFStr(file, @"kind_label") ?: @"";
    NSString *identifier = SZFStr(file, @"type_identifier");
    UTType *type = identifier.length ? [UTType typeWithIdentifier:identifier] : nil;
    // The type's icon as this Mac draws it; with no identifier the drawn page and the kind label stand in.
    _typeIcon = type ? [NSWorkspace.sharedWorkspace iconForContentType:type] : nil;
    NSString *path = SZFStr(thumbnail, @"path");
    NSInteger width = (NSInteger)SZFNum(thumbnail, @"width"), height = (NSInteger)SZFNum(thumbnail, @"height");
    BOOL usable = path.length && width >= 1 && height >= 1 && width <= SZFPreviewMaxPixels &&
                  height <= SZFPreviewMaxPixels;
    NSString *key = usable ? [NSString stringWithFormat:@"%ldx%ld|%@", (long)width, (long)height, path] : nil;
    self.needsDisplay = YES;
    if (key && [key isEqualToString:_key]) return; // the same preview: loaded, loading or unreadable as before
    _key = key;
    _generation++;
    _image = nil;
    if (!key) {
        _state = SZFriendsPreviewTypeIcon;
        return;
    }
    // Laid out from the snapshot's size before anything loads, never upscaled past one point per pixel.
    CGFloat scale = MIN(1, MIN(SZFPreviewBox / width, SZFPreviewBox / height));
    _previewSize = NSMakeSize(MAX(1, round(width * scale)), MAX(1, round(height * scale)));
    NSImage *cached = [SZFPreviewImages() objectForKey:key];
    if (cached) {
        _image = cached;
        _state = SZFriendsPreviewShown;
        return;
    }
    _state = SZFriendsPreviewLoading;
    NSUInteger generation = _generation;
    __weak SZFriendsFilePreviewView *weakSelf = self;
    dispatch_async(SZFPreviewQueue(), ^{
        CGImageRef decoded = SZFriendsCopyThumbnailImage(path, width, height);
        dispatch_async(dispatch_get_main_queue(), ^{
            NSImage *image = decoded ? [[NSImage alloc] initWithCGImage:decoded size:NSMakeSize(width, height)] : nil;
            if (decoded) CGImageRelease(decoded);
            if (image) [SZFPreviewImages() setObject:image forKey:key];
            [weakSelf finishLoad:image generation:generation];
        });
    });
}

- (void)finishLoad:(NSImage *)image generation:(NSUInteger)generation {
    if (generation != _generation) return; // another preview was asked for meanwhile
    _image = image;
    _state = image ? SZFriendsPreviewShown : SZFriendsPreviewTypeIcon;
    self.needsDisplay = YES;
    // Missing or unreadable: no preview. The type icon's slot is narrower, so the card lays out again.
    if (!image)
        for (NSView *view = self.superview; view; view = view.superview) view.needsLayout = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect bounds = self.bounds;
    if (_state == SZFriendsPreviewTypeIcon) {
        if (_typeIcon) {
            CGFloat side = MIN(NSWidth(bounds), NSHeight(bounds));
            [_typeIcon drawInRect:NSMakeRect(NSMidX(bounds) - side / 2, NSMidY(bounds) - side / 2, side, side)
                         fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1
                   respectFlipped:YES hints:nil];
        } else {
            SZFriendsDrawDocumentGlyph(bounds, _kindLabel, SZFriendsDynamicColor(0x3a3a46, 0x3a3a46));
        }
        return;
    }
    NSRect picture = NSMakeRect(floor(NSMidX(bounds) - _previewSize.width / 2), NSMinY(bounds), _previewSize.width,
                                _previewSize.height);
    NSBezierPath *frame = [NSBezierPath bezierPathWithRoundedRect:picture xRadius:4 yRadius:4];
    if (_state == SZFriendsPreviewLoading || !_image) {
        // Its place, until the picture arrives: a faint tile of the picture's own size.
        [[self.theme.separatorColor colorWithAlphaComponent:0.35] setFill];
        [frame fill];
        return;
    }
    [NSGraphicsContext saveGraphicsState];
    [frame addClip];
    NSGraphicsContext.currentContext.imageInterpolation = NSImageInterpolationHigh;
    [_image drawInRect:picture fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1
        respectFlipped:YES hints:nil];
    [NSGraphicsContext restoreGraphicsState];
    // A hairline, so a white page shows its edge on a light card.
    [self.theme.separatorColor setStroke];
    NSBezierPath *edge = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(picture, 0.5, 0.5) xRadius:4 yRadius:4];
    edge.lineWidth = 1;
    [edge stroke];
}

@end
