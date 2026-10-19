// SZFriendsAnimalSet: the bundled animal set, read from avatars/animals/manifest.json (SZFriendsAvatars.h).

#import "avatars/SZFriendsAvatarsInternal.h"

// A real manifest is a few kilobytes; anything near this is damage, and reading it whole would waste memory.
static const unsigned long long SZFriendsManifestMaxBytes = 1024 * 1024;
// Indexes travel as u16 in the PROFILE session frame (SZFriendsSession.h), so no set can exceed this.
static const NSInteger SZFriendsAnimalMaxCount = 65536;

@interface SZFriendsAnimalSet ()
@property(nonatomic, copy) NSArray<NSString *> *names;
@property(nonatomic, copy) NSArray<NSString *> *colors;
@property(nonatomic, copy) NSArray<NSString *> *svgPaths;
@property(nonatomic, copy) NSArray<NSString *> *pdfPaths;
@end

static NSError *SZFriendsManifestError(NSString *path, NSString *reason) {
    // Developer-facing: a damaged manifest is a packaging bug, never something a person can act on.
    NSString *message = [NSString stringWithFormat:@"Animal set manifest %@: %@", path, reason];
    return [NSError errorWithDomain:SZFriendsPictureErrorDomain
                               code:SZFriendsPictureErrorInternal
                           userInfo:@{NSLocalizedDescriptionKey : message, NSFilePathErrorKey : path}];
}

static BOOL SZFriendsIsJSONInteger(id value) {
    // NSJSONSerialization gives booleans as NSNumber too; true must not count as 1.
    if (![value isKindOfClass:[NSNumber class]] || value == (id)kCFBooleanTrue || value == (id)kCFBooleanFalse) {
        return NO;
    }
    double d = [value doubleValue];
    return d == floor(d) && fabs(d) < 9007199254740992.0;
}

// A relative path that stays inside the manifest's directory: no absolute paths, no "..", no empty parts.
static NSString *SZFriendsContainedPath(NSString *directory, id relative) {
    if (![relative isKindOfClass:[NSString class]] || [relative length] == 0 || [relative hasPrefix:@"/"]) return nil;
    for (NSString *part in [relative componentsSeparatedByString:@"/"]) {
        if (part.length == 0 || [part isEqualToString:@".."] || [part isEqualToString:@"."]) return nil;
    }
    return [directory stringByAppendingPathComponent:relative];
}

static BOOL SZFriendsIsColor(id value) {
    static NSRegularExpression *pattern;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pattern = [NSRegularExpression regularExpressionWithPattern:@"^#[0-9a-f]{6}$" options:0 error:nil];
    });
    return [value isKindOfClass:[NSString class]] &&
           [pattern numberOfMatchesInString:value options:0 range:NSMakeRange(0, [value length])] == 1;
}

@implementation SZFriendsAnimalSet

+ (instancetype)bundledSet {
    static SZFriendsAnimalSet *bundled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (NSString *candidate in [self bundledManifestCandidates]) {
            if (![[NSFileManager defaultManager] fileExistsAtPath:candidate]) continue;
            bundled = [self setWithManifestAtPath:candidate error:NULL];
            break;
        }
    });
    return bundled;
}

+ (NSArray<NSString *> *)bundledManifestCandidates {
    NSString *override = NSProcessInfo.processInfo.environment[@"SZFRIENDS_AVATARS_MANIFEST"];
    if (override.length > 0 && override.isAbsolutePath) return @[ override ];

    NSString *relative = @"Contents/Resources/Friends/animals/manifest.json";
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    NSString *bundlePath = NSBundle.mainBundle.bundlePath.stringByStandardizingPath;
    [candidates addObject:[bundlePath stringByAppendingPathComponent:relative]];
    // A helper in Host.app/Contents/Helpers/Helper.app reads the host's copy, so the set ships once per app.
    NSString *helpers = bundlePath.stringByDeletingLastPathComponent;
    if ([helpers.lastPathComponent isEqualToString:@"Helpers"]) {
        NSString *hostBundle = helpers.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
        [candidates addObject:[hostBundle stringByAppendingPathComponent:relative]];
    }
    return candidates;
}

+ (instancetype)setWithManifestAtPath:(NSString *)path error:(NSError **)error {
    NSError *readError = nil;
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:&readError];
    if (!attributes || attributes.fileSize > SZFriendsManifestMaxBytes) {
        if (error) *error = SZFriendsManifestError(path, attributes ? @"too large" : @"cannot be read");
        return nil;
    }
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:&readError];
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&readError] : nil;
    if (![json isKindOfClass:[NSDictionary class]]) {
        if (error) *error = SZFriendsManifestError(path, @"not a JSON object");
        return nil;
    }
    NSString *problem = nil;
    SZFriendsAnimalSet *set = [[self alloc] initWithManifest:json directory:path.stringByDeletingLastPathComponent
                                                     problem:&problem];
    if (!set && error) *error = SZFriendsManifestError(path, problem);
    return set;
}

- (instancetype)initWithManifest:(NSDictionary *)manifest directory:(NSString *)directory problem:(NSString **)problem {
    if (!(self = [super init])) return nil;
    id version = manifest[@"set"], count = manifest[@"count"], animals = manifest[@"animals"];
    if (!SZFriendsIsJSONInteger(version) || [version integerValue] < 1) {
        *problem = @"\"set\" must be an integer of at least 1";
        return nil;
    }
    if (![animals isKindOfClass:[NSArray class]] || [animals count] == 0 ||
        (NSInteger)[animals count] > SZFriendsAnimalMaxCount) {
        *problem = @"\"animals\" must be a non-empty array of at most 65536 entries";
        return nil;
    }
    if (!SZFriendsIsJSONInteger(count) || [count integerValue] != (NSInteger)[animals count]) {
        *problem = @"\"count\" must equal the number of animals";
        return nil;
    }
    NSMutableArray *names = [NSMutableArray array], *colors = [NSMutableArray array];
    NSMutableArray *svgs = [NSMutableArray array], *pdfs = [NSMutableArray array];
    NSInteger expected = 0;
    for (id animal in animals) {
        NSString *where = [NSString stringWithFormat:@"animal %ld", (long)expected];
        if (![animal isKindOfClass:[NSDictionary class]]) {
            *problem = [where stringByAppendingString:@" is not an object"];
            return nil;
        }
        // Indexes are positions: an animal's index is permanent, so the array can never skip or reorder one.
        id index = animal[@"index"], name = animal[@"name"], color = animal[@"color"];
        if (!SZFriendsIsJSONInteger(index) || [index integerValue] != expected) {
            *problem = [where stringByAppendingString:@" has the wrong \"index\""];
            return nil;
        }
        if (![name isKindOfClass:[NSString class]] || [name length] == 0) {
            *problem = [where stringByAppendingString:@" needs a \"name\""];
            return nil;
        }
        if (!SZFriendsIsColor(color)) {
            *problem = [where stringByAppendingString:@" needs a \"color\" like #5a4a7a"];
            return nil;
        }
        NSString *svg = SZFriendsContainedPath(directory, animal[@"svg"]);
        NSString *pdf = SZFriendsContainedPath(directory, animal[@"pdf"]);
        if (!svg || !pdf) {
            *problem = [where stringByAppendingString:@" needs relative \"svg\" and \"pdf\" paths inside the set"];
            return nil;
        }
        [names addObject:name];
        [colors addObject:color];
        [svgs addObject:svg];
        [pdfs addObject:pdf];
        expected++;
    }
    _version = [version integerValue];
    _names = names;
    _colors = colors;
    _svgPaths = svgs;
    _pdfPaths = pdfs;
    return self;
}

- (NSInteger)count {
    return (NSInteger)self.names.count;
}

- (BOOL)containsIndex:(NSInteger)index {
    return index >= 0 && index < self.count;
}

- (NSString *)nameAtIndex:(NSInteger)index {
    return [self containsIndex:index] ? self.names[(NSUInteger)index] : nil;
}

- (NSString *)colorAtIndex:(NSInteger)index {
    return [self containsIndex:index] ? self.colors[(NSUInteger)index] : nil;
}

- (NSString *)svgPathAtIndex:(NSInteger)index {
    return [self containsIndex:index] ? self.svgPaths[(NSUInteger)index] : nil;
}

- (NSString *)pdfPathAtIndex:(NSInteger)index {
    return [self containsIndex:index] ? self.pdfPaths[(NSUInteger)index] : nil;
}

- (NSInteger)indexForRandomValue:(uint32_t)randomValue {
    // Modulo bias is count / 2^32, under one in ten million for any plausible set: irrelevant for a picture.
    return (NSInteger)(randomValue % (uint32_t)self.count);
}

- (SZFriendsPicture *)randomDefaultPicture {
    NSInteger index = (NSInteger)arc4random_uniform((uint32_t)self.count);
    return [SZFriendsPicture animalWithSet:self.version index:index];
}

@end
