// Value records the store hands out, identifiers, and the store-error to protocol-code mapping.

#import <objc/runtime.h>
#import <stdlib.h>

#import "service/store/SZFriendsStoreInternal.h"

NS_ASSUME_NONNULL_BEGIN

NSString *SZFriendsNewIdentifier(void) {
    uint8_t bytes[16];
    // arc4random_buf is the kernel CSPRNG on macOS and needs no initialisation, so ids can be drawn before
    // libsodium is set up and from any thread.
    arc4random_buf(bytes, sizeof bytes);
    NSMutableString *hex = [NSMutableString stringWithCapacity:32];
    for (size_t i = 0; i < sizeof bytes; i++) [hex appendFormat:@"%02x", bytes[i]];
    return hex;
}

NSString *SZFriendsStoreProtocolErrorCode(NSError *_Nullable error) {
    if (![error.domain isEqualToString:SZFriendsStoreErrorDomain]) return @"internal";
    switch ((SZFriendsStoreError)error.code) {
        case SZFriendsStoreErrorDiskFull: return @"disk_full";
        case SZFriendsStoreErrorFileMissing: return @"file_missing";
        case SZFriendsStoreErrorFolderNotSupported: return @"folder_not_supported";
        case SZFriendsStoreErrorSourceChanged: return @"source_changed";
        case SZFriendsStoreErrorStale: return @"stale";
        case SZFriendsStoreErrorNotFound: return @"not_found";
        case SZFriendsStoreErrorInvalid: return @"invalid_field";
        default: return @"internal";
    }
}

// Every read-write property of the record's class chain below NSObject, copied through KVC (which boxes BOOL,
// NSInteger, uint64_t and double), so adding a property to a record needs no copy code.
id SZFriendsCopyRecord(id record) {
    id copy = [[[record class] alloc] init];
    for (Class cls = [record class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        objc_property_t *properties = class_copyPropertyList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            char *readonly = property_copyAttributeValue(properties[i], "R");
            if (readonly) {
                free(readonly);
                continue;
            }
            NSString *name = @(property_getName(properties[i]));
            [copy setValue:[record valueForKey:name] forKey:name];
        }
        free(properties);
    }
    return copy;
}

@implementation SZFriendsPersonRecord
- (instancetype)init {
    if ((self = [super init])) {
        _conversationID = @"";
        _picture = [SZFriendsPicture placeholder];
        _relation = SZFriendsRelationIncomingRequest;
        _lastInteractionAt = [NSDate date];
    }
    return self;
}
- (id)copyWithZone:(nullable NSZone *)zone {
    (void)zone;
    return SZFriendsCopyRecord(self);
}
@end

@implementation SZFriendsIDRequestRecord
- (instancetype)init {
    if ((self = [super init])) {
        _conversationID = @"";
        _targetFriendsID = @"";
        _requestToken = [NSData data];
        _callbackSecret = [NSData data];
        _createdAt = [NSDate date];
        _expiresAt = [_createdAt dateByAddingTimeInterval:SZFriendsIDRequestLifetime];
    }
    return self;
}
- (id)copyWithZone:(nullable NSZone *)zone {
    (void)zone;
    return SZFriendsCopyRecord(self);
}
@end

@implementation SZFriendsItemRecord
- (instancetype)init {
    if ((self = [super init])) {
        _itemID = @"";
        _conversationID = @"";
        _sentAt = [NSDate date];
        _receivedAt = _sentAt;
        _outboxState = -1;
    }
    return self;
}
- (id)copyWithZone:(nullable NSZone *)zone {
    (void)zone;
    return SZFriendsCopyRecord(self);
}
@end

@implementation SZFriendsSearchHit
- (instancetype)initWithConversationID:(NSString *)conversationID
                                itemID:(NSString *)itemID
                                  kind:(SZFriendsItemKind)kind
                                sentAt:(NSDate *)sentAt
                             direction:(SZFriendsDirection)direction
                                  text:(NSString *)text
                           matchRanges:(NSArray<NSValue *> *)matchRanges {
    if ((self = [super init])) {
        _conversationID = [conversationID copy];
        _itemID = [itemID copy];
        _kind = kind;
        _sentAt = [sentAt copy];
        _direction = direction;
        _text = [text copy];
        _matchRanges = [matchRanges copy];
    }
    return self;
}
@end

@implementation SZFriendsOutboxEntry
- (instancetype)init {
    if ((self = [super init])) {
        _entryID = @"";
        _conversationID = @"";
        _createdAt = [NSDate date];
    }
    return self;
}
- (id)copyWithZone:(nullable NSZone *)zone {
    (void)zone;
    return SZFriendsCopyRecord(self);
}
@end

@implementation SZFriendsRevision
- (instancetype)init {
    if ((self = [super init])) {
        _source = @"";
        _documentID = @"";
        _revisionID = @"";
    }
    return self;
}
- (id)copyWithZone:(nullable NSZone *)zone {
    (void)zone;
    return SZFriendsCopyRecord(self);
}
@end

@implementation SZFriendsTransferRecord
- (instancetype)init {
    if ((self = [super init])) {
        _transferID = @"";
        _conversationID = @"";
        _fileName = @"";
        _contentDigest = [NSData data];
    }
    return self;
}
- (id)copyWithZone:(nullable NSZone *)zone {
    (void)zone;
    return SZFriendsCopyRecord(self);
}
@end

NS_ASSUME_NONNULL_END
