static NSArray* ScrollRows(NSUInteger count) {
    NSMutableArray* rows=[NSMutableArray array];
    for(NSUInteger i=0;i<count;i++)[rows addObject:@{@"document":@{
        @"id":[NSString stringWithFormat:@"row-%lu",(unsigned long)i],
        @"title":@"Retained document",@"versions":@[]},@"version":@{}}];
    return rows;
}
static void CheckScrollPosition(SPDFMacCollectionWindow* manager, NSString* label) {
    NSRect viewport=manager.listScroll.contentView.bounds;
    NSRect visible=manager.table.visibleRect;
    NSRange rows=[manager.table rowsInRect:visible];
    NSRect last=manager.rows.count ? [manager.table rectOfRow:manager.rows.count-1] : NSZeroRect;
    CGFloat bottom=NSMaxY(last), maximum=MAX(0,bottom-NSHeight(viewport));
    Expect([label stringByAppendingString:@": finite, bounded origin"],isfinite(viewport.origin.x) && isfinite(viewport.origin.y) &&
        viewport.origin.x>=0 && viewport.origin.y>=0 && viewport.origin.y<=maximum+.5);
    Expect([label stringByAppendingString:@": retained rows are visible"],!manager.rows.count || (rows.location!=NSNotFound && rows.length>0));
}
static void CheckCollectionScrollRestoration(void) {
    NSURL* root=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    SPDFMacCollectionStore* store=[[SPDFMacCollectionStore alloc] initWithRootURL:root];
    SPDFMacCollectionWindow* manager=[[SPDFMacCollectionWindow alloc] initWithStore:store open:^(NSString* path,BOOL archived){(void)path;(void)archived;}];
    [manager.window setContentSize:NSMakeSize(850,590)];
    [manager.window.contentView layoutSubtreeIfNeeded];
    manager.reloadingResults=YES; manager.rows=ScrollRows(93);
    [manager.table reloadData];
    NSDictionary* oldState=@{@"query":@"",@"listX":@10000,@"listY":@10877,@"selection":@[]};
    [manager restoreBrowseSelectionAndScroll:oldState];
    CheckScrollPosition(manager,@"startup with saved offset beyond retained documents");
    [manager restoreBrowseSelectionAndScroll:@{@"query":@"",@"listX":@0,@"listY":@6000}];
    Expect(@"valid reading position is retained",fabs(manager.listScroll.contentView.bounds.origin.y-6000)<.5);
    manager.hasLoadedResults=YES; manager.resultQuery=@"";
    [manager.listScroll.contentView scrollToPoint:NSMakePoint(0,9000)];
    NSDictionary* before=[manager captureBrowseState];
    manager.rows=ScrollRows(3); [manager.table reloadData];
    [manager restoreBrowseSelectionAndScroll:before];
    CheckScrollPosition(manager,@"refresh shrinks list from 93 rows to 3");
    [manager restoreBrowseSelectionAndScroll:@{@"query":@"",@"listX":@(NAN),@"listY":@(INFINITY)}];
    CheckScrollPosition(manager,@"invalid edited config coordinates");
    [manager restoreBrowseSelectionAndScroll:@{@"query":@"",@"listX":@-10,@"listY":@-900}];
    CheckScrollPosition(manager,@"negative restored coordinates");
    manager.rows=@[]; [manager.table reloadData];
    [manager restoreBrowseSelectionAndScroll:oldState];
    CheckScrollPosition(manager,@"empty list has neutral origin");
    Expect(@"scroll regression never shows a window or creates Collection data",!manager.window.visible &&
        ![NSFileManager.defaultManager fileExistsAtPath:root.path]);
}
