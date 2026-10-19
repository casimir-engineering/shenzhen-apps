// The Objective-C layer: fitting and stepping down to the byte budget, the checks on a friend's thumbnail before
// anything is allocated, the maker's timeout, late answers and concurrency (with scripted renderers), the cache file,
// and real QuickLook renders of the formats the brief names.

#import "SZFriendsThumbnailTestSupport.h"

#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <sys/stat.h>

#import "service/thumbnails/SZFriendsThumbnails.h"
#import "service/thumbnails/szfriends_qoi.h"

// A renderer whose answer, delay and concurrency the test controls.
@interface SZTScriptedRenderer : NSObject <SZFriendsThumbnailRenderer>
@property(nonatomic, nullable) SZFriendsThumbnailPixels *answer;
@property(nonatomic) NSTimeInterval delay; // < 0: never answers, until stopped
@property(atomic) NSInteger running, mostRunning, calls, stops;
@end

@implementation SZTScriptedRenderer

- (dispatch_block_t)renderFileAtPath:(NSString *)path
                      typeIdentifier:(NSString *)typeIdentifier
                             maxSide:(NSUInteger)maxSide
                          completion:(void (^)(SZFriendsThumbnailPixels *))completion {
    (void)path, (void)typeIdentifier, (void)maxSide;
    @synchronized(self) {
        self.calls++;
        self.running++;
        self.mostRunning = MAX(self.mostRunning, self.running);
    }
    // Stopping answers nil at once, as QuickLook reports a cancelled request.
    dispatch_block_t stop = ^{
      @synchronized(self) {
          self.stops++;
      }
      if (self.delay < 0) completion(nil);
    };
    if (self.delay < 0) return stop;
    SZFriendsThumbnailPixels *answer = self.answer;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.delay * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                       @synchronized(self) {
                           self.running--;
                       }
                       completion(answer);
                   });
    return stop;
}

@end

static SZFriendsThumbnailPixels *SZTPixels(NSData *rgba, NSUInteger width, NSUInteger height) {
    return [[SZFriendsThumbnailPixels alloc] initWithRGBA:rgba width:width height:height];
}

static void SZTFitting(void) {
    SZT_CHECK(SZTPixels(SZTSolid(2, 2, 0), 2, 3) == nil && SZTPixels([NSData data], 0, 0) == nil,
              @"pixels must match their size");
    SZFriendsThumbnail *smooth = SZFriendsThumbnailFromPixels(SZTPixels(SZTGradient(300, 150), 300, 150));
    SZT_CHECK(smooth.width == 192 && smooth.height == 96 && smooth.qoi.length <= SZFriendsThumbnailMaxBytes,
              @"a smooth picture fits at 192: %lux%lu", (unsigned long)smooth.width, (unsigned long)smooth.height);
    // Noise at 192 x 192 is about 147 KB of QOI: the sizes step down until it fits.
    SZFriendsThumbnail *noisy = SZFriendsThumbnailFromPixels(SZTPixels(SZTNoise(192, 192, YES), 192, 192));
    SZT_CHECK(noisy != nil && noisy.width < 192 && noisy.width == noisy.height &&
                  noisy.qoi.length <= SZFriendsThumbnailMaxBytes,
              @"noise steps down to %lu px, %lu bytes", (unsigned long)noisy.width, (unsigned long)noisy.qoi.length);
    SZFriendsThumbnail *small = SZFriendsThumbnailFromPixels(SZTPixels(SZTNoise(40, 30, NO), 40, 30));
    SZT_CHECK(small.width == 40 && small.height == 30 && ((const uint8_t *)small.qoi.bytes)[12] == 4,
              @"a small translucent picture keeps its size and its alpha");
    NSUInteger w = 0, h = 0;
    SZT_CHECK(SZTDecodePNG(noisy.png, &w, &h) != nil && w == noisy.width && h == noisy.height,
              @"the PNG this Mac shows is the picture that travels");
}

static void SZTReceived(void) {
    SZFriendsThumbnail *good = SZFriendsThumbnailFromPixels(SZTPixels(SZTGradient(120, 80), 120, 80));
    NSString *reason = nil;
    NSData *png = SZFriendsPNGFromReceivedThumbnail(good.qoi, 120, 80, &reason);
    NSUInteger w = 0, h = 0;
    SZT_CHECK(png != nil && SZTDecodePNG(png, &w, &h) != nil && w == 120 && h == 80, @"accepted: %@", reason);
    SZT_CHECK(SZFriendsPNGFromReceivedThumbnail(good.qoi, 80, 120, &reason) == nil, @"declared size disagrees");
    SZT_CHECK(SZFriendsPNGFromReceivedThumbnail(good.qoi, 193, 80, &reason) == nil, @"declared wider than 192");
    SZT_CHECK(SZFriendsPNGFromReceivedThumbnail(good.qoi, 0, 80, &reason) == nil, @"declared zero");
    NSMutableData *big = [good.qoi mutableCopy];
    big.length = SZFriendsThumbnailMaxBytes + 1;
    SZT_CHECK(SZFriendsPNGFromReceivedThumbnail(big, 120, 80, &reason) == nil, @"over 64,000 bytes");
    SZT_CHECK(SZFriendsPNGFromReceivedThumbnail([good.qoi subdataWithRange:NSMakeRange(0, 20)], 120, 80, &reason) ==
                  nil,
              @"shorter than any stream");
    // A header claiming 4,000 x 4,000 is refused on the header: nothing that size is ever allocated.
    NSMutableData *huge = [good.qoi mutableCopy];
    uint8_t dims[8] = {0, 0, 0x0f, 0xa0, 0, 0, 0x0f, 0xa0};
    memcpy((uint8_t *)huge.mutableBytes + 4, dims, 8);
    SZT_CHECK(SZFriendsPNGFromReceivedThumbnail(huge, 4000, 4000, &reason) == nil, @"oversized dimensions");
    SZT_CHECK(SZFriendsPNGFromReceivedThumbnail(huge, 120, 80, &reason) == nil, @"header disagrees with frame");
    NSMutableData *cut = [good.qoi mutableCopy];
    [cut replaceBytesInRange:NSMakeRange(cut.length - 12, 4) withBytes:NULL length:0];
    SZT_CHECK(SZFriendsPNGFromReceivedThumbnail(cut, 120, 80, &reason) == nil && reason.length > 0,
              @"malformed stream: %@", reason);
}

static void SZTMakerScripted(void) {
    dispatch_queue_t queue = dispatch_queue_create("szft.maker", DISPATCH_QUEUE_SERIAL);
    static char queueKey;
    dispatch_queue_set_specific(queue, &queueKey, &queueKey, NULL);
    SZTScriptedRenderer *renderer = [[SZTScriptedRenderer alloc] init];
    renderer.answer = SZTPixels(SZTGradient(400, 300), 400, 300);
    renderer.delay = 0.05;
    SZFriendsThumbnailMaker *maker = [[SZFriendsThumbnailMaker alloc] initWithRenderer:renderer timeout:0.5];
    __block NSInteger answers = 0, thumbnails = 0;
    __block BOOL onQueue = YES;
    for (int i = 0; i < 6; i++) {
        [maker makeThumbnailOfFileAtPath:@"/nonexistent" typeIdentifier:nil queue:queue
                              completion:^(SZFriendsThumbnail *thumbnail) {
                                  onQueue = onQueue && dispatch_get_specific(&queueKey) == &queueKey;
                                  answers++;
                                  if (thumbnail.width == 192 && thumbnail.height == 144) thumbnails++;
                              }];
    }
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while ([deadline timeIntervalSinceNow] > 0) {
        __block NSInteger seen = 0;
        dispatch_sync(queue, ^{ seen = answers; });
        if (seen == 6) break;
        [NSThread sleepForTimeInterval:0.02];
    }
    dispatch_sync(queue, ^{
        SZT_CHECK(answers == 6 && thumbnails == 6 && onQueue, @"six thumbnails on the queue: %ld", (long)thumbnails);
    });
    SZT_CHECK(renderer.mostRunning <= 2, @"at most two renders at a time, saw %ld", (long)renderer.mostRunning);
    SZT_CHECK(renderer.stops == 0, @"a render that answers in time is never stopped: %ld", (long)renderer.stops);

    // Silent and late renderers: nil once the timeout passes, and the late picture is never delivered.
    for (NSNumber *delay in @[ @(-1), @0.6 ]) {
        SZTScriptedRenderer *slow = [[SZTScriptedRenderer alloc] init];
        slow.answer = SZTPixels(SZTGradient(10, 10), 10, 10);
        slow.delay = delay.doubleValue;
        SZFriendsThumbnailMaker *patient = [[SZFriendsThumbnailMaker alloc] initWithRenderer:slow timeout:0.2];
        __block NSInteger calls = 0;
        __block SZFriendsThumbnail *got = (SZFriendsThumbnail *)[NSNull null];
        NSDate *start = [NSDate date];
        __block NSTimeInterval took = 0;
        [patient makeThumbnailOfFileAtPath:@"/nonexistent" typeIdentifier:nil queue:queue
                                completion:^(SZFriendsThumbnail *thumbnail) {
                                    calls++;
                                    got = thumbnail;
                                    took = -start.timeIntervalSinceNow;
                                }];
        [NSThread sleepForTimeInterval:1.0];
        dispatch_sync(queue, ^{
            SZT_CHECK(calls == 1 && got == nil && took < 0.5,
                      @"delay %@: one nil after the timeout (%ld calls, %.2f s)", delay, (long)calls, took);
        });
        // Security review, wave 6a: the render went on after the timeout. It is stopped, once.
        SZT_CHECK(slow.stops == 1, @"delay %@: the render is stopped when the timeout runs out (%ld)", delay,
                  (long)slow.stops);
    }
    // QuickLook's renderer hands back what stops its request.
    dispatch_block_t stop = [[[SZFriendsQuickLookRenderer alloc] init]
        renderFileAtPath:@"/nonexistent/szfriends.pdf"
          typeIdentifier:nil
                 maxSide:SZFriendsThumbnailMaxSide
              completion:^(SZFriendsThumbnailPixels *pixels) {
                  (void)pixels;
              }];
    SZT_CHECK(stop != nil, @"a QuickLook render can be stopped");
    if (stop) stop();
}

static void SZTFilesAndTypes(void) {
    NSString *scratch = SZTScratchDirectory();
    NSString *directory = [scratch stringByAppendingPathComponent:@"thumbnails"];
    NSData *png = [@"not really a png" dataUsingEncoding:NSUTF8StringEncoding];
    NSString *first = SZFriendsWriteThumbnailFile(png, directory, NULL);
    NSString *second = SZFriendsWriteThumbnailFile(png, directory, NULL);
    struct stat info = {0}, dir = {0};
    SZT_CHECK(first && second && ![first isEqual:second], @"fresh names: %@ %@", first, second);
    SZT_CHECK(stat(first.fileSystemRepresentation, &info) == 0 && (info.st_mode & 0777) == 0600, @"0600 file");
    SZT_CHECK(stat(directory.fileSystemRepresentation, &dir) == 0 && (dir.st_mode & 0777) == 0700, @"0700 folder");
    SZT_CHECK([[NSData dataWithContentsOfFile:first] isEqualToData:png], @"the bytes written");
    NSString *link = [scratch stringByAppendingPathComponent:@"elsewhere"];
    symlink(scratch.fileSystemRepresentation, link.fileSystemRepresentation);
    NSError *error = nil;
    SZT_CHECK(SZFriendsWriteThumbnailFile(png, link, &error) == nil && error != nil, @"a symlinked folder is refused");
    SZT_CHECK([SZFriendsTypeIdentifierForFileName(@"Site photos.pdf") isEqual:@"com.adobe.pdf"], @"PDF type");
    SZT_CHECK(SZFriendsTypeIdentifierForFileName(@"README") == nil, @"no extension");
    SZT_CHECK(SZFriendsTypeIdentifierForFileName(@"blob.zzqqxx") == nil, @"an extension nothing knows");
}

void SZTRunThumbnailTests(void) {
    SZTFitting();
    SZTReceived();
    SZTMakerScripted();
    SZTFilesAndTypes();
}

#pragma mark - QuickLook

static void SZTWritePDF(NSString *path) {
    CGRect box = CGRectMake(0, 0, 595, 842); // A4 portrait: the thumbnail must be taller than wide
    CGContextRef pdf = CGPDFContextCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], &box, NULL);
    CGPDFContextBeginPage(pdf, NULL);
    CGContextSetRGBFillColor(pdf, 0.85, 0.1, 0.1, 1);
    CGContextFillRect(pdf, box);
    CGPDFContextEndPage(pdf);
    CGPDFContextClose(pdf);
    CGContextRelease(pdf);
}

static void SZTWritePNG(NSString *path) {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context =
        CGBitmapContextCreate(NULL, 640, 360, 8, 0, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextSetRGBFillColor(context, 0.1, 0.2, 0.9, 1);
    CGContextFillRect(context, CGRectMake(0, 0, 640, 360));
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGImageDestinationRef destination =
        CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(destination, image, NULL);
    CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CGImageRelease(image);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
}

static SZFriendsThumbnail *_Nullable SZTRender(SZFriendsThumbnailMaker *maker, NSString *path, NSString *type,
                                               BOOL *answered) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block SZFriendsThumbnail *result = nil;
    [maker makeThumbnailOfFileAtPath:path typeIdentifier:type
                               queue:dispatch_get_global_queue(QOS_CLASS_UTILITY, 0)
                          completion:^(SZFriendsThumbnail *thumbnail) {
                              result = thumbnail;
                              dispatch_semaphore_signal(done);
                          }];
    *answered = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0;
    return result;
}

void SZTRunRenderTests(void) {
    NSString *scratch = SZTScratchDirectory();
    NSString *(^file)(NSString *) = ^NSString *(NSString *name) {
        return [scratch stringByAppendingPathComponent:name];
    };
    SZTWritePDF(file(@"Bracket drawing.pdf"));
    SZTWritePNG(file(@"Site photo.png"));
    [@"# Delivery dates\n\n| Part | Date |\n|---|---|\n| Bracket | 14 Oct |\n" writeToFile:file(@"Notes.md")
                                                                              atomically:YES
                                                                                encoding:NSUTF8StringEncoding
                                                                                   error:NULL];
    [@"Supplier call notes\nPages 3-5 changed.\n" writeToFile:file(@"Call.txt") atomically:YES
                                                      encoding:NSUTF8StringEncoding error:NULL];
    [SZTNoise(64, 64, NO) writeToFile:file(@"Firmware.bin") atomically:YES];
    // An outgoing snapshot is stored without its extension; the type comes from the name the friend sees.
    [[NSFileManager defaultManager] copyItemAtPath:file(@"Bracket drawing.pdf") toPath:file(@"0a1b2c3d") error:NULL];
    SZFriendsThumbnailMaker *maker = [[SZFriendsThumbnailMaker alloc] init];
    struct {
        NSString *name, *type;
        BOOL expected;
    } cases[] = {{@"Bracket drawing.pdf", nil, YES}, {@"Notes.md", nil, YES},     {@"Site photo.png", nil, YES},
                 {@"Call.txt", nil, YES},           {@"Firmware.bin", nil, NO}, {@"0a1b2c3d", @"com.adobe.pdf", YES}};
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        BOOL answered = NO;
        NSDate *start = [NSDate date];
        SZFriendsThumbnail *thumbnail = SZTRender(maker, file(cases[i].name), cases[i].type, &answered);
        NSTimeInterval took = -start.timeIntervalSinceNow;
        SZT_CHECK(answered && took < SZFriendsThumbnailRenderTimeout + 0.5, @"%@ answered in %.2f s", cases[i].name,
                  took);
        SZT_CHECK((thumbnail != nil) == cases[i].expected, @"%@: %@ thumbnail", cases[i].name,
                  thumbnail ? @"a" : @"no");
        if (thumbnail == nil) continue;
        SZT_CHECK(MAX(thumbnail.width, thumbnail.height) <= SZFriendsThumbnailMaxSide &&
                      thumbnail.qoi.length <= SZFriendsThumbnailMaxBytes,
                  @"%@ within the limits: %lux%lu, %lu bytes", cases[i].name, (unsigned long)thumbnail.width,
                  (unsigned long)thumbnail.height, (unsigned long)thumbnail.qoi.length);
        NSString *reason = nil;
        SZT_CHECK(SZFriendsPNGFromReceivedThumbnail(thumbnail.qoi, thumbnail.width, thumbnail.height, &reason) != nil,
                  @"%@: the recipient's checks accept what we send (%@)", cases[i].name, reason);
    }
    BOOL answered = NO;
    SZFriendsThumbnail *page = SZTRender(maker, file(@"Bracket drawing.pdf"), nil, &answered);
    NSUInteger w = 0, h = 0;
    NSData *pixels = page ? SZTDecodePNG(page.png, &w, &h) : nil;
    const uint8_t *centre = pixels.length ? (const uint8_t *)pixels.bytes + ((h / 2) * w + w / 2) * 4 : NULL;
    SZT_CHECK(page.height > page.width && centre && centre[0] > 150 && centre[1] < 80 && centre[2] < 80,
              @"the PDF's first page, portrait and red in the middle");
}
