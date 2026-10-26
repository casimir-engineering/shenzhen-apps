#import "SPDFMacAIChatSessionInternal.h"
#import "SPDFMacAIToolArguments.h"
// What the model is told about a call it must send again. Model-facing: it names the tool and the fault so the
// next attempt can avoid it. A long run_python call is where arguments get cut off, hence the advice on code.
static NSString* RetryResult(NSString* name,SPDFMacAIToolArgumentsProblem problem) {
    NSString* fault=problem==SPDFMacAIToolArgumentsTruncated ? @"were cut off before they ended" :
        problem==SPDFMacAIToolArgumentsTooLong ? @"were longer than 64 KB" : @"were not valid JSON";
    NSString* text=[NSString stringWithFormat:@"The arguments for %@ %@, so nothing in your last reply ran. "
        "Send the call again with valid JSON arguments; for long code, write shorter code or split it into "
        "several calls.",name,fault];
    return SPDFMacAIToolArgumentsJSON(@{@"error":text});
}
static NSString* const NotRunResult=@"{\"error\":\"Not run: another call in the same reply could not be read. "
    "Send this call again if it is still needed.\"}";
@implementation SPDFMacAIChatSession (Calls)
- (BOOL)canRetry { return _retryable && !_running && _activityState==SPDFMacAIChatActivityError; }
- (NSDictionary*)lastUnreadableCall { return _unreadableCall; }
- (NSUInteger)retryMessageIndex {
    for (NSUInteger index=_messages.count;index>0;index--) {
        NSDictionary* message=_messages[index-1];
        if ([message[@"role"] isEqual:@"user"] && [message[@"content"] isKindOfClass:NSString.class]) return index-1;
    }
    return NSNotFound;
}
- (void)finish:(NSString*)status retryable:(BOOL)retryable {
    // Sending the question again would repeat changes this request already made to a document; a follow-up won't.
    _retryable=retryable && !_changedDocument && !self.depth && _context.origin==SPDFMacAIRequestOriginChat &&
        [self retryMessageIndex]!=NSNotFound;
    [self finish:status];
}
// Decided before the save that writes the calls' arguments. A call to a tool this request did not offer has no
// provider to vouch that its arguments quote no friend.
- (void)markRequestOnlyCalls:(NSArray*)calls offered:(NSSet*)offered {
    SPDFMacAIRequestContext* request=_context;
    for (NSDictionary* call in calls) {
        NSString* name=call[@"function"][@"name"];
        if ([_registry isRequestOnlyTool:name context:request] ||
            (request.includesFriendsChats && ![offered containsObject:name]))
            [_requestOnlyCalls addObject:call[@"id"]];
    }
}
// In memory only: the provider's own text, which may quote the document, never reaches the chat file or a log.
- (void)rememberUnreadableCall:(NSDictionary*)call problem:(SPDFMacAIToolArgumentsProblem)problem {
    id raw=call[@"function"][@"arguments"];
    NSString* text=[raw isKindOfClass:NSString.class] ? raw : [raw description] ?: @"";
    _unreadableCall=@{@"name":call[@"function"][@"name"],@"problem":@(problem),@"length":@(text.length),
        @"arguments":[text substringToIndex:[text rangeOfComposedCharacterSequencesForRange:
            NSMakeRange(0,MIN(text.length,4096UL))].length]};
}
- (NSArray*)runnableCalls:(NSArray*)calls message:(NSDictionary*)message offered:(NSSet*)offered
    generation:(NSUInteger)generation {
    NSMutableSet* identifiers=[NSMutableSet set]; NSMutableArray* runnable=[NSMutableArray array];
    NSMutableDictionary* problems=[NSMutableDictionary dictionary];
    for (id call in calls) {
        id function=[call isKindOfClass:NSDictionary.class] ? call[@"function"] : nil;
        if (!function || ![call[@"id"] isKindOfClass:NSString.class] || ![call[@"id"] length] ||
            [identifiers containsObject:call[@"id"]] || ![function isKindOfClass:NSDictionary.class] ||
            ![function[@"name"] isKindOfClass:NSString.class] || ![function[@"name"] length]) {
            [self recoverFromUnusableReply:nil problem:@"it could not be read" generation:generation]; return nil;
        }
        [identifiers addObject:call[@"id"]];
        SPDFMacAIToolArgumentsProblem problem; BOOL repaired=NO;
        NSDictionary* arguments=SPDFMacAIToolCallArguments(function[@"arguments"],&problem,&repaired);
        NSMutableDictionary* kept=[call mutableCopy]; NSMutableDictionary* readable=[function mutableCopy];
        if (!arguments) { problems[call[@"id"]]=@(problem); [self rememberUnreadableCall:call problem:problem]; }
        else if (repaired) readable[@"arguments"]=SPDFMacAIToolArgumentsJSON(arguments);
        kept[@"function"]=readable; [runnable addObject:kept];
    }
    if (!problems.count) return runnable;
    // Nothing in the batch runs: its other calls may depend on the one that can't be read.
    // The model is asked again within the request, at the cost of a step, a few times in a row; then the request winds
    // up with what it has, and Continue. The turn is kept as the provider can take it back: every call with "{}"
    // arguments, then a result saying what to resend.
    BOOL windUp=_argumentsRetries>=3; _argumentsRetries++;
    NSMutableArray* stubs=[NSMutableArray array];
    for (NSDictionary* call in runnable)
        [stubs addObject:@{@"id":call[@"id"],@"type":@"function",
            @"function":@{@"name":call[@"function"][@"name"],@"arguments":@"{}"}}];
    [self markRequestOnlyCalls:stubs offered:offered];
    id content=message[@"content"];
    [_messages addObject:@{@"role":@"assistant",@"content":[content isKindOfClass:NSString.class] ? content : @"",
        @"tool_calls":[stubs copy]}];
    for (NSDictionary* call in stubs) {
        NSNumber* problem=problems[call[@"id"]];
        [_messages addObject:@{@"role":@"tool",@"tool_call_id":call[@"id"],@"content":problem ?
            RetryResult(call[@"function"][@"name"],(SPDFMacAIToolArgumentsProblem)problem.integerValue) :
            NotRunResult}];
    }
    if (![self persist]) return nil;
    [self notify];
    if (windUp) [self windUpWithReason:@"Your last replies' calls could not be read." generation:generation];
    else [self nextRequest:generation];
    return nil;
}
@end
