#import <AppKit/AppKit.h>

#import "SPDFMacModels.h"
#import "SPDFMacPreviousTab.h"
#import "SPDFMacTabGroups.h"

static int failures;
static void Expect(NSString* label, BOOL condition) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", label.UTF8String); ++failures; }
}
static SPDFDocumentTab* Tab(NSString* path, NSInteger page, SPDFTabGroup* group) {
    SPDFDocumentTab* tab = [SPDFDocumentTab new];
    tab.path = path;
    tab.title = path.lastPathComponent;
    tab.pageIndex = page;
    tab.zoom = 1.25;
    tab.scrollOrigin = NSMakePoint(8, page * 100);
    tab.hasScrollOrigin = YES;
    tab.group = group;
    return tab;
}

int main(void) {
    @autoreleasepool {
        SPDFTabGroup* research = [SPDFTabGroup groupWithColor:@"Blue"];
        research.name = @"Research";
        SPDFDocumentTab* a = Tab(@"/tmp/a.pdf", 2, nil);
        SPDFDocumentTab* b = Tab(@"/tmp/b.md", 7, research);
        SPDFDocumentTab* c = Tab(@"/tmp/c.pdf", 11, research);
        SPDFMacPreviousTabController* controller = [SPDFMacPreviousTabController new];
        Expect(@"fresh controller performs no work", ![controller hasTargetFromCurrentTab:a]);

        [controller noteTransitionFromTab:a toTab:b];
        SPDFMacPreviousTabActivation* back = [controller takeActivationFromCurrentTab:b openTabs:@[ a, b, c ]];
        Expect(@"first return targets the prior open tab", back.existingIndex == 0 && !back.tabToReopen);
        SPDFMacPreviousTabActivation* forward = [controller takeActivationFromCurrentTab:a openTabs:@[ a, b, c ]];
        Expect(@"second return toggles to the tab just left", forward.existingIndex == 1 && !forward.tabToReopen);

        // The target closes after its viewport changes. Updating its retained
        // snapshot must reopen that exact state inside its original group.
        [controller noteTransitionFromTab:b toTab:a];
        b.pageIndex = 19;
        b.scrollOrigin = NSMakePoint(31, 1900);
        [controller updateSnapshotForTab:b];
        SPDFMacPreviousTabActivation* reopen = [controller takeActivationFromCurrentTab:a openTabs:@[ a, c ]];
        Expect(@"closed target reopens instead of disappearing", reopen.existingIndex == -1 && reopen.tabToReopen);
        Expect(@"reopened target preserves reading state", reopen.tabToReopen.pageIndex == 19 &&
                   NSEqualPoints(reopen.tabToReopen.scrollOrigin, NSMakePoint(31, 1900)));
        Expect(@"reopened target preserves group and appends to its members",
               [reopen.tabToReopen.group.identifier isEqualToString:research.identifier] && reopen.insertionIndex == 2);
        SPDFMacPreviousTabActivation* toggle =
            [controller takeActivationFromCurrentTab:reopen.tabToReopen openTabs:@[ a, c, reopen.tabToReopen ]];
        Expect(@"reopen also leaves a two-press return target", toggle.existingIndex == 0);

        // Closing the active tab is itself a transition. The coordinator notes
        // it before removal, so Previous Active Tab can restore what was just
        // closed rather than returning to an older unrelated target.
        SPDFMacPreviousTabController* closedActive = [SPDFMacPreviousTabController new];
        [closedActive noteTransitionFromTab:b toTab:c];
        SPDFMacPreviousTabActivation* restoreClosed =
            [closedActive takeActivationFromCurrentTab:c openTabs:@[ a, c ]];
        Expect(@"closing active tab leaves that closed tab as previous target",
               restoreClosed.existingIndex == -1 && [restoreClosed.tabToReopen.path isEqual:b.path]);
        SPDFMacPreviousTabActivation* returnToReplacement =
            [closedActive takeActivationFromCurrentTab:restoreClosed.tabToReopen
                                              openTabs:@[ a, c, restoreClosed.tabToReopen ]];
        Expect(@"closed-active restoration still toggles back to replacement", returnToReplacement.existingIndex == 1);
    }
    if (!failures) puts("SPDFMacPreviousTabTests passed");
    return failures ? 1 : 0;
}
