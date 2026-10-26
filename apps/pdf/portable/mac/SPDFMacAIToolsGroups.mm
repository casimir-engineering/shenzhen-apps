#import "SPDFMacAIToolsPrivate.h"
#import "SPDFMacAIToolsReader.h"
#import "SPDFMacAgentCommand.h"
#import "SPDFMacAgentGroups.h"
@implementation SPDFMacAITools (Groups)
// Several documents moved into one group in one call, as one undoable change: each is the existing move-tab, and an
// error puts back the ones already moved. `paths` holds the documents' paths (performTool maps the IDs).
- (void)moveTabs:(NSDictionary*)command completion:(void (^)(NSDictionary*))completion {
    NSArray* members=[command[@"paths"] isKindOfClass:NSArray.class] ? command[@"paths"] : nil;
    if (!members.count || members.count>256) { completion(@{@"error":@"move-tab takes 1 to 256 document IDs in paths."}); return; }
    NSDictionary* before=[self.reader aiCaptureWorkspace],*result=nil;
    for (NSString* member in members) {
        NSMutableDictionary* one=[command mutableCopy]; [one removeObjectForKey:@"paths"]; one[@"path"]=member;
        NSError* error=nil;
        NSDictionary* valid=SPDFMacValidateAgentCommand([NSJSONSerialization dataWithJSONObject:one options:0 error:nil],&error);
        result=valid ? [self.reader performAgentGroupCommand:valid] : @{@"error":error.localizedDescription ?: @"Invalid group command."};
        if (result[@"error"]) {
            [self.reader aiRestoreWorkspace:before expected:[self.reader aiWorkspaceFingerprint]];
            completion(result); return;
        }
    }
    completion([self recordResult:result before:before]);
}
@end
