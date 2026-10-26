#pragma once
// One assistant request, as the person asked it: built once per message from what they typed and attached, then
// handed to every tool provider for that request (SPDFMacAIToolProvider.h). What a tool returns never widens it:
// chips are fixed at construction, and no API adds one later, so text in a document, a web page or a friend's
// message can steer wording but never add a recipient, an attachment or a chat to read.
#import <Foundation/Foundation.h>

@class SPDFMacAISettingsSnapshot, SPDFMacAIChatSession;
@protocol SPDFMacAIActivityReporting;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SPDFMacAIRequestOrigin) {
    SPDFMacAIRequestOriginChat,           // the AI chat panel's composer
    SPDFMacAIRequestOriginFriendComposer, // `/` in a friend conversation's composer
};

FOUNDATION_EXPORT NSString* const SPDFMacAIChipKindFriends;    // `@` chip: one or all Friends chats
FOUNDATION_EXPORT NSString* const SPDFMacAIChipKindDocument;   // `#` chip: one document at an exact revision
FOUNDATION_EXPORT NSString* const SPDFMacAIChipKindAttachment; // a file the person dropped on the composer

// One chip on the person's message. Immutable.
@interface SPDFMacAIRequestChip : NSObject <NSCopying>
@property(nonatomic, readonly, copy) NSString* kind;
// What the person saw on the chip: "Mei", "All Friends chats", "Supplier contract v3.pdf".
@property(nonatomic, readonly, copy) NSString* displayName;
// Friends: the conversation ids the chip covers; nil means All Friends chats.
@property(nonatomic, readonly, copy, nullable) NSArray<NSString*>* scopeIDs;
// Document and attachment: the file holding exactly the bytes the person chose, an opaque identifier where the
// reader has one (a doc:… id of an open document, a collection:… id), and the revision object
// (PROTOCOL.md file.revision: source, document_id, revision_id, label, sha256, size), nil for a plain file.
@property(nonatomic, readonly, copy, nullable) NSURL* fileURL;
@property(nonatomic, readonly, copy, nullable) NSString* identifier;
@property(nonatomic, readonly, copy, nullable) NSDictionary<NSString*, id>* revision;
+ (instancetype)friendsChipWithConversationIDs:(nullable NSArray<NSString*>*)conversationIDs
                                   displayName:(NSString*)displayName;
+ (instancetype)documentChipWithFileURL:(NSURL*)fileURL identifier:(nullable NSString*)identifier
                               revision:(nullable NSDictionary<NSString*, id>*)revision
                            displayName:(NSString*)displayName;
+ (instancetype)attachmentChipWithFileURL:(NSURL*)fileURL displayName:(NSString*)displayName;
// A file or folder the person gave the chat (SPDFMacAIChatGrants.h): `identifier` is the attachment:… id the model
// uses for it, and a folder's URL is a directory URL.
+ (instancetype)attachmentChipWithFileURL:(NSURL*)fileURL identifier:(NSString*)identifier
                              displayName:(NSString*)displayName;
@end

// Steps (model turns), tool calls and tokens one request may still spend. A child budget is carved from its
// parent's remaining allowance and every charge to it is charged to the parent too, so subagents together can
// never outspend the request that started them. Safe to use from any thread.
FOUNDATION_EXPORT const NSUInteger SPDFMacAIRequestStepCeiling; // 120
@interface SPDFMacAIRequestBudget : NSObject
// A ceiling, not the usual end: SPDFMacAIRequestStepCeiling steps and 8,000,000 estimated tokens, no separate
// tool-call limit. A request normally ends when its task is done, or earlier when it stops making progress
// (SPDFMacAIChatProgress.h); reaching the ceiling pauses it with an answer saying what is left, and Continue.
+ (instancetype)defaultRequestBudget;
- (instancetype)initWithSteps:(NSUInteger)steps tokens:(NSUInteger)tokens toolCalls:(NSUInteger)toolCalls;
@property(nonatomic, readonly) NSUInteger remainingSteps;
@property(nonatomic, readonly) NSUInteger remainingTokens;
@property(nonatomic, readonly) NSUInteger remainingToolCalls; // NSUIntegerMax when unlimited
@property(nonatomic, readonly) NSUInteger usedSteps;
@property(nonatomic, readonly) NSUInteger usedTokens;
@property(nonatomic, readonly) NSUInteger usedToolCalls;
// YES and charged, or NO when nothing remains here or in any parent.
- (BOOL)consumeStep;
// Gives back a step consumeStep charged for a request the provider refused before doing any work, here and in every
// parent; nothing when none was charged.
- (void)returnStep;
- (BOOL)consumeToolCall;
// Charges up to what remains; tokens beyond the allowance are not an error, they end the request at its next step.
- (void)consumeTokens:(NSUInteger)tokens;
// Capped at what remains. nil when no step or no token remains to give.
- (nullable SPDFMacAIRequestBudget*)childBudgetWithSteps:(NSUInteger)steps tokens:(NSUInteger)tokens
                                               toolCalls:(NSUInteger)toolCalls;
@end

// Stop, as one object a provider can check or observe. Cancelled when the person presses Stop, starts or opens
// another chat, or the request is abandoned (a failed save, a closed window); not when a request completes, so work
// the person asked for that outlives its request (a queued send) is never cancelled by finishing normally.
@interface SPDFMacAICancellationToken : NSObject
@property(nonatomic, readonly, getter=isCancelled) BOOL cancelled;
- (void)cancel;
// Runs once when cancelled, at once if already cancelled, on the thread that cancels.
- (void)onCancel:(dispatch_block_t)handler;
// Cancelled with this token (and on its own).
- (SPDFMacAICancellationToken*)childToken;
@end

@interface SPDFMacAIRequestContext : NSObject
// `friendConversation` is required for SPDFMacAIRequestOriginFriendComposer (the conversation the `/` was typed
// in) and ignored otherwise. `budget` nil means defaultRequestBudget. `settings` nil reads as every capability
// switched off, which is what tests that build contexts by hand want.
- (instancetype)initWithText:(NSString*)text chips:(nullable NSArray<SPDFMacAIRequestChip*>*)chips
                      origin:(SPDFMacAIRequestOrigin)origin
          friendConversation:(nullable SPDFMacAIRequestChip*)friendConversation
                    settings:(nullable SPDFMacAISettingsSnapshot*)settings
                      budget:(nullable SPDFMacAIRequestBudget*)budget
                    activity:(nullable id<SPDFMacAIActivityReporting>)activity NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly, copy) NSString* requestID;
// The person's message as the model reads it (chips written as "@Mei").
@property(nonatomic, readonly, copy) NSString* text;
@property(nonatomic, readonly, copy) NSArray<SPDFMacAIRequestChip*>* chips;
- (NSArray<SPDFMacAIRequestChip*>*)chipsOfKind:(NSString*)kind;
@property(nonatomic, readonly) SPDFMacAIRequestOrigin origin;
@property(nonatomic, readonly, nullable) SPDFMacAIRequestChip* friendConversation;
// YES when the request includes Friends chats: a Friends chip (requests sent while the AI chat's time grant for all
// chats runs carry one, SPDFMacFriendsChatGrant.h), or `/` typed in a friend's conversation. Its
// assistant may then quote a friend in anything it writes, so web tools stay out of it and work kept for the
// request only (-[SPDFMacAIToolProvider isRequestOnlyTool:context:]) is decided from this, one rule for every tool.
@property(nonatomic, readonly) BOOL includesFriendsChats;
@property(nonatomic, readonly, nullable) SPDFMacAISettingsSnapshot* settings;
@property(nonatomic, readonly) SPDFMacAIRequestBudget* budget;
@property(nonatomic, readonly) SPDFMacAICancellationToken* cancellation;
// Step rows, cards and images in the chat (SPDFMacAIChatActivity.h). nil only in hand-built test contexts.
@property(nonatomic, readonly, nullable) id<SPDFMacAIActivityReporting> activity;
// 0 for the person's own request, 1 inside a child session (a subagent). There is no level 2.
@property(nonatomic, readonly) NSUInteger depth;
// The session running this request, set when it starts (weak: the context never keeps a session alive).
@property(nonatomic, readonly, weak, nullable) SPDFMacAIChatSession* session;
// A subagent's request: same chips, origin, friend, settings and activity; its own id, text and budget; cancelled
// with this one. nil with an error at depth 1, so nesting stops at one level.
- (nullable SPDFMacAIRequestContext*)childContextWithText:(NSString*)text budget:(SPDFMacAIRequestBudget*)budget
                                                    error:(NSError**)error;
// For SPDFMacAIChatSession only: binds the context to the session that runs it. NO when it was bound before, so
// one context is never two requests.
- (BOOL)bindToSession:(SPDFMacAIChatSession*)session;
@end

NS_ASSUME_NONNULL_END
