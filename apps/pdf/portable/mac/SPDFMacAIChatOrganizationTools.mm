#import "SPDFMacAIChatOrganizationTools.h"
#import "SPDFMacAIToolsPrivate.h"
#import "SPDFMacAIChatStore.h"
static NSDictionary* Definition(NSString* name,NSString* description,NSDictionary* properties,NSArray* required) {
    return @{@"type":@"function",@"function":@{@"name":name,@"description":description,
        @"parameters":@{@"type":@"object",@"properties":properties,@"required":required,@"additionalProperties":@NO}}};
}
NSArray* SPDFChatOrganizationToolDefinitions(void) {
    NSDictionary* text=@{@"type":@"string"};
    return @[
        Definition(@"list_chats",@"List saved chat titles, folders, timestamps and optional message-match snippets. General is the default folder (empty ID). Page through all results before organizing all chats. Reads are lazy; transcripts are not sent in full.",
            @{@"query":text,@"first":@{@"type":@"integer",@"minimum":@1},@"count":@{@"type":@"integer",@"minimum":@1,@"maximum":@100}},@[]),
        Definition(@"organize_chats",@"Reversibly organize saved conversations when asked. Atomically create folders, move chats or rename them. List chats first and pass organizationRevision. Up to 200 operations; create_folder then move_chat with folderName can create and populate folders in one call. No chats are deleted. Undo/Redo refuses to overwrite intervening organization edits.",
            @{@"organizationRevision":text,@"operations":@{@"type":@"array",@"minItems":@1,@"maxItems":@200,
                @"items":@{@"type":@"object",@"properties":@{
                    @"operation":@{@"type":@"string",@"enum":@[@"create_folder",@"move_chat",@"rename_chat",@"rename_folder"]},
                    @"chatID":text,@"folderID":text,@"folderName":text,@"name":text},@"required":@[@"operation"],@"additionalProperties":@NO}}},@[@"organizationRevision",@"operations"])
    ];
}
@implementation SPDFMacAITools (ChatOrganization)
- (void)performChatOrganizationTool:(NSString*)name arguments:(NSDictionary*)arguments completion:(void (^)(NSDictionary*))completion {
    if(!self.queue){self.queue=[NSOperationQueue new];self.queue.maxConcurrentOperationCount=1;self.queue.qualityOfService=NSQualityOfServiceUtility;}
    self.progress=[NSProgress progressWithTotalUnitCount:1];NSProgress* progress=self.progress;
    SPDFMacAIChatStore* store=[[SPDFMacAIChatStore alloc] initWithDirectory:SPDFMacAIChatStore.defaultDirectory];
    [self.queue addOperationWithBlock:^{
        if(progress.cancelled){dispatch_async(dispatch_get_main_queue(),^{completion(@{@"cancelled":@YES});});return;}
        NSDictionary* result=nil;NSDictionary* receipt=nil;NSError* error=nil;
        if([name isEqual:@"list_chats"]) {
            NSDictionary* snapshot=[store organizationSnapshot];
            // As the assistant: chats quoting Friends messages match by title only (SPDFMacAIChatTitleSearchOnlyKey).
            NSArray* chats=[store chatsMatchingQuery:arguments[@"query"] ?: @"" forAssistant:YES];
            NSUInteger first=MAX(1,[arguments[@"first"] unsignedIntegerValue]),count=arguments[@"count"] ? MIN(100,[arguments[@"count"] unsignedIntegerValue]) : 50;
            NSUInteger offset=MIN(first-1,chats.count),length=MIN(count,chats.count-offset);
            result=snapshot ? @{@"chats":[chats subarrayWithRange:NSMakeRange(offset,length)],@"folders":store.folders,
                @"totalChats":@(chats.count),@"next":offset+length<chats.count ? @(offset+length+1) : NSNull.null,
                @"organizationRevision":snapshot[@"revision"]} : @{@"error":@"Saved chat organization could not be read."};
        } else {
            receipt=[store organizeChats:arguments[@"operations"] expectedRevision:arguments[@"organizationRevision"] progress:progress error:&error];
            result=receipt ? @{@"changed":@YES,@"operationsApplied":@([arguments[@"operations"] count]),@"organizationRevision":receipt[@"after"]} :
                @{@"error":error.localizedDescription ?: @"Chat organization cancelled or invalid."};
        }
        dispatch_async(dispatch_get_main_queue(),^{
            NSMutableDictionary* visible=[result mutableCopy];
            if(receipt) {
                NSString* identifier=NSUUID.UUID.UUIDString;
                [self.actions addObject:@{@"id":identifier,@"chatOrganization":receipt}];[self.redoActions removeAllObjects];
                if(self.actions.count>32)[self.actions removeObjectAtIndex:0];
                visible[@"actionID"]=identifier;visible[@"undoable"]=@YES;
            }
            completion(progress.cancelled && !receipt ? @{@"cancelled":@YES} : visible);
        });
    }];
}
- (void)swapChatOrganizationAction:(BOOL)redo completion:(void (^)(NSDictionary*))completion {
    NSMutableArray* source=redo ? self.redoActions : self.actions;NSDictionary* action=source.lastObject;
    self.progress=[NSProgress progressWithTotalUnitCount:1];NSProgress* progress=self.progress;
    if(!self.queue){self.queue=[NSOperationQueue new];self.queue.maxConcurrentOperationCount=1;self.queue.qualityOfService=NSQualityOfServiceUtility;}
    [self.queue addOperationWithBlock:^{
        SPDFMacAIChatStore* store=[[SPDFMacAIChatStore alloc] initWithDirectory:SPDFMacAIChatStore.defaultDirectory];
        NSDictionary* reverse=[store swapOrganizationReceipt:action[@"chatOrganization"] progress:progress error:nil];
        dispatch_async(dispatch_get_main_queue(),^{
            if(!reverse){completion(@{@"error":@"Chat folders changed after the action, or it was cancelled. Nothing was overwritten."});return;}
            [source removeObjectIdenticalTo:action];
            if(!self.redoActions)self.redoActions=[NSMutableArray array];
            [(redo ? self.actions : self.redoActions) addObject:@{@"id":NSUUID.UUID.UUIDString,@"chatOrganization":reverse}];
            completion(@{redo ? @"redone" : @"undone":@YES});
        });
    }];
}
@end
