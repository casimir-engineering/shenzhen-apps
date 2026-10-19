#pragma once
#import "SPDFMacDelegatePrivate.h"

@interface ShenzhenMacDelegate (SPDFMacDocumentOpening)
// Documents the reader asked for (Finder, the Dock, Open..., Open Recent, links):
// each one's tab comes forward, selected and expanded in its own group, in the
// window that already shows it, which may be another window; otherwise it opens here.
- (void)showDocumentsAtPaths:(NSArray<NSString*>*)paths;
// The same for one document, at a one-based page when `page` is given, also when
// another window shows it.
- (void)showDocumentAtPath:(NSString*)path page:(NSNumber*)page;
// Installed after the first paint so another window can hand this one a document it shows.
- (void)listenForDocumentsOpenedInOtherWindows;
- (void)handleShowDocumentRequest:(NSDictionary*)userInfo;
- (void)handleShowDocumentConfirmation:(NSDictionary*)userInfo;
- (pid_t)otherWindowProcessShowingPath:(NSString*)path;
// Asks the owning window to show the document. When it does not answer within
// showDocumentHandOffTimeout, the document opens here instead.
- (BOOL)handOffDocumentAtPath:(NSString*)path page:(NSNumber*)page toProcess:(pid_t)pid;
- (NSTimeInterval)showDocumentHandOffTimeout;
// Delivery to the other process; YES when it was sent.
- (BOOL)sendShowDocumentRequest:(NSDictionary*)userInfo toProcess:(pid_t)pid;
- (void)sendShowDocumentConfirmation:(NSDictionary*)userInfo;
@end
