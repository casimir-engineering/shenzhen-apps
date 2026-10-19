// Bluetooth constants, the permission mapping and the presence characteristic's payload (pure).

#import "service/discovery/SZFriendsBluetoothRadio.h"

NSString *const SZFriendsBluetoothServiceUUID = @"22FB96F7-C35A-45B5-9673-1CAC64EC8E75";
NSString *const SZFriendsBluetoothPublicUUID = @"C8B26601-A773-4E6D-BC10-BA6F596D92C1";
NSString *const SZFriendsBluetoothPresenceCharacteristicUUID = @"9F2BC83C-9A97-49C4-9F30-19D368A135BA";
NSString *const SZFriendsBluetoothPublicCharacteristicUUID = @"E66577A2-9C37-4D7B-876E-03127666B7DA";

static const uint8_t kPresenceVersion = 1;
static const NSUInteger kFixedLength = 15;

SZFriendsPermission SZFriendsPermissionFromBluetoothAuthorization(CBManagerAuthorization authorization) {
    switch (authorization) {
    case CBManagerAuthorizationNotDetermined:
        return SZFriendsPermissionNotDetermined;
    case CBManagerAuthorizationAllowedAlways:
        return SZFriendsPermissionAllowed;
    case CBManagerAuthorizationRestricted:
    case CBManagerAuthorizationDenied:
        return SZFriendsPermissionDenied;
    }
    return SZFriendsPermissionUnknown;
}

@implementation SZFriendsBluetoothPresence

- (instancetype)initWithPresenceTag:(NSData *)presenceTag
                       callbackTags:(NSArray<NSData *> *)callbackTags
                          hiddenPSM:(uint16_t)hiddenPSM
                          publicPSM:(uint16_t)publicPSM {
    if ((self = [super init])) {
        _presenceTag = presenceTag.length == SZFriendsPresenceTagLength ? [presenceTag copy] : nil;
        NSMutableArray<NSData *> *tags = [NSMutableArray array];
        for (NSData *tag in callbackTags) {
            if (tag.length == SZFriendsPresenceTagLength && tags.count < SZFriendsCallbackTagsMax) [tags addObject:tag];
        }
        _callbackTags = tags;
        _hiddenPSM = hiddenPSM;
        _publicPSM = publicPSM;
    }
    return self;
}

+ (instancetype)presenceFromValue:(NSData *)value {
    const uint8_t *bytes = value.bytes;
    if (value.length < kFixedLength || bytes[0] != kPresenceVersion) return nil;
    NSUInteger count = bytes[14];
    NSUInteger needed = kFixedLength + count * SZFriendsPresenceTagLength;
    if (count > SZFriendsCallbackTagsMax || value.length < needed) return nil;
    NSData *tag = (bytes[1] & 1) ? [NSData dataWithBytes:bytes + 2 length:SZFriendsPresenceTagLength] : nil;
    NSMutableArray<NSData *> *callbacks = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) {
        [callbacks addObject:[NSData dataWithBytes:bytes + kFixedLength + i * SZFriendsPresenceTagLength
                                            length:SZFriendsPresenceTagLength]];
    }
    return [[self alloc] initWithPresenceTag:tag
                                callbackTags:callbacks
                                   hiddenPSM:(uint16_t)(bytes[10] << 8 | bytes[11])
                                   publicPSM:(uint16_t)(bytes[12] << 8 | bytes[13])];
}

- (NSData *)value {
    NSMutableData *value = [NSMutableData dataWithLength:kFixedLength];
    uint8_t *bytes = value.mutableBytes;
    bytes[0] = kPresenceVersion;
    if (self.presenceTag) {
        bytes[1] = 1;
        memcpy(bytes + 2, self.presenceTag.bytes, SZFriendsPresenceTagLength);
    }
    bytes[10] = (uint8_t)(self.hiddenPSM >> 8);
    bytes[11] = (uint8_t)self.hiddenPSM;
    bytes[12] = (uint8_t)(self.publicPSM >> 8);
    bytes[13] = (uint8_t)self.publicPSM;
    bytes[14] = (uint8_t)self.callbackTags.count;
    for (NSData *tag in self.callbackTags) [value appendData:tag];
    return value;
}

@end
