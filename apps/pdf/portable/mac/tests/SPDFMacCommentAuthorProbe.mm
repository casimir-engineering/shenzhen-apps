// Your name on comments, changed from where it is shown, on the real reader: its own delegate, window, comment box
// and Comments panel cards, with SPDF_STATE_DIR and HOME in a temporary folder (never the user's settings).
//
//   The box of a new comment: hovering the name shows the pencil; a click edits it with the name selected. Esc keeps
//   the old name and the box with its draft; an empty name changes nothing; Return keeps the new name, stored in
//   settings.yaml as Settings stores it, with the draft still there and the keyboard back in it; ⌘↩ from the name
//   field keeps the name and adds the comment, under the new name; a click outside keeps the name. An Edit Comment
//   box's name (the comment's own) cannot be changed there.
//   Cards: yours (under the current name) have the pencil and edit the same way; an agent's do not. A card written
//   under the old name is no longer yours once the name changed.
//   A new reader reading the same state has the new name.
// Pictures of the hover and edit states, light and dark, go to COMMENT_AUTHOR_EVIDENCE_DIR when it is set.
//
// No window is ever seen: every window AppKit orders in is made fully transparent and click-through, and the app's
// activation policy is Prohibited.
//
// Run from portable/: make -f Makefile -f mac/tests/comment-author-probe.mk mac-comment-author-probe

#import "SPDFMacDelegatePrivate.h"
#import "SPDFMacCommentActions.h"
#import "SPDFMacCommentAuthorName.h"
#import "SPDFMacCommentCards.h"
#import "SPDFMacCommentEditor.h"
#import <objc/runtime.h>

static NSUInteger failures;
static void Check(BOOL ok, NSString* message) {
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        failures++;
    }
}

static void Settle(NSTimeInterval seconds) {
    NSDate* end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (end.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
}

#pragma mark - Windows nobody sees

static IMP gOriginalOrder;
static void TransparentOrder(NSWindow* window, SEL selector, NSInteger place, NSInteger other) {
    if (place != NSWindowOut) {
        window.alphaValue = 0;
        window.ignoresMouseEvents = YES;
        if (NSMaxX(window.frame) > -1000) [window setFrameOrigin:NSMakePoint(-10000 - NSWidth(window.frame), -10000)];
    }
    ((void (*)(id, SEL, NSInteger, NSInteger))gOriginalOrder)(window, selector, place, other);
}
static NSRect Unconstrained(id object, SEL selector, NSRect frame, NSScreen* screen) {
    (void)object, (void)selector, (void)screen;
    return frame;
}

#pragma mark - The reader

@interface ShenzhenMacDelegate (CommentAuthorProbeAccess)
- (void)buildWindow;
- (void)buildMenu;
- (void)loadPersistentState;
- (SPDFMacCommentEditorView*)commentEditor;
- (id)stateObjectFromFile:(NSString*)name;
@end

@interface AuthorProbeReader : ShenzhenMacDelegate
- (void)prepareEmptyWindow;
- (NSWindow*)window;
@end

@implementation AuthorProbeReader
- (void)prepareEmptyWindow {
    _tabs = [NSMutableArray array];
    _selectedTabIndex = -1; _zoom = 1; _fitMode = SPDFFitModeWidth; _markdownFontScale = 1;
    _sidebarWidth = 240; _minimapWidth = 112;
    _restoredWindowContentSize = NSMakeSize(1100, 760);
    _renderedPages = [NSMutableArray array]; _sidebarItems = [NSMutableArray array];
    _findMatches = [NSMutableArray array]; _findHighlights = [NSMutableDictionary dictionary];
    _findMatchIndex = -1; _findQueue = [NSOperationQueue new];
    _paletteResults = [NSMutableArray array]; _favorites = [NSMutableArray array];
    _recentlyOpenedPaths = [NSMutableArray array]; _closedDocumentPaths = [NSMutableArray array];
    _documentStates = [NSMutableDictionary dictionary];
    [self buildWindow];
    _uiReady = YES;
    [_window setContentSize:NSMakeSize(1100, 760)];
    [_window orderWindow:NSWindowAbove relativeTo:0];
    [_window.contentView layoutSubtreeIfNeeded];
}
- (NSWindow*)window { return _window; }
@end

#pragma mark - Events

static NSEvent* Mouse(NSView* view, NSEventType type, NSPoint point) {
    return [NSEvent mouseEventWithType:type location:[view convertPoint:point toView:nil] modifierFlags:0
                             timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:view.window.windowNumber
                               context:nil eventNumber:0 clickCount:1 pressure:1];
}
static NSPoint Middle(NSRect r) { return NSMakePoint(NSMidX(r), NSMidY(r)); }
// A click as the window server sends it: NSApp (where the comment box watches for clicks outside it), then the view
// under the pointer.
static void Click(NSView* view, NSPoint point) {
    // The release waits in the queue, for a view that tracks the mouse until it comes up.
    [NSApp postEvent:Mouse(view, NSEventTypeLeftMouseUp, point) atStart:NO];
    [NSApp sendEvent:Mouse(view, NSEventTypeLeftMouseDown, point)];
    Settle(0.05);
}
static void Hover(NSView* view, NSPoint point) {
    [view mouseEntered:Mouse(view, NSEventTypeMouseMoved, point)];
    [view mouseMoved:Mouse(view, NSEventTypeMouseMoved, point)];
}
static NSEvent* Key(NSWindow* window, NSString* characters, unsigned short code, NSEventModifierFlags flags) {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags
                           timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil
                          characters:characters charactersIgnoringModifiers:characters isARepeat:NO keyCode:code];
}
// A key as AppKit delivers it: key equivalents first (the window's views), else to the first responder.
static void Press(NSWindow* window, NSString* characters, unsigned short code, NSEventModifierFlags flags) {
    NSEvent* event = Key(window, characters, code, flags);
    if (!(flags & NSEventModifierFlagCommand) || ![window performKeyEquivalent:event]) [window sendEvent:event];
    Settle(0.05);
}
static void Return(NSWindow* window) { Press(window, @"\r", 36, 0); }
static void Escape(NSWindow* window) { Press(window, @"\x1b", 53, 0); }
static void Type(NSWindow* window, NSString* text) {
    NSTextView* editor = (NSTextView*)window.firstResponder;
    Check([editor isKindOfClass:NSTextView.class], @"something has the keyboard to type into");
    if ([editor isKindOfClass:NSTextView.class]) [editor insertText:text replacementRange:editor.selectedRange];
}
static NSTextField* EditingField(NSView* host) {
    for (NSView* view in host.subviews)
        if ([view isKindOfClass:NSTextField.class] && !view.hidden && ((NSTextField*)view).currentEditor) return (NSTextField*)view;
    return nil;
}

#pragma mark - Evidence

static void Capture(NSView* view, NSString* name) {
    NSString* folder = NSProcessInfo.processInfo.environment[@"COMMENT_AUTHOR_EVIDENCE_DIR"];
    if (!folder.length) return;
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString* look in @[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]) {
        view.window.appearance = [NSAppearance appearanceNamed:look];
        [view.window.contentView layoutSubtreeIfNeeded];
        NSRect rect = NSInsetRect(view.bounds, -12, -12);
        NSView* backdrop = view.superview;
        NSRect inBackdrop = [view convertRect:rect toView:backdrop];
        NSBitmapImageRep* rep = [backdrop bitmapImageRepForCachingDisplayInRect:inBackdrop];
        [backdrop cacheDisplayInRect:inBackdrop toBitmapImageRep:rep];
        NSString* file = [NSString stringWithFormat:@"%@-%@.png", name, [look isEqual:NSAppearanceNameAqua] ? @"light" : @"dark"];
        Check([[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
                  writeToFile:[folder stringByAppendingPathComponent:file] atomically:YES],
              [@"wrote " stringByAppendingString:file]);
    }
    view.window.appearance = nil;
}

static NSString* StoredAuthor(AuthorProbeReader* reader) {
    NSDictionary* settings = [reader stateObjectFromFile:@"settings.yaml"];
    id value = [settings isKindOfClass:NSDictionary.class] ? settings[@"commentAuthor"] : nil;
    return [value isKindOfClass:NSString.class] ? value : nil;
}

#pragma mark - The box

static NSString* gAdded;

static SPDFMacCommentEditorView* OpenNewCommentBox(AuthorProbeReader* reader, NSString* draftKey) {
    [reader openCommentEditorWithTitle:@"Add Comment" button:@"Add" author:[reader currentCommentAuthor] text:@""
                              draftKey:draftKey completion:^(NSString* text) { gAdded = text; }];
    Settle(0.05);
    return [reader commentEditor];
}

static void CheckBox(AuthorProbeReader* reader, NSString* mac) {
    NSWindow* window = reader.window;
    SPDFMacCommentEditorView* box = OpenNewCommentBox(reader, @"probe#box");
    SPDFMacCommentAuthorByline* byline = (SPDFMacCommentAuthorByline*)box.authorByline;
    Check(box.isOpen && [byline isKindOfClass:SPDFMacCommentAuthorByline.class], @"a new comment's box is open with its byline");
    Check(byline.editable && [byline.name isEqualToString:mac], @"its byline is your name and can be changed");
    NSString* draft = @"A draft the name change must not lose";
    Type(window, draft);

    Check(!byline.hovered, @"no pencil before the pointer is on the name");
    Hover(byline, Middle(byline.nameArea));
    Check(byline.hovered, @"the pointer on the name shows the pencil");
    Capture(box, @"comment-box-name-hover");
    Hover(byline, NSMakePoint(1, 1));
    Check(!byline.hovered || NSPointInRect(NSMakePoint(1, 1), byline.nameArea), @"the pencil goes when the pointer leaves the name");

    // Esc: the old name, the box still open with its draft.
    Click(byline, Middle(byline.nameArea));
    NSTextField* field = EditingField(byline);
    Check(byline.editing && field != nil, @"a click on the name edits it");
    NSText* fieldEditor = field.currentEditor;
    Check(NSEqualRanges(fieldEditor.selectedRange, NSMakeRange(0, mac.length)), @"the whole name is selected");
    Capture(box, @"comment-box-name-editing");
    Type(window, @"Mei Lin");
    Escape(window);
    Check(!byline.editing && box.isOpen, @"Esc ends the name edit and leaves the box open");
    Check([[reader currentCommentAuthor] isEqualToString:mac] && [byline.name isEqualToString:mac], @"Esc keeps the old name");
    Check([box.textView.string isEqualToString:draft], @"the draft is still there after Esc");
    Check(window.firstResponder == box.textView, @"the keyboard is back in the comment after Esc");

    // An empty name changes nothing.
    Click(byline, Middle(byline.nameArea));
    Type(window, @"   ");
    Return(window);
    Check([[reader currentCommentAuthor] isEqualToString:mac] && [byline.name isEqualToString:mac],
          [NSString stringWithFormat:@"an empty name keeps the old one (%@)", byline.name]);
    Check(!StoredAuthor(reader).length, @"an empty name stores nothing");

    // Return: the new name, stored as Settings stores it.
    Click(byline, Middle(byline.nameArea));
    Type(window, @"Mei Lin");
    Return(window);
    Check([[reader currentCommentAuthor] isEqualToString:@"Mei Lin"] && [byline.name isEqualToString:@"Mei Lin"],
          @"Return keeps the new name");
    Check([StoredAuthor(reader) isEqualToString:@"Mei Lin"],
          [NSString stringWithFormat:@"the new name is in settings.yaml (%@)", StoredAuthor(reader)]);
    Check(box.isOpen && [box.textView.string isEqualToString:draft], @"the box and its draft are still there after Return");
    Check(window.firstResponder == box.textView, @"the keyboard is back in the comment after Return");

    // ⌘↩ from the name field: the name, then the comment, under that name.
    Click(byline, Middle(byline.nameArea));
    Type(window, @"Mei L.");
    gAdded = nil;
    Press(window, @"\r", 36, NSEventModifierFlagCommand);
    Check(!box.isOpen && [gAdded isEqualToString:draft], [NSString stringWithFormat:@"⌘↩ in the name adds the comment (%@)", gAdded]);
    Check([[reader currentCommentAuthor] isEqualToString:@"Mei L."], @"⌘↩ in the name keeps the new name first");

    // A click outside the box keeps the name typed.
    box = OpenNewCommentBox(reader, @"probe#click-away");
    Check([byline.name isEqualToString:@"Mei L."], @"the next box shows the new name");
    Click(byline, Middle(byline.nameArea));
    Type(window, @"Mei Clicked");
    NSRect content = window.contentView.bounds;
    NSPoint away = NSMakePoint(NSMidX(box.frame) < NSMidX(content) ? NSMaxX(content) - 80 : NSMinX(content) + 80, NSMidY(content));
    Check(!NSPointInRect(away, box.frame), @"the click lands outside the box");
    Click(window.contentView, away);
    Check(!box.isOpen, @"a click outside closes the box");
    Check([[reader currentCommentAuthor] isEqualToString:@"Mei Clicked"],
          [NSString stringWithFormat:@"a click outside keeps the typed name (%@)", [reader currentCommentAuthor]]);

    // An existing comment's box shows that comment's name, which is not changed there.
    [reader openCommentEditorWithTitle:@"Edit Comment" button:@"Save" author:@"Claude" text:@"Agent's comment"
                              draftKey:@"probe#edit" completion:^(NSString* text) { (void)text; }];
    Settle(0.05);
    Check(!byline.editable && NSIsEmptyRect(byline.nameArea), @"an Edit Comment box's name has no pencil");
    Click(byline, NSMakePoint(NSMaxX(byline.bounds) - 8, NSMidY(byline.bounds)));
    Check(!byline.editing, @"a click on an Edit Comment box's name does not edit it");
    [[reader commentEditor] cancel];
}

#pragma mark - Cards

static NSView* PlaceCard(AuthorProbeReader* reader, NSTableView* table, NSDictionary* item, CGFloat y) {
    NSView* card = SPDFCommentCardCell(table, item, reader);
    card.frame = NSMakeRect(40, y, 320, SPDFCommentCardRowHeight(item, 320));
    [reader.window.contentView addSubview:card positioned:NSWindowAbove relativeTo:nil];
    [card layoutSubtreeIfNeeded];
    return card;
}
static NSRect NameArea(NSView* card) { return [[card valueForKey:@"nameArea"] rectValue]; }
static BOOL EditingName(NSView* card) { return [[card valueForKey:@"editingName"] boolValue]; }

static void CheckCards(AuthorProbeReader* reader) {
    NSWindow* window = reader.window;
    NSTableView* table = [NSTableView new];
    NSString* you = [reader currentCommentAuthor];
    NSDictionary* yours = @{@"kind" : @"comment", @"author" : you, @"body" : @"Check the torque figure on this page.",
                            @"quote" : @"Tighten to 0.6 N·m", @"date" : NSDate.date, @"meta" : @"p. 3", @"commentIndex" : @0};
    NSDictionary* agents = @{@"kind" : @"comment", @"author" : @"Claude", @"body" : @"The table on p. 4 disagrees.",
                             @"date" : NSDate.date, @"meta" : @"p. 4", @"commentIndex" : @1};
    NSView* card = PlaceCard(reader, table, yours, 100);
    NSView* agentCard = PlaceCard(reader, table, agents, 260);
    Check(!NSIsEmptyRect(NameArea(card)), @"your card's name can be changed");
    Check(NSIsEmptyRect(NameArea(agentCard)), @"an agent's card has no pencil");

    NSView* spot = [card valueForKey:@"nameSpot"];
    Check(!spot.hidden && NSEqualRects(spot.frame, NameArea(card)), @"your card's name has its click target over it");
    Check([[card hitTest:[card convertPoint:Middle(NameArea(card)) toView:card.superview]] isEqual:spot],
          @"a click on the name lands on it");
    Hover(spot, Middle(spot.bounds));
    Check([[card valueForKey:@"nameHovered"] boolValue], @"the pointer on your card's name shows the pencil");
    Capture(card, @"comment-card-name-hover");
    Check([[agentCard valueForKey:@"nameSpot"] isHidden], @"an agent's name has nothing to click");

    // Esc and an empty name keep the name; Return changes it.
    Click(card, Middle(NameArea(card)));
    Check(EditingName(card) && EditingField(card), @"a click on your card's name edits it");
    Capture(card, @"comment-card-name-editing");
    Type(window, @"Somebody Else");
    Escape(window);
    Check(!EditingName(card) && [[reader currentCommentAuthor] isEqualToString:you], @"Esc on a card keeps the name");
    Click(card, Middle(NameArea(card)));
    Type(window, @"");
    [EditingField(card).currentEditor setString:@""];
    Return(window);
    Check([[reader currentCommentAuthor] isEqualToString:you], @"an empty name on a card keeps the name");
    Click(card, Middle(NameArea(card)));
    Type(window, @"Mei Chen");
    Return(window);
    Check([[reader currentCommentAuthor] isEqualToString:@"Mei Chen"] && [StoredAuthor(reader) isEqualToString:@"Mei Chen"],
          [NSString stringWithFormat:@"Return on a card keeps and stores the new name (%@)", StoredAuthor(reader)]);

    // The comment keeps the name it was written under, and is not "yours" any more.
    [card setValue:yours forKey:@"item"];
    Check(NSIsEmptyRect(NameArea(card)), @"a card under the old name is not yours after the change");
    [card setValue:@{@"kind" : @"comment", @"author" : @"Mei Chen", @"body" : @"New one", @"commentIndex" : @2} forKey:@"item"];
    Check(!NSIsEmptyRect(NameArea(card)), @"a card under the new name is yours");
    [card removeFromSuperview];
    [agentCard removeFromSuperview];
}

#pragma mark - Main

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    @autoreleasepool {
        NSString* root = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"spdf-comment-author-%d-%@", getpid(), NSUUID.UUID.UUIDString]];
        NSString* state = [root stringByAppendingPathComponent:@"state"];
        NSString* home = [root stringByAppendingPathComponent:@"home"];
        for (NSString* folder in @[ state, home, [root stringByAppendingPathComponent:@"friends"] ])
            [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
        [@"version: 1\nshowShortcutHelpOnLaunch: false\nautoUpdateEnabled: false\nfriends:\n  enabled: false\n"
            writeToFile:[state stringByAppendingPathComponent:@"settings.yaml"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        setenv("SPDF_STATE_DIR", state.fileSystemRepresentation, 1);
        setenv("SZFRIENDS_STATE_DIR", [root stringByAppendingPathComponent:@"friends"].fileSystemRepresentation, 1);
        setenv("HOME", home.fileSystemRepresentation, 1);
        setenv("CFFIXED_USER_HOME", home.fileSystemRepresentation, 1);
        setenv("SPDF_NO_WINDOW_FIRST", "1", 1);
        setenv("SPDF_NO_ACTIVATE", "1", 1);
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        gOriginalOrder = method_setImplementation(class_getInstanceMethod(NSWindow.class, @selector(orderWindow:relativeTo:)),
                                                  (IMP)TransparentOrder);
        method_setImplementation(class_getInstanceMethod(NSWindow.class, @selector(constrainFrameRect:toScreen:)),
                                 (IMP)Unconstrained);

        AuthorProbeReader* reader = [AuthorProbeReader new];
        NSApp.delegate = reader;
        [reader loadPersistentState];
        [reader buildMenu];
        [reader prepareEmptyWindow];
        NSString* mac = SPDFDefaultCommentAuthor();
        Check([[reader currentCommentAuthor] isEqualToString:mac], @"the name starts as the Mac's");

        CheckBox(reader, mac);
        CheckCards(reader);

        // What the next launch reads.
        AuthorProbeReader* next = [AuthorProbeReader new];
        [next loadPersistentState];
        Check([[next currentCommentAuthor] isEqualToString:@"Mei Chen"],
              [NSString stringWithFormat:@"a new reader has the new name (%@)", [next currentCommentAuthor]]);

        for (NSWindow* w in NSApp.windows)
            Check(!w.visible || w.alphaValue == 0, @"every window stayed transparent");
        [reader.window orderOut:nil];
        [NSFileManager.defaultManager removeItemAtPath:root error:nil];
        if (!failures) puts("SPDFMacCommentAuthorProbe passed");
    }
    return failures ? 1 : 0;
}
