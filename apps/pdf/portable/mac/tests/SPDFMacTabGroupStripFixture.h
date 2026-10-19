// Headless strip fixture: records actions instead of displaying menus or prompts.
@interface SPDFGroupTestStrip : SPDFTabStripView
@property(nonatomic) NSInteger renameRequests;
@property(nonatomic) NSInteger groupDragRequests;
@property(nonatomic) NSInteger hiddenListRequests;
@property(nonatomic) BOOL hiddenListLeft;
@property(nonatomic) NSInteger hiddenMenuBuilds;
@end
@implementation SPDFGroupTestStrip
- (void)renameGroup:(SPDFTabGroup*)group { if (group) self.renameRequests++; }
- (NSMenu*)hiddenTabsMenuOnLeft:(BOOL)left { self.hiddenMenuBuilds++; return [super hiddenTabsMenuOnLeft:left]; }
- (void)showHiddenTabsOnLeft:(BOOL)left { self.hiddenListRequests++; self.hiddenListLeft=left; }
- (void)startGroupDragSessionWithEvent:(NSEvent*)event { (void)event; self.groupDragRequests++; }
@end
