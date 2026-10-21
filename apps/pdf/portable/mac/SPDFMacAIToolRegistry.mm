#import "SPDFMacAIToolRegistry.h"
#import "SPDFMacAIChatSession.h"
#import <objc/message.h>
#import <objc/runtime.h>

static NSDictionary* Refusal(NSString* message) { return @{@"error" : message}; }
static NSString* const kUnknown = @"Unknown tool.";
static NSString* const kFiltered = @"This task can only read, so it can't use that tool. Answer with what you "
    "found, and say what the user could ask for in the main chat.";
static NSString* const kUnavailable = @"That tool isn't available for this request.";

static NSString* DefinitionName(id definition) {
    id function = [definition isKindOfClass:NSDictionary.class] ? definition[@"function"] : nil;
    id name = [function isKindOfClass:NSDictionary.class] ? function[@"name"] : nil;
    return [name isKindOfClass:NSString.class] && [name length] ? name : nil;
}

@implementation SPDFMacAIToolFilter
- (instancetype)initReadOnly:(BOOL)readOnly providers:(NSSet*)providers {
    if (!(self = [super init])) return nil;
    _readOnlyOnly = readOnly;
    _providerIdentifiers = [providers copy];
    return self;
}
+ (instancetype)readOnly { return [[self alloc] initReadOnly:YES providers:nil]; }
+ (instancetype)readOnlyFromProviders:(NSSet<NSString*>*)identifiers {
    return [[self alloc] initReadOnly:YES providers:identifiers ?: [NSSet set]];
}
@end

@interface SPDFMacAIChatToolsProvider ()
// The legacy registry's one provider performs every name, as the tools object did before providers existed.
@property(nonatomic) BOOL routesEveryTool;
@end

@implementation SPDFMacAIChatToolsProvider {
    NSString* _identifier;
    NSArray* _definitions;
    NSSet* _names;
    NSSet* _readOnly;
}
- (instancetype)initWithIdentifier:(NSString*)identifier tools:(id<SPDFMacAIChatTools>)tools
                       definitions:(NSArray<NSDictionary*>*)definitions readOnlyTools:(NSSet<NSString*>*)readOnly {
    if (!(self = [super init])) return nil;
    _identifier = [identifier copy];
    _tools = tools;
    _definitions = [definitions copy] ?: @[];
    NSMutableSet* names = [NSMutableSet set];
    for (id definition in _definitions) if (DefinitionName(definition)) [names addObject:DefinitionName(definition)];
    _names = names;
    _readOnly = [readOnly copy] ?: [NSSet set];
    return self;
}
- (NSString*)providerIdentifier { return _identifier; }
- (BOOL)providesTool:(NSString*)name { return _routesEveryTool || [_names containsObject:name]; }
- (NSArray<NSDictionary*>*)toolDefinitionsForContext:(SPDFMacAIRequestContext*)context {
    (void)context;
    return _definitions;
}
- (BOOL)isReadOnlyTool:(NSString*)name { return [_readOnly containsObject:name]; }
- (void)performTool:(NSString*)name arguments:(NSDictionary*)arguments context:(SPDFMacAIRequestContext*)context
         completion:(SPDFMacAIToolCompletion)completion {
    // Tools that report to the chat take the request's context; the rest run as before providers existed.
    if ([(id)_tools respondsToSelector:@selector(performTool:arguments:context:completion:)])
        [(id<SPDFMacAIToolProvider>)_tools performTool:name arguments:arguments context:context completion:completion];
    else [_tools performTool:name arguments:arguments completion:completion];
}
- (void)cancel { [_tools cancel]; }
- (NSDictionary*)chatForStorage:(NSDictionary*)chat {
    return [_tools respondsToSelector:@selector(chatForStorage:)] ? [_tools chatForStorage:chat] ?: chat : chat;
}
- (NSArray<NSDictionary*>*)messagesForTitle:(NSArray<NSDictionary*>*)messages {
    return [_tools respondsToSelector:@selector(messagesForTitle:)] ? [_tools messagesForTitle:messages] ?: messages :
        messages;
}
- (NSDictionary*)conversationContext {
    return [_tools respondsToSelector:@selector(conversationContext)] ? [_tools conversationContext] : nil;
}
- (BOOL)canUndo { return _tools.canUndo; }
- (BOOL)canRedo { return [_tools respondsToSelector:@selector(canRedo)] && _tools.canRedo; }
- (BOOL)undoLastAction:(NSError**)error { return [_tools undoLastAction:error]; }
- (void)undoWithCompletion:(void (^)(NSDictionary*))completion {
    if ([_tools respondsToSelector:@selector(undoWithCompletion:)]) [_tools undoWithCompletion:completion];
    else completion(Refusal(@"No action available."));
}
- (void)redoWithCompletion:(void (^)(NSDictionary*))completion {
    if ([_tools respondsToSelector:@selector(redoWithCompletion:)]) [_tools redoWithCompletion:completion];
    else completion(Refusal(@"No action available."));
}
@end

@implementation SPDFMacAIToolRegistry {
    NSMutableArray<id<SPDFMacAIToolProvider>>* _providers;
    BOOL _legacy;
}
- (instancetype)init {
    if ((self = [super init])) _providers = [NSMutableArray array];
    return self;
}
- (instancetype)initWithLegacyTools:(id<SPDFMacAIChatTools>)tools definitions:(NSArray<NSDictionary*>*)definitions {
    if (!(self = [self init])) return nil;
    SPDFMacAIChatToolsProvider* provider = [[SPDFMacAIChatToolsProvider alloc] initWithIdentifier:@"tools"
        tools:tools definitions:definitions readOnlyTools:[NSSet set]];
    provider.routesEveryTool = YES;
    [_providers addObject:provider];
    _legacy = YES;
    return self;
}
- (NSArray<id<SPDFMacAIToolProvider>>*)providers { return [_providers copy]; }
- (BOOL)registerProvider:(id<SPDFMacAIToolProvider>)provider error:(NSError**)error {
    NSString* identifier = provider.providerIdentifier;
    BOOL taken = !identifier.length || _legacy;
    for (id<SPDFMacAIToolProvider> existing in _providers)
        taken = taken || [existing.providerIdentifier isEqual:identifier];
    if (!provider || taken) {
        if (error) *error = [NSError errorWithDomain:@"ShenzhenPDF.AI.Tools" code:1 userInfo:@{
            NSLocalizedDescriptionKey : [NSString stringWithFormat:@"A tool provider named %@ is already registered.",
                                         identifier ?: @"(none)"]}];
        return NO;
    }
    [_providers addObject:provider];
    return YES;
}
- (SPDFMacAIToolRegistry*)registryWithFilter:(SPDFMacAIToolFilter*)filter {
    SPDFMacAIToolRegistry* filtered = [SPDFMacAIToolRegistry new];
    filtered->_providers = _providers; // shared on purpose: a provider registered later joins every view
    filtered->_legacy = _legacy;
    NSSet* allowed = filter.providerIdentifiers;
    if (_filter.providerIdentifiers) {
        NSMutableSet* both = [_filter.providerIdentifiers mutableCopy];
        if (allowed) [both intersectSet:allowed];
        allowed = both;
    }
    filtered->_filter = [[SPDFMacAIToolFilter alloc] initReadOnly:filter.readOnlyOnly || _filter.readOnlyOnly
                                                        providers:allowed];
    return filtered;
}
// The first registered provider claiming a name owns it; a later claim is ignored rather than allowed to shadow it.
- (id<SPDFMacAIToolProvider>)ownerOfTool:(NSString*)name {
    if (![name isKindOfClass:NSString.class]) return nil;
    for (id<SPDFMacAIToolProvider> provider in _providers) if ([provider providesTool:name]) return provider;
    return nil;
}
- (BOOL)filterAllowsTool:(NSString*)name provider:(id<SPDFMacAIToolProvider>)provider {
    if (!_filter) return YES;
    if (_filter.providerIdentifiers && ![_filter.providerIdentifiers containsObject:provider.providerIdentifier])
        return NO;
    return !_filter.readOnlyOnly || [provider isReadOnlyTool:name];
}
- (NSArray<NSDictionary*>*)toolDefinitionsForContext:(SPDFMacAIRequestContext*)context {
    NSMutableArray* definitions = [NSMutableArray array];
    NSMutableSet* names = [NSMutableSet set];
    for (id<SPDFMacAIToolProvider> provider in _providers) {
        for (NSDictionary* definition in [provider toolDefinitionsForContext:context]) {
            NSString* name = DefinitionName(definition);
            if (!name || [names containsObject:name]) continue;
            if (!_legacy && [self ownerOfTool:name] != provider) continue;
            if (![self filterAllowsTool:name provider:provider]) continue;
            [names addObject:name];
            [definitions addObject:definition];
        }
    }
    return definitions;
}
- (BOOL)isReadOnlyTool:(NSString*)name {
    id<SPDFMacAIToolProvider> owner = [self ownerOfTool:name];
    return owner && [owner isReadOnlyTool:name];
}
- (BOOL)isRequestOnlyTool:(NSString*)name context:(SPDFMacAIRequestContext*)context {
    id<SPDFMacAIToolProvider> owner = [self ownerOfTool:name];
    return [owner respondsToSelector:@selector(isRequestOnlyTool:context:)] &&
        [owner isRequestOnlyTool:name context:context];
}
- (BOOL)tool:(NSString*)name offeredBy:(id<SPDFMacAIToolProvider>)provider context:(SPDFMacAIRequestContext*)context {
    for (NSDictionary* definition in [provider toolDefinitionsForContext:context])
        if ([DefinitionName(definition) isEqual:name]) return YES;
    return NO;
}
- (NSString*)readOnlyReasonForContext:(SPDFMacAIRequestContext*)context {
    for (id<SPDFMacAIToolProvider> provider in _providers) {
        if (![provider respondsToSelector:@selector(readOnlyReasonForContext:)]) continue;
        NSString* reason = [provider readOnlyReasonForContext:context];
        if (reason.length) return reason;
    }
    return nil;
}
- (void)performTool:(NSString*)name arguments:(NSDictionary*)arguments context:(SPDFMacAIRequestContext*)context
         completion:(SPDFMacAIToolCompletion)completion {
    __block BOOL finished = NO;
    SPDFMacAIToolCompletion once = ^(NSDictionary* result) {
        dispatch_block_t deliver = ^{
            if (finished) return;
            finished = YES;
            completion([result isKindOfClass:NSDictionary.class] ? result : Refusal(@"No tool result"));
        };
        if (NSThread.isMainThread) deliver(); else dispatch_async(dispatch_get_main_queue(), deliver);
    };
    id<SPDFMacAIToolProvider> provider = [self ownerOfTool:name];
    if (!provider) { once(Refusal(kUnknown)); return; }
    if (![self filterAllowsTool:name provider:provider]) { once(Refusal(kFiltered)); return; }
    if (!_legacy) {
        if (![self tool:name offeredBy:provider context:context]) {
            NSString* message = [provider respondsToSelector:@selector(unavailableMessageForTool:context:)] ?
                [provider unavailableMessageForTool:name context:context] : nil;
            once(Refusal(message.length ? message : kUnavailable));
            return;
        }
        NSString* reason = [provider isReadOnlyTool:name] ? nil : [self readOnlyReasonForContext:context];
        if (reason) { once(Refusal(reason)); return; }
    }
    [provider performTool:name arguments:arguments ?: @{} context:context completion:once];
}
- (void)beginRequestWithContext:(SPDFMacAIRequestContext*)context {
    for (id<SPDFMacAIToolProvider> provider in [_providers copy])
        if ([provider respondsToSelector:@selector(beginRequestWithContext:)])
            [provider beginRequestWithContext:context];
}
- (void)endRequestWithContext:(SPDFMacAIRequestContext*)context {
    for (id<SPDFMacAIToolProvider> provider in [_providers copy])
        if ([provider respondsToSelector:@selector(endRequestWithContext:)]) [provider endRequestWithContext:context];
}
- (void)cancel { for (id<SPDFMacAIToolProvider> provider in [_providers copy]) [provider cancel]; }
- (NSArray<NSDictionary*>*)messagesForRequest:(NSArray<NSDictionary*>*)messages
                                      context:(SPDFMacAIRequestContext*)context {
    for (id<SPDFMacAIToolProvider> provider in _providers)
        if ([provider respondsToSelector:@selector(messagesForRequest:context:)])
            messages = [provider messagesForRequest:messages context:context] ?: messages;
    return messages;
}
- (NSArray<SPDFMacAIRequestChip*>*)requestChipsInComposerText:(NSAttributedString*)text {
    NSMutableArray* chips = [NSMutableArray array];
    if (!text.length) return chips;
    for (id<SPDFMacAIToolProvider> provider in _providers)
        if ([provider respondsToSelector:@selector(requestChipsInComposerText:)])
            [chips addObjectsFromArray:[provider requestChipsInComposerText:text] ?: @[]];
    return chips;
}
- (NSDictionary*)chatForStorage:(NSDictionary*)chat {
    for (id<SPDFMacAIToolProvider> provider in _providers)
        if ([provider respondsToSelector:@selector(chatForStorage:)]) {
            NSDictionary* stored = [provider chatForStorage:chat];
            if ([stored isKindOfClass:NSDictionary.class] && [stored[@"messages"] isKindOfClass:NSArray.class])
                chat = stored;
        }
    return chat;
}
- (NSArray<NSDictionary*>*)messagesForTitle:(NSArray<NSDictionary*>*)messages {
    for (id<SPDFMacAIToolProvider> provider in _providers)
        if ([provider respondsToSelector:@selector(messagesForTitle:)]) {
            NSArray* kept = [provider messagesForTitle:messages];
            if ([kept isKindOfClass:NSArray.class]) messages = kept;
        }
    return messages;
}
- (NSDictionary*)conversationContext {
    for (id<SPDFMacAIToolProvider> provider in _providers)
        if ([provider respondsToSelector:@selector(conversationContext)]) {
            NSDictionary* context = [provider conversationContext];
            if (context) return context;
        }
    return nil;
}
- (id<SPDFMacAIToolProvider>)historyProvider {
    for (id<SPDFMacAIToolProvider> provider in _providers)
        if ([provider respondsToSelector:@selector(undoLastAction:)]) return provider;
    return nil;
}
- (BOOL)canUndo {
    id<SPDFMacAIToolProvider> provider = self.historyProvider;
    return [provider respondsToSelector:@selector(canUndo)] && provider.canUndo;
}
- (BOOL)canRedo {
    id<SPDFMacAIToolProvider> provider = self.historyProvider;
    return [provider respondsToSelector:@selector(canRedo)] && provider.canRedo;
}
- (BOOL)undoLastAction:(NSError**)error {
    id<SPDFMacAIToolProvider> provider = self.historyProvider;
    return provider && [provider undoLastAction:error];
}
- (void)undoWithCompletion:(void (^)(NSDictionary*))completion {
    id<SPDFMacAIToolProvider> provider = self.historyProvider;
    if ([provider respondsToSelector:@selector(undoWithCompletion:)]) [provider undoWithCompletion:completion];
    else completion(Refusal(@"No action available."));
}
- (void)redoWithCompletion:(void (^)(NSDictionary*))completion {
    id<SPDFMacAIToolProvider> provider = self.historyProvider;
    if ([provider respondsToSelector:@selector(redoWithCompletion:)]) [provider redoWithCompletion:completion];
    else completion(Refusal(@"No action available."));
}
@end

NSSet<NSString*>* SPDFMacAIReaderReadOnlyToolNames(void) {
    static NSSet* names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = [NSSet setWithArray:@[@"list_workspace", @"document_metadata", @"read_pages", @"search_documents",
                                      @"render_page", @"list_collection", @"current_view", @"reader_state",
                                      @"list_chats"]];
    });
    return names;
}

NSArray<id<SPDFMacAIToolProvider>>* SPDFMacAIDiscoverToolProviders(id owner) {
    if (!owner) return @[];
    unsigned int count = 0;
    Method* methods = class_copyMethodList(object_getClass(owner), &count);
    NSMutableArray<NSString*>* selectors = [NSMutableArray array];
    for (unsigned int index = 0; index < count; index++) {
        NSString* name = NSStringFromSelector(method_getName(methods[index]));
        char returnType[8] = {0};
        method_getReturnType(methods[index], returnType, sizeof(returnType));
        // Exactly "aiToolProvider<Name>": no arguments, an object back.
        if ([name hasPrefix:@"aiToolProvider"] && name.length > 14 && ![name containsString:@":"] &&
            returnType[0] == '@') [selectors addObject:name];
    }
    free(methods);
    [selectors sortUsingSelector:@selector(compare:)];
    NSMutableArray* providers = [NSMutableArray array];
    for (NSString* name in selectors) {
        id provider = ((id (*)(id, SEL))objc_msgSend)(owner, NSSelectorFromString(name));
        if ([provider conformsToProtocol:@protocol(SPDFMacAIToolProvider)]) [providers addObject:provider];
    }
    return providers;
}
