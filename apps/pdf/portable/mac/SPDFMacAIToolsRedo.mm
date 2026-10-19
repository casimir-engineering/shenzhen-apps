#import "SPDFMacAIToolsPrivate.h"
#import "SPDFMacAIChatOrganizationTools.h"
#import "SPDFMacAIToolsReader.h"
#import "SPDFMacAIReaderControls.h"
#import "SPDFMacAIIntegration.h"
#import "SPDFMacAIMetadataActions.h"
#import "SPDFMacSearchFileCache.h"
#import "SPDFMacAIDocumentContext.h"
#include <sys/stat.h>
@implementation SPDFMacAITools (Redo)
- (BOOL)canRedo {return self.redoActions.count>0;}
- (NSDictionary*)redoGuardForAction:(NSDictionary*)action {
    NSString* path=action[@"forward"][@"arguments"][@"path"] ?: action[@"metadata"][@"path"];
    NSMutableDictionary* reader=[[self.reader aiReaderControls] mutableCopy];
    NSString* revision=path ? (SPDFSearchFileStamp(path) ?: @"missing") : @"";
    if(action[@"comment"]) {
        // File Undo replaces the inode. Compare the bounded PDF's bytes so a
        // sequence of Undo/Redo remains valid while external edits still fail.
        struct stat info={};
        BOOL bounded=path && !lstat(path.fileSystemRepresentation,&info) && S_ISREG(info.st_mode) &&
            info.st_size>0 && info.st_size<=32LL*1024*1024;
        revision=bounded ? (SPDFAIContentHash(path,[NSProgress progressWithTotalUnitCount:1],nil) ?: @"missing") : @"missing";
        if([reader[@"path"] isEqual:path])[reader removeObjectForKey:@"revision"];
    }
    if(action[@"metadata"]) {
        // The metadata swap checks the source and persistent cache on its worker.
        // Its saved stat stamp may differ after another journaled file restore.
        revision=@"";
        if([reader[@"path"] isEqual:path])[reader removeObjectForKey:@"revision"];
    }
    return @{@"workspace":[self.reader aiWorkspaceFingerprint] ?: @"",
        @"reader":reader ?: @{},@"path":path ?: @"",
        @"revision":revision,
        @"metadata":path && !action[@"comment"] && !action[@"metadata"] ?
            ([self.reader aiAnalysisForPath:path] ?: @{}) : @{}};
}
- (void)retainUndoneAction:(NSDictionary*)action {
    if(!action[@"forward"] && !action[@"metadata"])return;
    if(!self.redoActions)self.redoActions=[NSMutableArray array];
    NSMutableDictionary* saved=[action mutableCopy];saved[@"guard"]=[self redoGuardForAction:action];
    [self.redoActions addObject:saved];if(self.redoActions.count>8)[self.redoActions removeObjectAtIndex:0];
}
- (void)undoWithCompletion:(void (^)(NSDictionary*))completion {
    NSDictionary* action=self.actions.lastObject;
    if(action[@"chatOrganization"]){[self swapChatOrganizationAction:NO completion:completion];return;}
    if(!action[@"metadata"]) {NSError* error=nil;BOOL ok=[self undoLastAction:&error];completion(ok ? @{@"undone":@YES} : @{@"error":error.localizedDescription ?: @"Nothing to undo"});return;}
    self.progress=[NSProgress progressWithTotalUnitCount:1];
    [self.reader aiSwapMetadataReceipt:action[@"metadata"] progress:self.progress completion:^(NSDictionary* result){
        if(!result[@"error"]) {
            [self.actions removeObjectIdenticalTo:action];NSMutableDictionary* reversed=[action mutableCopy];reversed[@"metadata"]=result[@"metadataReceipt"];
            [self retainUndoneAction:reversed];completion(@{@"undone":@YES});
        } else completion(result);
    }];
}
// Saving the same edit again gives the PDF a new file identifier, so the bytes a
// redone edit writes differ from those it wrote the first time. The next Redo
// expected the first ones; when that is what it saw at Undo, it takes these.
- (void)carryRedoGuardFrom:(NSString*)firstHash to:(NSString*)redoneHash {
    NSDictionary* next=self.redoActions.lastObject;
    if(!firstHash.length || !redoneHash.length || [firstHash isEqual:redoneHash] ||
       ![next[@"guard"][@"revision"] isEqual:firstHash])return;
    NSMutableDictionary* carried=[next mutableCopy],*guard=[next[@"guard"] mutableCopy];
    guard[@"revision"]=redoneHash;carried[@"guard"]=guard;
    self.redoActions[self.redoActions.count-1]=carried;
}
- (void)redoWithCompletion:(void (^)(NSDictionary*))completion {
    NSDictionary* action=self.redoActions.lastObject;
    if(action[@"chatOrganization"]){[self swapChatOrganizationAction:YES completion:completion];return;}
    if(!action || ![action[@"guard"] isEqual:[self redoGuardForAction:action]]) {completion(@{@"error":@"Nothing to redo, or the document/workspace changed since Undo."});return;}
    self.progress=[NSProgress progressWithTotalUnitCount:1];
    void (^finished)(NSDictionary*)=^(NSDictionary* result){
        if(!result[@"error"]) {
            [self.redoActions removeObjectIdenticalTo:action];
            if(action[@"metadata"]) [self.actions addObject:@{@"id":NSUUID.UUID.UUIDString,@"metadata":result[@"metadataReceipt"]}];
            else if(self.actions.count) {
                NSMutableDictionary* recorded=[self.actions.lastObject mutableCopy];
                recorded[@"forward"]=action[@"forward"];
                self.actions[self.actions.count-1]=recorded;
                [self carryRedoGuardFrom:action[@"comment"][@"afterHash"] to:recorded[@"comment"][@"afterHash"]];
            }
            completion(@{@"redone":@YES});
        } else completion(result);
    };
    if(action[@"metadata"]) [self.reader aiSwapMetadataReceipt:action[@"metadata"] progress:self.progress completion:finished];
    else {
        NSMutableDictionary* arguments=[action[@"forward"][@"arguments"] mutableCopy];
        if(arguments[@"revision"])arguments[@"revision"]=SPDFSearchFileStamp(arguments[@"path"]) ?: @"";
        [self performInternalTool:action[@"forward"][@"name"] arguments:arguments completion:finished];
    }
}
@end
