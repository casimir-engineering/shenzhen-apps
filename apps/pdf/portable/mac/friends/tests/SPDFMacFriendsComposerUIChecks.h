// The `@` picker and note on a real NSTextView in an offscreen window (never shown): typing "@" asks for the picker
// only at the start of a word and only while available, choosing inserts a chip, and the note follows the chips.
// Included by SPDFMacFriendsScopeTests.mm.

#pragma once
#import "SPDFMacFriendsComposerScope.h"

static void Type(NSTextView* composer, NSString* text) {
    [composer insertText:text replacementRange:composer.selectedRange];
}

// The chat panel's input box is made at zero size and laid out by constraints, first at one width and later at
// another (the panel opened, then narrowed). The note inside it must follow the box: it once kept the right margin
// of the first layout, so the box could not get narrower and the composer ran past the panel's edge.
static void CheckNoteFollowsTheBox(void) {
    NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 650, 120)
                                                   styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered defer:YES];
    window.releasedWhenClosed = NO;
    NSView* panel = window.contentView;
    NSScrollView* input = [NSScrollView new];
    input.translatesAutoresizingMaskIntoConstraints = NO;
    input.automaticallyAdjustsContentInsets = NO;
    input.contentInsets = NSEdgeInsetsMake(2, 2, 2, 2);
    NSTextView* composer = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 500, 64)];
    composer.autoresizingMask = NSViewWidthSizable;
    input.documentView = composer;
    [panel addSubview:input];
    SPDFMacFriendsComposerScope* scope = [[SPDFMacFriendsComposerScope alloc] initWithComposer:composer
        choices:^(SPDFMacFriendsChoicesDelivery deliver) { deliver(@[]); }];
    [NSLayoutConstraint activateConstraints:@[
        [input.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:16],
        [input.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-16],
        [input.topAnchor constraintEqualToAnchor:panel.topAnchor constant:20],
        [input.heightAnchor constraintEqualToConstant:68]
    ]];
    [panel layoutSubtreeIfNeeded];
    Expect(fabs(NSWidth(input.frame) - 618) < 0.5, @"the box must take the panel's width: %@",
           NSStringFromRect(input.frame));
    [window setContentSize:NSMakeSize(400, 120)];
    [panel layoutSubtreeIfNeeded];
    Expect(fabs(NSWidth(input.frame) - 368) < 0.5, @"the box must narrow with the panel: %@ in a 400 pt panel",
           NSStringFromRect(input.frame));
    scope.note.stringValue = @"The assistant can read your chat with Mei and write messages to Mei for you to send.";
    scope.note.hidden = NO;
    [panel layoutSubtreeIfNeeded];
    NSRect note = scope.note.frame;
    Expect(fabs(NSMinX(note) - 10) < 0.5 && fabs(NSMaxX(note) - (NSWidth(input.bounds) - 10)) < 0.5,
           @"the note must span the box less 10 pt each side: %@ in %@", NSStringFromRect(note),
           NSStringFromRect(input.bounds));
    Expect(fabs(NSMaxY(note) - (NSHeight(input.bounds) - 3)) < 0.5,
           @"the note must sit in the strip at the bottom of the box: %@ in %@", NSStringFromRect(note),
           NSStringFromRect(input.bounds));
    [scope uninstall];
    [window close];
}

static void CheckComposerUI(void) {
    CheckNoteFollowsTheBox();
    NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 500, 120)
                                                   styleMask:NSWindowStyleMaskTitled
                                                     backing:NSBackingStoreBuffered defer:YES];
    window.releasedWhenClosed = NO;
    NSScrollView* input = [[NSScrollView alloc] initWithFrame:NSMakeRect(10, 10, 480, 68)];
    input.automaticallyAdjustsContentInsets = NO;
    input.contentInsets = NSEdgeInsetsMake(2, 2, 2, 2);
    NSTextView* composer = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 480, 64)];
    composer.richText = NO;
    composer.font = [NSFont systemFontOfSize:13];
    input.documentView = composer;
    [window.contentView addSubview:input];
    [window makeFirstResponder:composer];

    __block NSInteger requests = 0;
    __block NSUInteger requestedIndex = NSNotFound;
    __block NSArray* offered = nil;
    NSArray* rows = @[@{@"conversation_id" : @"c_mei", @"title" : @"Mei"}];
    SPDFMacFriendsComposerScope* scope = [[SPDFMacFriendsComposerScope alloc] initWithComposer:composer
        choices:^(SPDFMacFriendsChoicesDelivery deliver) { deliver(SPDFMacFriendsScopeChoices(rows)); }];
    scope.presentPicker = ^(NSUInteger index, NSArray* choices) {
        requests++;
        requestedIndex = index;
        offered = choices;
    };
    Expect(scope.note.superview == input && scope.note.hidden, @"the note must live in the input box, hidden");

    Type(composer, @"Ask @");
    Expect(requests == 0, @"the picker opened while Friends chats are unavailable");
    composer.string = @"";
    scope.available = YES;
    Type(composer, @"mei@");
    Expect(requests == 0, @"an @ inside a word opened the picker");
    composer.string = @"";
    Type(composer, @"Ask ");
    Type(composer, @"@");
    Expect(requests == 1 && requestedIndex == 4 && offered.count == 2, @"typing @ must ask for the picker at the @");

    [scope choose:offered[1]];
    Expect([composer.string characterAtIndex:4] == NSAttachmentCharacter && ![composer.string containsString:@"@"],
           @"choosing must replace the @ with a chip: %@", composer.string);
    Expect(([SPDFMacFriendsPlainTextReplacingChips(composer.textStorage) isEqual:@"Ask @Mei"]), @"chip text");
    Expect(!scope.note.hidden && [scope.note.stringValue containsString:@"your chat with Mei and write messages to "
                                                                        "Mei for you to send"] &&
           input.contentInsets.bottom > 2, @"the note must show while the chip is there");
    Type(composer, @"about delivery?");
    Expect(requests == 1, @"typing after the chip reopened the picker");

    // `#` asks for the host's documents only when it offers them, and a choice becomes a file chip.
    Type(composer, @" #");
    Expect(requests == 1, @"# opened a picker without a document source");
    SPDFMacAIRequestChip* contract = [SPDFMacAIRequestChip documentChipWithFileURL:
        [NSURL fileURLWithPath:@"/tmp/attach/Contract.pdf"] identifier:nil revision:@{@"size" : @1}
                                                                     displayName:@"Contract.pdf"];
    scope.fileChoices = ^(SPDFMacFriendsChoicesDelivery deliver) {
        deliver(@[@{@"id" : @"file:0", @"name" : @"Contract.pdf", @"file" : contract}]);
    };
    [composer deleteBackward:nil];
    Type(composer, @"#");
    Expect(requests == 2 && [composer.string characterAtIndex:requestedIndex] == '#' && offered.count == 1,
           @"typing # must ask for the document picker at the #");
    [scope choose:offered[0]];
    Expect(([SPDFMacFriendsPlainTextReplacingChips(composer.textStorage)
                isEqual:@"Ask @Mei about delivery? #Contract.pdf"]) &&
           [SPDFMacFriendsFileChipsInText(composer.textStorage) isEqual:@[contract]],
           @"choosing a document must replace the # with its chip: %@",
           SPDFMacFriendsPlainTextReplacingChips(composer.textStorage));
    SPDFMacAIRequestChip* photo = [SPDFMacAIRequestChip attachmentChipWithFileURL:
        [NSURL fileURLWithPath:@"/tmp/attach/site.jpg"] displayName:@"site.jpg"];
    [scope insertFiles:@[photo]];
    Expect(([SPDFMacFriendsFileChipsInText(composer.textStorage) isEqual:@[contract, photo]]),
           @"dropped files must become chips at the caret");
    composer.string = @"Ask ";
    [composer.textStorage appendAttributedString:[SPDFMacFriendsScopeToken chipWithScope:
        [SPDFMacFriendsScopeRequest conversationIDs:@[@"c_mei"] labels:@[@"Mei"]] font:composer.font]];
    [composer didChangeText];

    // Deleting the chip removes the scope and the note, and gives the text its room back.
    [composer setSelectedRange:NSMakeRange(4, 1)];
    [composer delete:nil];
    Expect(scope.note.hidden && input.contentInsets.bottom == 2 && !SPDFMacFriendsScopeInText(composer.textStorage),
           @"the note outlived its chip");
    [scope uninstall];
    Expect(!scope.note.superview, @"uninstall must take the note away");
}
