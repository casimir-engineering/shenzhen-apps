#import "SPDFMacDelegatePrivate.h"
#import "SPDFMacCollectionCompare.h"
#import "SPDFMacSupport.h"
#import "markdown/SPDFTextDocumentFormats.h"

// Tab menu ▸ Compare to Current Document: the right-clicked tab against the one being read, in the comparison window
// Version History uses. That window reads PDFs and the text documents ShenzhenPDF lays out on pages (Markdown and
// source code); for any other kind of document the item is left out, as Open in Editor is for non-text documents.
static BOOL SPDFTabCompareSupportsPath(NSString* path) {
    return path.length && ([path.pathExtension.lowercaseString isEqualToString:@"pdf"] ||
                           SPDFIsRenderedTextDocumentPath(path));
}

@implementation ShenzhenMacDelegate (SPDFTabCompare)
- (NSString*)tabCompareLabelAtIndex:(NSInteger)index {
    SPDFDocumentTab* tab = _tabs[(NSUInteger)index];
    if (tab.collectionVersionLabel.length) return tab.collectionVersionLabel;
    if (spdf_tab_display_name(tab)) return spdf_tab_display_name(tab);
    NSMutableArray<NSString*>* paths = [NSMutableArray arrayWithCapacity:_tabs.count];
    for (SPDFDocumentTab* item in _tabs) [paths addObject:item.path ?: @""];
    NSArray<NSString*>* names = spdf_disambiguated_display_names_for_paths(paths);
    return (NSUInteger)index < names.count ? names[(NSUInteger)index] : tab.path.lastPathComponent;
}

- (NSString*)tabCompareReadPathAtIndex:(NSInteger)index {
    SPDFDocumentTab* tab = _tabs[(NSUInteger)index];
    if (index == _selectedTabIndex && [tab.path isEqualToString:_path]) return _workingPath.length ? _workingPath : _path;
    return tab.workingPath.length ? tab.workingPath : tab.path;
}

- (BOOL)tabCanCompareToCurrentAtIndex:(NSInteger)index {
    NSInteger current = _selectedTabIndex;
    if (index < 0 || index >= (NSInteger)_tabs.count || current < 0 || current >= (NSInteger)_tabs.count ||
        index == current) return NO;
    SPDFDocumentTab* tab = _tabs[(NSUInteger)index], *front = _tabs[(NSUInteger)current];
    if (tab.missingFile || front.missingFile || [tab.path isEqualToString:front.path]) return NO;
    return SPDFTabCompareSupportsPath(tab.path) && SPDFTabCompareSupportsPath(front.path);
}

- (void)addCompareItemToTabMenu:(NSMenu*)menu tabIndex:(NSInteger)index {
    if (![self tabCanCompareToCurrentAtIndex:index]) return;
    NSMenuItem* item = [menu addItemWithTitle:@"Compare to Current Document"
                                       action:@selector(compareTabToCurrentDocument:) keyEquivalent:@""];
    item.target = self;
    item.representedObject = _tabs[(NSUInteger)index].path;
    spdf_set_menu_item_system_symbol(item, @"rectangle.split.2x1");
}

- (void)compareTabToCurrentDocument:(NSMenuItem*)sender {
    // By path, not index: the tabs can move between the menu opening and the click.
    NSString* path = [sender.representedObject isKindOfClass:NSString.class] ? sender.representedObject : nil;
    NSUInteger index = [_tabs indexOfObjectPassingTest:^BOOL(SPDFDocumentTab* tab, NSUInteger i, BOOL* stop) {
        (void)i; (void)stop; return [tab.path isEqualToString:path];
    }];
    if (index == NSNotFound || ![self tabCanCompareToCurrentAtIndex:(NSInteger)index]) { NSBeep(); return; }
    NSInteger current = _selectedTabIndex;
    SPDFMacShowComparison([NSURL fileURLWithPath:[self tabCompareReadPathAtIndex:(NSInteger)index]],
                          [NSURL fileURLWithPath:[self tabCompareReadPathAtIndex:current]],
                          [self tabCompareLabelAtIndex:(NSInteger)index], [self tabCompareLabelAtIndex:current],
                          @"Document Comparison — Read-only", _window);
}
@end
