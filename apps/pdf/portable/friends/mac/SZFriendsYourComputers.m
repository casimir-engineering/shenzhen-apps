// SZFriendsYourComputersView: the profile's "Your computers" (PROTOCOL.md § Devices, type.device_row).

#import "mac/SZFriendsDevices.h"

// The longest prefix of `text` that fits `maxBytes` of UTF-8 without splitting a character.
static NSString *SZFPrefixFittingBytes(NSString *text, NSUInteger maxBytes) {
    if ([text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= maxBytes) return text;
    __block NSUInteger bytes = 0, end = 0;
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *character, NSRange range, NSRange enclosing, BOOL *stop) {
                              (void)enclosing;
                              NSUInteger size = [character lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
                              if (bytes + size > maxBytes) {
                                  *stop = YES;
                                  return;
                              }
                              bytes += size;
                              end = NSMaxRange(range);
                          }];
    return [text substringToIndex:end];
}

@interface SZFriendsYourComputersView () <NSTextFieldDelegate>
@end

@implementation SZFriendsYourComputersView {
    SZFriendsContext *_context;
    NSDictionary *_devices;
    NSDictionary *_rename; // this computer's row's rename object
    NSString *_thisName;
    NSTextField *_title;
    NSTextField *_addTitle; // "Add a computer or phone"
    NSTextField *_addSteps; // its steps, numbered, one per line
    NSMutableArray<NSTextField *> *_names;
    NSMutableArray<NSTextField *> *_details;
    NSMutableArray<NSView *> *_dots;
    NSMutableArray<SZFriendsActionButton *> *_removes;
}

- (instancetype)initWithContext:(SZFriendsContext *)context {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 368, 10)])) return nil;
    _context = context;
    SZFriendsAppearance *appearance = context.appearance;
    __weak SZFriendsYourComputersView *weakSelf = self;
    _title = SZFriendsLabel(@"", SZFriendsSemibold(appearance.bodyFont), appearance.primaryTextColor);
    _addTitle = SZFriendsLabel(@"", SZFriendsSemibold(appearance.secondaryFont), appearance.primaryTextColor);
    _addSteps = SZFriendsLabel(@"", appearance.secondaryFont, appearance.secondaryTextColor);
    _addSteps.selectable = YES; // the ID in it can be copied from here too
    _renameButton = [SZFriendsButton buttonWithTitle:@"" style:SZFriendsButtonStyleLink appearance:appearance];
    _renameButton.onPress = ^(SZFriendsButton *button) {
        (void)button;
        [weakSelf beginRenaming];
    };
    _renameField = [NSTextField textFieldWithString:@""];
    _renameField.bezelStyle = NSTextFieldRoundedBezel;
    _renameField.font = appearance.bodyFont;
    _renameField.delegate = self;
    _saveButton = [SZFriendsButton buttonWithTitle:@"" style:SZFriendsButtonStylePrimary appearance:appearance];
    _saveButton.onPress = ^(SZFriendsButton *button) {
        (void)button;
        [weakSelf saveName];
    };
    _renameError = SZFriendsLabel(@"", appearance.secondaryFont, appearance.destructiveColor);
    for (NSView *view in @[ _title, _addTitle, _addSteps, _renameButton, _renameField, _saveButton, _renameError ])
        [self addSubview:view];
    _names = [NSMutableArray array];
    _details = [NSMutableArray array];
    _dots = [NSMutableArray array];
    _removes = [NSMutableArray array];
    self.hidden = YES;
    return self;
}

- (NSArray<NSTextField *> *)nameLabels {
    return [_names copy];
}

- (NSArray<NSTextField *> *)detailLabels {
    return [_details copy];
}

- (NSTextField *)addTitleLabel {
    return _addTitle;
}

- (NSTextField *)addStepsLabel {
    return _addSteps;
}

- (NSArray<SZFriendsActionButton *> *)removeButtons {
    return [_removes copy];
}

- (void)applyDevices:(NSDictionary *)devices {
    _devices = [devices copy];
    self.hidden = devices == nil;
    _title.stringValue = SZFStr(devices, @"title") ?: @"";
    NSDictionary *add = SZFDict(devices, @"add");
    _addTitle.stringValue = SZFStr(add, @"title") ?: @"";
    NSMutableArray<NSString *> *steps = [NSMutableArray array];
    for (id step in SZFArr(add, @"steps"))
        if ([step isKindOfClass:NSString.class])
            [steps addObject:[NSString stringWithFormat:@"%lu. %@", (unsigned long)steps.count + 1, step]];
    _addSteps.stringValue = [steps componentsJoinedByString:@"\n"];
    _rename = nil;
    for (NSArray *views in @[ _names, _details, _dots ])
        for (NSView *view in views) [view removeFromSuperview];
    [_names removeAllObjects];
    [_details removeAllObjects];
    [_dots removeAllObjects];
    NSMutableArray *removes = [NSMutableArray array];
    SZFriendsAppearance *appearance = _context.appearance;
    for (id row in SZFArr(devices, @"rows")) {
        if (![row isKindOfClass:NSDictionary.class]) continue;
        BOOL here = SZFBool(row, @"this_computer");
        NSFont *nameFont = here ? SZFriendsSemibold(appearance.bodyFont) : appearance.bodyFont;
        NSTextField *name = SZFriendsLabel(SZFStr(row, @"name"), nameFont, appearance.primaryTextColor);
        name.accessibilityLabel = SZFStr(row, @"accessibility_label");
        NSTextField *detail = SZFriendsLabel(SZFStr(row, @"detail"), appearance.secondaryFont,
                                             appearance.secondaryTextColor);
        // A dot by state: connected computers in the success colour, the others hollow and quiet.
        SZFriendsFlippedView *dot = [[SZFriendsFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 8, 8)];
        dot.cornerRadius = 4;
        BOOL connected = [SZFStr(row, @"state") isEqualToString:@"connected"];
        dot.fillColor = connected ? appearance.successColor : nil;
        dot.strokeColor = connected ? nil : appearance.secondaryTextColor;
        for (NSView *view in @[ dot, name, detail ]) [self addSubview:view];
        [_names addObject:name];
        [_details addObject:detail];
        [_dots addObject:dot];
        if (here) {
            _rename = SZFDict(row, @"rename");
            _thisName = SZFStr(row, @"name");
        }
        NSDictionary *remove = SZFDict(row, @"remove");
        if (remove) [removes addObject:remove];
    }
    NSArray *previous = [_removes copy];
    NSArray *buttons = SZFriendsActionButtonsFor(removes, nil, _context, previous);
    for (NSView *old in previous)
        if (![buttons containsObject:old]) [old removeFromSuperview];
    for (SZFriendsActionButton *button in buttons) {
        if (!button.superview) [self addSubview:button];
        NSString *device = SZFStr(button.actionObject, @"device_id");
        for (id row in SZFArr(devices, @"rows"))
            if ([SZFStr(row, @"device_id") isEqualToString:device])
                button.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", button.title, SZFStr(row, @"name")];
    }
    [_removes setArray:buttons];
    _renameButton.title = SZFStr(_rename, @"label") ?: @"";
    _renameButton.hidden = _rename == nil;
    _renameField.placeholderString = SZFStr(_rename, @"placeholder");
    _renameField.accessibilityLabel = SZFStr(_rename, @"placeholder");
    _saveButton.title = SZFStr(_rename, @"button_label") ?: @"";
    if (!_rename) [self cancelRenaming];
    [self setNeedsLayout:YES];
}

#pragma mark - Renaming this computer

// The profile page lays this view out with the rest, so a field that opens or an error that shows reaches it.
- (void)relayout {
    for (NSView *view = self; view; view = view.superview) {
        view.needsLayout = YES;
        if ([view isKindOfClass:SZFriendsPage.class]) break;
    }
}

- (void)beginRenaming {
    if (!_rename || _renaming) return;
    _renaming = YES;
    _renameField.stringValue = _thisName ?: @"";
    _renameError.stringValue = @"";
    [self.window makeFirstResponder:_renameField];
    [self relayout];
}

- (BOOL)cancelRenaming {
    if (!_renaming) return NO;
    _renaming = NO;
    _renameError.stringValue = @"";
    [self relayout];
    return YES;
}

- (void)saveName {
    if (!_renaming) return;
    NSString *name = _renameField.stringValue ?: @"";
    _saveButton.enabled = NO;
    __weak SZFriendsYourComputersView *weakSelf = self;
    [_context.link sendIntent:@"rename_device" fields:@{@"name" : name}
                        reply:^(NSDictionary *result, SZFriendsLinkError *error) {
                            (void)result;
                            SZFriendsYourComputersView *view = weakSelf;
                            if (!view) return;
                            view->_saveButton.enabled = YES;
                            if (!error) {
                                [view cancelRenaming];
                                return;
                            }
                            view->_renameError.stringValue = error.message ?: @"";
                            [view->_context announce:error.message];
                            [view relayout];
                        }];
}

- (void)controlTextDidChange:(NSNotification *)notification {
    if (notification.object != _renameField) return;
    // The helper takes at most max_bytes of UTF-8: what does not fit is never typed rather than refused later.
    NSUInteger maxBytes = (NSUInteger)MAX(1, SZFNum(_rename, @"max_bytes"));
    NSString *fitting = SZFPrefixFittingBytes(_renameField.stringValue, maxBytes);
    if (![fitting isEqualToString:_renameField.stringValue]) _renameField.stringValue = fitting;
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command {
    (void)control, (void)textView;
    if (command == @selector(cancelOperation:)) {
        if (![self cancelRenaming]) SZFriendsForwardEscape(self);
        return YES;
    }
    if (command != @selector(insertNewline:)) return NO;
    [self saveName];
    return YES;
}

#pragma mark - Layout

- (CGFloat)layoutForWidth:(CGFloat)width {
    if (self.hidden) return 0;
    CGFloat y = 0;
    if (_title.stringValue.length) y = SZFriendsPlace(_title, 0, y, width) + 8;
    NSUInteger removeIndex = 0;
    NSArray *rows = SZFArr(_devices, @"rows");
    for (NSUInteger i = 0; i < _names.count && i < rows.count; i++) {
        NSDictionary *row = rows[i];
        SZFriendsButton *trailing = nil;
        if (SZFBool(row, @"this_computer") && _rename) trailing = _renaming ? nil : _renameButton;
        else if (SZFDict(row, @"remove") && removeIndex < _removes.count) trailing = _removes[removeIndex++];
        CGFloat trailingWidth = trailing ? MAX(trailing.style == SZFriendsButtonStyleLink ? 0 : 72,
                                               [trailing fittingWidth]) : 0;
        // Name and detail wrap rather than truncate: a long computer name or "Not connected to this computer yet"
        // must read whole at the narrowest dropdown.
        CGFloat textX = 16, textWidth = width - textX - (trailingWidth ? trailingWidth + 8 : 0);
        _dots[i].frame = NSMakeRect(2, y + 5, 8, 8);
        CGFloat bottom = SZFriendsPlace(_names[i], textX, y, textWidth);
        bottom = SZFriendsPlace(_details[i], textX, bottom + 1, textWidth);
        if (trailing) {
            CGFloat height = trailing.style == SZFriendsButtonStyleLink ? 20 : 24;
            trailing.frame = NSMakeRect(width - trailingWidth, y + floor((bottom - y - height) / 2), trailingWidth,
                                        height);
        }
        y = bottom + 10;
        if (SZFBool(row, @"this_computer") && _renaming) {
            CGFloat saveWidth = MAX(64, [_saveButton fittingWidth]);
            _renameField.frame = NSMakeRect(textX, y - 4, width - textX - saveWidth - 8, 26);
            _saveButton.frame = NSMakeRect(width - saveWidth, y - 4, saveWidth, 26);
            y += 26 + 4;
            if (_renameError.stringValue.length) y = SZFriendsPlace(_renameError, textX, y, width - textX) + 6;
            y += 4;
        }
    }
    _renameButton.hidden = !_rename || _renaming;
    _renameField.hidden = _saveButton.hidden = !_renaming;
    _renameError.hidden = !_renaming || !_renameError.stringValue.length;
    // How to add another computer or phone, under the list of them.
    _addTitle.hidden = !_addTitle.stringValue.length;
    _addSteps.hidden = !_addSteps.stringValue.length;
    if (!_addTitle.hidden) y = SZFriendsPlace(_addTitle, 0, y + 2, width) + 3;
    if (!_addSteps.hidden) y = SZFriendsPlace(_addSteps, 0, y, width) + 4;
    return y;
}

@end
