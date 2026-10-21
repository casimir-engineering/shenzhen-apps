// An answer that couldn't be used (cut off, unreadable, empty): the panel says so in the person's words and offers
// Retry, which asks the latest question again (the "retry" action, SPDFMacAIIntegration.mm).
static void CheckRetryRow(SPDFMacAIChatView* view,ChatFixture* fixture) {
    void (^previous)(NSString*)=view.action; __block NSString* asked=nil;
    view.action=^(NSString* action) { asked=action; };
    fixture.activityState=SPDFMacAIChatActivityError; fixture.running=NO; fixture.canRetry=YES;
    fixture.status=@"The assistant's answer got cut off. Try again."; fixture.activityDetail=fixture.status;
    [view displaySession:(id)fixture]; [view layoutSubtreeIfNeeded];
    NSView* issue=Find(view,@"chatSubmissionIssue"); NSButton* retry=(id)Find(view,@"retry");
    NSTextField* text=(id)Find(view,@"chatSubmissionError");
    NSString* shown=[@[[(NSTextField*)Find(view,@"chatStatus") stringValue],
        [(NSTextField*)Find(view,@"chatActivityDetail") stringValue],text.stringValue ?: @""]
        componentsJoinedByString:@" "];
    Check(!issue.hidden && [text.stringValue isEqual:fixture.status] && [retry.title isEqual:@"Retry"] &&
        !retry.hiddenOrHasHiddenAncestor && NSContainsRect(view.bounds,[issue convertRect:issue.bounds toView:view]),
        @"an answer that got cut off is explained beside a Retry button");
    Check([shown containsString:@"Not finished"] && [shown containsString:@"Your chat is saved."] &&
        [shown rangeOfString:@"JSON" options:NSCaseInsensitiveSearch].location==NSNotFound &&
        [shown rangeOfString:@"Error" options:NSCaseInsensitiveSearch].location==NSNotFound,
        @"the panel says what happened, not how");
    [retry performClick:nil];
    Check([asked isEqual:@"retry"],@"Retry asks for the latest question to be sent again");
    fixture.canRetry=NO; [view displaySession:(id)fixture];
    Check(issue.hidden && [[(NSTextField*)Find(view,@"chatStatus") stringValue] containsString:@"Error"],
        @"without Retry, an error shows as before");
    view.action=previous;
}
