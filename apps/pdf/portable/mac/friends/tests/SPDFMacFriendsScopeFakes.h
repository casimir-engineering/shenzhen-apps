// Scripted Friends services, scope and model for the AI scope tests. Every call is counted, so a test proves what
// reached the helper rather than what came back.

#pragma once
#import <Foundation/Foundation.h>
#import "mac/SZFriendsHost.h"
#import "SPDFMacAIChatSession.h"
#import "SPDFMacAITransport.h"

static inline NSDictionary* FakeResult(NSString* conversation, NSString* message, NSString* excerpt) {
    return @{@"conversation_id" : conversation, @"conversation_title" : conversation, @"message_id" : message,
             @"sender_label" : @"Mei", @"sent_at" : @"2026-10-12T06:32:00Z", @"excerpt" : excerpt};
}

@interface FakeScope : NSObject <SZFriendsChatScope>
@property NSArray* searchResults;
@property NSDictionary* readExcerpt;
@property NSInteger searches, reads, closes;
@end
@implementation FakeScope
- (void)searchFor:(NSString*)query completion:(SZFriendsScopeSearchCompletion)completion {
    (void)query; self.searches++; completion(self.searchResults ?: @[], nil);
}
- (void)readAroundMessage:(NSString*)messageID completion:(SZFriendsScopeReadCompletion)completion {
    (void)messageID; self.reads++; completion(self.readExcerpt, nil);
}
- (void)close { self.closes++; }
@end

@interface FakeServices : NSObject <SZFriendsServices>
@property FakeScope* scope;
@property NSInteger opens;
@property NSArray* openedIDs;
@property NSTimeInterval delay;
@property BOOL never;
@end
@implementation FakeServices
- (instancetype)init { if ((self = [super init])) _scope = [FakeScope new]; return self; }
- (void)searchMessages:(NSString*)q limit:(NSUInteger)l completion:(void (^)(NSArray<SZFriendsSearchResult*>*))c {
    (void)q; (void)l; c(@[]);
}
- (void)showMessage:(NSString*)m inConversation:(NSString*)c { (void)m; (void)c; }
- (void)openChatScopeForConversations:(NSArray<NSString*>*)ids
                           completion:(void (^)(id<SZFriendsChatScope>, NSError*))completion {
    self.opens++;
    self.openedIDs = ids;
    if (self.never) return;
    FakeScope* scope = self.scope;
    if (self.delay <= 0) { completion(scope, nil); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.delay * NSEC_PER_SEC)), dispatch_get_main_queue(),
                   ^{ completion(scope, nil); });
}
@end

// The model: records each request's tool definitions and lets the test answer it.
@interface FakeModel : SPDFMacAITransport
@property(copy) void (^reply)(NSDictionary*, NSError*);
@property NSArray* definitions;
@property NSArray* messages;
@property NSUInteger sends;
@end
@implementation FakeModel
- (SPDFMacAIRequestToken*)sendMessages:(NSArray*)messages tools:(NSArray*)tools model:(NSString*)model
                                apiKey:(NSString*)key completion:(void (^)(NSDictionary*, NSError*))completion {
    (void)model; (void)key;
    self.definitions = tools; self.messages = messages; self.reply = completion; self.sends++;
    return [SPDFMacAIRequestToken new];
}
@end

// ShenzhenPDF's own tools: counts what actually ran.
@interface FakeReaderTools : NSObject <SPDFMacAIChatTools>
@property NSMutableArray<NSString*>* ran;
@end
@implementation FakeReaderTools
- (instancetype)init { if ((self = [super init])) _ran = [NSMutableArray array]; return self; }
- (void)performTool:(NSString*)name arguments:(NSDictionary*)arguments completion:(void (^)(NSDictionary*))completion {
    (void)arguments; [self.ran addObject:name]; completion(@{@"ok" : @YES});
}
- (BOOL)canUndo { return NO; }
- (void)cancel {}
- (BOOL)undoLastAction:(NSError**)error { (void)error; return NO; }
@end

static inline NSDictionary* ToolCall(NSString* identifier, NSString* name, NSDictionary* arguments) {
    NSData* json = [NSJSONSerialization dataWithJSONObject:arguments options:0 error:nil];
    return @{@"id" : identifier, @"type" : @"function",
             @"function" : @{@"name" : name, @"arguments" : [[NSString alloc] initWithData:json encoding:4]}};
}
