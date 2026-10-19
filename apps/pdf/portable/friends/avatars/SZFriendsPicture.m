// SZFriendsPicture, initials and placeholder colors (SZFriendsAvatars.h).

#import "avatars/SZFriendsAvatarsInternal.h"

static NSString *const SZFriendsCodingKind = @"kind";
static NSString *const SZFriendsCodingSet = @"set";
static NSString *const SZFriendsCodingIndex = @"index";
static NSString *const SZFriendsCodingPath = @"path";
static NSString *const SZFriendsCodingSHA256 = @"sha256";

@implementation SZFriendsPicture

- (instancetype)initWithKind:(SZFriendsPictureKind)kind
                         set:(NSInteger)set
                       index:(NSInteger)index
                        path:(NSString *)path
                      sha256:(NSData *)sha256 {
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
    // Out-of-range values cannot name any animal in any version, so they are a placeholder from the start,
    // which keeps the invariants documented on the properties true for every instance.
    if (set < 1 || index < 0) return [self placeholder];
    return [[self alloc] initWithKind:SZFriendsPictureKindAnimal set:set index:index path:nil sha256:nil];
}

+ (instancetype)imageAtPath:(NSString *)path sha256:(NSData *)sha256 {
    return [[self alloc] initWithKind:SZFriendsPictureKindImage set:0 index:-1 path:path sha256:sha256];
}

- (NSDictionary<NSString *, id> *)protocolFieldsValidatedAgainst:(SZFriendsAnimalSet *)set {
    switch (self.kind) {
    case SZFriendsPictureKindAnimal: {
        NSString *color = [set containsIndex:self.animalIndex] ? [set colorAtIndex:self.animalIndex] : nil;
        if (!color) return @{@"kind" : @"placeholder"};
        return @{@"kind" : @"animal", @"set" : @(self.animalSet), @"index" : @(self.animalIndex), @"color" : color};
    }
    case SZFriendsPictureKindImage:
        if (self.imagePath.length == 0) return @{@"kind" : @"placeholder"};
        return @{@"kind" : @"image", @"path" : self.imagePath};
    case SZFriendsPictureKindPlaceholder:
        break;
    }
    return @{@"kind" : @"placeholder"};
}

- (id)copyWithZone:(NSZone *)zone {
    (void)zone;
    return self; // immutable
}

- (BOOL)isEqual:(id)object {
    if (object == self) return YES;
    if (![object isKindOfClass:[SZFriendsPicture class]]) return NO;
    SZFriendsPicture *other = object;
    return other.kind == self.kind && other.animalSet == self.animalSet && other.animalIndex == self.animalIndex &&
           (other.imagePath == self.imagePath || [other.imagePath isEqualToString:self.imagePath]) &&
           (other.imageSHA256 == self.imageSHA256 || [other.imageSHA256 isEqualToData:self.imageSHA256]);
}

- (NSUInteger)hash {
    return (NSUInteger)self.kind * 31u + (NSUInteger)self.animalSet * 1009u + (NSUInteger)self.animalIndex * 7u +
           self.imagePath.hash;
}

- (NSString *)description {
    switch (self.kind) {
    case SZFriendsPictureKindAnimal:
        return [NSString stringWithFormat:@"<SZFriendsPicture animal %ld/%ld>", (long)self.animalSet,
                                          (long)self.animalIndex];
    case SZFriendsPictureKindImage:
        return [NSString stringWithFormat:@"<SZFriendsPicture image %@>", self.imagePath.lastPathComponent];
    case SZFriendsPictureKindPlaceholder:
        break;
    }
    return @"<SZFriendsPicture placeholder>";
}

#pragma mark NSSecureCoding

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeInteger:self.kind forKey:SZFriendsCodingKind];
    [coder encodeInteger:self.animalSet forKey:SZFriendsCodingSet];
    [coder encodeInteger:self.animalIndex forKey:SZFriendsCodingIndex];
    if (self.imagePath) [coder encodeObject:self.imagePath forKey:SZFriendsCodingPath];
    if (self.imageSHA256) [coder encodeObject:self.imageSHA256 forKey:SZFriendsCodingSHA256];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    NSInteger kind = [coder decodeIntegerForKey:SZFriendsCodingKind];
    if (kind == SZFriendsPictureKindAnimal) {
        NSInteger set = [coder decodeIntegerForKey:SZFriendsCodingSet];
        NSInteger index = [coder decodeIntegerForKey:SZFriendsCodingIndex];
        if (set >= 1 && index >= 0) return [self initWithKind:kind set:set index:index path:nil sha256:nil];
    } else if (kind == SZFriendsPictureKindImage) {
        NSString *path = [coder decodeObjectOfClass:[NSString class] forKey:SZFriendsCodingPath];
        NSData *sha256 = [coder decodeObjectOfClass:[NSData class] forKey:SZFriendsCodingSHA256];
        if (path.length > 0 && sha256.length == 32) {
            return [self initWithKind:kind set:0 index:-1 path:path sha256:sha256];
        }
    } else if (kind == SZFriendsPictureKindPlaceholder) {
        return [self initWithKind:kind set:0 index:-1 path:nil sha256:nil];
    }
    // Damaged archives must not produce a picture that breaks the property invariants.
    [coder failWithError:[NSError errorWithDomain:NSCocoaErrorDomain code:NSCoderReadCorruptError userInfo:nil]];
    return nil;
}

@end

#pragma mark - Initials

// The first character people would see as a letter: skips leading punctuation and symbols ("(Mei)" -> "M"),
// keeping whole composed characters (é, 王, a flag emoji). A word of only symbols gives its first character.
static NSString *SZFriendsFirstCharacter(NSString *word) {
    NSCharacterSet *alphanumerics = [NSCharacterSet alphanumericCharacterSet];
    __block NSString *found = nil;
    [word enumerateSubstringsInRange:NSMakeRange(0, word.length)
                             options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *character, NSRange range, NSRange enclosing, BOOL *stop) {
                              (void)range;
                              (void)enclosing;
                              if ([character rangeOfCharacterFromSet:alphanumerics].location == 0) {
                                  found = character;
                                  *stop = YES;
                              }
                          }];
    if (found) return found;
    if (word.length == 0) return @"";
    return [word substringWithRange:[word rangeOfComposedCharacterSequenceAtIndex:0]];
}

static BOOL SZFriendsLooksLikeFriendsID(NSString *text) {
    static NSRegularExpression *pattern;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pattern = [NSRegularExpression regularExpressionWithPattern:@"^[a-z]+(-[a-z]+)+$" options:0 error:nil];
    });
    return [pattern numberOfMatchesInString:text options:0 range:NSMakeRange(0, text.length)] == 1;
}

NSString *SZFriendsInitials(NSString *nameOrFriendsID) {
    NSCharacterSet *spaces = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSString *trimmed = [nameOrFriendsID ?: @"" stringByTrimmingCharactersInSet:spaces];
    NSArray<NSString *> *words;
    if (SZFriendsLooksLikeFriendsID(trimmed)) {
        words = [trimmed componentsSeparatedByString:@"-"];
    } else {
        NSPredicate *nonEmpty = [NSPredicate predicateWithFormat:@"length > 0"];
        words = [[trimmed componentsSeparatedByCharactersInSet:spaces] filteredArrayUsingPredicate:nonEmpty];
    }
    NSMutableString *initials = [NSMutableString string];
    // Two at most: the placeholder circle is 28 pt in rows, and a third letter would not fit legibly.
    for (NSUInteger i = 0; i < words.count && i < 2; i++) [initials appendString:SZFriendsFirstCharacter(words[i])];
    return [initials uppercaseStringWithLocale:[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]];
}

#pragma mark - Placeholder colors

// Muted mid-dark sRGB colors from the same family as the animal set's circles. Each keeps white initials at or
// above 4.5:1 (WCAG AA for text), checked by friends-avatars-check, and stays distinct from the light and dark
// dropdown backgrounds. Order is part of the contract: a person's color must not change between releases.
static NSString *const SZFriendsPlaceholderPalette[] = {
    @"#5a4a7a", @"#2f6474", @"#7a3f4f", @"#4a6a2f", @"#7a5a34", @"#3f6b4f",
    @"#4f4f86", @"#5a5a66", @"#6a4a6a", @"#355f80", @"#80463a", @"#3d6a6a",
};

NSString *SZFriendsPlaceholderColor(NSString *seed) {
    // FNV-1a 32 over UTF-8: stable across launches and platforms, unlike -hash, so a GTK host computing the
    // same function would agree.
    NSData *bytes = [seed ?: @"" dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *p = bytes.bytes;
    uint32_t hash = 0x811c9dc5u;
    for (NSUInteger i = 0; i < bytes.length; i++) {
        hash ^= p[i];
        hash *= 0x01000193u;
    }
    NSUInteger count = sizeof(SZFriendsPlaceholderPalette) / sizeof(SZFriendsPlaceholderPalette[0]);
    return SZFriendsPlaceholderPalette[hash % count];
}
