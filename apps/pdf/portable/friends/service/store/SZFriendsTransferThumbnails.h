// Shenzhen Friends transfers: where file previews are kept, and when they go (brief § Transfers, Thumbnails before
// acceptance; ADR 0003, schema v6).
//
// Helper-only. One row per transfer in friends.sqlite (table transfer_thumbnails), pointing at a PNG in
// <state dir>/thumbnails/ named by this Mac, never by the sender. Making and checking the pictures is the thumbnails
// area's (service/thumbnails/SZFriendsThumbnails.h); this records them, with the rules that decide which to keep:
//   - Sender: our own file's picture, made from its snapshot, with the QOI the outbox delivers after the OFFER until
//     the friend's Mac acknowledges it (then the QOI is dropped; the PNG stays for our own history).
//   - Recipient: at most one picture per offer from that friend, kept only while the file has not arrived (waiting or
//     receiving); once the digest checks, a picture made here from the real file replaces it, or nothing does.
//   - A transfer that is declined, cancelled, or that fails before anyone accepted it (an offer that expired or was
//     refused) loses its picture, file and row, on both sides, in the same transaction as the state change.
//   - Delete history and Reset Friends remove pictures with their transfers.

#import <Foundation/Foundation.h>

#import "service/store/SZFriendsTransfers.h"

NS_ASSUME_NONNULL_BEGIN

// PROTOCOL.md transfer thumbnail.source: "sender" and "local".
typedef NS_ENUM(NSInteger, SZFriendsThumbnailSource) {
    SZFriendsThumbnailSourceSender = 1, // the sender's picture of the file, received before acceptance
    SZFriendsThumbnailSourceLocal = 2,  // made on this Mac from the file itself
};

@interface SZFriendsThumbnailRecord : NSObject
@property(nonatomic, copy) NSString *transferID;
@property(nonatomic) SZFriendsThumbnailSource source;
@property(nonatomic) NSUInteger width;
@property(nonatomic) NSUInteger height;
@property(nonatomic, copy) NSString *path;            // the PNG, inside -thumbnailDirectory
@property(nonatomic, copy, nullable) NSData *qoi;     // sender: what the outbox sends; nil once delivered
@property(nonatomic) BOOL delivered;                  // sender: the friend's Mac acknowledged it
@end

@interface SZFriendsTransfers (Thumbnails)
// <state dir>/thumbnails/: where callers write PNGs (SZFriendsWriteThumbnailFile) before recording them.
@property(nonatomic, readonly) NSString *thumbnailDirectory;

- (nullable SZFriendsThumbnailRecord *)thumbnailForTransfer:(NSString *)transferID;

// Sender. Records our picture of our own pending offer (Queued or Offered). Stale when the offer was answered,
// withdrawn or deleted meanwhile, or already has one; Invalid for a path outside -thumbnailDirectory or sizes out of
// range. On any failure the caller deletes the file it wrote.
- (BOOL)setOutgoingThumbnailForTransfer:(NSString *)transferID
                                   path:(NSString *)path
                                  width:(NSUInteger)width
                                 height:(NSUInteger)height
                                    qoi:(NSData *)qoi
                                  error:(NSError **)error;
// Our pending offers in this conversation whose picture still has to reach the friend, oldest first.
- (NSArray<SZFriendsThumbnailRecord *> *)thumbnailsToSendInConversation:(NSString *)conversationID;
// The friend's Mac acknowledged our THUMBNAIL: nothing more to send. Checked against the conversation it came from.
- (BOOL)markThumbnailDelivered:(NSString *)transferID fromConversation:(NSString *)conversationID
                         error:(NSError **)error;

// Recipient. Whether a THUMBNAIL naming this id may be kept: an incoming transfer of this conversation whose file has
// not arrived (waiting for an answer, or receiving), with no picture yet. Reads only, before anything is decoded.
- (BOOL)mayRecordReceivedThumbnailForTransfer:(NSString *)transferID fromConversation:(NSString *)conversationID;
// Records the picture decoded and re-encoded on this Mac, under the same checks in one transaction: Stale for a
// second one or a transfer no longer waiting. On failure the caller deletes the file it wrote.
- (BOOL)recordReceivedThumbnailForTransfer:(NSString *)transferID
                          fromConversation:(NSString *)conversationID
                                      path:(NSString *)path
                                     width:(NSUInteger)width
                                    height:(NSUInteger)height
                                     error:(NSError **)error;
// After the digest checked: our picture of the received file replaces whatever is there, or, with a nil path, the
// sender's picture goes and the file shows its type icon. Stale unless the transfer is Received.
- (BOOL)replaceThumbnailOfReceivedTransfer:(NSString *)transferID
                                 localPath:(nullable NSString *)path
                                     width:(NSUInteger)width
                                    height:(NSUInteger)height
                                     error:(NSError **)error;

// Deletes files in -thumbnailDirectory that no row names: left by a crash between writing a file and recording it,
// or by an older helper whose deletes removed rows without knowing about the files. At helper start.
- (void)removeUnreferencedThumbnailFiles;
@end

NS_ASSUME_NONNULL_END
