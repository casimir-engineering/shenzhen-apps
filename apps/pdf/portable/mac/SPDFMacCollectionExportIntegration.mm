#import "SPDFMacCollectionSavePanel.h"
#import "SPDFMacCollectionIntegration.h"
#import "SPDFMacCollectionStore.h"
@implementation ShenzhenMacDelegate (SPDFMacCollectionExport)
- (void)collectionSaveArchiveCopy:(id)sender {
    (void)sender;
    SPDFMacCollectionStore* store = [SPDFMacCollectionStore defaultStore];
    NSDictionary* info = [store archiveInfoForPath:_path]; if (!info) return;
    NSSavePanel* panel = [NSSavePanel savePanel]; SPDFCollectionConfigureSavePanel(panel, _path);
    [panel beginSheetModalForWindow:_window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK) return;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError* error = nil;
            BOOL ok = [store exportVersionID:info[@"version"][@"id"] documentID:info[@"document"][@"id"] toURL:panel.URL error:&error];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (ok) [self collectionOpenPath:panel.URL.path archived:NO]; else [self->_window presentError:error];
            });
        });
    }];
}
@end
