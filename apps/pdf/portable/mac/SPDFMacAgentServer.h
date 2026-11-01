#pragma once
// The reader's side of the szpdf channel (SPDFMacAgentChannel.h): a listening socket per process, started after the
// first paint, and the commands it answers. A launch that no tool ever talks to pays one socket and one idle dispatch
// source, after the first frame; nothing polls.
#import "SPDFMacDelegatePrivate.h"

// Starts listening once per process; later calls do nothing. Called after the first paint.
void SPDFMacAgentServerStart(void);

@interface ShenzhenMacDelegate (SPDFMacAgentServer)
// Called on the main queue with a checked request; `reply` takes the answer, once, on any queue.
+ (void)agentServerHandleRequest:(NSDictionary*)request reply:(void (^)(NSDictionary* answer))reply;
@end
