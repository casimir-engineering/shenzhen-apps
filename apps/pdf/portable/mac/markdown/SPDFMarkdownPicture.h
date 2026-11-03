#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// A picture a Markdown document shows, laid out at its pixel size but decoded
// only when it is drawn, and only as large as it is drawn.
//
// Layout needs nothing but the pixel size, which ImageIO reads from the file's
// header. Each draw asks for the device pixels the destination really covers
// (the fitted display size times the screen's backing scale times the zoom) and
// gets an ImageIO thumbnail of at least that size, so a 4000 x 3000 photo shown
// 440 pt wide on a Retina screen costs about 1 MP, not 12. (A picture at most
// twice the size wanted is drawn from the file as it is: thumbnailing it would
// cost a full decode and a copy for little saving.) Zooming in past what
// was decoded decodes again, sharper, the next time the page is drawn. Print and
// PDF export (contexts with no pixels of their own) get 300 dpi: the file itself
// when it is at most twice that, else a copy (a JPEG for a JPEG). Nothing
// is ever decoded past SPDFMarkdownPictureMaximumDecodedSide a side: a bigger
// picture is drawn from a downsampled copy, never left out.
//
// Decoded pixels live in purgeable memory behind a shared cost-limited cache:
// while no draw holds them the system may reclaim them (and the cache drops the
// least recently used), and the next draw decodes again. The compressed bytes
// are not kept either; `reload` reads them again for each decode.
@interface SPDFMarkdownPictureRep : NSImageRep

// An image holding one picture rep sized from `bytes`, or nil when ImageIO
// cannot read a pixel size from them. `reload` may run on any thread.
+ (nullable NSImage*)imageWithBytes:(NSData*)bytes reload:(NSData* _Nullable (^)(void))reload;

// The picture to draw into `size` user-space points of `context`, decoded for
// the pixels that covers. `variant` (optional) derives the drawn picture from
// the decoded one, such as the dark theme's recolor; its result is cached with
// the decode. NULL when the picture can no longer be read.
- (nullable CGImageRef)copyImageForContext:(CGContextRef)context
                                      size:(CGSize)size
                                   variant:(CGImageRef _Nullable (*_Nullable)(CGImageRef))variant
    CF_RETURNS_RETAINED;

// The longest side of the decode currently cached, 0 when there is none.
@property(nonatomic, readonly) NSUInteger cachedLongestSide;

@end

FOUNDATION_EXPORT const NSUInteger SPDFMarkdownPictureMaximumDecodedSide;

// The picture rep behind `image`, when it is one.
FOUNDATION_EXPORT SPDFMarkdownPictureRep* _Nullable SPDFMarkdownPictureRepForImage(NSImage* _Nullable image);

NS_ASSUME_NONNULL_END
