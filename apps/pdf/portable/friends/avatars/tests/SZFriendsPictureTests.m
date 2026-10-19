// SZFriendsPicture as a value, its PROTOCOL.md fields and archiving; initials; placeholder colors.

#import "SZFriendsAvatarsTestSupport.h"

double SZTestContrastWithWhite(NSString *hex);

// Archives as an SZFriendsPicture whose fields break the class's invariants, as a damaged store row would.
@interface SZTestDamagedPicture : NSObject <NSSecureCoding>
@end

@implementation SZTestDamagedPicture
+ (BOOL)supportsSecureCoding {
    return YES;
}
- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeInteger:SZFriendsPictureKindImage forKey:@"kind"];
    [coder encodeObject:@"/tmp/x.jpg" forKey:@"path"];
    [coder encodeObject:[NSData dataWithBytes:"short" length:5] forKey:@"sha256"];
}
- (instancetype)initWithCoder:(NSCoder *)coder {
    (void)coder;
    return [super init];
}
@end

static SZFriendsPicture *SZTestRoundTrip(SZFriendsPicture *picture) {
    NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:picture requiringSecureCoding:YES error:NULL];
    return [NSKeyedUnarchiver unarchivedObjectOfClass:[SZFriendsPicture class] fromData:archive error:NULL];
}

static void SZTestValues(SZTestContext context) {
    SZFriendsAnimalSet *set = [SZFriendsAnimalSet setWithManifestAtPath:context.manifestPath error:NULL];
    SZFriendsPicture *mei = [SZFriendsPicture animalWithSet:1 index:7];
    SZ_CHECK(mei.kind == SZFriendsPictureKindAnimal && mei.animalSet == 1 && mei.animalIndex == 7 && !mei.imagePath,
             @"%@", mei);
    SZ_CHECK([mei isEqual:[SZFriendsPicture animalWithSet:1 index:7]] &&
                 mei.hash == [SZFriendsPicture animalWithSet:1 index:7].hash,
             @"equal animals");
    SZ_CHECK(![mei isEqual:[SZFriendsPicture animalWithSet:1 index:8]] && ![mei isEqual:@"mei"], @"unequal");
    SZ_CHECK([[mei copy] isEqual:mei], @"copy");
    SZFriendsPicture *placeholder = [SZFriendsPicture placeholder];
    SZ_CHECK(placeholder.kind == SZFriendsPictureKindPlaceholder && placeholder.animalSet == 0 &&
                 placeholder.animalIndex == -1,
             @"placeholder");
    SZ_CHECK([[SZFriendsPicture animalWithSet:0 index:3] isEqual:placeholder] &&
                 [[SZFriendsPicture animalWithSet:1 index:-1] isEqual:placeholder],
             @"out-of-range animals are placeholders");
    uint8_t digest[32] = {1, 2, 3};
    NSData *sha = [NSData dataWithBytes:digest length:32];
    SZFriendsPicture *photo = [SZFriendsPicture imageAtPath:@"/state/pictures/0102.jpg" sha256:sha];
    SZ_CHECK(photo.kind == SZFriendsPictureKindImage && [photo.imageSHA256 isEqualToData:sha], @"image");
    SZ_CHECK(![photo isEqual:[SZFriendsPicture imageAtPath:@"/state/pictures/other.jpg" sha256:sha]], @"paths");

    NSDictionary *expected = @{@"kind" : @"animal", @"set" : @1, @"index" : @7, @"color" : @"#3f6b4f"};
    SZ_CHECK([[mei protocolFieldsValidatedAgainst:set] isEqual:expected], @"%@",
             [mei protocolFieldsValidatedAgainst:set]);
    // An animal from a newer set (a friend on a newer app) is drawn when this copy has its index.
    NSDictionary *newer = [[SZFriendsPicture animalWithSet:2 index:7] protocolFieldsValidatedAgainst:set];
    SZ_CHECK([newer[@"kind"] isEqual:@"animal"], @"known index from a newer set");
    NSDictionary *placeholderFields = @{@"kind" : @"placeholder"};
    SZ_CHECK([[[SZFriendsPicture animalWithSet:2 index:4000] protocolFieldsValidatedAgainst:set]
                 isEqual:placeholderFields],
             @"an index this copy lacks falls back to a placeholder");
    SZ_CHECK([[mei protocolFieldsValidatedAgainst:nil] isEqual:placeholderFields], @"no set: placeholder");
    SZ_CHECK([[placeholder protocolFieldsValidatedAgainst:set] isEqual:placeholderFields], @"placeholder fields");
    NSDictionary *photoFields = @{@"kind" : @"image", @"path" : @"/state/pictures/0102.jpg"};
    SZ_CHECK([[photo protocolFieldsValidatedAgainst:set] isEqual:photoFields], @"image fields");

    for (SZFriendsPicture *picture in @[ mei, placeholder, photo ]) {
        SZ_CHECK([SZTestRoundTrip(picture) isEqual:picture], @"secure coding round trip of %@", picture);
    }
    NSKeyedArchiver *archiver = [[NSKeyedArchiver alloc] initRequiringSecureCoding:YES];
    [archiver setClassName:@"SZFriendsPicture" forClass:[SZTestDamagedPicture class]];
    [archiver encodeObject:[SZTestDamagedPicture new] forKey:NSKeyedArchiveRootObjectKey];
    [archiver finishEncoding];
    NSError *error = nil;
    id damaged = [NSKeyedUnarchiver unarchivedObjectOfClass:[SZFriendsPicture class]
                                                   fromData:archiver.encodedData
                                                      error:&error];
    SZ_CHECK(damaged == nil && error != nil, @"a damaged archive must not decode: %@", damaged);
}

static void SZTestInitials(void) {
    NSDictionary<NSString *, NSString *> *cases = @{
        @"Lena Weber" : @"LW",
        @"Raph" : @"R",
        @"orchid-summit" : @"OS",
        @"maple-river-stone" : @"MR",
        @"  mei   lin  " : @"ML",
        @"Mei\nLin" : @"ML",
        @"émile zola" : @"ÉZ",
        @"王小明" : @"王",
        @"(Mei) Lin" : @"ML",
        @"Jean-Luc Picard" : @"JP",
        @"Anne-Marie" : @"A",
        @"o'brien" : @"O",
        @"🦊 Fox" : @"🦊F",
        @"" : @"",
        @"   " : @"",
    };
    for (NSString *input in cases) {
        NSString *initials = SZFriendsInitials(input);
        SZ_CHECK([initials isEqualToString:cases[input]], @"initials of \"%@\": \"%@\", expected \"%@\"", input,
                 initials, cases[input]);
    }
}

static void SZTestPlaceholderColors(void) {
    // Expected values computed independently (FNV-1a 32 over UTF-8, modulo the 12-color palette): a change here
    // would recolor every placeholder people already know.
    NSDictionary<NSString *, NSString *> *known = @{
        @"" : @"#2f6474", @"c_mei" : @"#5a4a7a", @"c_kenji" : @"#4f4f86", @"c_lena" : @"#355f80",
    };
    for (NSString *seed in known) {
        SZ_CHECK([SZFriendsPlaceholderColor(seed) isEqualToString:known[seed]], @"color of \"%@\": %@", seed,
                 SZFriendsPlaceholderColor(seed));
    }
    NSMutableSet<NSString *> *palette = [NSMutableSet set];
    for (int i = 0; i < 1000; i++) {
        NSString *seed = [NSString stringWithFormat:@"c_%d", i];
        NSString *color = SZFriendsPlaceholderColor(seed);
        SZ_CHECK([color isEqualToString:SZFriendsPlaceholderColor([seed copy])], @"unstable color for %@", seed);
        [palette addObject:color];
    }
    SZ_CHECK(palette.count == 12, @"1,000 seeds reached %lu palette colors", (unsigned long)palette.count);
    for (NSString *color in palette) {
        SZ_CHECK(SZTestContrastWithWhite(color) >= 4.5, @"%@ contrast with white initials %.2f", color,
                 SZTestContrastWithWhite(color));
    }
}

void SZRunPictureTests(SZTestContext context) {
    SZTestValues(context);
    SZTestInitials();
    SZTestPlaceholderColors();
}
