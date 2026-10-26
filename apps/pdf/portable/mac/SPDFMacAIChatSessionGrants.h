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
// Files the assistant saved in Downloads from this chat: grants too ("saved": true, ids "attachment:saved-…"), so this
// chat, and no other, may read them back, while the rest of Downloads stays unreadable. Not shown as chips. Returns the
// id, or nil when the file is gone. Main thread.
- (nullable NSString*)addSavedFileAtPath:(NSString*)path;
// The saved files as chips, read now: a file saved earlier in the running request is readable at once.
- (NSArray<SPDFMacAIRequestChip*>*)savedFileChips;
@end

@class SPDFMacAIRequestContext;
// What a request may read as attachments: its own chips, and the files its chat saved since it started. A part
// (run_subagents) has its parent's chips only.
NSArray<SPDFMacAIRequestChip*>* SPDFMacAIRequestReadableAttachments(SPDFMacAIRequestContext* context);
// YES for a saved file's id (attachment:saved-…).
BOOL SPDFMacAIChatGrantIsSaved(NSString* _Nullable identifier);

NS_ASSUME_NONNULL_END
