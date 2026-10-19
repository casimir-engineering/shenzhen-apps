// Friend requests nobody answers lapse (wave-3 security re-check, key policy). While a request waits, the requester's
// key is one the helper knows; that let someone who sent one request during our five visible minutes, then waited,
// follow our hidden device for as long as the request sat unanswered. The helper narrows what such a key may do to
// the first hours (pendingRequestSince); this ends the wait itself.

#import <unistd.h>

#import "service/store/SZFriendsStoreInternal.h"

NS_ASSUME_NONNULL_BEGIN

const NSTimeInterval SZFriendsIncomingRequestLifetime = 14 * 24 * 60 * 60;
const NSTimeInterval SZFriendsOutgoingRequestLifetime = 7 * 24 * 60 * 60;

// An unexpired Add by ID request of ours that admitted the key ?1 (bound twice: ?1 the key, ?2 now).
static NSString *const SZFriendsAnswerOpen =
    @"EXISTS (SELECT 1 FROM id_request_answers a JOIN id_requests r ON r.request_token = a.request_token "
    @"WHERE a.identity_pk = ?1 AND r.expires_at > ?2)";

// Requests we sent that nobody can answer any more (SZFriendsStore.h, -expireOutgoingRequestsAtDate:). ?1 now, ?2 the
// nearby cutoff, ?3 OutgoingRequest.
static NSString *const SZFriendsOutgoingLapsedWhere =
    @"WHERE relation = ?3 AND ((request_found_nearby = 1 AND "
    @"coalesce(request_since, request_at, last_interaction_at) <= ?2) OR (request_found_nearby = 0 AND "
    @"NOT EXISTS (SELECT 1 FROM id_requests r WHERE r.conversation_id = friends.conversation_id AND "
    @"r.expires_at > ?1) AND (identity_pk IS NULL OR NOT EXISTS (SELECT 1 FROM id_request_answers a JOIN "
    @"id_requests r ON r.request_token = a.request_token WHERE a.identity_pk = friends.identity_pk AND "
    @"r.expires_at > ?1))))";

// The same moment the reads report as pendingRequestSince (SZFriendsStorePeople.m).
static NSString *const SZFriendsLapsedWhere =
    @"WHERE relation = ? AND coalesce(request_since, request_at, last_interaction_at) <= ?";

// Pictures of deleted rows that nothing else shows. Only files inside pictures/ are touched: a path read from a row
// is never trusted to point elsewhere. Content-addressed pictures may be shared, hence the reference check.
static void SZFriendsRemoveUnusedPictures(SZFriendsStoreDB *db, NSString *stateDirectory, NSArray<NSString *> *paths) {
    NSString *pictures = [[stateDirectory stringByAppendingPathComponent:@"pictures"].stringByStandardizingPath
        stringByAppendingString:@"/"];
    for (NSString *path in paths) {
        NSString *standard = path.stringByStandardizingPath;
        if (![standard hasPrefix:pictures] || [standard.lastPathComponent hasPrefix:@"."]) continue;
        NSNumber *uses = [db scalar:@"SELECT (SELECT count(*) FROM friends WHERE picture_path = ?1) + "
                                    @"(SELECT count(*) FROM profile WHERE picture_path = ?1)"
                              binds:@[ path ]
                              error:NULL];
        if (uses && uses.integerValue == 0) unlink(standard.fileSystemRepresentation);
    }
}

@implementation SZFriendsStore (Requests)

- (nullable NSArray<SZFriendsPersonRecord *> *)expireIncomingRequestsAtDate:(NSDate *)now error:(NSError **)error {
    NSDate *cutoff = [now dateByAddingTimeInterval:-SZFriendsIncomingRequestLifetime];
    __block NSArray<SZFriendsPersonRecord *> *lapsed = @[];
    NSMutableArray<NSString *> *pictures = [NSMutableArray array];
    BOOL ok = [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        lapsed = SZFriendsStorePeople(db, SZFriendsLapsedWhere, @[ @(SZFriendsRelationIncomingRequest), cutoff ]);
        for (SZFriendsPersonRecord *person in lapsed) {
            NSNumber *held = [db scalar:@"SELECT (SELECT count(*) FROM messages WHERE conversation_id = ?1) + "
                                        @"(SELECT count(*) FROM transfers WHERE conversation_id = ?1) + "
                                        @"(SELECT count(*) FROM outbox WHERE conversation_id = ?1)"
                                  binds:@[ person.conversationID ]
                                  error:inner];
            if (!held) return NO;
            if (held.integerValue == 0) {
                // A stranger's request and nothing else: nothing of theirs is worth keeping, their key included.
                if (![db run:@"DELETE FROM friends WHERE conversation_id = ?" binds:@[ person.conversationID ] row:nil
                       error:inner]) {
                    return NO;
                }
                if (person.picture.imagePath) [pictures addObject:person.picture.imagePath];
                continue;
            }
            // Someone with history here, a former friend asking again: back to where they were before they asked.
            if (![db run:@"UPDATE friends SET relation = ?, request_since = NULL, callback_token = NULL, "
                         @"callback_secret = NULL, auto_accept = 0 WHERE conversation_id = ?"
                   binds:@[ @(SZFriendsRelationRemoved), person.conversationID ]
                     row:nil
                   error:inner]) {
                return NO;
            }
        }
        return YES;
    } error:error];
    if (!ok) return nil;
    if (pictures.count) {
        [self performOnWriter:^(SZFriendsStoreDB *_Nullable db) {
            if (db) SZFriendsRemoveUnusedPictures(db, self.stateDirectory, pictures);
        }];
    }
    return lapsed;
}

- (nullable NSArray<SZFriendsPersonRecord *> *)expireOutgoingRequestsAtDate:(NSDate *)now error:(NSError **)error {
    NSDate *cutoff = [now dateByAddingTimeInterval:-SZFriendsOutgoingRequestLifetime];
    __block NSArray<SZFriendsPersonRecord *> *lapsed = @[];
    NSMutableArray<NSString *> *pictures = [NSMutableArray array];
    BOOL ok = [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        lapsed = SZFriendsStorePeople(db, SZFriendsOutgoingLapsedWhere,
                                      @[ now, cutoff, @(SZFriendsRelationOutgoingRequest) ]);
        for (SZFriendsPersonRecord *person in lapsed) {
            NSString *conversationID = person.conversationID;
            // What we queued for them (the request itself) goes with the request; history is the person's own.
            NSNumber *held = [db scalar:@"SELECT (SELECT count(*) FROM messages WHERE conversation_id = ?1) + "
                                        @"(SELECT count(*) FROM transfers WHERE conversation_id = ?1)"
                                  binds:@[ conversationID ]
                                  error:inner];
            if (!held) return NO;
            NSArray *only = @[ conversationID ];
            NSString *removed = @"UPDATE friends SET relation = ?, request_since = NULL, callback_token = NULL, "
                                @"callback_secret = NULL, auto_accept = 0 WHERE conversation_id = ?";
            NSArray<NSArray *> *statements =
                held.integerValue == 0
                    ? @[ @[ @"DELETE FROM friends WHERE conversation_id = ?", only ] ]
                    : @[ @[ @"DELETE FROM id_requests WHERE conversation_id = ?", only ],
                         @[ @"DELETE FROM outbox WHERE conversation_id = ? AND item_id IS NULL", only ],
                         @[ removed, @[ @(SZFriendsRelationRemoved), conversationID ] ] ];
            for (NSArray *statement in statements) {
                if (![db run:statement[0] binds:statement[1] row:nil error:inner]) return NO;
            }
            if (held.integerValue == 0 && person.picture.imagePath) [pictures addObject:person.picture.imagePath];
        }
        return YES;
    } error:error];
    if (!ok) return nil;
    if (pictures.count) {
        [self performOnWriter:^(SZFriendsStoreDB *_Nullable db) {
            if (db) SZFriendsRemoveUnusedPictures(db, self.stateDirectory, pictures);
        }];
    }
    return lapsed;
}

- (BOOL)identityKeyAnswersUnexpiredIDRequest:(NSData *)identityKey atDate:(NSDate *)now {
    if (identityKey.length != 32) return NO;
    __block BOOL open = NO;
    [self performRead:^(SZFriendsStoreDB *_Nullable db) {
        open = [[db scalar:[@"SELECT " stringByAppendingString:SZFriendsAnswerOpen] binds:@[ identityKey, now ]
                     error:NULL] boolValue];
    }];
    return open;
}

@end

NS_ASSUME_NONNULL_END
