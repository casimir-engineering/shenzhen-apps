#pragma once

#import "SPDFMacDelegatePrivate.h"
#import "SPDFMacPreviousTab.h"

// Associated state keeps this feature off the delegate's capped ivar list and
// allocates nothing until the first real tab transition.
@interface ShenzhenMacDelegate (SPDFMacPreviousTabIntegration)
- (void)notePreviousTabTransitionFrom:(SPDFDocumentTab*)fromTab to:(SPDFDocumentTab*)toTab;
- (void)updatePreviousTabSnapshotForTab:(SPDFDocumentTab*)tab;
- (BOOL)hasPreviousTabTargetFromCurrent:(SPDFDocumentTab*)currentTab;
- (SPDFMacPreviousTabActivation*)takePreviousTabActivationFromCurrent:(SPDFDocumentTab*)currentTab
                                                              openTabs:(NSArray<SPDFDocumentTab*>*)openTabs;
@end
