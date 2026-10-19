#import "SPDFMacCollectionSavePanel.h"
#import <objc/runtime.h>
@interface SPDFCollectionSavePanelDelegate : NSObject <NSOpenSavePanelDelegate>
@end
@implementation SPDFCollectionSavePanelDelegate
- (BOOL)panel:(id)sender validateURL:(NSURL*)URL error:(NSError**)error {
    (void)sender;
    if (![NSFileManager.defaultManager fileExistsAtPath:URL.path]) return YES;
    if (error) *error = [NSError errorWithDomain:@"ShenzhenPDF.Collection" code:20 userInfo:@{
        NSLocalizedDescriptionKey:@"Choose a new filename for this copy. Existing documents are preserved."}];
    return NO;
}
@end
void SPDFCollectionConfigureSavePanel(NSSavePanel* panel, NSString* sourceName) {
    static char delegateKey;
    id delegate = [SPDFCollectionSavePanelDelegate new];
    objc_setAssociatedObject(panel, &delegateKey, delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    panel.delegate = delegate;
    panel.title = @"Save a Collection Copy";
    panel.message = @"Create a separate editable copy with a new filename.";
    NSString* name = sourceName.lastPathComponent ?: @"Document";
    panel.nameFieldStringValue = [[name.stringByDeletingPathExtension stringByAppendingString:@" copy"]
        stringByAppendingPathExtension:name.pathExtension];
}
