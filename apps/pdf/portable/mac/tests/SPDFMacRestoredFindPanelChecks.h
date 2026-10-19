static void CheckRestoredFindPanel(ShenzhenMacDelegate* reader) {
    NSSearchField* search=[reader valueForKey:@"searchField"];
    SPDFSidebarNavigationControl* modes=[reader valueForKey:@"sidebarModeControl"];
    modes.spdf_selectedSidebarMode=SPDFSidebarModeGroups;
    [reader setValue:@YES forKey:@"sidebarPreferredVisible"];
    search.stringValue=@"workspace";
    [reader startFindForCurrentQueryResetSavedIndex:NO revealMatch:NO];
    Check(modes.spdf_selectedSidebarMode==SPDFSidebarModeGroups,@"saved search starts without replacing Groups");
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:10];
    while(([[reader valueForKey:@"findSearchInProgress"] boolValue] || ([reader isMarkdownActive] && !reader.activeMarkdownSession.searchMatches.count)) && deadline.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    Check(![[reader valueForKey:@"findSearchInProgress"] boolValue] && ([reader isMarkdownActive] ? reader.activeMarkdownSession.searchMatches.count : [[reader valueForKey:@"findMatches"] count])>0,
        @"saved query restores real search results in the background");
    Check(modes.spdf_selectedSidebarMode==SPDFSidebarModeGroups,@"search completion keeps Groups visible");
    [reader startFindForCurrentQueryResetSavedIndex:YES revealMatch:NO];
    Check(modes.spdf_selectedSidebarMode==SPDFSidebarModeSearch,@"explicit search still opens Find");
    search.stringValue=@"";
    [reader startFindForCurrentQueryResetSavedIndex:NO revealMatch:NO];
    modes.spdf_selectedSidebarMode=SPDFSidebarModeChapters;
    [reader rebuildSidebar];
}
