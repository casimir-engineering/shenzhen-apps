#import "SPDFMacDelegatePrivate.h"
#import "SPDFMacShortcutHelpStyle.h"

static int failures, saves;
static void Check(BOOL condition, const char* message) {
    if (!condition) { fprintf(stderr,"FAIL: %s\n",message); failures++; }
}
// Exercise the real panel builder without ordering any window onto the desktop.
@implementation SPDFShortcutHelpPanel
- (void)makeKeyAndOrderFront:(id)sender { (void)sender; }
@end
@implementation ShenzhenMacDelegate
- (instancetype)init {
    if ((self = [super init])) { _shortcutHelpRows = [NSMutableArray array]; _showShortcutHelpOnLaunch = YES; }
    return self;
}
- (void)savePersistentState { saves++; }
- (NSInteger)numberOfRowsInTableView:(NSTableView*)table { (void)table; return _shortcutHelpRows.count; }
- (CGFloat)tableView:(NSTableView*)table heightOfRow:(NSInteger)row {
    (void)table; return SPDFShortcutHelpRowHeight(_shortcutHelpRows[row]);
}
- (NSView*)tableView:(NSTableView*)table viewForTableColumn:(NSTableColumn*)column row:(NSInteger)row {
    (void)table; (void)column; return SPDFShortcutHelpRowView(_shortcutHelpRows[row]);
}
@end

static void CheckLabels(NSView* view) {
    if ([view isKindOfClass:NSTextField.class]) {
        NSTextField* label = (id)view;
        Check(NSWidth(label.frame)+1 >= label.intrinsicContentSize.width,"shortcut text and keycaps fit without truncation");
    }
    for (NSView* child in view.subviews) CheckLabels(child);
}

int main(void) { @autoreleasepool {
    [NSApplication sharedApplication];
    NSArray* rows = SPDFShortcutHelpRows(@"");
    Check([rows.firstObject[@"title"] isEqual:@"New!"] && [rows.firstObject[@"highlighted"] boolValue],"New! is the first highlighted category");
    NSMutableDictionary* newActions = [NSMutableDictionary dictionary];
    for (NSDictionary* row in rows) if ([row[@"highlighted"] boolValue] && row[@"keys"])
        newActions[row[@"title"]] = row[@"keys"];
    Check([newActions[@"Groups"] isEqual:@[@"Cmd",@"G"]],"Groups owns Command G");
    Check([newActions[@"Version history"] isEqual:@[@"Cmd",@"H"]],"History is discoverable in New!");
    Check([newActions[@"Previous document"] isEqual:@[@"Cmd",@"D"]],"Previous document is discoverable in New!");
    Check([newActions[@"Open or close Friends"] isEqual:@[@"Cmd",@"J"]],"Friends owns Command J in New!");
    Check(SPDFShortcutHelpRows(@"friends").count > 1,"searching for Friends finds its shortcut");
    Check(SPDFShortcutHelpRows(@"document chat").count > 1,"new chat path is discoverable");
    NSArray* previous = SPDFShortcutHelpRows(@"Previous result");
    Check([previous.lastObject[@"keys"] isEqual:@[@"Cmd",@"Enter"]],"previous result advertises Command Return");
    Check([SPDFShortcutHelpRows(@"Find next").firstObject[@"kind"] isEqual:@"empty"],"obsolete find next binding is absent");
    Check(SPDFShortcutHelpRows(@"command").count > 8,"key-name aliases are searchable");
    Check(SPDFShortcutHelpRows(@"  groups  ").count > 1,"search trims whitespace and finds actions");
    ShenzhenMacDelegate* reader = [ShenzhenMacDelegate new];
    for (NSNumber* dark in @[@NO,@YES]) {
        [reader showShortcutHelp:nil];
        NSPanel* panel = [reader valueForKey:@"shortcutHelpPanel"];
        panel.appearance = [NSAppearance appearanceNamed:dark.boolValue ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
        Check(!panel.visible,"offscreen panel never opens on the user's desktop");
        [panel.contentView layoutSubtreeIfNeeded];
        NSSearchField* search = [reader valueForKey:@"shortcutHelpSearchField"];
        NSTableView* table = [reader valueForKey:@"shortcutHelpTable"];
        Check(NSHeight(search.frame) == 28,"compact search field has intended height");
        Check(NSWidth(table.frame) > 560,"shortcut table fills the native window");
        Check(NSHeight(table.enclosingScrollView.frame) > 450,"initial view has room for the new shortcuts and search controls");
        for (NSDictionary* row in rows) {
            NSView* cell = SPDFShortcutHelpRowView(row);
            cell.frame = NSMakeRect(0,0,NSWidth(table.frame),SPDFShortcutHelpRowHeight(row));
            [panel.contentView addSubview:cell]; [cell layoutSubtreeIfNeeded];
            CheckLabels(cell); [cell removeFromSuperview];
        }
        NSString* directory = NSProcessInfo.processInfo.environment[@"SHORTCUT_EVIDENCE_DIR"];
        if (directory.length) {
            [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
            NSBitmapImageRep* bitmap = [panel.contentView bitmapImageRepForCachingDisplayInRect:panel.contentView.bounds];
            [panel.contentView cacheDisplayInRect:panel.contentView.bounds toBitmapImageRep:bitmap];
            NSString* path = [directory stringByAppendingPathComponent:dark.boolValue ? @"shortcuts-dark.png" : @"shortcuts-light.png"];
            Check([[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES],"offscreen native render written");
        }
        search.stringValue = @"unfindable"; [reader refreshShortcutHelpRows];
        Check(table.numberOfRows == 1,"no-result state is a readable single row");
        search.stringValue = @"";
    }
    [reader disableLaunchShortcutHelp:nil];
    Check(saves == 1 && ![[reader valueForKey:@"showShortcutHelpOnLaunch"] boolValue],"launch opt-out still persists exactly once");
    [reader showShortcutHelp:nil];
    Check([[reader valueForKey:@"shortcutHelpDisableButton"] isHidden],"manual help remains available after launch opt-out");
    if (!failures) puts("Shortcut help catalog, native geometry, search and launch preference tests passed");
    return failures ? 1 : 0;
} }
