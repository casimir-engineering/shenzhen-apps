// Friend and download links in the store (SZFriendsStoreLinks.h; schema v7).

#import "service/store/SZFriendsStoreLinks.h"

#import <CommonCrypto/CommonDigest.h>
#import <unistd.h>

#import "service/store/SZFriendsStoreInternal.h"

NS_ASSUME_NONNULL_BEGIN

const NSUInteger SZFriendsDownloadLinksMax = 50;
const NSTimeInterval SZFriendsOneTimeInviteLifetime = 30 * 86400;
const NSUInteger SZFriendsLinkThumbnailMaxBytes = 48000;
const NSUInteger SZFriendsInviteAcceptsPerDay = 20;
// What manual acceptance keeps free beside the file (SZFriendsTransfers.m), kept for a link's file too.
static const uint64_t SZFriendsLinkAcceptMargin = 16ULL << 20;

static NSString *const SZFriendsLinkColumns =
    @"link_id, secret, file_name, uniform_type, size, sha256, blake2b, snapshot_path, source_path, source_mtime_ns, "
    @"source_ctime_ns, source_inode, source_device, thumbnail_png, created_at, expires_at, downloads";
static NSString *const SZFriendsInviteColumns = @"token, one_time, created_at, expires_at, used_at, revoked_at";
static BOOL SZFriendsCountInviteAccept(SZFriendsStoreDB *db, NSData *token, NSDate *now, NSError **error);

const NSTimeInterval SZFriendsLinkTombstoneLifetime = 31 * 86400;
const NSUInteger SZFriendsLinkTombstonesMax = 500;
NSString *const SZFriendsLinkTombstoneRevoked = @"revoked";
NSString *const SZFriendsLinkTombstoneExpired = @"expired";
static NSString *const SZFriendsLinkTombstonesKey = @"link_tombstones";
// Each tombstone in the setting's blob: the hash (32), the reason (1: revoked, 2: expired), until (u64be seconds).
enum { SZFriendsLinkTombstoneBytes = 41 };

@implementation SZFriendsLinkTombstone
@end

NSData *SZFriendsLinkTombstoneHash(NSData *linkID) {
    NSMutableData *input = [[@"SZFriends link tombstone v1" dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [input appendData:linkID];
    NSMutableData *digest = [NSMutableData dataWithLength:CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(input.bytes, (CC_LONG)input.length, digest.mutableBytes);
    return digest;
}

static NSArray<SZFriendsLinkTombstone *> *SZFriendsTombstonesFromBlob(id blob, NSDate *now) {
    NSMutableArray *list = [NSMutableArray array];
    NSData *data = [blob isKindOfClass:[NSData class]] ? blob : nil;
    const uint8_t *bytes = data.bytes;
    for (NSUInteger at = 0; at + SZFriendsLinkTombstoneBytes <= data.length; at += SZFriendsLinkTombstoneBytes) {
        uint64_t seconds = 0;
        for (NSUInteger i = 0; i < 8; i++) seconds = (seconds << 8) | bytes[at + 33 + i];
        SZFriendsLinkTombstone *tombstone = [SZFriendsLinkTombstone new];
        tombstone.linkHash = [data subdataWithRange:NSMakeRange(at, 32)];
        tombstone.reason = bytes[at + 32] == 1 ? SZFriendsLinkTombstoneRevoked : SZFriendsLinkTombstoneExpired;
        tombstone.until = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)seconds];
        if ([tombstone.until compare:now] == NSOrderedDescending) [list addObject:tombstone];
    }
    return list;
}

// Adds tombstones for `links` inside the caller's transaction, dropping those past their time and, beyond the
// maximum, those ending soonest. `until` gives each one's end.
static BOOL SZFriendsAddLinkTombstones(SZFriendsStoreDB *db, NSArray<SZFriendsDownloadLinkRecord *> *links,
                                       NSString *reason, NSDate *now, NSDate * (^until)(SZFriendsDownloadLinkRecord *),
                                       NSError **error) {
    if (links.count == 0) return YES;
    id blob = [db scalar:@"SELECT value FROM settings WHERE key = ?" binds:@[ SZFriendsLinkTombstonesKey ] error:NULL];
    NSMutableArray<SZFriendsLinkTombstone *> *list = [SZFriendsTombstonesFromBlob(blob, now) mutableCopy];
    for (SZFriendsDownloadLinkRecord *link in links) {
        SZFriendsLinkTombstone *tombstone = [SZFriendsLinkTombstone new];
        tombstone.linkHash = SZFriendsLinkTombstoneHash(link.linkID);
        tombstone.reason = reason;
        tombstone.until = until(link);
        if ([tombstone.until compare:now] == NSOrderedDescending) [list addObject:tombstone];
    }
    [list sortUsingComparator:^NSComparisonResult(SZFriendsLinkTombstone *a, SZFriendsLinkTombstone *b) {
        return [b.until compare:a.until];
    }];
    NSMutableData *out = [NSMutableData data];
    for (NSUInteger i = 0; i < MIN(list.count, SZFriendsLinkTombstonesMax); i++) {
        SZFriendsLinkTombstone *tombstone = list[i];
        uint8_t record[SZFriendsLinkTombstoneBytes];
        memcpy(record, tombstone.linkHash.bytes, 32);
        record[32] = [tombstone.reason isEqual:SZFriendsLinkTombstoneRevoked] ? 1 : 2;
        uint64_t seconds = (uint64_t)MAX(0, floor(tombstone.until.timeIntervalSince1970));
        for (NSUInteger b = 0; b < 8; b++) record[33 + b] = (uint8_t)(seconds >> (56 - 8 * b));
        [out appendBytes:record length:sizeof record];
    }
    return [db run:@"INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = "
                   @"excluded.value"
             binds:@[ SZFriendsLinkTombstonesKey, out ]
               row:nil
             error:error];
}

@implementation SZFriendsDownloadLinkRecord
- (id)copyWithZone:(nullable NSZone *)zone {
    (void)zone;
    return SZFriendsCopyRecord(self);
}
@end

@implementation SZFriendsInviteRecord
- (id)copyWithZone:(nullable NSZone *)zone {
    (void)zone;
    return SZFriendsCopyRecord(self);
}
@end

static NSError *SZFriendsLinkError(SZFriendsStoreError code, NSString *why) {
    return SZFriendsStoreMakeError(code, why);
}

static NSArray<SZFriendsDownloadLinkRecord *> *SZFriendsLinkRows(SZFriendsStoreDB *db, NSString *tail,
                                                                 NSArray *binds) {
    NSMutableArray<SZFriendsDownloadLinkRecord *> *rows = [NSMutableArray array];
    NSString *sql = [NSString stringWithFormat:@"SELECT %@ FROM links %@", SZFriendsLinkColumns, tail];
    [db run:sql binds:binds row:^(sqlite3_stmt *statement) {
        SZFriendsDownloadLinkRecord *link = [[SZFriendsDownloadLinkRecord alloc] init];
        link.linkID = SZFriendsColumnBlob(statement, 0);
        link.secret = SZFriendsColumnBlob(statement, 1);
        link.fileName = SZFriendsColumnText(statement, 2) ?: @"";
        link.uniformType = SZFriendsColumnText(statement, 3);
        link.size = (uint64_t)SZFriendsColumnInt(statement, 4);
        link.sha256 = SZFriendsColumnBlob(statement, 5);
        link.blake2b = SZFriendsColumnBlob(statement, 6);
        link.snapshotPath = SZFriendsColumnText(statement, 7);
        link.sourcePath = SZFriendsColumnText(statement, 8);
        link.sourceModifiedNanoseconds = SZFriendsColumnInt(statement, 9);
        link.sourceChangedNanoseconds = SZFriendsColumnInt(statement, 10);
        link.sourceInode = (uint64_t)SZFriendsColumnInt(statement, 11);
        link.sourceDevice = SZFriendsColumnInt(statement, 12);
        link.thumbnailPNG = SZFriendsColumnBlob(statement, 13);
        link.createdAt = SZFriendsColumnDate(statement, 14) ?: [NSDate distantPast];
        link.expiresAt = SZFriendsColumnDate(statement, 15) ?: [NSDate distantPast];
        link.downloads = (NSUInteger)MAX(SZFriendsColumnInt(statement, 16), 0);
        [rows addObject:link];
    } error:NULL];
    return rows;
}

static NSArray<SZFriendsInviteRecord *> *SZFriendsInviteRows(SZFriendsStoreDB *db, NSString *tail, NSArray *binds) {
    NSMutableArray<SZFriendsInviteRecord *> *rows = [NSMutableArray array];
    NSString *sql = [NSString stringWithFormat:@"SELECT %@ FROM invites %@", SZFriendsInviteColumns, tail];
    [db run:sql binds:binds row:^(sqlite3_stmt *statement) {
        SZFriendsInviteRecord *invite = [[SZFriendsInviteRecord alloc] init];
        invite.token = SZFriendsColumnBlob(statement, 0);
        invite.oneTime = SZFriendsColumnInt(statement, 1) != 0;
        invite.createdAt = SZFriendsColumnDate(statement, 2) ?: [NSDate distantPast];
        invite.expiresAt = SZFriendsColumnDate(statement, 3);
        invite.usedAt = SZFriendsColumnDate(statement, 4);
        invite.revokedAt = SZFriendsColumnDate(statement, 5);
        [rows addObject:invite];
    } error:NULL];
    return rows;
}

static BOOL SZFriendsLinkRecordValid(SZFriendsDownloadLinkRecord *link) {
    BOOL oneSource = (link.snapshotPath.length > 0) != (link.sourcePath.length > 0);
    return link.linkID.length == 16 && link.secret.length == 32 && link.sha256.length == 32 &&
           link.blake2b.length == 32 && link.fileName.length > 0 && oneSource && link.size <= INT64_MAX &&
           link.createdAt != nil && link.expiresAt != nil &&
           link.thumbnailPNG.length <= SZFriendsLinkThumbnailMaxBytes &&
           (link.thumbnailPNG == nil || link.thumbnailPNG.length > 0);
}

static NSData *SZFriendsLinkRandom(NSUInteger length) {
    NSMutableData *data = [NSMutableData dataWithLength:length];
    arc4random_buf(data.mutableBytes, length);
    return data;
}

static SZFriendsInviteRecord *_Nullable SZFriendsInsertInvite(SZFriendsStoreDB *db, BOOL oneTime, NSDate *now,
                                                              NSError **error) {
    SZFriendsInviteRecord *invite = [[SZFriendsInviteRecord alloc] init];
    invite.token = SZFriendsLinkRandom(16);
    invite.oneTime = oneTime;
    invite.createdAt = now;
    invite.expiresAt = oneTime ? [now dateByAddingTimeInterval:SZFriendsOneTimeInviteLifetime] : nil;
    BOOL ok = [db run:@"INSERT INTO invites (token, one_time, created_at, expires_at) VALUES (?, ?, ?, ?)"
                binds:@[ invite.token, @(oneTime), now, SZFriendsSQL(invite.expiresAt) ]
                  row:nil
                error:error];
    return ok ? invite : nil;
}

@implementation SZFriendsStore (Links)

#pragma mark - Download links

- (BOOL)saveDownloadLink:(SZFriendsDownloadLinkRecord *)link error:(NSError **)error {
    if (!SZFriendsLinkRecordValid(link)) return SZFriendsFail(error, SZFriendsLinkError(SZFriendsStoreErrorInvalid,
                                                                                        @"malformed download link"));
    return [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        NSNumber *live = [db scalar:@"SELECT count(*) FROM links WHERE expires_at > ?" binds:@[ [NSDate date] ]
                              error:inner];
        if (!live) return NO;
        if (live.unsignedIntegerValue >= SZFriendsDownloadLinksMax) {
            return SZFriendsFail(inner, SZFriendsLinkError(SZFriendsStoreErrorConstraint, @"too many links"));
        }
        NSString *sql = [NSString stringWithFormat:@"INSERT INTO links (%@) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, "
                                                   @"?, ?, ?, ?, ?, ?)",
                                                   SZFriendsLinkColumns];
        return [db run:sql
                 binds:@[
                     link.linkID, link.secret, link.fileName, SZFriendsSQL(link.uniformType), @(link.size),
                     link.sha256, link.blake2b, SZFriendsSQL(link.snapshotPath), SZFriendsSQL(link.sourcePath),
                     @(link.sourceModifiedNanoseconds), @(link.sourceChangedNanoseconds), @(link.sourceInode),
                     @(link.sourceDevice), SZFriendsSQL(link.thumbnailPNG), link.createdAt, link.expiresAt,
                     @(link.downloads)
                 ]
                   row:nil
                 error:inner];
    } error:error];
}

- (nullable SZFriendsDownloadLinkRecord *)downloadLinkWithID:(NSData *)linkID {
    __block SZFriendsDownloadLinkRecord *link = nil;
    if (linkID.length != 16) return nil;
    [self performRead:^(SZFriendsStoreDB *_Nullable db) {
        if (db) link = SZFriendsLinkRows(db, @"WHERE link_id = ?", @[ linkID ]).firstObject;
    }];
    return link;
}

- (NSArray<SZFriendsDownloadLinkRecord *> *)downloadLinks {
    __block NSArray<SZFriendsDownloadLinkRecord *> *links = @[];
    [self performRead:^(SZFriendsStoreDB *_Nullable db) {
        if (db) links = SZFriendsLinkRows(db, @"ORDER BY created_at DESC, link_id", @[]);
    }];
    return links;
}

- (nullable SZFriendsDownloadLinkRecord *)removeDownloadLink:(NSData *)linkID error:(NSError **)error {
    __block SZFriendsDownloadLinkRecord *removed = nil;
    BOOL ok = [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        removed = linkID.length == 16 ? SZFriendsLinkRows(db, @"WHERE link_id = ?", @[ linkID ]).firstObject : nil;
        if (removed == nil) return SZFriendsFail(inner, SZFriendsLinkError(SZFriendsStoreErrorNotFound, @"no link"));
        NSDate *now = [NSDate date];
        return [db run:@"DELETE FROM links WHERE link_id = ?" binds:@[ linkID ] row:nil error:inner] &&
               SZFriendsAddLinkTombstones(db, @[ removed ], SZFriendsLinkTombstoneRevoked, now,
                                          ^NSDate *(SZFriendsDownloadLinkRecord *link) {
                                              (void)link;
                                              return [now dateByAddingTimeInterval:SZFriendsLinkTombstoneLifetime];
                                          }, inner);
    } error:error];
    return ok ? removed : nil;
}

- (nullable NSArray<SZFriendsDownloadLinkRecord *> *)removeDownloadLinksExpiredAtDate:(NSDate *)now
                                                                                error:(NSError **)error {
    __block NSArray<SZFriendsDownloadLinkRecord *> *removed = @[];
    BOOL ok = [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        removed = SZFriendsLinkRows(db, @"WHERE expires_at <= ?", @[ now ]);
        return removed.count == 0 ||
               ([db run:@"DELETE FROM links WHERE expires_at <= ?" binds:@[ now ] row:nil error:inner] &&
                SZFriendsAddLinkTombstones(db, removed, SZFriendsLinkTombstoneExpired, now,
                                           ^NSDate *(SZFriendsDownloadLinkRecord *link) {
                                               return [link.expiresAt
                                                   dateByAddingTimeInterval:SZFriendsLinkTombstoneLifetime];
                                           }, inner));
    } error:error];
    return ok ? removed : nil;
}

- (NSArray<SZFriendsLinkTombstone *> *)linkTombstonesAtDate:(NSDate *)now {
    __block NSArray<SZFriendsLinkTombstone *> *list = @[];
    [self performRead:^(SZFriendsStoreDB *db) {
        id blob = [db scalar:@"SELECT value FROM settings WHERE key = ?" binds:@[ SZFriendsLinkTombstonesKey ]
                       error:NULL];
        if (db) list = SZFriendsTombstonesFromBlob(blob, now);
    }];
    return list;
}

- (BOOL)countDownloadOfLink:(NSData *)linkID error:(NSError **)error {
    return [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        if (![db run:@"UPDATE links SET downloads = downloads + 1 WHERE link_id = ?" binds:@[ linkID ] row:nil
               error:inner]) {
            return NO;
        }
        return db.changes == 1 || SZFriendsFail(inner, SZFriendsLinkError(SZFriendsStoreErrorNotFound, @"no link"));
    } error:error];
}

#pragma mark - Invites

- (nullable SZFriendsInviteRecord *)standingInviteCreatingIfNeeded:(BOOL)create error:(NSError **)error {
    __block SZFriendsInviteRecord *invite = nil;
    BOOL ok = [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        invite = SZFriendsInviteRows(db, @"WHERE one_time = 0 AND revoked_at IS NULL ORDER BY created_at DESC", @[])
                     .firstObject;
        if (invite != nil || !create) return YES;
        invite = SZFriendsInsertInvite(db, NO, [NSDate date], inner);
        return invite != nil;
    } error:error];
    return ok ? invite : nil;
}

- (nullable SZFriendsInviteRecord *)resetStandingInviteAtDate:(NSDate *)now error:(NSError **)error {
    __block SZFriendsInviteRecord *invite = nil;
    BOOL ok = [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        if (![db run:@"UPDATE invites SET revoked_at = ? WHERE one_time = 0 AND revoked_at IS NULL" binds:@[ now ]
                 row:nil
               error:inner] ||
            ![db run:@"DELETE FROM settings WHERE key LIKE 'invite_accepts.%'" binds:nil row:nil error:inner]) {
            return NO;
        }
        invite = SZFriendsInsertInvite(db, NO, now, inner);
        return invite != nil;
    } error:error];
    return ok ? invite : nil;
}

- (nullable SZFriendsInviteRecord *)createOneTimeInviteAtDate:(NSDate *)now error:(NSError **)error {
    __block SZFriendsInviteRecord *invite = nil;
    BOOL ok = [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        invite = SZFriendsInsertInvite(db, YES, now, inner);
        return invite != nil;
    } error:error];
    return ok ? invite : nil;
}

- (NSArray<SZFriendsInviteRecord *> *)liveInvitesAtDate:(NSDate *)now {
    __block NSArray<SZFriendsInviteRecord *> *invites = @[];
    [self performRead:^(SZFriendsStoreDB *_Nullable db) {
        if (db) {
            invites = SZFriendsInviteRows(db, @"WHERE revoked_at IS NULL AND used_at IS NULL AND (expires_at IS NULL "
                                              @"OR expires_at > ?) ORDER BY created_at",
                                          @[ now ]);
        }
    }];
    return invites;
}

- (BOOL)useInvite:(NSData *)token atDate:(NSDate *)now error:(NSError **)error {
    return [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        SZFriendsInviteRecord *invite =
            SZFriendsInviteRows(db, @"WHERE token = ? AND revoked_at IS NULL AND used_at IS NULL AND (expires_at IS "
                                    @"NULL OR expires_at > ?)",
                                @[ token, now ])
                .firstObject;
        if (invite == nil) return SZFriendsFail(inner, SZFriendsLinkError(SZFriendsStoreErrorStale, @"not live"));
        if (!invite.oneTime) return SZFriendsCountInviteAccept(db, token, now, inner);
        return [db run:@"UPDATE invites SET used_at = ? WHERE token = ?" binds:@[ now, token ] row:nil error:inner];
    } error:error];
}

// The standing invite's acceptances over the last 24 hours, in the settings table (key "invite_accepts.<token hex>",
// the times as Unix seconds separated by spaces): one more unless SZFriendsInviteAcceptsPerDay already happened.
static BOOL SZFriendsCountInviteAccept(SZFriendsStoreDB *db, NSData *token, NSDate *now, NSError **error) {
    NSMutableString *key = [NSMutableString stringWithString:@"invite_accepts."];
    const uint8_t *bytes = token.bytes;
    for (NSUInteger i = 0; i < token.length; i++) [key appendFormat:@"%02x", bytes[i]];
    id stored = [db scalar:@"SELECT value FROM settings WHERE key = ?" binds:@[ key ] error:NULL];
    NSMutableArray<NSString *> *recent = [NSMutableArray array];
    // Times are kept to the millisecond, so `now` is compared as it will be kept: an acceptance written rounded up
    // past the exact `now` used to fall outside the window it was just counted in, and a second one slipped through.
    double stamp = round(now.timeIntervalSince1970 * 1000) / 1000;
    NSTimeInterval since = stamp - 86400;
    for (NSString *time in [stored isKindOfClass:NSString.class] ? [stored componentsSeparatedByString:@" "] : @[]) {
        if (time.doubleValue > since && time.doubleValue <= stamp) [recent addObject:time];
    }
    if (recent.count >= SZFriendsInviteAcceptsPerDay) {
        return SZFriendsFail(error, SZFriendsLinkError(SZFriendsStoreErrorConstraint, @"invite's daily limit"));
    }
    [recent addObject:[NSString stringWithFormat:@"%.3f", stamp]];
    return [db run:@"INSERT INTO settings(key, value) VALUES (?, ?) "
                   @"ON CONFLICT(key) DO UPDATE SET value = excluded.value"
             binds:@[ key, [recent componentsJoinedByString:@" "] ]
               row:nil
             error:error];
}

#pragma mark - Our requests, and link contacts

- (BOOL)setInviteToken:(NSData *)token forIDRequestConversation:(NSString *)conversationID error:(NSError **)error {
    if (token.length != 16) return SZFriendsFail(error, SZFriendsLinkError(SZFriendsStoreErrorInvalid, @"token"));
    return [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        return [db run:@"INSERT INTO link_requests (conversation_id, invite_token) VALUES (?, ?) "
                       @"ON CONFLICT(conversation_id) DO UPDATE SET invite_token = excluded.invite_token"
                 binds:@[ conversationID, token ]
                   row:nil
                 error:inner];
    } error:error];
}

- (nullable NSData *)inviteTokenForIDRequestConversation:(NSString *)conversationID {
    __block NSData *token = nil;
    [self performRead:^(SZFriendsStoreDB *_Nullable db) {
        id value = [db scalar:@"SELECT invite_token FROM link_requests WHERE conversation_id = ?"
                        binds:@[ conversationID ]
                        error:NULL];
        token = [value isKindOfClass:[NSData class]] ? value : nil;
    }];
    return token;
}

- (BOOL)markLinkContact:(NSString *)conversationID error:(NSError **)error {
    return [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        return [db run:@"INSERT OR IGNORE INTO link_contacts (conversation_id) VALUES (?)" binds:@[ conversationID ]
                   row:nil
                 error:inner];
    } error:error];
}

- (NSSet<NSString *> *)linkContactConversationIDs {
    NSMutableSet<NSString *> *ids = [NSMutableSet set];
    [self performRead:^(SZFriendsStoreDB *_Nullable db) {
        [db run:@"SELECT c.conversation_id FROM link_contacts c JOIN friends f USING (conversation_id) "
                @"WHERE f.relation <> ?"
            binds:@[ @(SZFriendsRelationFriend) ]
              row:^(sqlite3_stmt *statement) {
                  NSString *conversationID = SZFriendsColumnText(statement, 0);
                  if (conversationID) [ids addObject:conversationID];
              }
            error:NULL];
    }];
    return ids;
}

@end

@implementation SZFriendsTransfers (Links)

- (nullable SZFriendsTransferRecord *)recordLinkTransferWithID:(NSString *)transferID
                                                conversationID:(NSString *)conversationID
                                                      fileName:(NSString *)proposedName
                                                   uniformType:(nullable NSString *)uniformType
                                                          size:(uint64_t)size
                                                 contentDigest:(NSData *)contentDigest
                                                         error:(NSError **)error {
    uint64_t freeBytes = [self freeBytesForReceiving];
    NSString *partialDirectory = [self.receivedDirectory stringByAppendingPathComponent:@".partial"];
    __block SZFriendsTransferRecord *result = nil;
    __block NSString *partial = nil;
    BOOL ok = [self.store performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        NSString *reason = nil;
        if (!SZFriendsStoreIsValidIdentifier(transferID) || uniformType.length > 255 ||
            !SZFriendsValidateOffer(proposedName, size, contentDigest, 0, &reason) ||
            SZFriendsTransferRows(db, @"WHERE transfer_id = ? COLLATE NOCASE", @[ transferID ]).count > 0) {
            return SZFriendsFail(inner, SZFriendsLinkError(SZFriendsStoreErrorInvalid, reason ?: @"bad transfer"));
        }
        SZFriendsPersonRecord *person =
            SZFriendsStorePeople(db, @"WHERE conversation_id = ?", @[ conversationID ]).firstObject;
        if (person == nil || person.relation == SZFriendsRelationBlocked) {
            return SZFriendsFail(inner, SZFriendsLinkError(SZFriendsStoreErrorInvalid, @"no such sender"));
        }
        if (size > freeBytes || freeBytes - size < SZFriendsLinkAcceptMargin) {
            return SZFriendsFail(inner, SZFriendsLinkError(SZFriendsStoreErrorDiskFull, @"not enough space"));
        }
        partial = SZFriendsEnsurePrivateDirectory(partialDirectory, inner)
                      ? SZFriendsCreateStagingFile(partialDirectory, inner)
                      : nil;
        if (partial == nil) return NO;
        SZFriendsTransferRecord *record = [[SZFriendsTransferRecord alloc] init];
        record.transferID = transferID;
        record.conversationID = conversationID;
        record.state = SZFriendsTransferStateWaitingForYou;
        record.fileName = SZFriendsSanitizedFileName(proposedName);
        record.uniformType = uniformType;
        record.size = size;
        record.contentDigest = contentDigest;
        record.createdAt = [NSDate date];
        if (!SZFriendsTransferRowInsert(db, record, nil, inner)) return NO;
        SZFriendsItemRecord *item = [[SZFriendsItemRecord alloc] init];
        item.itemID = transferID;
        item.conversationID = conversationID;
        item.kind = SZFriendsItemKindTransfer;
        item.direction = SZFriendsDirectionIncoming;
        item.transferID = transferID;
        item.text = record.fileName;
        item.sentAt = record.createdAt;
        item.receivedAt = record.createdAt;
        if (!SZFriendsStoreInsertItem(db, item, NULL, inner)) return NO;
        if (!SZFriendsTransferRowApplyEvent(db, transferID, SZFriendsTransferEventAccepted, nil, inner)) return NO;
        NSDictionary *values = @{@"partial_path" : partial, @"verified_bytes" : @0, @"accepted_automatically" : @0,
                                 @"received_via" : @(SZFriendsReceivedSourceLink)};
        if (!SZFriendsTransferRowUpdate(db, transferID, values, inner)) return NO;
        result = SZFriendsTransferRowLoad(db, transferID);
        return result != nil;
    } error:error];
    if (!ok && partial != nil) unlink(partial.fileSystemRepresentation); // the row that named it rolled back
    return ok ? result : nil;
}

@end

NS_ASSUME_NONNULL_END
