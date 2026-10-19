// Render public documentation from native components without showing a window.
#import "SPDFMacCollectionWindowPrivate.h"
#import "SPDFMacPaletteAppearance.h"
#import "SPDFMacReadmeFixtures.h"
#import "SPDFMacReadmeWindowCapture.h"
#undef main
static void Settle(NSTimeInterval seconds) {
    NSDate* end=[NSDate dateWithTimeIntervalSinceNow:seconds];
    while(end.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
}
static void Capture(NSWindow* window,NSString* path) {
    if(window.visible) abort();
    [window.contentView layoutSubtreeIfNeeded];
    NSBitmapImageRep* bitmap=SPDFReadmeWindowBitmap(window);
    if(![[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES]) abort();
}
int main(int argc,const char* argv[]) {
    @autoreleasepool {
        if(argc!=2) return 2;
        NSString* output=[NSString stringWithUTF8String:argv[1]];
        NSString* root=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        setenv("SPDF_STATE_DIR",root.UTF8String,1);
        // Friends is on by default and attaches after first paint; its state must be the probe's, never the real one.
        setenv("SZFRIENDS_STATE_DIR",root.UTF8String,1);
        [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        NSFileManager* fm=NSFileManager.defaultManager;
        [fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
        SPDFMacCollectionStore* store=[[SPDFMacCollectionStore alloc] initWithRootURL:[NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"Collection"]]];
        [store updateSettings:@{@"choice":@"enabled"} error:nil];
        for(NSString* title in @[@"Project notes.md",@"Hardware reference.md",@"Delivery plan.md"]) {
            NSString* path=[root stringByAppendingPathComponent:title];
            [SPDFReadmeMarkdown() writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
            if(![store capturePath:path reason:@"Opened" error:nil]) return 1;
        }
        SPDFMacCollectionWindow* manager=[[SPDFMacCollectionWindow alloc] initWithStore:store open:^(NSString* path,BOOL archived){ (void)path; (void)archived; }];
        manager.window.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        [manager.window setContentSize:NSMakeSize(1100,630)];
        [manager reload:nil]; Settle(2);
        [manager.table reloadData]; [manager.window.contentView layoutSubtreeIfNeeded];
        for(NSUInteger row=0;row<manager.rows.count;row++) [manager.table viewAtColumn:0 row:row makeIfNecessary:YES];
        Settle(2);
        if(manager.rows.count!=3 || manager.window.visible) return 1;
        Capture(manager.window,[output stringByAppendingPathComponent:@"collection.png"]);
        [manager showDestination:@"Settings"]; Settle(.1);
        // Show the documented default location without leaking a temporary fixture path.
        manager.locationField.stringValue=@"~/Library/Application Support/ShenzhenPDF/Collection";
        Capture(manager.window,[output stringByAppendingPathComponent:@"collection-settings.png"]);
        [fm removeItemAtPath:root error:nil];
        puts("SPDFMacReadmeProbe passed");
    }
    return 0;
}
