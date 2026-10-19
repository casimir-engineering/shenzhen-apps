#import "SPDFMacCollectionIntegration.h"
#import "SPDFMacCollectionUsage.h"
#import "SPDFMacCollectionStore.h"
#import <objc/runtime.h>
static char openIntentsKey;
@implementation ShenzhenMacDelegate (SPDFMacCollectionUsage)
- (void)collectionWillOpenPaths:(NSArray<NSString*>*)paths {
    // Session restore loads tabs without openPaths:. A dragged tab is not a new open.
    if (_startupDocumentWorkInProgress && (self.detachedTabLaunch || self.restoreWindowID.length)) return;
    SPDFCollectionOpenIntents* intents = objc_getAssociatedObject(self,&openIntentsKey);
    if (!intents) {
        intents = [SPDFCollectionOpenIntents new];
        objc_setAssociatedObject(self,&openIntentsKey,intents,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [intents requestPaths:paths];
}
- (NSUInteger)collectionConsumeUserOpenForPath:(NSString*)path {
    SPDFCollectionOpenIntents* intents = objc_getAssociatedObject(self,&openIntentsKey);
    return [intents consumePath:path];
}
- (void)collectionRecordUserOpenForPath:(NSString*)path document:(NSDictionary*)document {
    if (![document[@"id"] length]) return;
    [self collectionRecordUserOpenCount:[self collectionConsumeUserOpenForPath:path] document:document];
}
- (void)collectionRecordUserOpenCount:(NSUInteger)count document:(NSDictionary*)document {
    if (!count || ![document[@"id"] length]) return;
    NSString* identifier = document[@"id"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        [SPDFMacCollectionStore.defaultStore recordUserOpenCount:count forDocumentID:identifier error:nil];
    });
}
@end
