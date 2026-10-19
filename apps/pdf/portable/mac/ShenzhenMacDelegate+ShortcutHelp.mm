#import "SPDFMacShortcutHelpStyle.h"
#import "SPDFMacDelegatePrivate.h"

@implementation ShenzhenMacDelegate (ShortcutHelp)

- (NSArray<NSDictionary*>*)shortcutHelpCatalog { return SPDFShortcutHelpCatalog(); }

- (void)refreshShortcutHelpRows {
    [_shortcutHelpRows setArray:SPDFShortcutHelpRows(_shortcutHelpSearchField.stringValue ?: @"")];
    [_shortcutHelpTable reloadData];
    [_shortcutHelpTable scrollPoint:NSZeroPoint];
}

- (NSView*)shortcutKeycapsViewForKeys:(NSArray<NSString*>*)keys {
    return SPDFShortcutHelpKeycaps(keys);
}

- (void)showShortcutHelp:(id)sender {
    (void)sender;
    if (_shortcutHelpPanel && _shortcutHelpPanel.visible) {
        [_shortcutHelpPanel makeKeyAndOrderFront:nil];
        return;
    }

    NSRect frame = NSMakeRect(0, 0, 620, 620);
    if (!_shortcutHelpPanel) {
        _shortcutHelpPanel = [[SPDFShortcutHelpPanel alloc] initWithContentRect:frame
                                                                      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                                        backing:NSBackingStoreBuffered
                                                                          defer:NO];
        _shortcutHelpPanel.releasedWhenClosed = NO;
        _shortcutHelpPanel.floatingPanel = YES;
        _shortcutHelpPanel.hidesOnDeactivate = NO;
        _shortcutHelpPanel.hasShadow = YES;
        _shortcutHelpPanel.title = @"Keyboard Shortcuts";
        _shortcutHelpPanel.backgroundColor = NSColor.windowBackgroundColor;

        NSView* content = SPDFShortcutHelpSurface(frame);
        _shortcutHelpPanel.contentView = content;
        NSTextField* title = [NSTextField labelWithString:@"Find a shortcut by action or key."];
        title.translatesAutoresizingMaskIntoConstraints = NO;
        title.font = [NSFont systemFontOfSize:13];
        title.textColor = NSColor.secondaryLabelColor;
        [content addSubview:title];

        _shortcutHelpSearchField = [[NSSearchField alloc] init];
        _shortcutHelpSearchField.translatesAutoresizingMaskIntoConstraints = NO;
        _shortcutHelpSearchField.placeholderString = @"Search shortcuts";
        _shortcutHelpSearchField.accessibilityLabel = @"Search keyboard shortcuts";
        _shortcutHelpSearchField.font = [NSFont systemFontOfSize:13];
        _shortcutHelpSearchField.delegate = self;
        [content addSubview:_shortcutHelpSearchField];

        NSScrollView* scrollView = [[NSScrollView alloc] init];
        scrollView.translatesAutoresizingMaskIntoConstraints = NO;
        scrollView.hasVerticalScroller = YES;
        scrollView.autohidesScrollers = YES;
        scrollView.borderType = NSNoBorder;
        scrollView.drawsBackground = NO;
        [content addSubview:scrollView];

        _shortcutHelpTable = [[NSTableView alloc] init];
        _shortcutHelpTable.headerView = nil;
        _shortcutHelpTable.intercellSpacing = NSMakeSize(0, 0);
        _shortcutHelpTable.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
        _shortcutHelpTable.backgroundColor = NSColor.clearColor;
        _shortcutHelpTable.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
        _shortcutHelpTable.dataSource = self;
        _shortcutHelpTable.delegate = self;
        NSTableColumn* column = [[NSTableColumn alloc] initWithIdentifier:@"Shortcut"];
        column.resizingMask = NSTableColumnAutoresizingMask;
        [_shortcutHelpTable addTableColumn:column];
        scrollView.documentView = _shortcutHelpTable;

        _shortcutHelpDisableButton = [NSButton buttonWithTitle:@"Don’t show at launch"
                                                        target:self
                                                        action:@selector(disableLaunchShortcutHelp:)];
        _shortcutHelpDisableButton.translatesAutoresizingMaskIntoConstraints = NO;
        _shortcutHelpDisableButton.bezelStyle = NSBezelStyleRounded;
        [content addSubview:_shortcutHelpDisableButton];

        NSTextField* hint = [NSTextField labelWithString:@"⌘ Command    ⌥ Option    ⇧ Shift    ↩ Return"];
        hint.translatesAutoresizingMaskIntoConstraints = NO;
        hint.font = [NSFont systemFontOfSize:11 weight:NSFontWeightRegular];
        hint.textColor = NSColor.secondaryLabelColor;
        [content addSubview:hint];

        [NSLayoutConstraint activateConstraints:@[
            [title.topAnchor constraintEqualToAnchor:content.topAnchor constant:16],
            [title.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
            [_shortcutHelpSearchField.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:12],
            [_shortcutHelpSearchField.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
            [_shortcutHelpSearchField.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
            [_shortcutHelpSearchField.heightAnchor constraintEqualToConstant:28],
            [scrollView.topAnchor constraintEqualToAnchor:_shortcutHelpSearchField.bottomAnchor constant:12],
            [scrollView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:8],
            [scrollView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-8],
            [scrollView.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-48],
            [hint.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
            [hint.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-18],
            [_shortcutHelpDisableButton.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
            [_shortcutHelpDisableButton.centerYAnchor constraintEqualToAnchor:hint.centerYAnchor]
        ]];
    }

    _shortcutHelpDisableButton.hidden = !_showShortcutHelpOnLaunch;
    [self refreshShortcutHelpRows];
    [_shortcutHelpPanel center];
    [_shortcutHelpPanel makeKeyAndOrderFront:nil];
    [_shortcutHelpPanel makeFirstResponder:_shortcutHelpSearchField];
}

- (void)closeShortcutHelp:(id)sender {
    (void)sender;
    [_shortcutHelpPanel orderOut:nil];
}

- (void)disableLaunchShortcutHelp:(id)sender {
    (void)sender;
    _showShortcutHelpOnLaunch = NO;
    _shortcutHelpDisableButton.hidden = YES;
    [self savePersistentState];
    [_shortcutHelpPanel orderOut:nil];
}

@end
