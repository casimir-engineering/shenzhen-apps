// File > Close (Cmd+W). Closing never asks to save: every change is saved as it is made, and a pasted image already
// lives in the app's own storage ("Pasted Images" in the state folder), where Recently Closed and Cmd+K find it again.
#import "SPDFMacAIIntegration.h"
@interface ShenzhenMacDelegate (SPDFMacCloseDocumentPrivate)
- (void)closeTabAtIndex:(NSInteger)index preferMostRecentActive:(BOOL)recent;
- (void)rememberClosedDocumentPath:(NSString*)path;
- (void)clearFindResults;
- (void)rebuildSidebar;
- (void)updateControls;
@end
@implementation ShenzhenMacDelegate (SPDFMacCloseDocument)
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

@end
