#import "SPDFMacMarkdownLanguagePicker.h"

#import "markdown/SPDFMarkdownLanguage.h"

// Compact command-menu metrics: a tight popover that hugs its rows.
static const CGFloat kSPDFLanguagePickerWidth = 240.0;
static const CGFloat kSPDFLanguagePickerRowHeight = 25.0;
static const NSUInteger kSPDFLanguagePickerMaxVisibleRows = 9;
static const CGFloat kSPDFLanguagePickerTopInset = 8.0;
static const CGFloat kSPDFLanguagePickerSearchInset = 8.0;
static const CGFloat kSPDFLanguagePickerSearchListGap = 6.0;
static const CGFloat kSPDFLanguagePickerBottomInset = 6.0;
static const CGFloat kSPDFLanguagePickerRowPadding = 12.0;
static const CGFloat kSPDFLanguagePickerLabelFontSize = 13.0;
static NSUserInterfaceItemIdentifier const kSPDFLanguagePickerCellIdentifier = @"language";

@interface SPDFMacMarkdownLanguagePickerController () <NSTableViewDataSource,
                                                       NSTableViewDelegate,
                                                       NSSearchFieldDelegate,
                                                       NSPopoverDelegate>
@end

@implementation SPDFMacMarkdownLanguagePickerController {
    SPDFMarkdownLanguagePickerModel* _model;
    NSSearchField* _searchField;
    NSTableView* _tableView;
    NSPopover* _popover;
    void (^_completion)(SPDFMarkdownLanguage*);
}

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;
    _model = [SPDFMarkdownLanguagePickerModel new];
    (void)self.view; // keep the keyboard/model machinery usable before any presentation
    return self;
}

- (void)loadView {
    NSView* content = [[NSView alloc] initWithFrame:NSZeroRect];
    _searchField = [[NSSearchField alloc] init];
    _searchField.placeholderString = @"Search languages";
    _searchField.delegate = self;
    _searchField.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:_searchField];

    NSScrollView* scroll = [[NSScrollView alloc] init];
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.borderType = NSNoBorder;
    scroll.drawsBackground = NO;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:scroll];
    _tableView = [[NSTableView alloc] init];
    _tableView.headerView = nil;
    _tableView.rowHeight = kSPDFLanguagePickerRowHeight;
    _tableView.intercellSpacing = NSMakeSize(0, 0);
    _tableView.focusRingType = NSFocusRingTypeNone;
    _tableView.backgroundColor = NSColor.clearColor;
    if (@available(macOS 11.0, *)) _tableView.style = NSTableViewStyleFullWidth;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.target = self;
    _tableView.action = @selector(tableClicked:);
    _tableView.doubleAction = @selector(acceptSelection:);
    NSTableColumn* column = [[NSTableColumn alloc] initWithIdentifier:kSPDFLanguagePickerCellIdentifier];
    column.resizingMask = NSTableColumnAutoresizingMask;
    [_tableView addTableColumn:column];
    scroll.documentView = _tableView;

    [NSLayoutConstraint activateConstraints:@[
        [_searchField.topAnchor constraintEqualToAnchor:content.topAnchor
                                               constant:kSPDFLanguagePickerTopInset],
        [_searchField.leadingAnchor constraintEqualToAnchor:content.leadingAnchor
                                                   constant:kSPDFLanguagePickerSearchInset],
        [_searchField.trailingAnchor constraintEqualToAnchor:content.trailingAnchor
                                                    constant:-kSPDFLanguagePickerSearchInset],
        [scroll.topAnchor constraintEqualToAnchor:_searchField.bottomAnchor
                                         constant:kSPDFLanguagePickerSearchListGap],
        [scroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:content.bottomAnchor
                                            constant:-kSPDFLanguagePickerBottomInset],
    ]];
    self.view = content;
    NSSize size = [self contentSizeForRowCount:_model.filteredLanguages.count];
    [content setFrameSize:size];
    self.preferredContentSize = size;
}

- (NSArray<SPDFMarkdownLanguage*>*)visibleLanguages { return _model.filteredLanguages; }
- (NSInteger)selectedIndex { return _model.selectedIndex; }
- (NSPopover*)popover { return _popover; }

- (NSSize)contentSizeForRowCount:(NSUInteger)rowCount {
    NSUInteger visibleRows = MIN(rowCount, kSPDFLanguagePickerMaxVisibleRows);
    if (visibleRows == 0) visibleRows = 1; // "no matches" keeps one row of air
    CGFloat searchHeight = ceil(_searchField.fittingSize.height);
    if (searchHeight <= 0) searchHeight = 22.0;
    CGFloat height = kSPDFLanguagePickerTopInset + searchHeight + kSPDFLanguagePickerSearchListGap
        + (CGFloat)visibleRows * kSPDFLanguagePickerRowHeight + kSPDFLanguagePickerBottomInset;
    return NSMakeSize(kSPDFLanguagePickerWidth, height);
}

- (void)updateContentSize {
    NSSize size = [self contentSizeForRowCount:_model.filteredLanguages.count];
    self.preferredContentSize = size;
    if (_popover) _popover.contentSize = size;
}

- (void)presentFromView:(NSView*)view
             anchorRect:(NSRect)anchorRect
             completion:(void (^)(SPDFMarkdownLanguage*))completion {
    if (!view || !completion) return;
    if (_completion) [self finishWithLanguage:nil]; // a pending presentation resolves before re-arming
    _completion = [completion copy];
    [self updateQuery:@""]; // full catalog, selection back on the first row
    if (!_popover) {
        _popover = [NSPopover new];
        _popover.behavior = NSPopoverBehaviorTransient;
        _popover.animates = NO; // instant open and close — no zoom-in animation
        _popover.delegate = self;
        _popover.contentViewController = self;
    }
    _popover.contentSize = self.preferredContentSize;
    // Without a window there is nothing to anchor to (headless tests); the
    // keyboard machinery still drives the armed completion.
    if (!view.window) return;
    [_popover showRelativeToRect:(NSIsEmptyRect(anchorRect) ? view.bounds : anchorRect)
                          ofView:view
                   preferredEdge:NSRectEdgeMaxY];
    [_searchField.window makeFirstResponder:_searchField];
}

- (void)finishWithLanguage:(SPDFMarkdownLanguage*)language {
    void (^completion)(SPDFMarkdownLanguage*) = _completion;
    _completion = nil; // popoverDidClose: re-enters finishWithLanguage: with nothing left to fire
    if (_popover.isShown) [_popover close];
    if (completion) completion(language);
}

// NSPopoverDelegate: clicking outside a transient popover (or Esc) closes it
// without going through cancel:, so a still-pending completion resolves to nil
// here — exactly once, because finishWithLanguage: clears it first.
- (void)popoverDidClose:(NSNotification*)notification {
    (void)notification;
    [self finishWithLanguage:nil];
    // Break the popover <-> contentViewController retain cycle between
    // presentations; presentFromView: rebuilds the popover on demand.
    _popover.contentViewController = nil;
    _popover = nil;
}

- (void)acceptSelection:(id)sender {
    (void)sender;
    SPDFMarkdownLanguage* language = _model.selectedLanguage;
    if (language) [self finishWithLanguage:language];
    else NSBeep();
}

- (void)cancel:(id)sender {
    (void)sender;
    [self finishWithLanguage:nil];
}

- (void)tableClicked:(id)sender {
    (void)sender;
    NSInteger row = _tableView.clickedRow;
    if (row < 0 || row >= (NSInteger)_model.filteredLanguages.count) return;
    _model.selectedIndex = row;
    [self acceptSelection:nil];
}

- (void)updateQuery:(NSString*)query {
    _model.query = query ?: @"";
    if (![_searchField.stringValue isEqualToString:_model.query]) _searchField.stringValue = _model.query;
    [_tableView reloadData];
    [self syncTableSelection];
    [self updateContentSize];
}

- (void)syncTableSelection {
    if (_model.selectedIndex >= 0) {
        [_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)_model.selectedIndex]
               byExtendingSelection:NO];
        [_tableView scrollRowToVisible:_model.selectedIndex];
    } else [_tableView deselectAll:nil];
}

- (BOOL)handleCommandSelector:(SEL)selector {
    if (selector == @selector(moveDown:)) [_model moveSelectionBy:1];
    else if (selector == @selector(moveUp:)) [_model moveSelectionBy:-1];
    else if (selector == @selector(pageDown:))
        [_model moveSelectionByPage:1 visibleRowCount:kSPDFLanguagePickerMaxVisibleRows];
    else if (selector == @selector(pageUp:))
        [_model moveSelectionByPage:-1 visibleRowCount:kSPDFLanguagePickerMaxVisibleRows];
    else if (selector == @selector(moveToBeginningOfDocument:)) [_model selectFirst];
    else if (selector == @selector(moveToEndOfDocument:)) [_model selectLast];
    else if (selector == @selector(insertNewline:) || selector == @selector(insertNewlineIgnoringFieldEditor:)) {
        [self acceptSelection:nil];
        return YES;
    } else if (selector == @selector(cancelOperation:)) {
        [self cancel:nil];
        return YES;
    } else return NO;
    [self syncTableSelection];
    return YES;
}

- (void)controlTextDidChange:(NSNotification*)notification {
    if (notification.object == _searchField) [self updateQuery:_searchField.stringValue];
}

- (BOOL)control:(NSControl*)control textView:(NSTextView*)textView doCommandBySelector:(SEL)selector {
    (void)textView;
    return control == _searchField && [self handleCommandSelector:selector];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView*)tableView {
    (void)tableView;
    return (NSInteger)_model.filteredLanguages.count;
}

- (NSView*)tableView:(NSTableView*)tableView viewForTableColumn:(NSTableColumn*)column row:(NSInteger)row {
    (void)column;
    NSTableCellView* cell = [tableView makeViewWithIdentifier:kSPDFLanguagePickerCellIdentifier owner:self];
    if (![cell isKindOfClass:NSTableCellView.class]) {
        cell = [[NSTableCellView alloc]
            initWithFrame:NSMakeRect(0, 0, kSPDFLanguagePickerWidth, kSPDFLanguagePickerRowHeight)];
        cell.identifier = kSPDFLanguagePickerCellIdentifier;
        NSTextField* label = [NSTextField labelWithString:@""];
        label.font = [NSFont systemFontOfSize:kSPDFLanguagePickerLabelFontSize];
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        label.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:label];
        cell.textField = label; // standard cell view: highlight recolors the label
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor
                                                constant:kSPDFLanguagePickerRowPadding],
            [label.trailingAnchor constraintLessThanOrEqualToAnchor:cell.trailingAnchor
                                                           constant:-kSPDFLanguagePickerRowPadding],
            [label.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }
    SPDFMarkdownLanguage* language = _model.filteredLanguages[(NSUInteger)row];
    cell.textField.stringValue = language.displayName;
    cell.toolTip = language.identifier;
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification*)notification {
    if (notification.object == _tableView && _tableView.selectedRow >= 0)
        _model.selectedIndex = _tableView.selectedRow;
}

@end
