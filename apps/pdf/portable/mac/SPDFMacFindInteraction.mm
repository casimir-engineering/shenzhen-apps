#import "SPDFMacFindInteraction.h"
#import "SPDFMacSidebarModeControl.h"
#import "SPDFMacSidebarWorkspace.h"
#import "SPDFMacWorkspaceChrome.h"
#import <objc/runtime.h>

static char previousPanelKey;
@interface ShenzhenMacDelegate (FindInteractionHost)
- (void)clearFindFieldFocus;
- (NSView*)activeDocumentKeyView;
- (void)findFromCurrentForward:(BOOL)forward;
- (BOOL)hasActiveDocument;
- (void)rebuildSidebar;
- (void)startFindForCurrentQuery;
- (void)setSidebarFilterTextForCurrentMode:(NSString*)filter;
- (void)startFindForCurrentQueryResetSavedIndex:(BOOL)reset revealMatch:(BOOL)reveal;
@end

@implementation ShenzhenMacDelegate (SPDFMacFindInteraction)
- (void)rememberPanelBeforeFind {
    // Capture only when entering Find. Further keystrokes/reveals cannot replace
    // the panel to return to, and no state is allocated before the feature is used.
    if (!_sidebarModeControl || _sidebarModeControl.spdf_selectedSidebarMode == SPDFSidebarModeSearch) return;
    objc_setAssociatedObject(self, &previousPanelKey,
        @{@"mode":@(_sidebarModeControl.spdf_selectedSidebarMode), @"visible":@(_sidebarPreferredVisible),
          @"tab":[NSValue valueWithNonretainedObject:[self selectedTab]]}, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)dismissWorkspaceFind {
    NSDictionary* previous = objc_getAssociatedObject(self, &previousPanelKey);
    BOOL restore = previous && [previous[@"tab"] nonretainedObjectValue] == [self selectedTab] &&
        _sidebarModeControl.spdf_selectedSidebarMode == SPDFSidebarModeSearch;
    objc_setAssociatedObject(self, &previousPanelKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    _searchField.stringValue = @"";
    [self startFindForCurrentQuery];
    if (restore) {
        _sidebarModeControl.spdf_selectedSidebarMode = [previous[@"mode"] integerValue];
        _sidebarPreferredVisible = [previous[@"visible"] boolValue];
        [self rebuildSidebar]; [self syncWorkspaceChrome]; [self rememberSidebarWorkspaceMode];
    }
    [self clearFindFieldFocus];
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
- (void)clearFindFieldFocus {
    if (_window.firstResponder == _searchField || _window.firstResponder == _searchField.currentEditor)
        [_window makeFirstResponder:[self activeDocumentKeyView]];
}
#pragma clang diagnostic pop
- (void)dismissSidebarFilterField {
    // End the shared editor before changing modes/fields. Otherwise Escape
    // leaves subsequent document typing in the hidden panel's filter.
    [_sidebarFilterField abortEditing]; _sidebarFilterField.stringValue=@"";
    [self setSidebarFilterTextForCurrentMode:@""]; [self rebuildSidebar];
    [_window makeFirstResponder:[self activeDocumentKeyView]];
}
- (BOOL)documentFindReturnKeyDown:(NSEvent*)event {
    if (event.keyCode != 36 && event.keyCode != 76) return NO;
    if (![self hasActiveDocument] || _presentationMode || _window.attachedSheet ||
        _sidebarModeControl.spdf_selectedSidebarMode != SPDFSidebarModeSearch || !_searchField.stringValue.length) return NO;
    if (event.modifierFlags & (NSEventModifierFlagOption|NSEventModifierFlagControl)) return NO;
    id responder=_window.firstResponder;
    if (([responder isKindOfClass:NSText.class] || [responder isKindOfClass:NSTextField.class]) &&
        responder != _searchField && responder != _searchField.currentEditor) return NO;
    BOOL previous=(event.modifierFlags & (NSEventModifierFlagCommand|NSEventModifierFlagShift)) != 0;
    if (_findMatches.count) [self findFromCurrentForward:!previous]; else [self startFindForCurrentQuery];
    return YES;
}

- (BOOL)documentEscapeKeyDown:(NSEvent*)event {
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if (flags & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption)) return NO;
    if ([_tabStrip dismissGroupPickerIfShown]) return YES;
    if (![self hasActiveDocument] || _presentationMode) return NO;
    BOOL hasActiveSearch = _searchField.stringValue.length > 0 || _findSearchInProgress || _findMatches.count > 0;
    if (!hasActiveSearch && !objc_getAssociatedObject(self, &previousPanelKey)) return NO;
    [self dismissWorkspaceFind];
    return YES;
}

- (BOOL)documentTypeToSearchKeyDown:(NSEvent*)event {
    if (![self hasActiveDocument] || _presentationMode || !_searchField || _window.attachedSheet) return NO;
    if (event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption |
                               NSEventModifierFlagFunction)) return NO;
    id firstResponder = _window.firstResponder;
    if ([firstResponder isKindOfClass:NSText.class] || [firstResponder isKindOfClass:NSTextField.class]) return NO;
    NSString* typed = event.characters ?: @"";
    if (typed.length == 0 || [typed rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound)
        return NO;
    for (NSUInteger i = 0; i < typed.length; i++) if ([typed characterAtIndex:i] >= 0xF700 &&
        [typed characterAtIndex:i] <= 0xF8FF) return NO; // AppKit function-key characters are not document text.
    [self revealWorkspaceFind];
    [_window makeFirstResponder:_searchField];
    _searchField.stringValue = typed;
    [_searchField.currentEditor setSelectedRange:NSMakeRange(typed.length, 0)];
    [self startFindForCurrentQueryResetSavedIndex:YES revealMatch:YES];
    return YES;
}
@end
