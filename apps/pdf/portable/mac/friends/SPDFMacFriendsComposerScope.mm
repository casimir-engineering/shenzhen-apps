#import "SPDFMacFriendsComposerScope.h"
#import "../SPDFMacCollectionStyle.h"
#import "SPDFMacFriendsComposerText.h"

NSString* const SPDFMacFriendsScopePickerIdentifier = @"szfriends.scopePicker";

// Room for the note's two lines at 11 pt inside the input box; the text area shrinks by this much while it shows.
static const CGFloat kNoteHeight = 30.0;
// Above the lengths after All Friends chats: what the person is choosing.
static NSString* const kLengthTitle = @"Let the assistant read all your Friends chats for";

// The picker's rows: Return chooses and Escape closes when the rows, not the search field, have focus (the lengths).
@interface SPDFMacFriendsPickerTable : NSTableView
@property(nonatomic, copy) dispatch_block_t cancel;
@end
@implementation SPDFMacFriendsPickerTable
- (void)keyDown:(NSEvent*)event {
    unichar key = event.charactersIgnoringModifiers.length ? [event.charactersIgnoringModifiers characterAtIndex:0] : 0;
    if (key == NSCarriageReturnCharacter || key == NSEnterCharacter) [self sendAction:self.action to:self.target];
    else if (key == 27 && self.cancel) self.cancel();
    else [super keyDown:event];
}
@end

@interface SPDFMacFriendsComposerScope () <NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate,
                                           NSPopoverDelegate>
@end

@implementation SPDFMacFriendsComposerScope {
    __weak NSTextView* _composer;
    void (^_choices)(SPDFMacFriendsChoicesDelivery);
    NSUInteger _pendingIndex;
    unichar _pendingTrigger;
    NSUInteger _generation;
    NSPopover* _popover;
    NSSearchField* _search;
    NSTableView* _table;
    NSArray<NSDictionary*>* _allChoices;
    NSArray<NSDictionary*>* _filtered;
    CGFloat _baseBottomInset;
    BOOL _noteShown;
    id _observer;
    id _boxObserver;
}

- (instancetype)initWithComposer:(NSTextView*)composer choices:(void (^)(SPDFMacFriendsChoicesDelivery))choices {
    if (!(self = [super init])) return nil;
    _composer = composer;
    _choices = [choices copy];
    _pendingIndex = NSNotFound;
    _filePlaceholder = @"Search documents";
    _note = [NSTextField wrappingLabelWithString:@""];
    _note.identifier = @"friendsScopeNote";
    _note.font = [NSFont systemFontOfSize:11];
    _note.textColor = SPDFCollectionColor(@"secondary");
    _note.maximumNumberOfLines = 2;
    _note.hidden = YES;
    NSScrollView* input = composer.enclosingScrollView;
    if (input) {
        _baseBottomInset = input.contentInsets.bottom;
        // A subview of the scroll view, not of the text, so it stays put while the text scrolls; it sits in the
        // strip the bottom inset reserves while it is visible. Placed by hand whenever the box changes size: a
        // width-sizable mask froze the margins the box had when it was first laid out (a box made at zero width and
        // laid out at 618 pt kept a 608 pt right margin), so the box could never get narrower and the composer ran
        // past the chat panel's edge; and the scroll view is flipped, so y = 3 put the note at the top. A fixed mask
        // gives Auto Layout the note's position and width only, never a margin to the box's far edge.
        _note.autoresizingMask = NSViewNotSizable;
        [input addSubview:_note positioned:NSWindowAbove relativeTo:nil];
        [self placeNote];
        input.postsFrameChangedNotifications = YES;
        __weak SPDFMacFriendsComposerScope* weakScope = self;
        _boxObserver = [NSNotificationCenter.defaultCenter addObserverForName:NSViewFrameDidChangeNotification
            object:input queue:nil usingBlock:^(NSNotification* note) { (void)note; [weakScope placeNote]; }];
    }
    __weak SPDFMacFriendsComposerScope* weakSelf = self;
    _presentPicker = ^(NSUInteger index, NSArray* list) { [weakSelf showPopoverAt:index choices:list title:nil]; };
    _presentLengths = ^(NSUInteger index, NSArray* list) {
        [weakSelf showPopoverAt:index choices:list title:kLengthTitle];
    };
    _observer = [NSNotificationCenter.defaultCenter addObserverForName:NSTextDidChangeNotification object:composer
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification* note) { (void)note; [weakSelf textDidChange]; }];
    return self;
}

- (void)dealloc { [self uninstall]; }

- (void)uninstall {
    if (_observer) [NSNotificationCenter.defaultCenter removeObserver:_observer];
    if (_boxObserver) [NSNotificationCenter.defaultCenter removeObserver:_boxObserver];
    _observer = _boxObserver = nil;
    [self closePopover];
    [self setNoteShown:NO];
    [_note removeFromSuperview];
}

- (BOOL)isPickerShown { return _popover.shown; }

- (void)textDidChange {
    [self refreshNote];
    NSTextView* composer = _composer;
    if (!self.available || !composer || composer.hasMarkedText || composer.selectedRange.length) return;
    NSUInteger caret = composer.selectedRange.location;
    BOOL mention = SPDFMacFriendsCaretFollowsTrigger(composer.string, caret, '@');
    if (!mention && !(self.fileChoices && SPDFMacFriendsCaretFollowsTrigger(composer.string, caret, '#'))) return;
    _pendingIndex = caret - 1;
    _pendingTrigger = mention ? '@' : '#';
    NSUInteger generation = ++_generation, index = _pendingIndex;
    __weak SPDFMacFriendsComposerScope* weakSelf = self;
    void (^deliver)(NSArray*) = ^(NSArray* list) {
        dispatch_block_t present = ^{
            SPDFMacFriendsComposerScope* scope = weakSelf;
            // The person may have typed on or deleted the "@" while the list was on its way.
            if (!scope || generation != scope->_generation || scope->_pendingIndex != index || !scope.available) return;
            if (scope.presentPicker) scope.presentPicker(index, list ?: @[]);
        };
        if (NSThread.isMainThread) present(); else dispatch_async(dispatch_get_main_queue(), present);
    };
    if (!mention) self.fileChoices(deliver);
    else if (_choices) _choices(deliver);
    else deliver(SPDFMacFriendsScopeChoices(@[]));
}

- (void)choose:(NSDictionary<NSString*, id>*)choice {
    NSTextView* composer = _composer;
    SPDFMacAIRequestChip* file = [choice[@"file"] isKindOfClass:SPDFMacAIRequestChip.class] ? choice[@"file"] : nil;
    NSNumber* length = [choice[@"length"] isKindOfClass:NSNumber.class] ? choice[@"length"] : nil;
    BOOL all = !file && [choice[@"id"] isEqual:SPDFMacFriendsAllChatsChoiceID];
    if (all && self.grantAllChats && composer) {
        // All Friends chats asks how long before anything is granted; "This request" falls through to the chip.
        if (!length) {
            if (self.presentLengths) self.presentLengths(_pendingIndex, SPDFMacFriendsGrantLengthChoices());
            return;
        }
        if (length.integerValue != SPDFMacFriendsGrantLengthRequest) {
            [self startGrant:(SPDFMacFriendsGrantLength)length.integerValue];
            return;
        }
    }
    SPDFMacFriendsScopeRequest* scope = file ? nil : SPDFMacFriendsScopeForChoice(choice);
    if (!composer || (!scope && !file)) return;
    NSFont* font = composer.font ?: [NSFont systemFontOfSize:13];
    NSMutableAttributedString* chip = [(file ? [SPDFMacFriendsFileToken chipWithFile:file font:font]
                                             : [SPDFMacFriendsScopeToken chipWithScope:scope font:font]) mutableCopy];
    // A plain space after the chip, so typing continues in ordinary text rather than inheriting the attachment.
    [chip appendAttributedString:[[NSAttributedString alloc] initWithString:@" " attributes:@{
        NSFontAttributeName : font, NSForegroundColorAttributeName : composer.textColor ?: SPDFCollectionColor(@"text")}]];
    NSString* text = composer.string;
    NSRange range = NSMakeRange(MIN(composer.selectedRange.location, text.length), 0);
    unichar trigger = file ? '#' : '@';
    if (_pendingIndex < text.length && [text characterAtIndex:_pendingIndex] == trigger)
        range = NSMakeRange(_pendingIndex, 1);
    _pendingIndex = NSNotFound;
    if ([composer shouldChangeTextInRange:range replacementString:chip.string]) {
        [composer.textStorage replaceCharactersInRange:range withAttributedString:chip];
        [composer didChangeText];
        composer.selectedRange = NSMakeRange(range.location + chip.length, 0);
    }
    [self closePopover];
    [composer.window makeFirstResponder:composer];
    [self refreshNote];
}

// A time grant: the "@" that opened the picker goes, since no chip stands for it; the bar above the chat says what
// was granted and for how long.
- (void)startGrant:(SPDFMacFriendsGrantLength)length {
    NSTextView* composer = _composer;
    NSString* text = composer.string;
    NSUInteger index = _pendingIndex;
    _pendingIndex = NSNotFound;
    if (index < text.length && [text characterAtIndex:index] == '@') {
        NSRange range = NSMakeRange(index, 1);
        if ([composer shouldChangeTextInRange:range replacementString:@""]) {
            [composer.textStorage replaceCharactersInRange:range withString:@""];
            [composer didChangeText];
            composer.selectedRange = NSMakeRange(index, 0);
        }
    }
    [self closePopover];
    [composer.window makeFirstResponder:composer];
    self.grantAllChats(length);
    [self refreshNote];
}

- (void)insertFiles:(NSArray<SPDFMacAIRequestChip*>*)files {
    _pendingIndex = NSNotFound; // a drop goes at the caret, never over a typed "#"
    for (SPDFMacAIRequestChip* file in files)
        [self choose:@{@"id" : @"file", @"name" : file.displayName, @"file" : file}];
}

// The note across the bottom strip of its box, 10 pt in from each side and 3 pt up from the bottom edge.
- (void)placeNote {
    NSView* input = _note.superview;
    if (!input) return;
    NSRect box = input.bounds;
    CGFloat height = kNoteHeight - 4, y = input.isFlipped ? NSHeight(box) - 3 - height : 3;
    _note.frame = NSMakeRect(10, y, MAX(0, NSWidth(box) - 20), height);
}

- (void)setNoteShown:(BOOL)shown {
    if (shown == _noteShown) return;
    _noteShown = shown;
    NSScrollView* input = _note.superview == _composer.enclosingScrollView ? _composer.enclosingScrollView : nil;
    NSEdgeInsets insets = input.contentInsets;
    insets.bottom = _baseBottomInset + (shown ? kNoteHeight : 0);
    input.contentInsets = insets;
    _note.hidden = !shown;
}

- (void)refreshNote {
    NSTextView* composer = _composer;
    NSString* text = composer ? SPDFMacFriendsComposerNote(composer.textStorage) : nil;
    _note.stringValue = text ?: @"";
    _note.toolTip = text;
    [self setNoteShown:text != nil];
}

#pragma mark - Picker

- (void)closePopover {
    if (_popover.shown) [_popover close];
    _popover = nil;
}

- (NSView*)pickerViewWithChoices:(NSArray<NSDictionary*>*)choices title:(NSString*)title {
    _allChoices = choices;
    _filtered = choices;
    CGFloat height = 48 + 28 * MIN(6, MAX(1, (NSInteger)choices.count));
    NSView* view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 280, height)];
    view.identifier = SPDFMacFriendsScopePickerIdentifier;
    BOOL files = _pendingTrigger == '#';
    if (title) {
        NSTextField* label = [NSTextField wrappingLabelWithString:title];
        label.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
        label.frame = NSMakeRect(12, height - 38, 256, 30);
        [view addSubview:label];
        _search = nil;
    } else {
        _search = [[NSSearchField alloc] initWithFrame:NSMakeRect(10, height - 38, 260, 28)];
        _search.placeholderString = files ? self.filePlaceholder : @"Search friends";
        _search.accessibilityLabel = _search.placeholderString;
        _search.delegate = self;
        [view addSubview:_search];
    }
    NSScrollView* scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(6, 6, 268, height - 50)];
    scroll.hasVerticalScroller = YES;
    scroll.drawsBackground = NO;
    SPDFMacFriendsPickerTable* table = [[SPDFMacFriendsPickerTable alloc] initWithFrame:scroll.bounds];
    __weak SPDFMacFriendsComposerScope* weakSelf = self;
    table.cancel = ^{ [weakSelf cancelPicker]; };
    _table = table;
    NSTableColumn* column = [[NSTableColumn alloc] initWithIdentifier:@"chat"];
    column.width = 250;
    [_table addTableColumn:column];
    _table.headerView = nil;
    _table.rowHeight = 26;
    _table.dataSource = self;
    _table.delegate = self;
    _table.target = self;
    _table.action = @selector(chooseSelectedRow:);
    _table.accessibilityLabel = title ? @"How long the assistant may read all your Friends chats"
        : files ? @"Documents to attach to this message" : @"Friends chats to bring into this message";
    scroll.documentView = _table;
    [view addSubview:scroll];
    [_table reloadData];
    if (_filtered.count) [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    return view;
}

- (void)showPopoverAt:(NSUInteger)index choices:(NSArray<NSDictionary*>*)choices title:(NSString*)title {
    NSTextView* composer = _composer;
    if (!composer.window || index >= composer.string.length) return;
    NSViewController* content = [NSViewController new];
    content.view = [self pickerViewWithChoices:choices title:title];
    NSView* focus = _search ?: _table;
    // The second step (how long) replaces the open picker's rows in place, so the "@" it was opened for stays.
    if (_popover.shown) {
        _popover.contentViewController = content;
        _popover.contentSize = content.view.frame.size;
        [focus.window makeFirstResponder:focus];
        return;
    }
    [self closePopover];
    _popover = [NSPopover new];
    _popover.behavior = NSPopoverBehaviorTransient;
    _popover.animates = NO;
    _popover.delegate = self;
    _popover.contentViewController = content;
    NSRange glyphs = [composer.layoutManager glyphRangeForCharacterRange:NSMakeRange(index, 1)
                                                    actualCharacterRange:NULL];
    NSRect rect = [composer.layoutManager boundingRectForGlyphRange:glyphs inTextContainer:composer.textContainer];
    rect = NSOffsetRect(rect, composer.textContainerOrigin.x, composer.textContainerOrigin.y);
    // Above the "@": the composer sits at the bottom of the chat panel (the text view is flipped, so MinY is up).
    [_popover showRelativeToRect:rect ofView:composer preferredEdge:NSRectEdgeMinY];
    [focus.window makeFirstResponder:focus];
}

- (void)cancelPicker {
    [self closePopover];
    [_composer.window makeFirstResponder:_composer];
}

- (void)popoverDidClose:(NSNotification*)notification {
    (void)notification;
    // Closed without a choice: the "@" or "#" stays as typed text.
    _pendingIndex = NSNotFound;
}

- (void)controlTextDidChange:(NSNotification*)notification {
    (void)notification;
    NSString* query = _search.stringValue;
    NSStringCompareOptions options = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
    _filtered = query.length ? [_allChoices filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:
        ^BOOL(NSDictionary* choice, NSDictionary* bindings) {
            (void)bindings;
            return [choice[@"name"] rangeOfString:query options:options].location != NSNotFound;
        }]] : _allChoices;
    [_table reloadData];
    if (_filtered.count) [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
}

- (BOOL)control:(NSControl*)control textView:(NSTextView*)textView doCommandBySelector:(SEL)command {
    (void)control; (void)textView;
    if (command == @selector(cancelOperation:)) {
        [self cancelPicker];
        return YES;
    }
    if (command == @selector(insertNewline:)) { [self chooseSelectedRow:nil]; return YES; }
    if (command == @selector(moveDown:) || command == @selector(moveUp:)) {
        if (!_filtered.count) return YES;
        NSInteger row = _table.selectedRow + (command == @selector(moveDown:) ? 1 : -1);
        row = MAX(0, MIN((NSInteger)_filtered.count - 1, row));
        [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
        [_table scrollRowToVisible:row];
        return YES;
    }
    return NO;
}

- (void)chooseSelectedRow:(id)sender {
    (void)sender;
    NSInteger row = _table.selectedRow;
    if (row >= 0 && row < (NSInteger)_filtered.count) [self choose:_filtered[(NSUInteger)row]];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView*)tableView {
    return tableView == _table ? (NSInteger)_filtered.count : 0;
}

- (NSView*)tableView:(NSTableView*)tableView viewForTableColumn:(NSTableColumn*)column row:(NSInteger)row {
    (void)column;
    // A table from the picker's first step can still draw once after the second step replaced the rows.
    if (tableView != _table || row < 0 || row >= (NSInteger)_filtered.count) return nil;
    NSTextField* label = [NSTextField labelWithString:_filtered[(NSUInteger)row][@"name"] ?: @""];
    label.font = [NSFont systemFontOfSize:13];
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

@end
