#pragma once
#import "SPDFMacDelegatePrivate.h"

// The reader's side of SPDFMacDocumentActivity.h: which tab the person is looking at, and when documents open.
@interface ShenzhenMacDelegate (SPDFMacDocumentActivity)
// After the first paint (listenForDocumentsOpenedInOtherWindows): observers, the clock and the store's writes. Before
// it, the two hooks below only note opens in memory.
- (void)activityStartTracking;
// loadSelectedTab: a tab's document loaded. The first load of a tab object in this process is an open (a new tab, a
// reopened one, or a restored one the person switched to); every call may change what is in front.
- (void)activityTabDidLoad:(SPDFDocumentTab*)tab;
// openPaths: documents the person opened, including one whose tab was already open.
- (void)activityDidOpenPaths:(NSArray<NSString*>*)paths;
// Anything that may change the tab in front.
- (void)activityViewMayHaveChanged;
// rememberClosedDocumentPath: a tab is closing; what is in front is known once it has gone.
- (void)activityDocumentWillClose;
// list_workspace with each document's last_opened and last_viewed (SPDFMacAIToolsReader), on the main queue.
- (void)aiWorkspaceContextWithArguments:(NSDictionary*)arguments completion:(void (^)(NSDictionary*))completion;
@end
