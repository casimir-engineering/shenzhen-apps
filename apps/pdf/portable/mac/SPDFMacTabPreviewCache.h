#pragma once

#import "SPDFMacTabHoverPreview.h"

NS_ASSUME_NONNULL_BEGIN

// Largest side of a tab hover thumbnail, in points. A4 portrait comes out
// 155 x 220 pt, 310 x 440 px at 2x: about 550 KB, so thirty tabs fit in 16 MB.
static const CGFloat kSPDFTabPreviewMaxPoints = 220.0;
// What every thumbnail together may hold. Past it the least recently used go.
static const size_t kSPDFTabPreviewByteBudget = 24u * 1024u * 1024u;

// The page's aspect ratio fitted inside maxPoints x maxPoints, whole points.
// pageSize is the page as displayed (MuPDF's bounds already include /Rotate).
NSSize SPDFTabPreviewPointSize(NSSize pageSize, CGFloat maxPoints);
// A width x height copy of `source`, opaque, in the source's RGB color space
// (sRGB otherwise). Returns +1, or NULL.
CGImageRef _Nullable SPDFTabPreviewCreateThumbnail(CGImageRef source, size_t width, size_t height) CF_RETURNS_RETAINED;
// An RGBA buffer (as the core renders it) as an image that owns a copy.
CGImageRef _Nullable SPDFTabPreviewCreateImageFromRGBA(const unsigned char* rgba, int width, int height,
                                                       int stride) CF_RETURNS_RETAINED;
// A page image's pixels as a CGImage that reads them in place and keeps the rep
// alive. -[NSBitmapImageRep CGImage] would do, but the image it returns keeps
// its own copy of the pixels once drawn, for as long as the page image lives:
// 1.4 MB for each restored tab's 492 x 700 page, 36 MB over a 30-tab session,
// measured. Returns +1, or NULL for a layout it does not read (planar, not
// 8-bit RGB(A)): that page then gets no thumbnail from memory.
CGImageRef _Nullable SPDFTabPreviewCreateImageReadingRep(NSBitmapImageRep* _Nullable rep) CF_RETURNS_RETAINED;
// "size:mtime" from a bare lstat of path: silent, never a permission prompt. Nil when it cannot be read.
NSString* _Nullable SPDFTabPreviewFileStamp(NSString* _Nullable path);

@interface SPDFTabPreviewEntry : NSObject <SPDFTabHoverPreview>
- (instancetype)initWithImage:(CGImageRef)image pointSize:(NSSize)pointSize pageIndex:(NSInteger)pageIndex;
- (instancetype)init NS_UNAVAILABLE;
// The page as displayed when the thumbnail was made: a turn swaps these.
@property(nonatomic) NSSize pageSize;
// The reading-theme render flags its pixels were made under.
@property(nonatomic) unsigned renderFlags;
// The page image it was scaled from (nil when rendered from the file), and the
// file as it was then. Together they decide whether it still shows the page.
@property(nonatomic, weak, nullable) id source;
@property(nonatomic, copy, nullable) NSString* fileStamp;
@property(nonatomic, readonly) size_t byteCount;
@property(nonatomic) uint64_t lastUse;
@end

// Thumbnails by tab, least recently used dropped past a byte budget. Keys are
// held weakly: a closed tab's thumbnail goes with it. Main thread only.
@interface SPDFTabPreviewCache : NSObject
- (instancetype)initWithByteBudget:(size_t)budget;
- (nullable SPDFTabPreviewEntry*)entryForTab:(id)tab;
- (void)setEntry:(SPDFTabPreviewEntry*)entry forTab:(id)tab;
- (void)removeEntryForTab:(id)tab;
- (void)removeAllEntries;
@property(nonatomic, readonly) size_t byteCount;
@property(nonatomic, readonly) NSUInteger count;
@property(nonatomic, readonly) size_t byteBudget;
@end

NS_ASSUME_NONNULL_END
