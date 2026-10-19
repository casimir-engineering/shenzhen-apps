#import "SPDFMacAIAnswerCardView.h"
static void RunAnswerCardViewChecks(void) {
    NSWindow* window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,400,650) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    SPDFMacAIChatView* view=[[SPDFMacAIChatView alloc] initWithFrame:window.contentView.bounds];window.contentView=view;
    NSString* link=@"spdf-ai://document?path=doc:fixture&page=1&revision=v1";
    NSDictionary* card=@{@"label":@"Full range travel",@"value":@"3.1 mm",@"citation":link};
    NSData* bytes=[NSJSONSerialization dataWithJSONObject:@{@"citation":link} options:0 error:nil];
    ChatFixture* fixture=[ChatFixture new]; fixture.status=@"";fixture.activityDetail=@"";fixture.activityState=SPDFMacAIChatActivityCompleted;
    fixture.chat=@{@"id":@"card-fixture",@"messages":@[@{@"role":@"user",@"content":@"What is the full range travel?"},
        @{@"role":@"tool",@"content":[[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding]},
        @{@"role":@"assistant",@"content":@"Full range travel: 3.1 mm",@"answerCard":card}]};
    __block NSUInteger opened=0;view.openLink=^(NSURL* URL){Check([URL.absoluteString isEqual:link],@"card preserves exact evidence destination");opened++;};
    for(NSString* appearance in @[NSAppearanceNameDarkAqua,NSAppearanceNameAqua]) {
        window.appearance=[NSAppearance appearanceNamed:appearance];
        [view displaySession:(id)fixture]; [view layoutSubtreeIfNeeded];
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.03]];[view layoutSubtreeIfNeeded];
        NSTextView* answer=(id)Find(view,@"answerCard");NSButton* evidence=(id)Find(view,@"answerEvidence");
        Check(answer && evidence && answer.selectable,@"native card has selectable answer and evidence button");
        Check([answer.accessibilityChildren containsObject:evidence],@"selectable card exposes its evidence button to accessibility clients");
        Check([evidence accessibilityPerformPress],@"evidence button supports an accessibility press");
        Check(NSContainsRect(answer.bounds,evidence.frame),@"evidence button remains inside the card");
        NSRect text=[answer.layoutManager usedRectForTextContainer:answer.textContainer];
        NSRange valueRange=[answer.string rangeOfString:@"3.1 mm"];
        NSRect value=[answer.layoutManager boundingRectForGlyphRange:[answer.layoutManager glyphRangeForCharacterRange:valueRange actualCharacterRange:NULL] inTextContainer:answer.textContainer];
        value=NSOffsetRect(value,answer.textContainerOrigin.x,answer.textContainerOrigin.y);
        Check(!NSIntersectsRect(value,evidence.frame),@"answer and evidence button never overlap");
        Check(NSHeight(answer.bounds)<115 && NSMinY(evidence.frame)<NSMaxY(value),@"short result and source action share a compact row");
        Check(fabs(NSMidY(value)-NSMidY(evidence.frame))<1,@"evidence button aligns with the answer optically");
        Check(NSMaxY(text)+answer.textContainerOrigin.y<=NSHeight(answer.bounds)-12,@"text keeps lower inset");
        Click(window,evidence,NSMakePoint(2,2));Click(window,evidence,NSMakePoint(NSWidth(evidence.bounds)-2,NSHeight(evidence.bounds)-2));
        if ([appearance isEqual:NSAppearanceNameDarkAqua]) {
            Capture(answer,@"answer-card");
            [evidence mouseEntered:nil]; Capture(answer,@"answer-card-hover"); [evidence mouseExited:nil];
            [evidence highlight:YES]; Capture(answer,@"answer-card-pressed"); [evidence highlight:NO];
        }
        Capture(view,[appearance isEqual:NSAppearanceNameAqua] ? @"answer-card-light" : @"answer-card-dark");
    }
    Check(opened==6,@"evidence clicks and accessibility presses forward the citation in both appearances");
    [view setChatSearchQuery:@"3.1"];[view layoutSubtreeIfNeeded];
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.03]];
    NSTextView* answer=(id)Find(view,@"answerCard");
    NSRange range=[answer.string rangeOfString:@"3.1"];
    Check(answer && range.location!=NSNotFound && [answer.layoutManager temporaryAttribute:NSBackgroundColorAttributeName atCharacterIndex:range.location effectiveRange:NULL],@"search highlights the exact value inside card");
    [view setChatSearchQuery:@""];[view displayChats:@[]];[view displaySession:(id)fixture];
    Check(Find(view,@"answerCard")!=nil,@"card survives hide/reopen history path");
    NSDictionary* longCard=@{@"label":@"A longer descriptive answer label that should wrap on narrow panels",@"value":@"Between 100 and 250 milliseconds",@"citation":link};
    fixture.chat=@{@"id":@"card-fixture-long",@"messages":@[[fixture.chat[@"messages"] objectAtIndex:1],
        @{@"role":@"assistant",@"content":@"Between 100 and 250 milliseconds",@"answerCard":longCard}]};
    [window setContentSize:NSMakeSize(300,650)];[view displaySession:(id)fixture];[view layoutSubtreeIfNeeded];
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.04]];[view layoutSubtreeIfNeeded];
    answer=(id)Find(view,@"answerCard");NSButton* button=(id)Find(view,@"answerEvidence");
    Check(NSMaxY([answer.layoutManager usedRectForTextContainer:answer.textContainer])+answer.textContainerOrigin.y<NSMinY(button.frame),@"long answer reflows above evidence at narrow width");
    Check(NSHeight(answer.bounds)<220,@"long fallback stays compact at minimum width");
    Capture(view,@"answer-card-narrow");[window orderOut:nil];
}
