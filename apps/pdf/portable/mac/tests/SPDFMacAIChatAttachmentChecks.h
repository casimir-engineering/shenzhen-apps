// Attachments in the chat view (SPDFMacAIChatAttachments.mm): files dropped on the chat or on its composer reach
// attachFiles, never the composer's text; the chat's grants show as chips above the composer, a folder as a folder,
// each removable; a problem shows in the row. Included by SPDFMacAIChatViewTests.mm after ChatFixture, Check, Capture
// and ConstraintWatchWindow.
#pragma once

@interface AttachmentFixture : ChatFixture
@property(nonatomic) NSArray* grants;
@end
@implementation AttachmentFixture @end

// What a drop gives the view: a pasteboard holding file URLs.
@interface AttachmentDrop : NSObject
@property(nonatomic) NSPasteboard* draggingPasteboard;
@end
@implementation AttachmentDrop
- (NSDragOperation)draggingSourceOperationMask { return NSDragOperationCopy; }
@end

static AttachmentDrop* AttachmentDropOf(NSArray<NSURL*>* URLs) {
    AttachmentDrop* drop = [AttachmentDrop new];
    drop.draggingPasteboard = [NSPasteboard pasteboardWithUniqueName];
    [drop.draggingPasteboard clearContents];
    [drop.draggingPasteboard writeObjects:URLs];
    return drop;
}

static NSArray<NSView*>* AttachmentChips(NSView* view) {
    NSMutableArray* chips = [NSMutableArray array];
    for (NSView* sub in Find(view, @"chatAttachments").subviews)
        if ([NSStringFromClass(sub.class) isEqual:@"SPDFChatAttachmentChip"]) [chips addObject:sub];
    return chips;
}

static void RunChatAttachmentChecks(void) {
    NSString* key = @"NSConstraintBasedLayoutVisualizeMutuallyExclusiveConstraints";
    [NSUserDefaults.standardUserDefaults registerDefaults:@{key : @YES}];
    ConstraintWatchWindow* window = [[ConstraintWatchWindow alloc] initWithContentRect:NSMakeRect(0, 0, 420, 620)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    SPDFMacAIChatView* view = [[SPDFMacAIChatView alloc] initWithFrame:window.contentView.bounds];
    window.contentView = view;
    NSMutableArray* received = [NSMutableArray array], *removed = [NSMutableArray array];
    __block NSString* reply = nil;
    view.attachFiles = ^NSString*(NSArray<NSURL*>* URLs) { [received addObjectsFromArray:URLs]; return reply; };
    view.removeAttachment = ^(NSString* identifier) { [removed addObject:identifier]; };
    AttachmentFixture* fixture = [AttachmentFixture new];
    fixture.chat = @{@"id" : @"attach", @"messages" : @[ @{@"role" : @"user", @"content" : @"Hello"},
                                                         @{@"role" : @"assistant", @"content" : @"Hi."} ]};
    [view displaySession:(id)fixture];
    [view layoutSubtreeIfNeeded];
    NSView* transcript = [view valueForKey:@"scroll"], *input = view.composer.enclosingScrollView;
    CGFloat bottom = NSMaxY(transcript.frame);
    NSButton* paperclip = nil;
    for (NSView* sub in view.subviews)
        if ([sub isKindOfClass:NSButton.class] && [sub.accessibilityLabel isEqual:@"Attach files"]) paperclip = (id)sub;
    Check(paperclip && !paperclip.hidden && NSMinX(paperclip.frame) <= NSMinX(input.frame) + .5 &&
          NSMinY(paperclip.frame) > NSMaxY(input.frame),
          @"a paperclip, Attach files, sits under the composer at its leading edge");
    Check(!AttachmentChips(view).count && fabs(NSMinY(input.frame) - bottom - 12) < .5,
          @"with nothing attached, the transcript keeps its 12 pt gap above the composer");

    NSURL* pdf = [NSURL fileURLWithPath:@"/tmp/plates.pdf"], *csv = [NSURL fileURLWithPath:@"/tmp/data.csv"];
    NSURL* blob = [NSURL fileURLWithPath:@"/tmp/capture.raw"];
    AttachmentDrop* drop = AttachmentDropOf(@[ pdf, csv, blob ]);
    Check([view draggingEntered:(id)drop] == NSDragOperationCopy && [view performDragOperation:(id)drop] &&
          [received isEqual:(@[ pdf, csv, blob ])], @"files dropped on the chat are attached, several at once");
    [received removeAllObjects];
    view.composer.string = @"Draft";
    NSTextView* composer = view.composer;
    Check([composer draggingEntered:(id)AttachmentDropOf(@[ csv ])] == NSDragOperationCopy &&
          [composer performDragOperation:(id)AttachmentDropOf(@[ csv ])] && [received isEqual:@[ csv ]] &&
          [composer.string isEqual:@"Draft"],
          @"a file dropped on the composer is attached, and its path is never typed into the draft");

    fixture.grants = @[ @{@"id" : @"attachment:1", @"name" : @"plates.pdf", @"kind" : @"file"},
                        @{@"id" : @"attachment:2", @"name" : @"data.csv", @"kind" : @"file"},
                        @{@"id" : @"attachment:3", @"name" : @"Captures", @"kind" : @"folder"} ];
    [view displaySession:(id)fixture];
    [view layoutSubtreeIfNeeded];
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
    [view layoutSubtreeIfNeeded];
    NSArray* chips = AttachmentChips(view);
    NSView* row = Find(view, @"chatAttachments");
    Check(chips.count == 3 && [[chips[2] accessibilityLabel] isEqual:@"Captures, attached folder"] &&
          [[chips[0] accessibilityLabel] isEqual:@"plates.pdf, attached file"],
          @"each grant is a chip, a folder shown as a folder");
    Check(row && NSMaxY(row.frame) <= NSMinY(input.frame) && NSMaxY(transcript.frame) <= NSMinY(row.frame) &&
          NSHeight(row.frame) >= 24, @"the chips sit between the transcript and the composer");
    Capture(view, @"attachments");
    [window setContentSize:NSMakeSize(300, 620)];
    [view layoutSubtreeIfNeeded];
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
    [view layoutSubtreeIfNeeded];
    CGFloat right = 0;
    for (NSView* chip in chips) right = MAX(right, NSMaxX(chip.frame));
    Check(NSHeight(row.frame) > 40 && right <= NSWidth(row.frame) + .5 && NSMaxY(row.frame) <= NSMinY(input.frame),
          @"in a narrow panel the chips wrap onto another line, every one in view");
    Capture(view, @"attachments-narrow");
    [window setContentSize:NSMakeSize(420, 620)];
    [view layoutSubtreeIfNeeded];
    NSButton* remove = nil;
    for (NSView* part in [[chips[1] subviews].firstObject subviews])
        if ([part isKindOfClass:NSButton.class]) remove = (id)part;
    [remove performClick:nil];
    Check([removed isEqual:@[ @"attachment:2" ]] && [remove.accessibilityLabel isEqual:@"Remove data.csv"],
          @"a chip's button removes that grant");
    reply = @"Library: This is one of the Mac’s own folders. Attach a folder of your documents instead.";
    [view attachURLs:@[ [NSURL fileURLWithPath:@"/Library"] ]];
    Check([[(NSTextField*)Find(view, @"chatAttachmentNote") stringValue] hasPrefix:@"Library: This is one"],
          @"what could not be attached is said beside the chips");
    fixture.grants = @[];
    [view displaySession:(id)fixture];
    [view layoutSubtreeIfNeeded];
    Check(!AttachmentChips(view).count, @"removed grants leave no chip");
    [view displayChats:@[]];
    Check(paperclip.hidden, @"the chat list has no paperclip");
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
    Check(!window.conflicts, @"attachments lay out without breaking a constraint");
    [NSUserDefaults.standardUserDefaults registerDefaults:@{key : @NO}];
}
