#import <Cocoa/Cocoa.h>
#import "SPDFMacCollectionStyle.h"
#import <objc/runtime.h>
#import "SPDFMacModels.h"
#import "SPDFMacTabGroups.h"
#import "SPDFMacCollectionTabIdentity.h"

static int failures;
static NSUInteger groupAllocations;
static IMP originalAlloc;
static id CountGroupAlloc(id cls, SEL selector) {
    ++groupAllocations;
    return ((id (*)(id, SEL))originalAlloc)(cls, selector);
}
static void Expect(NSString* label, BOOL condition) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", label.UTF8String); ++failures; }
}
static SPDFDocumentTab* Tab(NSString* path) {
    SPDFDocumentTab* tab = [[SPDFDocumentTab alloc] init];
    tab.path = path;
    tab.title = path.lastPathComponent;
    return tab;
}
static NSMutableArray* RoundTrip(NSArray* tabs) {
    NSMutableArray* dictionaries = [NSMutableArray array];
    for (SPDFDocumentTab* tab in tabs) [dictionaries addObject:spdf_dictionary_from_tab(tab, 7)];
    NSData* bytes = [NSJSONSerialization dataWithJSONObject:dictionaries options:0 error:nil];
    NSArray* decoded = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
    NSMutableArray* result = [NSMutableArray array];
    for (NSDictionary* item in decoded) [result addObject:spdf_tab_from_dictionary(item)];
    spdf_tab_groups_normalize(result);
    return result;
}
int main(void) {
    @autoreleasepool {
        Method alloc = class_getClassMethod(SPDFTabGroup.class, @selector(alloc));
        originalAlloc = method_getImplementation(alloc);
        class_addMethod(object_getClass(SPDFTabGroup.class), @selector(alloc), (IMP)CountGroupAlloc,
                        method_getTypeEncoding(alloc));
        NSMutableArray* ordinary = [NSMutableArray arrayWithArray:@[Tab(@"/a.pdf"), Tab(@"/b.md")]];
        for (NSUInteger i = 0; i < 100; ++i) {
            spdf_tab_groups_normalize(ordinary);
            SPDFDocumentTab* restored = spdf_tab_from_dictionary(spdf_dictionary_from_tab(ordinary.firstObject, 0));
            Expect(@"ungrouped codec omits the optional metadata", !spdf_dictionary_from_tab(restored, 0)[@"group"]);
        }
        Expect(@"ordinary tabs allocate zero group objects through normalize/save/restore", groupAllocations == 0);
        SPDFDocumentTab* source = Tab(@"/original.md"), *saved = Tab(@"/archive/v1.md");
        saved.readOnly = YES;
        saved.readOnlyCopyBinding = @{@"source":@{@"device":@1,@"inode":@9007199254740993ULL,@"size":@8,
            @"mtime":@1700000000,@"mtimeNS":@123456789,@"ctime":@1700000001,@"ctimeNS":@987654321},
            @"copy":@{@"device":@1,@"inode":@4,@"size":@8,@"mtime":@1700000000,@"mtimeNS":@0,@"ctime":@1700000000,@"ctimeNS":@0}};
        SPDFDocumentTab* rebound = spdf_tab_from_dictionary(spdf_dictionary_from_tab(saved,0));
        Expect(@"full source and render-copy identities persist without numeric narrowing",
            [rebound.readOnlyCopyBinding isEqual:saved.readOnlyCopyBinding] &&
            [spdf_copy_document_tab(saved).readOnlyCopyBinding isEqual:saved.readOnlyCopyBinding]);
        Expect(@"ordinary tabs do not serialize copy metadata",!spdf_dictionary_from_tab(source,0)[@"roCopyBinding"]);
        NSMutableArray* backupTabs = [@[source,saved] mutableCopy];
        spdf_tab_group_collection_copy(backupTabs,saved);
        Expect(@"opening a copy creates no special group", !saved.group && !source.group);
        SPDFTabGroup* project=[SPDFTabGroup groupWithColor:@"Blue"];
        source.group=project; source.collectionHistoryDocumentID=@"same-document";
        saved.group=SPDFTabGroup.collectionBackupsGroup; saved.collectionHistoryDocumentID=@"same-document";
        spdf_tab_groups_normalize(backupTabs);
        Expect(@"legacy backup rejoins its original group",saved.group==project);
        NSArray* restoredCopies=RoundTrip(backupTabs);
        Expect(@"migrated group persists without backup metadata",!((SPDFDocumentTab*)restoredCopies[1]).group.collectionBackups &&
            [((SPDFDocumentTab*)restoredCopies[1]).group.identifier isEqual:project.identifier]);
        SPDFDocumentTab* orphan=Tab(@"/archive/orphan.md"); orphan.group=SPDFTabGroup.collectionBackupsGroup;
        [backupTabs addObject:orphan]; spdf_tab_groups_normalize(backupTabs);
        Expect(@"unmatched legacy backup joins General",orphan.group.general);
        SPDFTabGroup* purple = [SPDFTabGroup groupWithColor:@"Purple"];
        purple.name = @"Research";
        purple.lastUsedPath = @"/c.md";
        purple.collapsed = YES;
        SPDFTabGroup* green = [SPDFTabGroup groupWithColor:@"Green"];
        SPDFDocumentTab* a = ordinary[0];
        SPDFDocumentTab* b = ordinary[1];
        SPDFDocumentTab* c = Tab(@"/c.md");
        SPDFDocumentTab* d = Tab(@"/d.pdf");
        SPDFDocumentTab* e = Tab(@"/e.pdf");
        b.group = purple; c.group = purple; d.group = green;
        c.pageIndex = 17; c.zoom = 1.75; c.customZoom = 2.0;
        c.scrollOrigin = NSMakePoint(81, 1234); c.hasScrollOrigin = YES;
        c.markdownSelectionRange = NSMakeRange(13, 22);
        c.searchText = @"canonical coordinates"; c.findMatchIndex = 2;
        NSMutableArray* tabs = [@[a, b, c, d, e] mutableCopy];
        spdf_tab_groups_normalize(tabs);
        Expect(@"first group creates General for all other tabs", a.group.general && a.group == e.group);
        Expect(@"normalization preserves group order and intra-group tab order",
               [tabs isEqualToArray:@[a, e, b, c, d]]);
        NSArray* identities = [tabs copy];
        spdf_tab_groups_normalize(tabs);
        Expect(@"normalization is stable", [identities isEqualToArray:tabs] && b.group == purple);
        NSArray* restored = RoundTrip(tabs);
        SPDFDocumentTab* rb = restored[2];
        SPDFDocumentTab* rc = restored[3];
        Expect(@"membership restores as one shared object", rb.group != nil && rb.group == rc.group && rb.group != purple);
        Expect(@"UUID name color collapse and last used restore", [rb.group.identifier isEqualToString:purple.identifier]
            && [rb.group.name isEqualToString:@"Research"] && [rb.group.colorName isEqualToString:@"Purple"]
            && rb.group.collapsed && [rb.group.lastUsedPath isEqualToString:@"/c.md"]);
        Expect(@"reading position zoom and selection restore", rc.pageIndex == 17 && rc.zoom == 1.75
            && rc.customZoom == 2.0 && rc.hasScrollOrigin && NSEqualPoints(rc.scrollOrigin, NSMakePoint(81, 1234))
            && NSEqualRanges(rc.markdownSelectionRange, NSMakeRange(13, 22)));
        Expect(@"search state survives grouped handoff", [rc.searchText isEqualToString:c.searchText]
            && rc.findMatchIndex == 2);
        SPDFDocumentTab* copy = spdf_copy_document_tab(c);
        copy.group.name = @"Independent transfer";
        Expect(@"tab snapshots copy metadata without mutating the source group",
               copy.group != nil && copy.group != c.group && [copy.group.identifier isEqualToString:c.group.identifier]
               && [c.group.name isEqualToString:@"Research"] && copy.pageIndex == c.pageIndex);
        a.group.collapsed = NO;
        spdf_tab_groups_activate(tabs, c);
        Expect(@"entering a custom group collapses every other group including General",
               !purple.collapsed && green.collapsed && a.group.collapsed);
        Expect(@"activation remembers last used tab", [purple.lastUsedPath isEqualToString:c.path]);
        spdf_tab_groups_activate(tabs, a);
        Expect(@"entering General collapses other groups", !a.group.collapsed && purple.collapsed && green.collapsed);
        // Reopening a document (Finder, Open Recent) while the strip browses another
        // group, or while its group is hidden, must bring its own group forward.
        purple.hidden = YES;
        Expect(@"revealing a document in a hidden folded group reports a strip change",
               spdf_tab_groups_reveal(tabs, c));
        Expect(@"revealing unhides and expands only the document's group",
               !purple.hidden && !purple.collapsed && a.group.collapsed && green.collapsed);
        Expect(@"revealing the group already in front changes nothing", !spdf_tab_groups_reveal(tabs, c));
        NSMutableArray* destination = [@[Tab(@"/existing.pdf")] mutableCopy];
        [destination addObjectsFromArray:RoundTrip(@[b, c])];
        spdf_tab_groups_normalize(destination);
        Expect(@"cross-window group transfer gives existing tabs General",
               ((SPDFDocumentTab*)destination[0]).group.general);
        Expect(@"transferred group retains order name and reading position",
               [((SPDFDocumentTab*)destination[1]).path isEqualToString:b.path]
               && ((SPDFDocumentTab*)destination[2]).pageIndex == c.pageIndex
               && [((SPDFDocumentTab*)destination[1]).group.name isEqualToString:@"Research"]);
        for (SPDFDocumentTab* tab in tabs) if (tab.group == purple || tab.group == green) tab.group = nil;
        spdf_tab_groups_normalize(tabs);
        BOOL allUngrouped = YES;
        for (SPDFDocumentTab* tab in tabs) allUngrouped &= tab.group == nil;
        Expect(@"removing last custom group returns ordinary tabs", allUngrouped);
        SPDFTabGroup* unnamed = [SPDFTabGroup groupWithColor:@"Rose"];
        Expect(@"unnamed groups use color names", [unnamed.displayName isEqualToString:@"Rose"]);
        unnamed.colorName = @"Teal";
        Expect(@"renaming the color updates unnamed label", [unnamed.displayName isEqualToString:@"Teal"]);
        Expect(@"invalid metadata is ignored", ![SPDFTabGroup fromDictionary:@"bad"]
            && ![SPDFTabGroup fromDictionary:@{@"id": @3}]);
        SPDFTabGroup* malformed = [SPDFTabGroup fromDictionary:@{@"id": @"x", @"color": @13, @"collapsed": @[]}];
        Expect(@"malformed optional values use safe defaults", [malformed.colorName isEqualToString:@"Purple"]
            && !malformed.collapsed);
        Expect(@"palette includes Orange", spdf_tab_group_colors().count == 11 && [spdf_tab_group_colors() containsObject:@"Orange"]);
        // Group colours against the chrome palette's tab bar ("titlebar") and tab title ("text"), light then dark.
        auto channel = [](unsigned hex, int shift) { return ((hex >> shift) & 255) / 255.0; };
        auto lum = [&](double r, double g, double b) {
            auto linear = [](double n) { return n <= 0.04045 ? n / 12.92 : pow((n + .055) / 1.055, 2.4); };
            return .2126 * linear(r) + .7152 * linear(g) + .0722 * linear(b);
        };
        auto hexLum = [&](unsigned hex) { return lum(channel(hex, 16), channel(hex, 8), channel(hex, 0)); };
        auto ratio = [](double a, double b) { return (MAX(a, b) + .05) / (MIN(a, b) + .05); };
        Expect(@"the palette keeps every stored colour name, so a group keeps its colour",
            [spdf_tab_group_colors() isEqualToArray:(@[@"Purple", @"Green", @"Blue", @"Teal", @"Rose", @"Coral",
                                                      @"Amber", @"Indigo", @"Plum", @"Slate", @"Orange"])]);
        for (NSString* color in [spdf_tab_group_colors() arrayByAddingObject:@"Gray"]) {
            unsigned fill = spdf_tab_group_hex(color, 0, NO), label = spdf_tab_group_hex(color, 1, NO);
            Expect([NSString stringWithFormat:@"%@ chip label reaches 4.5:1 (WCAG AA)", color],
                   ratio(hexLum(fill), hexLum(label)) >= 4.5);
            for (NSNumber* dark in @[@NO, @YES]) {
                unsigned bar = 0, text = 0;
                SPDFChromeHex(@"titlebar", dark.boolValue, &bar); SPDFChromeHex(@"text", dark.boolValue, &text);
                unsigned edge = spdf_tab_group_hex(color, 2, dark.boolValue);
                Expect([NSString stringWithFormat:@"%@ chip outline stands 3:1 from the %@ tab bar", color,
                           dark.boolValue ? @"dark" : @"light"], ratio(hexLum(edge), hexLum(bar)) >= 3.0);
                // The selected tab's fill is the group colour over the tab bar at the fill's alpha.
                NSColor* selected = [spdf_tab_group_selected_fill(color, dark.boolValue)
                                        colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
                double alpha = selected.alphaComponent;
                double r = channel(bar, 16) + (selected.redComponent - channel(bar, 16)) * alpha;
                double g = channel(bar, 8) + (selected.greenComponent - channel(bar, 8)) * alpha;
                double b = channel(bar, 0) + (selected.blueComponent - channel(bar, 0)) * alpha;
                Expect([NSString stringWithFormat:@"%@ selected tab title keeps 4.5:1 in %@", color,
                           dark.boolValue ? @"dark" : @"light"], ratio(lum(r, g, b), hexLum(text)) >= 4.5);
            }
        }
        NSString* dir = @(__FILE__).stringByDeletingLastPathComponent;
        NSString* coordinator = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:
            @"../ShenzhenPDFMac.mm"] encoding:NSUTF8StringEncoding error:nil];
        NSString* detach = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:
            @"../SPDFMacTabDetach.mm"] encoding:NSUTF8StringEncoding error:nil];
        NSString* integration = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:
            @"../SPDFMacTabGroupIntegration.mm"] encoding:NSUTF8StringEncoding error:nil];
        NSRange selectStart = [coordinator rangeOfString:@"- (void)selectTabAtIndex:"];
        NSRange selectEnd = [coordinator rangeOfString:@"- (void)closeTabAtIndex:" options:0
            range:NSMakeRange(selectStart.location, coordinator.length - selectStart.location)];
        NSString* selectSource = [coordinator substringWithRange:NSMakeRange(selectStart.location,
            selectEnd.location - selectStart.location)];
        Expect(@"same-index startup restore preserves manually collapsed groups",
            [selectSource containsString:@"if (index != _selectedTabIndex || [self hasActiveDocument])"]
            && ![selectSource containsString:@"[self activateSelectedTabGroup]"]);
        Expect(@"session normalizes group identities after decoding", [coordinator containsString:@"spdf_tab_groups_normalize(_tabs);"]);
        NSString* opening = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:
            @"../SPDFMacDocumentOpening.mm"] encoding:NSUTF8StringEncoding error:nil];
        Expect(@"new documents enter the active group",
            [opening containsString:@"[self appendNewTabToActiveGroup:tab]"]);
        Expect(@"group detach carries all tab dictionaries and window geometry",
            [integration containsString:@"@{@\"tabs\": tabs, @\"frame\": NSStringFromRect(frame)}"]
            && [detach containsString:@"NSRectFromString(frame)"] && [detach containsString:@"_hasRestoredWindowFrame = YES"]);
        Expect(@"failed handoff writes keep the source group intact",
            [integration containsString:@"if (![[self stateObjectFromFile:handoffName] isEqual:handoff])"]);
        Expect(@"detached window opens the group's last-used document",
            [detach containsString:@"self.initialPath = _tabs[(NSUInteger)_selectedTabIndex].path"]);
    }
    if (!failures) puts("SPDFMacTabGroupTests passed");
    return failures ? 1 : 0;
}
