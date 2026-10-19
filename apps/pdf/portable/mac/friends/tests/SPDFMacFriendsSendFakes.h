// A scripted Friends helper for the send tests: records every intent the adapter sends, answers each the way a test
// scripts it, and never touches a socket. What a test checks is what would have reached Friends.

#pragma once
#import <Foundation/Foundation.h>
#import "SPDFMacFriendsSendProvider.h"

@interface FakeSender : NSObject <SPDFMacFriendsIntentSender>
@property(nonatomic) BOOL friendsReady;
@property(nonatomic, copy) NSSet<NSString*>* helperCapabilities;
@property NSMutableArray<NSDictionary*>* intents; // {type, fields}
// type -> {"result": {...}} or {"code": "...", "message": "..."}; send_message defaults to a fresh message id.
@property NSMutableDictionary<NSString*, NSDictionary*>* replies;
// While YES, replies wait in `held` until -releaseHeld.
@property BOOL hold;
@property NSMutableArray<dispatch_block_t>* held;
// welcome.strings, as the helper's welcome would carry them (PROTOCOL.md § Static strings).
@property(copy) NSDictionary<NSString*, NSString*>* strings;
- (NSArray<NSDictionary*>*)intentsOfType:(NSString*)type;
- (void)releaseHeld;
@end

@implementation FakeSender
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _friendsReady = YES;
    _helperCapabilities = [NSSet set];
    _intents = [NSMutableArray array];
    _replies = [NSMutableDictionary dictionary];
    _held = [NSMutableArray array];
    return self;
}
- (NSArray<NSDictionary*>*)intentsOfType:(NSString*)type {
    return [self.intents filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"type == %@", type]];
}
- (void)sendIntent:(NSString*)type fields:(NSDictionary*)fields reply:(SPDFMacFriendsIntentReply)reply {
    [self.intents addObject:@{@"type" : type, @"fields" : fields ?: @{}}];
    NSDictionary* scripted = self.replies[type];
    NSUInteger count = [self intentsOfType:type].count;
    dispatch_block_t answer = ^{
        if (scripted[@"code"]) { reply(nil, scripted[@"code"], scripted[@"message"]); return; }
        NSDictionary* result = scripted[@"result"];
        if (!result && [type isEqual:@"send_message"]) {
            NSArray* files = fields[@"attachments"] ?: @[];
            NSMutableArray* transfers = [NSMutableArray array];
            for (NSUInteger index = 0; index < files.count; index++)
                [transfers addObject:[NSString stringWithFormat:@"t_%lu_%lu", (unsigned long)count,
                                                                (unsigned long)index]];
            result = @{@"message_id" : [NSString stringWithFormat:@"m_sent_%lu", (unsigned long)count],
                       @"transfer_ids" : transfers};
        }
        reply(result ?: @{}, nil, nil);
    };
    if (self.hold) [self.held addObject:answer]; else answer();
}
- (void)releaseHeld {
    NSArray* held = [self.held copy];
    [self.held removeAllObjects];
    for (dispatch_block_t answer in held) answer();
}
- (NSString*)staticStringForKey:(NSString*)key { return self.strings[key]; }
@end

// Friends' own sentence for when queued messages go, as fixtures/frames/welcome.json carries it.
static NSString* const kQueuedNote =
    @"Messages and files send when {first} is nearby with ShenzhenPDF, Shenzhen Files or Shenzhen 3D open.";

static inline SPDFMacAIRequestChip* FriendChip(NSString* conversation, NSString* name) {
    return [SPDFMacAIRequestChip friendsChipWithConversationIDs:@[conversation] displayName:name];
}

static inline NSDictionary* Revision(NSString* sha) {
    return @{@"source" : @"com.intuition.shenzhenpdf", @"document_id" : @"d_7f3a", @"revision_id" : @"r_0412",
             @"label" : @"version saved today, 14:02", @"sha256" : sha, @"size" : @2516582};
}
