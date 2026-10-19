#import <AppKit/AppKit.h>

#import "../SPDFMacMarkdownLanguagePicker.h"
#import "../markdown/SPDFMarkdownLanguage.h"

#include <assert.h>
#include <math.h>
#include <stdio.h>

static NSInteger IndexOfIdentifier(NSArray<SPDFMarkdownLanguage*>* languages, NSString* identifier) {
    for (NSUInteger i = 0; i < languages.count; i++)
        if ([languages[i].identifier isEqualToString:identifier]) return (NSInteger)i;
    return -1;
}

// Steps the keyboard selection to `identifier` and accepts with Return.
static void AcceptIdentifierViaKeyboard(SPDFMacMarkdownLanguagePickerController* picker,
                                        NSString* identifier) {
    assert([picker handleCommandSelector:@selector(moveToBeginningOfDocument:)]);
    NSInteger target = IndexOfIdentifier(picker.visibleLanguages, identifier);
    assert(target >= 0);
    for (NSInteger i = 0; i < target; i++) assert([picker handleCommandSelector:@selector(moveDown:)]);
    assert(picker.selectedIndex == target);
    assert([picker handleCommandSelector:@selector(insertNewline:)]);
}

int main(void) {
    @autoreleasepool {
        (void)NSApplication.sharedApplication;
        // The catalog is shared with the app; keep assertions relative to its
        // size so a growing language list does not invalidate this suite.
        NSUInteger catalogCount = SPDFMarkdownLanguageCatalog.sharedCatalog.languages.count;
        assert(catalogCount >= 5);

        SPDFMacMarkdownLanguagePickerController* picker = [SPDFMacMarkdownLanguagePickerController new];
        assert(picker.searchField != nil);
        assert(picker.tableView != nil);
        assert(picker.visibleLanguages.count == catalogCount); // empty query shows everything
        [picker updateQuery:@"py"];
        assert(picker.visibleLanguages.count >= 1);
        assert(picker.visibleLanguages.count < catalogCount);
        assert(IndexOfIdentifier(picker.visibleLanguages, @"python") >= 0);
        [picker updateQuery:@""];
        assert(picker.visibleLanguages.count == catalogCount);
        assert(picker.selectedIndex == 0); // query changes reset selection to the top
        assert([picker handleCommandSelector:@selector(moveDown:)]);
        assert(picker.selectedIndex == 1);
        assert([picker handleCommandSelector:@selector(moveUp:)]);
        assert(picker.selectedIndex == 0);
        assert([picker handleCommandSelector:@selector(moveToEndOfDocument:)]);
        assert(picker.selectedIndex == (NSInteger)catalogCount - 1);

        // Compact metrics: tight rows, subtle labels, no bezel, no focus ring.
        assert(picker.tableView.rowHeight >= 24.0 && picker.tableView.rowHeight <= 26.0);
        assert(picker.tableView.focusRingType == NSFocusRingTypeNone);
        assert(NSEqualSizes(picker.tableView.intercellSpacing, NSMakeSize(0, 0)));
        NSScrollView* scroll = picker.tableView.enclosingScrollView;
        assert(scroll != nil);
        assert(scroll.borderType == NSNoBorder);

        // The popover hugs its rows: monotonic below the cap, clamped at ~9
        // visible rows, never smaller than one row, 220-260 wide.
        NSSize one = [picker contentSizeForRowCount:1];
        NSSize two = [picker contentSizeForRowCount:2];
        NSSize nine = [picker contentSizeForRowCount:9];
        NSSize many = [picker contentSizeForRowCount:30];
        assert(one.width >= 220.0 && one.width <= 260.0);
        assert(one.width == two.width && two.width == many.width);
        CGFloat rowStep = two.height - one.height;
        assert(rowStep >= 24.0 && rowStep <= 26.0);
        assert(fabs(rowStep - picker.tableView.rowHeight) < 0.5);
        assert(nine.height == many.height); // capped: long lists scroll instead of growing
        assert(nine.height <= 300.0);
        NSSize zero = [picker contentSizeForRowCount:0];
        assert(zero.height == one.height); // empty result keeps one row of space
        // preferredContentSize tracks the filtered row count.
        [picker updateQuery:@"python"];
        NSSize filtered = [picker contentSizeForRowCount:picker.visibleLanguages.count];
        assert(NSEqualSizes(picker.preferredContentSize, filtered));
        assert(filtered.height < [picker contentSizeForRowCount:catalogCount].height);
        [picker updateQuery:@""];
        assert(NSEqualSizes(picker.preferredContentSize,
                            [picker contentSizeForRowCount:catalogCount]));

        // Auto Layout content: at the preferred size the search field and the
        // list never overlap, and both sit inside the content bounds.
        NSView* content = picker.view;
        [content setFrameSize:picker.preferredContentSize];
        [content layoutSubtreeIfNeeded];
        assert(!NSIntersectsRect(picker.searchField.frame, scroll.frame));
        assert(NSContainsRect(content.bounds, picker.searchField.frame));
        assert(NSContainsRect(content.bounds, scroll.frame));
        CGFloat gap;
        if (content.isFlipped)
            gap = NSMinY(scroll.frame) - NSMaxY(picker.searchField.frame);
        else
            gap = NSMinY(picker.searchField.frame) - NSMaxY(scroll.frame);
        assert(gap >= 4.0 && gap <= 8.0); // compact spacing between field and list

        // Rows are standard cell views: 13pt label, vertically centered,
        // 12pt horizontal padding, constrained (no manual/stale frames).
        id<NSTableViewDelegate> tableDelegate = picker.tableView.delegate;
        assert(tableDelegate != nil);
        for (NSUInteger row = 0; row < MIN(catalogCount, (NSUInteger)3); row++) {
            NSView* rowView = [tableDelegate tableView:picker.tableView
                                    viewForTableColumn:picker.tableView.tableColumns.firstObject
                                                   row:(NSInteger)row];
            assert([rowView isKindOfClass:NSTableCellView.class]);
            NSTableCellView* cell = (NSTableCellView*)rowView;
            NSTextField* label = cell.textField;
            assert(label != nil);
            assert(!label.translatesAutoresizingMaskIntoConstraints);
            assert(label.font.pointSize == 13.0);
            assert([label.stringValue
                isEqualToString:picker.visibleLanguages[row].displayName]);
            [cell setFrameSize:NSMakeSize(one.width, picker.tableView.rowHeight)];
            [cell layoutSubtreeIfNeeded];
            // Auto Layout positions the label's alignment rect, which is the
            // visual edge of the text.
            NSRect labelRect = [label alignmentRectForFrame:label.frame];
            assert(NSMinX(labelRect) == 12.0);
            assert(NSMaxX(labelRect) <= NSMaxX(cell.bounds) - 12.0 + 0.5);
            assert(NSContainsRect(cell.bounds, labelRect));
            CGFloat centerOffset = fabs(NSMidY(labelRect) - NSMidY(cell.bounds));
            assert(centerOffset <= 1.0);
        }

        // Present -> filter -> Return accepts with the filtered language. The
        // anchor view is windowless, so the popover machinery stays headless
        // while the armed completion is driven through the action methods.
        NSView* anchorView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 320, 240)];
        __block NSUInteger acceptCount = 0;
        __block NSString* chosen = nil;
        [picker presentFromView:anchorView
                     anchorRect:NSMakeRect(200, 20, 80, 20)
                     completion:^(SPDFMarkdownLanguage* language) {
                       acceptCount++;
                       chosen = language.identifier;
                     }];
        assert(picker.visibleLanguages.count == catalogCount); // presenting resets the query
        assert(picker.selectedIndex == 0);                     // ...and the selection
        // The configured popover opens instantly, both ways, and stays transient.
        assert(picker.popover != nil);
        assert(!picker.popover.animates);
        assert(picker.popover.behavior == NSPopoverBehaviorTransient);
        [picker updateQuery:@"swift"];
        assert(picker.visibleLanguages.count >= 1);
        AcceptIdentifierViaKeyboard(picker, @"swift");
        assert(acceptCount == 1);
        assert([chosen isEqualToString:@"swift"]);
        // A stale Return after the completion resolved must not re-fire it.
        assert([picker handleCommandSelector:@selector(insertNewline:)]);
        assert(acceptCount == 1);

        // Present -> Esc dismisses with nil, exactly once.
        __block NSUInteger dismissCount = 0;
        __block BOOL dismissedWithNil = NO;
        [picker presentFromView:anchorView
                     anchorRect:NSMakeRect(200, 20, 80, 20)
                     completion:^(SPDFMarkdownLanguage* language) {
                       dismissCount++;
                       dismissedWithNil = language == nil;
                     }];
        assert([picker handleCommandSelector:@selector(cancelOperation:)]);
        assert(dismissCount == 1);
        assert(dismissedWithNil);
        assert([picker handleCommandSelector:@selector(cancelOperation:)]);
        assert(dismissCount == 1);

        // Re-presenting while a completion is still pending resolves the old
        // presentation with nil before arming the new one.
        __block NSUInteger firstCount = 0;
        __block BOOL firstWasNil = NO;
        [picker presentFromView:anchorView
                     anchorRect:NSMakeRect(200, 20, 80, 20)
                     completion:^(SPDFMarkdownLanguage* language) {
                       firstCount++;
                       firstWasNil = language == nil;
                     }];
        __block NSString* second = nil;
        [picker presentFromView:anchorView
                     anchorRect:NSMakeRect(200, 20, 80, 20)
                     completion:^(SPDFMarkdownLanguage* language) {
                       second = language.identifier;
                     }];
        assert(firstCount == 1);
        assert(firstWasNil);
        [picker updateQuery:@"python"];
        AcceptIdentifierViaKeyboard(picker, @"python");
        assert([second isEqualToString:@"python"]);
        assert(firstCount == 1);
        puts("SPDFMacMarkdownLanguagePickerTests passed");
    }
    return 0;
}
