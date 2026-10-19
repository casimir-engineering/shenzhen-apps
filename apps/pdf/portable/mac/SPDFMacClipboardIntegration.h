#pragma once
#import "SPDFMacDelegatePrivate.h"
#import "SPDFMacClipboardImage.h"
@interface ShenzhenMacDelegate (SPDFMacClipboard)
- (BOOL)pasteClipboardDocument:(NSPasteboard*)pasteboard;
@end
