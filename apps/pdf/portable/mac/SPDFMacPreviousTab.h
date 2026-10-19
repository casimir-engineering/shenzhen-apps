#pragma once

#import <Foundation/Foundation.h>

@class SPDFDocumentTab;

NS_ASSUME_NONNULL_BEGIN

@interface SPDFMacPreviousTabActivation : NSObject
@property(nonatomic) NSInteger existingIndex;
@property(nonatomic) NSInteger insertionIndex;
@property(nonatomic, strong, nullable) SPDFDocumentTab* tabToReopen;
@end

// Two-document return model. Each activation swaps the saved target with the
// tab being left, so two presses return to the starting document. Snapshots
// retain view state and group identity when the target has since been closed.
@interface SPDFMacPreviousTabController : NSObject
@property(nonatomic, readonly, nullable) NSString* targetPath;
- (void)noteTransitionFromTab:(nullable SPDFDocumentTab*)fromTab
                        toTab:(nullable SPDFDocumentTab*)toTab;
- (void)updateSnapshotForTab:(nullable SPDFDocumentTab*)tab;
- (BOOL)hasTargetFromCurrentTab:(nullable SPDFDocumentTab*)currentTab;
- (nullable SPDFMacPreviousTabActivation*)takeActivationFromCurrentTab:(nullable SPDFDocumentTab*)currentTab
                                                               openTabs:(NSArray<SPDFDocumentTab*>*)openTabs;
@end

NS_ASSUME_NONNULL_END
