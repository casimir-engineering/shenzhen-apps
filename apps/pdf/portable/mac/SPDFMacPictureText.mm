// Text found in pictures: see SPDFMacPictureText.h.
#import "SPDFMacPictureText.h"
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <Vision/Vision.h>
#import <os/lock.h>
#import <sys/stat.h>
#include "shenzhen_pdf_core.h"
#include "spdf_picture_text.h"

NSString* const SPDFMacOCREngineMacOS = @"macos";
NSString* const SPDFMacOCREngineOpenSource = @"open-source";
static NSString* const EngineKey = @"SPDFOCREngine";
static NSString* const LanguageKey = @"SPDFOCROpenSourceLanguage";

BOOL SPDFMacPictureTextCandidatePath(NSString* path) {
    static NSSet<NSString*>* extensions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        extensions = [NSSet setWithArray:@[
            @"png", @"jpg", @"jpeg", @"jpe", @"jfif", @"jfif-tbnl", @"bmp", @"gif", @"tif", @"tiff", @"jp2", @"jpx",
            @"j2k", @"jb2", @"jbig2", @"pnm", @"pam", @"pbm", @"pgm", @"ppm", @"psd", @"webp", @"heic", @"heif",
            // Camera RAW photos, wherever the reader learns to open them.
            @"dng", @"cr2", @"cr3", @"crw", @"nef", @"nrw", @"arw", @"srf", @"sr2", @"orf", @"raf", @"rw2", @"rwl",
            @"pef", @"srw", @"x3f", @"3fr", @"fff", @"iiq", @"mos", @"mef", @"erf", @"kdc", @"dcr"]];
    });
    return path.length && [extensions containsObject:path.pathExtension.lowercaseString];
}

NSString* SPDFMacOCREngine(void) {
    NSString* engine = [NSUserDefaults.standardUserDefaults stringForKey:EngineKey];
    return [engine isEqualToString:SPDFMacOCREngineOpenSource] ? SPDFMacOCREngineOpenSource : SPDFMacOCREngineMacOS;
}
void SPDFMacSetOCREngine(NSString* engine) {
    [NSUserDefaults.standardUserDefaults setObject:engine forKey:EngineKey];
}
NSString* SPDFMacOCROpenSourceLanguage(void) {
    NSString* language = [NSUserDefaults.standardUserDefaults stringForKey:LanguageKey];
    return language.length ? language : @"chi_sim+eng";
}
void SPDFMacSetOCROpenSourceLanguage(NSString* language) {
    if (language.length) [NSUserDefaults.standardUserDefaults setObject:language forKey:LanguageKey];
}

#pragma mark Reading

static NSArray* Box(CGRect r) { return @[@(round(r.origin.x)), @(round(r.origin.y)), @(round(r.size.width)), @(round(r.size.height))]; }
static CGRect FromBox(NSArray* box) {
    if (![box isKindOfClass:NSArray.class] || box.count != 4) return CGRectNull;
    return CGRectMake([box[0] doubleValue], [box[1] doubleValue], [box[2] doubleValue], [box[3] doubleValue]);
}

// Vision's boxes are fractions of the picture from its bottom left; ours are pixels from the top left.
static CGRect PixelRect(CGRect normalized, size_t width, size_t height) {
    return CGRectMake(normalized.origin.x * width, (1 - normalized.origin.y - normalized.size.height) * height,
                      normalized.size.width * width, normalized.size.height * height);
}

static NSArray* VisionLines(CGImageRef image, NSError** error) API_AVAILABLE(macos(10.15)) {
    VNRecognizeTextRequest* request = [[VNRecognizeTextRequest alloc] init];
    request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    request.usesLanguageCorrection = YES;
    if (@available(macOS 13.0, *)) {
        // Any language Vision reads, found from the picture itself (a Chinese label beside English part numbers).
        request.automaticallyDetectsLanguage = YES;
    }
    VNImageRequestHandler* handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
    if (![handler performRequests:@[request] error:error]) return nil;
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    NSMutableArray* lines = [NSMutableArray array];
    for (VNRecognizedTextObservation* observation in request.results) {
        VNRecognizedText* best = [observation topCandidates:1].firstObject;
        NSString* string = [best.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!string.length) continue;
        NSString* full = best.string;
        CGRect lineRect = PixelRect(observation.boundingBox, width, height);
        // Words are what the spaces separate (a Chinese line without spaces is one word): each gets its own box, so
        // a selection starts and ends on the letters.
        NSMutableArray* words = [NSMutableArray array];
        __block NSUInteger start = NSNotFound;
        void (^addWord)(NSRange) = ^(NSRange range) {
            NSError* boxError = nil;
            VNRectangleObservation* box = [best boundingBoxForRange:range error:&boxError];
            CGRect rect = box ? PixelRect(box.boundingBox, width, height) : CGRectNull;
            if (CGRectIsNull(rect) || rect.size.width <= 0) return;
            [words addObject:@{@"text": [full substringWithRange:range], @"box": Box(rect)}];
        };
        for (NSUInteger i = 0; i <= full.length; ++i) {
            BOOL space = i == full.length ||
                [NSCharacterSet.whitespaceCharacterSet characterIsMember:[full characterAtIndex:i]];
            if (!space && start == NSNotFound) start = i;
            if (space && start != NSNotFound) { addWord(NSMakeRange(start, i - start)); start = NSNotFound; }
        }
        if (!words.count) [words addObject:@{@"text": string, @"box": Box(lineRect)}];
        [lines addObject:@{@"text": string, @"box": Box(lineRect), @"words": words}];
    }
    return lines;
}

// Tesseract's TSV: one row per word (level 5) with its block, paragraph and line numbers and its box in pixels.
static NSArray* TesseractLines(CGImageRef image, NSString* tesseract, NSDictionary* environment, NSString* language,
                               NSError** error) {
    NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSString* input = [directory stringByAppendingPathComponent:@"page.png"];
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)[NSURL fileURLWithPath:input], CFSTR("public.png"), 1, NULL);
    BOOL written = NO;
    if (destination) {
        CGImageDestinationAddImage(destination, image, NULL);
        written = CGImageDestinationFinalize(destination);
        CFRelease(destination);
    }
    NSArray* lines = nil;
    if (written) {
        NSTask* task = [NSTask new];
        task.executableURL = [NSURL fileURLWithPath:tesseract];
        task.arguments = @[input, @"stdout", @"-l", language, @"tsv"];
        if (environment.count) task.environment = environment;
        NSPipe* output = [NSPipe pipe];
        task.standardOutput = output;
        task.standardError = [NSFileHandle fileHandleWithNullDevice];
        if ([task launchAndReturnError:error]) {
            NSData* data = [output.fileHandleForReading readDataToEndOfFile];
            [task waitUntilExit];
            if (task.terminationStatus == 0) {
                NSString* tsv = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
                NSMutableArray* found = [NSMutableArray array];
                NSMutableDictionary* current = nil; NSString* currentKey = nil;
                for (NSString* row in [tsv componentsSeparatedByString:@"\n"]) {
                    NSArray* cells = [row componentsSeparatedByString:@"\t"];
                    if (cells.count < 12 || [cells[0] integerValue] != 5) continue;
                    NSString* text = [cells[11] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                    if (!text.length || [cells[10] doubleValue] < 0) continue;
                    CGRect rect = CGRectMake([cells[6] doubleValue], [cells[7] doubleValue], [cells[8] doubleValue],
                                             [cells[9] doubleValue]);
                    NSString* key = [NSString stringWithFormat:@"%@.%@.%@", cells[2], cells[3], cells[4]];
                    if (![key isEqualToString:currentKey]) {
                        current = [@{@"words": [NSMutableArray array], @"rect": [NSValue valueWithRect:rect]} mutableCopy];
                        [found addObject:current]; currentKey = key;
                    }
                    [current[@"words"] addObject:@{@"text": text, @"box": Box(rect)}];
                    current[@"rect"] = [NSValue valueWithRect:NSUnionRect([current[@"rect"] rectValue], rect)];
                }
                NSMutableArray* result = [NSMutableArray array];
                for (NSDictionary* line in found) {
                    NSMutableArray* texts = [NSMutableArray array];
                    for (NSDictionary* word in line[@"words"]) [texts addObject:word[@"text"]];
                    // Tesseract puts a space between Chinese characters it reads as words; a line of them reads as one.
                    [result addObject:@{@"text": [texts componentsJoinedByString:@" "],
                                        @"box": Box([line[@"rect"] rectValue]), @"words": line[@"words"]}];
                }
                lines = result;
            } else if (error) {
                *error = [NSError errorWithDomain:@"ShenzhenPDF.OCR" code:2 userInfo:@{
                    NSLocalizedDescriptionKey: @"Tesseract couldn't read this picture."}];
            }
        }
    }
    [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
    return lines;
}

static NSError* ReadError(NSString* message) {
    return [NSError errorWithDomain:@"ShenzhenPDF.OCR" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

NSDictionary* SPDFMacRecognizeText(NSString* path, NSString* engine, NSString* tesseract,
                                   NSDictionary<NSString*, NSString*>* environment,
                                   NSIndexSet* pages, NSUInteger maxPages, BOOL (^cancelled)(void), NSError** error) {
    BOOL openSource = [engine isEqualToString:SPDFMacOCREngineOpenSource] && tesseract.length;
    if (@available(macOS 10.15, *)) {} else if (!openSource) {
        if (error) *error = ReadError(@"Text recognition needs macOS 10.15 or later.");
        return nil;
    }
    char message[1024] = {};
    spdf_document* document = spdf_open(path.fileSystemRepresentation, message, sizeof(message));
    if (!document) {
        if (error) *error = ReadError(message[0] ? @(message) : @"The document couldn't be opened.");
        return nil;
    }
    NSMutableArray* found = [NSMutableArray array];
    NSError* failure = nil;
    int count = spdf_page_count(document);
    for (int index = 0; index < count && (NSUInteger)index < maxPages; ++index) {
        if (cancelled && cancelled()) { failure = ReadError(@"Stopped."); break; }
        if (pages && ![pages containsIndex:(NSUInteger)index]) continue;
        @autoreleasepool {
            float width = 0, height = 0;
            if (!spdf_page_size(document, index, &width, &height, message, sizeof(message)) || width <= 0 || height <= 0)
                continue;
            // A page or a small picture three times over (216 dpi for a page: small print reads), a larger one
            // twice; 4096 pixels on the long side at most, already more than the recognisers look at.
            float longest = MAX(width, height);
            float zoom = MIN(4096.0f / longest, longest < 1500 ? 3.0f : 2.0f);
            spdf_bitmap bitmap = {};
            if (!spdf_render_page_rgba(document, index, zoom, &bitmap, message, sizeof(message))) continue;
            NSData* pixels = [NSData dataWithBytesNoCopy:bitmap.rgba length:(NSUInteger)bitmap.stride * bitmap.height
                                            freeWhenDone:NO];
            CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
            CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            CGImageRef image = CGImageCreate((size_t)bitmap.width, (size_t)bitmap.height, 8, 32, (size_t)bitmap.stride,
                space, kCGBitmapByteOrderDefault | kCGImageAlphaNoneSkipLast, provider, NULL, false,
                kCGRenderingIntentDefault);
            CGColorSpaceRelease(space);
            CGDataProviderRelease(provider);
            NSArray* lines = nil;
            NSError* pageError = nil;
            if (image) {
                if (openSource)
                    lines = TesseractLines(image, tesseract, environment, SPDFMacOCROpenSourceLanguage(), &pageError);
                else if (@available(macOS 10.15, *))
                    lines = VisionLines(image, &pageError);
                CGImageRelease(image);
            }
            int bitmapWidth = bitmap.width, bitmapHeight = bitmap.height;
            spdf_free_bitmap(&bitmap);
            if (!lines) { failure = pageError ?: ReadError(@"Text recognition failed."); break; }
            if (lines.count)
                [found addObject:@{@"page": @(index + 1), @"width": @(bitmapWidth), @"height": @(bitmapHeight),
                                   @"lines": lines}];
        }
    }
    spdf_close(document);
    if (failure) {
        if (error) *error = failure;
        return nil;
    }
    return @{@"engine": openSource ? SPDFMacOCREngineOpenSource : SPDFMacOCREngineMacOS, @"pages": found};
}

NSString* SPDFMacRecognizedPageText(NSDictionary* page) {
    NSMutableArray* texts = [NSMutableArray array];
    for (NSDictionary* line in page[@"lines"])
        if ([line[@"text"] isKindOfClass:NSString.class]) [texts addObject:line[@"text"]];
    return [texts componentsJoinedByString:@"\n"];
}

#pragma mark Laid over the picture

static os_unfair_lock knownLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSString*, NSDictionary*>* known;  // path -> {stamp, recognized}

static NSString* Stamp(NSString* path) {
    struct stat info = {};
    if (stat(path.fileSystemRepresentation, &info) != 0) return nil;
    return [NSString stringWithFormat:@"%llu:%llu:%lld:%ld", (unsigned long long)info.st_ino, (unsigned long long)info.st_size,
            (long long)info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec];
}

void SPDFMacPictureTextRemember(NSString* path, NSDictionary* recognized) {
    if (!path.length) return;
    NSString* stamp = recognized ? Stamp(path) : nil;
    os_unfair_lock_lock(&knownLock);
    if (!known) known = [NSMutableDictionary dictionary];
    if (stamp && SPDFMacRecognizedHasText(recognized)) known[path] = @{@"stamp": stamp, @"recognized": recognized};
    else [known removeObjectForKey:path];
    os_unfair_lock_unlock(&knownLock);
}

NSDictionary* SPDFMacPictureTextKnown(NSString* path) {
    if (!path.length) return nil;
    os_unfair_lock_lock(&knownLock);
    NSDictionary* entry = known[path];
    os_unfair_lock_unlock(&knownLock);
    if (!entry || ![entry[@"stamp"] isEqualToString:Stamp(path) ?: @""]) return nil;
    return entry[@"recognized"];
}

static int Wants(const char* path) {
    @autoreleasepool { return path && SPDFMacPictureTextCandidatePath(@(path)); }
}

// The words of one page as fractions of it, in one malloc'd block with their texts (spdf_picture_text_lookup).
static int Lookup(const char* path, int pageIndex, spdf_picture_word** out) {
    *out = NULL;
    @autoreleasepool {
        NSDictionary* recognized = path ? SPDFMacPictureTextKnown(@(path)) : nil;
        NSDictionary* page = nil;
        for (NSDictionary* candidate in recognized[@"pages"])
            if ([candidate[@"page"] integerValue] == pageIndex + 1) { page = candidate; break; }
        double width = [page[@"width"] doubleValue], height = [page[@"height"] doubleValue];
        if (!page || width <= 0 || height <= 0) return 0;
        NSMutableArray<NSDictionary*>* words = [NSMutableArray array];
        NSMutableArray<NSNumber*>* lineNumbers = [NSMutableArray array];
        size_t textBytes = 0;
        int lineNumber = 0;
        for (NSDictionary* line in page[@"lines"]) {
            for (NSDictionary* word in line[@"words"]) {
                const char* text = [word[@"text"] isKindOfClass:NSString.class] ? [word[@"text"] UTF8String] : NULL;
                if (!text || !*text || CGRectIsNull(FromBox(word[@"box"]))) continue;
                [words addObject:word]; [lineNumbers addObject:@(lineNumber)];
                textBytes += strlen(text) + 1;
            }
            ++lineNumber;
        }
        if (!words.count) return 0;
        size_t head = sizeof(spdf_picture_word) * words.count;
        spdf_picture_word* block = (spdf_picture_word*)malloc(head + textBytes);
        if (!block) return 0;
        char* texts = (char*)block + head;
        for (NSUInteger i = 0; i < words.count; ++i) {
            CGRect box = FromBox(words[i][@"box"]);
            const char* text = [words[i][@"text"] UTF8String];
            size_t length = strlen(text) + 1;
            memcpy(texts, text, length);
            block[i] = (spdf_picture_word){(float)(box.origin.x / width), (float)(box.origin.y / height),
                (float)(CGRectGetMaxX(box) / width), (float)(CGRectGetMaxY(box) / height), lineNumbers[i].intValue, texts};
            texts += length;
        }
        *out = block;
        return (int)words.count;
    }
}

// Before main(): the launch prerender, the szpdf tool and every window open documents through spdf_open.
__attribute__((constructor)) static void InstallAtLoad(void) { spdf_picture_text_install(Wants, Lookup); }
