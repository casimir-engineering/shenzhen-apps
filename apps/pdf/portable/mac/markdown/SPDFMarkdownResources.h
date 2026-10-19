#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// Canonical cache key for a remote image target: the absolute URL string when
// the target is a well-formed https URL, nil otherwise. https is the only
// remote scheme the pipeline accepts — http, data, file and every other
// scheme keep rendering the text placeholder.
FOUNDATION_EXPORT NSString* _Nullable SPDFMarkdownRemoteImageKeyForTarget(NSString* target);

// Holds a verified directory descriptor for one Markdown document and shares
// decoded images across every reference in a render. Remote https images are
// served purely from `remoteImageData` — bytes the session layer fetched ahead
// of the render — so the engine itself never touches the network and renders
// stay deterministic for a given byte map.
@interface SPDFMarkdownResourceStore : NSObject

@property(nonatomic, readonly) NSUInteger loadedResourceBytes;
@property(nonatomic, readonly) NSUInteger decodedImagePixels;
@property(nonatomic, readonly) NSUInteger cachedResourceCount;

- (nullable instancetype)initWithDocumentURL:(NSURL*)documentURL;
- (nullable instancetype)initWithDocumentURL:(NSURL*)documentURL
                         maximumResourceBytes:(NSUInteger)maximumResourceBytes
                    maximumDecodedImagePixels:(NSUInteger)maximumDecodedImagePixels;
- (instancetype)init NS_UNAVAILABLE;

// A store with no pinned local directory: it can only serve remote https
// bytes from `remoteImageData`. Used for models without a source URL.
+ (instancetype)remoteOnlyStoreWithMaximumResourceBytes:(NSUInteger)maximumResourceBytes
                              maximumDecodedImagePixels:(NSUInteger)maximumDecodedImagePixels;

// Raw image bytes keyed by SPDFMarkdownRemoteImageKeyForTarget output.
// Consulted synchronously under the same aggregate byte/pixel budgets as
// local resources.
@property(nonatomic, copy, nullable) NSDictionary<NSString*, NSData*>* remoteImageData;

// Creates an independent cache with render-specific budgets while retaining
// the exact directory identity pinned by this store.
- (nullable SPDFMarkdownResourceStore*)storeWithMaximumResourceBytes:(NSUInteger)maximumResourceBytes
                                           maximumDecodedImagePixels:(NSUInteger)maximumDecodedImagePixels;

- (nullable NSData*)dataForTarget:(NSString*)target resolvedURL:(NSURL* _Nullable* _Nullable)resolvedURL;
- (nullable NSImage*)imageForTarget:(NSString*)target resolvedURL:(NSURL* _Nullable* _Nullable)resolvedURL;

@end

NS_ASSUME_NONNULL_END
