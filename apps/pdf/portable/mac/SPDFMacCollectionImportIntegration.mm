#import "SPDFMacCollectionImportIntegration.h"
#import "SPDFMacCollectionImport.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacReadOnlyCopy.h"
@interface ShenzhenMacDelegate (CollectionImportBookmark)
- (void)captureSecurityBookmarkForPath:(NSString*)path;
@end
@interface SPDFCollectionImportAccessSheet : NSObject <NSOpenSavePanelDelegate>
@property(weak) ShenzhenMacDelegate* owner;
@property NSString* source;
@property(weak) NSWindow* window;
@property(weak) NSTextField* status;
@property NSURL* destination;
@property(copy) SPDFCollectionImportReply reply;
@property NSOpenPanel* panel;
@property BOOL skipRemaining;
- (void)begin;
@end
@implementation SPDFCollectionImportAccessSheet
- (void)skipRemaining:(id)sender { (void)sender; self.skipRemaining=YES; [self.panel cancel:nil]; }
- (BOOL)panel:(id)sender validateURL:(NSURL*)URL error:(NSError**)error {
    (void)sender;
    if (SPDFCollectionImportURLMatchesSource(URL,self.source)) return YES;
    if (error) *error=[NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadInvalidFileNameError
        userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Select the original document “%@”.",self.source.lastPathComponent]}];
    return NO;
}
- (void)begin {
    ShenzhenMacDelegate* owner=self.owner;
    if (!owner || !self.window) {
        self.reply(nil,NO,[NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil]); return;
    }
    if (!SPDFMacCollectionStore.defaultStore.isEnabled) { self.reply(nil,NO,nil); return; }
    if (self.window.attachedSheet) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/4),dispatch_get_main_queue(),^{[self begin];}); return;
    }
    self.status.stringValue=@"Building Collection · waiting for document access";
    NSOpenPanel* panel=NSOpenPanel.openPanel; self.panel=panel; panel.delegate=self;
    panel.title=@"Allow Collection access"; panel.prompt=@"Allow access";
    panel.message=[NSString stringWithFormat:@"Select “%@” to include it in Collection. Cancel skips this document; saved history is always kept.",self.source.lastPathComponent];
    panel.canChooseFiles=YES; panel.canChooseDirectories=NO; panel.allowsMultipleSelection=NO;
    panel.directoryURL=[NSURL fileURLWithPath:self.source.stringByDeletingLastPathComponent];
    panel.nameFieldStringValue=self.source.lastPathComponent;
    NSButton* skip=[NSButton buttonWithTitle:@"Skip remaining unavailable documents" target:self action:@selector(skipRemaining:)];
    [skip sizeToFit]; panel.accessoryView=skip;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response!=NSModalResponseOK) { self.reply(nil,self.skipRemaining,nil); return; }
        // Validate again at completion: a different selection never acquires
        // permission or bytes on behalf of the requested source identity.
        NSError* validation=nil;
        if (![self panel:panel validateURL:panel.URL error:&validation]) { self.reply(nil,NO,validation); return; }
        ShenzhenMacDelegate* grantedOwner=self.owner;
        [grantedOwner captureSecurityBookmarkForPath:self.source];
        [grantedOwner ensureSecurityAccessForPath:self.source];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            NSError* failure=nil;
            SPDFReadOnlyCopyResolution result=SPDFResolveReadOnlyCopyWithError(self.source,self.destination.path,nil,nil,&failure);
            NSMutableDictionary* hint=[result.fingerprintBinding mutableCopy];
            if (hint) hint[@"path"]=result.workingPath;
            dispatch_async(dispatch_get_main_queue(),^{self.reply(hint,NO,failure);});
        });
    }];
}
@end
@implementation ShenzhenMacDelegate (CollectionInitialImport)
- (void)collectionImportRecentDocuments {
    __weak ShenzhenMacDelegate* weakSelf=self;
    [SPDFMacCollectionStore.defaultStore importRecentPaths:[_recentlyOpenedPaths copy]
        recovery:^(NSString* source,NSURL* destination,SPDFCollectionImportReply reply) {
            ShenzhenMacDelegate* owner=weakSelf;
            // Prefer a copy already read with authorization; no second panel
            // or source read is needed for an open, fingerprint-bound tab.
            NSInteger index=owner ? [owner indexOfTabForPath:source] : -1;
            SPDFDocumentTab* tab=index>=0 ? owner->_tabs[(NSUInteger)index] : nil;
            if (SPDFReadOnlyCopyBindingMatches(tab.readOnlyCopyBinding,source,tab.workingPath)) {
                NSMutableDictionary* hint=[tab.readOnlyCopyBinding mutableCopy]; hint[@"path"]=tab.workingPath;
                reply(hint,NO,nil); return;
            }
            SPDFCollectionImportAccessSheet* sheet=[SPDFCollectionImportAccessSheet new];
            sheet.owner=owner; sheet.window=owner ? owner->_window : nil; sheet.status=owner ? owner->_statusLabel : nil; sheet.source=source; sheet.destination=destination; sheet.reply=reply; [sheet begin];
        } completion:^(NSError* error) {
            ShenzhenMacDelegate* owner=weakSelf; if (!owner) return;
            if (error) [owner collectionAllowImportRetryAfterFailure];
            owner->_statusLabel.stringValue=error ? [NSString stringWithFormat:@"Collection import paused · %@",error.localizedDescription] :
                (SPDFMacCollectionStore.defaultStore.isEnabled ? @"Collection is ready" : @"Collection is off");
        }];
}
@end
