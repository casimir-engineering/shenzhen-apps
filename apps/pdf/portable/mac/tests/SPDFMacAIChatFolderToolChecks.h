#import "SPDFMacAIChatStore.h"
static void CheckChatFolderTools(AIContextProbe* reader) {
    SPDFMacAIChatStore* store=[[SPDFMacAIChatStore alloc] initWithDirectory:SPDFMacAIChatStore.defaultDirectory];
    NSString* first=NSUUID.UUID.UUIDString,*second=NSUUID.UUID.UUIDString;
    for(NSString* identifier in @[first,second])Check([store saveChat:@{@"id":identifier,@"title":@"Switch travel",@"updated":@1,@"messages":@[]} error:nil],"chat tool fixture saved");
    SPDFMacAITools* tools=[[SPDFMacAITools alloc] initWithReader:reader];
    __block NSDictionary* result=nil;
    void (^wait)(void)=^{NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:5];while(!result && deadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.005]];};
    [tools performTool:@"list_chats" arguments:@{@"count":@1} completion:^(NSDictionary* value){result=value;}];wait();
    Check([result[@"chats"] count]==1 && result[@"next"]!=NSNull.null && [result[@"folders"][0][@"name"] isEqual:@"General"],"assistant discovers paged chats and General");
    NSString* revision=result[@"organizationRevision"];
    result=nil;[tools performTool:@"organize_chats" arguments:@{@"organizationRevision":revision,@"operations":@[
        @{@"operation":@"create_folder",@"name":@"Tool switches"},
        @{@"operation":@"move_chat",@"chatID":first,@"folderName":@"Tool switches"},
        @{@"operation":@"move_chat",@"chatID":second,@"folderName":@"Tool switches"}]}
        completion:^(NSDictionary* value){result=value;}];wait();
    Check([result[@"changed"] boolValue] && [result[@"undoable"] boolValue] && tools.canUndo,"assistant creates and populates folder through real tool dispatch");
    Check([[store chatWithID:first][@"folder"] length]>0,"tool persists chat membership");
    result=nil;[tools performTool:@"undo_action" arguments:@{} completion:^(NSDictionary* value){result=value;}];wait();
    Check([result[@"undone"] boolValue] && ![[store chatWithID:first][@"folder"] length] && tools.canRedo,"assistant folder batch Undo is complete");
    result=nil;[tools performTool:@"redo_action" arguments:@{} completion:^(NSDictionary* value){result=value;}];wait();
    Check([result[@"redone"] boolValue] && [[store chatWithID:second][@"folder"] length]>0,"assistant folder batch Redo is complete");
    [store renameChat:first title:@"Manual change" error:nil];
    result=nil;[tools performTool:@"undo_action" arguments:@{} completion:^(NSDictionary* value){result=value;}];wait();
    Check(result[@"error"] && [[store chatWithID:first][@"title"] isEqual:@"Manual change"],"assistant cannot Undo over intervening human edit");
}
