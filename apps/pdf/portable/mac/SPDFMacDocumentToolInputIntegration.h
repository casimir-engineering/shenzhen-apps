#pragma once
#import "SPDFMacDelegatePrivate.h"
#import "SPDFMacDocumentToolInput.h"
#import "SPDFMacPictureTextIntegration.h"  // OCR on this Mac, and a picture's text

@interface ShenzhenMacDelegate (SPDFMacDocumentToolInput)
- (BOOL)beginImageOCRWithLanguage:(NSString*)language displayName:(NSString*)displayName;
- (BOOL)beginNativeDocumentTranslation;
@end
