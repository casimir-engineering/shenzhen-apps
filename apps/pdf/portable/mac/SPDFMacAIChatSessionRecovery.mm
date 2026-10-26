// How a long request keeps going, and how it ends when it can't (SPDFMacAIChatSessionInternal.h § RecoveryInternal):
// a reply that can't be used is asked for again with a note saying what went wrong; a dropped connection is tried
// again after a pause; a loop is pointed out to the model (SPDFMacAIChatProgress.h); and when nothing more can be
// done in this request, one last reply without tools says what was done and what is left, and the chat offers
// Continue, which resumes the same work rather than starting it again.
#import "SPDFMacAIChatSessionInternal.h"

const NSUInteger SPDFMacAICallsRunPerReply=64;
static const NSUInteger kReplyRetries=3, kConnectionRetries=3;
static NSString* const kNotRun=@"{\"error\":\"Not run: the request paused before this call.\"}";


@implementation SPDFMacAIChatSession (Recovery)
- (NSString*)pausedStatus {
    return _changedDocument ? @"Not finished yet. Changes so far are kept; Continue picks up where it stopped." :
        @"Not finished yet. Continue picks up where it stopped.";
}
- (BOOL)canContinue { return _canContinue && !_running && !self.depth; }
- (BOOL)continueWithContext:(SPDFMacAIRequestContext*)context model:(NSString*)model apiKey:(NSString*)key {
    if (!self.canContinue || !context) return NO;
    NSUInteger before=_messages.count; _continuing=YES;
    [self sendContext:context model:model apiKey:key];
    _continuing=NO;
    return _messages.count>before;
}
// Calls of the latest reply that never got a result (a reply wound up mid-way) are answered, so the history stays a
// valid conversation to resume from.
- (void)completeOpenCallsWith:(NSString*)content {
    NSMutableSet* answered=[NSMutableSet set];
    for (NSDictionary* message in _messages)
        if ([message[@"role"] isEqual:@"tool"] && message[@"tool_call_id"]) [answered addObject:message[@"tool_call_id"]];
    for (NSDictionary* message in [_messages copy]) for (NSDictionary* call in message[@"tool_calls"])
        if ([call[@"id"] isKindOfClass:NSString.class] && ![answered containsObject:call[@"id"]])
            [_messages addObject:@{@"role":@"tool",@"tool_call_id":call[@"id"],@"content":content}];
}
- (void)recoverFromUnusableReply:(NSError*)error problem:(NSString*)problem generation:(NSUInteger)generation {
    if (!_running || generation!=_generation) return;
    _request=nil;
    if (_wrapUpSent) { [self pauseWithLocalSummary:self.pausedStatus]; return; }
    [_context.budget returnStep]; // the reply did no work
    BOOL connection=[error.domain isEqual:@"SPDFMacAI"] && [@[@5,@10,@429] containsObject:@(error.code)];
    if (connection) {
        if (_connectionRetries>=kConnectionRetries) {
            NSString* status=error.code==429 ? @"OpenRouter is busy or your account limit was reached. Your chat is "
                "saved; press Continue in a moment." : error.code==10 ? @"The model's provider stopped answering. "
                "Your chat is saved; press Continue, or choose another model first." :
                @"OpenRouter can't be reached. Your chat is saved; check your connection, then press Continue.";
            [self pauseWithLocalSummary:status]; return;
        }
        NSTimeInterval delay=(NSTimeInterval[]){2,6,15}[_connectionRetries]; _connectionRetries++;
        _activityState=SPDFMacAIChatActivityThinking; _status=@"Reconnecting…"; [self notify];
        __weak __typeof__(self) weakSelf=self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            __typeof__(self) owner=weakSelf;
            if (owner && owner->_running && owner->_generation==generation) [owner nextRequest:generation];
        });
        return;
    }
    if (_replyRetries>=kReplyRetries) {
        [self windUpWithReason:@"Your last replies could not be used." generation:generation]; return;
    }
    _replyRetries++;
    _pendingNote=[NSString stringWithFormat:@"Your previous reply could not be used: %@. Nothing in it ran. Carry on "
        "with the task.",problem];
    [self nextRequest:generation];
}
- (void)windUpWithReason:(NSString*)reason generation:(NSUInteger)generation {
    if (!_running || generation!=_generation) return;
    if (_wrapUpSent) { [self pauseWithLocalSummary:self.pausedStatus]; return; }
    _windUp=YES; _windUpReason=[reason copy]; _pendingNote=nil;
    [self completeOpenCallsWith:kNotRun];
    if ([self persist]) [self nextRequest:generation];
}
- (void)pauseAfterWindUp {
    // A part's last answer is its answer to the main assistant, which decides what is left; it just ends.
    if (self.depth) { [self finish:@""]; return; }
    _canContinue=YES;
    [self finish:self.pausedStatus state:SPDFMacAIChatActivityPaused];
}
- (void)pauseWithLocalSummary:(NSString*)status {
    [self completeOpenCallsWith:kNotRun];
    NSUInteger done=_progress.succeededCalls, failed=_progress.failedCalls;
    // A part's summary goes to the main assistant and its row, where there is no Continue.
    NSMutableString* text=[NSMutableString stringWithString:self.depth ? @"Stopped before finishing." :
        @"I stopped before finishing."];
    if (done) [text appendFormat:@" So far %lu action%@ worked",(unsigned long)done,done==1 ? @"" : @"s"];
    if (done && failed) [text appendFormat:@" and %lu didn't",(unsigned long)failed];
    if (done) [text appendString:@"."];
    if (!self.depth) [text appendString:@" Press Continue and I'll pick up from here."];
    [_messages addObject:@{@"role":@"assistant",@"content":text}];
    _canContinue=!self.depth;
    [self finish:status state:SPDFMacAIChatActivityPaused];
}
- (void)recordCall:(NSDictionary*)call arguments:(NSDictionary*)arguments result:(NSDictionary*)result {
    if (!_progress) _progress=[SPDFMacAIProgressGuard new];
    id name=call[@"function"][@"name"];
    [_progress recordCall:[name isKindOfClass:NSString.class] ? name : @"" arguments:arguments result:result];
}
- (void)endStepWithGeneration:(NSUInteger)generation {
    if (!_running || generation!=_generation) return;
    if (!_progress) _progress=[SPDFMacAIProgressGuard new];
    SPDFMacAIProgressVerdict verdict=[_progress endStep];
    if (verdict==SPDFMacAIProgressStop) {
        [self windUpWithReason:[_progress.note stringByAppendingString:@" You were told and it went on, so the "
            "request stops here."] generation:generation];
        return;
    }
    if (verdict==SPDFMacAIProgressNudge)
        _pendingNote=[_progress.note stringByAppendingString:@" Change approach: other arguments or another tool, "
            "or skip this part and carry on with the rest of the task, then say in your answer what could not be "
            "done."];
    [self nextRequest:generation];
}
- (NSArray<NSDictionary*>*)trailingNotesWrappingUp:(BOOL)wrappingUp {
    if (wrappingUp) {
        NSString* reason=_windUpReason.length ? [_windUpReason stringByAppendingString:@" "] : @"";
        return @[@{@"role":@"system",@"content":[NSString stringWithFormat:@"Stop working for now: tools are off for "
            "this reply. %@In a few short bullets, tell the person what was done (only what tool results confirm) "
            "and what is still left to do. Do not mention steps, budgets or limits: they can press Continue and you "
            "will pick up from here.",reason]}];
    }
    NSString* note=_pendingNote; _pendingNote=nil;
    return note.length ? @[@{@"role":@"system",@"content":note}] : @[];
}
@end
