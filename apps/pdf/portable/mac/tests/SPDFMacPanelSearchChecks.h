@interface WorkspaceReaderProbe (PanelSearchTestHost)
- (BOOL)firstResponderIsEditingText;
- (void)waitForFindCheck;
@end
// Exercise the native shared field editor: a panel filter must relinquish it
// before a printable document key can start Find.
static NSSearchField* ActivePanelFilter(NSView* view,NSSearchField* documentFind) {
    if (view.hidden) return nil;
    if ([view isKindOfClass:NSSearchField.class] && view!=documentFind) return (id)view;
    for (NSView* child in view.subviews) { NSSearchField* found=ActivePanelFilter(child,documentFind); if(found) return found; }
    return nil;
}
@implementation WorkspaceReaderProbe (PanelSearchTransitions)
- (void)checkPanelSearchTransitions:(NSString*)query matches:(NSUInteger)expected {
    for (NSNumber* mode in @[@(SPDFSidebarModeChapters),@(SPDFSidebarModeGroups),@(SPDFSidebarModeComments)]) {
        [self dismissWorkspaceFind];
        _sidebarModeControl.spdf_selectedSidebarMode=mode.integerValue; _sidebarPreferredVisible=YES;
        [self rebuildSidebar]; [_window.contentView layoutSubtreeIfNeeded];
        NSSearchField* field=ActivePanelFilter(_sidebarContainer,_searchField);
        Check(field!=nil,@"panel exposes its filter field"); if(!field) continue;
        Check([field.cell class]==[_searchField.cell class] && field.font.pointSize==_searchField.font.pointSize,
            @"all panel search fields share their cell and font");
        Check(fabs(NSHeight(field.frame)-NSHeight(_searchField.frame))<.5,@"panel search field heights match");
        [_window makeFirstResponder:field]; NSTextView* editor=(id)field.currentEditor;
        Check(editor!=nil,@"panel filter uses the real field editor");
        [editor insertText:@"no-such-heading-or-group" replacementRange:NSMakeRange(0,editor.string.length)];
        BOOL handled=[field.delegate respondsToSelector:@selector(control:textView:doCommandBySelector:)] && [field.delegate control:field textView:editor doCommandBySelector:@selector(cancelOperation:)];
        Check(handled,@"Escape is handled by panel filter");
        Check(![self firstResponderIsEditingText],@"Escape from panel filter returns focus to document");
        NSEvent* key=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0
            windowNumber:_window.windowNumber context:nil characters:[query substringToIndex:1]
            charactersIgnoringModifiers:[query substringToIndex:1] isARepeat:NO keyCode:0];
        BOOL started=[self documentTypeToSearchKeyDown:key];
        Check(started,@"typing after panel-filter Escape starts document Find");
        if (!started) { [_window makeFirstResponder:_pageView]; continue; }
        editor=(id)_searchField.currentEditor;
        for(NSUInteger i=1;i<query.length;i++) [editor insertText:[query substringWithRange:NSMakeRange(i,1)] replacementRange:editor.selectedRange];
        [self waitForFindCheck];
        Check([_searchField.stringValue isEqual:query] && _findMatches.count==expected,@"panel-filter Escape then document typing returns all matches");
    }
}
@end
