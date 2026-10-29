// Getting a file again from the friend who sent it (ADR 0016; PROTOCOL.md § Getting a file again). One exchange per
// session with a friend, carried by AGAIN frames (session minor 3); each message is one frame's Again field:
//   1 WANT   id (16) | offset u64 | parts u16       send these parts of the file offered under id
//   2 PART   id (16) | offset u64 | last u8 | bytes at most SZFriendsSyncFilePartMax, in order from offset
//   3 NONE   id (16) | reason u8                    SZFriendsAgainAnswer
//   4 WANT BLOCKS    id (16) | shift u8 | ranges    these blocks (ADR 0018 § 4; fast-transfer sessions only)
//   5 BLOCKS FOLLOW  id (16) | root (32) | shift u8  this tree; HASHES and PARTs follow on the session
// The requester copies one file at a time into <partial>/again-<transfer id> (a later session resumes it) and hands
// it over only once its whole digest matches; the server reads only the path its owner gives for that id. Both run on
// the caller's queue, with no store of their own: the helper (nearby/SZFriendsNearbyService+Again.m) decides what is
// wanted, what may be served and what a finished copy becomes.

#import <Foundation/Foundation.h>

@class SZFriendsFrame;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(uint8_t, SZFriendsAgainAnswer) {
    SZFriendsAgainAnswerNotHere = 0, // this computer does not have that file (unknown, not theirs, gone, changed)
    SZFriendsAgainAnswerNotNow = 1,  // ask again on a later session (busy, a limit, another of its computers has it)
};

// A file asked for again: its transfer id (32 lowercase hex characters, the offer id), size and BLAKE2b-256 digest.
@interface SZFriendsAgainFile : NSObject
@property(nonatomic, copy) NSString *transferID;
@property(nonatomic) uint64_t size;
@property(nonatomic, copy) NSData *digest;
@end

// Whether the file at `path` is exactly `size` bytes whose BLAKE2b-256 is `digest` (reads it whole).
BOOL SZFriendsFileHasDigest(NSString *path, uint64_t size, NSData *digest);
// A Get again or own-device copy given up for good (the file is gone, or the copy did not check): its partial file and
// the received-blocks record beside it (<path>.map) go together. Kept otherwise, across restarts (the store's sweep
// gives up one untouched for 30 days).
void SZFriendsRemoveCopy(NSString *path);

@interface SZFriendsAgainExchange : NSObject
- (instancetype)initWithPartialDirectory:(NSString *)directory
                                    send:(void (^)(NSData *message))send NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// Requester. The files to ask for, oldest first; a copy that arrived whole and matches its digest; a file the friend
// does not have (NONE 0, or bytes that did not match, whose partial copy is gone).
@property(nonatomic, copy, nullable) NSArray<SZFriendsAgainFile *> * (^wanted)(void);
@property(nonatomic, copy, nullable) void (^arrived)(SZFriendsAgainFile *file, NSString *path);
@property(nonatomic, copy, nullable) void (^notThere)(NSString *transferID);
// No room left here mid-copy: what arrived is gone, and the request ends (the next Get again says why).
@property(nonatomic, copy, nullable) void (^noRoom)(NSString *transferID);
// Server. The path to read a file's bytes from, checked by the owner (the session's person is the one it was sent to,
// the bytes are unchanged), its size in `*size`; nil with `*answer` set otherwise.
@property(nonatomic, copy, nullable) NSString *_Nullable (^servePath)(NSString *transferID, uint64_t *size,
                                                                     SZFriendsAgainAnswer *answer);
// The friend asks for a file by blocks (4 WANT BLOCKS): the blocks wanted, as packed (first, count) pairs. The owner
// calls -beginServingBlocks: and serves the file (5 BLOCKS FOLLOW, then HASHES and PARTs on the session); without
// this, the answer is NONE "not now".
@property(nonatomic, copy, nullable) void (^wantBlocks)(NSString *transferID, uint8_t shift, NSData *ranges);
// The same checks as a WANT's (one file at a time, -servePath): the path to serve and its size, marked as the file
// being served; nil after answering NONE.
- (nullable NSString *)beginServingBlocks:(NSString *)transferID size:(uint64_t *)size;
// NONE for that file (0 not here, 1 not now).
- (void)sendNone:(NSString *)transferID reason:(SZFriendsAgainAnswer)reason;
// Requester by blocks (ADR 0018 § 4): set on a session that negotiated fast transfers, so copies go by blocks (4 WANT
// BLOCKS, resumed from the map beside the partial copy); otherwise by offset (1 WANT), as any helper serves.
@property(nonatomic) BOOL fast;
// Session frames for a copy by blocks (HAVE), sent in order after the AGAIN messages.
@property(nonatomic, copy, nullable) void (^sendFrame)(SZFriendsFrame *frame);
// The file copying by blocks now, whose HASHES and PARTs on this session are its own.
@property(nonatomic, readonly, nullable) NSString *copyingByBlocks;
// HASHES or a PART of the copy by blocks: NO when this exchange is not copying that file by blocks.
- (BOOL)receiveHashes:(NSData *)hashes index:(uint32_t)index forTransfer:(NSString *)transferID;
- (BOOL)receivePart:(NSData *)data offset:(uint64_t)offset forTransfer:(NSString *)transferID;
// Starts the next wanted copy when none runs (after a Get again, or once the session is live).
- (void)pump;
// A message from the peer. NO: it does not decode; end the session.
- (BOOL)receiveMessage:(NSData *)message;
// The file this side is copying, and the share of it here; nil and 0 when none.
@property(nonatomic, readonly, nullable) NSString *copyingTransferID;
@property(nonatomic, readonly) double copyingFraction;
// Cancel: stops the copy of this file now; what arrived stays for a later Get again.
- (void)abandon:(NSString *)transferID;
// The session ended: partial copies stay for the next one.
- (void)stop;
@end

NS_ASSUME_NONNULL_END
