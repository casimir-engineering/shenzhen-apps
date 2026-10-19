#import "SPDFMacAgentPDFInspection.h"
#import "shenzhen_pdf_core.h"
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <sys/stat.h>
#import <unistd.h>

static NSDictionary* failure(NSString* message, NSError** error) {
    if (error) *error = [NSError errorWithDomain:@"ShenzhenPDF.Agent" code:1
        userInfo:@{NSLocalizedDescriptionKey:message}];
    return nil;
}
struct PDFHandle {
    spdf_document* value = nullptr;
    ~PDFHandle() { if (value) spdf_close(value); }
};
struct PDFLines {
    spdf_text_lines value = {};
    ~PDFLines() { spdf_free_text_lines(&value); }
};
struct PDFBitmap {
    spdf_bitmap value = {};
    ~PDFBitmap() { spdf_free_bitmap(&value); }
};

static NSString* coreError(const char* error) {
    return error[0] ? [NSString stringWithUTF8String:error] : @"Could not read the PDF page.";
}
static BOOL finiteRect(spdf_rect rect) {
    return isfinite(rect.x0) && isfinite(rect.y0) && isfinite(rect.x1) && isfinite(rect.y1) &&
        rect.x1 >= rect.x0 && rect.y1 >= rect.y0;
}
static NSDictionary* rectJSON(spdf_rect rect) {
    return @{@"x":@(rect.x0), @"y":@(rect.y0), @"width":@(rect.x1 - rect.x0), @"height":@(rect.y1 - rect.y0)};
}

static BOOL writePNG(spdf_document* document, NSUInteger page, NSString* path, NSError** error) {
    char message[1024] = {};
    PDFBitmap bitmap;
    if (!spdf_render_page_rgba_opts(document, (int)page, 1, SPDF_RENDER_DEFAULT, NULL,
            &bitmap.value, message, sizeof(message))) {
        failure(coreError(message), error);
        return NO;
    }
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, bitmap.value.rgba,
        (size_t)bitmap.value.stride * bitmap.value.height, NULL);
    CGImageRef image = CGImageCreate(bitmap.value.width, bitmap.value.height, 8, 32, bitmap.value.stride,
        space, kCGImageAlphaLast | kCGBitmapByteOrder32Big, provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(space);
    CGDataProviderRelease(provider);
    CGImageDestinationRef destination = image ? CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, NULL) : NULL;
    BOOL written = NO;
    if (destination) {
        CGImageDestinationAddImage(destination, image, NULL);
        written = CGImageDestinationFinalize(destination);
        CFRelease(destination);
    }
    if (image) CGImageRelease(image);
    if (!written) failure(@"Could not write PDF page image.", error);
    return written;
}

NSDictionary* SPDFMacAgentInspectPDF(NSDictionary* command, NSError** error) {
    NSString* path = command[@"path"];
    if (![path isKindOfClass:NSString.class] || !path.isAbsolutePath ||
        ![path.pathExtension.lowercaseString isEqualToString:@"pdf"])
        return failure(@"PDF inspection requires an absolute .pdf path.", error);
    if (command[@"paper"]) return failure(@"PDF pages have fixed geometry; paper overrides apply only to Markdown.", error);
    NSNumber* selected = command[@"page"];
    if (selected && (![selected isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)selected) == CFBooleanGetTypeID() || !isfinite(selected.doubleValue) ||
        selected.doubleValue < 1 || selected.doubleValue > 1000000 || floor(selected.doubleValue) != selected.doubleValue))
        return failure(@"page must be a positive integer.", error);
    NSString* directory = command[@"renderDirectory"];
    if (directory && (![directory isKindOfClass:NSString.class] || !directory.isAbsolutePath))
        return failure(@"Render directory must be an absolute path.", error);
    struct stat info;
    if (stat(path.fileSystemRepresentation, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size <= 0)
        return failure(@"PDF must be a readable regular file.", error);
    if ((unsigned long long)info.st_size > 256ULL * 1024 * 1024)
        return failure(@"PDF exceeds the 256 MiB input budget.", error);
    char message[1024] = {};
    PDFHandle document;
    document.value = spdf_open(path.fileSystemRepresentation, message, sizeof(message));
    if (!document.value) return failure(coreError(message), error);
    int count = spdf_page_count(document.value);
    if (count <= 0) return failure(@"PDF has no pages.", error);
    NSUInteger first = selected ? selected.unsignedIntegerValue - 1 : 0;
    if (first >= (NSUInteger)count) return failure(@"Page is outside the document.", error);
    NSUInteger end = selected ? first + 1 : MIN((NSUInteger)count, (NSUInteger)100);
    NSMutableArray* pages = [NSMutableArray array];
    NSMutableArray* diagnostics = [NSMutableArray array];
    NSUInteger totalLines = 0, totalBytes = 0;
    unsigned long long totalPixels = 0;
    for (NSUInteger index = first; index < end; ++index) {
        {
            float width = 0, height = 0;
            if (!spdf_page_size(document.value, (int)index, &width, &height, message, sizeof(message)))
                return failure(coreError(message), error);
            if (!isfinite(width) || !isfinite(height) || width <= 0 || height <= 0)
                return failure(@"PDF has invalid page dimensions.", error);
            if (directory) {
                if (ceil(width) > 4096 || ceil(height) > 4096)
                    return failure(@"PDF paper exceeds the 4096-pixel PNG dimension budget.", error);
                totalPixels += (unsigned long long)ceil(width) * (unsigned long long)ceil(height);
                if (totalPixels > 100000000)
                    return failure(@"PDF render exceeds 100 million pixels; select one page.", error);
            }
            PDFLines extracted;
            if (!spdf_extract_page_text_lines(document.value, (int)index, &extracted.value, message, sizeof(message)))
                return failure(coreError(message), error);
            totalLines += MAX(0, extracted.value.count);
            if (totalLines > 32000) return failure(@"PDF report exceeds 32,000 text lines; select one page.", error);
            NSMutableString* text = [NSMutableString string];
            NSMutableArray* lines = [NSMutableArray array];
            for (int lineIndex = 0; lineIndex < extracted.value.count; ++lineIndex) {
                spdf_text_line line = extracted.value.items[lineIndex];
                NSUInteger bytes = line.text ? strlen(line.text) : 0;
                totalBytes += bytes;
                if (totalBytes > 8 * 1024 * 1024)
                    return failure(@"PDF report exceeds 8 MiB of text; select one page.", error);
                NSString* value = line.text ? [NSString stringWithUTF8String:line.text] : @"";
                if (!value) return failure(@"PDF text extraction returned invalid UTF-8.", error);
                NSRange range = NSMakeRange(text.length, value.length);
                [text appendString:value];
                [text appendString:@"\n"];
                NSMutableDictionary* entry = [@{@"range":@{@"location":@(range.location), @"length":@(range.length)}} mutableCopy];
                if (finiteRect(line.bounds)) entry[@"rect"] = rectJSON(line.bounds);
                else {
                    entry[@"rect"] = NSNull.null;
                    [diagnostics addObject:@{@"kind":@"invalid-text-geometry", @"page":@(index + 1), @"line":@(lineIndex)}];
                }
                if (isfinite(line.font_size) && line.font_size > 0) entry[@"fontSize"] = @(line.font_size);
                [lines addObject:entry];
            }
            [pages addObject:@{@"page":@(index + 1), @"width":@(width), @"height":@(height),
                @"canonicalText":text, @"lines":lines, @"imageBacked":@(extracted.value.image_backed != 0)}];
        }
    }
    NSMutableDictionary* result = [@{@"schemaVersion":@1, @"format":@"pdf", @"path":path,
        @"pageCount":@(count), @"inspectedPageCount":@(end - first), @"truncated":@(!selected && end < (NSUInteger)count),
        @"coordinateSpace":@"page-canonical-utf16", @"geometrySpace":@"page-top-left-points",
        @"pages":pages, @"diagnostics":diagnostics} mutableCopy];
    if (!selected && end < (NSUInteger)count) result[@"nextPage"] = @(end + 1);
    NSData* serialized = [NSJSONSerialization dataWithJSONObject:result options:0 error:error];
    if (!serialized || serialized.length > 16 * 1024 * 1024)
        return failure(@"PDF report exceeds 16 MiB; select one page.", error);
    if (directory) {
        // All geometry and text validation finishes before creating any output.
        if (mkdir(directory.fileSystemRepresentation, 0700) != 0)
            return failure(@"Render directory must be new and its parent must exist.", error);
        NSMutableArray<NSString*>* images = [NSMutableArray array];
        for (NSUInteger index = first; index < end; ++index) {
            NSString* imagePath = [directory stringByAppendingPathComponent:
                [NSString stringWithFormat:@"page-%04lu.png", (unsigned long)index + 1]];
            [images addObject:imagePath];
            if (!writePNG(document.value, index, imagePath, error)) {
                for (NSString* ownPath in images) unlink(ownPath.fileSystemRepresentation);
                rmdir(directory.fileSystemRepresentation);
                return nil;
            }
        }
        result[@"images"] = images;
    }
    return result;
}
