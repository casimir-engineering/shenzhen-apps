// Attachments in the chat panel: files and folders dropped anywhere on it, or chosen with the paperclip (Attach files,
// as in Friends' composer), become this chat's grants (SPDFMacAIChatGrants.h); a row of chips above the composer shows
// them, each with a button that removes it. The composer passes file drops here instead of typing their paths.
#import "SPDFMacAIChatViewInternal.h"
#import "SPDFMacCollectionStyle.h"

static NSArray<NSURL*>* SPDFDroppedURLs(NSPasteboard* board) {
    return [board readObjectsForClasses:@[ NSURL.class ] options:@{NSPasteboardURLReadingFileURLsOnlyKey : @YES}] ?: @[];
}

// One attachment: its kind's symbol, its name, and a button that removes it.
@interface SPDFChatAttachmentChip : NSView
@end
@implementation SPDFChatAttachmentChip
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSBezierPath* shape = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, .5, .5) xRadius:6 yRadius:6];
    [SPDFCollectionColor(@"pane") setFill];
    [shape fill];
    [SPDFCollectionColor(@"line") setStroke];
    [shape stroke];
}
- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance]; self.needsDisplay = YES; }
@end

// The chips, wrapped onto as many lines as they need (at most four; past that the rest are clipped), then the note.
// It asks for its own height through `height`, which the chat view's row constraint follows.
@interface SPDFChatAttachmentFlow : NSView
@property(nonatomic, weak) NSLayoutConstraint* height;
@end
@implementation SPDFChatAttachmentFlow
- (BOOL)isFlipped { return YES; }
- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds), x = 0, y = 0, line = 24, gap = 6;
    NSUInteger shown = 0;
    for (NSView* item in self.subviews) {
        if (item.hidden) continue;
        NSSize size = [item isKindOfClass:NSTextField.class] ? item.fittingSize : item.subviews.firstObject.fittingSize;
        size.width = MIN(ceil(size.width), width);
        size.height = [item isKindOfClass:NSTextField.class] ? 16 : line;
        if (x > 0 && x + size.width > width) { x = 0; y += line + gap; }
        item.frame = NSMakeRect(x, y + (line - size.height) / 2, size.width, size.height);
        x += size.width + gap;
        shown++;
    }
    CGFloat needed = shown ? MIN(y + line, 4 * line + 3 * gap) : 0;
    NSLayoutConstraint* height = self.height;
    if (height && fabs(height.constant - needed) > .5)
        dispatch_async(dispatch_get_main_queue(), ^{ height.constant = needed; });
}
@end

@implementation SPDFMacAIChatView (Attachments)

- (void)setUpAttachments {
    _attach = [self button:@"Attach files" action:@"attach"];
    _attach.target = self;
    _attach.action = @selector(chooseAttachments:);
    _attach.image = [NSImage imageWithSystemSymbolName:@"paperclip" accessibilityDescription:nil];
    _attach.title = @"";
    _attach.toolTip = @"Attach files or folders. The assistant in this chat can read them.";
    _attach.accessibilityLabel = @"Attach files";
    [_attach.widthAnchor constraintEqualToConstant:28].active = YES;
    [self addSubview:_attach];
    SPDFChatAttachmentFlow* row = [SPDFChatAttachmentFlow new];
    row.identifier = @"chatAttachments";
    row.translatesAutoresizingMaskIntoConstraints = NO;
    _attachmentNote = SPDFCollectionText(@"", 11, NSFontWeightRegular, YES);
    _attachmentNote.identifier = @"chatAttachmentNote";
    _attachmentNote.maximumNumberOfLines = 1;
    _attachmentNote.cell.truncatesLastVisibleLine = YES;
    _attachmentNote.translatesAutoresizingMaskIntoConstraints = YES;
    [row addSubview:_attachmentNote];
    _attachmentRow = row;
    [self addSubview:row];
    _attachmentRowHeight = [row.heightAnchor constraintEqualToConstant:0];
    row.height = _attachmentRowHeight;
    // The row sits between the transcript (or a problem shown above the composer) and the composer; empty, it takes
    // no room and the transcript keeps its 12 pt gap.
    for (NSLayoutConstraint* constraint in self.constraints) {
        BOOL helpLeading = constraint.firstItem == _inputHelp && constraint.firstAttribute == NSLayoutAttributeLeading;
        BOOL issueBottom = constraint.firstItem == _issue && constraint.firstAttribute == NSLayoutAttributeBottom;
        if (helpLeading || issueBottom) constraint.active = NO;
    }
    _scrollAboveInput.active = NO;
    _scrollAboveInput = [_scroll.bottomAnchor constraintEqualToAnchor:row.topAnchor constant:-6];
    [NSLayoutConstraint activateConstraints:@[
        _scrollAboveInput, _attachmentRowHeight,
        [row.leadingAnchor constraintEqualToAnchor:_input.leadingAnchor],
        [row.trailingAnchor constraintEqualToAnchor:_input.trailingAnchor],
        [row.bottomAnchor constraintEqualToAnchor:_input.topAnchor constant:-6],
        [_issue.bottomAnchor constraintEqualToAnchor:row.topAnchor constant:-4],
        [_attach.leadingAnchor constraintEqualToAnchor:_input.leadingAnchor],
        [_attach.centerYAnchor constraintEqualToAnchor:_send.centerYAnchor],
        [_inputHelp.leadingAnchor constraintEqualToAnchor:_attach.trailingAnchor constant:8],
    ]];
    [self registerForDraggedTypes:@[ NSPasteboardTypeFileURL ]];
}

- (void)chooseAttachments:(id)sender {
    (void)sender;
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = YES;
    panel.prompt = @"Attach";
    panel.message = @"The assistant in this chat can read what you attach, and all a folder holds.";
    __weak __typeof__(self) weakSelf = self;
    void (^done)(NSModalResponse) = ^(NSModalResponse response) {
        if (response == NSModalResponseOK) [weakSelf attachURLs:panel.URLs];
    };
    if (self.window) [panel beginSheetModalForWindow:self.window completionHandler:done];
    else done([panel runModal]);
}

- (BOOL)attachURLs:(NSArray<NSURL*>*)URLs {
    if (!URLs.count || _history || !self.attachFiles) return NO;
    NSString* problem = self.attachFiles(URLs);
    _attachmentNote.stringValue = problem.length ? [problem componentsSeparatedByString:@"\n"].firstObject : @"";
    _attachmentNote.toolTip = problem;
    [self refreshAttachmentRow];
    return problem.length == 0;
}

- (void)showAttachments:(NSArray<NSDictionary*>*)grants {
    if (![grants isKindOfClass:NSArray.class]) grants = @[];
    // Files the assistant saved are this chat's to read back, not something the person attached: no chip.
    grants = [grants filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary* grant,
        NSDictionary* bindings) { (void)bindings; return ![grant isKindOfClass:NSDictionary.class] || ![grant[@"saved"] boolValue]; }]];
    _attach.hidden = _history;
    if ([grants isEqual:_shownAttachments]) return;
    _shownAttachments = [grants copy];
    for (NSView* view in _attachmentRow.subviews.copy) if (view != _attachmentNote) [view removeFromSuperview];
    for (NSDictionary* grant in grants)
        [_attachmentRow addSubview:[self chipForGrant:grant] positioned:NSWindowBelow relativeTo:_attachmentNote];
    if (grants.count) _attachmentNote.stringValue = @"";
    [self refreshAttachmentRow];
}

- (void)refreshAttachmentRow {
    _attachmentNote.hidden = !_attachmentNote.stringValue.length;
    BOOL empty = !_shownAttachments.count && _attachmentNote.hidden;
    _attachmentRow.hidden = empty;
    if (empty) _attachmentRowHeight.constant = 0;
    _attachmentRow.needsLayout = YES;
}

- (NSView*)chipForGrant:(NSDictionary*)grant {
    BOOL folder = [grant[@"kind"] isEqual:@"folder"];
    NSString* name = [grant[@"name"] isKindOfClass:NSString.class] ? grant[@"name"] : @"";
    SPDFChatAttachmentChip* chip = [SPDFChatAttachmentChip new];
    chip.identifier = grant[@"id"];
    chip.toolTip = folder ? @"The assistant in this chat can read this folder and everything in it."
                          : @"The assistant in this chat can read this file.";
    chip.translatesAutoresizingMaskIntoConstraints = YES;
    NSImageView* symbol = [NSImageView imageViewWithImage:
        [NSImage imageWithSystemSymbolName:folder ? @"folder" : @"doc" accessibilityDescription:nil]];
    symbol.contentTintColor = NSColor.secondaryLabelColor;
    NSTextField* label = SPDFCollectionText(name, 12, NSFontWeightRegular, NO);
    label.maximumNumberOfLines = 1;
    label.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [label.widthAnchor constraintLessThanOrEqualToConstant:180].active = YES;
    NSButton* remove = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"xmark"
                                                           accessibilityDescription:nil]
                                          target:self action:@selector(removeAttachmentChip:)];
    remove.bordered = NO;
    remove.identifier = grant[@"id"];
    remove.toolTip = @"Remove. The assistant can no longer read it.";
    remove.accessibilityLabel = [@"Remove " stringByAppendingString:name];
    NSStackView* parts = [NSStackView stackViewWithViews:@[ symbol, label, remove ]];
    parts.spacing = 4;
    parts.edgeInsets = NSEdgeInsetsMake(0, 8, 0, 6);
    parts.translatesAutoresizingMaskIntoConstraints = NO;
    [chip addSubview:parts];
    // The chip's frame comes from the row's layout (SPDFChatAttachmentFlow), sized to its parts; the parts may never
    // force it, so a chip narrower than its name, or not yet laid out, breaks no constraint.
    NSLayoutConstraint* trailing = [parts.trailingAnchor constraintEqualToAnchor:chip.trailingAnchor];
    trailing.priority = NSLayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [parts.leadingAnchor constraintEqualToAnchor:chip.leadingAnchor], trailing,
        [parts.centerYAnchor constraintEqualToAnchor:chip.centerYAnchor],
        [symbol.widthAnchor constraintEqualToConstant:14], [remove.widthAnchor constraintEqualToConstant:14]]];
    chip.frame = NSMakeRect(0, 0, ceil(parts.fittingSize.width), 24);
    chip.accessibilityElement = YES;
    chip.accessibilityRole = NSAccessibilityGroupRole;
    chip.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", name, folder ? @"attached folder" : @"attached file"];
    return chip;
}

- (void)removeAttachmentChip:(NSButton*)sender {
    if (self.removeAttachment && sender.identifier.length) self.removeAttachment(sender.identifier);
}

#pragma mark Drops anywhere on the chat

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    return !_history && self.attachFiles && SPDFDroppedURLs(sender.draggingPasteboard).count ? NSDragOperationCopy
                                                                                             : NSDragOperationNone;
}
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender { return [self draggingEntered:sender]; }
- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender { return [self draggingEntered:sender] != NSDragOperationNone; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSArray* URLs = SPDFDroppedURLs(sender.draggingPasteboard);
    if (!URLs.count) return NO;
    [self attachURLs:URLs];
    return YES;
}

@end

// The composer is a text view, which would type a dropped file's path; files go to the chat as attachments instead.
@implementation SPDFChatComposer (Attachments)
- (SPDFMacAIChatView*)attachmentChat {
    NSView* view = self.superview;
    while (view && ![view isKindOfClass:SPDFMacAIChatView.class]) view = view.superview;
    return (SPDFMacAIChatView*)view;
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    if (SPDFDroppedURLs(sender.draggingPasteboard).count) return [self.attachmentChat draggingEntered:sender];
    return [super draggingEntered:sender];
}
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    if (SPDFDroppedURLs(sender.draggingPasteboard).count) return [self.attachmentChat draggingUpdated:sender];
    return [super draggingUpdated:sender];
}
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    if (SPDFDroppedURLs(sender.draggingPasteboard).count) return [self.attachmentChat performDragOperation:sender];
    return [super performDragOperation:sender];
}
@end
