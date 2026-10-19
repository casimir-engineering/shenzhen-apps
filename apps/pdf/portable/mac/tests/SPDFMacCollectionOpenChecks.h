static NSButton* CollectionActionButton(NSView* view, NSString* title) {
    if ([view isKindOfClass:NSButton.class] && [[(NSButton*)view title] isEqual:title]) return (id)view;
    for (NSView* child in view.subviews) {
        NSButton* found = CollectionActionButton(child,title); if (found) return found;
    }
    return nil;
}
static void CheckCollectionActionGeometry(SPDFMacCollectionWindow* manager) {
    NSSize previous = manager.window.contentView.bounds.size;
    NSIndexSet* selection = manager.table.selectedRowIndexes;
    for (NSNumber* width in @[@680,@1100]) {
        [manager.window setContentSize:NSMakeSize(width.doubleValue,590)];
        [manager.window.contentView layoutSubtreeIfNeeded]; [manager.table reloadData];
        NSView* row = [manager.table viewAtColumn:0 row:0 makeIfNecessary:YES];
        [row layoutSubtreeIfNeeded];
        CGFloat lastRight = 0;
        for (NSString* title in @[@"Open original",@"Open collection copy",@"History"]) {
            NSButton* button = CollectionActionButton(row,title);
            NSRect frame = [button convertRect:button.bounds toView:row];
            Expect(@"all three Collection actions fit at minimum and full width",button &&
                NSContainsRect(NSInsetRect(row.bounds,-1,-1),frame) && NSMinX(frame)>=lastRight &&
                NSWidth(frame)>=button.intrinsicContentSize.width-1);
            lastRight = NSMaxX(frame);
        }
        NSString* evidence = NSProcessInfo.processInfo.environment[@"SPDF_COLLECTION_WINDOW_EVIDENCE"];
        if (evidence.length && width.integerValue == 680) {
            NSView* content = manager.window.contentView;
            NSBitmapImageRep* bitmap = [content bitmapImageRepForCachingDisplayInRect:content.bounds];
            [content cacheDisplayInRect:content.bounds toBitmapImageRep:bitmap];
            [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
                writeToFile:[evidence.stringByDeletingPathExtension stringByAppendingString:@"-minimum-actions.png"] atomically:YES];
        }
    }
    [manager.window setContentSize:previous]; [manager.window.contentView layoutSubtreeIfNeeded];
    [manager.table selectRowIndexes:selection byExtendingSelection:NO];
}
// Exercise the real asynchronous actions with an available original and its saved bytes.
static void CheckCollectionOpenTargets(SPDFMacCollectionWindow* manager, SPDFMacCollectionStore* store) {
    CheckCollectionActionGeometry(manager);
    SPDFCollectionOpenHandler previous = manager.openHandler;
    __block NSString* opened = nil;
    __block BOOL archived = NO;
    manager.openHandler = ^(NSString* path, BOOL copy) { opened = path; archived = copy; };
    NSDictionary* document = [manager selectedDocument];
    NSMenu* menu = [NSMenu new]; [manager populateDocumentMenu:menu];
    Expect(@"Collection distinguishes Original from Collection Copy",
        [menu itemWithTitle:@"Open Original"].enabled && [menu itemWithTitle:@"Open Collection Copy"].enabled &&
        ![menu itemWithTitle:@"Open Document"]);
    [manager openOriginal:nil];
    Expect(@"Open Original routes the source without archive status",[opened isEqual:document[@"path"]] && !archived);
    opened = nil;
    [manager preview:nil];
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:3];
    while (!opened && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    Expect(@"Open Collection Copy never substitutes the available original",
        opened && ![opened isEqual:document[@"path"]] && archived && [store editableInfoForPath:opened]!=nil);
    Expect(@"Collection copy contains the saved bytes",opened &&
        [[NSData dataWithContentsOfFile:opened] isEqual:[NSData dataWithContentsOfFile:document[@"path"]]]);
    NSNumber* mode = [NSFileManager.defaultManager attributesOfItemAtPath:opened error:nil][NSFilePosixPermissions];
    Expect(@"Collection opens an independent writable copy while preserved snapshots remain immutable",mode && (mode.unsignedIntegerValue & 0200) != 0 && ![store isArchivePath:opened]);
    manager.openHandler = previous;
}
