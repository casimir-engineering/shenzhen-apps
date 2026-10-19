#import "SPDFMacAIIntegration.h"
#import "SPDFMacUnsavedImageClose.h"
#import <objc/runtime.h>
static char approvedKey, terminationPendingKey, closePendingKey, queuedQuitKey;
@interface ShenzhenMacDelegate (SPDFMacUnsavedImageClosePrivate)
- (void)closeTabAtIndex:(NSInteger)index preferMostRecentActive:(BOOL)recent;
- (void)rememberClosedDocumentPath:(NSString*)path;
- (void)clearFindResults;
- (void)rebuildSidebar;
- (void)updateControls;
@end
@implementation ShenzhenMacDelegate (SPDFMacUnsavedImageClose)
- (void)closeDocument:(id)sender {
    if ([self aiChatWindow].isKeyWindow) { [self closeAIChat]; return; }
    (void)sender;
    [self cancelDocumentTransientInteraction];
    if (_selectedTabIndex >= 0) {
        [self closeTabAtIndex:_selectedTabIndex];
        return;
    }
    NSString* closedPath = [_path copy];
    [self rememberClosedDocumentPath:closedPath];
    [self cancelInactiveTabPreloads];
    [self clearActiveMetadata];
    [self closeActiveDocumentIfUnowned];
    _path = nil;
    _workingPath = nil; // keep working/source paths in sync when the doc clears
    _pageIndex = 0;
    _highlightPageIndex = -1;
    _selectionPageIndex = -1;
    _selectedText = nil;
    _searchField.stringValue = @"";
    _findRegexCheckbox.state = NSControlStateValueOff;
    _findRegexMultiline = YES;
    [self clearFindResults];
    _renderGeneration++;
    [_renderedPages removeAllObjects];
    _window.title = @"Shenzhen PDF";
    _statusLabel.stringValue = @"Ready";
    [self rebuildSidebar];
    [self showEmptyDocumentViewWithMessage:@"Open a document"];
    [self updateControls];
}

- (NSModalResponse)promptToCloseUnsavedImage:(SPDFDocumentTab*)tab {
    NSAlert* alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"Save “%@” before closing?", tab.title.length ? tab.title : @"Pasted Image"];
    alert.informativeText = @"This image has not been saved to a location you chose. Save it as an image or PDF, close without saving, or cancel to keep it open.";
    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:@"Save…"];
    [alert addButtonWithTitle:@"Don't Save"];
    [alert addButtonWithTitle:@"Cancel"].keyEquivalent = @"\e";
    return [alert runModal];
}
- (void)approveClosingImageTabs:(NSArray<SPDFDocumentTab*>*)tabs completion:(void (^)(BOOL))completion {
    [self approveImageTabs:tabs accepted:[NSMapTable strongToStrongObjectsMapTable] allWindowsTabs:NO completion:completion];
}
- (void)approveImageTabs:(NSArray<SPDFDocumentTab*>*)tabs accepted:(NSMapTable*)accepted
         allWindowsTabs:(BOOL)all completion:(void (^)(BOOL))completion {
    SPDFDocumentTab* next = nil;
    // Quit rechecks live tabs after every asynchronous save, including newly
    // pasted images. Approval belongs to an exact tab identity and source path.
    for (SPDFDocumentTab* tab in all ? [_tabs copy] : tabs) {
        if ([_tabs containsObject:tab] && tab.unsavedPastedImage &&
            ![[accepted objectForKey:tab] isEqual:tab.path]) { next = tab; break; }
    }
    if (!next) { completion(YES); return; }
    NSModalResponse response = [self promptToCloseUnsavedImage:next];
    if (response == NSAlertSecondButtonReturn) {
        [accepted setObject:next.path forKey:next];
        [self approveImageTabs:tabs accepted:accepted allWindowsTabs:all completion:completion];
    } else if (response == NSAlertFirstButtonReturn) {
        [self saveImageTab:next completion:^(BOOL saved) {
            if (saved) [self approveImageTabs:tabs accepted:accepted allWindowsTabs:all completion:completion];
            else completion(NO);
        }];
    } else completion(NO);
}
- (BOOL)deferClosingImageTabs:(NSArray<SPDFDocumentTab*>*)tabs action:(void (^)(void))action {
    if (objc_getAssociatedObject(self, &approvedKey)) return NO;
    if (objc_getAssociatedObject(self, &closePendingKey) || objc_getAssociatedObject(self, &terminationPendingKey)) return YES;
    BOOL unsaved = NO;
    for (SPDFDocumentTab* tab in tabs) if (tab.unsavedPastedImage) { unsaved = YES; break; }
    if (!unsaved) return NO;
    objc_setAssociatedObject(self, &closePendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    void (^finish)(BOOL) = ^(BOOL approved) {
        objc_setAssociatedObject(self, &closePendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        BOOL quit = objc_getAssociatedObject(self, &queuedQuitKey) != nil;
        objc_setAssociatedObject(self, &queuedQuitKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!approved) return;
        objc_setAssociatedObject(self, &approvedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        action();
        objc_setAssociatedObject(self, &approvedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (quit) dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:self]; });
    };
    if (![self waitForPendingImageSave:^(BOOL saved) {
        if (saved) [self approveClosingImageTabs:tabs completion:finish]; else finish(NO);
    }]) [self approveClosingImageTabs:tabs completion:finish];
    return YES;
}
- (BOOL)deferClosingUnsavedImageAtIndex:(NSInteger)index preferMostRecentActive:(BOOL)recent {
    if (index < 0 || index >= (NSInteger)_tabs.count) return NO;
    SPDFDocumentTab* tab = _tabs[index];
    return [self deferClosingImageTabs:@[tab] action:^{
        NSInteger current = [self->_tabs indexOfObjectIdenticalTo:tab];
        if (current != NSNotFound) [self closeTabAtIndex:current preferMostRecentActive:recent];
    }];
}
- (BOOL)deferUnsavedImageTermination {
    if (objc_getAssociatedObject(self, &approvedKey)) return NO;
    if (objc_getAssociatedObject(self, &closePendingKey)) {
        objc_setAssociatedObject(self, &queuedQuitKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return YES;
    }
    if (objc_getAssociatedObject(self, &terminationPendingKey)) return YES;
    BOOL unsaved = NO;
    for (SPDFDocumentTab* tab in _tabs) if (tab.unsavedPastedImage) { unsaved = YES; break; }
    if (!unsaved && ![self waitForPendingImageSave:nil]) return NO;
    objc_setAssociatedObject(self, &terminationPendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_async(dispatch_get_main_queue(), ^{
        void (^finish)(BOOL) = ^(BOOL approved) {
            objc_setAssociatedObject(self, &terminationPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (!approved) return;
            objc_setAssociatedObject(self, &approvedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [NSApp terminate:self];
            objc_setAssociatedObject(self, &approvedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        };
        void (^check)(BOOL) = ^(BOOL saved) {
            if (saved) [self approveImageTabs:nil accepted:[NSMapTable strongToStrongObjectsMapTable]
                allWindowsTabs:YES completion:finish];
            else finish(NO);
        };
        if (![self waitForPendingImageSave:check]) check(YES);
    });
    return YES;
}
@end
