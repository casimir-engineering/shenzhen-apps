#import "SPDFMacSidebarModeControl.h"

void spdf_sidebar_mode_control_set_segment_count(NSControl* control, NSInteger segmentCount,
                                                 NSInteger fallbackSegment) {
    if (!control || segmentCount <= 0) return;
    NSInteger selected = control.selectedSegment;
    if (control.segmentCount != segmentCount) control.segmentCount = segmentCount;
    // Growing keeps the selection, so there is nothing to put back; only a
    // shrink that removes the selected segment leaves it at -1.
    if (control.selectedSegment >= 0) return;
    if (selected < 0 || selected >= segmentCount) selected = fallbackSegment;
    control.selectedSegment = MAX(0, MIN(selected, segmentCount - 1));
}

@implementation NSControl (SPDFSidebarModes)
- (NSInteger)spdf_selectedSidebarMode {
    return self.selectedSegment >= 0 ? [self tagForSegment:self.selectedSegment] : SPDFSidebarModeChapters;
}
- (void)setSpdf_selectedSidebarMode:(NSInteger)mode {
    for (NSInteger i = 0; i < self.segmentCount; ++i) {
        if ([self tagForSegment:i] == mode) { self.selectedSegment = i; return; }
    }
    self.selectedSegment = self.segmentCount ? 0 : -1;
}
- (void)spdf_setEnabled:(BOOL)enabled forSidebarMode:(NSInteger)mode {
    for (NSInteger i = 0; i < self.segmentCount; ++i)
        if ([self tagForSegment:i] == mode) { [self setEnabled:enabled forSegment:i]; return; }
}
@end

void spdf_sidebar_mode_control_configure(NSControl* control, BOOL supportsComments, BOOL hasSearch) {
    spdf_sidebar_mode_control_configure_history(control, supportsComments, hasSearch, NO);
}

static void Configure(NSControl* control, BOOL supportsComments, BOOL hasSearch, BOOL hasHistory, BOOL hasGroups) {
    if (!control) return;
    NSInteger selectedMode = control.spdf_selectedSidebarMode;
    NSInteger count = 1 + supportsComments + hasSearch + hasHistory + 2*hasGroups;
    if (control.segmentCount != count) control.segmentCount = count;
    NSInteger segment = 0;
    for (NSInteger mode = SPDFSidebarModeChapters; mode <= SPDFSidebarModeChats; ++mode) {
        if ((mode == SPDFSidebarModeComments && !supportsComments) ||
            (mode == SPDFSidebarModeSearch && !hasSearch) ||
            (mode == SPDFSidebarModeHistory && !hasHistory) ||
            ((mode == SPDFSidebarModeGroups || mode == SPDFSidebarModeChats) && !hasGroups)) continue;
        [control setTag:mode forSegment:segment];
        if (mode >= SPDFSidebarModeSearch) [control setEnabled:YES forSegment:segment];
        [control setLabel:mode == SPDFSidebarModeChapters ? @"Chapters" :
                         (mode == SPDFSidebarModeComments ? @"Comments" :
                          (mode == SPDFSidebarModeSearch ? @"Search" :
                           (mode == SPDFSidebarModeHistory ? @"History" : mode == SPDFSidebarModeChats ? @"Chats" : @"Groups"))) forSegment:segment];
        ++segment;
    }
    control.spdf_selectedSidebarMode = selectedMode;
}

void spdf_sidebar_mode_control_configure_history(NSControl* control, BOOL supportsComments, BOOL hasSearch, BOOL hasHistory) {
    BOOL vertical = [control isKindOfClass:SPDFSidebarNavigationControl.class];
    Configure(control,supportsComments,hasSearch || vertical,hasHistory,vertical);
}

void spdf_sidebar_mode_control_set_document_availability(NSControl* control, BOOL hasChapters,
                                                         BOOL hasComments) {
    [control spdf_setEnabled:hasChapters forSidebarMode:SPDFSidebarModeChapters];
    [control spdf_setEnabled:hasComments forSidebarMode:SPDFSidebarModeComments];
}

void spdf_sidebar_mode_control_configure_navigation(NSControl* control, BOOL supportsComments, BOOL hasHistory) {
    Configure(control,supportsComments,YES,hasHistory,YES);
}
