#import "SPDFMacPagePDFCopy.h"
#include "spdf_document_export.h"

@implementation SPDFMacPagePDFCopy
@end

SPDFMacPagePDFCopy* SPDFCreatePagePDFCopy(spdf_document* document, NSInteger pageIndex,
                                         NSString* sourcePath, NSError** error) {
    NSString* detail = nil;
    if (!document || pageIndex < 0 || pageIndex >= spdf_page_count(document)) {
        detail = @"The selected page is unavailable.";
    } else {
        NSString* root = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ShenzhenPDF-copy"];
        NSString* directory = [root stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSFileManager* manager = NSFileManager.defaultManager;
        if (![manager createDirectoryAtPath:directory withIntermediateDirectories:YES
            attributes:@{NSFilePosixPermissions:@0700} error:error]) return nil;
        NSString* base = sourcePath.lastPathComponent.stringByDeletingPathExtension;
        NSString* name = [NSString stringWithFormat:@"%@ - page %ld.pdf", base.length ? base : @"Page", (long)pageIndex + 1];
        NSString* output = [directory stringByAppendingPathComponent:name];
        char message[1024] = {};
        BOOL pdfSource = [sourcePath.pathExtension.lowercaseString isEqualToString:@"pdf"];
        BOOL saved = pdfSource
            ? spdf_save_single_page_pdf(document, (int)pageIndex, output.fileSystemRepresentation, message, sizeof(message))
            : spdf_document_export_pdf(document, output.fileSystemRepresentation, (int)pageIndex, message, sizeof(message));
        NSData* data = saved ? [NSData dataWithContentsOfFile:output] : nil;
        if (data.length) {
            [manager setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:output error:nil];
            SPDFMacPagePDFCopy* result = [SPDFMacPagePDFCopy new];
            result.data = data; result.fileURL = [NSURL fileURLWithPath:output]; return result;
        }
        [manager removeItemAtPath:directory error:nil];
        detail = message[0] ? @(message) : @"The page could not be written as a PDF.";
    }
    if (error) *error = [NSError errorWithDomain:@"ShenzhenPDF.CopyPage" code:1
        userInfo:@{NSLocalizedDescriptionKey:detail}];
    return nil;
}

BOOL SPDFWritePagePDFCopy(SPDFMacPagePDFCopy* copy, NSPasteboard* pasteboard) {
    if (!copy.data.length || !copy.fileURL) return NO;
    NSPasteboardItem* item = [NSPasteboardItem new];
    [item setData:copy.data forType:NSPasteboardTypePDF];
    [item setString:copy.fileURL.absoluteString forType:NSPasteboardTypeFileURL];
    [pasteboard clearContents];
    return [pasteboard writeObjects:@[item]];
}
