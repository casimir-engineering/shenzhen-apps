#import "SPDFMacClipboardIntegration.h"
@interface ShenzhenMacDelegate (SPDFMacClipboardPrivate)
- (NSString*)pathForStateFile:(NSString*)name;
- (void)showError:(NSString*)message detail:(NSString*)detail;
@end
@implementation ShenzhenMacDelegate (SPDFMacClipboard)
- (BOOL)pasteClipboardDocument:(NSPasteboard*)pasteboard {
    if ([self openFilesFromPasteboard:pasteboard]) return YES;
    NSData* imageData = SPDFClipboardImageData(pasteboard);
    if (!imageData) return NO;
    // Durable, app-owned sources allow normal YAML session restoration even
    // when Collection is disabled. Nothing is created until an explicit paste.
    NSString* directory = [self pathForStateFile:@"Pasted Images"];
    __weak ShenzhenMacDelegate* weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSError* error = nil;
            NSString* path = SPDFStoreClipboardImage(imageData, directory, &error);
            dispatch_async(dispatch_get_main_queue(), ^{
                ShenzhenMacDelegate* owner = weakSelf;
                if (!owner) return;
                if (path) [owner openPath:path];
                else [owner showError:@"Could not open clipboard image" detail:error.localizedDescription];
            });
        }
    });
    return YES;
}
@end
