#import "SPDFMacAIAppAccess.h"
#import "SPDFMacAIAppControls.h"
#import <objc/runtime.h>
static char appAccessKey;
// Listing and operating live in SPDFMacAIAppControls.mm, which needs no coordinator, so what the assistant may reach
// is tested headlessly; this category only keeps the last inspection's targets on the reader.
@implementation ShenzhenMacDelegate (AIAppAccess)
- (NSDictionary*)aiAppAccess:(NSDictionary*)arguments {
    if(!NSThread.isMainThread)return @{@"error":@"App controls must be accessed on the main thread."};
    NSString* operation=arguments[@"operation"] ?: @"inspect";
    if(![operation isKindOfClass:NSString.class])return @{@"error":@"Invalid operation."};
    if([operation isEqual:@"inspect"]) {
        NSMutableDictionary* targets=[NSMutableDictionary dictionary];
        NSDictionary* result=SPDFMacAIAppControlsInspect(NSApp.mainMenu,NSApp.windows,targets);
        // All discovery and target storage is created on explicit inspection, never at startup.
        objc_setAssociatedObject(self,&appAccessKey,targets,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return result;
    }
    return SPDFMacAIAppControlsOperate(operation,arguments,objc_getAssociatedObject(self,&appAccessKey));
}
@end
