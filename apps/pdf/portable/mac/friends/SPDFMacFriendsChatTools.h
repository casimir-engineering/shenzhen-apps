// The AI tool layer's Friends boundary: what wraps ShenzhenPDF's chat tools and transport for one chat session.
//
// SPDFMacAIChatSession is built with fixed tool definitions and one tools object. These two wrappers add Friends
// to it per request without changing it: the transport appends the Friends tool definitions only while the gate's
// current request carries a scope, and sends earlier Friends excerpts only when that scope covers them
// (SPDFMacFriendsChatHistory.h); the tools object routes Friends calls to the gate, keeps Friends excerpts out of the
// chat file, and keeps answers built from them out of the chat's suggested title. While a request has read Friends
// messages, or its context still holds some, the tools object refuses every tool that could change something
// (anything outside SPDFMacFriendsReadOnlyToolNames()), so instructions hidden in a friend's message cannot act
// through the assistant, in that request or a later one.

#import <Foundation/Foundation.h>
#import "SPDFMacAIChatSession.h"
#import "SPDFMacAITransport.h"
#import "SPDFMacFriendsChatScope.h"

NS_ASSUME_NONNULL_BEGIN

// ShenzhenPDF tools that only read (SPDFMacAITools toolDefinitions); everything else is refused while a request
// may only read (SPDFMacFriendsChatScopeGate requestIsReadOnly).
NSSet<NSString*>* SPDFMacFriendsReadOnlyToolNames(void);

@interface SPDFMacFriendsScopedChatTools : NSObject <SPDFMacAIChatTools>
- (instancetype)initWithTools:(id<SPDFMacAIChatTools>)tools
                         gate:(SPDFMacFriendsChatScopeGate*)gate NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) id<SPDFMacAIChatTools> tools;
@property(nonatomic, readonly) SPDFMacFriendsChatScopeGate* gate;
@end

// A transport for the chat session: forwards every request to `transport`, adding the gate's definitions to
// requests that offer tools (requests sent without tools, the final wrap-up turn and chat titles, stay without), and
// replacing the Friends excerpts the current scope does not cover.
@interface SPDFMacFriendsScopedTransport : SPDFMacAITransport
- (instancetype)initWithTransport:(SPDFMacAITransport*)transport gate:(SPDFMacFriendsChatScopeGate*)gate;
@end

NS_ASSUME_NONNULL_END
