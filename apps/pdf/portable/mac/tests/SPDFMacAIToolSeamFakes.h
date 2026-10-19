// Scripted model and providers for SPDFMacAIToolSeamTests. Every call is counted, so a check proves what reached a
// provider rather than what came back.
#pragma once
#import <Foundation/Foundation.h>
#import "SPDFMacAIChatSession.h"
#import "SPDFMacAIChatStore.h"
#import "SPDFMacAISettings.h"
#import "SPDFMacAITransport.h"

static int failures;
static void SeamCheck(const char* file, int line, BOOL condition, const char* message) {
    if (condition) return;
    fprintf(stderr, "FAIL %s:%d: %s\n", file, line, message);
    ++failures;
}
// Variadic, because a condition holding an array literal has commas the preprocessor would split on.
#define CHECK(...) SeamCheck(__FILE__, __LINE__, __VA_ARGS__)

@interface SeamModel : SPDFMacAITransport
@property(copy) void (^reply)(NSDictionary*, NSError*);
@property NSArray* messages;
@property NSArray* definitions;
@property NSUInteger sends;
@property NSString* key;
@end
@implementation SeamModel
- (SPDFMacAIRequestToken*)sendMessages:(NSArray*)messages tools:(NSArray*)tools model:(NSString*)model
                                apiKey:(NSString*)key completion:(void (^)(NSDictionary*, NSError*))completion {
    (void)model;
    self.key = key; self.messages = messages; self.definitions = tools; self.reply = completion; self.sends++;
    return [SPDFMacAIRequestToken new];
}
@end

static NSDictionary* SeamDefinition(NSString* name) {
    return @{@"type" : @"function", @"function" : @{@"name" : name, @"description" : name,
             @"parameters" : @{@"type" : @"object", @"properties" : @{}}}};
}
static NSArray* SeamNames(NSArray* definitions) { return [definitions valueForKeyPath:@"function.name"] ?: @[]; }
static NSDictionary* SeamCall(NSString* identifier, NSString* name) {
    return @{@"id" : identifier, @"type" : @"function", @"function" : @{@"name" : name, @"arguments" : @"{}"}};
}
static NSDictionary* SeamToolTurn(NSArray* calls) {
    return @{@"role" : @"assistant", @"content" : @"", @"tool_calls" : calls};
}
static NSDictionary* SeamAnswer(NSString* text) { return @{@"role" : @"assistant", @"content" : text}; }
static BOOL SeamWireContains(SeamModel* model, NSString* text) {
    NSData* data = [NSJSONSerialization dataWithJSONObject:model.messages ?: @[] options:0 error:nil];
    return [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] containsString:text];
}
static NSString* SeamTemporaryDirectory(NSString* name) {
    NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"spdf-ai-seam-%@-%@", name, NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    return path;
}
static void SeamRunLoop(NSTimeInterval seconds) {
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

// A provider whose tools, offers and answers a check scripts.
@interface SeamProvider : NSObject <SPDFMacAIToolProvider>
- (instancetype)initWithIdentifier:(NSString*)identifier tools:(NSDictionary<NSString*, NSNumber*>*)readOnlyByName;
@property(copy) BOOL (^offers)(NSString* name, SPDFMacAIRequestContext* context); // nil: offers everything
@property(copy) NSDictionary* (^answer)(NSString* name, SPDFMacAIRequestContext* context);
// nil: no call is request-only. Otherwise what -isRequestOnlyTool:context: answers.
@property(copy) BOOL (^requestOnly)(NSString* name, SPDFMacAIRequestContext* context);
@property(copy) NSString* readOnlyReason;
@property(copy) NSString* unavailableMessage;
@property(copy) NSString* storageMark;   // added to stored chats when set
@property(copy) NSString* wireReplace;   // replaced by "[kept out]" in each turn's messages when set
@property(copy) NSArray<SPDFMacAIRequestChip*>* chips;
@property BOOL deferCompletion;
@property(copy) SPDFMacAIToolCompletion pending;
@property NSMutableArray<NSString*>* ran;
@property NSMutableArray<SPDFMacAIRequestContext*>* contexts;
@property NSUInteger begins, ends, cancels;
@end
@implementation SeamProvider {
    NSString* _identifier;
    NSDictionary* _tools;
}
- (instancetype)initWithIdentifier:(NSString*)identifier tools:(NSDictionary<NSString*, NSNumber*>*)tools {
    if (!(self = [super init])) return nil;
    _identifier = identifier; _tools = tools;
    _ran = [NSMutableArray array]; _contexts = [NSMutableArray array];
    return self;
}
- (NSString*)providerIdentifier { return _identifier; }
- (BOOL)providesTool:(NSString*)name { return _tools[name] != nil; }
- (BOOL)isReadOnlyTool:(NSString*)name { return [_tools[name] boolValue]; }
- (BOOL)isRequestOnlyTool:(NSString*)name context:(SPDFMacAIRequestContext*)context {
    return self.requestOnly && self.requestOnly(name, context);
}
- (NSArray<NSDictionary*>*)toolDefinitionsForContext:(SPDFMacAIRequestContext*)context {
    NSMutableArray* definitions = [NSMutableArray array];
    for (NSString* name in [_tools.allKeys sortedArrayUsingSelector:@selector(compare:)])
        if (!self.offers || self.offers(name, context)) [definitions addObject:SeamDefinition(name)];
    return definitions;
}
- (void)performTool:(NSString*)name arguments:(NSDictionary*)arguments context:(SPDFMacAIRequestContext*)context
         completion:(SPDFMacAIToolCompletion)completion {
    (void)arguments;
    [self.ran addObject:name]; [self.contexts addObject:context];
    NSDictionary* result = self.answer ? self.answer(name, context) : @{@"ok" : @YES, @"tool" : name};
    if (self.deferCompletion) { self.pending = completion; return; }
    completion(result);
}
- (void)cancel { self.cancels++; }
- (void)beginRequestWithContext:(SPDFMacAIRequestContext*)context { (void)context; self.begins++; }
- (void)endRequestWithContext:(SPDFMacAIRequestContext*)context { (void)context; self.ends++; }
- (NSString*)readOnlyReasonForContext:(SPDFMacAIRequestContext*)context { (void)context; return self.readOnlyReason; }
- (NSString*)unavailableMessageForTool:(NSString*)name context:(SPDFMacAIRequestContext*)context {
    (void)name; (void)context; return self.unavailableMessage;
}
- (NSArray<NSDictionary*>*)messagesForRequest:(NSArray<NSDictionary*>*)messages context:(SPDFMacAIRequestContext*)c {
    (void)c;
    if (!self.wireReplace) return messages;
    NSMutableArray* kept = [NSMutableArray array];
    for (NSDictionary* message in messages) {
        NSMutableDictionary* copy = [message mutableCopy];
        if ([copy[@"content"] isKindOfClass:NSString.class])
            copy[@"content"] = [copy[@"content"] stringByReplacingOccurrencesOfString:self.wireReplace
                                                                           withString:@"[kept out]"];
        [kept addObject:copy];
    }
    return kept;
}
- (NSArray<SPDFMacAIRequestChip*>*)requestChipsInComposerText:(NSAttributedString*)text {
    return text.length ? self.chips ?: @[] : @[];
}
- (NSDictionary*)chatForStorage:(NSDictionary*)chat {
    if (!self.storageMark) return chat;
    NSMutableDictionary* stored = [chat mutableCopy]; stored[self.storageMark] = @YES; return stored;
}
@end

// The reader's tools object, as SPDFMacAITools looks to the session.
@interface SeamReaderTools : NSObject <SPDFMacAIChatTools>
@property NSMutableArray<NSString*>* ran;
@property NSUInteger cancels, undos;
@end
@implementation SeamReaderTools
- (instancetype)init { if ((self = [super init])) _ran = [NSMutableArray array]; return self; }
- (void)performTool:(NSString*)name arguments:(NSDictionary*)arguments completion:(void (^)(NSDictionary*))completion {
    (void)arguments; [self.ran addObject:name]; completion(@{@"ok" : @YES});
}
- (BOOL)canUndo { return self.ran.count > 0; }
- (void)cancel { self.cancels++; }
- (BOOL)undoLastAction:(NSError**)error { (void)error; self.undos++; return YES; }
- (NSDictionary*)conversationContext { return @{@"path" : @"doc:fixture", @"page" : @3}; }
@end
