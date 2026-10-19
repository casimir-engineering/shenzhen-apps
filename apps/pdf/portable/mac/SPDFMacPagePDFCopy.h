#pragma once
#import <Cocoa/Cocoa.h>
#include "shenzhen_pdf_core.h"

@interface SPDFMacPagePDFCopy : NSObject
@property(nonatomic, copy) NSData* data;
@property(nonatomic, copy) NSURL* fileURL;
@end
// Export only when explicitly requested. Non-PDF formats use the common MuPDF
// writer; PDF input retains the existing original-page grafting path.
SPDFMacPagePDFCopy* SPDFCreatePagePDFCopy(spdf_document* document, NSInteger pageIndex,
                                         NSString* sourcePath, NSError** error);
BOOL SPDFWritePagePDFCopy(SPDFMacPagePDFCopy* copy, NSPasteboard* pasteboard);
