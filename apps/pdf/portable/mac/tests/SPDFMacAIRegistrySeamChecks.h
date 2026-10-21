// The registry: routing, offers, refusals, read-only filtering, fan-out and discovery. Included by
// SPDFMacAIToolSeamTests.mm.
#pragma once

static NSDictionary* SeamRun(SPDFMacAIToolRegistry* registry, NSString* name, SPDFMacAIRequestContext* context) {
    __block NSDictionary* result = nil;
    __block NSUInteger completions = 0;
    [registry performTool:name arguments:@{} context:context completion:^(NSDictionary* r) {
        result = r; completions++;
    }];
    CHECK(completions == 1, "a tool call completes exactly once");
    return result;
}

static SPDFMacAIRequestContext* SeamContext(NSArray* chips) {
    return [[SPDFMacAIRequestContext alloc] initWithText:@"question" chips:chips origin:SPDFMacAIRequestOriginChat
                                      friendConversation:nil settings:nil budget:nil activity:nil];
}

@interface SeamDiscoveryOwner : NSObject
@property NSUInteger calls;
@end
@implementation SeamDiscoveryOwner
- (id<SPDFMacAIToolProvider>)aiToolProviderZed {
    self.calls++; return [[SeamProvider alloc] initWithIdentifier:@"zed" tools:@{}];
}
- (id<SPDFMacAIToolProvider>)aiToolProviderAlpha {
    self.calls++; return [[SeamProvider alloc] initWithIdentifier:@"alpha" tools:@{}];
}
- (id<SPDFMacAIToolProvider>)aiToolProviderNone { self.calls++; return nil; }
- (id<SPDFMacAIToolProvider>)aiToolProviderWithArgument:(id)argument { (void)argument; self.calls += 100; return nil; }
- (id)aiToolProvider { self.calls += 100; return nil; }
@end

// A tools object that reports to the chat (the reader's, for a saved document's card): takes the request's context.
@interface SeamContextTools : NSObject <SPDFMacAIChatTools>
@property(nonatomic) SPDFMacAIRequestContext* context;
@property(nonatomic) NSUInteger plainCalls;
@end
@implementation SeamContextTools
- (void)performTool:(NSString*)name arguments:(NSDictionary*)arguments completion:(void (^)(NSDictionary*))completion {
    (void)name; (void)arguments; self.plainCalls++; completion(@{});
}
- (void)performTool:(NSString*)name arguments:(NSDictionary*)arguments context:(SPDFMacAIRequestContext*)context
         completion:(void (^)(NSDictionary*))completion {
    (void)name; (void)arguments; self.context = context; completion(@{});
}
- (BOOL)canUndo { return NO; }
- (void)cancel {}
- (BOOL)undoLastAction:(NSError**)error { (void)error; return NO; }
@end

static void CheckRegistry(void) {
    SPDFMacAIToolRegistry* registry = [SPDFMacAIToolRegistry new];
    SeamProvider* reader = [[SeamProvider alloc] initWithIdentifier:@"reader" tools:@{@"read_pages" : @YES,
                                                                                       @"rename_document" : @NO}];
    SeamProvider* web = [[SeamProvider alloc] initWithIdentifier:@"web" tools:@{@"web_search" : @YES,
                                                                                 @"read_pages" : @YES}];
    // Offered only to a request whose person attached a Friends chip.
    SeamProvider* send = [[SeamProvider alloc] initWithIdentifier:@"send" tools:@{@"friends_send_message" : @NO}];
    send.offers = ^BOOL(NSString* name, SPDFMacAIRequestContext* context) {
        (void)name; return [context chipsOfKind:SPDFMacAIChipKindFriends].count > 0;
    };
    send.unavailableMessage = @"Sending needs an @ chip.";
    CHECK([registry registerProvider:reader error:nil] && [registry registerProvider:web error:nil] &&
          [registry registerProvider:send error:nil], "providers register");
    NSError* error = nil;
    CHECK(![registry registerProvider:[[SeamProvider alloc] initWithIdentifier:@"web" tools:@{}] error:&error] &&
          error && registry.providers.count == 3, "a second provider with a taken name is refused");

    SPDFMacAIRequestContext* plain = SeamContext(nil);
    NSArray* names = SeamNames([registry toolDefinitionsForContext:plain]);
    CHECK([names isEqual:@[@"read_pages", @"rename_document", @"web_search"]],
          "definitions come per request; a later claim on a taken name is dropped, never duplicated");
    CHECK([SeamRun(registry, @"read_pages", plain)[@"tool"] isEqual:@"read_pages"] &&
          [reader.ran isEqual:@[@"read_pages"]] && !web.ran.count, "a call reaches the provider that owns the name");
    CHECK([SeamRun(registry, @"format_disk", plain)[@"error"] isEqual:@"Unknown tool."], "unknown names are refused");
    NSDictionary* refused = SeamRun(registry, @"friends_send_message", plain);
    CHECK([refused[@"error"] isEqual:@"Sending needs an @ chip."] && !send.ran.count,
          "a tool the request does not offer is refused before its provider runs it");
    SPDFMacAIRequestContext* scoped = SeamContext(@[[SPDFMacAIRequestChip friendsChipWithConversationIDs:@[@"c_mei"]
                                                                                             displayName:@"Mei"]]);
    CHECK([SeamNames([registry toolDefinitionsForContext:scoped]) containsObject:@"friends_send_message"] &&
          !SeamRun(registry, @"friends_send_message", scoped)[@"error"] && send.contexts.lastObject == scoped,
          "the chip offers the tool, and the provider receives the request's own context");

    reader.readOnlyReason = @"This request can only read.";
    CHECK([SeamRun(registry, @"rename_document", plain)[@"error"] isEqual:@"This request can only read."] &&
          ![reader.ran containsObject:@"rename_document"] && !SeamRun(registry, @"web_search", plain)[@"error"],
          "while a provider says the request may only read, only read-only tools run");
    reader.readOnlyReason = nil;

    SPDFMacAIToolRegistry* tasks = [registry registryWithFilter:SPDFMacAIToolFilter.readOnly];
    CHECK([SeamNames([tasks toolDefinitionsForContext:scoped]) isEqual:@[@"read_pages", @"web_search"]],
          "a read-only registry offers read-only tools only");
    NSUInteger ran = send.ran.count;
    CHECK([SeamRun(tasks, @"friends_send_message", scoped)[@"error"] containsString:@"can only read"] &&
          send.ran.count == ran && [SeamRun(tasks, @"rename_document", plain)[@"error"] length],
          "a read-only registry refuses changes before any provider sees them");
    SPDFMacAIToolRegistry* webOnly = [registry registryWithFilter:
        [SPDFMacAIToolFilter readOnlyFromProviders:[NSSet setWithObject:@"web"]]];
    CHECK([SeamNames([webOnly toolDefinitionsForContext:plain]) isEqual:@[@"web_search"]] &&
          [SeamRun(webOnly, @"read_pages", plain)[@"error"] length], "a filter can name the providers it keeps");
    SPDFMacAIToolRegistry* widened = [webOnly registryWithFilter:SPDFMacAIToolFilter.readOnly];
    CHECK([SeamNames([widened toolDefinitionsForContext:plain]) isEqual:@[@"web_search"]],
          "filters combine: a wider filter never widens a narrower one");

    [registry beginRequestWithContext:plain];
    [registry endRequestWithContext:plain];
    [registry cancel];
    CHECK(reader.begins == 1 && web.ends == 1 && send.cancels == 1, "begin, end and cancel reach every provider");
    reader.wireReplace = @"secret";
    web.storageMark = @"webStored";
    reader.chips = @[[SPDFMacAIRequestChip attachmentChipWithFileURL:[NSURL fileURLWithPath:@"/tmp/a.png"]
                                                         displayName:@"a.png"]];
    NSArray* wire = [registry messagesForRequest:@[@{@"role" : @"tool", @"content" : @"a secret"}] context:plain];
    CHECK([wire.firstObject[@"content"] isEqual:@"a [kept out]"], "each turn's messages pass through providers");
    CHECK([[registry chatForStorage:@{@"messages" : @[]}][@"webStored"] isEqual:@YES],
          "storage passes through providers");
    CHECK([registry requestChipsInComposerText:[[NSAttributedString alloc] initWithString:@"x"]].count == 1 &&
          ![registry requestChipsInComposerText:nil].count, "chips come from providers that read the composer");

    SeamReaderTools* tools = [SeamReaderTools new];
    SPDFMacAIChatToolsProvider* adapter = [[SPDFMacAIChatToolsProvider alloc] initWithIdentifier:@"reader" tools:tools
        definitions:@[SeamDefinition(@"read_pages"), SeamDefinition(@"rename_document")]
        readOnlyTools:SPDFMacAIReaderReadOnlyToolNames()];
    SPDFMacAIToolRegistry* readerRegistry = [SPDFMacAIToolRegistry new];
    [readerRegistry registerProvider:adapter error:nil];
    SeamRun(readerRegistry, @"rename_document", plain);
    CHECK([adapter isReadOnlyTool:@"read_pages"] && ![adapter isReadOnlyTool:@"rename_document"] &&
          [tools.ran isEqual:@[@"rename_document"]] && readerRegistry.canUndo && [readerRegistry undoLastAction:nil] &&
          tools.undos == 1 && [[readerRegistry conversationContext][@"page"] isEqual:@3],
          "the reader's tools object works as a provider, Undo and context included");
    CHECK([SPDFMacAIReaderReadOnlyToolNames() containsObject:@"search_documents"] &&
          ![SPDFMacAIReaderReadOnlyToolNames() containsObject:@"show_document"],
          "navigation is not read-only: text just read could steer what the person sees");
    SPDFMacAIToolRegistry* legacy = [[SPDFMacAIToolRegistry alloc] initWithLegacyTools:tools definitions:@[]];
    CHECK(!SeamRun(legacy, @"friends_search_chats", plain)[@"error"] &&
          [tools.ran.lastObject isEqual:@"friends_search_chats"],
          "the original initializer still hands every call to its tools object");
    SeamContextTools* reporting = [SeamContextTools new];
    SPDFMacAIToolRegistry* reportingRegistry = [SPDFMacAIToolRegistry new];
    [reportingRegistry registerProvider:[[SPDFMacAIChatToolsProvider alloc] initWithIdentifier:@"reader"
        tools:reporting definitions:@[SeamDefinition(@"document_job")] readOnlyTools:[NSSet set]] error:nil];
    SeamRun(reportingRegistry, @"document_job", plain);
    CHECK(reporting.context == plain && !reporting.plainCalls,
          "a tools object that takes the request's context gets it, so its cards reach the request's chat");

    SeamDiscoveryOwner* owner = [SeamDiscoveryOwner new];
    NSArray* found = SPDFMacAIDiscoverToolProviders(owner);
    CHECK(found.count == 2 && [[found valueForKey:@"providerIdentifier"] isEqual:@[@"alpha", @"zed"]] &&
          owner.calls == 3,
          "providers are found by their aiToolProvider<Name> methods, in name order, skipping nil and other shapes");
}
