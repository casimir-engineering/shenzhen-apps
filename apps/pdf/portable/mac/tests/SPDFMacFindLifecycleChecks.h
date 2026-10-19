#import "SPDFMacFindFailure.h"
#import "SPDFMacFindInteraction.h"
#import "SPDFMacPanelSearchChecks.h"
@implementation WorkspaceReaderProbe (FindLifecycle)
- (void)waitForFindCheck {
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:15];
    while (_findSearchInProgress && deadline.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    Check(!_findSearchInProgress,@"find finishes within its test deadline");
}
- (void)checkFindLifecycle {
    NSString* query=getenv("SPDF_FIND_PROBE_PATH") ? @"Audio" : @"workspace";
    _findQueue.maxConcurrentOperationCount=1;
    [_window makeFirstResponder:_pageView];
    NSEvent* key=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0
        windowNumber:_window.windowNumber context:nil characters:[query substringToIndex:1]
        charactersIgnoringModifiers:[query substringToIndex:1] isARepeat:NO keyCode:0];
    Check([self documentTypeToSearchKeyDown:key],@"typing in document opens Find");
    for (NSUInteger i=1;i<query.length;i++) {
        NSTextView* editor=(id)_searchField.currentEditor;
        Check(editor!=nil,@"type-to-search transfers focus into native field editor");
        [editor insertText:[query substringWithRange:NSMakeRange(i,1)] replacementRange:editor.selectedRange];
    }
    [self waitForFindCheck];
    NSUInteger expected=_findMatches.count;
    Check([_searchField.stringValue isEqual:query] && expected>0,@"native typed query returns matches");
    fprintf(stdout,"Typed %s: %lu matches\n",query.UTF8String,(unsigned long)expected);
    [self checkPanelSearchTransitions:query matches:expected];
    _searchField.stringValue=query;
    // Superseded operations must not replace the last query's results.
    for (NSUInteger i=0;i<30;i++) {
        _searchField.stringValue=i%2 ? query : @"definitely-absent-query";
        [self startFindForCurrentQueryResetSavedIndex:YES revealMatch:NO];
    }
    [self waitForFindCheck];
    Check(_findMatches.count==expected,@"rapid queries keep only the latest results");
    NSString* working=_workingPath;
    _workingPath=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [self startFindForCurrentQueryResetSavedIndex:YES revealMatch:NO]; [self waitForFindCheck];
    Check([self.findFailureMessage containsString:@"Search unavailable"] && [_findCountLabel.stringValue isEqual:@"Error"],
        @"background reopen failure is visible rather than zero matches");
    BOOL visible=NO;
    for (NSDictionary* row in _sidebarItems) if ([row[@"title"] containsString:@"Search unavailable"]) visible=YES;
    Check(visible,@"search failure appears in visible sidebar");
    _workingPath=working;
    [self startFindForCurrentQueryResetSavedIndex:YES revealMatch:NO]; [self waitForFindCheck];
    Check(!self.findFailureMessage.length && _findMatches.count==expected,@"retry clears failure and recovers matches");
    _findRegexCheckbox.state=NSControlStateValueOn; _searchField.stringValue=@"[";
    [self startFindForCurrentQueryResetSavedIndex:YES revealMatch:NO]; [self waitForFindCheck];
    Check(self.findFailureMessage.length>0 && [_findCountLabel.stringValue isEqual:@"Error"],@"invalid regex has visible failure state");
    _findRegexCheckbox.state=NSControlStateValueOff;
    [self dismissWorkspaceFind];
    Check(!self.findFailureMessage.length,@"dismiss clears failure state");
}
@end
