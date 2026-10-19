#import "SPDFMacOCRValidation.h"

BOOL spdf_mac_ocr_document_is_image_backed(spdf_document* doc) {
    if (!doc) return NO;
    int pageCount = spdf_page_count(doc);
    if (pageCount <= 0) return NO;
    // Every page, not just the first: a cover scan in front of an authored
    // document must not turn the whole file into a rasterising job.
    for (int page = 0; page < pageCount; ++page) {
        spdf_text_lines lines;
        memset(&lines, 0, sizeof(lines));
        char err[1024] = {0};
        if (!spdf_extract_page_text_lines(doc, page, &lines, err, sizeof(err))) return NO;
        BOOL backed = lines.image_backed != 0;
        spdf_free_text_lines(&lines);
        if (!backed) return NO;
    }
    return YES;
}

NSInteger spdf_mac_ocr_pages_without_text(spdf_document* doc) {
    if (!doc) return -1;
    int pageCount = spdf_page_count(doc);
    if (pageCount <= 0) return -1;
    NSInteger empty = 0;
    for (int page = 0; page < pageCount; ++page) {
        spdf_text_lines lines;
        memset(&lines, 0, sizeof(lines));
        char err[1024] = {0};
        if (!spdf_extract_page_text_lines(doc, page, &lines, err, sizeof(err))) return -1;
        if (lines.count <= 0) ++empty;
        spdf_free_text_lines(&lines);
    }
    return empty;
}

BOOL spdf_mac_ocr_failure_wants_forced_pass(NSString* output) {
    if (!output.length) return NO;
    // Match ocrmypdf's own advice rather than the prose around it: the wording
    // of the explanation has changed between releases, the flag name has not.
    // "--skip-text" would leave the scan unread, so --force-ocr is the answer.
    if ([output rangeOfString:@"--force-ocr"].location == NSNotFound) return NO;
    return [output rangeOfString:@"TaggedPDFError"].location != NSNotFound ||
           [output rangeOfString:@"Tagged PDF"].location != NSNotFound ||
           [output rangeOfString:@"vector content"].location != NSNotFound;
}

NSString* spdf_mac_ocr_human_readable_failure(NSString* output) {
    if (!output.length) return @"OCRmyPDF exited with an error.";
    if ([output rangeOfString:@"--redo-ocr"].location != NSNotFound &&
        [output rangeOfString:@"not compatible"].location != NSNotFound) {
        return @"OCRmyPDF could not redo OCR on this PDF.\n\n"
               @"This document already contains selectable text, and this OCRmyPDF version cannot combine redo OCR "
               @"with cleanup operations for it. OCR is probably not needed for text-only or vector-text PDFs.";
    }
    if ([output rangeOfString:@"Traceback"].location != NSNotFound) {
        return @"OCRmyPDF crashed while processing this PDF.\n\n"
               @"This looks like an OCRmyPDF compatibility error rather than a Shenzhen PDF error. Try updating "
               @"OCRmyPDF and Tesseract, or run OCRmyPDF from Terminal for the full traceback.";
    }
    // Whatever it printed, trimmed to what an alert can actually display.
    return output.length > 1200 ? [output substringToIndex:1200] : output;
}
