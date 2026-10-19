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
NSColor* spdf_tab_group_accent(NSString* color) {
    NSArray* names = spdf_tab_group_colors();
    NSUInteger index = [names indexOfObject:color ?: @""];
    const unsigned values[] = {0xc4a0fa, 0x86d9ac, 0x85c5fa, 0x6cd8d1, 0xf1a0c4,
                               0xffaa94, 0xf1cd78, 0xaab5ff, 0xdca5e9, 0xabc5d8, 0xffbc83};
    return RGB(index < names.count ? values[index] : 0xb5b5be);
}
NSImage* spdf_tab_group_swatch_image(NSString* color) {
    NSString* label = color.length ? color : @"Gray";
    return [NSImage imageWithSize:NSMakeSize(12, 12) flipped:NO drawingHandler:^BOOL(NSRect rect) {
      [spdf_tab_group_accent(label) setFill];
      [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(rect, 1, 1)] fill];
      return YES;
    }];
}
NSColor* spdf_tab_group_selected_fill(NSString* color, BOOL dark) {
    if (!color.length || [color isEqualToString:@"Gray"]) return RGB(dark ? 0x50535c : 0xc6c8ce);
    NSUInteger index = [spdf_tab_group_colors() indexOfObject:color ?: @""];
    // Aqua uses labelColor (black) for every tab title, so selected fills are
    // pale tints. Dark Aqua keeps the deep fills below for white labelColor.
    const unsigned light[] = {0xd6b9fa, 0xa4e3bd, 0xb1d9fc, 0x9ce1da, 0xf5bbd5,
                              0xffc2af, 0xf5dda0, 0xc5ccff, 0xe8c0f0, 0xc0d8e8, 0xffc18a};
    const unsigned night[] = {0x72539b, 0x347456, 0x396f9b, 0x267773, 0x965274,
                              0x985b4b, 0x826a32, 0x5b65a2, 0x85558e, 0x526f83, 0x8f603a};
    return RGB(index < spdf_tab_group_colors().count ? (dark ? night[index] : light[index])
                                                    : (dark ? 0x16161b : 0x41414a));
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
