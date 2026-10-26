#import <Foundation/Foundation.h>
#import "SPDFMacAIChatSession.h"
#import "SPDFMacAIChatStore.h"
#import "SPDFMacAICitations.h"
#import "SPDFMacAITransport.h"
static int failures;
#define CHECK(c,m) do { if (!(c)) { fprintf(stderr,"FAIL: %s\n",m); ++failures; } } while(0)
@interface FakeTransport : SPDFMacAITransport
@property(copy) void (^reply)(NSDictionary*,NSError*);
@property NSArray* messages;
@property NSArray* definitions;
@property NSUInteger sends;
@end
@implementation FakeTransport
- (SPDFMacAIRequestToken*)sendMessages:(NSArray*)messages tools:(NSArray*)tools model:(NSString*)model apiKey:(NSString*)key completion:(void (^)(NSDictionary*,NSError*))completion {
    (void)model; (void)key; self.definitions=tools; self.messages=messages; self.reply=completion; self.sends++;
    return [SPDFMacAIRequestToken new];
}
@end
@interface FakeTools : NSObject <SPDFMacAIChatTools>
@property NSUInteger calls;
@property NSUInteger cancellations;
@property NSUInteger contextReads;
@property NSString* lastName;
@property NSDictionary* lastArguments;
@property(copy) void (^reply)(NSDictionary*);
@end
@implementation FakeTools
- (void)performTool:(NSString*)name arguments:(NSDictionary*)args completion:(void (^)(NSDictionary*))completion {
    self.lastName=name; self.lastArguments=args; self.calls++; self.reply=completion;
}
- (NSDictionary*)conversationContext {self.contextReads++;return @{@"path":@"doc:active-fixture",@"title":@"Active drawing",@"page":@1};}
- (void)cancel { self.cancellations++; }
- (BOOL)canUndo { return self.calls>0; }
- (BOOL)undoLastAction:(NSError**)error { (void)error; return YES; }
@end
#import "SPDFMacAIChatSnapshotChecks.h"
#import "SPDFMacAIChatCompletionChecks.h"
#import "SPDFMacAIChatVisionChecks.h"
#import "SPDFMacAIReasoningChecks.h"
#import "SPDFMacAICitationRecoveryChecks.h"
#import "SPDFMacAIDocumentLinkChecks.h"
#import "SPDFMacAISourceLinkChecks.h"
#import "SPDFMacAIAnswerCardChecks.h"
#import "SPDFMacAIChatCompactionChecks.h"
#import "SPDFMacAIChatContextRetryChecks.h"
#import "SPDFMacAIChatRewriteChecks.h"
#import "SPDFMacAIToolArgumentChecks.h"
#import "SPDFMacAIChatLongTaskChecks.h"
int main(void) { @autoreleasepool {
    NSURL* citation=[NSURL URLWithString:@"spdf-ai://document?path=doc:fixture&page=2&revision=abc"];
    NSDictionary* arguments=SPDFMacAICitationArguments(citation);
    CHECK([arguments[@"page"] isEqual:@2],"citation page is strongly typed");
    CHECK(!SPDFMacAICitationArguments([NSURL URLWithString:@"spdf-ai://document?path=doc:x&page=2&page=3&revision=a"]),"duplicate citation parameters rejected");
    NSDictionary* cited=@{@"messages":@[@{@"role":@"tool",@"content":@"{\"pages\":[{\"citation\":\"spdf-ai://document?path=doc:fixture&page=2&revision=abc\"}]}"}]};
    CHECK(SPDFMacAIChatContainsCitation(cited,arguments),"retrieved citation is clickable");
    CHECK(!SPDFMacAIChatContainsCitation(@{@"messages":@[@{@"role":@"assistant",@"content":citation.absoluteString}]},arguments),"model-fabricated citation is not evidence");
    NSURL* root=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    NSURL* snapshotRoot=[root URLByAppendingPathExtension:@"snapshots"];
    CheckChatSnapshots(snapshotRoot);
    CheckStoreSnapshot([snapshotRoot URLByAppendingPathComponent:@"store"]);
    CheckSessionConflict([snapshotRoot URLByAppendingPathComponent:@"conflict"]);
    CheckChatCompletion([snapshotRoot URLByAppendingPathComponent:@"completion"]);
    CheckLongTasks([snapshotRoot URLByAppendingPathComponent:@"long-tasks"]);
    CheckChatVision([snapshotRoot URLByAppendingPathComponent:@"vision"]);
    CheckReasoning([snapshotRoot URLByAppendingPathComponent:@"reasoning"]);
    CheckAnswerCards([snapshotRoot URLByAppendingPathComponent:@"answer-cards"]);
    CheckCitationRecovery([snapshotRoot URLByAppendingPathComponent:@"citation-recovery"]);
    CheckDocumentLinks();
    CheckSourceLinks();
    CheckBudgetMath();
    CheckAutomaticCompaction([snapshotRoot URLByAppendingPathComponent:@"compaction"]);
    CheckManualCompaction([snapshotRoot URLByAppendingPathComponent:@"manual-compaction"]);
    CheckEditAndResend([snapshotRoot URLByAppendingPathComponent:@"edit"]);
    CheckContextLengthRetry([snapshotRoot URLByAppendingPathComponent:@"context-retry"]);
    CheckHistoryRewrites([snapshotRoot URLByAppendingPathComponent:@"rewrites"]);
    CheckToolArgumentRecovery([snapshotRoot URLByAppendingPathComponent:@"tool-arguments"]);
    [NSFileManager.defaultManager removeItemAtURL:snapshotRoot error:nil];
    SPDFMacAIChatStore* store=[[SPDFMacAIChatStore alloc] initWithDirectory:root];
    FakeTransport* transport=[FakeTransport new]; FakeTools* tools=[FakeTools new];
    SPDFMacAIChatSession* session=[[SPDFMacAIChatSession alloc] initWithTransport:transport tools:tools definitions:@[] store:store];
    CHECK(![NSFileManager.defaultManager fileExistsAtPath:root.path],"construction is disk-inert");
    CHECK(!transport.sends && !tools.contextReads,"construction is network-inert and does not request reader context");
    session.defaultLanguage=@"fr";
    [session send:@"Explain this document" model:@"fake/model" apiKey:@"TEST-SECRET-NOT-PERSISTED"];
    CHECK(transport.sends==1 && session.running,"explicit send starts request");
    NSString* system=transport.messages.firstObject[@"content"];
    CHECK(tools.contextReads==1 && [system containsString:@"doc:active-fixture"] && [system containsString:@"active document"] && [system containsString:@"Use render_page when visual content or layout matters"],"explicit send carries focused context and general evidence selection instructions");
    CHECK([system containsString:@"Be as brief as possible"] && [system containsString:@"follow the user's specifications closely"] &&
        [system containsString:@"Perform requested actions with tools"] && [system containsString:@"without emojis"] &&
        [system containsString:@"do not repeat the same arguments"],"system prompt requires brief, faithful, action-oriented responses");
    CHECK([system containsString:@"Default response language: French"] &&
        [system containsString:@"Explicit user language instructions take precedence"],"chat respects selected language with explicit user override");
    void (^late)(NSDictionary*,NSError*)=transport.reply;
    [session cancel]; CHECK(session.activityState==SPDFMacAIChatActivityStopped,"cancel reports stopped"); late(@{@"role":@"assistant",@"content":@"late"},nil);
    CHECK([session.chat[@"messages"] count]==1,"cancel discards late assistant response");
    [session send:@"Read page 1" model:@"fake/model" apiKey:@"TEST-SECRET-NOT-PERSISTED"];
    transport.reply(@{@"role":@"assistant",@"content":@"",@"tool_calls":@[
        @{@"id":@"call1",@"type":@"function",@"function":@{@"name":@"read_pages",@"arguments":@"{}"}},
        @{@"id":@"call2",@"type":@"function",@"function":@{@"name":@"show_document",@"arguments":@"{}"}}]},nil);
    CHECK(tools.calls==1,"tools execute sequentially");
    void (^lateTool)(NSDictionary*)=tools.reply; [session cancel]; lateTool(@{@"ok":@YES});
    CHECK(tools.calls==1,"cancel prevents queued second action");
    NSArray* messages=session.chat[@"messages"];
    CHECK([messages.lastObject[@"tool_call_id"] isEqual:@"call2"],"cancel closes all outstanding tool-call pairs");
    [session send:@"Continue" model:@"fake/model" apiKey:@"TEST-SECRET-NOT-PERSISTED"];
    transport.reply(@{@"role":@"assistant",@"content":@"Answer with evidence"},nil);
    CHECK(!session.running && !session.status.length,"completed answer clears running state");
    CHECK([store chats].count==1,"chat persisted");
    NSDictionary* loaded=[store chatWithID:session.chat[@"id"]];
    CHECK([loaded[@"messages"] count]==[session.chat[@"messages"] count],"complete history roundtrips");
    NSData* data=[NSJSONSerialization dataWithJSONObject:loaded options:0 error:nil];
    NSString* serialized=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    CHECK(![serialized containsString:@"TEST-SECRET"],"credentials excluded from persistence");
    CHECK(![store chatWithID:@"../../escape"],"chat identifiers reject path traversal");
    CHECK([session undo:nil],"explicit undo reaches tool action journal");
    [session newChat]; [session send:@"Second conversation" model:@"fake/model" apiKey:@"test"];
    transport.reply(@{@"role":@"assistant",@"content":@"Done"},nil);
    CHECK([store chats].count==2,"separate chat files preserve other conversation");
    [session newChat]; [session send:@"bad shape" model:@"fake/model" apiKey:@"test"];
    transport.reply(@{@"role":@"assistant",@"tool_calls":@[@"bad"]},nil);
    CHECK(session.running && [transport.messages.lastObject[@"content"] containsString:@"could not be read"],
        "malformed tool entries run nothing and are asked for again");
    transport.reply(@{@"role":@"assistant",@"content":@"Answered."},nil);
    NSUInteger callsBefore=tools.calls;
    [session send:@"bad arguments" model:@"fake/model" apiKey:@"test"];
    transport.reply(@{@"role":@"assistant",@"tool_calls":@[@{@"id":@"badargs",@"function":
        @{@"name":@"undo_action",@"arguments":@"not JSON"}}]},nil);
    for (int attempt=0;attempt<3;attempt++) // asked again three times, then the request winds up
        transport.reply(@{@"role":@"assistant",@"tool_calls":@[@{@"id":[NSString stringWithFormat:@"badargs-%d",attempt],
            @"function":@{@"name":@"undo_action",@"arguments":@"not JSON"}}]},nil);
    transport.reply(@{@"role":@"assistant",@"content":@"The undo could not be sent."},nil);
    CHECK(!session.running && tools.calls==callsBefore && session.canContinue,
        "invalid JSON cannot invoke a zero-argument mutation");
    NSString* sharedID=NSUUID.UUID.UUIDString;
    NSDictionary* base=@{@"id":sharedID,@"messages":@[@{@"role":@"user",@"content":@"base"}]};
    [store saveChat:base error:nil];
    SPDFMacAIChatStore* otherWindow=[[SPDFMacAIChatStore alloc] initWithDirectory:root];
    NSDictionary* branchA=@{@"id":sharedID,@"messages":[base[@"messages"] arrayByAddingObject:@{@"role":@"assistant",@"content":@"first window"}]};
    NSDictionary* branchB=@{@"id":sharedID,@"messages":[base[@"messages"] arrayByAddingObject:@{@"role":@"assistant",@"content":@"second window"}]};
    CHECK([store saveChat:branchA error:nil] && ![otherWindow saveChat:branchB error:nil],"stale concurrent chat writer cannot erase another window's answer");
    CHECK([[[store chatWithID:sharedID][@"messages"] lastObject][@"content"] isEqual:@"first window"],"concurrent conflict retains the committed transcript");
    CHECK([store deleteAll:nil] && ![store chats].count,"delete all removes only owned chat files");
    SPDFMacAIChatStore* second=[[SPDFMacAIChatStore alloc] initWithDirectory:root];
    CHECK(![second saveChat:loaded error:nil],"deleted chat cannot be resurrected by a stale writer");
    NSString* orphan=NSUUID.UUID.UUIDString;
    NSURL* malformed=[root URLByAppendingPathComponent:[orphan stringByAppendingPathExtension:@"json"]];
    [@"malformed" writeToURL:malformed atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSURL* assets=[root URLByAppendingPathComponent:[orphan stringByAppendingString:@"-assets"]];
    [NSFileManager.defaultManager createDirectoryAtURL:assets withIntermediateDirectories:YES attributes:nil error:nil];
    CHECK([store deleteAll:nil] && ![NSFileManager.defaultManager fileExistsAtPath:malformed.path] &&
        ![NSFileManager.defaultManager fileExistsAtPath:assets.path],"delete all cleans malformed and orphan transcript data");
    NSString* invalidID=NSUUID.UUID.UUIDString;
    NSDictionary* invalid=@{@"id":invalidID,@"messages":@[@{@"role":@"assistant",@"tool_calls":@[@"bad"]}]};
    CHECK([store saveChat:invalid error:nil] && ![store chatWithID:invalidID],"malformed stored actions rejected before resume");
    NSString* interruptedID=NSUUID.UUID.UUIDString;
    NSDictionary* interrupted=@{@"id":interruptedID,@"messages":@[@{@"role":@"assistant",@"tool_calls":@[
        @{@"id":@"pending",@"function":@{@"name":@"read_pages",@"arguments":@"{}"}}]}]};
    [store saveChat:interrupted error:nil];
    CHECK([[[store chatWithID:interruptedID][@"messages"] lastObject][@"tool_call_id"] isEqual:@"pending"],"interrupted stored action is completed as cancelled without replay");
    NSString* temp=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"ShenzhenPDF-AI-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:temp withIntermediateDirectories:YES attributes:nil error:nil];
    NSString* png=[temp stringByAppendingPathComponent:@"page.png"];
    const unsigned char bytes[]={137,80,78,71,13,10,26,10};
    [[NSData dataWithBytes:bytes length:sizeof(bytes)] writeToFile:png atomically:YES];
    CHECK(![store savePreview:@{@"path":png} chatID:loaded[@"id"]],"deleted chat cannot recreate preview assets");
    CHECK(![NSFileManager.defaultManager fileExistsAtPath:temp],"rejected preview cleans owned temporary directory");
    // current_view writes viewport.png: its folder is a preview folder too, and is gone once the chat keeps a copy.
    NSString* viewChat=NSUUID.UUID.UUIDString;
    [store saveChat:@{@"id":viewChat,@"messages":@[@{@"role":@"user",@"content":@"view"}]} error:nil];
    NSString* tmp=NSTemporaryDirectory(); NSFileManager* files=NSFileManager.defaultManager;
    NSString* view=[tmp stringByAppendingFormat:@"/ShenzhenPDF-AI-%@",NSUUID.UUID.UUIDString];
    NSString* other=[tmp stringByAppendingFormat:@"/ShenzhenPDF-AI-x%@",NSUUID.UUID.UUIDString];
    for (NSString* folder in @[view,other]) {
        [files createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
        [[NSData dataWithBytes:bytes length:sizeof(bytes)]
            writeToFile:[folder stringByAppendingPathComponent:@"viewport.png"] atomically:YES];
    }
    NSString* shot=[view stringByAppendingPathComponent:@"viewport.png"];
    CHECK([store savePreview:@{@"path":shot} chatID:viewChat] && ![files fileExistsAtPath:view],
        "a saved current_view preview leaves no temporary folder");
    [SPDFMacAIChatStore discardTemporaryPreview:@{@"path":[other stringByAppendingPathComponent:@"viewport.png"]}];
    CHECK([files fileExistsAtPath:other],"a folder whose name isn't a preview's is never removed");
    for (NSString* folder in @[view,other]) [NSFileManager.defaultManager removeItemAtPath:folder error:nil];
    [NSFileManager.defaultManager removeItemAtURL:root error:nil];
    fprintf(stderr,"AI chat session: %d failures\n",failures); return failures ? 1 : 0;
} }
