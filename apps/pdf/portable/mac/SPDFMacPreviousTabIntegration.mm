#import "SPDFMacPreviousTabIntegration.h"

#import <objc/runtime.h>

static char kSPDFMacPreviousTabControllerKey;

@implementation ShenzhenMacDelegate (SPDFMacPreviousTabIntegration)

- (SPDFMacPreviousTabController*)previousTabControllerCreateIfNeeded:(BOOL)create {
    SPDFMacPreviousTabController* controller = objc_getAssociatedObject(self, &kSPDFMacPreviousTabControllerKey);
    if (!controller && create) {
        controller = [SPDFMacPreviousTabController new];
        objc_setAssociatedObject(self, &kSPDFMacPreviousTabControllerKey, controller,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return controller;
}

- (void)notePreviousTabTransitionFrom:(SPDFDocumentTab*)fromTab to:(SPDFDocumentTab*)toTab {
    if (!fromTab.path.length || !toTab.path.length ||
        [fromTab.path.stringByStandardizingPath isEqualToString:toTab.path.stringByStandardizingPath])
        return;
    [[self previousTabControllerCreateIfNeeded:YES] noteTransitionFromTab:fromTab toTab:toTab];
}

- (void)updatePreviousTabSnapshotForTab:(SPDFDocumentTab*)tab {
    [[self previousTabControllerCreateIfNeeded:NO] updateSnapshotForTab:tab];
}

- (BOOL)hasPreviousTabTargetFromCurrent:(SPDFDocumentTab*)currentTab {
    return [[self previousTabControllerCreateIfNeeded:NO] hasTargetFromCurrentTab:currentTab];
}

- (SPDFMacPreviousTabActivation*)takePreviousTabActivationFromCurrent:(SPDFDocumentTab*)currentTab
                                                              openTabs:(NSArray<SPDFDocumentTab*>*)openTabs {
    return [[self previousTabControllerCreateIfNeeded:NO] takeActivationFromCurrentTab:currentTab openTabs:openTabs];
}

@end
