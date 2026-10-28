#import <Cocoa/Cocoa.h>
@class SPDFDocumentTab;

// Nil on ordinary tabs: no registry, palette, or group layout is created until
// the reader groups a tab or restores a session that actually contains groups.
@interface SPDFTabGroup : NSObject <NSCopying>
@property(nonatomic, copy) NSString* identifier;
@property(nonatomic, copy) NSString* name;
@property(nonatomic, copy) NSString* colorName;
@property(nonatomic, copy) NSString* lastUsedPath;
@property(nonatomic) BOOL collapsed;
@property(nonatomic) BOOL hidden;
// General created explicitly in Group Management survives without custom groups.
@property(nonatomic) BOOL explicitGeneral;
@property(nonatomic, readonly) BOOL general;
@property(nonatomic, readonly) BOOL collectionBackups;
@property(nonatomic, readonly) NSString* displayName;
+ (instancetype)generalGroup;
+ (instancetype)collectionBackupsGroup;
+ (instancetype)groupWithColor:(NSString*)color;
- (NSDictionary*)dictionary;
+ (instancetype)fromDictionary:(id)value;
@end

NSArray<NSString*>* spdf_tab_group_colors(void);
// The group's colour: its title tab, the bar under an open group, swatches.
NSColor* spdf_tab_group_accent(NSString* color);
// Text and icons drawn on the accent: white or near-black, 4.5:1 or more.
NSColor* spdf_tab_group_label(NSString* color);
// The title tab's outline in the current drawing appearance, 3:1 or more against the tab bar.
NSColor* spdf_tab_group_edge(NSString* color);
// For tests: part 0 fill, 1 label, 2 edge, as 0xRRGGBB.
unsigned spdf_tab_group_hex(NSString* color, int part, BOOL dark);
NSColor* spdf_tab_group_selected_fill(NSString* color, BOOL dark);
NSImage* spdf_tab_group_swatch_image(NSString* color);
NSString* spdf_tab_group_unused_color(NSArray<SPDFDocumentTab*>* tabs);
// Canonicalizes decoded identities and keeps each group's tabs contiguous,
// preserving first-occurrence group order and intra-group tab order.
void spdf_tab_groups_normalize(NSMutableArray<SPDFDocumentTab*>* tabs);
void spdf_tab_groups_activate(NSArray<SPDFDocumentTab*>* tabs, SPDFDocumentTab* selected);
// An opened document always shows its own tab: its group is unhidden and becomes the
// expanded one, whichever group the strip was browsing. YES when the strip changed.
BOOL spdf_tab_groups_reveal(NSArray<SPDFDocumentTab*>* tabs, SPDFDocumentTab* opened);
NSArray<SPDFDocumentTab*>* spdf_tab_group_members(NSArray<SPDFDocumentTab*>* tabs, SPDFTabGroup* group);
// A drop outside group spans joins General without relocating it. When absent,
// General is created at the supplied insertion boundary. Called only on drop.
NSInteger spdf_tab_group_prepare_gap_drop(NSArray<SPDFDocumentTab*>* tabs,
    SPDFDocumentTab* tab, NSInteger insertionIndex);

@protocol SPDFTabGroupReader <NSObject>
- (void)createGroupForTabAtIndex:(NSInteger)index withTabAtIndex:(NSInteger)other color:(NSString*)color;
- (void)createGroupForTabAtIndex:(NSInteger)index withTabAtIndex:(NSInteger)other color:(NSString*)color
             beforeTargetGroup:(BOOL)before;
- (void)toggleTabGroup:(SPDFTabGroup*)group;
- (void)setTabGroup:(SPDFTabGroup*)group hidden:(BOOL)hidden;
- (void)jumpTabGroup:(SPDFTabGroup*)group;
- (void)renameTabGroup:(SPDFTabGroup*)group name:(NSString*)name;
- (void)recolorTabGroup:(SPDFTabGroup*)group color:(NSString*)color;
- (void)ungroupTabs:(SPDFTabGroup*)group;
- (void)requestCloseTabGroup:(SPDFTabGroup*)group;
- (void)closeTabGroup:(SPDFTabGroup*)group;
- (void)moveTabGroup:(SPDFTabGroup*)group toIndex:(NSInteger)index;
- (void)moveTabAtIndex:(NSInteger)index toGroup:(SPDFTabGroup*)group atIndex:(NSInteger)destination;
- (NSArray<NSDictionary*>*)snapshotTabGroup:(SPDFTabGroup*)group;
- (void)insertDraggedGroup:(NSArray<NSDictionary*>*)tabs atIndex:(NSInteger)index;
- (void)detachTabGroup:(SPDFTabGroup*)group atScreenPoint:(NSPoint)point;
@end

// Legacy compatibility entry point; copies remain in ordinary groups.
void spdf_tab_group_collection_copy(NSMutableArray<SPDFDocumentTab*>* tabs, SPDFDocumentTab* tab);
