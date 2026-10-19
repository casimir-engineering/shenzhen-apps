#pragma once
#import "SPDFMacDelegatePrivate.h"
FOUNDATION_EXPORT NSMenu* SPDFMacTranslationChoiceMenu(id target);
@interface ShenzhenMacDelegate (SPDFMacTranslationChoice)
- (void)translateDocument:(id)sender;
- (void)translateDocumentWithAI:(id)sender;
@end
