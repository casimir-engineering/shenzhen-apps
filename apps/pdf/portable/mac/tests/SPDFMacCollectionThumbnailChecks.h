#import "SPDFMacCollectionThumbnail.h"

static NSData* CollectionThumbnailFixture(void) {
    NSMutableData* data = [NSMutableData data];
    CGDataConsumerRef consumer = CGDataConsumerCreateWithCFData((__bridge CFMutableDataRef)data);
    CGRect box = CGRectMake(0,0,200,200);
    CGContextRef context = CGPDFContextCreate(consumer,&box,NULL);
    CGPDFContextBeginPage(context,NULL); CGContextSetRGBFillColor(context,.1,.3,.8,1);
    CGContextFillRect(context,CGRectMake(20,20,160,160)); CGPDFContextEndPage(context);
    CGPDFContextClose(context); CGContextRelease(context); CGDataConsumerRelease(consumer);
    return data;
}

static void CheckCollectionThumbnails(void) {
    NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSFileManager* fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSData* data = CollectionThumbnailFixture();
    PDFDocument* plain = [[PDFDocument alloc] initWithData:data];
    NSURL* restricted = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"Restricted.pdf"]];
    Expect(@"write owner-restricted PDF",[plain writeToURL:restricted withOptions:@{
        PDFDocumentOwnerPasswordOption:@"owner-secret",PDFDocumentUserPasswordOption:@""}]);
    PDFDocument* ownerRestricted = [[PDFDocument alloc] initWithURL:restricted];
    Expect(@"fixture encrypted but readable without a user password",ownerRestricted.isEncrypted && !ownerRestricted.isLocked);
    __block BOOL prompted = NO;
    NSImage* image = SPDFCollectionPDFThumbnail(restricted,1,^(PDFDocument* pdf) { (void)pdf; prompted = YES; },nil);
    Expect(@"encrypted readable PDF gets a real page thumbnail without prompting",image != nil && !prompted);
    NSURL* locked = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"Locked.pdf"]];
    Expect(@"write locked PDF",[plain writeToURL:locked withOptions:@{
        PDFDocumentOwnerPasswordOption:@"owner-secret",PDFDocumentUserPasswordOption:@"reader-secret"}]);
    NSError* error = nil;
    Expect(@"locked copy remains private without a credential",SPDFCollectionPDFThumbnail(locked,1,nil,&error)==nil && error.code==2);
    image = SPDFCollectionPDFThumbnail(locked,1,^(PDFDocument* pdf) { [pdf unlockWithPassword:@"reader-secret"]; },nil);
    Expect(@"already authenticated copy can render using a memory credential",image != nil);
    Expect(@"rendering does not decrypt or rewrite archived bytes",[[[PDFDocument alloc] initWithURL:locked] isLocked]);
    Expect(@"out of bounds result pages clamp to a real page",SPDFCollectionPDFThumbnail(restricted,999,nil,nil)!=nil);
    [fm removeItemAtPath:directory error:nil];
}

// Run inside the native Collection window suite to exercise the actual list cell
// and asynchronous rendering, not just PDFKit's thumbnail implementation.
static void CheckCollectionThumbnailRequests(SPDFMacCollectionWindow* manager) {
    NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSFileManager* fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    SPDFMacCollectionStore* originalStore = manager.store;
    NSArray* originalRows = manager.rows;
    SPDFMacCollectionStore* store = [[SPDFMacCollectionStore alloc] initWithRootURL:
        [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"Collection"]]];
    [store updateSettings:@{@"choice":@"enabled"} error:nil];
    NSString* path = [directory stringByAppendingPathComponent:@"Restricted.pdf"];
    PDFDocument* pdf = [[PDFDocument alloc] initWithData:CollectionThumbnailFixture()];
    [pdf writeToFile:path withOptions:@{PDFDocumentOwnerPasswordOption:@"owner",PDFDocumentUserPasswordOption:@""}];
    NSDictionary* document = [store capturePath:path reason:@"Opened" error:nil];
    NSDictionary* version = [store versionsForDocumentID:document[@"id"]].firstObject;
    Expect(@"Collection fixture records encryption metadata",[version[@"encrypted"] boolValue]);
    manager.store = store; manager.rows = @[@{@"document":document,@"version":version}];
    [manager.table reloadData];
    (void)[manager resultCellForRow:0];
    NSString* key = [NSString stringWithFormat:@"%@/%@/0",document[@"id"],version[@"id"]];
    Expect(@"encrypted list document requests its thumbnail",[manager.pendingThumbnails containsObject:key]);
    [manager.thumbnailQueue waitUntilAllOperationsAreFinished];
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:1];
    while ([manager.pendingThumbnails containsObject:key] && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    Expect(@"encrypted list thumbnail resolves to page pixels",[manager.thumbnailCache objectForKey:key]!=nil);
    // Imported metadata can exist before a document has ever been captured.
    NSDictionary* imported = @{@"id":@"uncaptured",@"path":path,@"title":@"Restricted.pdf"};
    manager.rows = @[@{@"document":imported}];
    NSString* originalKey = [NSString stringWithFormat:@"uncaptured//0/original-%lu",(unsigned long)manager.generation];
    [manager.thumbnailQueue waitUntilAllOperationsAreFinished];
    Expect(@"uncaptured original does no preview work before its row is consulted",
        ![manager.pendingThumbnails containsObject:originalKey] && ![manager.thumbnailCache objectForKey:originalKey]);
    NSView* originalCell = [manager resultCellForRow:0];
    Expect(@"consulting uncaptured original schedules a lazy thumbnail",[manager.pendingThumbnails containsObject:originalKey]);
    [manager.thumbnailQueue waitUntilAllOperationsAreFinished];
    deadline = [NSDate dateWithTimeIntervalSinceNow:1];
    while ([manager.pendingThumbnails containsObject:originalKey] && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    Expect(@"uncaptured original has a real preview",[manager.thumbnailCache objectForKey:originalKey]!=nil);
    BOOL labeledOriginal=NO;
    for (NSView* child in originalCell.subviews)
        if ([child.identifier isEqual:originalKey]) labeledOriginal=[child.accessibilityLabel isEqual:@"Original document preview"];
    Expect(@"original preview is not described as a saved copy",labeledOriginal);
    Expect(@"thumbnail reading never creates a snapshot",[store versionsForDocumentID:@"uncaptured"].count==0);
    (void)[manager resultCellForRow:0];
    Expect(@"reconsulting a cached preview does not schedule duplicate rendering",![manager.pendingThumbnails containsObject:originalKey]);
    manager.generation++;
    NSString* refreshedKey = [NSString stringWithFormat:@"uncaptured//0/original-%lu",(unsigned long)manager.generation];
    (void)[manager resultCellForRow:0];
    Expect(@"refresh lazily revalidates mutable original instead of using stale pixels",[manager.pendingThumbnails containsObject:refreshedKey]);
    [manager.thumbnailQueue waitUntilAllOperationsAreFinished];
    deadline = [NSDate dateWithTimeIntervalSinceNow:1];
    while ([manager.pendingThumbnails containsObject:refreshedKey] && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    for (NSDictionary* denied in @[
        @{@"document":imported,@"version":@{@"id":@"missing-history"}},
        @{@"document":@{@"id":@"replaced",@"path":path,@"sourceReplaced":@YES}},
        @{@"document":@{@"id":@"identity",@"path":path,@"fileIdentity":@"wrong-identity"}}]) {
        NSString* deniedKey = NSUUID.UUID.UUIDString;
        [manager requestThumbnail:denied key:deniedKey];
        [manager.thumbnailQueue waitUntilAllOperationsAreFinished];
        deadline = [NSDate dateWithTimeIntervalSinceNow:1];
        while ([manager.pendingThumbnails containsObject:deniedKey] && deadline.timeIntervalSinceNow > 0)
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
        Expect(@"missing history or replaced originals never get misleading original pixels",![manager.thumbnailCache objectForKey:deniedKey]);
    }
    manager.store = originalStore; manager.rows = originalRows;
    [manager.table reloadData];
    [fm removeItemAtPath:directory error:nil];
}
