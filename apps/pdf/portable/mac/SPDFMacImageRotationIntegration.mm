#import "SPDFMacImageRotationIntegration.h"
#import "SPDFMacImageRotation.h"
#import "SPDFMacImageProperties.h"
#import "SPDFMacCollectionIntegration.h"
#import <objc/runtime.h>
static char rotationStateKey;
@interface SPDFImageRotationState : NSObject
@property NSMutableArray<NSDictionary*>* requests;
@property BOOL busy;
@end
@implementation SPDFImageRotationState
- (instancetype)init { if((self=[super init])) _requests=[NSMutableArray array]; return self; }
@end
@interface ShenzhenMacDelegate (ImageRotationPrivate)
- (void)showError:(NSString*)message detail:(NSString*)detail;
- (void)performNextImageRotation;
@end
@implementation ShenzhenMacDelegate (ImageRotation)
- (BOOL)rotateActiveImageByDegrees:(int)degrees {
    if(!_doc || !SPDFPathIsRasterImage(_path)) return NO;
    SPDFDocumentTab* tab=[self selectedTab];
    if(tab.readOnly) { [self showError:@"This image is read-only" detail:@"Save a copy before rotating it."]; return YES; }
    SPDFImageRotationState* state=objc_getAssociatedObject(self,&rotationStateKey);
    if(!state) {
        state=[SPDFImageRotationState new];
        objc_setAssociatedObject(self,&rotationStateKey,state,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Preserve rapid repeated commands. Serial writes also avoid two workers
    // racing to replace the same source; no queue exists before the first edit.
    [state.requests addObject:@{@"tab":tab,@"path":[_path copy],@"degrees":@(degrees)}];
    [self performNextImageRotation];
    return YES;
}
- (void)performNextImageRotation {
    SPDFImageRotationState* state=objc_getAssociatedObject(self,&rotationStateKey);
    if(state.busy || !state.requests.count) return;
    NSDictionary* request=state.requests.firstObject; [state.requests removeObjectAtIndex:0];
    SPDFDocumentTab* tab=request[@"tab"]; NSString* path=request[@"path"];
    if(![_tabs containsObject:tab] || ![tab.path isEqual:path]) { [self performNextImageRotation]; return; }
    state.busy=YES;
    if(![self collectionProtectPath:path operation:@"rotating the image"]) {
        state.busy=NO; [state.requests removeAllObjects]; return;
    }
    __weak ShenzhenMacDelegate* weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        @autoreleasepool {
            NSError* error=nil; BOOL ok=SPDFRotateImageAtPath(path,[request[@"degrees"] intValue],&error);
            dispatch_async(dispatch_get_main_queue(),^{
                ShenzhenMacDelegate* owner=weakSelf; if(!owner) return;
                state.busy=NO;
                if(!ok) {
                    [state.requests removeAllObjects];
                    [owner showError:@"Could not rotate image" detail:error.localizedDescription]; return;
                }
                [owner collectionDidSavePath:path];
                if([owner->_tabs containsObject:tab] && [tab.path isEqual:path]) {
                    tab.hasScrollOrigin=NO; tab.scrollOrigin=NSZeroPoint;
                    [owner discardCachedRuntimeForTab:tab];
                    if([owner selectedTab]==tab) [owner loadSelectedTab];
                }
                [owner performNextImageRotation];
            });
        }
    });
}
@end
