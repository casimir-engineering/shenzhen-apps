#pragma once
// read_attachment(id, path?, page?, count?): the assistant reads a file or folder the person gave this chat
// (SPDFMacAIChatGrants.h). Offered only while the request has attachment chips, and it finds ids only among them, so
// a chat never reads another chat's files. A folder lists what it holds (path then reads a file inside it, never
// outside: no "..", no link that leads out); a PDF gives its pages' text, an image is shown to the model, text comes
// as text, and anything else is described so the model can pass it to run_python. While the request has attachments,
// the system prompt names them (SPDFMacAIChatGrantsNote). Read only, so the chat's parts (run_subagents) may use it.
#import <Foundation/Foundation.h>

#import "SPDFMacAIToolProvider.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString* const SPDFMacAIAttachmentToolName; // "read_attachment"

@interface SPDFMacAIAttachmentToolProvider : NSObject <SPDFMacAIToolProvider>
@end

// What read_attachment returns for one request, computed off the main thread; `chips` are the request's. Exposed for
// the suite.
NSDictionary* SPDFMacAIAttachmentRead(NSDictionary* arguments, NSArray<SPDFMacAIRequestChip*>* chips);

NS_ASSUME_NONNULL_END
