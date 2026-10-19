#import <Cocoa/Cocoa.h>

#import "SPDFMacDelegatePrivate.h"

// The Argos installer offer for selection translation. Split out of the
// coordinator; the whole-document variant still lives there.
@interface ShenzhenMacDelegate (SPDFMacTranslationInstall)
- (void)promptToInstallArgosAndContinueSelectionText:(NSString*)text
                                      sourceLanguage:(NSString*)sourceLanguage
                                      targetLanguage:(NSString*)targetLanguage;
@end
