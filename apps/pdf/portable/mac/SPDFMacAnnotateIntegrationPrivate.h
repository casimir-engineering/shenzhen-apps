#pragma once
// What SPDFMacAnnotateIntegration.mm and SPDFMacAnnotateIntegrationFiles.mm share, and the reader methods they call
// (implemented by the coordinator and its other categories).
#import "SPDFMacAnnotateIntegration.h"
#import "SPDFMacCollectionIntegration.h"
#import "SPDFMacSupport.h"

@class SPDFMacFillController;

@interface ShenzhenMacDelegate (SPDFMacAnnotateReader)
- (SPDFMacFillController*)fillController;
- (SPDFMacFillController*)existingFillController;
- (void)showError:(NSString*)message detail:(NSString*)detail;
- (NSInteger)indexOfTabForPath:(NSString*)path;
- (void)updateTabStrip;
- (void)rememberActiveTabState;
- (void)saveDocumentStateForTab:(SPDFDocumentTab*)tab;
- (void)refreshActiveTabCachedFileAttributesAfterSelfSave;
- (void)closeTabAtIndex:(NSInteger)index preferMostRecentActive:(BOOL)preferMostRecentActive;
- (NSPoint)visibleCenterWindowPoint;
- (void)fitPage:(id)sender;
- (void)saveDocumentAs:(id)sender;
@end

@interface ShenzhenMacDelegate (SPDFMacAnnotateShared) <SPDFMacAnnotateSessionHost>
- (SPDFMacFillController*)annotateController;
- (BOOL)annotateTurnOnActiveTab;
// Save / Save As with the Save panel (PNG chosen for a canvas or a picture that can't be written); saved NO when
// cancelled or failed.
- (void)annotateAskWhereToSaveSession:(SPDFMacAnnotateSession*)session completion:(void (^)(BOOL saved))completion;
@end
