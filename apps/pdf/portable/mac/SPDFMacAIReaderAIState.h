#pragma once
// The reader's AI chat, shared by SPDFMacAIIntegration.mm and SPDFMacAIChatBackground.mm. Nothing else imports this.
#import "SPDFMacAIIntegration.h"
@class SPDFMacAIChatSession, SPDFMacAIChatStore, SPDFMacAITools, SPDFMacAIToolRegistry, SPDFMacAIChatView,
    SPDFMacAIChatDock, SPDFMacAIChatHistoryView, SPDFMacAITransport;
@interface SPDFReaderAIState : NSObject
// The chat shown in the panel.
@property SPDFMacAIChatSession* session;
// A chat whose request kept running when another chat was shown (SPDFMacAIChatBackground.mm). The reader runs one
// request at a time, so there is at most one; showing that chat again shows it as it is now.
@property SPDFMacAIChatSession* background;
@property SPDFMacAIChatStore* store;
@property SPDFMacAITools* tools;
@property SPDFMacAIToolRegistry* registry;
@property SPDFMacAIChatView* view;
@property SPDFMacAIChatDock* dock;
@property SPDFMacAIChatHistoryView* historyView;
@property NSUInteger searchGeneration;
@property NSUInteger widthSaveGeneration;
@property NSMutableDictionary* drafts;
@property BOOL history;
@property NSString* submissionIssue;
@property BOOL setupRequired;
@property NSDictionary* pendingEdit; // An edit waiting for the user to authorize the saved key.
// The composer says a request is still running in another chat; it goes once that request ends.
@property BOOL waitingNotice;
@end
@interface ShenzhenMacDelegate (SPDFMacAIReaderAIState)
- (SPDFReaderAIState*)readerAIHistoryState;
- (SPDFReaderAIState*)readerAIState;
- (SPDFMacAITransport*)aiChatTransport;
@end
