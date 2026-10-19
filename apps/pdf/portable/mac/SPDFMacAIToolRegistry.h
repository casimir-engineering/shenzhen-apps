#pragma once
// The providers of one chat session, and the one place a tool call is checked before it runs (SPDFMacAIToolProvider.h
// explains the seam). Every call goes through -performTool:arguments:context:completion:, which refuses, in order:
// a name no provider claims; a tool the registry's filter excludes; a tool the request does not offer; and, while a
// provider says the request may only read, any tool that is not read-only. Only then does the provider run it.
#import <Foundation/Foundation.h>
#import "SPDFMacAIToolProvider.h"

@protocol SPDFMacAIChatTools;

NS_ASSUME_NONNULL_BEGIN

// Which tools a registry (and the session using it) may offer: subagents get +readOnly.
@interface SPDFMacAIToolFilter : NSObject
+ (instancetype)readOnly;
// Read-only tools of these providers only; any other provider offers nothing.
+ (instancetype)readOnlyFromProviders:(NSSet<NSString*>*)identifiers;
@property(nonatomic, readonly) BOOL readOnlyOnly;
@property(nonatomic, readonly, copy, nullable) NSSet<NSString*>* providerIdentifiers; // nil: every provider
@end

@interface SPDFMacAIToolRegistry : NSObject
// NO, with an error and nothing registered, when another provider already uses the identifier.
- (BOOL)registerProvider:(id<SPDFMacAIToolProvider>)provider error:(NSError**)error;
@property(nonatomic, readonly, copy) NSArray<id<SPDFMacAIToolProvider>>* providers;
@property(nonatomic, readonly, nullable) SPDFMacAIToolFilter* filter;
// The same providers seen through `filter` (and this registry's own filter: both must allow a tool).
- (SPDFMacAIToolRegistry*)registryWithFilter:(SPDFMacAIToolFilter*)filter;

- (NSArray<NSDictionary*>*)toolDefinitionsForContext:(SPDFMacAIRequestContext*)context;
- (BOOL)isReadOnlyTool:(NSString*)name;
// The owning provider's -isRequestOnlyTool:context:; NO for a tool nobody claims or a provider without the method.
- (BOOL)isRequestOnlyTool:(NSString*)name context:(SPDFMacAIRequestContext*)context;
// Completion runs exactly once, on the main thread.
- (void)performTool:(NSString*)name arguments:(NSDictionary*)arguments context:(SPDFMacAIRequestContext*)context
         completion:(SPDFMacAIToolCompletion)completion;
- (void)beginRequestWithContext:(SPDFMacAIRequestContext*)context;
- (void)endRequestWithContext:(SPDFMacAIRequestContext*)context;
- (void)cancel;
- (NSArray<NSDictionary*>*)messagesForRequest:(NSArray<NSDictionary*>*)messages
                                      context:(SPDFMacAIRequestContext*)context;
- (NSArray<SPDFMacAIRequestChip*>*)requestChipsInComposerText:(nullable NSAttributedString*)text;
// Each provider's version in turn, in registration order.
- (NSDictionary*)chatForStorage:(NSDictionary*)chat;
- (NSArray<NSDictionary*>*)messagesForTitle:(NSArray<NSDictionary*>*)messages;
// The first provider's that has one.
- (nullable NSDictionary*)conversationContext;
@property(nonatomic, readonly) BOOL canUndo;
@property(nonatomic, readonly) BOOL canRedo;
- (BOOL)undoLastAction:(NSError**)error;
- (void)undoWithCompletion:(void (^)(NSDictionary*))completion;
- (void)redoWithCompletion:(void (^)(NSDictionary*))completion;

// SPDFMacAIChatSession's original initializer: one tools object performs every call by name, as before providers
// existed; the definitions are offered as given and nothing is refused here.
- (instancetype)initWithLegacyTools:(id<SPDFMacAIChatTools>)tools definitions:(NSArray<NSDictionary*>*)definitions;
@end

// An SPDFMacAIChatTools object (the reader's SPDFMacAITools) as a provider: fixed definitions, and the names of the
// tools among them that only read.
@interface SPDFMacAIChatToolsProvider : NSObject <SPDFMacAIToolProvider>
- (instancetype)initWithIdentifier:(NSString*)identifier tools:(id<SPDFMacAIChatTools>)tools
                       definitions:(NSArray<NSDictionary*>*)definitions
                     readOnlyTools:(NSSet<NSString*>*)readOnlyTools NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) id<SPDFMacAIChatTools> tools;
@end

// The reader's tools (SPDFMacAITools toolDefinitions) that only read. show_document is not one: it only navigates,
// but text the assistant just read could then steer what the person sees next.
NSSet<NSString*>* SPDFMacAIReaderReadOnlyToolNames(void);

// Calls every zero-argument instance method of `owner`'s class named aiToolProvider<Name>, in name order, and
// returns the providers they give (nil results are skipped).
NSArray<id<SPDFMacAIToolProvider>>* SPDFMacAIDiscoverToolProviders(id owner);

NS_ASSUME_NONNULL_END
