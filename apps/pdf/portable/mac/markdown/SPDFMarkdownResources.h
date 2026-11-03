#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// Canonical cache key for a remote image target: the absolute URL string when
// the target is a well-formed https URL, nil otherwise. https is the only
// remote scheme the pipeline accepts — http, data, file and every other
// scheme keep rendering the text placeholder.
FOUNDATION_EXPORT NSString* _Nullable SPDFMarkdownRemoteImageKeyForTarget(NSString* target);

// SVG bytes to an image, or nil. ImageIO cannot read SVG and AppKit's own SVG
// support draws common charts wrongly (matplotlib's `font:` shorthand, glyphs
// placed with <use>), so the reader installs a decoder built on its SVG
// renderer (mac/SPDFMacSVGImage.mm). A process without one -- the Collection
// companion, the engine's own test binaries -- falls back to NSImage.
typedef NSImage* _Nullable (*SPDFMarkdownSVGDecoder)(NSData* data);
FOUNDATION_EXPORT void SPDFMarkdownSetSVGDecoder(SPDFMarkdownSVGDecoder _Nullable decoder);
FOUNDATION_EXPORT BOOL SPDFMarkdownDataLooksLikeSVG(NSData* data);
// A vector picture (an SVG as the decoder above makes it, or a PDF) is drawn
// from its page at every draw, so it stays sharp at any zoom. The dark theme
// draws it from a copy whose colours went through the dark theme's remap,
// made by the recolourer the reader installs (core/spdf_svg_image.h): PDF
// bytes in, the recoloured PDF's bytes out, nil when it cannot.
typedef NSData* _Nullable (*SPDFMarkdownVectorRecolorer)(NSData* pdf);
FOUNDATION_EXPORT void SPDFMarkdownSetVectorRecolorer(SPDFMarkdownVectorRecolorer _Nullable recolorer);
FOUNDATION_EXPORT SPDFMarkdownVectorRecolorer _Nullable SPDFMarkdownInstalledVectorRecolorer(void);
// Image bytes ImageIO did not identify: SVG through the installed decoder, the
// rest through NSImage.
FOUNDATION_EXPORT NSImage* _Nullable SPDFMarkdownImageFromData(NSData* data);

// Holds a verified directory descriptor for one Markdown document and shares
// each picture across every reference in a render. Remote https images are
// served purely from `remoteImageData` — bytes the session layer fetched ahead
// of the render — so the engine itself never touches the network and renders
// stay deterministic for a given byte map.
@interface SPDFMarkdownResourceStore : NSObject

// Bytes dataForTarget: has kept; pictures are not kept and do not count.
@property(nonatomic, readonly) NSUInteger loadedResourceBytes;
@property(nonatomic, readonly) NSUInteger cachedResourceCount;

// `maximumResourceBytes` caps each picture file, and what dataForTarget:
// keeps in all.
- (nullable instancetype)initWithDocumentURL:(NSURL*)documentURL;
- (nullable instancetype)initWithDocumentURL:(NSURL*)documentURL
                         maximumResourceBytes:(NSUInteger)maximumResourceBytes;
- (instancetype)init NS_UNAVAILABLE;

// A store with no pinned local directory: it can only serve remote https
// bytes from `remoteImageData`. Used for models without a source URL.
+ (instancetype)remoteOnlyStoreWithMaximumResourceBytes:(NSUInteger)maximumResourceBytes;

// Raw image bytes keyed by SPDFMarkdownRemoteImageKeyForTarget output.
// Consulted synchronously under the same per-file byte limit as local
// pictures.
@property(nonatomic, copy, nullable) NSDictionary<NSString*, NSData*>* remoteImageData;

// Creates an independent cache with render-specific budgets while retaining
// the exact directory identity pinned by this store.
- (nullable SPDFMarkdownResourceStore*)storeWithMaximumResourceBytes:(NSUInteger)maximumResourceBytes;

- (nullable NSData*)dataForTarget:(NSString*)target resolvedURL:(NSURL* _Nullable* _Nullable)resolvedURL;
// A picture sized from its file's header and decoded only when drawn, at the
// size drawn (see SPDFMarkdownPicture.h); nil when it cannot be read as one.
- (nullable NSImage*)imageForTarget:(NSString*)target resolvedURL:(NSURL* _Nullable* _Nullable)resolvedURL;

@end

NS_ASSUME_NONNULL_END
