#import "SPDFMacAISubagents.h"
#import "SPDFMacAISubagentsResults.h"
#import "SPDFMacAISubagentsRun.h"
#import "SPDFMacAISettings.h"

NSString* const SPDFMacAISubagentsToolName = @"run_subagents";
NSString* const SPDFMacAISubagentsProviderIdentifier = @"subagents";
const NSUInteger SPDFMacAISubagentsMaximumTasks = 4;
const NSUInteger SPDFMacAISubagentsToolCallsPerTask = 12;
const NSUInteger SPDFMacAISubagentsRunsPerRequest = 2;
const NSUInteger SPDFMacAISubagentsTurnsPerRequest = 48;
const NSUInteger SPDFMacAISubagentsTokensPerRun = 600000;

NSSet<NSString*>* SPDFMacAISubagentToolProviders(void) {
    static NSSet* providers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ providers = [NSSet setWithArray:@[@"reader", @"web", @"python"]]; });
    return providers;
}

// Why this request may not run tasks, written for the model; nil when it may.
static NSString* Unavailable(SPDFMacAIRequestContext* context) {
    if (context.depth) return @"A task can't start more tasks. Answer with what you found.";
    if (!context.settings.aiSubagentsEnabled)
        return @"Tasks are turned off in AI Settings. Do the work yourself, one tool call at a time.";
    if (!context.session) return @"Tasks can only run inside a chat request.";
    return nil;
}

static NSString* const kRunsUsed = @"This request has already run tasks twice, the most it can. Answer with what the "
    "tasks found, or do any remaining lookup yourself.";

// When to split, in the main assistant's prompt while the tool is offered (-messagesForRequest:context:). Without it
// the tool was a name at the end of a long list, described as for "only" some questions, beside a prompt that says
// to start with the active document and stop as soon as the answer is supported: the model never chose it.
static NSString* const kWhenToSplit = @"Split big requests with run_subagents, one task per independent piece: "
    "comparing or checking several documents, summarizing more than about 20 pages, answering several separate "
    "questions, or researching several items on the web. For one quick question or a single short lookup, work "
    "directly.";

static NSDictionary* Definition(NSTimeInterval timeout) {
    NSUInteger minutes = (NSUInteger)MAX(1.0, ceil(timeout / 60.0));
    NSString* description = [NSString stringWithFormat:@"Split a big request into up to 4 tasks that run at the "
        "same time, each in its own conversation with read-only tools (document search and reads, and web search, "
        "web pages and Python where available), and get back each task's short findings with sources. Use it when "
        "the work divides into independent pieces: comparing or checking several documents (one task per "
        "document); summarizing more than about 20 pages (one task per chapter or range of pages); answering "
        "several separate questions; or researching several items on the web. Don't use it for one quick question "
        "or a single short lookup: do that yourself. A task sees only its instructions and the user's message, "
        "never this conversation, so make each task's instructions complete: which document (its title or path), "
        "which pages, what to find and what to report. Tasks cannot make changes, send messages, see rendered page "
        "images or start tasks. Each stops after %lu tool calls, and the whole run after %lu minute%@. Call it at "
        "most %lu times in one request. Each task returns a status (answered; timed_out or out_of_budget, whose "
        "summary is partial; stopped, when the user cancelled it; failed, with the problem), a short summary and "
        "its sources. Combine the findings into one answer, citing their sources and copying citation URLs "
        "exactly.",
        (unsigned long)SPDFMacAISubagentsToolCallsPerTask, (unsigned long)minutes, minutes == 1 ? @"" : @"s",
        (unsigned long)SPDFMacAISubagentsRunsPerRequest];
    NSDictionary* task = @{@"type" : @"object", @"additionalProperties" : @NO,
        @"required" : @[@"title", @"instructions"],
        @"properties" : @{
            @"title" : @{@"type" : @"string", @"maxLength" : @(SPDFMacAISubagentTitleLimit),
                         @"description" : @"A few words the user sees while the task runs, such as \"Delivery "
                                          "dates in the supplier contract\"."},
            @"instructions" : @{@"type" : @"string", @"maxLength" : @(SPDFMacAISubagentInstructionsLimit),
                                @"description" : @"What to find out, where to look (document title or path, pages) and "
                                                 "what to report, complete on its own."}}};
    return @{@"type" : @"function", @"function" : @{@"name" : SPDFMacAISubagentsToolName,
        @"description" : description,
        @"parameters" : @{@"type" : @"object", @"additionalProperties" : @NO, @"required" : @[@"tasks"],
            @"properties" : @{@"tasks" : @{@"type" : @"array", @"minItems" : @1,
                @"maxItems" : @(SPDFMacAISubagentsMaximumTasks), @"items" : task}}}}};
}

// What one request has spent on tasks so far, across its runs.
@interface SPDFMacAISubagentAllowance : NSObject
@property(nonatomic) NSUInteger runs;
@property(nonatomic) SPDFMacAIRequestBudget* turns; // the request's task turns: a step budget, nothing else limited
@end
@implementation SPDFMacAISubagentAllowance
@end

@implementation SPDFMacAISubagentsProvider {
    NSMutableArray<SPDFMacAISubagentRun*>* _runs;
    // Per request, by its context. Weak keys: a request whose end never reached this provider (its chat closed
    // mid-request) leaves no entry behind, and a provider shared by two chats keeps their requests apart.
    NSMapTable<SPDFMacAIRequestContext*, SPDFMacAISubagentAllowance*>* _allowances;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _timeout = 180;
    _taskProviders = SPDFMacAISubagentToolProviders();
    _turnsPerRequest = SPDFMacAISubagentsTurnsPerRequest;
    _runs = [NSMutableArray array];
    _allowances = [NSMapTable weakToStrongObjectsMapTable];
    return self;
}

- (SPDFMacAISubagentAllowance*)allowanceForContext:(SPDFMacAIRequestContext*)context {
    SPDFMacAISubagentAllowance* allowance = [_allowances objectForKey:context];
    if (allowance) return allowance;
    allowance = [SPDFMacAISubagentAllowance new];
    allowance.turns = [[SPDFMacAIRequestBudget alloc] initWithSteps:self.turnsPerRequest tokens:NSUIntegerMax
                                                         toolCalls:NSUIntegerMax];
    [_allowances setObject:allowance forKey:context];
    return allowance;
}

// Why this request may not run tasks now, written for the model; nil when it may.
- (NSString*)unavailableReasonForContext:(SPDFMacAIRequestContext*)context {
    NSString* reason = Unavailable(context);
    if (reason) return reason;
    return [_allowances objectForKey:context].runs >= SPDFMacAISubagentsRunsPerRequest ? kRunsUsed : nil;
}

- (void)setTaskProviders:(NSSet<NSString*>*)taskProviders {
    // Never this provider: a task that could call run_subagents would be the recursion the plan rules out.
    NSMutableSet* allowed = [taskProviders mutableCopy] ?: [NSMutableSet set];
    [allowed removeObject:SPDFMacAISubagentsProviderIdentifier];
    _taskProviders = [allowed copy];
}

- (NSString*)providerIdentifier { return SPDFMacAISubagentsProviderIdentifier; }
- (BOOL)providesTool:(NSString*)name { return [name isEqual:SPDFMacAISubagentsToolName]; }
// It changes nothing: its tasks only read. That also keeps it available to a request that read Friends messages,
// which may only read; its tasks still never see Friends tools.
- (BOOL)isReadOnlyTool:(NSString*)name { return [self providesTool:name]; }

// In a request that includes Friends chats the main assistant may copy a friend's words into a task, and the findings
// can echo them: the call's tasks and findings stay out of the chat file, like the rows (SPDFMacAIToolProvider.h § 4).
- (BOOL)isRequestOnlyTool:(NSString*)name context:(SPDFMacAIRequestContext*)context {
    return [self providesTool:name] && context.includesFriendsChats;
}

- (NSArray<NSDictionary*>*)toolDefinitionsForContext:(SPDFMacAIRequestContext*)context {
    return [self unavailableReasonForContext:context] ? @[] : @[Definition(self.timeout)];
}

// While the tool is offered, the main assistant's prompt says when to split; until the request has run tasks, it
// also says when the person's message itself points at work that splits (SPDFMacAISubagentSplitHint). Nothing for a
// task (depth 1) or a request that may not run tasks, so a request without the tool costs nothing more.
- (NSArray<NSDictionary*>*)messagesForRequest:(NSArray<NSDictionary*>*)messages
                                      context:(SPDFMacAIRequestContext*)context {
    NSDictionary* system = messages.firstObject;
    if ([self unavailableReasonForContext:context] || ![system isKindOfClass:NSDictionary.class] ||
        ![system[@"role"] isEqual:@"system"] || ![system[@"content"] isKindOfClass:NSString.class])
        return messages;
    NSString* added = kWhenToSplit;
    if (![_allowances objectForKey:context].runs) {
        NSMutableArray* files = [NSMutableArray array];
        for (SPDFMacAIRequestChip* chip in context.chips)
            if ([chip.kind isEqual:SPDFMacAIChipKindDocument] || [chip.kind isEqual:SPDFMacAIChipKindAttachment])
                [files addObject:chip.displayName];
        NSString* hint = SPDFMacAISubagentSplitHint(context.text, files);
        if (hint) added = [added stringByAppendingFormat:@" %@", hint];
    }
    NSMutableDictionary* prompt = [system mutableCopy];
    prompt[@"content"] = [system[@"content"] stringByAppendingFormat:@" %@", added];
    NSMutableArray* told = [messages mutableCopy];
    told[0] = prompt;
    return told;
}

- (NSString*)unavailableMessageForTool:(NSString*)name context:(SPDFMacAIRequestContext*)context {
    (void)name;
    return [self unavailableReasonForContext:context];
}

- (void)performTool:(NSString*)name arguments:(NSDictionary*)arguments context:(SPDFMacAIRequestContext*)context
         completion:(SPDFMacAIToolCompletion)completion {
    // The registry already refuses a tool the request does not offer; checked again here so that holds for any
    // caller, a test or a future registry, not only this one.
    NSString* refusal = [self providesTool:name] ? [self unavailableReasonForContext:context] : @"Unknown tool.";
    NSArray* tasks = refusal ? nil : SPDFMacAISubagentTasks(arguments, &refusal);
    if (!tasks) {
        completion(@{@"error" : refusal ?: @"Unknown tool."});
        return;
    }
    SPDFMacAISubagentAllowance* allowance = [self allowanceForContext:context];
    SPDFMacAISubagentRun* run = [[SPDFMacAISubagentRun alloc] initWithTasks:tasks context:context
        providers:self.taskProviders timeout:self.timeout requestTurns:allowance.turns];
    [_runs addObject:run];
    __weak __typeof__(self) weakSelf = self;
    [run startWithCompletion:^(NSDictionary* result) {
        __typeof__(self) owner = weakSelf;
        if (owner) [owner->_runs removeObject:run];
        completion(result);
    }];
    // Only a run whose tasks started counts: a refused one spent nothing, and its refusal may ask for fewer tasks.
    // A model retrying refusals still spends a step of the request on each.
    if (run.started) allowance.runs++;
}

- (void)cancel {
    for (SPDFMacAISubagentRun* run in [_runs copy]) [run cancel];
}

// A request ends with its run finished; this only matters if it ended some other way first.
- (void)endRequestWithContext:(SPDFMacAIRequestContext*)context {
    for (SPDFMacAISubagentRun* run in [_runs copy])
        if (run.context == context) [run cancel];
    [_allowances removeObjectForKey:context];
}

@end
