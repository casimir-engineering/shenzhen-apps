#import "SPDFMacCollectionRetention.h"
static void CheckCollectionRetentionMenu(SPDFMacCollectionWindow* manager) {
    NSArray* savedRows = manager.rows;
    NSIndexSet* savedSelection = manager.table.selectedRowIndexes;
    if (!savedRows.count) { Expect(@"retention menu fixture has a document",NO); return; }
    NSDictionary* doc = @{@"id":@"retention",@"title":@"Notes",@"path":@"/missing/notes.txt",@"excluded":@NO};
    NSDictionary* version = @{@"id":@"version",@"keep":@NO};
    NSDictionary* row = @{@"document":doc,@"version":version};
    NSDictionary* kept = @{@"document":doc,@"version":@{@"id":@"version",@"keep":@YES}};
    Expect(@"mixed kept selections offer Keep for all",!SPDFCollectionSelectionIsKept(@[row,kept]));
    Expect(@"all kept selections offer removal",SPDFCollectionSelectionIsKept(@[kept,kept]));
    [manager.table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    // Swap the selected model without reloading cells or requesting fake previews.
    NSDictionary* savedSettings = manager.store.settings;
    for (NSNumber* cap in @[@0,@1000000000]) {
      [manager.store updateSettings:@{@"storageLimitBytes":cap} error:nil];
      for (NSNumber* flag in @[@NO,@YES]) {
        NSMutableDictionary* d = [doc mutableCopy]; d[@"excluded"] = flag;
        NSMutableDictionary* v = [version mutableCopy]; v[@"keep"] = flag;
        manager.rows = @[@{@"document":d,@"version":v}];
        NSMenu* menu = [NSMenu new]; [manager populateDocumentMenu:menu];
        NSMenuItem* keep = nil; NSMenuItem* pause = nil;
        for (NSMenuItem* item in menu.itemArray) {
            if (item.action == @selector(keep:)) keep = item;
            if ([NSStringFromSelector(item.action) isEqual:@"exclude:"]) pause = item;
        }
        Expect(@"Pause and Resume actions are absent even for legacy paused documents",pause == nil);
        Expect(@"Keep forever is available only with an applied storage limit",(keep != nil) == (cap.unsignedLongLongValue > 0));
        if (keep) {
            Expect(@"Keep forever command names the actual next action",[keep.title isEqual:flag.boolValue ?
                @"Stop keep forever" : @"Keep forever"]);
            Expect(@"Keep help explains whole-history cleanup protection",[keep.toolTip containsString:@"entire history"] &&
                [keep.toolTip containsString:@"Manual deletion"]);
        }
      }
    }
    [manager.store updateSettings:savedSettings error:nil];
    manager.rows = savedRows;
    [manager.table selectRowIndexes:savedSelection byExtendingSelection:NO]; [manager updateDetails];
}
