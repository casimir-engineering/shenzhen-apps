// Shenzhen Friends links in the store (schema v7; portable/docs/plans/friends-links.md; PROTOCOL.md § Links).
//
// Helper-only. What persists of friend links and download links:
//   - for 31 days after a download link is revoked or expires, its tombstone: a hash of its id and why it ended,
//     never the id or secret, so the host can tell whoever opens it (settings key link_tombstones; no schema change);
//   - each download link this person made: its id and secret, what it serves and how the file is held (an APFS clone
//     in <state dir>/links/, or the original's size, dates, inode and hashes, served only while unchanged), its expiry
//     and how many downloads finished. A row lives until the link expires or is revoked; the caller removes the
//     clone it names (-removeDownloadLink:..., -removeDownloadLinksExpiredAtDate:...);
//   - the invite tokens behind this person's friend links: one standing token until Reset, and one-time tokens that
//     work once within 30 days. A request presenting a live one is accepted at once (the helper's nearby service);
//   - the invite one of our own Add by ID requests presents, kept with the request and gone with it;
//   - the people in the list only because they sent this person a file through a link ("link contacts"), until they
//     become friends.

#import <Foundation/Foundation.h>

#import "service/store/SZFriendsStore.h"
#import "service/store/SZFriendsTransfers.h"

NS_ASSUME_NONNULL_BEGIN

extern const NSUInteger SZFriendsDownloadLinksMax;          // 50 live download links: the host's limit per person
extern const NSTimeInterval SZFriendsOneTimeInviteLifetime; // 30 days
extern const NSUInteger SZFriendsLinkThumbnailMaxBytes;     // 48,000 bytes of PNG
// Requests the standing friend link accepts at once in any 24 hours; past it they wait for the person, so a link that
// leaks cannot make friends of strangers faster than this.
extern const NSUInteger SZFriendsInviteAcceptsPerDay;       // 20

@interface SZFriendsDownloadLinkRecord : NSObject <NSCopying>
@property(nonatomic, copy) NSData *linkID; // 16 random bytes: what the host and the page see
@property(nonatomic, copy) NSData *secret; // 32 random bytes: only in the link, never sent anywhere
@property(nonatomic, copy) NSString *fileName;
@property(nonatomic, copy, nullable) NSString *uniformType;
@property(nonatomic) uint64_t size;
@property(nonatomic, copy) NSData *sha256;  // what the page checks
@property(nonatomic, copy) NSData *blake2b; // what an app's received-file check uses (ADR 0001's digest)
// Exactly one of these: the clone the link serves, or the original it serves while it is unchanged.
@property(nonatomic, copy, nullable) NSString *snapshotPath;
@property(nonatomic, copy, nullable) NSString *sourcePath;
@property(nonatomic) int64_t sourceModifiedNanoseconds; // st_mtimespec
@property(nonatomic) int64_t sourceChangedNanoseconds;  // st_ctimespec
@property(nonatomic) uint64_t sourceInode;
@property(nonatomic) int64_t sourceDevice;
@property(nonatomic, copy, nullable) NSData *thumbnailPNG;
@property(nonatomic, copy) NSDate *createdAt;
@property(nonatomic, copy) NSDate *expiresAt;
@property(nonatomic) NSUInteger downloads;
@end

// What is left of a download link once it ended, for SZFriendsLinkTombstoneLifetime: what the helper tells its host
// on every connection (HOST-PROTOCOL-ONLINE.md § Download links, link_tombstones).
extern const NSTimeInterval SZFriendsLinkTombstoneLifetime; // 31 days
extern const NSUInteger SZFriendsLinkTombstonesMax;         // 500: those ending soonest go first
extern NSString *const SZFriendsLinkTombstoneRevoked;       // "revoked"
extern NSString *const SZFriendsLinkTombstoneExpired;       // "expired"
// SHA-256("SZFriends link tombstone v1" || link id).
NSData *SZFriendsLinkTombstoneHash(NSData *linkID);

@interface SZFriendsLinkTombstone : NSObject
@property(nonatomic, copy) NSData *linkHash; // SZFriendsLinkTombstoneHash of the link's id
@property(nonatomic, copy) NSString *reason; // revoked or expired
@property(nonatomic, copy) NSDate *until;
@end

@interface SZFriendsInviteRecord : NSObject <NSCopying>
@property(nonatomic, copy) NSData *token; // 16 random bytes, in the friend link
@property(nonatomic) BOOL oneTime;
@property(nonatomic, copy) NSDate *createdAt;
@property(nonatomic, copy, nullable) NSDate *expiresAt; // nil: until Reset (the standing link)
@property(nonatomic, copy, nullable) NSDate *usedAt;    // a one-time token, once used
@property(nonatomic, copy, nullable) NSDate *revokedAt; // the standing token, once Reset
@end

@interface SZFriendsStore (Links)
// Inserts a new link. Constraint when SZFriendsDownloadLinksMax unexpired links exist already; Invalid for a record
// whose lengths, paths or dates are wrong.
- (BOOL)saveDownloadLink:(SZFriendsDownloadLinkRecord *)link error:(NSError **)error;
- (nullable SZFriendsDownloadLinkRecord *)downloadLinkWithID:(NSData *)linkID;
// Every link held, expired or not, newest first.
- (NSArray<SZFriendsDownloadLinkRecord *> *)downloadLinks;
// Revoke: the row goes, leaving a "revoked" tombstone until 31 days from now, and is returned so the caller can
// remove its clone and tell the host. NotFound when absent.
- (nullable SZFriendsDownloadLinkRecord *)removeDownloadLink:(NSData *)linkID error:(NSError **)error;
// Expiry: every row whose expiry is not after `now` goes, each leaving an "expired" tombstone until 31 days after
// its expiry, returned for the same clean-up.
- (nullable NSArray<SZFriendsDownloadLinkRecord *> *)removeDownloadLinksExpiredAtDate:(NSDate *)now
                                                                                error:(NSError **)error;
// Tombstones still in their 31 days at `now`.
- (NSArray<SZFriendsLinkTombstone *> *)linkTombstonesAtDate:(NSDate *)now;
// One download finished and its recipient confirmed the file's SHA-256.
- (BOOL)countDownloadOfLink:(NSData *)linkID error:(NSError **)error;

// The standing invite, made when there is none (or, with create NO, nil then).
- (nullable SZFriendsInviteRecord *)standingInviteCreatingIfNeeded:(BOOL)create error:(NSError **)error;
// Reset: the standing invite is revoked and a new one made, in one transaction.
- (nullable SZFriendsInviteRecord *)resetStandingInviteAtDate:(NSDate *)now error:(NSError **)error;
- (nullable SZFriendsInviteRecord *)createOneTimeInviteAtDate:(NSDate *)now error:(NSError **)error;
// Invites a request may present now: not revoked, not used, not expired.
- (NSArray<SZFriendsInviteRecord *> *)liveInvitesAtDate:(NSDate *)now;
// A request presented this invite and is accepted through it: a one-time invite is used up (Stale when it no longer
// is live); a standing one stays live and counts the acceptance, refusing (Constraint, nothing counted) once
// SZFriendsInviteAcceptsPerDay happened in the 24 hours before `now`. Reset starts the new link's count afresh.
- (BOOL)useInvite:(NSData *)token atDate:(NSDate *)now error:(NSError **)error;

// The invite our own Add by ID request `conversationID` presents (its id_requests row must exist).
- (BOOL)setInviteToken:(NSData *)token forIDRequestConversation:(NSString *)conversationID error:(NSError **)error;
- (nullable NSData *)inviteTokenForIDRequestConversation:(NSString *)conversationID;

// People in the list only through a link they used to send a file: marked when their row is made for it, forgotten
// with the row, and no longer one once they are friends.
- (BOOL)markLinkContact:(NSString *)conversationID error:(NSError **)error;
- (NSSet<NSString *> *)linkContactConversationIDs;
@end

@interface SZFriendsTransfers (Links)
// A file arriving through a download link this person chose to receive: an incoming transfer already accepted
// (Receiving, with its staging file) and its history item, in the conversation of the person who sent it, whatever
// their relation except Blocked (Invalid). The chunks and the end then go through -appendChunk:... and
// -finishTransfer:..., which check the digest, publish into received/ and set the quarantine attribute as for any
// transfer. DiskFull when the file does not fit with the margin manual acceptance keeps.
- (nullable SZFriendsTransferRecord *)recordLinkTransferWithID:(NSString *)transferID
                                                conversationID:(NSString *)conversationID
                                                      fileName:(NSString *)proposedName
                                                   uniformType:(nullable NSString *)uniformType
                                                          size:(uint64_t)size
                                                 contentDigest:(NSData *)contentDigest
                                                         error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
