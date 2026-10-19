#import "SPDFMacClipboardIntegration.h"
static BOOL fileHandled;
static NSString* opened;
static NSString* stateDirectory;
static NSError* failure;
@implementation ShenzhenMacDelegate
- (BOOL)openFilesFromPasteboard:(NSPasteboard*)pasteboard { (void)pasteboard; return fileHandled; }
- (NSString*)pathForStateFile:(NSString*)name { return [stateDirectory stringByAppendingPathComponent:name]; }
- (void)openPath:(NSString*)path { opened = path; }
- (void)showError:(NSString*)message detail:(NSString*)detail {
    failure = [NSError errorWithDomain:message code:1 userInfo:@{NSLocalizedDescriptionKey:detail ?: @""}];
}
@end
static void Check(BOOL ok, NSString* detail) { if (!ok) { NSLog(@"FAIL: %@", detail); exit(1); } }
int main() { @autoreleasepool {
    stateDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    ShenzhenMacDelegate* reader = [ShenzhenMacDelegate new];
    NSPasteboard* board = [NSPasteboard pasteboardWithUniqueName];
    NSBitmapImageRep* bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr pixelsWide:4 pixelsHigh:4
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    memset(bitmap.bitmapData, 128, bitmap.bytesPerRow * bitmap.pixelsHigh);
    [board declareTypes:@[NSPasteboardTypePNG] owner:nil];
    [board setData:[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] forType:NSPasteboardTypePNG];
    fileHandled = YES;
    Check([reader pasteClipboardDocument:board], @"file wins over clipboard preview");
    Check(![NSFileManager.defaultManager fileExistsAtPath:stateDirectory], @"file paste creates no image capture");
    fileHandled = NO;
    Check([reader pasteClipboardDocument:board], @"bitmap opens with no active document");
    // Mutating the private clipboard immediately must not change the queued snapshot.
    [board clearContents];
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!opened && !failure && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    Check(opened && !failure && [NSFileManager.defaultManager fileExistsAtPath:opened], @"worker materializes then opens snapshot");
    Check([opened.stringByDeletingLastPathComponent.lastPathComponent isEqual:@"Pasted Images"], @"durable capture source");
    [board declareTypes:@[NSPasteboardTypeString] owner:nil];
    [board setString:@"ordinary search" forType:NSPasteboardTypeString];
    Check(![reader pasteClipboardDocument:board], @"ordinary text remains available to Find");
    [board releaseGlobally];
    [NSFileManager.defaultManager removeItemAtPath:stateDirectory error:nil];
    NSLog(@"Clipboard routing tests passed");
} return 0; }
