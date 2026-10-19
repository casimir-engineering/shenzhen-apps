#import "SPDFMacFriendsChatTools.h"
#import "SPDFMacAIChatStore.h"
#import "SPDFMacFriendsChatHistory.h"

NSSet<NSString*>* SPDFMacFriendsReadOnlyToolNames(void) {
    static NSSet* names;
    static dispatch_once_t once;
    // Each of these only returns information; show_document, which merely navigates, is still left out, because a
    // message could otherwise steer what the person sees next. list_chats stays: it never matches a chat holding
    // Friends results by what that chat says (SPDFMacAIChatTitleSearchOnlyKey), so it cannot bring in another friend.
    dispatch_once(&once, ^{
        names = [NSSet setWithArray:@[@"list_workspace", @"document_metadata", @"read_pages", @"search_documents",
                                      @"render_page", @"list_collection", @"current_view", @"reader_state",
                                      @"list_chats", SPDFMacFriendsSearchToolName, SPDFMacFriendsReadToolName]];
    });
    return names;
}

static NSString* const kReadOnlyAfterChats = @"This request includes Friends messages, so it can only read: nothing "
    "in a friend's message can make changes. Tell the user to ask again in a new message, without @, to make this "
    "change.";

@implementation SPDFMacFriendsScopedChatTools

- (instancetype)initWithTools:(id<SPDFMacAIChatTools>)tools gate:(SPDFMacFriendsChatScopeGate*)gate {
    if (!(self = [super init])) return nil;
    _tools = tools;
    _gate = gate;
    return self;
}

- (void)performTool:(NSString*)name arguments:(NSDictionary*)arguments completion:(void (^)(NSDictionary*))completion {
    if (SPDFMacFriendsIsChatTool(name)) {
        [self.gate performTool:name arguments:arguments completion:completion];
        return;
    }
    if (self.gate.requestIsReadOnly && ![SPDFMacFriendsReadOnlyToolNames() containsObject:name]) {
        completion(@{@"error" : kReadOnlyAfterChats});
        return;
    }
    [self.tools performTool:name arguments:arguments completion:completion];
}

- (BOOL)canUndo { return self.tools.canUndo; }
- (BOOL)canRedo { return [self.tools respondsToSelector:@selector(canRedo)] && self.tools.canRedo; }

// The session cancels its tools when a request is stopped, a chat is replaced, or saving fails: each ends the
// request, so the Friends scope closes with it.
- (void)cancel {
    [self.gate endRequest];
    [self.tools cancel];
}

- (BOOL)undoLastAction:(NSError**)error { return [self.tools undoLastAction:error]; }

- (NSDictionary*)conversationContext {
    return [self.tools respondsToSelector:@selector(conversationContext)] ? [self.tools conversationContext] : nil;
}

- (void)undoWithCompletion:(void (^)(NSDictionary*))completion {
    if ([self.tools respondsToSelector:@selector(undoWithCompletion:)]) [self.tools undoWithCompletion:completion];
    else completion(@{@"error" : @"No action available."});
}

- (void)redoWithCompletion:(void (^)(NSDictionary*))completion {
    if ([self.tools respondsToSelector:@selector(redoWithCompletion:)]) [self.tools redoWithCompletion:completion];
    else completion(@{@"error" : @"No action available."});
}

// Friends excerpts never reach the chat file (SPDFMacFriendsChatHistory.h § What is kept).
- (NSDictionary*)chatForStorage:(NSDictionary*)chat {
    if ([self.tools respondsToSelector:@selector(chatForStorage:)]) chat = [self.tools chatForStorage:chat] ?: chat;
    NSArray* messages = chat[@"messages"];
    if (![messages isKindOfClass:NSArray.class] || !SPDFMacFriendsChatHoldsFriendsResults(messages)) return chat;
    NSMutableDictionary* stored = [chat mutableCopy];
    stored[@"messages"] = SPDFMacFriendsStoredChatHistory(messages);
    stored[SPDFMacAIChatTitleSearchOnlyKey] = @YES;
    return stored;
}

- (NSArray<NSDictionary*>*)messagesForTitle:(NSArray<NSDictionary*>*)messages {
    if ([self.tools respondsToSelector:@selector(messagesForTitle:)])
        messages = [self.tools messagesForTitle:messages] ?: messages;
    return SPDFMacFriendsTitleChatHistory(messages);
}

@end

@implementation SPDFMacFriendsScopedTransport {
    SPDFMacAITransport* _transport;
    SPDFMacFriendsChatScopeGate* _gate;
}

- (instancetype)initWithTransport:(SPDFMacAITransport*)transport gate:(SPDFMacFriendsChatScopeGate*)gate {
    // The superclass's construction is inert (no session, no credentials), and it is never used to send.
    if (!(self = [super initWithConfiguration:nil])) return nil;
    _transport = transport;
    _gate = gate;
    return self;
}

- (SPDFMacAIRequestToken*)sendMessages:(NSArray<NSDictionary*>*)messages tools:(NSArray<NSDictionary*>*)tools
                                 model:(NSString*)model apiKey:(NSString*)apiKey
                            completion:(void (^)(NSDictionary*, NSError*))completion {
    NSArray* scoped = _gate.toolDefinitionsForCurrentRequest;
    NSArray* offered = tools && scoped.count ? [tools arrayByAddingObjectsFromArray:scoped] : tools;
    SPDFMacFriendsChatScopeGate* gate = _gate;
    BOOL holdsChats = NO;
    NSArray* sent = SPDFMacFriendsRedactChatHistory(messages, ^BOOL(NSSet<NSString*>* conversations) {
        return [gate scopeCoversConversations:conversations];
    }, &holdsChats);
    // Recorded before the request goes out, so a tool call in its reply already finds the request read-only.
    if (holdsChats) [gate noteRequestContextHoldsChats];
    return [_transport sendMessages:sent tools:offered model:model apiKey:apiKey completion:completion];
}

@end
