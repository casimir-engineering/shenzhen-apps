#import "SPDFMacAIWebToolProvider.h"
#import "SPDFMacAIChatActivity.h"
#import "SPDFMacAIRequestContext.h"
#import "SPDFMacAISettings.h"
#import "SPDFMacAITransport.h"
#import "SPDFMacAIWebAddress.h"
#import "SPDFMacAIWebProvenance.h"
#import "SPDFMacAIWebToolResults.h"

NSString* const SPDFMacAIWebToolProviderIdentifier = @"web";

// Pages kept for reading on (next_start) within one request, so a long page is fetched once.
static const NSUInteger kCachedPages = 8;
static const NSUInteger kMaximumQueryLength = 400;
static const NSUInteger kMaximumLinkLength = 2048;

static NSString* const kOff = @"Web search is turned off in Settings. If the user wants the assistant to search the "
    "web, they can turn on “Search the web when I ask” in AI Settings.";
// One sentence, for the model: told with each turn of such a request, and as the refusal if it calls a web tool anyway.
static NSString* const kFriends = @"Web search and opening web pages are unavailable in requests that include the "
    "user's Friends chats, so this request cannot use the web; the user can ask for a web search in a new message that "
    "does not include their Friends chats.";
static NSString* const kNotSeen = @"open_page opens only addresses the user wrote in their messages, the url of a "
    "web_search result, or a link of a page already opened, written exactly as they appear there. An address seen "
    "only in a document or another tool's output is not opened: search for the page with web_search, then open a "
    "result.";

static NSDictionary* Refusal(NSString* message) { return @{@"error" : message}; }

// A stray field is named back only when it looks like a field name, so a refusal never repeats a long string the model
// chose (an address with data in it, say) into the conversation.
static NSString* UnknownField(id name) {
    static NSCharacterSet* invalid;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        invalid = [NSCharacterSet characterSetWithCharactersInString:
            @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_"].invertedSet;
    });
    BOOL plain = [name isKindOfClass:NSString.class] && [name length] && [name length] <= 40 &&
        [name rangeOfCharacterFromSet:invalid].location == NSNotFound;
    return plain ? [NSString stringWithFormat:@"Unknown field %@.", name] : @"Unknown field.";
}

// Exactly the fields a tool takes, each of its type: a stray field from the model is refused, not ignored.
static NSString* ArgumentProblem(NSDictionary* arguments, NSDictionary<NSString*, Class>* fields) {
    if (![arguments isKindOfClass:NSDictionary.class]) return @"Arguments must be a JSON object.";
    for (id name in arguments) {
        Class type = [name isKindOfClass:NSString.class] ? fields[name] : nil;
        if (!type) return UnknownField(name);
        if (![arguments[name] isKindOfClass:type]) return [NSString stringWithFormat:@"%@ has the wrong type.", name];
    }
    return nil;
}

// A request that includes Friends chats (an @ chip, or `/` in a friend's conversation) gets no web tools at all. Its
// model may have read a friend's messages, and a search query or a page it chooses to open would carry their words
// off the Mac to OpenRouter, its search service and the site, none of which Friends' "Delete history" can reach. So
// nothing here runs in such a request, a subagent's included, and no web step is ever kept for one request only.
static BOOL IncludesFriends(SPDFMacAIRequestContext* context) { return context.includesFriendsChats; }

static BOOL WholeNumber(NSNumber* number, long long minimum, long long maximum) {
    double value = number.doubleValue;
    return CFGetTypeID((__bridge CFTypeRef)number) != CFBooleanGetTypeID() && value == floor(value) &&
        value >= minimum && value <= maximum;
}

@implementation SPDFMacAIWebToolProvider {
    SPDFMacAIWebSearcher* _searcher;
    SPDFMacAIWebFetcher* _fetcher;
    SPDFMacAIWebKeySource _apiKey;
    SPDFMacAIWebProvenance* _provenance;
    NSMutableDictionary<NSString*, SPDFMacAIWebPage*>* _pages;
    NSMutableArray<NSString*>* _pageOrder;
    NSMutableDictionary<NSNumber*, dispatch_block_t>* _running;
    NSMutableDictionary<NSString*, NSNumber*>* _opensBySite; // by SPDFMacAIWebShownHost
    NSUInteger _nextOperation, _searches, _opens;
}

- (instancetype)initWithSearcher:(SPDFMacAIWebSearcher*)searcher fetcher:(SPDFMacAIWebFetcher*)fetcher
                          apiKey:(SPDFMacAIWebKeySource)apiKey {
    if (!(self = [super init])) return nil;
    _searcher = searcher;
    _fetcher = fetcher;
    _apiKey = [apiKey copy];
    _provenance = [SPDFMacAIWebProvenance new];
    _pages = [NSMutableDictionary dictionary];
    _pageOrder = [NSMutableArray array];
    _running = [NSMutableDictionary dictionary];
    _opensBySite = [NSMutableDictionary dictionary];
    _maxSearchesPerRequest = 10;
    _maxPagesPerRequest = 20;
    _maxPagesPerSitePerRequest = 3;
    return self;
}

- (NSString*)providerIdentifier { return SPDFMacAIWebToolProviderIdentifier; }

- (BOOL)providesTool:(NSString*)name {
    return [name isEqual:SPDFMacAIWebSearchToolName] || [name isEqual:SPDFMacAIWebPageToolName];
}

// Both only read: queries and visits leave the Mac, as the Settings switch says, but nothing changes for anyone.
- (BOOL)isReadOnlyTool:(NSString*)name { return [self providesTool:name]; }

- (NSArray<NSDictionary*>*)toolDefinitionsForContext:(SPDFMacAIRequestContext*)context {
    return context.settings.aiWebSearchEnabled && !IncludesFriends(context) ? SPDFMacAIWebToolDefinitions() : @[];
}

// A web call the model makes anyway in a request that includes Friends chats is refused, but its arguments are the
// model's words, a search query that may quote a friend: the chat file keeps the call as a stub
// (SPDFMacAIChatStoredRequestOnlyMessages), whether or not it ran.
- (BOOL)isRequestOnlyTool:(NSString*)name context:(SPDFMacAIRequestContext*)context {
    return [self providesTool:name] && IncludesFriends(context);
}

// Friends first: turning the switch on would not help a request that includes Friends chats, and asking again
// without them leads to the switch's own message if it is off.
static NSString* Unavailable(SPDFMacAIRequestContext* context) {
    return IncludesFriends(context) ? kFriends : context.settings.aiWebSearchEnabled ? nil : kOff;
}

- (NSString*)unavailableMessageForTool:(NSString*)name context:(SPDFMacAIRequestContext*)context {
    (void)name;
    return Unavailable(context);
}

- (void)resetRequest {
    [self cancel];
    [_provenance reset];
    [_pages removeAllObjects];
    [_pageOrder removeAllObjects];
    [_opensBySite removeAllObjects];
    _searches = _opens = 0;
}

- (void)beginRequestWithContext:(SPDFMacAIRequestContext*)context {
    [self resetRequest];
    [_provenance notePersonText:context.text];
}

- (void)endRequestWithContext:(SPDFMacAIRequestContext*)context {
    (void)context;
    [self resetRequest];
}

- (void)cancel {
    NSArray* stops = _running.allValues;
    [_running removeAllObjects];
    for (dispatch_block_t stop in stops) stop();
}

// Every turn's messages pass here first, for the addresses the person wrote in this chat's earlier messages. Only the
// person's own text counts: a user message whose content is a list of parts is one the chat composed (page images
// with their captions), a subagent's user message is the task the assistant wrote, and tool results are left alone
// (SPDFMacAIWebProvenance.h says why). Search results and opened pages grant their addresses when they arrive.
//
// In a request that includes Friends chats the turn also says, after the instructions, that the web is unavailable and
// why, so a request for a search gets that answer rather than a guess.
- (NSArray<NSDictionary*>*)messagesForRequest:(NSArray<NSDictionary*>*)messages
                                      context:(SPDFMacAIRequestContext*)context {
    if (IncludesFriends(context)) {
        NSMutableArray* told = [messages mutableCopy];
        BOOL instructions = [messages.firstObject isKindOfClass:NSDictionary.class] &&
            [messages.firstObject[@"role"] isEqual:@"system"];
        [told insertObject:@{@"role" : @"system", @"content" : kFriends} atIndex:instructions ? 1 : 0];
        return told; // its user messages grant nothing: no web tool runs in this request
    }
    if (context.depth) return messages;
    for (NSDictionary* message in messages)
        if ([message isKindOfClass:NSDictionary.class] && [message[@"role"] isEqual:@"user"] &&
            [message[@"content"] isKindOfClass:NSString.class])
            [_provenance notePersonText:message[@"content"]];
    return messages;
}

- (void)performTool:(NSString*)name arguments:(NSDictionary*)arguments context:(SPDFMacAIRequestContext*)context
         completion:(SPDFMacAIToolCompletion)completion {
    NSString* unavailable = Unavailable(context);
    if (unavailable) { completion(Refusal(unavailable)); return; }
    if ([name isEqual:SPDFMacAIWebSearchToolName]) [self search:arguments context:context completion:completion];
    else if ([name isEqual:SPDFMacAIWebPageToolName]) [self open:arguments context:context completion:completion];
    else completion(Refusal(@"Unknown tool."));
}

// Runs `start`, which returns the operation's stop block, so that Stop, the row's Cancel and -cancel all reach it.
// Completions always arrive later on the main thread, so `done` never runs before the operation is recorded.
- (dispatch_block_t)track:(dispatch_block_t (^)(dispatch_block_t done))start
                  context:(SPDFMacAIRequestContext*)context {
    NSNumber* operation = @(++_nextOperation);
    __weak __typeof__(self) weakSelf = self;
    dispatch_block_t stop = start(^{
        __typeof__(self) owner = weakSelf;
        if (owner) [owner->_running removeObjectForKey:operation];
    });
    _running[operation] = stop;
    [context.cancellation onCancel:^{ stop(); }];
    return stop;
}

- (void)search:(NSDictionary*)arguments context:(SPDFMacAIRequestContext*)context
    completion:(SPDFMacAIToolCompletion)completion {
    NSString* problem = ArgumentProblem(arguments, @{@"query" : NSString.class, @"max_results" : NSNumber.class});
    NSString* query = [arguments[@"query"] isKindOfClass:NSString.class] ?
        [arguments[@"query"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : nil;
    NSNumber* count = [arguments[@"max_results"] isKindOfClass:NSNumber.class] ? arguments[@"max_results"] : @5;
    if (problem || !query.length || query.length > kMaximumQueryLength ||
        !WholeNumber(count, 1, (long long)SPDFMacAIWebSearchMaximumResults)) {
        completion(Refusal(problem ?: @"Give web_search a query of 1 to 400 characters and max_results from 1 to 8."));
        return;
    }
    if (_searches >= _maxSearchesPerRequest) {
        completion(Refusal([NSString stringWithFormat:@"This request has already searched the web %lu times, the "
                            "most one request may. Answer with what you found.", (unsigned long)_searches]));
        return;
    }
    _searches++;
    __block dispatch_block_t stop = nil;
    id<SPDFMacAIActivityReporting> activity = context.activity;
    NSString* step = [activity beginStepWithTitle:@"Searching the web" detail:SPDFMacAIWebSearchStepDetail(query)
                                          options:SPDFMacAIActivityOptionsNone cancel:^{ if (stop) stop(); }];
    NSError* keyError = nil;
    NSString* key = _apiKey ? _apiKey(&keyError) : nil;
    if (!key.length) {
        [activity updateEntry:step changes:@{SPDFMacAIActivityTitleKey : @"Couldn’t search the web",
            SPDFMacAIActivityStateKey : SPDFMacAIActivityStateFailed,
            SPDFMacAIActivityStatusKey : @"Your OpenRouter key couldn’t be read"}];
        completion(Refusal(@"The OpenRouter key could not be read, so the web was not searched. Ask the user to "
                           "reconnect OpenRouter in AI Settings."));
        return;
    }
    NSString* model = context.settings.model.length ? context.settings.model : SPDFMacAIDefaultModel;
    __weak __typeof__(self) weakSelf = self;
    stop = [self track:^dispatch_block_t(dispatch_block_t done) {
        return [self->_searcher search:query maxResults:count.unsignedIntegerValue model:model apiKey:key
                            completion:^(NSArray* results, NSUInteger tokens, NSError* error) {
            done();
            NSData* JSON = [NSJSONSerialization dataWithJSONObject:results ?: @[] options:0 error:nil];
            // Without reported usage: the search prompt and the excerpts the model read, about 4 bytes a token.
            [context.budget consumeTokens:tokens ?: 1500 + (query.length + JSON.length) / 4];
            if (!results) {
                BOOL stopped = error.code == SPDFMacAIWebErrorCancelled;
                [activity updateEntry:step changes:@{
                    SPDFMacAIActivityTitleKey : stopped ? @"Web search" : @"Couldn’t search the web",
                    SPDFMacAIActivityStateKey : stopped ? SPDFMacAIActivityStateStopped : SPDFMacAIActivityStateFailed,
                    SPDFMacAIActivityStatusKey : SPDFMacAIWebStatusForError(error, YES)}];
                completion(Refusal(stopped ? @"The search was stopped before it finished." :
                                   error.localizedDescription ?: @"The search did not finish."));
                return;
            }
            // The urls the search engine cited, never the query echoed back: the model wrote that.
            for (NSDictionary* result in results) [weakSelf noteURL:[NSURL URLWithString:result[@"url"]]];
            [activity updateEntry:step changes:@{SPDFMacAIActivityTitleKey : @"Searched the web",
                SPDFMacAIActivityStateKey : SPDFMacAIActivityStateDone,
                SPDFMacAIActivityStatusKey : SPDFMacAIWebSearchStepStatus(results.count),
                SPDFMacAIActivityLinksKey : SPDFMacAIWebSearchStepLinks(results)}];
            completion(SPDFMacAIWebSearchToolResult(query, results));
        }];
    } context:context];
}

- (void)noteURL:(NSURL*)URL { if (URL) [_provenance noteURL:URL]; }

- (void)countOpenOn:(NSString*)host { _opensBySite[host] = @(_opensBySite[host].unsignedIntegerValue + 1); }

- (void)rememberPage:(SPDFMacAIWebPage*)page key:(NSString*)key {
    for (NSString* name in @[key, SPDFMacAIWebProvenanceKey(page.URL) ?: key]) {
        if (!_pages[name]) [_pageOrder addObject:name];
        _pages[name] = page;
    }
    while (_pageOrder.count > kCachedPages * 2) {
        [_pages removeObjectForKey:_pageOrder.firstObject];
        [_pageOrder removeObjectAtIndex:0];
    }
    // Where the site's redirects ended and the links its HTML holds: the model wrote none of them.
    [_provenance noteURL:page.URL];
    for (NSDictionary* link in page.readable.links) [self noteURL:[NSURL URLWithString:link[@"url"]]];
}

- (void)open:(NSDictionary*)arguments context:(SPDFMacAIRequestContext*)context
    completion:(SPDFMacAIToolCompletion)completion {
    NSString* problem = ArgumentProblem(arguments, @{@"url" : NSString.class, @"start" : NSNumber.class});
    NSString* link = [arguments[@"url"] isKindOfClass:NSString.class] ?
        [arguments[@"url"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : nil;
    NSNumber* start = [arguments[@"start"] isKindOfClass:NSNumber.class] ? arguments[@"start"] : @0;
    NSURL* URL = link.length && link.length <= kMaximumLinkLength ? [NSURL URLWithString:link] : nil;
    NSString* key = URL ? SPDFMacAIWebProvenanceKey(URL) : nil;
    if (problem || !key || !WholeNumber(start, 0, 100000000)) {
        completion(Refusal(problem ?: @"Give open_page a complete https:// URL of at most 2,048 characters, and a "
                           "start from next_start when reading on."));
        return;
    }
    NSUInteger offset = start.unsignedIntegerValue;
    SPDFMacAIWebPage* cached = _pages[key];
    if (cached) { completion(SPDFMacAIWebPageToolResult(cached, offset)); return; }
    if (![_provenance allowsURL:URL]) { completion(Refusal(kNotSeen)); return; }
    if (_opens >= _maxPagesPerRequest) {
        completion(Refusal([NSString stringWithFormat:@"This request has already opened %lu pages, the most one "
                            "request may. Answer with what you found.", (unsigned long)_opens]));
        return;
    }
    // Every address on an opened page is openable, so a hostile page could have the model spell something out by
    // which of its links it follows, one choice per open; a few opens per site keeps that to a few choices.
    NSString* host = SPDFMacAIWebShownHost(link);
    if (_opensBySite[host].unsignedIntegerValue >= _maxPagesPerSitePerRequest) {
        completion(Refusal([NSString stringWithFormat:@"This request has already opened %lu pages on this site, the "
                            "most one request may. Answer with what you found.",
                            (unsigned long)_maxPagesPerSitePerRequest]));
        return;
    }
    _opens++;
    [self countOpenOn:host];
    __block dispatch_block_t stop = nil;
    id<SPDFMacAIActivityReporting> activity = context.activity;
    NSString* step = [activity beginStepWithTitle:[@"Opening " stringByAppendingString:host] detail:link
                                          options:SPDFMacAIActivityOptionsNone cancel:^{ if (stop) stop(); }];
    __weak __typeof__(self) weakSelf = self;
    stop = [self track:^dispatch_block_t(dispatch_block_t done) {
        return [self->_fetcher fetchURL:URL completion:^(SPDFMacAIWebPage* page, NSError* error) {
            done();
            if (!page) {
                BOOL stopped = error.code == SPDFMacAIWebErrorCancelled;
                [activity updateEntry:step changes:@{
                    SPDFMacAIActivityTitleKey :
                        [(stopped ? @"Page on " : @"Didn’t open ") stringByAppendingString:host],
                    SPDFMacAIActivityStateKey : stopped ? SPDFMacAIActivityStateStopped : SPDFMacAIActivityStateFailed,
                    SPDFMacAIActivityStatusKey : SPDFMacAIWebStatusForError(error, NO)}];
                completion(@{@"error" : stopped ? @"The page was stopped before it opened." :
                             error.localizedDescription ?: @"The page could not be opened.", @"url" : link});
                return;
            }
            [weakSelf rememberPage:page key:key];
            // Where the site's redirects ended counts as a visit to that site too.
            NSString* landed = SPDFMacAIWebShownHost(page.URL.absoluteString);
            if (![landed isEqual:host]) [weakSelf countOpenOn:landed];
            // No status of its own: the title says it opened, the row under it is the page.
            [activity updateEntry:step changes:@{
                SPDFMacAIActivityTitleKey : [@"Opened " stringByAppendingString:landed],
                SPDFMacAIActivityDetailKey : SPDFMacAIWebPageStepDetail(page), // empty clears the address shown
                SPDFMacAIActivityStateKey : SPDFMacAIActivityStateDone,
                SPDFMacAIActivityLinksKey : SPDFMacAIWebPageStepLinks(page)}];
            completion(SPDFMacAIWebPageToolResult(page, offset));
        }];
    } context:context];
}

@end
