// Edit-and-resend controls, the summary marker and the chat actions menu.
#import "SPDFMacAIChatBudget.h"
@interface SPDFMacAIChatView (EditProbe)
- (NSMenu*)chatActionsMenu;
@end
static NSTextView* EditorIn(SPDFMacAIChatView* view) { return (NSTextView*)Find(view,@"messageEditor"); }
static void ReplaceEditorText(NSTextView* editor,NSString* text) {
    [editor selectAll:nil]; [editor insertText:text replacementRange:editor.selectedRange];
}
static BOOL EditCommand(SPDFMacAIChatView* view,NSTextView* editor,SEL command) {
    return [(id<NSTextViewDelegate>)view textView:editor doCommandBySelector:command];
}
static NSString* EditHelp(SPDFMacAIChatView* view) {
    id help=[(NSStackView*)Find(view,@"editControls") arrangedSubviews].firstObject;
    return [help isKindOfClass:NSTextField.class] ? [help stringValue] : nil;
}
static void RunChatEditChecks(void) {
    NSWindow* window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,520,640) styleMask:NSWindowStyleMaskTitled
        backing:NSBackingStoreBuffered defer:NO];
    SPDFMacAIChatView* view=[[SPDFMacAIChatView alloc] initWithFrame:window.contentView.bounds];
    window.contentView=view;
    NSArray* turns=@[@{@"role":@"user",@"content":@"Compare the boards"},
        @{@"role":@"assistant",@"content":@"Board A is larger."},
        @{@"role":@"compaction",@"local":@YES,@"summary":@"Boards compared."},
        @{@"role":@"user",@"content":@"Which uses less power?"},@{@"role":@"assistant",@"content":@"Board B."}];
    ChatFixture* fixture=[ChatFixture new]; fixture.chat=@{@"id":@"edit",@"messages":turns};
    [view displaySession:(id)fixture]; [window.contentView layoutSubtreeIfNeeded];
    NSTextField* marker=(id)Find(view,@"summaryMarker");
    Check([marker isKindOfClass:NSTextField.class] && [marker.stringValue isEqual:@"Earlier messages summarized"] &&
        ChatBodies(view).count==4,@"a short marker shows where earlier messages were summarized; every message stays");
    NSButton* editFirst=(id)Find(view,@"edit:0"); NSButton* editLater=(id)Find(view,@"edit:3");
    Check(editFirst && editLater && !Find(view,@"edit:1") && !Find(view,@"edit:4"),
        @"only your own messages offer Edit");
    Check(editLater.alphaValue==0 && editLater.image && [editLater.toolTip isEqual:@"Edit message"],
        @"Edit stays out of the way until hovered");
    SPDFChatMessageView* question=(id)ChatBodies(view)[2];
    NSEvent* (^hover)(NSEventType)=^NSEvent*(NSEventType type){
        return [NSEvent enterExitEventWithType:type location:NSZeroPoint modifierFlags:0 timestamp:0
            windowNumber:window.windowNumber context:nil eventNumber:0 trackingNumber:0 userData:NULL];
    };
    [question mouseEntered:hover(NSEventTypeMouseEntered)];
    Check(editLater.alphaValue==1,@"hovering your message reveals Edit");
    [question mouseExited:hover(NSEventTypeMouseExited)];
    Check(editLater.alphaValue==0,@"leaving your message hides Edit again");
    NSEvent* right=[NSEvent mouseEventWithType:NSEventTypeRightMouseDown location:NSMakePoint(20,20) modifierFlags:0
        timestamp:0 windowNumber:window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];
    Check([[[question menuForEvent:right] itemAtIndex:0].identifier isEqual:@"editMessage"] &&
        [[ChatBodies(view)[3] menuForEvent:right] indexOfItemWithTitle:@"Edit message"]<0,
        @"the context menu offers Edit on your messages only");
    __block NSMutableArray* actions=[NSMutableArray array];
    view.action=^(NSString* action){ [actions addObject:action]; };
    __block NSUInteger editedIndex=NSNotFound; __block NSString* editedText=nil; __block BOOL accept=NO;
    view.editMessage=^BOOL(NSUInteger index,NSString* text){ editedIndex=index; editedText=text; return accept; };
    Click(window,editLater,NSMakePoint(2,2));
    NSTextView* editor=EditorIn(view);
    Check(editor.editable && [editor.string isEqual:@"Which uses less power?"] && window.firstResponder==editor &&
        Find(view,@"editControls") && Find(view,@"editSend") && Find(view,@"editCancel") && !actions.count,
        @"Edit opens the message in place with Send and Cancel");
    Check([EditHelp(view) containsString:@"removes the messages below"],
        @"the editor says what Send does to later messages");
    ReplaceEditorText(editor,@"Draft that is cancelled");
    Check(EditCommand(view,editor,@selector(cancelOperation:)) && !EditorIn(view) && editedIndex==NSNotFound &&
        [[ChatBodies(view)[2] string] isEqual:@"Which uses less power?"],@"Cancel restores the original message");
    [(NSButton*)Find(view,@"edit:3") performClick:nil]; editor=EditorIn(view);
    ReplaceEditorText(editor,@"Which runs cooler?");
    NSMutableArray* grown=[turns mutableCopy]; [grown addObject:@{@"role":@"assistant",@"content":@"More detail."}];
    fixture.chat=@{@"id":@"edit",@"messages":grown}; [view displaySession:(id)fixture];
    Check([EditorIn(view).string isEqual:@"Which runs cooler?"] && window.firstResponder==EditorIn(view),
        @"an update to the chat keeps the edit in progress");
    Check(EditCommand(view,EditorIn(view),@selector(insertNewline:)) && editedIndex==3 &&
        [editedText isEqual:@"Which runs cooler?"] && EditorIn(view),
        @"Return sends the edit; a refused send keeps it open");
    accept=YES; [(NSButton*)Find(view,@"editSend") performClick:nil];
    Check(!EditorIn(view) && editedIndex==3 && !Find(view,@"editControls"),@"an accepted edit closes the editor");
    fixture.running=YES; [view displaySession:(id)fixture]; [(NSButton*)Find(view,@"edit:0") performClick:nil];
    Check(![actions containsObject:@"stop"] && [EditorIn(view).string isEqual:@"Compare the boards"],
        @"opening Edit while a reply is running leaves the reply running");
    Check(EditCommand(view,EditorIn(view),@selector(cancelOperation:)) && !EditorIn(view) &&
        ![actions containsObject:@"stop"],@"Cancel closes the editor and the reply keeps going");
    [(NSButton*)Find(view,@"edit:0") performClick:nil];
    fixture.chat=@{@"id":@"edit",@"messages":@[@{@"role":@"user",@"content":@"Sent elsewhere"}]};
    [view displaySession:(id)fixture]; Check(!EditorIn(view),@"an edit ends when its message no longer exists");
    fixture.activityState=SPDFMacAIChatActivitySummarizing; [view displaySession:(id)fixture];
    Check([[(NSTextField*)Find(view,@"chatStatus") stringValue] isEqual:@"Summarizing earlier messages…"],
        @"the panel says when earlier messages are being summarized");
    fixture.running=NO; fixture.canCompact=NO; fixture.activityState=SPDFMacAIChatActivityIdle;
    [view displaySession:(id)fixture];
    NSButton* more=(id)Find(view,@"more");
    NSMenuItem* compact=[[view chatActionsMenu] itemWithTitle:@"Summarize earlier messages"];
    Check(more.image && more.toolTip.length && compact && !compact.enabled,
        @"the chat menu offers summarizing, only when possible");
    fixture.canCompact=YES; compact=[[view chatActionsMenu] itemWithTitle:@"Summarize earlier messages"];
    [actions removeAllObjects]; [NSApp sendAction:compact.action to:compact.target from:compact];
    Check(compact.enabled && [actions isEqual:@[@"compact"]],@"choosing Summarize asks the session to summarize");
    // A long reply can be summarized while you edit its question; the summary moves the question down a place.
    NSArray* asked=@[@{@"role":@"user",@"content":@"Compare the boards"},@{@"role":@"assistant",@"content":@"Board A."},
        @{@"role":@"user",@"content":@"Which uses less power?"},@{@"role":@"assistant",@"content":@"Reading…"}];
    fixture.running=YES; fixture.chat=@{@"id":@"edit",@"messages":asked}; [view displaySession:(id)fixture];
    [(NSButton*)Find(view,@"edit:2") performClick:nil]; ReplaceEditorText(EditorIn(view),@"Which runs cooler?");
    NSArray* summarized=SPDFMacAICompactedMessages(asked,2,@"Boards compared.");
    fixture.chat=@{@"id":@"edit",@"messages":summarized}; [view displaySession:(id)fixture];
    Check([EditorIn(view).string isEqual:@"Which runs cooler?"] &&
        [summarized[3][@"content"] isEqual:asked[2][@"content"]],
        @"a summary made while you edit keeps the editor and what you typed");
    editedIndex=NSNotFound; accept=YES;
    Check(EditCommand(view,EditorIn(view),@selector(insertNewline:)) && editedIndex==3 &&
        [editedText isEqual:@"Which runs cooler?"],@"the edit is sent for your question where the summary moved it");
    Check(!window.visible,@"edit fixture never opens a window");
}
