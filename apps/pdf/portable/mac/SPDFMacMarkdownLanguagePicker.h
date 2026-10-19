#pragma once

#import <AppKit/AppKit.h>

@class SPDFMarkdownLanguage;

NS_ASSUME_NONNULL_BEGIN

// Searchable code-language picker presented as a transient popover anchored to
// the code box's language control (GitHub command-menu feel): typing filters,
// Return or a click accepts, Esc or clicking outside dismisses with nil.
@interface SPDFMacMarkdownLanguagePickerController : NSViewController
@property(nonatomic, readonly) NSSearchField* searchField;
@property(nonatomic, readonly) NSTableView* tableView;
@property(nonatomic, readonly, copy) NSArray<SPDFMarkdownLanguage*>* visibleLanguages;
@property(nonatomic, readonly) NSInteger selectedIndex;

// The popover the picker presents in. Configured (transient, no open/close
// animation) on first present; nil until then and again after a shown popover
// closes. Exposed so hosts and tests can verify presentation settings.
@property(nonatomic, readonly, nullable) NSPopover* popover;

// anchorRect is in view's coordinate space. The completion fires exactly once
// per presentation: with the accepted language, or with nil on dismissal.
- (void)presentFromView:(NSView*)view
             anchorRect:(NSRect)anchorRect
             completion:(void (^)(SPDFMarkdownLanguage* _Nullable language))completion;
- (BOOL)handleCommandSelector:(SEL)selector;
- (void)updateQuery:(NSString*)query;

// Popover content size that exactly fits the search field plus
// min(rowCount, max visible rows) rows — short filtered lists shrink the
// popover instead of leaving empty space (a zero-row result keeps one row of
// space so the popover never collapses to just the search field).
- (NSSize)contentSizeForRowCount:(NSUInteger)rowCount;
@end

NS_ASSUME_NONNULL_END
