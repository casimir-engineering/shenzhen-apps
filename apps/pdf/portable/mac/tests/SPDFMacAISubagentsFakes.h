// A scripted model that answers each conversation separately (the main chat and every task talk to it at once), and
// a chat wired the way the reader wires it: providers through the registry, run_subagents among them. Builds on the
// tool seam's fakes (SeamProvider and the CHECK macro).
#pragma once
#import <Foundation/Foundation.h>
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-function"
#import "SPDFMacAIToolSeamFakes.h"
#pragma clang diagnostic pop
#import "SPDFMacAISubagents.h"
#import "SPDFMacAISubagentsResults.h"
#import "SPDFMacAICitations.h"

// One request the model received; `reply` answers it.
@interface TaskTurn : NSObject
@property NSArray* messages;
@property NSArray* tools;
@property NSString* key;
@property(copy) void (^reply)(NSDictionary*, NSError*);
@property BOOL answered;
@end
@implementation TaskTurn
- (NSString*)system { return self.messages.firstObject[@"content"]; }
// The newest user message: the request this turn belongs to (a chat holds every earlier request too).
- (NSString*)user {
    for (NSDictionary* message in self.messages.reverseObjectEnumerator)
        if ([message[@"role"] isEqual:@"user"]) return message[@"content"];
    return nil;
}
// The tool result answering `callID`, parsed.
- (NSDictionary*)resultFor:(NSString*)callID {
    for (NSDictionary* message in self.messages)
        if ([message[@"role"] isEqual:@"tool"] && [message[@"tool_call_id"] isEqual:callID])
            return [NSJSONSerialization JSONObjectWithData:[message[@"content"] dataUsingEncoding:NSUTF8StringEncoding]
                                                   options:0 error:nil];
    return nil;
}
- (BOOL)wireContains:(NSString*)text {
    NSData* data = [NSJSONSerialization dataWithJSONObject:self.messages ?: @[] options:0 error:nil];
    return [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] containsString:text];
}
@end

@interface TaskModel : SPDFMacAITransport
@property NSMutableArray<TaskTurn*>* turns;
@end
@implementation TaskModel
- (instancetype)init {
    if ((self = [super init])) _turns = [NSMutableArray array];
    return self;
}
- (SPDFMacAIRequestToken*)sendMessages:(NSArray*)messages tools:(NSArray*)tools model:(NSString*)model
                                apiKey:(NSString*)key completion:(void (^)(NSDictionary*, NSError*))completion {
    (void)model;
    TaskTurn* turn = [TaskTurn new];
    turn.messages = messages; turn.tools = tools; turn.key = key; turn.reply = completion;
    [self.turns addObject:turn];
    return [SPDFMacAIRequestToken new];
}
@end

// The newest unanswered turn of the main chat's request `person` (its user message exactly), or of the task whose
// instructions hold `marker`.
static TaskTurn* MainTurn(TaskModel* model, NSString* person) {
    for (TaskTurn* turn in model.turns.reverseObjectEnumerator)
        if (!turn.answered && [turn.user isEqual:person]) return turn;
    return nil;
}
static TaskTurn* TaskTurnFor(TaskModel* model, NSString* marker) {
    for (TaskTurn* turn in model.turns.reverseObjectEnumerator)
        if (!turn.answered && [turn.user containsString:marker]) return turn;
    return nil;
}
static void Reply(TaskTurn* turn, NSDictionary* reply) {
    CHECK(turn != nil && !turn.answered, "the scripted model has that request waiting");
    if (!turn || turn.answered) return;
    turn.answered = YES;
    turn.reply(reply, nil);
}
static NSDictionary* WithUsage(NSDictionary* reply, NSUInteger tokens) {
    NSMutableDictionary* reported = [reply mutableCopy];
    reported[@"usage"] = @{@"total_tokens" : @(tokens)};
    return reported;
}
static NSDictionary* Job(NSString* title, NSString* instructions) {
    return @{@"title" : title, @"instructions" : instructions};
}
static NSDictionary* RunCall(NSString* identifier, NSArray* tasks) {
    NSData* data = [NSJSONSerialization dataWithJSONObject:@{@"tasks" : tasks} options:0 error:nil];
    return @{@"id" : identifier, @"type" : @"function", @"function" : @{@"name" : @"run_subagents",
             @"arguments" : [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]}};
}
static NSString* JSONText(id value) {
    NSData* data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

// Friends as SPDFMacFriendsToolProvider runs it, reduced to what the seam sees: the request's `@` chip opens a scope,
// reading a chat makes the rest of the request read-only, and -cancel or the request's end closes the scope and lifts
// that rule (the real provider's -cancel ends the gate's request). So a stray -cancel in the middle of a request does
// here exactly what it would do in the app.
@interface FriendsGateProvider : SeamProvider
@property BOOL scopeOpen, readChats;
@end
@implementation FriendsGateProvider
+ (instancetype)gate {
    FriendsGateProvider* gate = [[self alloc] initWithIdentifier:@"friends" tools:@{@"friends_search_chats" : @YES}];
    __weak FriendsGateProvider* weakGate = gate;
    gate.offers = ^BOOL(NSString* name, SPDFMacAIRequestContext* context) {
        (void)name; (void)context;
        return weakGate.scopeOpen;
    };
    return gate;
}
- (void)closeScope { self.scopeOpen = NO; self.readChats = NO; }
- (void)beginRequestWithContext:(SPDFMacAIRequestContext*)context {
    [super beginRequestWithContext:context];
    self.scopeOpen = [context chipsOfKind:SPDFMacAIChipKindFriends].count > 0;
    self.readChats = NO;
}
- (void)endRequestWithContext:(SPDFMacAIRequestContext*)context {
    [super endRequestWithContext:context];
    [self closeScope];
}
- (void)cancel { [super cancel]; [self closeScope]; }
- (NSString*)readOnlyReasonForContext:(SPDFMacAIRequestContext*)context {
    (void)context;
    return self.readChats ? @"This request includes Friends messages, so it can only read." : nil;
}
- (void)performTool:(NSString*)name arguments:(NSDictionary*)arguments context:(SPDFMacAIRequestContext*)context
         completion:(SPDFMacAIToolCompletion)completion {
    if (self.scopeOpen) self.readChats = YES;
    [super performTool:name arguments:arguments context:context completion:completion];
}
@end

typedef struct {
    NSString* root;
    SPDFMacAIChatStore* store;
    TaskModel* model;
    SeamProvider* reader;  // "reader": read_pages reads; rename_document and app_controls change things
    FriendsGateProvider* friends; // "friends": friends_search_chats, read-only but never for tasks
    SeamProvider* send;    // "send": friends_send_message
    SeamProvider* web;     // "web": web_search, read-only and allowlisted
    SeamProvider* notes;   // "notes": notes_read, read-only but not on the allowlist
    SPDFMacAISubagentsProvider* subagents;
    SPDFMacAIChatSession* session;
} TaskChat;

static TaskChat MakeTaskChat(NSString* name) {
    TaskChat chat;
    chat.root = SeamTemporaryDirectory(name);
    chat.store = [[SPDFMacAIChatStore alloc] initWithDirectory:[NSURL fileURLWithPath:chat.root]];
    chat.model = [TaskModel new];
    chat.reader = [[SeamProvider alloc] initWithIdentifier:@"reader" tools:@{@"read_pages" : @YES,
        @"rename_document" : @NO, @"app_controls" : @NO}];
    chat.friends = [FriendsGateProvider gate];
    chat.send = [[SeamProvider alloc] initWithIdentifier:@"send" tools:@{@"friends_send_message" : @NO}];
    chat.web = [[SeamProvider alloc] initWithIdentifier:@"web" tools:@{@"web_search" : @YES}];
    chat.notes = [[SeamProvider alloc] initWithIdentifier:@"notes" tools:@{@"notes_read" : @YES}];
    chat.subagents = [SPDFMacAISubagentsProvider new];
    SPDFMacAIToolRegistry* registry = [SPDFMacAIToolRegistry new];
    for (id<SPDFMacAIToolProvider> provider in @[chat.reader, chat.friends, chat.send, chat.web, chat.notes,
                                                 chat.subagents])
        [registry registerProvider:provider error:nil];
    chat.session = [[SPDFMacAIChatSession alloc] initWithTransport:chat.model registry:registry store:chat.store];
    return chat;
}

static void EndTaskChat(TaskChat chat) {
    [chat.session cancel];
    SeamRunLoop(0.02); // let released task sessions go before their folder does
    [NSFileManager.defaultManager removeItemAtPath:chat.root error:nil];
}

static SPDFMacAISettingsSnapshot* TaskSettings(BOOL subagents) {
    // Constructing settings reads nothing; the path only names where -save: would write, which no check calls.
    SPDFMacAISettings* settings = [[SPDFMacAISettings alloc] initWithURL:[NSURL fileURLWithPath:
        [NSTemporaryDirectory() stringByAppendingPathComponent:@"spdf-subagents-unused-settings.yaml"]]];
    settings.aiSubagentsEnabled = subagents;
    return settings.snapshot;
}

static SPDFMacAIRequestContext* TaskRequest(TaskChat chat, NSString* text, NSArray* chips,
                                            SPDFMacAIRequestBudget* budget, SPDFMacAISettingsSnapshot* settings) {
    return [[SPDFMacAIRequestContext alloc] initWithText:text chips:chips origin:SPDFMacAIRequestOriginChat
                                      friendConversation:nil settings:settings budget:budget
                                                activity:chat.session.activity];
}

static void Ask(TaskChat chat, NSString* person, SPDFMacAIRequestBudget* budget) {
    [chat.session sendContext:TaskRequest(chat, person, nil, budget, TaskSettings(YES)) model:@"fake/model"
                       apiKey:@"TEST-NOT-A-KEY"];
}

// The step rows in the chat, oldest first.
static NSArray<NSDictionary*>* Rows(TaskChat chat) {
    return [chat.session.activity.entries filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"%K == %@",
        SPDFMacAIActivityKindKey, SPDFMacAIActivityKindStep]];
}
