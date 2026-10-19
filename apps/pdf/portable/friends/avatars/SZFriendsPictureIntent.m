// set_picture parsing (PROTOCOL.md § Intents) and the content-addressed pictures directory.

#import <CommonCrypto/CommonDigest.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

#import "avatars/SZFriendsAvatarsInternal.h"

// Base64 of SZFriendsPictureMaxInputBytes is 4 * ceil(5 MiB / 3) characters. Checked before decoding, so an
// oversized upload is refused without allocating its decoded copy.
static const NSUInteger SZFriendsMaxBase64Length = 4 * ((5 * 1024 * 1024 + 2) / 3);

static BOOL SZFriendsIsWholeNumber(id value) {
    if (![value isKindOfClass:[NSNumber class]] || value == (id)kCFBooleanTrue || value == (id)kCFBooleanFalse) {
        return NO;
    }
    double d = [value doubleValue];
    return d == floor(d) && fabs(d) < 9007199254740992.0;
}

NSData *SZFriendsPictureReadFile(NSString *path, NSUInteger limit, NSError **error) {
    if (![path isKindOfClass:[NSString class]] || !path.isAbsolutePath) {
        return (SZFriendsPictureFail(error, SZFriendsPictureFailureMalformedIntent, @"picture.path", nil), nil);
    }
    // O_NONBLOCK: opening a named pipe would otherwise wait for a writer forever and stall the helper.
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) return (SZFriendsPictureFail(error, SZFriendsPictureFailureFileMissing, nil, path), nil);
    struct stat info;
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode)) {
        close(fd);
        return (SZFriendsPictureFail(error, SZFriendsPictureFailureNotAFile, nil, path), nil);
    }
    if (info.st_size > (off_t)limit) {
        close(fd);
        return (SZFriendsPictureFail(error, SZFriendsPictureFailureTooManyBytes, nil, path), nil);
    }
    // Read at most limit + 1 bytes: a file growing while it is read is caught instead of trusted.
    NSMutableData *data = [NSMutableData dataWithLength:limit + 1];
    size_t used = 0;
    while (used < limit + 1) {
        ssize_t got = read(fd, (uint8_t *)data.mutableBytes + used, limit + 1 - used);
        if (got < 0 && errno == EINTR) continue;
        if (got < 0) {
            close(fd);
            return (SZFriendsPictureFail(error, SZFriendsPictureFailureFileMissing, nil, path), nil);
        }
        if (got == 0) break;
        used += (size_t)got;
    }
    close(fd);
    if (used > limit) return (SZFriendsPictureFail(error, SZFriendsPictureFailureTooManyBytes, nil, path), nil);
    data.length = used;
    return data;
}

static BOOL SZFriendsParseCrop(id crop, NSRect *rect, NSError **error) {
    *rect = NSZeroRect;
    if (!crop || crop == (id)[NSNull null]) return YES;
    if (![crop isKindOfClass:[NSDictionary class]]) {
        return SZFriendsPictureFail(error, SZFriendsPictureFailureMalformedIntent, @"picture.crop", nil);
    }
    id x = crop[@"x"], y = crop[@"y"], side = crop[@"side"];
    if (!SZFriendsIsWholeNumber(x) || [x doubleValue] < 0) {
        return SZFriendsPictureFail(error, SZFriendsPictureFailureMalformedIntent, @"picture.crop.x", nil);
    }
    if (!SZFriendsIsWholeNumber(y) || [y doubleValue] < 0) {
        return SZFriendsPictureFail(error, SZFriendsPictureFailureMalformedIntent, @"picture.crop.y", nil);
    }
    if (!SZFriendsIsWholeNumber(side) || [side doubleValue] < 1) {
        return SZFriendsPictureFail(error, SZFriendsPictureFailureMalformedIntent, @"picture.crop.side", nil);
    }
    *rect = NSMakeRect([x doubleValue], [y doubleValue], [side doubleValue], [side doubleValue]);
    return YES;
}

static SZFriendsPicture *SZFriendsAnimalFromIntent(NSDictionary *picture, SZFriendsAnimalSet *set, NSError **error) {
    id setVersion = picture[@"set"], index = picture[@"index"];
    if (!SZFriendsIsWholeNumber(setVersion)) {
        return (SZFriendsPictureFail(error, SZFriendsPictureFailureMalformedIntent, @"picture.set", nil), nil);
    }
    if (!SZFriendsIsWholeNumber(index)) {
        return (SZFriendsPictureFail(error, SZFriendsPictureFailureMalformedIntent, @"picture.index", nil), nil);
    }
    // The person can only choose an animal this app offers. A set version newer than ours means a view from a
    // newer build talking to this helper; indexes are permanent, so the check that matters is the index.
    NSInteger version = [setVersion integerValue], number = [index integerValue];
    if (!set || version < 1 || version > set.version || ![set containsIndex:number]) {
        return (SZFriendsPictureFail(error, SZFriendsPictureFailureAnimalUnavailable, nil, nil), nil);
    }
    return [SZFriendsPicture animalWithSet:version index:number];
}

SZFriendsPicture *SZFriendsPictureFromIntent(id picture, SZFriendsAnimalSet *set, NSString *directory,
                                             NSError **error) {
    if (![picture isKindOfClass:[NSDictionary class]]) {
        return (SZFriendsPictureFail(error, SZFriendsPictureFailureMalformedIntent, @"picture", nil), nil);
    }
    id kind = picture[@"kind"];
    if ([kind isEqual:@"animal"]) return SZFriendsAnimalFromIntent(picture, set, error);
    if (![kind isEqual:@"image"]) {
        return (SZFriendsPictureFail(error, SZFriendsPictureFailureMalformedIntent, @"picture.kind", nil), nil);
    }
    id base64 = picture[@"data_base64"], path = picture[@"path"];
    if ((base64 == nil) == (path == nil)) {
        // Exactly one source: a photo is either uploaded or named, never both or neither.
        return (SZFriendsPictureFail(error, SZFriendsPictureFailureMalformedIntent, @"picture", nil), nil);
    }
    NSRect crop;
    if (!SZFriendsParseCrop(picture[@"crop"], &crop, error)) return nil;
    NSData *bytes;
    if (base64) {
        if (![base64 isKindOfClass:[NSString class]]) {
            return (SZFriendsPictureFail(error, SZFriendsPictureFailureMalformedIntent, @"picture.data_base64", nil),
                    nil);
        }
        if ([base64 length] > SZFriendsMaxBase64Length) {
            return (SZFriendsPictureFail(error, SZFriendsPictureFailureTooManyBytes, nil, nil), nil);
        }
        bytes = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
        if (!bytes) {
            return (SZFriendsPictureFail(error, SZFriendsPictureFailureMalformedIntent, @"picture.data_base64", nil),
                    nil);
        }
    } else {
        bytes = SZFriendsPictureReadFile(path, SZFriendsPictureMaxInputBytes, error);
        if (!bytes) return nil;
    }
    NSData *jpeg = [SZFriendsPicturePipeline normalizedImageFromData:bytes crop:crop error:error];
    return jpeg ? SZFriendsPictureStore(jpeg, directory, error) : nil;
}

static NSString *SZFriendsHex(NSData *data) {
    NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
    const uint8_t *p = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) [hex appendFormat:@"%02x", p[i]];
    return hex;
}

static BOOL SZFriendsWriteAll(int fd, NSData *data) {
    size_t done = 0;
    while (done < data.length) {
        ssize_t wrote = write(fd, (const uint8_t *)data.bytes + done, data.length - done);
        if (wrote < 0 && errno == EINTR) continue;
        if (wrote <= 0) return NO;
        done += (size_t)wrote;
    }
    return YES;
}

SZFriendsPicture *SZFriendsPictureStore(NSData *jpeg, NSString *directory, NSError **error) {
    if (jpeg.length == 0 || jpeg.length > SZFriendsPictureMaxOutputBytes || directory.length == 0) {
        return (SZFriendsPictureFail(error, SZFriendsPictureFailureEncode, nil, nil), nil);
    }
    NSMutableData *digest = [NSMutableData dataWithLength:CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(jpeg.bytes, (CC_LONG)jpeg.length, digest.mutableBytes);
    NSString *path = [directory stringByAppendingPathComponent:[SZFriendsHex(digest) stringByAppendingString:@".jpg"]];
    SZFriendsPicture *picture = [SZFriendsPicture imageAtPath:path sha256:digest];

    NSDictionary *attributes = @{NSFilePosixPermissions : @0700};
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory
                                   withIntermediateDirectories:YES
                                                    attributes:attributes
                                                         error:NULL]) {
        return (SZFriendsPictureFail(error, SZFriendsPictureFailureWrite, nil, directory), nil);
    }
    // Content-addressed: an existing file with this name and these exact bytes is the same picture. Compared in
    // full (48 KiB at most) so a damaged file is replaced rather than trusted for its name.
    NSData *existing = [NSData dataWithContentsOfFile:path options:0 error:NULL];
    if ([existing isEqualToData:jpeg]) return picture;

    // A unique temporary name in the same directory, then rename: readers never see a half-written picture,
    // and mkstemp creates it 0600.
    NSString *template = [directory stringByAppendingPathComponent:@".picture-XXXXXX"];
    char *buffer = strdup(template.fileSystemRepresentation);
    int fd = buffer ? mkstemp(buffer) : -1;
    BOOL ok = fd >= 0 && SZFriendsWriteAll(fd, jpeg) && fsync(fd) == 0;
    if (fd >= 0) ok = (close(fd) == 0) && ok;
    if (ok) ok = rename(buffer, path.fileSystemRepresentation) == 0;
    if (!ok && fd >= 0) unlink(buffer);
    free(buffer);
    if (!ok) return (SZFriendsPictureFail(error, SZFriendsPictureFailureWrite, nil, directory), nil);
    return picture;
}
