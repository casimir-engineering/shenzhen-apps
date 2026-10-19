#import <Foundation/Foundation.h>

#import "SPDFMacTabLifecycle.h"

#define EXPECT(condition)                                                                                         \
    do {                                                                                                          \
        if (!(condition)) {                                                                                       \
            NSLog(@"FAIL %s:%d: %s", __FILE__, __LINE__, #condition);                                            \
            return 1;                                                                                             \
        }                                                                                                         \
    } while (0)

@interface ViewedTabFixture : NSObject
@property NSTimeInterval lastViewedAt;
@end
@implementation ViewedTabFixture
@end

static int test_active_detach_restores_mru(void) {
    ViewedTabFixture* viewed=[ViewedTabFixture new];
    SPDFMacTabLifecycle* tracking=[SPDFMacTabLifecycle new];
    NSTimeInterval before=NSDate.timeIntervalSinceReferenceDate;
    [tracking recordActivationOfIdentifier:viewed];
    EXPECT(viewed.lastViewedAt>=before);

    NSObject* a = [NSObject new];
    NSObject* b = [NSObject new];
    NSObject* c = [NSObject new];
    SPDFMacTabLifecycle* lifecycle = [SPDFMacTabLifecycle new];
    [lifecycle recordActivationOfIdentifier:a];
    [lifecycle recordActivationOfIdentifier:b];
    [lifecycle recordActivationOfIdentifier:a];
    [lifecycle recordActivationOfIdentifier:c];

    id replacement = [lifecycle removeIdentifier:c
                           fromOrderedIdentifiers:@[ a, b, c ]
                           preferMostRecentActive:YES];
    EXPECT(replacement == a);

    replacement = [lifecycle removeIdentifier:a
                        fromOrderedIdentifiers:@[ a, b ]
                        preferMostRecentActive:YES];
    EXPECT(replacement == b);
    return 0;
}

static int test_detach_fallback_is_adjacent(void) {
    NSObject* a = [NSObject new];
    NSObject* b = [NSObject new];
    NSObject* c = [NSObject new];
    SPDFMacTabLifecycle* lifecycle = [SPDFMacTabLifecycle new];
    [lifecycle recordActivationOfIdentifier:b];

    id replacement = [lifecycle removeIdentifier:b
                           fromOrderedIdentifiers:@[ a, b, c ]
                           preferMostRecentActive:YES];
    EXPECT(replacement == c);

    [lifecycle reset];
    [lifecycle recordActivationOfIdentifier:c];
    replacement = [lifecycle removeIdentifier:c
                        fromOrderedIdentifiers:@[ a, b, c ]
                        preferMostRecentActive:YES];
    EXPECT(replacement == b);

    [lifecycle reset];
    [lifecycle recordActivationOfIdentifier:a];
    replacement = [lifecycle removeIdentifier:a
                        fromOrderedIdentifiers:@[ a ]
                        preferMostRecentActive:YES];
    EXPECT(replacement == nil);
    return 0;
}

static int test_close_prefers_adjacent_over_history(void) {
    NSObject* a = [NSObject new];
    NSObject* b = [NSObject new];
    NSObject* c = [NSObject new];
    SPDFMacTabLifecycle* lifecycle = [SPDFMacTabLifecycle new];
    [lifecycle recordActivationOfIdentifier:a];
    [lifecycle recordActivationOfIdentifier:b];
    [lifecycle recordActivationOfIdentifier:c];

    id replacement = [lifecycle removeIdentifier:c
                           fromOrderedIdentifiers:@[ a, b, c ]
                           preferMostRecentActive:NO];
    EXPECT(replacement == b);
    return 0;
}

static int test_inactive_removal_preserves_selection(void) {
    NSObject* a = [NSObject new];
    NSObject* b = [NSObject new];
    NSObject* c = [NSObject new];
    SPDFMacTabLifecycle* lifecycle = [SPDFMacTabLifecycle new];
    [lifecycle recordActivationOfIdentifier:b];
    [lifecycle recordActivationOfIdentifier:a];

    id replacement = [lifecycle removeIdentifier:c
                           fromOrderedIdentifiers:@[ a, b, c ]
                           preferMostRecentActive:YES];
    EXPECT(replacement == nil);

    replacement = [lifecycle removeIdentifier:a
                        fromOrderedIdentifiers:@[ a, b ]
                        preferMostRecentActive:YES];
    EXPECT(replacement == b);
    return 0;
}

static int test_identity_survives_reorder_and_equal_values(void) {
    NSMutableString* first = [@"same" mutableCopy];
    NSMutableString* second = [@"same" mutableCopy];
    NSObject* third = [NSObject new];
    SPDFMacTabLifecycle* lifecycle = [SPDFMacTabLifecycle new];
    [lifecycle recordActivationOfIdentifier:first];
    [lifecycle recordActivationOfIdentifier:second];
    [lifecycle recordActivationOfIdentifier:third];

    id replacement = [lifecycle removeIdentifier:third
                           fromOrderedIdentifiers:@[ third, first, second ]
                           preferMostRecentActive:YES];
    EXPECT(replacement == second);
    EXPECT(replacement != first);
    return 0;
}

static int test_stale_history_is_ignored(void) {
    NSObject* stale = [NSObject new];
    NSObject* a = [NSObject new];
    NSObject* b = [NSObject new];
    SPDFMacTabLifecycle* lifecycle = [SPDFMacTabLifecycle new];
    [lifecycle recordActivationOfIdentifier:stale];
    [lifecycle recordActivationOfIdentifier:b];

    id replacement = [lifecycle removeIdentifier:b
                           fromOrderedIdentifiers:@[ a, b ]
                           preferMostRecentActive:YES];
    EXPECT(replacement == a);
    return 0;
}

static int test_close_action_policy(void) {
    EXPECT(spdf_mac_tab_close_action_enabled(2, 1, NO));
    EXPECT(spdf_mac_tab_close_action_enabled(0, -1, YES));
    EXPECT(!spdf_mac_tab_close_action_enabled(2, -1, NO));
    EXPECT(!spdf_mac_tab_close_action_enabled(2, 2, NO));
    EXPECT(!spdf_mac_tab_close_action_enabled(0, 0, NO));
    return 0;
}

static int test_coordinator_source_contract(void) {
    NSString* testPath = @(__FILE__);
    NSString* sourcePath = [[testPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"../ShenzhenPDFMac.mm"];
    NSError* error = nil;
    NSString* source = [NSString stringWithContentsOfFile:sourcePath encoding:NSUTF8StringEncoding error:&error];
    EXPECT(source != nil);
    EXPECT([source containsString:@"if (action == @selector(closeDocument:))"]);
    EXPECT([source containsString:@"spdf_mac_tab_close_action_enabled"]);
    // Detaching moved to SPDFMacTabDetach.mm, which hands the tab's reading
    // position to the process it launches; the close-here half went with it.
    NSString* detachPath =
        [[testPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"../SPDFMacTabDetach.mm"];
    NSString* detach = [NSString stringWithContentsOfFile:detachPath encoding:NSUTF8StringEncoding error:nil];
    EXPECT(detach != nil);
    EXPECT([detach containsString:@"preferMostRecentActive:index == _selectedTabIndex"]);
    EXPECT([detach containsString:@"spdf_mac_detach_handoff_name"]);
    EXPECT([source containsString:@"recordActivationOfIdentifier:tab"]);
    // A Markdown tab has no spdf_document, so gating the file watcher on _doc
    // alone left Markdown unwatched: editing the file on disk never reloaded it,
    // while PDFs did. The watcher must accept an active Markdown session too.
    EXPECT([source containsString:@"if ((!_doc && !self.isMarkdownActive) || !path.length || tab.missingFile)"]);
    NSString* markdownPath = [[testPath stringByDeletingLastPathComponent]
        stringByAppendingPathComponent:@"../SPDFMacMarkdownIntegration.mm"];
    NSString* markdown = [NSString stringWithContentsOfFile:markdownPath encoding:NSUTF8StringEncoding error:&error];
    EXPECT(markdown != nil);
    // ...and it is armed only once the load has recorded the file's stat, which
    // is the baseline the change handler compares against.
    EXPECT([markdown containsString:@"[strongSelf recordFileAttributes:attributes forTab:tab];"]);
    EXPECT([markdown containsString:@"[strongSelf repointActiveFileWatcher];"]);
    return 0;
}

int main(void) {
    @autoreleasepool {
        if (test_active_detach_restores_mru()) return 1;
        if (test_detach_fallback_is_adjacent()) return 1;
        if (test_close_prefers_adjacent_over_history()) return 1;
        if (test_inactive_removal_preserves_selection()) return 1;
        if (test_identity_survives_reorder_and_equal_values()) return 1;
        if (test_stale_history_is_ignored()) return 1;
        if (test_close_action_policy()) return 1;
        if (test_coordinator_source_contract()) return 1;
        NSLog(@"SPDFMacTabLifecycleTests passed");
    }
    return 0;
}
