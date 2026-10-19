#import "SPDFMacOCRCommand.h"

NSArray<NSString*>* spdf_mac_ocr_arguments(NSString* language, NSString* originalPath, NSString* tmpPath,
                                           NSInteger jobs, BOOL sourceHasText, BOOL forceOCR) {
    NSMutableArray<NSString*>* args = [@[
        @"--jobs", [NSString stringWithFormat:@"%ld", (long)jobs], @"--rotate-pages", @"--optimize", @"1",
        @"--oversample", @"400", @"--tesseract-pagesegmode", @"11", @"-l", language ?: @"eng"
    ] mutableCopy];
    if (!sourceHasText) {
        [args addObject:@"--deskew"];
        if (forceOCR) [args addObject:@"--force-ocr"];
    } else {
        [args addObject:@"--redo-ocr"];
    }
    [args addObject:originalPath ?: @""];
    [args addObject:tmpPath ?: @""];
    return args;
}
