// Shenzhen Friends file previews: the small picture of a file that travels with its offer, so the person deciding
// whether to accept sees the first page, the photo or the frame before any of the file's bytes move (brief
// § Transfers, Thumbnails before acceptance; PROTOCOL.md § Thumbnails).
//
// Helper-only. Two halves:
//   - Sending: a renderer (QuickLook on macOS, behind SZFriendsThumbnailRenderer so a later Linux helper supplies its
//     own) draws the file off the helper's queue within SZFriendsThumbnailRenderTimeout; the result is fitted to
//     SZFriendsThumbnailMaxSide and encoded as QOI within SZFriendsThumbnailMaxBytes, smaller sizes tried until it
//     fits. The same pixels become the PNG this Mac shows for its own offer.
//   - Receiving: SZFriendsPNGFromReceivedThumbnail checks the declared size and dimensions and the QOI header before
//     allocating anything, decodes with this module's own bounds-checked decoder (szfriends_qoi.h, fuzzed), and
//     re-encodes the pixels as a PNG with its own encoder (szfriends_image.h). Views only ever load that PNG.
// Where thumbnails are kept, and when they are deleted, is the store's (service/store/SZFriendsTransferThumbnails.h).

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern const NSUInteger SZFriendsThumbnailMaxSide;           // 192 px on the longer side
// 64,000 bytes of QOI ("64 KB"): a THUMBNAIL frame with its id, width and height fields stays well inside one
// session frame (SZFriendsFramePlaintextMax, 65,519 bytes).
extern const NSUInteger SZFriendsThumbnailMaxBytes;
extern const NSTimeInterval SZFriendsThumbnailRenderTimeout; // 2 s: no picture by then means none

// Pixels as a renderer produced them: RGBA, 8 bits per channel, straight alpha, rows top to bottom.
@interface SZFriendsThumbnailPixels : NSObject
// Nil unless `rgba` holds exactly width * height * 4 bytes and both sides are 1 to 4,096.
- (nullable instancetype)initWithRGBA:(NSData *)rgba width:(NSUInteger)width height:(NSUInteger)height;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) NSData *rgba;
@property(nonatomic, readonly) NSUInteger width;
@property(nonatomic, readonly) NSUInteger height;
@end

// The platform half of making a thumbnail.
@protocol SZFriendsThumbnailRenderer <NSObject>
// Calls `completion` once, on any queue, with pixels at most `maxSide` on the longer side, or nil when the system has
// no picture of this file (an unknown format: the views then draw its type's icon). `typeIdentifier` overrides what
// the path's extension says, for snapshots stored without one. Returns what stops the render (nil when nothing can):
// the maker calls it once the timeout has run out, so the system stops working on a file the helper has given up on,
// a hostile 1 GiB PDF say; `completion` may still be called after it, and is then ignored.
- (nullable dispatch_block_t)renderFileAtPath:(NSString *)path
                               typeIdentifier:(nullable NSString *)typeIdentifier
                                      maxSide:(NSUInteger)maxSide
                                   completion:(void (^)(SZFriendsThumbnailPixels *_Nullable pixels))completion;
@end

// QuickLook's thumbnail generator: whatever this Mac can preview (PDF, Office, Markdown and text, images, video).
// Asks for a real thumbnail only, never the file-type icon, so a format QuickLook cannot draw yields nil.
@interface SZFriendsQuickLookRenderer : NSObject <SZFriendsThumbnailRenderer>
@end

// A finished thumbnail: the QOI that travels and the PNG this Mac shows, made from the same pixels.
@interface SZFriendsThumbnail : NSObject
@property(nonatomic, readonly) NSUInteger width;
@property(nonatomic, readonly) NSUInteger height;
@property(nonatomic, readonly) NSData *qoi;
@property(nonatomic, readonly) NSData *png;
@end

// Pure: fits `pixels` to SZFriendsThumbnailMaxSide and encodes them, trying smaller sizes (160, 128, 112, 96, 80, 64,
// 48, 32 px) until the QOI fits SZFriendsThumbnailMaxBytes. Nil only when even the smallest does not.
SZFriendsThumbnail *_Nullable SZFriendsThumbnailFromPixels(SZFriendsThumbnailPixels *pixels);

// Recipient: a friend's QOI with the width and height its frame declared, as PNG bytes for the cache. Checks, before
// allocating the pixels, that the bytes are within SZFriendsThumbnailMaxBytes, that both declared sides are 1 to
// SZFriendsThumbnailMaxSide, and that the QOI header agrees with them; then decodes strictly. Nil, with a reason for
// the log, for anything else.
NSData *_Nullable SZFriendsPNGFromReceivedThumbnail(NSData *qoi, uint64_t declaredWidth, uint64_t declaredHeight,
                                                   NSString *_Nullable *_Nullable reason);

// Makes thumbnails off the caller's queue: at most two renders at a time, each given `timeout` from its start.
@interface SZFriendsThumbnailMaker : NSObject
- (instancetype)initWithRenderer:(id<SZFriendsThumbnailRenderer>)renderer
                         timeout:(NSTimeInterval)timeout NS_DESIGNATED_INITIALIZER;
- (instancetype)init; // SZFriendsQuickLookRenderer, SZFriendsThumbnailRenderTimeout
// Calls `completion` once on `queue`: the thumbnail, or nil when the renderer had none or took longer than the timeout
// (the render is then stopped, and a late picture is dropped, never delivered after the nil).
- (void)makeThumbnailOfFileAtPath:(NSString *)path
                   typeIdentifier:(nullable NSString *)typeIdentifier
                            queue:(dispatch_queue_t)queue
                       completion:(void (^)(SZFriendsThumbnail *_Nullable thumbnail))completion;
@end

// The uniform type identifier a file name's extension names, or nil (no extension, or a dynamic identifier that names
// nothing an app recognises). Views draw a file's type icon from it, or from the extension.
NSString *_Nullable SZFriendsTypeIdentifierForFileName(NSString *name);

// Writes `png` into `directory` (created 0700 when missing; refused when it is not a real directory) under a fresh
// random name, 0600, created exclusively without following a link, and flushed. The new file's path, or nil.
NSString *_Nullable SZFriendsWriteThumbnailFile(NSData *png, NSString *directory, NSError **error);

NS_ASSUME_NONNULL_END
