#import "SPDFMacAIRequestContext.h"

NSString* const SPDFMacAIChipKindFriends = @"friends";
NSString* const SPDFMacAIChipKindDocument = @"document";
NSString* const SPDFMacAIChipKindAttachment = @"attachment";

@implementation SPDFMacAIRequestChip
- (instancetype)initWithKind:(NSString*)kind name:(NSString*)name scope:(NSArray*)scope file:(NSURL*)file
                  identifier:(NSString*)identifier revision:(NSDictionary*)revision {
    if (!(self = [super init])) return nil;
    _kind = [kind copy];
    _displayName = [name copy] ?: @"";
    _scopeIDs = [scope copy];
    _fileURL = [file copy];
    _identifier = [identifier copy];
    _revision = [revision copy];
    return self;
}
+ (instancetype)friendsChipWithConversationIDs:(NSArray<NSString*>*)conversationIDs displayName:(NSString*)name {
    return [[self alloc] initWithKind:SPDFMacAIChipKindFriends name:name scope:conversationIDs file:nil identifier:nil
                             revision:nil];
}
+ (instancetype)documentChipWithFileURL:(NSURL*)fileURL identifier:(NSString*)identifier
                               revision:(NSDictionary*)revision displayName:(NSString*)name {
    return [[self alloc] initWithKind:SPDFMacAIChipKindDocument name:name scope:nil file:fileURL identifier:identifier
                             revision:revision];
}
+ (instancetype)attachmentChipWithFileURL:(NSURL*)fileURL displayName:(NSString*)name {
    return [[self alloc] initWithKind:SPDFMacAIChipKindAttachment name:name scope:nil file:fileURL identifier:nil
                             revision:nil];
}
+ (instancetype)attachmentChipWithFileURL:(NSURL*)fileURL identifier:(NSString*)identifier displayName:(NSString*)name {
    return [[self alloc] initWithKind:SPDFMacAIChipKindAttachment name:name scope:nil file:fileURL identifier:identifier
                             revision:nil];
}
- (id)copyWithZone:(NSZone*)zone { (void)zone; return self; }
@end

const NSUInteger SPDFMacAIRequestStepCeiling=120;
@implementation SPDFMacAIRequestBudget {
    SPDFMacAIRequestBudget* _parent;
    NSUInteger _steps, _tokens, _toolCalls;
    NSUInteger _usedSteps, _usedTokens, _usedToolCalls;
}
+ (instancetype)defaultRequestBudget { return [[self alloc] initWithSteps:SPDFMacAIRequestStepCeiling tokens:8000000
    toolCalls:NSUIntegerMax]; }
- (instancetype)initWithSteps:(NSUInteger)steps tokens:(NSUInteger)tokens toolCalls:(NSUInteger)toolCalls {
    if (!(self = [super init])) return nil;
    _steps = steps;
    _tokens = tokens;
    _toolCalls = toolCalls;
    return self;
}
// One lock for a whole budget tree: a child charge checks and updates every ancestor atomically, so two subagents
// finishing at once cannot both take the parent's last step.
static NSObject* BudgetLock(void) {
    static NSObject* lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}
static NSUInteger Remaining(NSUInteger limit, NSUInteger used) { return used >= limit ? 0 : limit - used; }
- (NSUInteger)localRemainingSteps { return Remaining(_steps, _usedSteps); }
- (NSUInteger)localRemainingTokens { return Remaining(_tokens, _usedTokens); }
- (NSUInteger)localRemainingToolCalls {
    return _toolCalls == NSUIntegerMax ? NSUIntegerMax : Remaining(_toolCalls, _usedToolCalls);
}
- (NSUInteger)remainingSteps {
    @synchronized (BudgetLock()) {
        NSUInteger value = self.localRemainingSteps;
        for (SPDFMacAIRequestBudget* b = _parent; b; b = b->_parent) value = MIN(value, b.localRemainingSteps);
        return value;
    }
}
- (NSUInteger)remainingTokens {
    @synchronized (BudgetLock()) {
        NSUInteger value = self.localRemainingTokens;
        for (SPDFMacAIRequestBudget* b = _parent; b; b = b->_parent) value = MIN(value, b.localRemainingTokens);
        return value;
    }
}
- (NSUInteger)remainingToolCalls {
    @synchronized (BudgetLock()) {
        NSUInteger value = self.localRemainingToolCalls;
        for (SPDFMacAIRequestBudget* b = _parent; b; b = b->_parent) value = MIN(value, b.localRemainingToolCalls);
        return value;
    }
}
- (NSUInteger)usedSteps { @synchronized (BudgetLock()) { return _usedSteps; } }
- (NSUInteger)usedTokens { @synchronized (BudgetLock()) { return _usedTokens; } }
- (NSUInteger)usedToolCalls { @synchronized (BudgetLock()) { return _usedToolCalls; } }
- (BOOL)consumeStep {
    @synchronized (BudgetLock()) {
        if (!self.remainingSteps) return NO;
        for (SPDFMacAIRequestBudget* b = self; b; b = b->_parent) b->_usedSteps++;
        return YES;
    }
}
- (void)returnStep {
    @synchronized (BudgetLock()) {
        if (!_usedSteps) return;
        for (SPDFMacAIRequestBudget* b = self; b; b = b->_parent)
            if (b->_usedSteps) b->_usedSteps--;
    }
}
- (BOOL)consumeToolCall {
    @synchronized (BudgetLock()) {
        if (!self.remainingToolCalls) return NO;
        for (SPDFMacAIRequestBudget* b = self; b; b = b->_parent) b->_usedToolCalls++;
        return YES;
    }
}
- (void)consumeTokens:(NSUInteger)tokens {
    @synchronized (BudgetLock()) {
        for (SPDFMacAIRequestBudget* b = self; b; b = b->_parent)
            b->_usedTokens = tokens > NSUIntegerMax - b->_usedTokens ? NSUIntegerMax : b->_usedTokens + tokens;
    }
}
- (SPDFMacAIRequestBudget*)childBudgetWithSteps:(NSUInteger)steps tokens:(NSUInteger)tokens
                                       toolCalls:(NSUInteger)toolCalls {
    @synchronized (BudgetLock()) {
        if (!self.remainingSteps || !self.remainingTokens) return nil;
        NSUInteger calls = self.remainingToolCalls;
        SPDFMacAIRequestBudget* child = [[SPDFMacAIRequestBudget alloc]
            initWithSteps:MIN(steps, self.remainingSteps) tokens:MIN(tokens, self.remainingTokens)
                toolCalls:calls == NSUIntegerMax ? toolCalls : MIN(toolCalls, calls)];
        child->_parent = self;
        return child;
    }
}
@end

@implementation SPDFMacAICancellationToken {
    BOOL _cancelled;
    NSMutableArray<dispatch_block_t>* _handlers;
}
- (instancetype)init {
    if ((self = [super init])) _handlers = [NSMutableArray array];
    return self;
}
- (BOOL)isCancelled { @synchronized (self) { return _cancelled; } }
- (void)cancel {
    NSArray* handlers = nil;
    @synchronized (self) {
        if (_cancelled) return;
        _cancelled = YES;
        handlers = [_handlers copy];
        [_handlers removeAllObjects];
    }
    // Outside the lock: a handler may cancel related tokens or check this one.
    for (dispatch_block_t handler in handlers) handler();
}
- (void)onCancel:(dispatch_block_t)handler {
    if (!handler) return;
    @synchronized (self) {
        if (!_cancelled) { [_handlers addObject:[handler copy]]; return; }
    }
    handler();
}
- (SPDFMacAICancellationToken*)childToken {
    SPDFMacAICancellationToken* child = [SPDFMacAICancellationToken new];
    __weak SPDFMacAICancellationToken* weakChild = child;
    [self onCancel:^{ [weakChild cancel]; }];
    return child;
}
@end

@implementation SPDFMacAIRequestContext {
    __weak SPDFMacAIChatSession* _session;
    BOOL _bound;
}
- (instancetype)initWithText:(NSString*)text chips:(NSArray<SPDFMacAIRequestChip*>*)chips
                      origin:(SPDFMacAIRequestOrigin)origin friendConversation:(SPDFMacAIRequestChip*)friendConversation
                    settings:(SPDFMacAISettingsSnapshot*)settings budget:(SPDFMacAIRequestBudget*)budget
                    activity:(id<SPDFMacAIActivityReporting>)activity {
    if (!(self = [super init])) return nil;
    _requestID = NSUUID.UUID.UUIDString;
    _text = [text copy] ?: @"";
    // A copy of the person's chips, so a caller mutating its array later cannot add one to a running request.
    _chips = [[NSArray alloc] initWithArray:chips ?: @[] copyItems:YES];
    _origin = origin;
    _friendConversation = origin == SPDFMacAIRequestOriginFriendComposer ? friendConversation : nil;
    _settings = settings;
    _budget = budget ?: [SPDFMacAIRequestBudget defaultRequestBudget];
    _cancellation = [SPDFMacAICancellationToken new];
    _activity = activity;
    return self;
}
- (NSArray<SPDFMacAIRequestChip*>*)chipsOfKind:(NSString*)kind {
    return [_chips filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(SPDFMacAIRequestChip* chip,
        NSDictionary* bindings) { (void)bindings; return [chip.kind isEqual:kind]; }]];
}
- (BOOL)includesFriendsChats {
    return [self chipsOfKind:SPDFMacAIChipKindFriends].count > 0 || _origin == SPDFMacAIRequestOriginFriendComposer;
}
- (SPDFMacAIChatSession*)session { return _session; }
- (BOOL)bindToSession:(SPDFMacAIChatSession*)session {
    @synchronized (self) {
        if (_bound) return NO;
        _bound = YES;
        _session = session;
        return YES;
    }
}
- (SPDFMacAIRequestContext*)childContextWithText:(NSString*)text budget:(SPDFMacAIRequestBudget*)budget
                                            error:(NSError**)error {
    if (_depth >= 1 || !budget) {
        if (error) *error = [NSError errorWithDomain:@"ShenzhenPDF.AI.Request" code:1 userInfo:@{
            NSLocalizedDescriptionKey : _depth >= 1 ? @"A task inside a task can't start more tasks." :
                @"A task needs a budget."}];
        return nil;
    }
    SPDFMacAIRequestContext* child = [[SPDFMacAIRequestContext alloc] initWithText:text chips:_chips origin:_origin
        friendConversation:_friendConversation settings:_settings budget:budget activity:_activity];
    child->_depth = _depth + 1;
    child->_cancellation = [_cancellation childToken];
    return child;
}
@end
