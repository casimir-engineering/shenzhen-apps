#import "SPDFMacIconGeometry.h"
#import "SPDFMacChromeColors.h"
#import "SPDFMacPastedImageState.h"
#import "SPDFMacHeaderDragView.h"
#import "SPDFMacWorkspaceChrome.h"
#import "SPDFMacPanelSearchField.h"
#import "SPDFMacFindInteraction.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacSidebarModeControl.h"
#import "SPDFMacSidebarWorkspace.h"
#import "SPDFMacSidebarChapters.h"
#import "SPDFMacCollectionIntegration.h"
#import "SPDFMacCollectionReaderNavigation.h"
#import "SPDFMacWorkspacePanels.h"
#import "SPDFMacCollectionStyle.h"
#import <objc/runtime.h>

// One compact header per column. The renderer and real minimap retain their
// existing hosts; only the chrome is moved, so no page coordinates change.
static char chromeKey;
@interface SPDFWorkspaceChromeState : NSObject
@property NSView* mapHeader;
@property NSView* searchControls;
@property NSButton* command;
@property NSButton* collection;
@property NSButton* print;
@property NSButton* imageColors;
@property NSButton* previous;
@property NSButton* next;
@property NSLayoutConstraint* toolbarRight;
@property NSLayoutConstraint* headerWidth;
@property NSView* sourcePill;
@property NSTextField* sourceStatus;
@property NSTextField* outlineSummary;
@property NSLayoutConstraint* sidebarBottom;
@property NSStackView* primaryRow;
@property NSStackView* headerRow;
@property NSStackView* toolsRow;
@property NSArray<NSView*>* tools;
@property BOOL wrapped;
@property NSLayoutConstraint* statusSpace;
@property NSArray<NSLayoutConstraint*>* wrappedWidths;
@end
@implementation SPDFWorkspaceChromeState
@end

// Explicit icon drawing keeps inactive windows legible and gives every direct
// action the same optical size, while NSButton keeps its normal input/AX behavior.
@interface SPDFWorkspaceIconCell : NSButtonCell
@end
@implementation SPDFWorkspaceIconCell
- (NSCellHitResult)hitTestForEvent:(NSEvent*)event inRect:(NSRect)frame ofView:(NSView*)view {
    (void)frame;
    return self.enabled && NSPointInRect([view convertPoint:event.locationInWindow fromView:nil],view.bounds)
        ? NSCellHitContentArea | NSCellHitTrackableArea : NSCellHitNone;
}
- (void)drawWithFrame:(NSRect)frame inView:(NSView*)view {
    NSBezierPath* shape = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(frame,1,1) xRadius:6 yRadius:6];
    if (self.highlighted) { [SPDFCollectionColor(@"selected") setFill]; [shape fill]; }
    NSImage* image = SPDFChromeSymbolImage(self.image,SPDFToolbarSymbolPointSize,NSFontWeightRegular,SPDFChromeIconColor(self.enabled));
    SPDFDrawVectorIcon(image,NSInsetRect(frame,1,1),view.isFlipped);
    if (view.window.firstResponder == view) {
        [NSGraphicsContext saveGraphicsState]; NSSetFocusRingStyle(NSFocusRingOnly); [shape fill]; [NSGraphicsContext restoreGraphicsState];
    }
}
@end
static void StyleIcon(NSButton* button) {
    NSImage* image = button.image; NSString* title = button.title;
    id target = button.target; SEL action = button.action; BOOL enabled = button.enabled;
    SPDFWorkspaceIconCell* cell = [[SPDFWorkspaceIconCell alloc] initImageCell:image];
    cell.title = title; cell.bordered = NO; cell.imagePosition = NSImageOnly;
    button.cell = cell; button.target = target; button.action = action; button.enabled = enabled;
    SPDFConfigureIconButtonRendering(button);
}
@interface SPDFWorkspaceIconButton : NSButton
@end
@implementation SPDFWorkspaceIconButton
- (void)setBordered:(BOOL)bordered {
    [super setBordered:bordered]; SPDFConfigureIconButtonRendering(self);
}
- (void)viewDidChangeBackingProperties { [super viewDidChangeBackingProperties]; self.needsDisplay=YES; }
- (NSEdgeInsets)alignmentRectInsets { return NSEdgeInsetsMake(0,0,0,0); }
- (NSView*)hitTest:(NSPoint)point {
    return !self.hidden && NSPointInRect([self convertPoint:point fromView:self.superview],self.bounds) ? self : nil;
}
- (void)mouseDown:(NSEvent*)event {
    if(!self.enabled) return;
    [self highlight:YES];
    for(;;) {
        NSEvent* next=[self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged|NSEventMaskLeftMouseUp
            untilDate:NSDate.distantFuture inMode:NSEventTrackingRunLoopMode dequeue:YES];
        if(!next) break;
        BOOL inside=NSPointInRect([self convertPoint:next.locationInWindow fromView:nil],self.bounds);
        [self highlight:inside];
        if(next.type==NSEventTypeLeftMouseUp) {
            [self highlight:NO];
            if(inside) [self sendAction:self.action to:self.target];
            break;
        }
    }
    [self highlight:NO];
}
- (BOOL)acceptsFirstMouse:(NSEvent*)event { (void)event; return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
@end
static NSButton* Icon(NSString* symbol, NSString* title, id target, SEL action) {
    NSImage* image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
    [image setTemplate:YES];
    NSButton* button = [SPDFWorkspaceIconButton buttonWithImage:image target:target action:action];
    StyleIcon(button); button.bordered = NO; button.toolTip = title; button.accessibilityLabel = title;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.widthAnchor constraintEqualToConstant:24].active = YES;
    [button.heightAnchor constraintEqualToConstant:24].active = YES;
    return button;
}
@interface ShenzhenMacDelegate (WorkspaceActions)
- (void)showFavoritesPalette:(id)sender;
- (void)printDocument:(id)sender;
- (void)toggleSidebar:(id)sender;
- (void)toggleMinimap:(id)sender;
- (void)previousPage:(id)sender;
- (void)nextPage:(id)sender;
@end
@implementation ShenzhenMacDelegate (SPDFMacWorkspaceChrome)
- (void)installWorkspaceChrome {
    SPDFWorkspaceChromeState* state = [SPDFWorkspaceChromeState new];
    objc_setAssociatedObject(self,&chromeKey,state,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SPDFSidebarNavigationControl* navigation = (id)_sidebarModeControl;
    [navigation setCollapseTarget:self action:@selector(toggleSidebar:)];
    _window.backgroundColor = SPDFCollectionColor(@"titlebar");
    NSView* sidebarHeader = [SPDFHeaderDragView new]; sidebarHeader.translatesAutoresizingMaskIntoConstraints = NO;
    [_sidebarContainer addSubview:sidebarHeader positioned:NSWindowBelow relativeTo:_sidebarModeControl];
    [NSLayoutConstraint activateConstraints:@[
        [sidebarHeader.leadingAnchor constraintEqualToAnchor:_sidebarContainer.leadingAnchor],
        [sidebarHeader.trailingAnchor constraintEqualToAnchor:_sidebarContainer.trailingAnchor],
        [sidebarHeader.topAnchor constraintEqualToAnchor:_sidebarContainer.topAnchor],
        [sidebarHeader.bottomAnchor constraintEqualToAnchor:_sidebarModeControl.bottomAnchor]]];
    for (NSView* host in @[_sidebarContainer,_toolbar]) {
        NSView* surface = SPDFCollectionSurface(host == _sidebarContainer ? @"sidebar" : @"window"); surface.translatesAutoresizingMaskIntoConstraints = NO;
        [host addSubview:surface positioned:NSWindowBelow relativeTo:nil];
        [NSLayoutConstraint activateConstraints:@[[surface.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
            [surface.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
            [surface.topAnchor constraintEqualToAnchor:host.topAnchor],
            [surface.bottomAnchor constraintEqualToAnchor:host.bottomAnchor]]];
    }
    for (NSSearchField* field in @[_sidebarFilterField,_searchField]) {
        SPDFConfigurePanelSearchField(field);
        [field.heightAnchor constraintEqualToConstant:30].active = YES;
    }
    for (NSLayoutConstraint* constraint in _sidebarContainer.constraints)
        if (constraint.firstItem == _sidebarFilterField && constraint.firstAttribute == NSLayoutAttributeLeading)
            constraint.constant = 8;
    state.outlineSummary = SPDFCollectionText(@"",11,NSFontWeightRegular,YES);
    state.outlineSummary.translatesAutoresizingMaskIntoConstraints = NO;
    [_sidebarContainer addSubview:state.outlineSummary];
    [NSLayoutConstraint activateConstraints:@[
        [state.outlineSummary.leadingAnchor constraintEqualToAnchor:_sidebarContainer.leadingAnchor constant:16],
        [state.outlineSummary.trailingAnchor constraintEqualToAnchor:_sidebarContainer.trailingAnchor constant:-12],
        [state.outlineSummary.bottomAnchor constraintEqualToAnchor:_sidebarContainer.bottomAnchor constant:-10]]];
    for (NSLayoutConstraint* constraint in _sidebarContainer.constraints)
        if (constraint.firstItem == _sidebarTable.enclosingScrollView && constraint.firstAttribute == NSLayoutAttributeBottom)
            state.sidebarBottom = constraint;
    _sidebarTable.backgroundColor = NSColor.clearColor; _sidebarTable.enclosingScrollView.drawsBackground = NO;
    _toolbar.edgeInsets = NSEdgeInsetsMake(4,8,4,8); _toolbar.spacing = 4;
    // Replace the crowded global toolbar with document controls; Cmd+F's real
    // field now lives in the Find panel, keeping search state and its delegate.
    for (NSView* view in _toolbar.arrangedSubviews.copy) { [_toolbar removeArrangedSubview:view]; [view removeFromSuperview]; }
    _pageField.bordered = NO; _pageField.drawsBackground = NO;
    _pageField.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
    _pageCountLabel.font = _pageField.font;
    for (NSLayoutConstraint* c in _pageField.constraints) if (c.firstAttribute == NSLayoutAttributeWidth) c.constant = 30;
    _fitModePopup.bordered = NO; _fitModePopup.font = [NSFont systemFontOfSize:12];
    StyleIcon(_ocrButton); StyleIcon(_translateButton);
    for (NSSegmentedControl* control in @[_zoomSegments,_markdownFontSizeSegments]) {
        control.segmentStyle = NSSegmentStyleRounded;
        [(NSCell*)control.cell setBordered:NO];
        for (NSInteger segment=0; segment<control.segmentCount; segment++) [control setWidth:28 forSegment:segment];
        [control.heightAnchor constraintEqualToConstant:28].active = YES;
    }
    _zoomSegments.accessibilityLabel = @"Document zoom";
    _markdownFontSizeSegments.accessibilityLabel = @"Text size";
    _readingThemeButton.segmentStyle = NSSegmentStyleSeparated;
    [(NSCell*)_readingThemeButton.cell setBordered:NO];
    state.previous = Icon(@"chevron.left",@"Previous page",self,@selector(previousPage:));
    state.next = Icon(@"chevron.right",@"Next page",self,@selector(nextPage:));
    state.collection = Icon(@"books.vertical",@"Collection",self,@selector(showCollectionManager:));
    state.print = Icon(@"printer",@"Print document",self,@selector(printDocument:));
    NSStackView* counter = [NSStackView stackViewWithViews:@[_pageField,_pageCountLabel]];
    counter.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    counter.alignment = NSLayoutAttributeFirstBaseline; counter.spacing = 2;
    state.primaryRow = [NSStackView stackViewWithViews:@[_sidebarToggleButton,state.previous,counter,state.next,_fitModePopup,_zoomSegments,_markdownFontSizeSegments,_toolbarSpacer]];
    [_toolbarSpacer.heightAnchor constraintEqualToConstant:28].active=YES;
    state.statusSpace=[_toolbarSpacer.widthAnchor constraintGreaterThanOrEqualToConstant:0];
    state.statusSpace.active=YES;
    state.imageColors=Icon(@"photo",@"Invert image colors · ⇧⌘I",self,@selector(toggleDarkThemePreservesImages:));
    state.tools = @[state.collection,_readingThemeButton,state.imageColors,_ocrButton,_translateButton,state.print];
    state.toolsRow = [NSStackView stackViewWithViews:state.tools];
    for (NSStackView* row in @[state.primaryRow,state.toolsRow]) {
        row.orientation = NSUserInterfaceLayoutOrientationHorizontal; row.alignment = NSLayoutAttributeCenterY;
        row.spacing = 4; row.translatesAutoresizingMaskIntoConstraints = NO;

    }
    [state.primaryRow setCustomSpacing:8 afterView:state.next];
    [state.primaryRow setCustomSpacing:12 afterView:_zoomSegments];
    state.headerRow = [NSStackView stackViewWithViews:@[state.primaryRow,state.toolsRow]];
    state.headerRow.spacing = 4; state.headerRow.alignment = NSLayoutAttributeCenterY;
    state.headerRow.translatesAutoresizingMaskIntoConstraints = NO;
    [_toolbar addArrangedSubview:state.headerRow];
    state.headerWidth = [state.headerRow.widthAnchor constraintEqualToAnchor:_toolbar.widthAnchor constant:-16];
    state.headerWidth.active = YES;
    state.wrappedWidths=@[[state.primaryRow.widthAnchor constraintEqualToAnchor:state.headerRow.widthAnchor],
                          [state.toolsRow.widthAnchor constraintEqualToAnchor:state.headerRow.widthAnchor]];
    _toolbar.orientation = NSUserInterfaceLayoutOrientationVertical; _toolbar.alignment = NSLayoutAttributeLeading;
    [state.primaryRow setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [state.toolsRow setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];

    state.mapHeader = [SPDFHeaderDragView new]; state.mapHeader.translatesAutoresizingMaskIntoConstraints = NO;
    [_documentContainer addSubview:state.mapHeader];
    [NSLayoutConstraint activateConstraints:@[
        [state.mapHeader.topAnchor constraintEqualToAnchor:_documentContainer.topAnchor],
        [state.mapHeader.leadingAnchor constraintEqualToAnchor:_minimapView.leadingAnchor],
        [state.mapHeader.trailingAnchor constraintEqualToAnchor:_minimapView.trailingAnchor],
        [state.mapHeader.heightAnchor constraintEqualToConstant:36]]];
    // Keep one control alive at one position. Swapping hidden controls under a
    // stationary pointer leaves AppKit's mouse target pointing at the old view.
    [_minimapToggleButton removeFromSuperview];
    _minimapToggleButton.identifier = @"WorkspaceMapToggle";
    [_documentContainer addSubview:_minimapToggleButton positioned:NSWindowAbove relativeTo:nil];
    [NSLayoutConstraint activateConstraints:@[
        [_minimapToggleButton.trailingAnchor constraintEqualToAnchor:_documentContainer.trailingAnchor constant:-8],
        [_minimapToggleButton.topAnchor constraintEqualToAnchor:_documentContainer.topAnchor constant:4],
        [_minimapToggleButton.widthAnchor constraintEqualToConstant:28],
        [_minimapToggleButton.heightAnchor constraintEqualToConstant:28]]];
    [_documentContainer addSubview:_minimapDividerView positioned:NSWindowAbove relativeTo:nil];
    state.toolbarRight = [_toolbar.trailingAnchor constraintEqualToAnchor:_pageScrollView.trailingAnchor];
    state.toolbarRight.active = YES;

    state.command = Icon(@"magnifyingglass",@"Find documents, groups and text · ⌘K",self,@selector(showFavoritesPalette:));
    [_window.contentView addSubview:state.command];
    [NSLayoutConstraint activateConstraints:@[
        [state.command.trailingAnchor constraintEqualToAnchor:_window.contentView.trailingAnchor constant:-8],
        [state.command.centerYAnchor constraintEqualToAnchor:_tabStrip.centerYAnchor]]];

    state.searchControls = [NSView new]; state.searchControls.translatesAutoresizingMaskIntoConstraints = NO;
    [_sidebarContainer addSubview:state.searchControls];
    for (NSLayoutConstraint* c in _searchField.constraints.copy)
        if (c.firstAttribute == NSLayoutAttributeWidth) c.active = NO;
    _searchField.placeholderString = @"Find in document";
    [state.searchControls addSubview:_searchField];
    NSStackView* options = [NSStackView stackViewWithViews:@[_findRegexCheckbox,_findCountLabel,_findSegments]];
    options.spacing = 4; options.translatesAutoresizingMaskIntoConstraints = NO;
    [state.searchControls addSubview:options];
    [NSLayoutConstraint activateConstraints:@[
        [state.searchControls.leadingAnchor constraintEqualToAnchor:_sidebarContainer.leadingAnchor constant:8],
        [state.searchControls.trailingAnchor constraintEqualToAnchor:_sidebarContainer.trailingAnchor constant:-8],
        [state.searchControls.topAnchor constraintEqualToAnchor:_sidebarModeControl.bottomAnchor constant:8],
        [state.searchControls.heightAnchor constraintEqualToConstant:66],
        [_searchField.topAnchor constraintEqualToAnchor:state.searchControls.topAnchor],
        [_searchField.leadingAnchor constraintEqualToAnchor:state.searchControls.leadingAnchor],
        [_searchField.trailingAnchor constraintEqualToAnchor:state.searchControls.trailingAnchor],
        [_searchField.heightAnchor constraintEqualToConstant:30],
        [options.topAnchor constraintEqualToAnchor:_searchField.bottomAnchor constant:6],
        [_findRegexCheckbox.heightAnchor constraintEqualToConstant:24],
        [options.leadingAnchor constraintEqualToAnchor:state.searchControls.leadingAnchor],
        [options.trailingAnchor constraintLessThanOrEqualToAnchor:state.searchControls.trailingAnchor]]];
    _sidebarScrollBelowModeConstraint.constant = 82;
    // Status updates keep their existing model for jobs and errors, but the
    // redundant page/zoom footer no longer consumes reader height.
    state.sourcePill = SPDFCollectionSurface(@"control");
    state.sourcePill.identifier = @"WorkspaceSourcePill";
    state.sourcePill.translatesAutoresizingMaskIntoConstraints = NO;
    state.sourcePill.wantsLayer = YES; state.sourcePill.layer.cornerRadius = 7;
    [_sidebarContainer addSubview:state.sourcePill];
    state.sourceStatus = SPDFCollectionText(@"",11,NSFontWeightRegular,YES);
    state.sourceStatus.translatesAutoresizingMaskIntoConstraints = NO;
    [state.sourcePill addSubview:state.sourceStatus];
    [NSLayoutConstraint activateConstraints:@[
        [state.sourcePill.leadingAnchor constraintEqualToAnchor:_sidebarContainer.leadingAnchor constant:12],
        [state.sourcePill.trailingAnchor constraintEqualToAnchor:_sidebarContainer.trailingAnchor constant:-12],
        [state.sourcePill.bottomAnchor constraintEqualToAnchor:_sidebarContainer.bottomAnchor constant:-8],
        [state.sourcePill.heightAnchor constraintEqualToConstant:26],
        [state.sourceStatus.leadingAnchor constraintEqualToAnchor:state.sourcePill.leadingAnchor constant:8],
        [state.sourceStatus.trailingAnchor constraintEqualToAnchor:state.sourcePill.trailingAnchor constant:-8],
        [state.sourceStatus.centerYAnchor constraintEqualToAnchor:state.sourcePill.centerYAnchor]]];
    [self syncWorkspaceChrome];
}
- (void)syncWorkspaceChrome {
    SPDFWorkspaceChromeState* state = objc_getAssociatedObject(self,&chromeKey); if (!state) return;
    ((SPDFSidebarNavigationControl*)_sidebarModeControl).documentTitle = spdf_tab_display_name([self selectedTab]) ?: [self selectedTab].path.lastPathComponent ?: _path.lastPathComponent ?: @"No document";
    BOOL chapters = _sidebarModeControl.spdf_selectedSidebarMode == SPDFSidebarModeChapters;
    SPDFDocumentTab* tab = [self selectedTab];
    BOOL saved = [self collectionTabIsSavedVersion:tab];
    BOOL copy = _sidebarModeControl.spdf_selectedSidebarMode!=SPDFSidebarModeChats && (saved || tab.readOnly || SPDFPathIsUnsavedPastedImage(tab.path));
    state.sourcePill.hidden = !copy || _presentationMode;
    state.sourceStatus.stringValue = saved ? @"Collection document" :
        tab.readOnly ? @"Working copy · Read-only" : @"Unsaved image";
    state.sourceStatus.toolTip = state.sourceStatus.stringValue;
    state.outlineSummary.hidden = !chapters || copy;
    state.outlineSummary.stringValue = chapters ? [self sidebarOutlineSummary] : @"";
    state.sidebarBottom.constant = (chapters || copy) ? -42 : 0;
    // History and Groups use their own hosts. Reserve the same bottom slot in
    // every mode so their final row/actions never sit beneath the source pill.
    for(NSLayoutConstraint* constraint in _sidebarContainer.constraints)
        if(constraint.firstAttribute==NSLayoutAttributeBottom &&
           [constraint.firstItem isKindOfClass:NSView.class] &&
           [((NSView*)constraint.firstItem).identifier isEqual:@"WorkspaceSidebarBody"])
            constraint.constant = copy ? -42 : 0;
    state.searchControls.hidden = _sidebarModeControl.spdf_selectedSidebarMode != SPDFSidebarModeSearch;
    state.mapHeader.hidden = !_minimapVisible || _presentationMode;
    state.command.hidden = _presentationMode;
    _markdownFontSizeSegments.hidden = ![self isMarkdownActive];
    state.headerWidth.constant = _minimapVisible ? -16 : -48;
    state.statusSpace.constant=saved ? 154 : 0;
    BOOL wrapped = NSWidth(_toolbar.bounds) > 0 && NSWidth(_toolbar.bounds)-(_minimapVisible ? 0 : 32) < ([self isMarkdownActive] ? 632 : 564)+(saved ? 154 : 0);
    if (state.wrapped != wrapped) {
        [NSLayoutConstraint deactivateConstraints:state.wrappedWidths];
        NSStackView* oldHost=state.wrapped ? state.toolsRow : state.primaryRow;
        [oldHost removeArrangedSubview:_toolbarSpacer]; [_toolbarSpacer removeFromSuperview];
        if (wrapped) [state.toolsRow insertArrangedSubview:_toolbarSpacer atIndex:0];
        else [state.primaryRow addArrangedSubview:_toolbarSpacer];
        state.wrapped = wrapped;
        state.headerRow.orientation = wrapped ? NSUserInterfaceLayoutOrientationVertical : NSUserInterfaceLayoutOrientationHorizontal;
        state.headerRow.alignment = wrapped ? NSLayoutAttributeLeading : NSLayoutAttributeCenterY;
        if (wrapped) [NSLayoutConstraint activateConstraints:state.wrappedWidths];
    }
    _toolbarHeightConstraint.constant = _presentationMode ? 0 : (wrapped ? 68 : 36);
    _toolbar.edgeInsets = NSEdgeInsetsMake(4,_sidebarVisible ? 8 : 8-_splitView.dividerThickness,4,8);
    _sidebarToggleButton.hidden = _sidebarVisible;
    _minimapToggleButton.hidden = _presentationMode;
    _toolbarOverflowButton.hidden = YES;
    // Sized by the total, not the current number, so typing a page number of
    // the total's length shows every digit and nothing beside it moves.
    CGFloat pageWidth = spdf_page_field_width_for_total(_pageField,_pageCountLabel.stringValue);
    for (NSLayoutConstraint* c in _pageField.constraints)
        if (c.firstAttribute==NSLayoutAttributeWidth && !c.secondItem) c.constant=pageWidth;
    state.previous.enabled = [_pageSegments isEnabledForSegment:0];
    state.next.enabled = [_pageSegments isEnabledForSegment:1];
    state.print.enabled = [self hasActiveDocument];
    state.imageColors.enabled=[self hasActiveDocument];
    state.imageColors.image=[NSImage imageWithSystemSymbolName:_darkThemePreservesImages ? @"photo" : @"photo.fill" accessibilityDescription:nil];
    state.imageColors.toolTip=_darkThemePreservesImages ? @"Invert image colors in dark theme · ⇧⌘I" : @"Preserve image colors in dark theme · ⇧⌘I";
    state.imageColors.accessibilityLabel=state.imageColors.toolTip;
    _findCountLabel.hidden = !_searchField.stringValue.length;
    _findSegments.hidden = !_searchField.stringValue.length;
}
- (void)showGroupsSidebar:(id)sender {
    [self prioritizeWorkspaceSidebar];
    (void)sender;
    _sidebarModeControl.spdf_selectedSidebarMode = SPDFSidebarModeGroups;
    _sidebarPreferredVisible = YES;
    [self rebuildSidebar]; [self syncWorkspaceChrome]; [self rememberSidebarWorkspaceMode];
}
- (void)revealWorkspaceFind {
    [self rememberPanelBeforeFind];
    [self prioritizeWorkspaceSidebar];
    if (!_sidebarModeControl) return;
    _sidebarModeControl.spdf_selectedSidebarMode = SPDFSidebarModeSearch;
    _sidebarPreferredVisible = YES;
    [self rebuildSidebar]; [self syncWorkspaceChrome];
    [self rememberSidebarWorkspaceMode];
}
@end
