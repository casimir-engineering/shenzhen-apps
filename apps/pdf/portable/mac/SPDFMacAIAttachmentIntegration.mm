// read_attachment in the reader's chat (SPDFMacAIAttachmentToolProvider.h), found by its aiToolProvider prefix when
// the chat is first used (SPDFMacAIToolProvider.h § 2). It holds no state: each request brings its own chips.
#import "SPDFMacDelegatePrivate.h"
#import "SPDFMacAIAttachmentToolProvider.h"

@implementation ShenzhenMacDelegate (SPDFMacAIAttachmentTools)

- (id<SPDFMacAIToolProvider>)aiToolProviderAttachments { return [SPDFMacAIAttachmentToolProvider new]; }

@end
