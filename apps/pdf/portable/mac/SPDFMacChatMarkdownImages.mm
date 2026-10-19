#import "SPDFMacChatMarkdownParts.h"

#import "SPDFMacMarkdownSessionImageLoader.h"
#import "markdown/SPDFMarkdownResources.h"

// Remote images in a chat message load only when the person clicks Load image on that message. Fetching an image
// tells its server when the message was read and from which network address, so a friend's message (or a page the
// assistant quotes) must not do it by itself: the same reason Shenzhen Friends never fetches link previews.

static const CGFloat kImageMaximumHeight = 360;
static const CGFloat kPlaceholderWidth = 360;
// Decoded size cap: the engine's own budget for every image in a document, here for one.
static const double kImageMaximumPixels = 32.0 * 1024 * 1024;

static NSCache<NSString*, NSMutableDictionary<NSString*, NSData*>*>* LoadedImages(void) {
    static NSCache* cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      cache = [NSCache new];
      cache.countLimit = 200;
      cache.totalCostLimit = 64 * 1024 * 1024;
    });
    return cache;
}

static NSMutableSet<NSString*>* StateSet(NSUInteger which) {
    static NSMutableSet* sets[2];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      sets[0] = [NSMutableSet set];
      sets[1] = [NSMutableSet set];
    });
    return sets[which];
}
static NSMutableSet<NSString*>* Loading(void) { return StateSet(0); }
static NSMutableSet<NSString*>* Failed(void) { return StateSet(1); }

static NSString* StateKey(NSString* messageKey, NSURL* URL) {
    return [NSString stringWithFormat:@"%lu:%@\n%@", (unsigned long)messageKey.length, messageKey, URL.absoluteString];
}

NSData* SPDFMacChatLoadedImage(NSString* messageKey, NSURL* URL) {
    return [LoadedImages() objectForKey:messageKey][URL.absoluteString];
}
BOOL SPDFMacChatImageIsLoading(NSString* messageKey, NSURL* URL) {
    return [Loading() containsObject:StateKey(messageKey, URL)];
}
BOOL SPDFMacChatImageFailed(NSString* messageKey, NSURL* URL) {
    return [Failed() containsObject:StateKey(messageKey, URL)];
}
void SPDFMacChatForgetLoadedImages(void) {
    [LoadedImages() removeAllObjects];
    [Loading() removeAllObjects];
    [Failed() removeAllObjects];
}

static NSImage* DecodedImage(NSData* data) {
    NSImage* image = data.length ? [[NSImage alloc] initWithData:data] : nil;
    NSImageRep* rep = image.representations.firstObject;
    double pixels = (double)MAX(rep.pixelsWide, 1) * (double)MAX(rep.pixelsHigh, 1);
    if (!image || image.size.width <= 0 || image.size.height <= 0 || pixels > kImageMaximumPixels) return nil;
    return image;
}

// The network path: the reader's own remote-image loader (no cookies, https redirects only, image/* only, 20 MB),
// one per click, released when its one image lands or fails.
static void FetchOverNetwork(NSURL* URL, void (^completion)(NSData* data)) {
    static NSMutableSet<SPDFMacMarkdownSessionImageLoader*>* live;
    if (!live) live = [NSMutableSet set];
    NSString* key = SPDFMarkdownRemoteImageKeyForTarget(URL.absoluteString);
    if (!key) {
        completion(nil);
        return;
    }
    SPDFMacMarkdownSessionImageLoader* loader = [SPDFMacMarkdownSessionImageLoader new];
    loader.coalescingInterval = 0.05;
    __weak SPDFMacMarkdownSessionImageLoader* weakLoader = loader;
    loader.imagesUpdatedHandler = ^{
      SPDFMacMarkdownSessionImageLoader* owner = weakLoader;
      NSData* data = owner.loadedImageData[key];
      if (!owner || (!data && ![owner.failedTargets containsObject:key])) return;
      [live removeObject:owner];
      completion(data);
    };
    [live addObject:loader];
    [loader requestTargets:@[ key ]];
}

void SPDFMacChatLoadImage(NSString* messageKey, NSURL* URL, SPDFMacChatMarkdownImageFetch fetch,
                          void (^finished)(void)) {
    NSString* state = StateKey(messageKey, URL);
    if ([Loading() containsObject:state] || SPDFMacChatLoadedImage(messageKey, URL)) return;
    [Loading() addObject:state];
    [Failed() removeObject:state];
    void (^done)(NSData*) = ^(NSData* data) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [Loading() removeObject:state];
        if (DecodedImage(data)) {
            NSMutableDictionary* images = [LoadedImages() objectForKey:messageKey] ?: [NSMutableDictionary dictionary];
            images[URL.absoluteString] = data;
            NSUInteger cost = 0;
            for (NSData* each in images.allValues) cost += each.length;
            [LoadedImages() setObject:images forKey:messageKey cost:cost];
        } else {
            [Failed() addObject:state];
        }
        if (finished) finished();
      });
    };
    if (fetch) fetch(URL, done);
    else FetchOverNetwork(URL, done);
}

typedef NS_ENUM(NSInteger, ImageState) { ImageIdle, ImageLoading, ImageFailed, ImageShown };

@interface SPDFMacChatImageCell : NSTextAttachmentCell <SPDFMacChatContentCell>
@property(nonatomic, copy) NSURL* URL;
@property(nonatomic, copy) NSString* alt;
@property(nonatomic) NSSize size;
@property(nonatomic, strong) SPDFMacChatMarkdownOptions* options;
@property(nonatomic, weak) NSView* shownIn;
@end

@implementation SPDFMacChatImageCell
- (NSString*)messageKey { return self.options.messageKey ?: @""; }
- (ImageState)imageState {
    if (SPDFMacChatLoadedImage(self.messageKey, self.URL)) return ImageShown;
    if (SPDFMacChatImageIsLoading(self.messageKey, self.URL)) return ImageLoading;
    return SPDFMacChatImageFailed(self.messageKey, self.URL) ? ImageFailed : ImageIdle;
}
- (NSSize)cellSize { return self.size; }
- (NSPoint)cellBaselineOffset { return NSZeroPoint; }
- (NSRect)buttonRect {
    return self.size.width >= 240 ? NSMakeRect(self.size.width - 98, (self.size.height - 22) / 2, 86, 22)
                                  : NSMakeRect(12, self.size.height - 32, 86, 22);
}
- (NSString*)host { return self.URL.host.length ? self.URL.host : @"the web"; }
// y runs down from the top-left corner.
- (void)drawContent {
    SPDFMacChatMarkdownOptions* options = self.options;
    SPDFMarkdownTheme* theme = [SPDFMarkdownTheme themeForVariant:options.dark ? SPDFMarkdownThemeVariantDark
                                                                                : SPDFMarkdownThemeVariantLight];
    NSRect box = NSMakeRect(0, 0, self.size.width, self.size.height);
    ImageState state = self.imageState;
    NSImage* image = state == ImageShown ? DecodedImage(SPDFMacChatLoadedImage(self.messageKey, self.URL)) : nil;
    if (image) {
        // Loaded after this layout was made: shown whole inside the placeholder until the message lays out again.
        CGFloat scale = MIN(NSWidth(box) / image.size.width, NSHeight(box) / image.size.height);
        NSSize fitted = NSMakeSize(image.size.width * scale, image.size.height * scale);
        [image drawInRect:NSMakeRect(0, (NSHeight(box) - fitted.height) / 2, fitted.width, fitted.height)
                 fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES
                    hints:nil];
        return;
    }
    NSBezierPath* shape = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(box, .5, .5) xRadius:6 yRadius:6];
    [theme.imagePlaceholderFillColor setFill];
    [shape fill];
    [theme.imagePlaceholderStrokeColor setStroke];
    [shape stroke];
    NSString* format = state == ImageLoading  ? @"Loading the image from %@…"
                       : state == ImageFailed ? @"Couldn’t load the image from %@."
                                              : @"Image from %@";
    NSString* title = [NSString stringWithFormat:format, self.host];
    NSRect button = [self buttonRect];
    CGFloat textRight = self.size.width >= 240 && state != ImageLoading ? NSMinX(button) - 8 : self.size.width - 12;
    NSMutableParagraphStyle* truncating = [NSMutableParagraphStyle new];
    truncating.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary* primary = @{NSFontAttributeName : [NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
                              NSForegroundColorAttributeName : options.textColor,
                              NSParagraphStyleAttributeName : truncating};
    NSDictionary* secondary = @{NSFontAttributeName : [NSFont systemFontOfSize:11],
                                NSForegroundColorAttributeName : options.secondaryTextColor,
                                NSParagraphStyleAttributeName : truncating};
    BOOL wide = self.size.width >= 240;
    CGFloat titleY = wide ? (self.alt.length ? 12 : 20) : 10;
    [title drawInRect:NSMakeRect(12, titleY, textRight - 12, 16) withAttributes:primary];
    if (self.alt.length) [self.alt drawInRect:NSMakeRect(12, titleY + 17, textRight - 12, 15) withAttributes:secondary];
    if (state == ImageLoading) return;
    SPDFMacChatDrawPill(button, state == ImageFailed ? @"Try again" : @"Load image", theme, theme.bodyTextColor);
}
- (void)drawWithFrame:(NSRect)frame inView:(NSView*)view {
    self.shownIn = view;
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(context);
    if (view.isFlipped) {
        CGContextTranslateCTM(context, NSMinX(frame), NSMinY(frame));
    } else {
        CGContextTranslateCTM(context, NSMinX(frame), NSMaxY(frame));
        CGContextScaleCTM(context, 1, -1);
    }
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:context flipped:YES];
    [self drawContent];
    [NSGraphicsContext restoreGraphicsState];
    CGContextRestoreGState(context);
}
- (void)drawWithFrame:(NSRect)frame inView:(NSView*)view characterIndex:(NSUInteger)index
        layoutManager:(NSLayoutManager*)layoutManager {
    (void)index, (void)layoutManager;
    [self drawWithFrame:frame inView:view];
}
- (BOOL)wantsToTrackMouse { return YES; }
- (BOOL)wantsToTrackMouseForEvent:(NSEvent*)event inRect:(NSRect)frame ofView:(NSView*)view
                 atCharacterIndex:(NSUInteger)index {
    (void)event, (void)frame, (void)view, (void)index;
    ImageState state = self.imageState;
    return state == ImageIdle || state == ImageFailed;
}
// The whole placeholder is the click target; the drawn button is where the eye goes.
- (BOOL)trackMouse:(NSEvent*)event inRect:(NSRect)frame ofView:(NSView*)view atCharacterIndex:(NSUInteger)index
      untilMouseUp:(BOOL)flag {
    (void)index, (void)flag;
    NSEvent* up = event;
    while (up.type != NSEventTypeLeftMouseUp) {
        up = [view.window nextEventMatchingMask:NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged];
        if (!up) return YES;
    }
    if (!NSPointInRect([view convertPoint:up.locationInWindow fromView:nil], frame)) return YES;
    [self load];
    [view setNeedsDisplayInRect:frame];
    return YES;
}
- (void)load {
    ImageState state = self.imageState;
    if (state != ImageIdle && state != ImageFailed) return;
    __weak SPDFMacChatImageCell* weakSelf = self;
    void (^finished)(void) = self.options.imageFinished;
    SPDFMacChatLoadImage(self.messageKey, self.URL, self.options.fetchImage, ^{
      weakSelf.shownIn.needsDisplay = YES;
      if (finished) finished();
    });
    self.shownIn.needsDisplay = YES;
}
- (NSString*)accessibilityRole { return NSAccessibilityButtonRole; }
- (NSString*)accessibilityLabel { return [NSString stringWithFormat:@"Load the image from %@", self.host]; }
- (BOOL)accessibilityPerformPress {
    [self load];
    return YES;
}
@end

NSAttributedString* SPDFMacChatImageAttachment(NSURL* URL, NSString* alt, CGFloat maximumWidth,
                                               SPDFMacChatMarkdownOptions* options) {
    NSString* messageKey = options.messageKey ?: @"";
    NSImage* image = DecodedImage(SPDFMacChatLoadedImage(messageKey, URL));
    NSTextAttachment* attachment = nil;
    NSString* source = [NSString stringWithFormat:@"![%@](%@)", alt ?: @"", URL.absoluteString];
    if (image) {
        CGFloat scale = MIN(1, MIN(MAX(40, maximumWidth) / image.size.width, kImageMaximumHeight / image.size.height));
        NSSize size = NSMakeSize(floor(image.size.width * scale), floor(image.size.height * scale));
        attachment = [NSTextAttachment new];
        attachment.image = image;
        attachment.bounds = NSMakeRect(0, 0, size.width, size.height);
        // TextKit 1 sizes an image cell by the image itself.
        image.size = size;
    } else {
        SPDFMacChatImageCell* cell = [SPDFMacChatImageCell new];
        cell.URL = URL;
        cell.alt = alt.length > 200 ? [alt substringToIndex:200] : alt ?: @"";
        CGFloat width = floor(MIN(kPlaceholderWidth, MAX(160, maximumWidth)));
        cell.size = NSMakeSize(width, width >= 240 ? 56 : 76);
        cell.options = options;
        attachment = [SPDFMacChatAttachment attachmentWithCell:cell];
    }
    NSMutableAttributedString* result = [[NSAttributedString attributedStringWithAttachment:attachment] mutableCopy];
    NSRange all = NSMakeRange(0, result.length);
    [result addAttribute:SPDFMacChatMarkdownSourceAttribute value:source range:all];
    if (alt.length) [result addAttribute:NSToolTipAttributeName value:alt range:all];
    return result;
}
