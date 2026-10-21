#import "SPDFMacAIChatViewInternal.h"
#import "SPDFMacAIAnswerCard.h"
#import "SPDFMacAIAnswerCardView.h"
#import "SPDFMacAIChatSession.h"
#import "SPDFMacCollectionStyle.h"
#import "SPDFMacAIChatMarkdown.h"
#import "SPDFMacChatMarkdownView.h"
#import "SPDFMacGroupActionButton.h"
#import "SPDFMacAIChatStore.h"
#import "SPDFMacAIChatSearch.h"
#import "SPDFMacPanelSearchField.h"
#import "SPDFMacAIChatViewParts.h"
#import "SPDFMacAIChatActivityView.h"
@implementation SPDFMacAIChatView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty; [SPDFCollectionColor(@"window") setFill]; NSRectFill(self.bounds);
    [SPDFCollectionColor(@"line") setFill]; NSRectFill(NSMakeRect(0,35.5,NSWidth(self.bounds),.5));
}
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance]; self.needsDisplay=YES;
    if(_displayedSession && !_history) { _displayedMessages=nil; [self displaySession:_displayedSession]; }
}
- (void)setFrameSize:(NSSize)size {
    BOOL atBottom=_scroll && NSMaxY(_scroll.contentView.bounds)>=NSHeight(_scroll.documentView.bounds)-24;
    BOOL widthChanged=fabs(size.width-self.bounds.size.width)>.5;
    [super setFrameSize:size];
    if(widthChanged && _displayedSession) [self refreshActivityFromSession:_displayedSession];
    if(atBottom && widthChanged && !_chatSearch.stringValue.length) dispatch_async(dispatch_get_main_queue(), ^{ [self scrollToNewest]; });
}
- (NSTextView*)composer { return _composer; }
- (NSView*)banner { return _banner; }
- (void)setBanner:(NSView*)banner {
    if(banner==_banner) return;
    if(_bannerConstraints) [NSLayoutConstraint deactivateConstraints:_bannerConstraints];
    [_banner removeFromSuperview]; _banner=banner; _bannerConstraints=nil;
    _scrollBelowPrompt.active=!banner; if(!banner) return;
    banner.translatesAutoresizingMaskIntoConstraints=NO; [self addSubview:banner];
    _bannerConstraints=@[[banner.topAnchor constraintEqualToAnchor:_prompt.bottomAnchor constant:8],
        [banner.leadingAnchor constraintEqualToAnchor:_scroll.leadingAnchor],
        [banner.trailingAnchor constraintEqualToAnchor:_scroll.trailingAnchor],
        [_scroll.topAnchor constraintEqualToAnchor:banner.bottomAnchor constant:8]];
    [NSLayoutConstraint activateConstraints:_bannerConstraints];
}
- (void)setChatSearchQuery:(NSString*)query {
    _chatSearch.stringValue=query ?: @""; _displayedMessages=nil;
    if(_displayedSession) [self displaySession:_displayedSession];
}
- (NSButton*)button:(NSString*)title action:(NSString*)action {
    return SPDFChatMakeButton(title,action,self,@selector(clicked:));
}
- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self=[super initWithFrame:frame])) return nil;
    _visibleLimit=40; _expandedActivity=[NSMutableSet set]; _editIndex=NSNotFound;
    _undo=[self button:@"Undo" action:@"undo"]; _undo.enabled=NO; _undo.toolTip=@"Undo the assistant’s last action";
    _redo=[self button:@"Redo" action:@"redo"];_redo.enabled=NO;
    NSArray* buttons=@[[self button:@"Hide chat panel" action:@"close"],[self button:@"New chat" action:@"new"],_undo,_redo,
        [self button:@"AI settings" action:@"settings"],[self button:@"More chat actions" action:@"more"]];
    NSArray* symbols=@[@"sidebar.left",@"square.and.pencil",@"arrow.uturn.backward",@"arrow.uturn.forward",@"gearshape",
        @"ellipsis.circle"];
    for(NSUInteger i=0;i<buttons.count;i++){NSButton* button=buttons[i];button.image=[NSImage imageWithSystemSymbolName:symbols[i] accessibilityDescription:nil];button.title=@"";[button.widthAnchor constraintEqualToConstant:28].active=YES;}
    NSStackView* header=[NSStackView stackViewWithViews:buttons];header.spacing=8;header.translatesAutoresizingMaskIntoConstraints=NO;[self addSubview:header];
    _chatSearch=[NSSearchField new];SPDFConfigurePanelSearchField(_chatSearch);_chatSearch.placeholderString=@"Search this chat";
    _chatSearch.toolTip=@"Search this chat · Return: next match · Shift-Return: previous match";
    _chatSearch.accessibilityLabel=_chatSearch.placeholderString;_chatSearch.delegate=self;_chatSearch.translatesAutoresizingMaskIntoConstraints=NO;[self addSubview:_chatSearch];
    [NSLayoutConstraint activateConstraints:@[[_chatSearch.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
        [_chatSearch.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],[_chatSearch.topAnchor constraintEqualToAnchor:self.topAnchor constant:44],
        [_chatSearch.heightAnchor constraintEqualToConstant:30]]];
    _status=SPDFCollectionText(@"Ready for your question",13,NSFontWeightSemibold,NO);
    _status.identifier=@"chatStatus"; _status.translatesAutoresizingMaskIntoConstraints=NO; _status.maximumNumberOfLines=2; [self addSubview:_status];
    _progress=[NSProgressIndicator new]; _progress.style=NSProgressIndicatorStyleSpinning; _progress.controlSize=NSControlSizeSmall;
    _progress.displayedWhenStopped=NO; _progress.translatesAutoresizingMaskIntoConstraints=NO; [self addSubview:_progress];
    _activityDetail=SPDFCollectionText(@"Sources link to highlighted passages",12,NSFontWeightRegular,YES);
    _activityDetail.identifier=@"chatActivityDetail"; _activityDetail.maximumNumberOfLines=2;
    _activityDetail.translatesAutoresizingMaskIntoConstraints=NO; [self addSubview:_activityDetail];
    _prompt=SPDFCollectionText(@"",13,NSFontWeightMedium,NO); _prompt.identifier=@"latestUserPrompt";
    _prompt.maximumNumberOfLines=3; _prompt.cell.truncatesLastVisibleLine=YES; _prompt.selectable=YES;
    _prompt.translatesAutoresizingMaskIntoConstraints=NO;
    _promptHeight=[_prompt.heightAnchor constraintEqualToConstant:0]; [self addSubview:_prompt];
    _scroll=[NSScrollView new]; _scroll.translatesAutoresizingMaskIntoConstraints=NO;
    _scroll.automaticallyAdjustsContentInsets=NO; _scroll.contentInsets=NSEdgeInsetsZero;
    _scroll.drawsBackground=NO; _scroll.hasVerticalScroller=YES; _scroll.autohidesScrollers=YES;
    _messages=[NSStackView new]; _messages.orientation=NSUserInterfaceLayoutOrientationVertical;
    _messages.alignment=NSLayoutAttributeLeading; _messages.spacing=8; _messages.translatesAutoresizingMaskIntoConstraints=NO;
    NSView* doc=[SPDFChatFlippedView new]; doc.translatesAutoresizingMaskIntoConstraints=NO;
    [doc addSubview:_messages]; _scroll.documentView=doc; [self addSubview:_scroll];
    _chatFind=[[SPDFMacAIChatSearch alloc] initWithScrollView:_scroll messages:_messages];
    SPDFChatInputScrollView* input=[SPDFChatInputScrollView new]; _input=input; input.translatesAutoresizingMaskIntoConstraints=NO;
    input.borderType=NSNoBorder; input.contentInsets=NSEdgeInsetsMake(2,2,2,2); input.drawsBackground=YES; input.backgroundColor=NSColor.textBackgroundColor;
    input.wantsLayer=YES; input.layer.cornerRadius=8; input.hasVerticalScroller=YES; [input updateBorder];
    _composer=[[SPDFChatComposer alloc] initWithFrame:NSMakeRect(0,0,500,64)];
    _composer.font=[NSFont systemFontOfSize:13]; _composer.textColor=NSColor.labelColor;
    _composer.backgroundColor=NSColor.textBackgroundColor; _composer.richText=NO; _composer.allowsUndo=YES;
    _composer.textContainerInset=NSMakeSize(8,8); _composer.autoresizingMask=NSViewWidthSizable;
    _composer.textContainer.widthTracksTextView=YES; _composer.horizontallyResizable=NO;
    _composer.accessibilityLabel=@"Message your document assistant. Enter sends; Shift Enter adds a line.";
    input.documentView=_composer; [self addSubview:input];
    _send=[self button:@"Send ↵" action:@"send"]; _stop=[self button:@"Stop" action:@"stop"];
    [self addSubview:_send]; [self addSubview:_stop];
    NSTextField* inputHelp=SPDFCollectionText(@"↵ Send · ⇧↵ New line",11,NSFontWeightRegular,YES);
    _inputHelp=inputHelp; inputHelp.translatesAutoresizingMaskIntoConstraints=NO; [self addSubview:inputHelp];
    [inputHelp.leadingAnchor constraintEqualToAnchor:input.leadingAnchor].active=YES;
    [inputHelp.centerYAnchor constraintEqualToAnchor:_send.centerYAnchor].active=YES;
    [inputHelp.trailingAnchor constraintLessThanOrEqualToAnchor:_stop.leadingAnchor constant:-12].active=YES;
    __weak __typeof__(self) weakSelf=self;
    _composer.submit=^{ [weakSelf submit]; }; _composer.undoAction=^{ if (weakSelf.action) weakSelf.action(@"undo"); };
    _composer.redoAction=^{if(weakSelf.action)weakSelf.action(@"redo");};
    _composer.closeAction=^{if(weakSelf.action)weakSelf.action(@"close");};
    _composer.fit=^{ [weakSelf fitComposer]; };
    _issueText=SPDFCollectionText(@"",12,NSFontWeightMedium,NO); _issueText.maximumNumberOfLines=3;
    _issueText.identifier=@"chatSubmissionError";
    _recovery=[self button:@"AI settings…" action:@"settings"];
    [_recovery setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_recovery setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    _issue=[NSStackView stackViewWithViews:@[_issueText,_recovery]]; _issue.spacing=12;
    _issue.identifier=@"chatSubmissionIssue"; _issue.translatesAutoresizingMaskIntoConstraints=NO; _issue.hidden=YES;
    [self addSubview:_issue];
    // Hidden, the row keeps its 60 pt and the transcript reaches past it to 12 pt above the composer. Squeezing it to
    // 0 pt instead made AppKit break its 28 pt button's height on every layout.
    _scrollAboveIssue=[_scroll.bottomAnchor constraintEqualToAnchor:_issue.topAnchor constant:-8];
    _scrollAboveInput=[_scroll.bottomAnchor constraintEqualToAnchor:input.topAnchor constant:-12];
    _inputHeight=[input.heightAnchor constraintEqualToConstant:SPDFChatComposerHeight];
    _stopTrailing=[_stop.trailingAnchor constraintEqualToAnchor:_send.leadingAnchor constant:-8];
    _stopHistoryTrailing=[_stop.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16];
    [NSLayoutConstraint activateConstraints:@[
        [header.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [header.topAnchor constraintEqualToAnchor:self.topAnchor constant:4],
        [header.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-16],
        [_status.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [_status.trailingAnchor constraintEqualToAnchor:_progress.leadingAnchor constant:-8],
        [_status.topAnchor constraintEqualToAnchor:_chatSearch.bottomAnchor constant:12],
        [_progress.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        [_progress.centerYAnchor constraintEqualToAnchor:_status.centerYAnchor],
        [_progress.widthAnchor constraintEqualToConstant:16], [_progress.heightAnchor constraintEqualToConstant:16],
        [_activityDetail.leadingAnchor constraintEqualToAnchor:_status.leadingAnchor],
        [_activityDetail.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        [_activityDetail.topAnchor constraintEqualToAnchor:_status.bottomAnchor constant:4],
        [_prompt.topAnchor constraintEqualToAnchor:_activityDetail.bottomAnchor constant:10],
        [_prompt.leadingAnchor constraintEqualToAnchor:_status.leadingAnchor],
        [_prompt.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16], _promptHeight,
        _scrollBelowPrompt=[_scroll.topAnchor constraintEqualToAnchor:_prompt.bottomAnchor constant:8],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        _scrollAboveInput,
        [_issue.leadingAnchor constraintEqualToAnchor:input.leadingAnchor],
        [_issue.trailingAnchor constraintEqualToAnchor:input.trailingAnchor],
        [_issue.bottomAnchor constraintEqualToAnchor:input.topAnchor constant:-4],
        [_issue.heightAnchor constraintEqualToConstant:60],
        [doc.widthAnchor constraintEqualToAnchor:_scroll.contentView.widthAnchor],
        [_messages.leadingAnchor constraintEqualToAnchor:doc.leadingAnchor],
        [_messages.trailingAnchor constraintEqualToAnchor:doc.trailingAnchor constant:-8],
        [_messages.topAnchor constraintEqualToAnchor:doc.topAnchor constant:10],
        [_messages.bottomAnchor constraintEqualToAnchor:doc.bottomAnchor constant:-12],
        [input.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [input.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        _inputHeight,
        [input.bottomAnchor constraintEqualToAnchor:_send.topAnchor constant:-8],
        [_send.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        [_send.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-12],
        _stopTrailing,
        [_stop.centerYAnchor constraintEqualToAnchor:_send.centerYAnchor]
    ]];
    return self;
}
// The field grows with what is typed, a line at a time, up to its maximum; past that the text scrolls in it.
- (void)fitComposer { if(!_history) _inputHeight.constant=[(SPDFChatInputScrollView*)_input fittingHeight]; }
- (void)controlTextDidChange:(NSNotification*)note { (void)note; [self setChatSearchQuery:_chatSearch.stringValue]; }
- (BOOL)control:(NSControl*)control textView:(NSTextView*)textView doCommandBySelector:(SEL)command {
    if (control!=_chatSearch || textView.hasMarkedText || (command!=@selector(insertNewline:) && command!=@selector(insertLineBreak:) && command!=@selector(insertNewlineIgnoringFieldEditor:))) return NO;
    [_chatFind moveBy:(NSApp.currentEvent.modifierFlags & NSEventModifierFlagShift) ? -1 : 1]; return YES;
}
- (void)submit {
    NSString* text=[_composer.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!text.length || !_send.enabled) return;
    if (self.sendText && self.sendText(text)) _composer.string=@"";
}
- (void)clicked:(NSButton*)sender {
    if ([sender.identifier isEqual:@"send"]) [self submit];
    else if ([sender.identifier isEqual:@"more"])
        [[self chatActionsMenu] popUpMenuPositioningItem:nil atLocation:NSMakePoint(0,NSHeight(sender.bounds)+4)
            inView:sender];
    else if ([sender.identifier hasPrefix:@"edit:"])
        [self beginEditingMessageAtIndex:(NSUInteger)[sender.identifier substringFromIndex:5].integerValue];
    else if ([sender.identifier isEqual:@"editSend"]) [self commitEdit];
    else if ([sender.identifier isEqual:@"editCancel"]) [self endEditing];
    else if ([sender.identifier isEqual:@"older"]) {
        NSPoint origin=_scroll.contentView.bounds.origin; CGFloat height=NSHeight(_scroll.documentView.bounds); _visibleLimit+=40; _displayedMessages=nil;
        _preserveScroll=YES; [self displaySession:_displayedSession]; _preserveScroll=NO; [self layoutSubtreeIfNeeded];
        origin.y+=NSHeight(_scroll.documentView.bounds)-height;
        [_scroll.contentView scrollToPoint:origin]; [_scroll reflectScrolledClipView:_scroll.contentView];
    } else if ([sender.identifier isEqual:@"current"]) {
        if(self.action) self.action(@"current");
    } else if ([sender.identifier hasPrefix:@"citation:"]) {
        NSURL* URL=[NSURL URLWithString:[sender.identifier substringFromIndex:9]];
        if (self.openLink && SPDFMacAIChatLinkAllowed(URL)) self.openLink(URL);
    } else if (self.action) self.action(sender.identifier);
}
- (void)clearRows { for (NSView* v in [_messages.arrangedSubviews copy]) { [_messages removeArrangedSubview:v]; [v removeFromSuperview]; } }
- (void)addPreview:(NSDictionary*)preview {
    if(![preview isKindOfClass:NSDictionary.class]) return;
    NSString* caption=[preview[@"caption"] isKindOfClass:NSString.class] ? preview[@"caption"] : @"Document page";
    NSImage* image=SPDFMacAIChatStoredImage([preview[@"path"] isKindOfClass:NSString.class] ? preview[@"path"] : nil);
    if(!image) {
        [self addText:@"This page preview is no longer available. Ask to show the page again." role:caption]; return;
    }
    NSTextField* label=SPDFCollectionText(caption,11,NSFontWeightSemibold,YES); [_messages addArrangedSubview:label];
    NSImageView* view=[NSImageView new]; view.image=image; view.imageScaling=NSImageScaleProportionallyUpOrDown;
    view.accessibilityLabel=caption; view.translatesAutoresizingMaskIntoConstraints=NO; [_messages addArrangedSubview:view];
    // Below the window's stay-put priority: a page rendered wider than the transcript scales down instead of
    // widening the chat panel.
    for(NSNumber* axis in @[@(NSLayoutConstraintOrientationHorizontal),@(NSLayoutConstraintOrientationVertical)])
        [view setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
            forOrientation:(NSLayoutConstraintOrientation)axis.integerValue];
    [view.widthAnchor constraintEqualToAnchor:_messages.widthAnchor].active=YES;
    [view.heightAnchor constraintEqualToConstant:MIN(280,280*image.size.height/image.size.width)].active=YES;
    NSDictionary* citation=preview[@"citation"];
    if([citation isKindOfClass:NSDictionary.class]) {
        NSMutableArray* items=[NSMutableArray array];
        for(NSString* key in @[@"path",@"page",@"revision",@"layoutIdentity"]) if(citation[key])
            [items addObject:[NSURLQueryItem queryItemWithName:key value:[citation[key] description]]];
        NSURLComponents* URL=[NSURLComponents new]; URL.scheme=@"spdf-ai"; URL.host=@"document"; URL.queryItems=items;
        NSButton* open=[self button:@"Open this page" action:[@"citation:" stringByAppendingString:URL.string]];
        [_messages addArrangedSubview:open]; [_messages setCustomSpacing:20 afterView:open];
    }
}
- (BOOL)textView:(NSTextView*)textView clickedOnLink:(id)link atIndex:(NSUInteger)index {
    (void)textView; (void)index; NSURL* URL=[link isKindOfClass:NSURL.class] ? link : [NSURL URLWithString:[link description]];
    if (self.openLink && SPDFMacAIChatLinkAllowed(URL)) self.openLink(URL); return YES;
}
- (void)showSubmissionError:(NSString*)message { [self showSubmissionError:message recoveryAction:@"settings"]; }
- (void)showSubmissionError:(NSString*)message recoveryAction:(NSString*)action {
    _submissionError=[message copy]; _issueText.stringValue=message ?: @"";
    _recovery.identifier=action ?: @"settings";
    _recovery.title=[action isEqual:@"authorize"] ? @"Authorize & send…" : @"AI settings…";
    _recovery.accessibilityLabel=_recovery.title; _recovery.toolTip=_recovery.title;
    [_recovery invalidateIntrinsicContentSize]; [self refreshActivityFromSession:_displayedSession];
    if(message.length)NSAccessibilityPostNotification(_issueText,NSAccessibilityValueChangedNotification);
}
- (void)refreshActivityFromSession:(SPDFMacAIChatSession*)session {
    _displayedSession=session; _running=session.running;
    BOOL issueVisible=!_history && _submissionError.length>0;
    _issue.hidden=!issueVisible;
    // One at a time, so the two are never active together.
    if(issueVisible) { _scrollAboveInput.active=NO; _scrollAboveIssue.active=YES; }
    else { _scrollAboveIssue.active=NO; _scrollAboveInput.active=YES; }
    NSString* fallback=_history ? @"Chats are saved on this Mac" : @"Sources link to highlighted passages";
    SPDFMacAIChatActivityState state=session.activityState;
    NSString* title=_history ? @"Your chats" : @"Ready for your question";
    if(state==SPDFMacAIChatActivityThinking) title=@"Thinking…";
    else if(state==SPDFMacAIChatActivityWorking) title=@"Working…";  // a search or a Python run is not documents
    else if(state==SPDFMacAIChatActivityCompleted) title=@"Complete · Ready for your reply";
    else if(state==SPDFMacAIChatActivityError) title=@"Error · Review the details";
    else if(state==SPDFMacAIChatActivityPaused) title=@"Paused · Ready to continue";
    else if(state==SPDFMacAIChatActivitySummarizing) title=@"Summarizing earlier messages…";
    else if(state==SPDFMacAIChatActivityStopped) title=@"Stopped · Ready for your next message";
    _status.stringValue=issueVisible ? @"Message not sent" : title;
    // While a tool runs, what it does in the person's words; never its identifier, and nothing for one without words.
    NSString* tool=[session respondsToSelector:@selector(runningTool)] ? session.runningTool : nil;
    NSString* detail=session.activityDetail.length ? session.activityDetail : fallback;
    if(tool) detail=SPDFChatRunningToolText(tool) ?: @"";
    _activityDetail.stringValue=issueVisible ? _submissionError : detail;
    if(_chatSearch.stringValue.length && !issueVisible && !session.running) {
        NSUInteger matches=0;
        for(NSDictionary* message in session.chat[@"messages"]) {
            NSString* role=message[@"role"], *content=message[@"content"];
            if(([role isEqual:@"user"] || [role isEqual:@"assistant"]) && [content isKindOfClass:NSString.class] &&
               [content rangeOfString:_chatSearch.stringValue options:NSCaseInsensitiveSearch|NSDiacriticInsensitiveSearch].location!=NSNotFound) matches++;
        }
        _activityDetail.stringValue=matches ? [NSString stringWithFormat:@"%lu matching message%@",(unsigned long)matches,matches==1 ? @"" : @"s"] : @"No matches in this chat";
    }
    _activityDetail.toolTip=_activityDetail.stringValue;
    if(session.running) [_progress startAnimation:nil]; else [_progress stopAnimation:nil];
    NSString* latest=@"";
    for(NSDictionary* message in [session.chat[@"messages"] reverseObjectEnumerator])
        if([message[@"role"] isEqual:@"user"] && [message[@"content"] isKindOfClass:NSString.class]) { latest=message[@"content"]; break; }
    _prompt.hidden=_history || !latest.length || _chatSearch.stringValue.length;
    _prompt.stringValue=latest.length ? [@"You: " stringByAppendingString:latest] : @"";
    CGFloat promptHeight=[_prompt.stringValue boundingRectWithSize:NSMakeSize(MAX(240,self.bounds.size.width-36),CGFLOAT_MAX)
        options:NSStringDrawingUsesLineFragmentOrigin attributes:@{NSFontAttributeName:_prompt.font}].size.height;
    _promptHeight.constant=_prompt.hidden ? 0 : MIN(50,MAX(18,ceil(promptHeight)));
    _prompt.toolTip=latest; _prompt.accessibilityLabel=_prompt.stringValue;
    _status.accessibilityLabel=_status.stringValue;
    _send.enabled=!session.running && !_history; _stop.enabled=session.running; _composer.editable=!_history;
    _input.hidden=_history; _send.hidden=_history; _inputHeight.constant=0; [self fitComposer];
    _stopTrailing.active=NO; _stopHistoryTrailing.active=NO;
    (_history ? _stopHistoryTrailing : _stopTrailing).active=YES;
    _inputHelp.stringValue=_history ? @"Select a chat above, or start a new one." : @"↵ Send · ⇧↵ New line";
    _redo.enabled=[session respondsToSelector:@selector(canRedo)] && session.canRedo && !session.running;
    _undo.enabled=!session.running && [session respondsToSelector:@selector(canUndo)] && [[session valueForKey:@"canUndo"] boolValue];
    _status.textColor=NSColor.labelColor;
    NSAccessibilityPostNotification(_status,NSAccessibilityValueChangedNotification);
}
- (void)scrollToNewest {
    if (_chatSearch.stringValue.length) return;
    // Rebuilt rich rows change document height. Resolve their layout before
    // clamping the scroll origin, otherwise the first label can be half hidden.
    [self layoutSubtreeIfNeeded]; [_scroll.documentView layoutSubtreeIfNeeded];
    [_scroll.contentView scrollToPoint:NSMakePoint(0,MAX(0,NSHeight(_scroll.documentView.bounds)-NSHeight(_scroll.contentView.bounds)))]; [_scroll reflectScrolledClipView:_scroll.contentView];
}
static NSUInteger ActivityAnchor(NSDictionary* row) {
    return [row[@"entry"][SPDFMacAIActivityAnchorKey] unsignedIntegerValue];
}
// Each entry with the actions it can still take, so a handler ending (Cancel no longer possible) redraws its row;
// runs of finished steps folded (SPDFMacAIChatActivityUnits).
- (NSArray<NSDictionary*>*)activityOfSession:(SPDFMacAIChatSession*)session {
    NSMutableArray* rows=[NSMutableArray array];
    BOOL live=[session respondsToSelector:@selector(liveActivityActionsForEntry:)];
    for(id item in session.chat[@"activity"]) {
        NSDictionary* entry=SPDFMacAIActivitySanitizedEntry(item); if(!entry) continue;
        NSArray* actions=live ? [session liveActivityActionsForEntry:entry[SPDFMacAIActivityIDKey]] : @[];
        [rows addObject:@{@"entry":entry,@"actions":actions ?: @[]}];
    }
    return SPDFMacAIChatActivityUnits([rows sortedArrayWithOptions:NSSortStable
        usingComparator:^NSComparisonResult(NSDictionary* a,NSDictionary* b) {
            return [@(ActivityAnchor(a)) compare:@(ActivityAnchor(b))];
        }]);
}
- (SPDFMacAIChatActivityRow*)activityRowFor:(NSDictionary*)row session:(SPDFMacAIChatSession*)session {
    // The transcript's width: the scroll view's 16 pt margins and the message column's 8 pt trailing inset.
    SPDFMacAIChatActivityRow* view=[[SPDFMacAIChatActivityRow alloc] initWithUnit:row expanded:_expandedActivity
        width:MAX(160,NSWidth(self.bounds)-40)];
    __weak __typeof__(self) weakSelf=self; __weak SPDFMacAIChatSession* weakSession=session;
    view.perform=^(NSString* identifier,NSString* action) {
        SPDFMacAIChatSession* owner=weakSession;
        if([owner respondsToSelector:@selector(performActivityAction:forEntry:)])
            [owner performActivityAction:action forEntry:identifier];
    };
    __weak SPDFMacAIChatActivityRow* weakView=view;
    view.toggled=^(NSString* key,BOOL expanded) {
        __typeof__(self) chat=weakSelf; SPDFMacAIChatActivityRow* shown=weakView; if(!chat || !shown) return;
        if(expanded)[chat->_expandedActivity addObject:key];
        else [chat->_expandedActivity removeObject:key];
        [chat replaceActivityRow:shown with:shown.unit session:weakSession];
    };
    view.saveImage=^(NSString* path,NSString* caption){
        __typeof__(self) chat=weakSelf;
        if(chat.saveImage) chat.saveImage(path,caption); else SPDFMacAIChatSaveStoredImage(chat.window,path,caption);
    };
    view.openLink=^(NSURL* URL){ __typeof__(self) chat=weakSelf; if(chat.openLink) chat.openLink(URL); };
    return view;
}
static BOOL StepRow(NSView* view) {
    if(![view isKindOfClass:SPDFMacAIChatActivityRow.class]) return NO;
    NSDictionary* unit=((SPDFMacAIChatActivityRow*)view).unit;
    return unit[@"fold"] || [unit[@"entry"][SPDFMacAIActivityKindKey] isEqual:SPDFMacAIActivityKindStep];
}
// Steps in a row read as one block, 4 pt apart; a card, a picture or a message keeps 12 pt around it.
- (void)spaceActivityRow:(NSView*)view {
    NSArray* rows=_messages.arrangedSubviews; NSUInteger index=[rows indexOfObject:view]; if(index==NSNotFound) return;
    if(index>0 && StepRow(rows[index-1])) [_messages setCustomSpacing:StepRow(view) ? 4 : 12 afterView:rows[index-1]];
    [_messages setCustomSpacing:index+1<rows.count && StepRow(view) && StepRow(rows[index+1]) ? 4 : 12 afterView:view];
}
- (void)addActivityRow:(NSDictionary*)row session:(SPDFMacAIChatSession*)session {
    NSView* view=[self activityRowFor:row session:session]; [_messages addArrangedSubview:view];
    [view.widthAnchor constraintEqualToAnchor:_messages.widthAnchor].active=YES;
    [self spaceActivityRow:view];
}
// YES when every displayed row was matched by id and the changed ones replaced in place.
- (BOOL)replaceActivityRows:(NSArray<NSDictionary*>*)activity session:(SPDFMacAIChatSession*)session {
    NSMutableDictionary<NSString*,SPDFMacAIChatActivityRow*>* shown=[NSMutableDictionary dictionary];
    for(NSView* view in _messages.arrangedSubviews)
        if([view isKindOfClass:SPDFMacAIChatActivityRow.class])
            shown[((SPDFMacAIChatActivityRow*)view).entryID]=(id)view;
    if(_chatSearch.stringValue.length || shown.count!=activity.count) return NO;
    for(NSDictionary* row in activity) if(!shown[SPDFMacAIChatActivityUnitKey(row)]) return NO;
    for(NSDictionary* row in activity)
        if(![_displayedActivity containsObject:row])
            [self replaceActivityRow:shown[SPDFMacAIChatActivityUnitKey(row)] with:row session:session];
    _displayedActivity=activity; return YES;
}
- (void)replaceActivityRow:(SPDFMacAIChatActivityRow*)old with:(NSDictionary*)row
    session:(SPDFMacAIChatSession*)session {
    NSUInteger index=[_messages.arrangedSubviews indexOfObject:old]; if(index==NSNotFound) return;
    NSView* view=[self activityRowFor:row session:session];
    [_messages insertArrangedSubview:view atIndex:index]; [old removeFromSuperview];
    [view.widthAnchor constraintEqualToAnchor:_messages.widthAnchor].active=YES;
    [self spaceActivityRow:view];
}
- (void)displaySession:(SPDFMacAIChatSession*)session {
    NSPoint previousOrigin=_scroll.contentView.bounds.origin;
    BOOL differentChat=![_chatID isEqual:session.chat[@"id"]];
    BOOL followBottom=differentChat || !_displayedMessages || NSMaxY(_scroll.contentView.bounds)>=NSHeight(_scroll.documentView.bounds)-24;
    if(differentChat) { _visibleLimit=40; _submissionError=nil; _chatSearch.stringValue=@""; [self clearEdit]; }
    [self refreshActivityFromSession:session];
    NSArray* messages=session.chat[@"messages"];
    if(messages.count>_displayedMessages.count && [messages.lastObject[@"role"] isEqual:@"user"])followBottom=YES;
    if(!differentChat && _displayedMessages && !followBottom)
        for(NSUInteger i=_displayedMessages.count;i<messages.count;i++) {
            NSDictionary* item=messages[i];NSString* role=item[@"role"];
            if(([role isEqual:@"preview"] && [item[@"local"] boolValue]) ||
                ([@[@"user",@"assistant"] containsObject:role] && [item[@"content"] isKindOfClass:NSString.class] && [[item[@"content"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] length]))_visibleLimit++;
        }
    NSArray* activity=[self activityOfSession:session];
    BOOL sameMessages=!_history && [_chatID isEqual:session.chat[@"id"]] && [_displayedMessages isEqual:messages];
    if (sameMessages && [_displayedActivity isEqual:activity]) return;
    // A step or card changed while the messages did not: replace just those rows, not every rendered message.
    if (sameMessages && [self replaceActivityRows:activity session:session]) {
        if(followBottom && !_preserveScroll)[self scrollToNewest];
        return;
    }
    _history=NO; [self refreshActivityFromSession:session]; _chatID=session.chat[@"id"];
    BOOL editorFocused=_editor && self.window.firstResponder==_editor;
    _editor=nil; [self validateEditForMessages:messages];
    _displayedMessages=[[NSArray alloc] initWithArray:messages ?: @[] copyItems:YES]; [self clearRows];
    _displayedActivity=activity; if(differentChat)[_expandedActivity removeAllObjects];
    if (!messages.count) {
        NSTextField* empty=SPDFCollectionText(@"Ask about this document, find an answer across groups, or organize your tabs.",13,NSFontWeightRegular,YES);
        empty.maximumNumberOfLines=0; empty.identifier=@"chatEmptyState";
        empty.translatesAutoresizingMaskIntoConstraints=NO; [_messages addArrangedSubview:empty];
        [empty.widthAnchor constraintEqualToAnchor:_messages.widthAnchor].active=YES;
    } else {
        NSMutableArray* visibleMessages=[NSMutableArray array]; NSString* query=_chatSearch.stringValue;
        NSMutableArray<NSNumber*>* visibleIndexes=[NSMutableArray array];
        for(NSUInteger index=0;index<messages.count;index++) {
            NSDictionary* message=messages[index];
            BOOL local=[message[@"role"] isEqual:@"preview"] || [message[@"role"] isEqual:@"compaction"];
            BOOL preview=local && [message[@"local"] boolValue] && !query.length;
            if(!preview) {
                if(![@[@"user",@"assistant"] containsObject:message[@"role"]])continue;
                NSString* content=message[@"content"];
                NSCharacterSet* blank=NSCharacterSet.whitespaceAndNewlineCharacterSet;
                if(![content isKindOfClass:NSString.class] || ![content stringByTrimmingCharactersInSet:blank].length)
                    continue;
                NSStringCompareOptions options=NSCaseInsensitiveSearch|NSDiacriticInsensitiveSearch;
                if(query.length && [content rangeOfString:query options:options].location==NSNotFound)continue;
            }
            [visibleMessages addObject:message]; [visibleIndexes addObject:@(index)]; // the index anchors activity
        }
        NSUInteger first=!query.length && visibleMessages.count>_visibleLimit ? visibleMessages.count-_visibleLimit : 0;
        if(first)[_messages addArrangedSubview:[self button:@"Show older messages" action:@"older"]];
        // Activity sits after the messages it followed; rows before the first message shown stay with the older ones.
        NSArray* rows=query.length ? @[] : activity; NSUInteger nextRow=0;
        NSUInteger shownFrom=first && first<visibleIndexes.count ? visibleIndexes[first].unsignedIntegerValue : 0;
        while(nextRow<rows.count && ActivityAnchor(rows[nextRow])<shownFrom) nextRow++;
        for(NSUInteger i=first;i<visibleMessages.count;i++) {
            NSDictionary* message=visibleMessages[i];
            for(;nextRow<rows.count && ActivityAnchor(rows[nextRow])<=visibleIndexes[i].unsignedIntegerValue;nextRow++)
                [self addActivityRow:rows[nextRow] session:session];
            NSString* role=message[@"role"];
            if([role isEqual:@"preview"])[self addPreview:message[@"preview"]];
            else if([role isEqual:@"compaction"])[self addSummaryMarker];
            else if (SPDFMacAIValidatedAnswerCard(message[@"answerCard"],session.chat)) {
                NSView* card=[[SPDFMacAIAnswerCardView alloc] initWithCard:message[@"answerCard"] width:NSWidth(self.bounds)-48 openLink:self.openLink];
                [_messages addArrangedSubview:card]; [card.widthAnchor constraintEqualToAnchor:_messages.widthAnchor].active=YES;
            } else if([role isEqual:@"user"])
                [self addText:message[@"content"] role:@"You" messageIndex:visibleIndexes[i].unsignedIntegerValue];
            else [self addText:message[@"content"] role:@"Assistant"];
        }
        for(;nextRow<rows.count;nextRow++)[self addActivityRow:rows[nextRow] session:session];
    }
    if (editorFocused) [self focusEditor];
    [_chatFind updateQuery:_chatSearch.stringValue];
    if (_chatSearch.stringValue.length) return;
    if(!_preserveScroll && followBottom) {
        [self scrollToNewest];
        dispatch_async(dispatch_get_main_queue(), ^{ [self scrollToNewest]; });
    } else if(!_preserveScroll) {
        [self layoutSubtreeIfNeeded];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self layoutSubtreeIfNeeded];
            if (self->_chatSearch.stringValue.length) return;
            [self->_scroll.contentView scrollToPoint:previousOrigin];
            [self->_scroll reflectScrolledClipView:self->_scroll.contentView];
        });
    }
}
- (void)displayChats:(NSArray<NSDictionary*>*)chats {
    [_chatFind updateQuery:@""];
    if(self.window.firstResponder==_composer) [self.window makeFirstResponder:nil];
    [self clearEdit];
    _history=YES; _send.enabled=NO; _stop.enabled=_running; _composer.editable=NO; [self clearRows]; _status.stringValue=@"Chats are saved on this Mac";
    if(_displayedSession) [self refreshActivityFromSession:_displayedSession];
    [_messages addArrangedSubview:[self button:@"Return to current chat" action:@"current"]];
    NSButton* deleteAll=[self button:@"Delete all chats…" action:@"deleteAll"]; deleteAll.enabled=chats.count>0;
    [_messages addArrangedSubview:deleteAll];
    if (!chats.count) [self addText:@"No conversations yet. Start a new chat to ask about your documents." role:@"Chats"];
    for (NSDictionary* chat in chats) {
        NSButton* open=[self button:chat[@"title"] action:[@"load:" stringByAppendingString:chat[@"id"]]];
        open.lineBreakMode=NSLineBreakByTruncatingTail; open.alignment=NSTextAlignmentLeft;
        NSButton* remove=[self button:@"Delete" action:[@"delete:" stringByAppendingString:chat[@"id"]]];
        NSStackView* row=[NSStackView stackViewWithViews:@[open,remove]]; row.spacing=8; [_messages addArrangedSubview:row];
        [row.widthAnchor constraintEqualToAnchor:_messages.widthAnchor].active=YES;
        [open.widthAnchor constraintEqualToAnchor:row.widthAnchor constant:-76].active=YES;
    }
    [self scrollToNewest];
    dispatch_async(dispatch_get_main_queue(), ^{ [self scrollToNewest]; });
}
@end
