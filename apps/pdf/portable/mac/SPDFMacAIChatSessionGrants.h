#pragma once
// The files and folders the person gave this chat (SPDFMacAIChatGrants.h), kept in the chat itself under "grants":
// saved with it, back when it is reopened, gone with it. Only this session's requests carry them, as attachment chips
// (-grantChips), and a child session (a part, run_subagents) gets them through its parent's request, never its own.
#import "SPDFMacAIChatSession.h"

@class SPDFMacAIRequestChip;

NS_ASSUME_NONNULL_BEGIN

@interface SPDFMacAIChatSession (Grants)
// The grants, oldest first.
@property(nonatomic, readonly) NSArray<NSDictionary*>* grants;
// Adds a grant for each item not given already (the same file or folder twice is one grant). Returns what could not
// be given, one line each for the person ("Pictures: This folder holds…"); empty when all were.
- (NSArray<NSString*>*)addGrantsForURLs:(NSArray<NSURL*>*)URLs;
// Ends a grant: later requests of this chat no longer carry it.
- (void)removeGrantWithIdentifier:(NSString*)identifier;
// The grants as chips for a request of this chat.
- (NSArray<SPDFMacAIRequestChip*>*)grantChips;
@end

NS_ASSUME_NONNULL_END
