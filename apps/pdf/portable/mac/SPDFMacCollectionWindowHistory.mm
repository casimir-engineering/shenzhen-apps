#import "SPDFMacCollectionWindowHistory.h"
#import "SPDFMacCollectionWindowPrivate.h"

// Collection has Documents and Settings only. History belongs to the reader's
// persistent sidebar, so opening it never replaces the Collection result list.
@implementation SPDFMacCollectionWindow (HistoryDetail)
- (void)showHistoryForDocument:(NSDictionary*)document version:(NSDictionary*)version {
    (void)version;
    if (![document[@"id"] length]) return;
    NSDictionary* latest = [document[@"versions"] lastObject];
    for (NSDictionary* candidate in document[@"versions"])
        if ([candidate[@"id"] isEqual:document[@"latestVersionID"]]) { latest = candidate; break; }
    [self persistManagerPreferences];
    if (self.navigateHandler) self.navigateHandler(document,latest,0,@"",YES);
}
- (NSDictionary*)historySelectedDocument { return nil; }
- (NSDictionary*)historySelectedVersion { return nil; }
- (void)returnFromCollectionHistory:(id)sender {
    (void)sender; [self showDestination:@"Documents"];
    [self.window makeFirstResponder:self.table]; [self persistManagerPreferences];
}
@end
