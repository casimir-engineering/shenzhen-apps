#import "SPDFMacPreviousTab.h"

#import "SPDFMacModels.h"
#import "SPDFMacTabGroups.h"

@implementation SPDFMacPreviousTabActivation
@end

@interface SPDFMacPreviousTabController ()
@property(nonatomic, strong) SPDFDocumentTab* targetSnapshot;
@end

@implementation SPDFMacPreviousTabController

- (NSString*)targetPath { return self.targetSnapshot.path; }

static NSString* CanonicalPath(SPDFDocumentTab* tab) {
    return tab.path.length ? tab.path.stringByStandardizingPath : nil;
}

- (void)noteTransitionFromTab:(SPDFDocumentTab*)fromTab toTab:(SPDFDocumentTab*)toTab {
    NSString* fromPath = CanonicalPath(fromTab);
    NSString* toPath = CanonicalPath(toTab);
    if (!fromPath.length || !toPath.length || [fromPath isEqualToString:toPath]) return;
    self.targetSnapshot = spdf_copy_document_tab(fromTab);
}

- (void)updateSnapshotForTab:(SPDFDocumentTab*)tab {
    NSString* path = CanonicalPath(tab);
    if (path.length && [path isEqualToString:CanonicalPath(self.targetSnapshot)])
        self.targetSnapshot = spdf_copy_document_tab(tab);
}

- (BOOL)hasTargetFromCurrentTab:(SPDFDocumentTab*)currentTab {
    NSString* target = CanonicalPath(self.targetSnapshot);
    return target.length && ![target isEqualToString:CanonicalPath(currentTab)];
}

- (SPDFMacPreviousTabActivation*)takeActivationFromCurrentTab:(SPDFDocumentTab*)currentTab
                                                      openTabs:(NSArray<SPDFDocumentTab*>*)openTabs {
    if (![self hasTargetFromCurrentTab:currentTab] || !CanonicalPath(currentTab).length) return nil;
    SPDFDocumentTab* destination = spdf_copy_document_tab(self.targetSnapshot);
    self.targetSnapshot = spdf_copy_document_tab(currentTab);  // the next press comes back here

    SPDFMacPreviousTabActivation* result = [SPDFMacPreviousTabActivation new];
    result.existingIndex = -1;
    result.insertionIndex = (NSInteger)openTabs.count;
    NSString* destinationPath = CanonicalPath(destination);
    for (NSInteger i = 0; i < (NSInteger)openTabs.count; ++i) {
        SPDFDocumentTab* candidate = openTabs[(NSUInteger)i];
        if ([CanonicalPath(candidate) isEqualToString:destinationPath]) {
            result.existingIndex = i;
            return result;
        }
        if (destination.group.identifier.length &&
            [candidate.group.identifier isEqualToString:destination.group.identifier])
            result.insertionIndex = i + 1;
    }
    result.tabToReopen = destination;
    return result;
}

@end
