#import "SPDFMacOCRValidation.h"

#import "SPDFMacLaunchPrerenderPrivate.h"

// The app-facing half of SPDFMacOCRValidation.h: the two checks that need a
// document opened through the delegate. Split from the pure verdict functions
// so those can be linked, and tested, without the whole app delegate.
@implementation ShenzhenMacDelegate (SPDFMacOCRValidation)

- (NSInteger)selectableTextStateForPDFAtPath:(NSString*)path errorMessage:(NSString**)errorOut {
    if (errorOut) *errorOut = nil;
    if (!path.length) {
        if (errorOut) *errorOut = @"No PDF path was supplied.";
        return -1;
    }

    char err[1024];
    spdf_document* doc = [self openSpdfDocumentAtPath:path
                                           sourcePath:path
                                               status:NULL
                                                error:err
                                          errorLength:sizeof(err)];
    if (!doc) {
        if (errorOut) *errorOut = [NSString stringWithUTF8String:err[0] ? err : "Could not open PDF."];
        return -1;
    }

    int hasText = spdf_document_has_text(doc, 0, err, sizeof(err));
    spdf_close(doc);
    if (hasText < 0 && errorOut)
        *errorOut = [NSString stringWithUTF8String:err[0] ? err : "Could not inspect PDF text."];
    return hasText;
}

- (BOOL)ocrOutputIsPartialAtPath:(NSString*)path {
    if (!path.length) return NO;
    char err[1024];
    spdf_document* doc = [self openSpdfDocumentAtPath:path
                                           sourcePath:path
                                               status:NULL
                                                error:err
                                          errorLength:sizeof(err)];
    if (!doc) return NO;  // Unreadable is a different failure; the caller reports it.
    NSInteger empty = spdf_mac_ocr_pages_without_text(doc);
    spdf_close(doc);
    return empty > 0;
}

@end
