// Registers Friends with the AI chat's tool registry (portable/mac/SPDFMacAIToolProvider.h § 2): SPDFMacAIIntegration
// finds this method by its aiToolProvider prefix when the chat is first used. The provider shares the window's
// scope gate with the composer's `@` scoper (SPDFMacFriendsAssistantIntegration.mm), which opens each request's
// scope as the person sends.

#import "SPDFMacFriendsReaderState.h"
#import "SPDFMacFriendsToolProvider.h"

@implementation ShenzhenMacDelegate (SPDFMacFriendsToolProvider)

- (id<SPDFMacAIToolProvider>)aiToolProviderFriends {
    return [[SPDFMacFriendsToolProvider alloc] initWithGate:[self friendsGate]];
}

@end
