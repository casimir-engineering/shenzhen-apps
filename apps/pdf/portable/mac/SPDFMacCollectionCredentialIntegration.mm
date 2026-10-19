#import "SPDFMacCollectionCredentialIntegration.h"
#import "SPDFMacCollectionStorePrivate.h"
#import "SPDFMacCollectionIntegration.h"

static BOOL CanRememberPath(SPDFMacCollectionStore* store, NSString* path) {
    return store.isEnabled || [store archiveInfoForPath:path][@"document"] != nil || [store documentForPath:path] != nil;
}
@implementation SPDFMacCollectionCredentials (Documents)
+ (SPDFPasswordCredential*)credentialForSourcePath:(NSString*)path {
    SPDFMacCollectionStore* store = SPDFMacCollectionStore.defaultStore;
    if (!CanRememberPath(store,path)) return nil;
    SPDFPasswordCredentialStore* memory = SPDFPasswordCredentialStore.sharedStore;
    NSString* identity = [memory sourceIdentityTokenForSourcePath:path];
    NSString* hash = SPDFCollectionHashURL([NSURL fileURLWithPath:path],nil);
    if (!hash || ![identity isEqual:[memory sourceIdentityTokenForSourcePath:path]]) return nil;
    return [self credentialForHash:hash error:nil];
}
+ (BOOL)rememberCredential:(SPDFPasswordCredential*)credential forSourcePath:(NSString*)path error:(NSError**)error {
    SPDFMacCollectionStore* store = SPDFMacCollectionStore.defaultStore;
    if (!credential || !CanRememberPath(store,path)) return NO;
    SPDFPasswordCredentialStore* memory = SPDFPasswordCredentialStore.sharedStore;
    NSString* identity = [memory sourceIdentityTokenForSourcePath:path];
    if ([memory credentialForSourcePath:path] != credential) return NO;
    NSString* hash = SPDFCollectionHashURL([NSURL fileURLWithPath:path],error);
    if (!hash || ![identity isEqual:[memory sourceIdentityTokenForSourcePath:path]]) return NO;
    return [self storeCredential:credential forHash:hash error:error];
}
@end

@implementation ShenzhenMacDelegate (SPDFMacCollectionPasswordRemembering)
- (void)collectionRememberPasswordForPath:(NSString*)path {
    SPDFPasswordCredential* credential = [SPDFPasswordCredentialStore.sharedStore credentialForSourcePath:path];
    if (!credential) return;
    NSString* source = path.copy;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        NSError* error = nil;
        [SPDFMacCollectionCredentials rememberCredential:credential forSourcePath:source error:&error];
        if (error) dispatch_async(dispatch_get_main_queue(), ^{
            if ([self->_path isEqual:source]) self->_statusLabel.stringValue =
                [@"Collection could not remember the PDF password: " stringByAppendingString:error.localizedDescription];
        });
    });
}
@end
