// `szpdf annotate`, `szpdf canvas new`, and the reader's side of them (SPDFMacAnnotateAgents.h). The command lines are
// read in SPDFMacSzpdfAnnotateCommands.mm; here szpdf finds the reader (opening the document behind your windows when
// it is not open), sends the operations, and prints what -[SPDFMacFillController applyOperations:tab:completion:]
// answered. Annotate's own answers say {"ok":false,"error":code,"message":...}; szpdf prints its errors as
// {"error":{"code","message"}}, so each answer is reshaped once, here.
#import "SPDFMacAnnotateAgents.h"

#import "SPDFMacBackgroundOpening.h"
#import "SPDFMacFillController+Annotate.h"
#import "SPDFMacModels.h"
#import "SPDFMacSzpdfInternal.h"

#import <objc/runtime.h>

#include <signal.h>
#include <unistd.h>

@interface ShenzhenMacDelegate (SPDFMacAnnotateAgentsHost)
- (SPDFMacFillController*)fillController;
- (NSInteger)indexOfTabForPath:(NSString*)path;
@end

#pragma mark - Tab ids

static char kTabIdentifierKey;

NSString* SPDFAnnotateTabIdentifier(SPDFDocumentTab* tab) {
    if (!tab) return nil;
    NSString* identifier = objc_getAssociatedObject(tab, &kTabIdentifierKey);
    if (identifier) return identifier;
    static NSUInteger next;
    identifier = [NSString stringWithFormat:@"tab-%d-%lu", (int)getpid(), (unsigned long)++next];
    objc_setAssociatedObject(tab, &kTabIdentifierKey, identifier, OBJC_ASSOCIATION_COPY_NONATOMIC);
    return identifier;
}

static pid_t TabProcess(NSString* identifier) {
    NSArray* parts = [identifier componentsSeparatedByString:@"-"];
    return parts.count == 3 ? (pid_t)[parts[1] intValue] : 0;
}

#pragma mark - Answers

// One of Annotate's answers in szpdf's shape: {"ok": false, "error": {"code", "message"}}.
NSDictionary* SPDFAnnotateAgentAnswer(NSDictionary* answer) {
    if (![answer isKindOfClass:NSDictionary.class]) return SPDFMacSzpdfFailure(@"failed", @"No answer.", nil);
    NSMutableDictionary* out = [answer mutableCopy];
    id error = out[@"error"];
    if ([error isKindOfClass:NSString.class] && !out[@"errorCode"]) {
        out[@"error"] = @{@"code" : error, @"message" : [out[@"message"] isKindOfClass:NSString.class] ? out[@"message"] : error};
        [out removeObjectForKey:@"message"];
    } else if (!error && [out[@"ok"] isEqual:@NO]) {
        out[@"error"] = @{@"code" : @"failed", @"message" : @"The operation did not succeed."};
    }
    return out;
}

NSDictionary* SPDFAnnotateScriptAnswer(NSDictionary* answer) {
    NSMutableArray* results = [NSMutableArray array];
    for (NSDictionary* result in [answer[@"results"] isKindOfClass:NSArray.class] ? answer[@"results"] : @[])
        [results addObject:SPDFAnnotateAgentAnswer(result)];
    NSMutableDictionary* out = [@{@"results" : results, @"applied" : @(results.count)} mutableCopy];
    NSUInteger failed = [results indexOfObjectPassingTest:^BOOL(NSDictionary* result, NSUInteger i, BOOL* stop) {
      (void)i; (void)stop;
      return result[@"error"] != nil;
    }];
    if (failed != NSNotFound) {
        out[@"error"] = results[failed][@"error"];
        out[@"failedAt"] = @(failed);
        out[@"applied"] = @(failed);
    }
    out[@"ok"] = @(failed == NSNotFound);
    for (NSString* key in @[ @"tab", @"windowId" ])
        if (answer[key]) out[key] = answer[key];
    return out;
}

static BOOL Shows(NSDictionary* state, NSString* path) {
    for (NSDictionary* window in state[@"windows"])
        for (NSDictionary* document in window[@"documents"])
            if ([document[@"path"] isEqual:path]) return YES;
    return NO;
}

#pragma mark - szpdf, in its own process

// The reader that will answer for `target`, the document opened there behind your windows if it is not shown yet.
static pid_t ReaderFor(NSString* target, NSTimeInterval timeout, NSDictionary** failure) {
    if (SPDFAnnotateIsTabIdentifier(target)) {
        pid_t pid = TabProcess(target);
        if (pid > 0 && SPDFMacSzpdfReaders()[@(pid)]) return pid;
        *failure = SPDFMacSzpdfFailure(@"not-open", @"No tab has that id: it was closed, or ShenzhenPDF quit since. "
                                                    @"szpdf canvas new answers a new one.", nil);
        return 0;
    }
    BOOL folder = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:target isDirectory:&folder] || folder) {
        *failure = SPDFMacSzpdfFailure(@"not-found", [NSString stringWithFormat:@"No document at %@.", target], nil);
        return 0;
    }
    pid_t pid = SPDFMacSzpdfReader(target, NO, timeout, failure);
    if (!pid || Shows(SPDFMacSzpdfReaders()[@(pid)], target)) return pid;
    NSDictionary* opened = SPDFMacSzpdfSend(pid, @{@"command" : @"open", @"path" : target, @"front" : @NO, @"wait" : @YES,
                                                   @"timeout" : @((NSInteger)timeout)}, timeout + 10);
    if ([opened[@"opened"] boolValue]) return pid;
    *failure = opened;
    return 0;
}

int SPDFMacSzpdfAnnotate(NSDictionary* command) {
    if ([command[@"command"] isEqual:@"annotate-schema"]) return SPDFMacSzpdfFinish(SPDFMacSzpdfAnnotateSchemaAnswer(command[@"op"]));
    NSString* target = command[@"target"];
    NSTimeInterval timeout = [command[@"timeout"] doubleValue] ?: 60;
    NSDictionary* failure = nil;
    pid_t pid = ReaderFor(target, timeout, &failure);
    if (!pid) return SPDFMacSzpdfFinish(failure ?: SPDFMacSzpdfFailure(@"not-responding", @"ShenzhenPDF did not answer.", nil));
    NSDictionary* answer = SPDFMacSzpdfSend(pid, @{@"command" : @"annotate", @"target" : target, @"ops" : command[@"ops"],
                                                   @"timeout" : @((NSInteger)timeout)}, timeout + 10);
    if (![answer[@"results"] isKindOfClass:NSArray.class]) return SPDFMacSzpdfFinish(SPDFAnnotateAgentAnswer(answer));
    if ([command[@"script"] boolValue]) return SPDFMacSzpdfFinish(SPDFAnnotateScriptAnswer(answer));
    NSArray* results = SPDFAnnotateScriptAnswer(answer)[@"results"];
    NSMutableDictionary* out = [results.firstObject mutableCopy] ?: [SPDFMacSzpdfFailure(@"failed", @"No answer.", nil) mutableCopy];
    NSMutableDictionary* form = results.count > 1 ? [results[1] mutableCopy] : nil;
    [form removeObjectForKey:@"ok"];
    if ([command[@"state"] boolValue] && form && !form[@"error"]) out[@"form"] = form;
    for (NSString* key in @[ @"tab", @"windowId" ])
        if (answer[key] && !out[key]) out[key] = answer[key];
    return SPDFMacSzpdfFinish(out);
}

int SPDFMacSzpdfCanvas(NSDictionary* command) {
    BOOL front = [command[@"front"] boolValue];
    NSTimeInterval timeout = [command[@"timeout"] doubleValue] ?: 60;
    NSDictionary* failure = nil;
    pid_t pid = SPDFMacSzpdfReader(@"", front, timeout, &failure);
    if (!pid) return SPDFMacSzpdfFinish(failure ?: SPDFMacSzpdfFailure(@"not-responding", @"ShenzhenPDF did not answer.", nil));
    NSMutableDictionary* request = [@{@"command" : @"canvas-new", @"front" : @(front)} mutableCopy];
    for (NSString* key in @[ @"width", @"height", @"background" ])
        if (command[key]) request[key] = command[key];
    return SPDFMacSzpdfFinish(SPDFAnnotateAgentAnswer(SPDFMacSzpdfSend(pid, request, timeout + 10)));
}

#pragma mark - The reader's side

@implementation ShenzhenMacDelegate (SPDFMacAnnotateAgentTabs)

- (SPDFDocumentTab*)annotateAgentTabForTarget:(NSString*)target {
    if (![target isKindOfClass:NSString.class] || !target.length) return nil;
    if (SPDFAnnotateIsTabIdentifier(target)) {
        for (SPDFDocumentTab* tab in _tabs)
            if ([objc_getAssociatedObject(tab, &kTabIdentifierKey) isEqual:target]) return tab;
        return nil;
    }
    NSInteger index = [self indexOfTabForPath:target];
    return index >= 0 && (NSUInteger)index < _tabs.count ? _tabs[(NSUInteger)index] : nil;
}

- (void)annotateAgentApply:(NSArray<NSDictionary*>*)ops tab:(SPDFDocumentTab*)tab
                     reply:(void (^)(NSDictionary*))reply {
    __block BOOL answered = NO;
    NSString* identifier = SPDFAnnotateTabIdentifier(tab);
    NSNumber* window = @(_window.windowNumber);
    [[self fillController] applyOperations:ops tab:tab completion:^(NSDictionary* result) {
      if (answered) return;
      answered = YES;
      NSMutableDictionary* answer = [result isKindOfClass:NSDictionary.class] ? [result mutableCopy] : [NSMutableDictionary dictionary];
      if (![answer[@"results"] isKindOfClass:NSArray.class]) answer[@"results"] = @[ result ?: @{@"ok" : @NO} ];
      answer[@"tab"] = identifier;
      answer[@"windowId"] = window;
      if (tab.path.length) answer[@"path"] = tab.path;
      reply(answer);
    }];
}

- (void)annotateAgentNewCanvas:(NSDictionary*)arguments front:(BOOL)front reply:(void (^)(NSDictionary*))reply {
    NSArray* before = [_tabs copy];
    NSMutableDictionary* op = [@{@"op" : @"canvas.new"} mutableCopy];
    for (NSString* key in @[ @"width", @"height", @"background" ])
        if (arguments[key]) op[key] = arguments[key];
    __block BOOL answered = NO;
    [[self fillController] applyOperation:op tab:nil completion:^(NSDictionary* result) {
      if (answered) return;
      answered = YES;
      NSMutableDictionary* answer = [result isKindOfClass:NSDictionary.class] ? [result mutableCopy] : [NSMutableDictionary dictionary];
      SPDFDocumentTab* made = nil;
      for (SPDFDocumentTab* tab in self->_tabs)
          if ([before indexOfObjectIdenticalTo:tab] == NSNotFound) made = tab;
      if (made) {
          answer[@"tab"] = SPDFAnnotateTabIdentifier(made);
          answer[@"windowId"] = @(self->_window.windowNumber);
          if (front) spdf_mac_bring_window_to_front(self->_window);
          else if (!self->_window.visible && !self->_window.miniaturized) spdf_mac_show_window_in_background(self->_window);
      }
      reply(answer);
    }];
}

@end

@implementation ShenzhenMacDelegate (SPDFMacAnnotateAgentServer)

+ (void)agentAnnotate:(NSDictionary*)request readers:(NSArray<ShenzhenMacDelegate*>*)readers
                reply:(void (^)(NSDictionary*))reply {
    for (ShenzhenMacDelegate* reader in readers) {
        SPDFDocumentTab* tab = [reader annotateAgentTabForTarget:request[@"target"]];
        if (!tab) continue;
        [reader annotateAgentApply:request[@"ops"] tab:tab reply:reply];
        return;
    }
    reply(SPDFAnnotateIsTabIdentifier(request[@"target"])
              ? @{@"errorCode" : @"not-open", @"error" : @"No tab has that id: it was closed since."}
              : @{@"errorCode" : @"not-open", @"error" : @"The document is not open in ShenzhenPDF."});
}

+ (void)agentCanvasNew:(NSDictionary*)request readers:(NSArray<ShenzhenMacDelegate*>*)readers
                 reply:(void (^)(NSDictionary*))reply {
    ShenzhenMacDelegate* target = nil;
    for (ShenzhenMacDelegate* reader in readers)
        if (!target && reader->_window.keyWindow) target = reader;
    target = target ?: readers.firstObject;
    if (!target) {
        reply(@{@"errorCode" : @"no-window", @"error" : @"ShenzhenPDF has no window to open the canvas in."});
        return;
    }
    [target annotateAgentNewCanvas:request front:[request[@"front"] boolValue] reply:reply];
}

@end
