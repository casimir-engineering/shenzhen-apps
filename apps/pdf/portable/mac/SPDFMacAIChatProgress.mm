#import "SPDFMacAIChatProgress.h"

const NSUInteger SPDFMacAIProgressRepeatedFailures = 3;
const NSUInteger SPDFMacAIProgressStalledSteps = 4;
static NSString* const kStall = @"(stalled)";
static const NSUInteger kMaximumNudges = 3;

NSString* SPDFMacAIProgressSignature(NSString* name, NSDictionary* arguments) {
    NSData* data = [arguments isKindOfClass:NSDictionary.class] && [NSJSONSerialization isValidJSONObject:arguments]
        ? [NSJSONSerialization dataWithJSONObject:arguments options:NSJSONWritingSortedKeys error:nil] : nil;
    NSString* text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
    return [NSString stringWithFormat:@"%@ %@", name ?: @"", text ?: @"{}"];
}

static NSString* Clip(NSString* text, NSUInteger limit) {
    if (text.length <= limit) return text;
    return [[text substringWithRange:[text rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, limit)]]
        stringByAppendingString:@"…"];
}

@implementation SPDFMacAIProgressGuard {
    NSMutableSet<NSString*>* _seen;                 // successful calls since the last change
    NSMutableDictionary<NSString*, NSNumber*>* _failures;
    NSMutableDictionary<NSString*, NSString*>* _errors;
    NSMutableSet<NSString*>* _nudged;               // loops the model was already told about
    NSMutableOrderedSet<NSString*>* _failedThisStep;
    BOOL _newThisStep;
    NSUInteger _stalled, _nudges;
    NSString* _note;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _seen = [NSMutableSet set];
    _failures = [NSMutableDictionary dictionary];
    _errors = [NSMutableDictionary dictionary];
    _nudged = [NSMutableSet set];
    _failedThisStep = [NSMutableOrderedSet orderedSet];
    return self;
}

- (NSString*)note { return _note; }

- (void)recordCall:(NSString*)name arguments:(NSDictionary*)arguments result:(NSDictionary*)result {
    NSString* signature = SPDFMacAIProgressSignature(name, arguments);
    id error = [result isKindOfClass:NSDictionary.class] ? result[@"error"] : nil;
    BOOL failed = ![result isKindOfClass:NSDictionary.class] || error || [result[@"cancelled"] boolValue];
    if (failed) {
        _failedCalls++;
        _failures[signature] = @(_failures[signature].unsignedIntegerValue + 1);
        _errors[signature] = [error isKindOfClass:NSString.class] ? error : [error description] ?: @"no result";
        [_failedThisStep addObject:signature];
        return;
    }
    _succeededCalls++;
    if ([result[@"changed"] boolValue] || [result[@"undoable"] boolValue]) {
        // Something changed: what was read before may read differently now.
        [_seen removeAllObjects];
        _newThisStep = YES;
    } else if (![_seen containsObject:signature]) {
        _newThisStep = YES;
    }
    [_seen addObject:signature];
    [_failures removeObjectForKey:signature];
}

- (SPDFMacAIProgressVerdict)endStep {
    _steps++;
    _stalled = _newThisStep ? 0 : _stalled + 1;
    NSString* loop = nil;
    for (NSString* signature in _failedThisStep)
        if (_failures[signature].unsignedIntegerValue >= SPDFMacAIProgressRepeatedFailures) { loop = signature; break; }
    if (!loop && _stalled >= SPDFMacAIProgressStalledSteps) loop = kStall;
    [_failedThisStep removeAllObjects];
    _newThisStep = NO;
    if (!loop) return SPDFMacAIProgressGoing;
    BOOL again = [_nudged containsObject:loop] || _nudges >= kMaximumNudges;
    if (loop == kStall) {
        _note = [NSString stringWithFormat:@"Your last %lu steps did nothing new: the same calls again, or calls "
                 "that failed. Repeating them will not help.", (unsigned long)_stalled];
    } else {
        NSString* tool = [loop componentsSeparatedByString:@" "].firstObject;
        _note = [NSString stringWithFormat:@"%@ with the same arguments has failed %lu times, each time with: \"%@\". "
                 "Calling it again the same way will fail again.", tool,
                 (unsigned long)_failures[loop].unsignedIntegerValue, Clip(_errors[loop], 300)];
        [_failures removeObjectForKey:loop];
    }
    _stalled = 0;
    if (again) return SPDFMacAIProgressStop;
    [_nudged addObject:loop];
    _nudges++;
    return SPDFMacAIProgressNudge;
}

@end
