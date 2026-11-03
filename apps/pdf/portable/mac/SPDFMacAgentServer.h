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

// The commands' parts (SPDFMacAgentServerCommands.mm, SPDFMacAgentServerTabs.mm).
@interface ShenzhenMacDelegate (SPDFMacAgentServerParts)
// page, pageCount, heading, headingPath of the selected document.
- (NSDictionary*)agentWhereIs;
// The window and its tabs, for `szpdf state`.
- (NSDictionary*)agentWindowState;
- (void)agentReload:(NSDictionary*)request reply:(void (^)(NSDictionary* answer))reply;
- (id)agentReloadSelected;
- (void)agentFinishOpen:(NSDictionary*)request reply:(void (^)(NSDictionary* answer))reply deadline:(NSDate*)deadline
              navigated:(BOOL)navigated;
- (NSDictionary*)agentOpenResult:(NSString*)path error:(NSDictionary*)error;
+ (void)agentClose:(NSDictionary*)request readers:(NSArray<ShenzhenMacDelegate*>*)readers
             reply:(void (^)(NSDictionary* answer))reply;
+ (void)agentWatchComments:(NSDictionary*)request reply:(void (^)(NSDictionary* answer))reply;
@end
