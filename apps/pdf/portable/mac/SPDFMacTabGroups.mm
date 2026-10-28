#import "SPDFMacTabGroups.h"
#import "SPDFMacModels.h"
#import "SPDFMacCollectionTabIdentity.h"

@implementation SPDFTabGroup
@synthesize colorName = _colorName;
- (NSString*)colorName { return self.collectionBackups ? @"Orange" : _colorName; }
+ (instancetype)generalGroup {
    SPDFTabGroup* group = [[self alloc] init];
    group.identifier = @"general";
    group.colorName = @"Gray";
    return group;
}
+ (instancetype)collectionBackupsGroup {
    SPDFTabGroup* group = [[self alloc] init];
    group.identifier = @"collection-backups";
    group.name = @"Collection Backups";
    group.colorName = @"Orange";
    return group;
}
+ (instancetype)groupWithColor:(NSString*)color {
    SPDFTabGroup* group = [[self alloc] init];
    group.identifier = NSUUID.UUID.UUIDString;
    group.colorName = [spdf_tab_group_colors() containsObject:color] ? color : @"Purple";
    return group;
}
- (BOOL)collectionBackups { return [self.identifier isEqualToString:@"collection-backups"]; }
- (BOOL)general { return [self.identifier isEqualToString:@"general"]; }
- (NSString*)displayName { return self.name.length ? self.name : self.general ? @"General" : self.colorName; }
- (NSDictionary*)dictionary {
    return @{@"id": self.identifier ?: @"", @"name": self.name ?: @"", @"color": self.colorName ?: @"Purple",
             @"collapsed": @(self.collapsed), @"hidden":@(self.hidden), @"explicitGeneral":@(self.explicitGeneral),
             @"lastUsedPath": self.lastUsedPath ?: @""};
}
+ (instancetype)fromDictionary:(id)value {
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSString* identifier = value[@"id"];
    if (![identifier isKindOfClass:NSString.class] || !identifier.length) return nil;
    SPDFTabGroup* group = [[self alloc] init];
    group.identifier = identifier;
    NSString* color = value[@"color"];
    group.colorName = [color isKindOfClass:NSString.class] && [spdf_tab_group_colors() containsObject:color]
        ? color : @"Purple";
    if (group.general) group.colorName = @"Gray";
    if ([value[@"name"] isKindOfClass:NSString.class]) group.name = value[@"name"];
    if ([value[@"lastUsedPath"] isKindOfClass:NSString.class]) group.lastUsedPath = value[@"lastUsedPath"];
    id collapsed = value[@"collapsed"];
    group.collapsed = [collapsed respondsToSelector:@selector(boolValue)] && [collapsed boolValue];
    for (NSString* key in @[@"hidden",@"explicitGeneral"]) {
        id flag=value[key];
        if ([flag respondsToSelector:@selector(boolValue)]) [group setValue:@([flag boolValue]) forKey:key];
    }
    return group;
}
- (id)copyWithZone:(NSZone*)zone { (void)zone; return [SPDFTabGroup fromDictionary:self.dictionary]; }
@end

NSArray<NSString*>* spdf_tab_group_colors(void) {
    // Function-local initialization is intentional: an ungrouped launch never
    // constructs the palette or generates an identifier.
    static NSArray* colors;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ colors = @[@"Purple", @"Green", @"Blue", @"Teal", @"Rose", @"Coral",
                                      @"Amber", @"Indigo", @"Plum", @"Slate", @"Orange"]; });
    return colors;
}
static NSColor* RGB(unsigned rgb) {
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 255) / 255.0 green:((rgb >> 8) & 255) / 255.0
                              blue:(rgb & 255) / 255.0 alpha:1];
}
// Group colours: vivid chips in the family of Codex's own round icons (its blue download button #3983f7 and yellow
// avatar #ffc205), hues after Radix Colors' step 9 (MIT, https://www.radix-ui.com/colors), each darkened just enough
// for its label. Names are what sessions store, so a group keeps its colour across this change. Per colour:
//   fill   the title tab ("chip") and the bar under an open group, the same in light and dark;
//   label  white where it reaches 4.5:1 on the fill, else near-black #111111 (every pair is 4.6:1 or more);
//   edge   the chip's 1 pt outline, light then dark: the fill itself where the fill already stands 3:1 from the tab
//          bar (#eaeaea / #282828), else the nearest shade of the same hue that does.
// Gray is General's, and the colour of tabs outside any group.
typedef struct { const char* name; unsigned fill; BOOL whiteLabel; unsigned edgeLight, edgeDark; } SPDFGroupColor;
static const SPDFGroupColor kGroupColors[] = {
    {"Purple", 0xa03ae0, YES, 0xa03ae0, 0xa23ee1}, {"Green", 0x2fb26a, NO, 0x28995b, 0x2fb26a},
    {"Blue", 0x1a6ae6, YES, 0x1a6ae6, 0x1b6be6},   {"Teal", 0x0ea5b0, NO, 0x0d959f, 0x0ea5b0},
    {"Rose", 0xe11969, YES, 0xe11969, 0xe11969},   {"Coral", 0xe1292f, YES, 0xe1292f, 0xe1292f},
    {"Amber", 0xffc205, NO, 0xa98000, 0xffc205},   {"Indigo", 0x4f46e5, YES, 0x4f46e5, 0x655de8},
    {"Plum", 0xd01fb0, YES, 0xd01fb0, 0xd01fb0},   {"Slate", 0x59779a, YES, 0x59779a, 0x59779a},
    {"Orange", 0xf76b15, NO, 0xe45b08, 0xf76b15},  {"Gray", 0x6e6e6e, YES, 0x6e6e6e, 0x717171},
};
static const SPDFGroupColor& GroupColor(NSString* color) {
    const size_t count = sizeof kGroupColors / sizeof kGroupColors[0];
    for (size_t i = 0; i < count; i++)
        if (color && !strcmp(kGroupColors[i].name, color.UTF8String)) return kGroupColors[i];
    return kGroupColors[count - 1];
}
static BOOL IsDark(NSAppearance* appearance) {
    return [[appearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]]
        isEqualToString:NSAppearanceNameDarkAqua];
}
NSColor* spdf_tab_group_accent(NSString* color) { return RGB(GroupColor(color).fill); }
NSColor* spdf_tab_group_label(NSString* color) { return RGB(GroupColor(color).whiteLabel ? 0xffffff : 0x111111); }
NSColor* spdf_tab_group_edge(NSString* color) {
    const SPDFGroupColor& entry = GroupColor(color);
    return IsDark(NSAppearance.currentDrawingAppearance) ? RGB(entry.edgeDark) : RGB(entry.edgeLight);
}
unsigned spdf_tab_group_hex(NSString* color, int part, BOOL dark) {
    const SPDFGroupColor& entry = GroupColor(color);
    return part == 0 ? entry.fill : part == 1 ? (entry.whiteLabel ? 0xffffff : 0x111111)
                                              : (dark ? entry.edgeDark : entry.edgeLight);
}
NSImage* spdf_tab_group_swatch_image(NSString* color) {
    NSString* label = color.length ? color : @"Gray";
    return [NSImage imageWithSize:NSMakeSize(12, 12) flipped:NO drawingHandler:^BOOL(NSRect rect) {
      NSBezierPath* dot = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(rect, 1.5, 1.5)];
      [spdf_tab_group_accent(label) setFill];
      [dot fill];
      [spdf_tab_group_edge(label) setStroke];
      [dot stroke];
      return YES;
    }];
}
// The selected tab of a group: its colour over the tab bar, strong enough to read as selected and light enough
// (dark enough in Dark Aqua) that the tab's ordinary title colour keeps 5:1 or more on it.
NSColor* spdf_tab_group_selected_fill(NSString* color, BOOL dark) {
    return [spdf_tab_group_accent(color) colorWithAlphaComponent:dark ? 0.42 : 0.30];
}
NSString* spdf_tab_group_unused_color(NSArray<SPDFDocumentTab*>* tabs) {
    NSMutableArray* available = [spdf_tab_group_colors() mutableCopy];
    for (SPDFDocumentTab* tab in tabs) if (tab.group.colorName) [available removeObject:tab.group.colorName];
    if (!available.count) available = [spdf_tab_group_colors() mutableCopy];
    return available[arc4random_uniform((uint32_t)available.count)];
}
NSArray<SPDFDocumentTab*>* spdf_tab_group_members(NSArray<SPDFDocumentTab*>* tabs, SPDFTabGroup* group) {
    NSMutableArray* members = [NSMutableArray array];
    if (!group) return members;
    for (SPDFDocumentTab* tab in tabs)
        if ([tab.group.identifier isEqualToString:group.identifier]) [members addObject:tab];
    return members;
}
NSInteger spdf_tab_group_prepare_gap_drop(NSArray<SPDFDocumentTab*>* tabs,
    SPDFDocumentTab* tab, NSInteger insertionIndex) {
    SPDFTabGroup* general = nil;
    NSInteger last = -1;
    for (NSUInteger i = 0; i < tabs.count; ++i) if (tabs[i].group.general) {
        if (!general) general = tabs[i].group;
        last = (NSInteger)i;
    }
    general = general ?: SPDFTabGroup.generalGroup;
    general.explicitGeneral = YES;
    general.hidden = NO;
    tab.group = general;
    return last >= 0 ? last + 1 : MAX(0, MIN(insertionIndex, (NSInteger)tabs.count));
}
void spdf_tab_groups_normalize(NSMutableArray<SPDFDocumentTab*>* tabs) {
    // Legacy Backups groups are retired without any filesystem work at launch.
    for (SPDFDocumentTab* tab in tabs) if (tab.group.collectionBackups) {
        SPDFTabGroup* original=nil;
        for (SPDFDocumentTab* other in tabs)
            if (!other.group.collectionBackups && tab.collectionHistoryDocumentID.length &&
                [other.collectionHistoryDocumentID isEqual:tab.collectionHistoryDocumentID]) { original=other.group; break; }
        tab.group=original;
    }
    BOOL hasCustom = NO;
    BOOL hasAny = NO;
    BOOL retainGeneral = NO;
    for (SPDFDocumentTab* tab in tabs) {
        if (tab.group) hasAny = YES;
        if (tab.group.general && (tab.group.hidden || tab.group.explicitGeneral)) retainGeneral = YES;
        if (tab.group && !tab.group.general) { hasCustom = YES; break; }
    }
    if (!hasAny) return;
    if (!hasCustom && !retainGeneral) { for (SPDFDocumentTab* tab in tabs) tab.group = nil; return; }
    // Strip refreshes also happen while reading. Already canonical, contiguous
    // groups need no rebuilding. Only multiple groups need an identifier set;
    // scanning every preceding tab at each boundary makes refresh quadratic.
    BOOL needsNormalization = NO;
    SPDFTabGroup* previous = nil;
    NSMutableSet<NSString*>* seen = nil;
    for (NSUInteger i = 0; i < tabs.count && !needsNormalization; ++i) {
        SPDFTabGroup* group = tabs[i].group;
        if (!group) { needsNormalization = YES; break; }
        if (group == previous) continue;
        if (previous) {
            if (!seen) seen = [NSMutableSet setWithObject:previous.identifier];
            if ([seen containsObject:group.identifier]) { needsNormalization = YES; break; }
            [seen addObject:group.identifier];
        }
        previous = group;
    }
    if (!needsNormalization) return;
    NSMutableDictionary<NSString*, SPDFTabGroup*>* canonical = [NSMutableDictionary dictionary];
    // Ungrouping a custom group can place nil-group tabs before an existing
    // General. Keep that General's explicit visibility instead of replacing it.
    for (SPDFDocumentTab* tab in tabs) if (tab.group.general) { canonical[@"general"]=tab.group; break; }
    NSMutableArray<NSString*>* order = [NSMutableArray array];
    NSMutableDictionary<NSString*, NSMutableArray*>* buckets = [NSMutableDictionary dictionary];
    for (SPDFDocumentTab* tab in tabs) {
        NSString* identifier = tab.group.identifier ?: @"general";
        if (!buckets[identifier]) {
            canonical[identifier] = canonical[identifier] ?: tab.group ?: SPDFTabGroup.generalGroup;
            buckets[identifier] = [NSMutableArray array];
            [order addObject:identifier];
        }
        tab.group = canonical[identifier];
        [buckets[identifier] addObject:tab];
    }
    [tabs removeAllObjects];
    for (NSString* identifier in order) [tabs addObjectsFromArray:buckets[identifier]];
}
void spdf_tab_groups_activate(NSArray<SPDFDocumentTab*>* tabs, SPDFDocumentTab* selected) {
    if (!selected.group) return;
    for (SPDFDocumentTab* tab in tabs)
        tab.group.collapsed = tab.group != selected.group;
    selected.group.collapsed = NO;
    selected.group.lastUsedPath = selected.path;
}

BOOL spdf_tab_groups_reveal(NSArray<SPDFDocumentTab*>* tabs, SPDFDocumentTab* opened) {
    SPDFTabGroup* group = opened.group;
    if (!group) return NO;
    BOOL changed = group.hidden || group.collapsed;
    for (SPDFDocumentTab* tab in tabs) changed = changed || (tab.group != group && !tab.group.collapsed);
    group.hidden = NO;
    spdf_tab_groups_activate(tabs, opened);
    return changed;
}

void spdf_tab_group_collection_copy(NSMutableArray<SPDFDocumentTab*>* tabs, SPDFDocumentTab* tab) {
    // Compatibility entry point: copies now remain ordinary group members.
    if (tab && [tabs containsObject:tab]) spdf_tab_groups_normalize(tabs);
}
