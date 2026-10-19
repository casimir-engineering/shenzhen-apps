#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Main-queue debounce used by the Markdown viewport. It is created on the
// first actual viewport update, so ordinary launches allocate and schedule
// nothing. Generation cancellation prevents stale tab/session writes.
@interface SPDFMacViewportCheckpoint : NSObject
- (instancetype)initWithDelay:(NSTimeInterval)delay;
- (void)scheduleAction:(dispatch_block_t)action;
- (void)cancel;
@property(nonatomic, readonly) BOOL hasPendingAction;
@end

@class ShenzhenMacDelegate, SPDFDocumentTab, SPDFMacMarkdownSession;
void spdf_schedule_markdown_checkpoint(SPDFMacViewportCheckpoint* checkpoint,
                                      ShenzhenMacDelegate* owner, SPDFDocumentTab* tab,
                                      SPDFMacMarkdownSession* session);
NS_ASSUME_NONNULL_END
