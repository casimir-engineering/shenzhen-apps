// The transcript's message rows (SPDFMacAIChatViewInternal.h): each message, your own with Edit; the editor that takes
// a question's place to ask again from there; the marker where earlier messages were summarized; and the chat
// actions menu.
#import "SPDFMacAIChatViewInternal.h"
#import "SPDFMacAIChatSession.h"
#import "SPDFMacCollectionStyle.h"
#import "SPDFMacAIChatMarkdown.h"

@implementation SPDFChatMarkdownMessageView {
    NSTrackingArea* _hoverArea;
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if(self.hoverButton && ![self.trackingAreas containsObject:_hoverArea])
        [self addTrackingArea:_hoverArea=SPDFChatHoverArea(self)];
}
- (void)mouseEntered:(NSEvent*)event { [super mouseEntered:event]; [self.hoverButton setRevealed:YES]; }
- (void)mouseExited:(NSEvent*)event { [super mouseExited:event]; [self.hoverButton setRevealed:NO]; }
- (NSMenu*)menuForEvent:(NSEvent*)event {
    NSMenu* menu=[super menuForEvent:event] ?: [NSMenu new];
    if(!self.editAction) return menu;
    NSMenuItem* edit=[[NSMenuItem alloc] initWithTitle:@"Edit message" action:@selector(editFromMenu:)
        keyEquivalent:@""];
    edit.target=self; edit.identifier=@"editMessage";
    [menu insertItem:edit atIndex:0]; [menu insertItem:NSMenuItem.separatorItem atIndex:1]; return menu;
}
- (void)editFromMenu:(id)sender { (void)sender; if(self.editAction) self.editAction(); }
@end

@implementation SPDFMacAIChatView (Messages)
- (void)addText:(NSString*)text role:(NSString*)role { [self addText:text role:role messageIndex:NSNotFound]; }
// `index` is the position of one of your own messages in the chat; those rows can be edited.
- (void)addText:(NSString*)text role:(NSString*)role messageIndex:(NSUInteger)index {
    if (index!=NSNotFound && index==_editIndex) { [self addEditorWithRole:role]; return; }
    // The reader's Markdown engine at chat scale (SPDFMacChatMarkdown.h): wide tables, code and diagrams scroll
    // sideways inside the bubble, remote images wait for Load image, links keep the chat's allow-list.
    SPDFChatMarkdownMessageView* view=[[SPDFChatMarkdownMessageView alloc] initWithMarkdown:text
        width:MAX(120,self.bounds.size.width-48) options:SPDFMacAIChatMarkdownOptions()];
    if (![view.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length) return;
    NSTextField* label=SPDFCollectionText(role,11,NSFontWeightSemibold,YES);
    SPDFChatButton* edit=index!=NSNotFound ? [self editButtonForMessageAtIndex:index] : nil;
    NSView* heading=edit ? [[SPDFChatRoleRow alloc] initWithLabel:label editButton:edit] : label;
    [_messages addArrangedSubview:heading];
    if (edit) [heading.widthAnchor constraintEqualToAnchor:_messages.widthAnchor].active=YES;
    if (edit) {
        view.hoverButton=edit; __weak __typeof__(self) weakSelf=self;
        view.editAction=^{ [weakSelf beginEditingMessageAtIndex:index]; };
    }
    view.delegate=self; view.accessibilityLabel=role;
    view.backgroundColor=SPDFCollectionColor([role isEqual:@"You"] ? @"selected" : @"control");
    [_messages addArrangedSubview:view];
    [view.widthAnchor constraintEqualToAnchor:_messages.widthAnchor].active=YES; view.contentHeight.active=YES;
    [_messages setCustomSpacing:16 afterView:view];
}
- (NSMenu*)chatActionsMenu {
    NSMenu* menu=[NSMenu new]; menu.autoenablesItems=NO;
    NSMenuItem* compact=[menu addItemWithTitle:@"Summarize earlier messages" action:@selector(menuAction:)
        keyEquivalent:@""];
    compact.target=self; compact.representedObject=@"compact"; compact.identifier=@"compact";
    compact.toolTip=@"The assistant continues from a short summary of earlier messages. They stay visible here.";
    SPDFMacAIChatSession* session=_displayedSession;
    compact.enabled=!_history && [session respondsToSelector:@selector(canCompact)] && session.canCompact;
    return menu;
}
- (void)menuAction:(NSMenuItem*)item { if (self.action) self.action(item.representedObject); }
- (void)addSummaryMarker {
    NSTextField* marker=SPDFChatSummaryMarker(); [_messages addArrangedSubview:marker];
    [marker.widthAnchor constraintEqualToAnchor:_messages.widthAnchor].active=YES;
    [_messages setCustomSpacing:16 afterView:marker];
}
- (SPDFChatButton*)editButtonForMessageAtIndex:(NSUInteger)index {
    NSString* action=[NSString stringWithFormat:@"edit:%lu",(unsigned long)index];
    SPDFChatButton* edit=(SPDFChatButton*)[self button:@"Edit message" action:action];
    edit.image=[NSImage imageWithSystemSymbolName:@"pencil" accessibilityDescription:nil]; edit.title=@"";
    // A compact target keeps the speaker label's line height.
    for (NSLayoutConstraint* c in edit.constraints) if (c.firstAttribute==NSLayoutAttributeHeight) c.constant=22;
    [edit.widthAnchor constraintEqualToConstant:22].active=YES; return edit;
}
- (void)addEditorWithRole:(NSString*)role {
    NSDictionary* attributes=@{NSFontAttributeName:[NSFont systemFontOfSize:13],
        NSForegroundColorAttributeName:NSColor.labelColor};
    NSTextField* label=SPDFCollectionText(role,11,NSFontWeightSemibold,YES); [_messages addArrangedSubview:label];
    SPDFChatMessageView* view=[[SPDFChatMessageView alloc]
        initWithFrame:NSMakeRect(0,0,MAX(120,self.bounds.size.width-48),40)];
    view.verticallyResizable=NO; view.horizontallyResizable=NO; view.selectable=YES; view.drawsBackground=NO;
    view.delegate=self; view.textContainerInset=NSMakeSize(10,8); view.textContainer.lineFragmentPadding=0;
    view.textContainer.widthTracksTextView=YES;
    [view.textStorage setAttributedString:[[NSAttributedString alloc] initWithString:_editDraft ?: @""
        attributes:attributes]];
    [view.layoutManager ensureLayoutForTextContainer:view.textContainer];
    CGFloat height=ceil(NSMaxY([view.layoutManager usedRectForTextContainer:view.textContainer]));
    view.translatesAutoresizingMaskIntoConstraints=NO; [_messages addArrangedSubview:view];
    [view.widthAnchor constraintEqualToAnchor:_messages.widthAnchor].active=YES;
    view.contentHeight=[view.heightAnchor constraintEqualToConstant:MAX(18,height)+2*view.textContainerInset.height];
    view.contentHeight.active=YES;
    _editor=view; view.identifier=@"messageEditor"; view.editable=YES; view.richText=NO; view.allowsUndo=YES;
    view.typingAttributes=attributes; view.backgroundColor=NSColor.textBackgroundColor;
    view.accessibilityLabel=@"Edit your message. Return sends; Escape cancels.";
    BOOL later=_editIndex+1<[_displayedSession.chat[@"messages"] count];
    NSTextField* help=SPDFCollectionText(later ? @"Sending removes the messages below and asks again from here." : @"",
        11,NSFontWeightRegular,YES);
    help.maximumNumberOfLines=2;
    [help setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
        forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView* controls=[NSStackView stackViewWithViews:@[help,[self button:@"Cancel" action:@"editCancel"],
        [self button:@"Send ↵" action:@"editSend"]]];
    controls.spacing=8; controls.identifier=@"editControls"; controls.translatesAutoresizingMaskIntoConstraints=NO;
    [_messages setCustomSpacing:6 afterView:view]; [_messages addArrangedSubview:controls];
    [controls.widthAnchor constraintEqualToAnchor:_messages.widthAnchor].active=YES;
    [_messages setCustomSpacing:16 afterView:controls];
}
- (void)focusEditor {
    SPDFChatMessageView* editor=_editor; if (!editor) return;
    [self layoutSubtreeIfNeeded]; [self.window makeFirstResponder:editor];
    editor.selectedRange=NSMakeRange(editor.string.length,0); [editor scrollRectToVisible:editor.bounds];
}
- (void)validateEditForMessages:(NSArray*)messages {
    // A summary moves the message being edited down; the edit ends only if it changed or disappeared.
    if (_editIndex==NSNotFound) return;
    _editIndex=SPDFChatEditedMessageIndex(messages,_editPlace,_editOriginal);
    if (_editIndex==NSNotFound) [self clearEdit];
}
- (void)clearEdit { _editIndex=NSNotFound; _editOriginal=nil; _editDraft=nil; _editor=nil; }
- (void)redisplayKeepingPosition {
    if (!_displayedSession || _history) return;
    _displayedMessages=nil; _preserveScroll=YES; [self displaySession:_displayedSession]; _preserveScroll=NO;
}
- (void)beginEditingMessageAtIndex:(NSUInteger)index {
    NSArray* messages=_displayedSession.chat[@"messages"];
    if (_history || index>=messages.count || ![messages[index][@"role"] isEqual:@"user"] ||
        ![messages[index][@"content"] isKindOfClass:NSString.class]) return;
    _editIndex=index; _editPlace=SPDFChatMessagePlace(messages,index);
    _editOriginal=[messages[index][@"content"] copy]; _editDraft=_editOriginal;
    // A reply in progress keeps going until the edited question is sent; Cancel leaves it untouched.
    [self redisplayKeepingPosition]; [self focusEditor];
}
- (void)endEditing {
    BOOL focused=_editor && self.window.firstResponder==_editor;
    [self clearEdit]; [self redisplayKeepingPosition];
    if (focused) [self.window makeFirstResponder:_composer];
}
- (void)commitEdit {
    NSString* text=[_editDraft stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (_editIndex==NSNotFound || !text.length) { NSBeep(); return; }
    if (!self.editMessage || !self.editMessage(_editIndex,text)) return;
    [self clearEdit]; _displayedMessages=nil; [self displaySession:_displayedSession];
    [self.window makeFirstResponder:_composer];
}
- (void)textDidChange:(NSNotification*)note {
    if (note.object!=_editor) return;
    _editDraft=[_editor.string copy]; [_editor remeasure];
}
- (BOOL)textView:(NSTextView*)textView doCommandBySelector:(SEL)command {
    if (textView!=_editor || textView.hasMarkedText) return NO;
    if (command==@selector(cancelOperation:)) { [self endEditing]; return YES; }
    BOOL shift=(NSApp.currentEvent.modifierFlags & NSEventModifierFlagShift)!=0;
    if (command==@selector(insertNewline:) && !shift) { [self commitEdit]; return YES; }
    return NO;
}
@end
