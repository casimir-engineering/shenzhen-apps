// Registers run_subagents with the AI chat's tool registry (SPDFMacAIToolProvider.h § 2): SPDFMacAIIntegration finds
// this method by its aiToolProvider prefix when the chat is first used, never at launch. Each window's chat gets its
// own provider, so Stop in one window never stops another window's tasks.
#import "SPDFMacDelegatePrivate.h"
#import "SPDFMacAISubagents.h"

@interface ShenzhenMacDelegate (SPDFMacAISubagents)
- (id<SPDFMacAIToolProvider>)aiToolProviderSubagents;
@end

@implementation ShenzhenMacDelegate (SPDFMacAISubagents)

- (id<SPDFMacAIToolProvider>)aiToolProviderSubagents { return [SPDFMacAISubagentsProvider new]; }

@end
