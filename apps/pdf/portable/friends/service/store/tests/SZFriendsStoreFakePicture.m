// A test-only SZFriendsPicture with the semantics the store relies on (kind, set, index, image path and hash), so
// the store suite does not depend on the avatars area's build. The helper links the real one; this file is never
// part of FRIENDS_SERVICE_OBJS.

#import "avatars/SZFriendsAvatars.h"

NS_ASSUME_NONNULL_BEGIN

@implementation SZFriendsPicture

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)initWithKind:(SZFriendsPictureKind)kind
                         set:(NSInteger)set
                       index:(NSInteger)index
                        path:(nullable NSString *)path
                      sha256:(nullable NSData *)sha256 {
    if ((self = [super init])) {
        _kind = kind;
        _animalSet = set;
        _animalIndex = index;
        _imagePath = [path copy];
        _imageSHA256 = [sha256 copy];
    }
    return self;
}

+ (instancetype)placeholder {
    return [[self alloc] initWithKind:SZFriendsPictureKindPlaceholder set:0 index:-1 path:nil sha256:nil];
}

+ (instancetype)animalWithSet:(NSInteger)set index:(NSInteger)index {
    return [[self alloc] initWithKind:SZFriendsPictureKindAnimal set:set index:index path:nil sha256:nil];
}

+ (instancetype)imageAtPath:(NSString *)path sha256:(NSData *)sha256 {
    return [[self alloc] initWithKind:SZFriendsPictureKindImage set:0 index:-1 path:path sha256:sha256];
}

- (id)copyWithZone:(nullable NSZone *)zone {
    (void)zone;
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeInteger:_kind forKey:@"kind"];
    [coder encodeInteger:_animalSet forKey:@"set"];
    [coder encodeInteger:_animalIndex forKey:@"index"];
    [coder encodeObject:_imagePath forKey:@"path"];
    [coder encodeObject:_imageSHA256 forKey:@"sha256"];
}

- (nullable instancetype)initWithCoder:(NSCoder *)coder {
    return [self initWithKind:[coder decodeIntegerForKey:@"kind"]
                          set:[coder decodeIntegerForKey:@"set"]
                        index:[coder decodeIntegerForKey:@"index"]
                         path:[coder decodeObjectOfClass:[NSString class] forKey:@"path"]
                       sha256:[coder decodeObjectOfClass:[NSData class] forKey:@"sha256"]];
}

- (NSDictionary<NSString *, id> *)protocolFieldsValidatedAgainst:(nullable SZFriendsAnimalSet *)set {
    (void)set;
    return @{};
}

- (BOOL)isEqual:(id)object {
    if (![object isKindOfClass:[SZFriendsPicture class]]) return NO;
    SZFriendsPicture *other = object;
    return other.kind == _kind && other.animalSet == _animalSet && other.animalIndex == _animalIndex &&
           (other.imagePath == _imagePath || [other.imagePath isEqualToString:_imagePath]) &&
           (other.imageSHA256 == _imageSHA256 || [other.imageSHA256 isEqualToData:_imageSHA256]);
}

- (NSUInteger)hash {
    return (NSUInteger)(_kind * 31 + _animalSet * 7 + _animalIndex);
}

@end

NS_ASSUME_NONNULL_END
