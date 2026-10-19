#import <Foundation/Foundation.h>
#import "SPDFMacAIChatStore.h"
static int failures;
#define CHECK(c,m) do {if(!(c)){fprintf(stderr,"FAIL: %s\n",m);failures++;}}while(0)
int main(void){@autoreleasepool{
    NSURL* root=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    SPDFMacAIChatStore* store=[[SPDFMacAIChatStore alloc] initWithDirectory:root];
    CHECK(![NSFileManager.defaultManager fileExistsAtPath:root.path],"store construction creates no files or startup work");
    NSString* identifier=NSUUID.UUID.UUIDString;
    NSDictionary* stale=@{@"id":identifier,@"title":@"Please help me inspect the board",@"updated":@1234,
        @"messages":@[@{@"role":@"user",@"content":@"Does this board need a regulated 5 V power supply?"},@{@"role":@"assistant",@"content":@"Use a regulated supply rated for two amps."}]};
    CHECK([store saveChat:stale error:nil],"save conversation");
    CHECK([store.folders.firstObject[@"name"] isEqual:@"General"] && ![store.folders.firstObject[@"id"] length],"General is the lazy default folder");
    CHECK([store setFolder:@"" collapsed:YES error:nil] && [store.folders.firstObject[@"collapsed"] boolValue],"General collapse persists");
    CHECK(![store createFolderNamed:@"general" error:nil],"default folder name reserved without duplicates");
    NSString* folder=[store createFolderNamed:@"Board design" error:nil];CHECK(folder.length,"create folder");
    CHECK(![store createFolderNamed:@"board DESIGN" error:nil],"reject duplicate folder name");
    CHECK(![store renameChat:identifier title:@"  \n " error:nil],"reject blank chat title");
    CHECK([store shouldSuggestTitleForChatID:identifier],"new chat requests concise title");
    CHECK([store setSuggestedTitle:@"Board power requirements" forChatID:identifier error:nil],"persist summarized title");
    CHECK(![store shouldSuggestTitleForChatID:identifier],"do not summarize repeatedly");
    CHECK([store renameChat:identifier title:@"Power supply sizing" error:nil],"user rename");
    CHECK(![store setSuggestedTitle:@"Late title response" forChatID:identifier error:nil],"late title response cannot overwrite user rename");
    CHECK([store moveChat:identifier toFolder:folder error:nil],"move to folder");
    CHECK([store setFolder:folder collapsed:YES error:nil],"persist collapse");
    CHECK([store saveChat:stale error:nil],"stale running conversation can still append independently");
    SPDFMacAIChatStore* reopened=[[SPDFMacAIChatStore alloc] initWithDirectory:root];
    NSDictionary* loaded=[reopened chatWithID:identifier];
    CHECK([loaded[@"title"] isEqual:@"Power supply sizing"],"rename survives stale session save and reopening");
    CHECK([loaded[@"folder"] isEqual:folder],"folder survives stale session save and reopening");
    CHECK([reopened.folders[1][@"collapsed"] boolValue],"folder collapse survives reopening");
    NSArray* matches=[reopened chatsMatchingQuery:@"regulated"];
    CHECK(matches.count==1 && [matches[0][@"snippet"] containsString:@"regulated"],"message search returns surrounding text with query");
    CHECK([matches[0][@"query"] isEqual:@"regulated"],"view receives query for highlight");
    CHECK([[reopened chatsMatchingQuery:@"Power supply sizing"][0][@"snippet"] length]==0,"title matches do not show redundant excerpts");
    CHECK([reopened renameFolder:folder name:@"Electronics" error:nil],"rename folder");
    CHECK([reopened removeFolder:folder error:nil],"remove folder");
    CHECK([[reopened chatWithID:identifier][@"folder"] isEqual:@""],"removing folder keeps chat in unfiled");
    CHECK(![reopened moveChat:identifier toFolder:NSUUID.UUID.UUIDString error:nil],"invalid destination rejected");
    NSDictionary* snapshot=[store organizationSnapshot];
    NSArray* batch=@[@{@"operation":@"create_folder",@"name":@"Switches"},
        @{@"operation":@"move_chat",@"chatID":identifier,@"folderName":@"Switches"},
        @{@"operation":@"rename_chat",@"chatID":identifier,@"name":@"Travel dimensions"}];
    NSProgress* progress=[NSProgress progressWithTotalUnitCount:1];
    NSDictionary* receipt=[store organizeChats:batch expectedRevision:snapshot[@"revision"] progress:progress error:nil];
    CHECK(receipt && [[store chatWithID:identifier][@"title"] isEqual:@"Travel dimensions"],"one atomic AI batch creates, moves and renames");
    CHECK(![store organizeChats:batch expectedRevision:snapshot[@"revision"] progress:progress error:nil],"stale batch rejected");
    NSDictionary* redo=[store swapOrganizationReceipt:receipt progress:progress error:nil];
    CHECK(redo && [[store chatWithID:identifier][@"title"] isEqual:@"Power supply sizing"],"undo restores all chat organization");
    NSDictionary* undo=[store swapOrganizationReceipt:redo progress:progress error:nil];
    CHECK(undo && [[store chatWithID:identifier][@"title"] isEqual:@"Travel dimensions"],"redo restores batch");
    [store renameChat:identifier title:@"Human edit" error:nil];
    CHECK(![store swapOrganizationReceipt:undo progress:progress error:nil],"undo cannot overwrite human rename");
    snapshot=[store organizationSnapshot];
    CHECK((![store organizeChats:@[@{@"operation":@"create_folder",@"name":@"Rollback"},@{@"operation":@"move_chat",@"chatID":@"missing",@"folderName":@"Rollback"}]
        expectedRevision:snapshot[@"revision"] progress:progress error:nil]),"invalid batch fails atomically");
    CHECK([[store organizationSnapshot][@"revision"] isEqual:snapshot[@"revision"]],"invalid batch writes nothing");
    [progress cancel];CHECK(![store organizeChats:batch expectedRevision:snapshot[@"revision"] progress:progress error:nil],"cancelled batch writes nothing");
    CHECK([reopened deleteChatWithID:identifier error:nil],"delete chat");
    CHECK(![reopened setSuggestedTitle:@"late" forChatID:identifier error:nil],"late title response cannot resurrect deleted chat");
    NSURL* organizationURL=[root URLByAppendingPathComponent:@".organization.json"];
    NSDictionary* metadata=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:organizationURL] options:0 error:nil];
    CHECK(!metadata[@"chats"][identifier],"deleting chat also removes its renamed title and folder record");
    NSData* malformed=[@"{\"folders\":[42],\"chats\":{}}" dataUsingEncoding:NSUTF8StringEncoding];
    [malformed writeToURL:organizationURL atomically:YES];
    CHECK(!store.folders.count && ![store createFolderNamed:@"Do not overwrite damaged data" error:nil],"malformed organization is safe and cannot be overwritten silently");
    CHECK([[NSData dataWithContentsOfURL:organizationURL] isEqual:malformed],"damaged metadata preserved for recovery");
    [NSFileManager.defaultManager removeItemAtURL:root error:nil];
    printf("Chat organization: %s\n",failures ? "FAILED" : "passed");return failures ? 1 : 0;
}}
