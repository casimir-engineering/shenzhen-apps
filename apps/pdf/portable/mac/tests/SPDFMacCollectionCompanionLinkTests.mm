#import "SPDFMacCollectionCompanion.h"
#import "SPDFMacCollectionPipe.h"
#import "SPDFMacCollectionWindowPrivate.h"
#import "SPDFMacCollectionStore.h"
#import "SPDFMacPassword.h"
#import "SPDFMacCollectionThumbnail.h"
#import "SPDFMacCollectionThumbnailLoader.h"
#import "SPDFMacMarkdownCache.h"
#import <PDFKit/PDFKit.h>
#import <objc/runtime.h>

@interface SPDFCollectionCompanionRuntime (LinkProbe)
- (void)receive:(NSDictionary*)message;
@end
static int failures;
static void Expect(NSString* label,BOOL ok) {
    if (!ok) { fprintf(stderr,"FAIL %s\n",label.UTF8String); failures++; }
}
static NSData* PlainPDF(void) {
    NSMutableData* bytes=[NSMutableData data];
    CGDataConsumerRef consumer=CGDataConsumerCreateWithCFData((__bridge CFMutableDataRef)bytes);
    CGRect box=CGRectMake(0,0,200,200); CGContextRef context=CGPDFContextCreate(consumer,&box,NULL);
    CGPDFContextBeginPage(context,NULL); CGContextSetRGBFillColor(context,.1,.5,.7,1);
    CGContextFillRect(context,CGRectMake(12,12,160,160)); CGPDFContextEndPage(context);
    CGPDFContextClose(context); CGContextRelease(context); CGDataConsumerRelease(consumer); return bytes;
}
static NSDictionary* CaptureRow(SPDFMacCollectionStore* store,NSString* path) {
    NSError* error=nil; NSDictionary* doc=[store capturePath:path reason:@"Opened" error:&error];
    Expect([NSString stringWithFormat:@"capture fixture: %@",error ?: @""],doc!=nil);
    NSDictionary* version=[store versionsForDocumentID:doc[@"id"]].lastObject;
    return doc && version ? @{@"document":doc,@"version":version} : nil;
}
static NSImage* Thumbnail(SPDFMacCollectionWindow* manager,NSDictionary* row,NSString* key) {
    if (!row) return nil;
    [manager requestThumbnail:row key:key]; [manager.thumbnailQueue waitUntilAllOperationsAreFinished];
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:2];
    while ([manager.pendingThumbnails containsObject:key] && deadline.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    return [manager.thumbnailCache objectForKey:key];
}
#import "SPDFMacCollectionLiveRefreshChecks.h"
#import "SPDFMacCollectionScrollChecks.h"
int main(void) {
    @autoreleasepool {
        // Thumbnails go to a scratch cache, never the user's (SPDFCollectionThumbnailDirectory).
        setenv("SPDF_STATE_DIR",[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString].UTF8String,1);
        Expect(@"helper links its runtime without activating it",NSClassFromString(@"SPDFCollectionCompanionRuntime")!=nil &&
            [SPDFCollectionCompanionRuntime activeRuntime]==nil);
        Expect(@"reader and persistent-password backend are absent from helper",
            NSClassFromString(@"ShenzhenMacDelegate")==nil && NSClassFromString(@"SPDFMacCollectionCredentials")==nil &&
            NSClassFromString(@"SPDFCollectionCompanionHost")==nil);
        Expect(@"dynamic Markdown renderer is present",NSClassFromString(@"SPDFMarkdownDocument")!=nil);
        [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        CheckCollectionScrollRestoration();
        CheckCollectionLiveRefresh();
        NSString* directory=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSFileManager* fm=NSFileManager.defaultManager;
        [fm createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL* root=[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"Collection"]];
        SPDFMacCollectionStore* store=[[SPDFMacCollectionStore alloc] initWithRootURL:root];
        SPDFCollectionCompanionRuntime* runtime=[SPDFCollectionCompanionRuntime new];
        Expect(@"runtime construction leaves Collection storage untouched",![fm fileExistsAtPath:root.path]);
        [store updateSettings:@{@"choice":@"enabled"} error:nil];
        SPDFMacCollectionWindow* manager=[[SPDFMacCollectionWindow alloc] initWithStore:store open:^(NSString* path,BOOL archived) {
            (void)path; (void)archived;
        }];
        [manager.window.contentView layoutSubtreeIfNeeded];
        [manager showDestination:@"Settings"];
        Expect(@"helper Settings pane is available",!manager.settingsPane.hidden && [manager.destination isEqual:@"Settings"]);
        [manager showDestination:@"Documents"];
        Expect(@"helper Documents pane is available",manager.settingsPane.hidden && [manager.destination isEqual:@"Documents"]);
        [runtime setValue:manager forKey:@"manager"];
        [runtime receive:@{@"kind":@"destination",@"destination":@"Settings"}];
        // The switch arrives on a later main-queue turn; under a loaded build 20 ms was sometimes too soon.
        NSDate* routed=[NSDate dateWithTimeIntervalSinceNow:5];
        while (![manager.destination isEqual:@"Settings"] && routed.timeIntervalSinceNow>0)
            [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
        Expect(@"unified Settings route opens the companion Settings pane",[manager.destination isEqual:@"Settings"] && !manager.settingsPane.hidden);
        [runtime receive:@{@"kind":@"destination",@"destination":@"arbitrary"}];
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
        Expect(@"companion ignores unsupported navigation destinations",[manager.destination isEqual:@"Settings"]);
        [manager showDestination:@"Documents"];
        Expect(@"probe does not display a window",!manager.window.visible);
        NSString* markdown=[directory stringByAppendingPathComponent:@"Preview.md"];
        [@"# Companion fixture\n\nA **Markdown** page with readable text.\n" writeToFile:markdown atomically:YES
            encoding:NSUTF8StringEncoding error:nil];
        NSDictionary* markdownRow=CaptureRow(store,markdown);
        NSImage* image=Thumbnail(manager,markdownRow,@"markdown");
        Expect(@"exact helper graph renders a real Markdown page",image!=nil && image.representations.count>0);

        NSPipe* outgoing=[NSPipe pipe], *incoming=[NSPipe pipe];
        SPDFCollectionPipe* host=[[SPDFCollectionPipe alloc] initWithReader:outgoing.fileHandleForReading writer:incoming.fileHandleForWriting];
        SPDFCollectionPipe* child=[[SPDFCollectionPipe alloc] initWithReader:incoming.fileHandleForReading writer:outgoing.fileHandleForWriting];
        [runtime setValue:child forKey:@"pipe"];
        __weak SPDFCollectionCompanionRuntime* weakRuntime=runtime;
        __weak SPDFCollectionPipe* weakHost=host;
        __block NSUInteger requests=0;
        child.messageHandler=^(NSDictionary* message) { [weakRuntime receive:message]; };
        host.messageHandler=^(NSDictionary* message) {
            if ([message[@"kind"] isEqual:@"credential"]) {
                requests++;
                [weakHost send:@{@"kind":@"credential",@"request":message[@"request"],@"password":@"session-secret"}];
            }
        };
        [host start]; [child start];
        Method active=class_getClassMethod(SPDFCollectionCompanionRuntime.class,@selector(activeRuntime));
        IMP injected=imp_implementationWithBlock(^id(id cls) { (void)cls; return runtime; });
        IMP original=method_setImplementation(active,injected);
        NSString* encrypted=[directory stringByAppendingPathComponent:@"Locked.pdf"];
        PDFDocument* pdf=[[PDFDocument alloc] initWithData:PlainPDF()];
        Expect(@"create password-protected fixture",[pdf writeToFile:encrypted withOptions:@{
            PDFDocumentOwnerPasswordOption:@"owner",PDFDocumentUserPasswordOption:@"session-secret"}]);
        [SPDFPasswordCredentialStore.sharedStore removeAllCredentials];
        NSDictionary* encryptedRow=CaptureRow(store,encrypted);
        image=Thumbnail(manager,encryptedRow,@"encrypted-pipe");
        Expect(@"encrypted PDF preview authenticates through private credential pipe",image!=nil && requests==1);
        Expect(@"a PDF opened with a password keeps its preview off disk",!spdf_mac_markdown_image_cache_read(
            manager.thumbnails.directory,SPDFCollectionThumbnailDiskKey(encryptedRow,0,MAX(1,manager.window.backingScaleFactor))));
        NSURL* archived=[store materializeVersionID:encryptedRow[@"version"][@"id"]
            documentID:encryptedRow[@"document"][@"id"] error:nil];
        Expect(@"rendering leaves saved encrypted bytes locked",[[[PDFDocument alloc] initWithURL:archived] isLocked]);
        Expect(@"helper does not retain a global plaintext credential cache",
            [SPDFPasswordCredentialStore.sharedStore credentialForSourcePath:encrypted]==nil);
        method_setImplementation(active,original); imp_removeBlock(injected);
        [host close]; [child close];
        dispatch_sync(manager.preferenceQueue,^{});
        Expect(@"all probe windows remain hidden",!manager.window.visible);
        [fm removeItemAtPath:directory error:nil];
        if (!failures) puts("SPDFMacCollectionCompanionLinkTests passed");
        return failures ? 1 : 0;
    }
}
