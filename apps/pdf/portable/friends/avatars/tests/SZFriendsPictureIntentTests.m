// set_picture intents end to end (PROTOCOL.md § Intents) and the content-addressed pictures directory.

#import <CommonCrypto/CommonDigest.h>
#import <sys/stat.h>

#import "SZFriendsAvatarsTestSupport.h"

void SZTestCheckOutputShape(NSString *what, NSData *jpeg);

static SZFriendsPicture *SZTestSetPicture(id picture, SZFriendsAnimalSet *set, NSString *directory, NSError **error) {
    return [SZFriendsPicturePipeline pictureFromIntentPicture:picture animalSet:set picturesDirectory:directory
                                                        error:error];
}

static void SZTestExpectIntentError(NSString *what, id picture, SZFriendsAnimalSet *set, NSString *directory,
                                    NSString *code, NSString *field) {
    NSError *error = nil;
    SZFriendsPicture *result = SZTestSetPicture(picture, set, directory, &error);
    SZ_CHECK(result == nil && [SZTestProtocolCode(error) isEqual:code], @"%@: %@ / %@", what, result,
             SZTestProtocolCode(error));
    if (field) {
        SZ_CHECK([error.userInfo[SZFriendsPictureErrorFieldKey] isEqual:field], @"%@: field %@, expected %@", what,
                 error.userInfo[SZFriendsPictureErrorFieldKey], field);
    }
    // Written for the person choosing a picture: no mechanism words.
    NSString *message = error.localizedDescription;
    SZ_CHECK(message.length > 0, @"%@: no message", what);
    for (NSString *jargon in @[ @"ImageIO", @"decode", @"MiB", @"byte", @"JSON", @"intent", @"field", @"base64" ]) {
        SZ_CHECK([message rangeOfString:jargon options:NSCaseInsensitiveSearch].location == NSNotFound,
                 @"%@: \"%@\" says %@", what, message, jargon);
    }
}

static void SZTestAnimalsAndMalformed(SZFriendsAnimalSet *set, NSString *directory) {
    NSDictionary *mei = @{@"kind" : @"animal", @"set" : @1, @"index" : @7};
    SZFriendsPicture *picture = SZTestSetPicture(mei, set, directory, NULL);
    SZ_CHECK([picture isEqual:[SZFriendsPicture animalWithSet:1 index:7]], @"animal: %@", picture);
    SZTestExpectIntentError(@"animal this app lacks", @{@"kind" : @"animal", @"set" : @1, @"index" : @999}, set,
                            directory, @"invalid_field", @"picture.index");
    SZTestExpectIntentError(@"animal from a newer set", @{@"kind" : @"animal", @"set" : @2, @"index" : @1}, set,
                            directory, @"invalid_field", @"picture.index");
    SZTestExpectIntentError(@"no animal set bundled", @{@"kind" : @"animal", @"set" : @1, @"index" : @1}, nil,
                            directory, @"invalid_field", @"picture.index");
    SZTestExpectIntentError(@"index as text", @{@"kind" : @"animal", @"set" : @1, @"index" : @"7"}, set, directory,
                            @"invalid_field", @"picture.index");
    SZTestExpectIntentError(@"set as boolean", @{@"kind" : @"animal", @"set" : @YES, @"index" : @7}, set, directory,
                            @"invalid_field", @"picture.set");
    SZTestExpectIntentError(@"fractional index", @{@"kind" : @"animal", @"set" : @1, @"index" : @1.5}, set, directory,
                            @"invalid_field", @"picture.index");
    SZTestExpectIntentError(@"unknown kind", @{@"kind" : @"video"}, set, directory, @"invalid_field", @"picture.kind");
    SZTestExpectIntentError(@"not an object", @[ @1 ], set, directory, @"invalid_field", @"picture");
    SZTestExpectIntentError(@"photo with two sources", @{@"kind" : @"image", @"data_base64" : @"AAAA", @"path" : @"/x"},
                            set, directory, @"invalid_field", @"picture");
    SZTestExpectIntentError(@"photo with no source", @{@"kind" : @"image"}, set, directory, @"invalid_field",
                            @"picture");
    SZTestExpectIntentError(@"crop not an object", @{@"kind" : @"image", @"data_base64" : @"AAAA", @"crop" : @"big"},
                            set, directory, @"invalid_field", @"picture.crop");
    SZTestExpectIntentError(@"negative crop x",
                            @{@"kind" : @"image", @"data_base64" : @"AAAA",
                              @"crop" : @{@"x" : @-1, @"y" : @0, @"side" : @9}},
                            set, directory, @"invalid_field", @"picture.crop.x");
    SZTestExpectIntentError(@"crop without side",
                            @{@"kind" : @"image", @"data_base64" : @"AAAA", @"crop" : @{@"x" : @0, @"y" : @0}}, set,
                            directory, @"invalid_field", @"picture.crop.side");
    SZTestExpectIntentError(@"data not text", @{@"kind" : @"image", @"data_base64" : @42}, set, directory,
                            @"invalid_field", @"picture.data_base64");
    SZTestExpectIntentError(@"data not base64", @{@"kind" : @"image", @"data_base64" : @"@@@@"}, set, directory,
                            @"invalid_field", @"picture.data_base64");
    SZTestExpectIntentError(@"relative path", @{@"kind" : @"image", @"path" : @"Pictures/me.png"}, set, directory,
                            @"invalid_field", @"picture.path");
    // Refused from its length alone, before anything is decoded or allocated for it.
    NSString *huge = [@"" stringByPaddingToLength:4 * ((SZFriendsPictureMaxInputBytes + 2) / 3) + 4 withString:@"AAAA"
                                  startingAtIndex:0];
    SZTestExpectIntentError(@"base64 over 5 MiB", @{@"kind" : @"image", @"data_base64" : huge}, set, directory,
                            @"picture_invalid", nil);
}

static NSString *SZTestHex(NSData *data) {
    NSMutableString *hex = [NSMutableString string];
    const uint8_t *p = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) [hex appendFormat:@"%02x", p[i]];
    return hex;
}

static void SZTestPhotosAndStorage(SZTestContext context, SZFriendsAnimalSet *set, NSString *directory) {
    CGImageRef image = SZTestCreateQuadrants(1200, 900);
    NSData *jpeg = SZTestEncode(image, @"public.jpeg", nil);
    NSData *heic = SZTestEncode(image, @"public.heic", nil);
    CGImageRelease(image);

    NSDictionary *upload = @{@"kind" : @"image", @"data_base64" : [jpeg base64EncodedStringWithOptions:0],
                             @"crop" : @{@"x" : @0, @"y" : @0, @"side" : @450}};
    NSError *error = nil;
    SZFriendsPicture *picture = SZTestSetPicture(upload, set, directory, &error);
    SZ_CHECK(picture.kind == SZFriendsPictureKindImage, @"upload: %@", error.localizedDescription);
    NSData *stored = [NSData dataWithContentsOfFile:picture.imagePath];
    SZTestCheckOutputShape(@"stored upload", stored);
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(stored.bytes, (CC_LONG)stored.length, digest);
    NSData *sha = [NSData dataWithBytes:digest length:sizeof digest];
    SZ_CHECK([picture.imageSHA256 isEqualToData:sha], @"picture hash must be the stored file's");
    NSString *expectedPath = [directory stringByAppendingFormat:@"/%@.jpg", SZTestHex(sha)];
    SZ_CHECK([picture.imagePath isEqual:expectedPath], @"%@", picture.imagePath);
    struct stat info, directoryInfo;
    SZ_CHECK(stat(picture.imagePath.fileSystemRepresentation, &info) == 0 && (info.st_mode & 0777) == 0600,
             @"picture mode %o", info.st_mode & 0777);
    SZ_CHECK(stat(directory.fileSystemRepresentation, &directoryInfo) == 0 && (directoryInfo.st_mode & 0777) == 0700,
             @"directory mode %o", directoryInfo.st_mode & 0777);
    int rgb[3];
    SZ_CHECK(SZTestPixel(stored, 128, 128, rgb) && SZTestNear(rgb, 255, 0, 0, 40), @"the crop took the top left");

    // Same picture again: the file is reused, not rewritten. A damaged file of that name is replaced.
    SZFriendsPicture *again = [SZFriendsPicturePipeline storeImage:stored inDirectory:directory error:NULL];
    struct stat infoAgain;
    stat(picture.imagePath.fileSystemRepresentation, &infoAgain);
    SZ_CHECK([again isEqual:picture] && infoAgain.st_ino == info.st_ino, @"identical picture must reuse the file");
    [@"damaged" writeToFile:picture.imagePath atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    SZ_CHECK([[SZFriendsPicturePipeline storeImage:stored inDirectory:directory error:NULL] isEqual:picture] &&
                 [[NSData dataWithContentsOfFile:picture.imagePath] isEqualToData:stored],
             @"a damaged file must be replaced");
    SZ_CHECK(![SZFriendsPicturePipeline storeImage:[NSData data] inDirectory:directory error:&error] &&
                 [SZTestProtocolCode(error) isEqual:@"internal"],
             @"storing nothing must fail");
    NSArray *leftovers = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:NULL]
        filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH '.'"]];
    SZ_CHECK(leftovers.count == 0, @"temporary files left behind: %@", leftovers);

    // Photos named by path, as the app's file picker returns them.
    NSString *files = [context.scratch stringByAppendingPathComponent:@"picked"];
    [NSFileManager.defaultManager createDirectoryAtPath:files withIntermediateDirectories:YES attributes:nil
                                                  error:NULL];
    NSString *heicPath = [files stringByAppendingPathComponent:@"Me.heic"];
    [heic writeToFile:heicPath atomically:YES];
    SZ_CHECK(SZTestSetPicture(@{@"kind" : @"image", @"path" : heicPath, @"crop" : [NSNull null]}, set, directory, NULL)
                     .kind == SZFriendsPictureKindImage,
             @"HEIC by path");
    NSString *missing = [files stringByAppendingPathComponent:@"gone.jpg"];
    SZTestExpectIntentError(@"missing file", @{@"kind" : @"image", @"path" : missing}, set, directory, @"file_missing",
                            nil);
    SZTestSetPicture(@{@"kind" : @"image", @"path" : missing}, set, directory, &error);
    SZ_CHECK([error.userInfo[NSFilePathErrorKey] isEqual:missing], @"file_missing must name the path");
    SZTestExpectIntentError(@"a folder", @{@"kind" : @"image", @"path" : files}, set, directory, @"picture_invalid",
                            nil);
    // A named pipe would block a plain open() forever; the watchdog in main() turns that into a failure.
    NSString *fifo = [files stringByAppendingPathComponent:@"pipe"];
    SZ_CHECK(mkfifo(fifo.fileSystemRepresentation, 0600) == 0, @"mkfifo");
    SZTestExpectIntentError(@"a named pipe", @{@"kind" : @"image", @"path" : fifo}, set, directory, @"picture_invalid",
                            nil);
    NSString *big = [files stringByAppendingPathComponent:@"big.jpg"];
    [[NSData data] writeToFile:big atomically:NO];
    truncate(big.fileSystemRepresentation, (off_t)SZFriendsPictureMaxInputBytes + 1);
    SZTestExpectIntentError(@"a file over 5 MiB", @{@"kind" : @"image", @"path" : big}, set, directory,
                            @"picture_invalid", nil);
}

static void SZTestFixtureIntents(SZTestContext context, SZFriendsAnimalSet *set, NSString *directory) {
    NSString *text = [NSString stringWithContentsOfFile:[context.fixturesPath stringByAppendingPathComponent:
                                                                                  @"intents.jsonl"]
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];
    NSUInteger seen = 0;
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (line.length == 0) continue;
        NSDictionary *intent = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding]
                                                               options:0
                                                                 error:NULL];
        if (![intent[@"type"] isEqual:@"set_picture"]) continue;
        seen++;
        NSMutableDictionary *picture = [intent[@"picture"] mutableCopy];
        NSError *error = nil;
        if ([picture[@"kind"] isEqual:@"animal"]) {
            SZ_CHECK(SZTestSetPicture(picture, set, directory, &error).kind == SZFriendsPictureKindAnimal,
                     @"fixture %@: %@", intent[@"id"], error.localizedDescription);
        } else if (picture[@"data_base64"]) {
            // The fixture's bytes are a stand-in, not a real JPEG: the intent parses (crop included) and the
            // picture itself is what fails.
            SZ_CHECK(!SZTestSetPicture(picture, set, directory, &error) &&
                         [SZTestProtocolCode(error) isEqual:@"picture_invalid"],
                     @"fixture %@: %@", intent[@"id"], SZTestProtocolCode(error));
        } else {
            // The fixture names a file on the owner's Mac; never read it. Same intent, a picture made for the test.
            NSString *path = [context.scratch stringByAppendingPathComponent:@"fixture-picture.png"];
            CGImageRef image = SZTestCreateQuadrants(400, 300);
            [SZTestEncode(image, @"public.png", nil) writeToFile:path atomically:YES];
            CGImageRelease(image);
            picture[@"path"] = path;
            SZ_CHECK(SZTestSetPicture(picture, set, directory, &error).kind == SZFriendsPictureKindImage,
                     @"fixture %@: %@", intent[@"id"], error.localizedDescription);
        }
    }
    SZ_CHECK(seen == 3, @"intents.jsonl has %lu set_picture examples, PROTOCOL.md promises three", (unsigned long)seen);
}

void SZRunIntentTests(SZTestContext context) {
    SZFriendsAnimalSet *set = [SZFriendsAnimalSet setWithManifestAtPath:context.manifestPath error:NULL];
    NSString *directory = [context.scratch stringByAppendingPathComponent:@"state/pictures"];
    SZTestAnimalsAndMalformed(set, directory);
    SZTestPhotosAndStorage(context, set, directory);
    SZTestFixtureIntents(context, set, directory);
}
