// The bundled animal set: manifest integrity, the SVG sources, the generated PDFs, malformed manifests, the bundle
// lookup and the random default.

#import <CommonCrypto/CommonDigest.h>

#import "SZFriendsAvatarsTestSupport.h"

@interface SZFriendsAnimalSet (Testing)
+ (NSArray<NSString *> *)bundledManifestCandidates;
@end

// WCAG 2 relative luminance of "#rrggbb".
static double SZTestLuminance(NSString *hex) {
    unsigned value = 0;
    [[NSScanner scannerWithString:[hex substringFromIndex:1]] scanHexInt:&value];
    double channels[3] = {(value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF};
    double linear[3];
    for (int i = 0; i < 3; i++) {
        double c = channels[i] / 255.0;
        linear[i] = c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
    }
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2];
}

double SZTestContrastWithWhite(NSString *hex);
double SZTestContrastWithWhite(NSString *hex) {
    return 1.05 / (SZTestLuminance(hex) + 0.05);
}

static NSString *SZTestSHA256Hex(NSData *data) {
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString string];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

// Renders page 1 of a PDF into a transparent 64 x 64 sRGB bitmap, as AppKit would draw it at 64 pt and 1x.
static NSData *SZTestRenderPDF(NSString *path, CGRect *mediaBox, size_t *pageCount) {
    CGPDFDocumentRef document = CGPDFDocumentCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path]);
    if (!document) return nil;
    *pageCount = CGPDFDocumentGetNumberOfPages(document);
    CGPDFPageRef page = CGPDFDocumentGetPage(document, 1);
    if (!page) {
        CGPDFDocumentRelease(document);
        return nil;
    }
    *mediaBox = CGPDFPageGetBoxRect(page, kCGPDFMediaBox);
    NSMutableData *pixels = [NSMutableData dataWithLength:64 * 64 * 4];
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(pixels.mutableBytes, 64, 64, 8, 64 * 4, space,
                                                 (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextScaleCTM(context, 64 / mediaBox->size.width, 64 / mediaBox->size.height);
    CGContextDrawPDFPage(context, page);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
    CGPDFDocumentRelease(document);
    return pixels;
}

static void SZTestManifestAndFiles(SZTestContext context, SZFriendsAnimalSet *set) {
    // The brief asks for at least 24 animals including geese, doves and bears; the fixtures name set 1.
    SZ_CHECK(set.version == 1, @"set version %ld", (long)set.version);
    SZ_CHECK(set.count >= 24, @"only %ld animals", (long)set.count);
    NSMutableSet *names = [NSMutableSet set];
    for (NSInteger i = 0; i < set.count; i++) [names addObject:[set nameAtIndex:i]];
    SZ_CHECK((NSInteger)names.count == set.count, @"animal names repeat");
    for (NSString *required in @[ @"Goose", @"Dove", @"Bear" ]) {
        SZ_CHECK([names containsObject:required], @"the set has no %@", required);
    }
    // Colors the golden fixtures carry for set 1 (SZFriendsAvatars.h); changing one breaks every view's tests.
    NSDictionary<NSNumber *, NSString *> *fixed = @{
        @0 : @"#5a4a7a", @1 : @"#2f6474", @3 : @"#7a3f4f", @4 : @"#4a6a2f", @5 : @"#7a5a34",
        @7 : @"#3f6b4f", @9 : @"#4f4f86", @10 : @"#5a5a66", @11 : @"#6a4a6a"
    };
    for (NSNumber *index in fixed) {
        SZ_CHECK([[set colorAtIndex:index.integerValue] isEqualToString:fixed[index]], @"index %@ color %@", index,
                 [set colorAtIndex:index.integerValue]);
    }

    NSString *directory = context.manifestPath.stringByDeletingLastPathComponent;
    NSString *checksums = [NSString stringWithContentsOfFile:[directory stringByAppendingPathComponent:
                                                                            @"pdf/sources.sha256"]
                                                    encoding:NSUTF8StringEncoding
                                                       error:NULL];
    SZ_CHECK(checksums.length > 0, @"pdf/sources.sha256 is missing: run tools/regenerate-pdfs.sh");
    NSMutableSet *pdfDigests = [NSMutableSet set];
    for (NSInteger i = 0; i < set.count; i++) {
        NSString *name = [set nameAtIndex:i], *color = [set colorAtIndex:i];
        NSString *svgPath = [set svgPathAtIndex:i], *pdfPath = [set pdfPathAtIndex:i];
        NSString *stem = [NSString stringWithFormat:@"%02ld-%@", (long)i, name.lowercaseString];
        SZ_CHECK([svgPath.lastPathComponent isEqualToString:[stem stringByAppendingString:@".svg"]], @"%@", svgPath);
        SZ_CHECK([pdfPath.lastPathComponent isEqualToString:[stem stringByAppendingString:@".pdf"]], @"%@", pdfPath);
        // A circle color carries white initials when the animal falls back to a placeholder (PROTOCOL.md).
        SZ_CHECK(SZTestContrastWithWhite(color) >= 4.5, @"%@ %@ contrast %.2f", name, color,
                 SZTestContrastWithWhite(color));

        NSData *svgData = [NSData dataWithContentsOfFile:svgPath];
        NSString *svg = [[NSString alloc] initWithData:svgData encoding:NSUTF8StringEncoding];
        SZ_CHECK(svg.length > 0, @"%@ unreadable", svgPath);
        if (svg.length == 0) continue;
        NSString *background =
            [NSString stringWithFormat:@"<circle id=\"bg\" cx=\"32\" cy=\"32\" r=\"32\" fill=\"%@\"/>", color];
        SZ_CHECK([svg containsString:background], @"%@: background circle is not %@", name, color);
        SZ_CHECK([svg containsString:@"width=\"64\" height=\"64\" viewBox=\"0 0 64 64\""], @"%@: canvas", name);
        // Self-contained drawings only: no text (the brief), no fonts, images, scripts or links that a GTK or
        // AppKit renderer might fetch or run.
        NSArray *bannedWords = @[ @"<text", @"<image", @"<script", @"<style", @"<foreignObject", @"href", @"@import" ];
        for (NSString *banned in bannedWords) {
            SZ_CHECK(![svg containsString:banned], @"%@ contains %@", name, banned);
        }
        SZ_CHECK([svg componentsSeparatedByString:@"http"].count == 2, @"%@: only the SVG namespace may be a URL",
                 name);
        // The PDF was regenerated after the last edit of its source.
        NSString *line = [NSString stringWithFormat:@"%@  svg/%@.svg", SZTestSHA256Hex(svgData), stem];
        SZ_CHECK([checksums containsString:line],
                 @"%@ changed since its PDF was generated: run tools/regenerate-pdfs.sh", name);

        CGRect box = CGRectZero;
        size_t pages = 0;
        NSData *pixels = SZTestRenderPDF(pdfPath, &box, &pages);
        SZ_CHECK(pixels != nil, @"%@: PDF does not load", name);
        if (!pixels) continue;
        SZ_CHECK(pages == 1, @"%@: %zu pages", name, pages);
        SZ_CHECK(CGRectEqualToRect(box, CGRectMake(0, 0, 64, 64)), @"%@: media box %@", name,
                 NSStringFromRect(NSRectFromCGRect(box)));
        const uint8_t *p = pixels.bytes;
        // Transparent outside the circle, so it sits on any background; the circle's left edge shows the
        // manifest color, which ties the PDF to the manifest and to the fixtures.
        SZ_CHECK(p[3] == 0, @"%@: corner is not transparent", name);
        unsigned value = 0;
        [[NSScanner scannerWithString:[color substringFromIndex:1]] scanHexInt:&value];
        const uint8_t *edge = p + (32 * 64 + 3) * 4;
        int rgb[3] = {edge[0], edge[1], edge[2]};
        SZ_CHECK(edge[3] == 255 && SZTestNear(rgb, (value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF, 4),
                 @"%@: circle edge is %d,%d,%d,%d, manifest says %@", name, rgb[0], rgb[1], rgb[2], edge[3], color);
        [pdfDigests addObject:SZTestSHA256Hex([NSData dataWithContentsOfFile:pdfPath])];
    }
    SZ_CHECK((NSInteger)pdfDigests.count == set.count, @"two animals share one PDF");
}

static void SZTestMalformedManifests(SZTestContext context) {
    NSString *good = @"{\"index\": 0, \"name\": \"Goose\", \"color\": \"#5a4a7a\", \"svg\": \"svg/00-goose.svg\", "
                     @"\"pdf\": \"pdf/00-goose.pdf\"}";
    NSDictionary<NSString *, NSString *> *cases = @{
        @"not json" : @"{\"set\": 1,",
        @"not an object" : @"[1, 2]",
        @"set zero" : [NSString stringWithFormat:@"{\"set\": 0, \"count\": 1, \"animals\": [%@]}", good],
        @"set boolean" : [NSString stringWithFormat:@"{\"set\": true, \"count\": 1, \"animals\": [%@]}", good],
        @"count mismatch" : [NSString stringWithFormat:@"{\"set\": 1, \"count\": 2, \"animals\": [%@]}", good],
        @"no animals" : @"{\"set\": 1, \"count\": 0, \"animals\": []}",
        @"index gap" : [NSString stringWithFormat:@"{\"set\": 1, \"count\": 1, \"animals\": [%@]}",
                                                  [good stringByReplacingOccurrencesOfString:@"\"index\": 0"
                                                                                  withString:@"\"index\": 1"]],
        @"uppercase color" : [NSString stringWithFormat:@"{\"set\": 1, \"count\": 1, \"animals\": [%@]}",
                                                        [good stringByReplacingOccurrencesOfString:@"#5a4a7a"
                                                                                        withString:@"#5A4A7A"]],
        @"escaping path" : [NSString stringWithFormat:@"{\"set\": 1, \"count\": 1, \"animals\": [%@]}",
                                                      [good stringByReplacingOccurrencesOfString:@"svg/00-goose.svg"
                                                                                      withString:@"../../x.svg"]],
        @"absolute path" : [NSString stringWithFormat:@"{\"set\": 1, \"count\": 1, \"animals\": [%@]}",
                                                      [good stringByReplacingOccurrencesOfString:@"pdf/00-goose.pdf"
                                                                                      withString:@"/etc/x.pdf"]],
        @"empty name" : [NSString stringWithFormat:@"{\"set\": 1, \"count\": 1, \"animals\": [%@]}",
                                                   [good stringByReplacingOccurrencesOfString:@"Goose"
                                                                                   withString:@""]],
    };
    NSString *directory = [context.scratch stringByAppendingPathComponent:@"manifests"];
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil
                                                  error:NULL];
    NSString *valid = [directory stringByAppendingPathComponent:@"valid.json"];
    [[NSString stringWithFormat:@"{\"set\": 1, \"count\": 1, \"animals\": [%@]}", good]
        writeToFile:valid atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    SZFriendsAnimalSet *one = [SZFriendsAnimalSet setWithManifestAtPath:valid error:NULL];
    SZ_CHECK(one.count == 1 && [[one pdfPathAtIndex:0] isEqualToString:[directory stringByAppendingPathComponent:
                                                                                     @"pdf/00-goose.pdf"]],
             @"a minimal valid manifest must load, with paths resolved next to it");
    SZ_CHECK([one nameAtIndex:1] == nil && [one colorAtIndex:-1] == nil && [one svgPathAtIndex:5] == nil,
             @"lookups outside the set must be nil");
    for (NSString *name in cases) {
        NSString *path = [directory stringByAppendingPathComponent:[name stringByAppendingString:@".json"]];
        [cases[name] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NSError *error = nil;
        SZ_CHECK([SZFriendsAnimalSet setWithManifestAtPath:path error:&error] == nil && error != nil,
                 @"manifest with %@ must be rejected", name);
    }
    NSString *huge = [directory stringByAppendingPathComponent:@"huge.json"];
    [[NSMutableData dataWithLength:1024 * 1024 + 1] writeToFile:huge atomically:YES];
    SZ_CHECK([SZFriendsAnimalSet setWithManifestAtPath:huge error:NULL] == nil, @"an oversized manifest must fail");
    SZ_CHECK([SZFriendsAnimalSet setWithManifestAtPath:[directory stringByAppendingPathComponent:@"none.json"]
                                                 error:NULL] == nil,
             @"a missing manifest must fail");
}

static void SZTestBundleLookup(SZTestContext context) {
    unsetenv("SZFRIENDS_AVATARS_MANIFEST");
    NSArray<NSString *> *candidates = [SZFriendsAnimalSet bundledManifestCandidates];
    SZ_CHECK([candidates.firstObject hasSuffix:@"/Contents/Resources/Friends/animals/manifest.json"], @"%@",
             candidates);
    // A relative override would depend on the helper's working directory, so it is ignored.
    setenv("SZFRIENDS_AVATARS_MANIFEST", "animals/manifest.json", 1);
    SZ_CHECK(![[SZFriendsAnimalSet bundledManifestCandidates] containsObject:@"animals/manifest.json"],
             @"relative overrides must be ignored");
    setenv("SZFRIENDS_AVATARS_MANIFEST", context.manifestPath.fileSystemRepresentation, 1);
    SZ_CHECK([[SZFriendsAnimalSet bundledManifestCandidates] isEqual:@[ context.manifestPath ]], @"override");
    SZFriendsAnimalSet *bundled = [SZFriendsAnimalSet bundledSet];
    SZ_CHECK(bundled.count >= 24 && bundled == [SZFriendsAnimalSet bundledSet], @"bundledSet must load once");
    unsetenv("SZFRIENDS_AVATARS_MANIFEST");
}

static void SZTestRandomDefault(SZFriendsAnimalSet *set) {
    SZ_CHECK([set indexForRandomValue:0] == 0, @"0");
    SZ_CHECK([set indexForRandomValue:(uint32_t)set.count + 1] == 1, @"count + 1");
    SZ_CHECK([set indexForRandomValue:UINT32_MAX] == (NSInteger)(UINT32_MAX % (uint32_t)set.count), @"max");
    NSMutableSet *seen = [NSMutableSet set];
    for (int i = 0; i < 2000; i++) {
        SZFriendsPicture *picture = [set randomDefaultPicture];
        SZ_CHECK(picture.kind == SZFriendsPictureKindAnimal && picture.animalSet == set.version &&
                     [set containsIndex:picture.animalIndex],
                 @"%@", picture);
        [seen addObject:@(picture.animalIndex)];
    }
    // 2,000 uniform draws miss one of 24 animals with probability about 24 * (23/24)^2000, effectively never.
    SZ_CHECK((NSInteger)seen.count == set.count, @"random defaults reached only %lu animals",
             (unsigned long)seen.count);
}

void SZRunAnimalSetTests(SZTestContext context) {
    NSError *error = nil;
    SZFriendsAnimalSet *set = [SZFriendsAnimalSet setWithManifestAtPath:context.manifestPath error:&error];
    SZ_CHECK(set != nil, @"manifest: %@", error.localizedDescription);
    if (!set) return;
    SZTestManifestAndFiles(context, set);
    SZTestMalformedManifests(context);
    SZTestBundleLookup(context);
    SZTestRandomDefault(set);
}
