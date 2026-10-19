#import "SPDFMacDocumentToolInput.h"
#include "spdf_document_export.h"
#include <fcntl.h>
#include <unistd.h>

BOOL SPDFOCRPathNeedsPDF(NSString* path) {
    NSString* ext = path.pathExtension.lowercaseString;
    // The reader's linked raster formats plus SVG; no system-wide image UTI probe.
    static NSString* const extensions[] = {@"png", @"jpg", @"jpeg", @"jpe", @"jfif-tbnl", @"jfif", @"bmp", @"gif",
        @"tif", @"tiff", @"jp2", @"jpx", @"j2k", @"jb2", @"jbig2", @"pnm", @"pam", @"pbm", @"pgm",
        @"ppm", @"pfm", @"psd", @"svg", @"svgz"};
    for (NSString* candidate : extensions) if ([ext isEqualToString:candidate]) return YES;
    return NO;
}

BOOL SPDFOCRPathSupported(NSString* path) {
    return [path.pathExtension.lowercaseString isEqualToString:@"pdf"] || SPDFOCRPathNeedsPDF(path);
}

static NSString* Fail(NSString* detail, NSError** error) {
    if (error) *error = [NSError errorWithDomain:@"ShenzhenPDF.DocumentToolInput" code:1
        userInfo:@{NSLocalizedDescriptionKey:detail ?: @"Could not create a PDF copy."}];
    return nil;
}

NSString* SPDFCreateToolPDF(NSString* source, NSString* suffix, NSError** error, NSString* destinationDirectory) {
    char message[1024] = {};
    spdf_document* document = spdf_open(source.fileSystemRepresentation, message, sizeof(message));
    if (!document) return Fail(@(message), error);
    NSString* directory = destinationDirectory ?: source.stringByDeletingLastPathComponent;
    NSString* stem = [source.lastPathComponent.stringByDeletingPathExtension stringByAppendingFormat:@"-%@", suffix];
    NSString* base = [directory stringByAppendingPathComponent:stem];
    NSString* output = nil;
    // Reserve the destination atomically: simultaneous windows must not overwrite
    // one another. The PDF writer replaces only the placeholder we just created.
    for (NSUInteger attempt = 0; attempt < 1000; ++attempt) {
        NSString* stem = attempt ? [base stringByAppendingFormat:@"-%lu", (unsigned long)attempt] : base;
        NSString* candidate = [stem stringByAppendingPathExtension:@"pdf"];
        int fd = open(candidate.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (fd >= 0) { close(fd); output = candidate; break; }
        if (errno != EEXIST) break;
    }
    BOOL success = output && spdf_document_export_pdf(document, output.fileSystemRepresentation, -1, message, sizeof(message));
    spdf_close(document);
    if (!success) {
        if (output) [NSFileManager.defaultManager removeItemAtPath:output error:nil];
        return Fail(message[0] ? @(message) : @"Choose a writable folder by saving a copy of this document first.", error);
    }
    return output;
}
