#import "SPDFMacClipboardImage.h"
#import <ImageIO/ImageIO.h>
static void Check(BOOL ok, NSString* detail) { if (!ok) { NSLog(@"FAIL: %@", detail); exit(1); } }
int main() { @autoreleasepool {
    NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSPasteboard* board = [NSPasteboard pasteboardWithUniqueName];
    [board declareTypes:@[NSPasteboardTypeString] owner:nil];
    [board setString:@"hello" forType:NSPasteboardTypeString];
    Check(!SPDFClipboardHasDocument(board), @"text stays text");
    Check(!SPDFClipboardImageData(board), @"text has no bitmap");
    [board declareTypes:@[NSPasteboardTypePNG] owner:nil];
    Check(SPDFClipboardHasDocument(board), @"advertised type enables paste without decoding");
    Check(![NSFileManager.defaultManager fileExistsAtPath:directory], @"availability does not create storage");
    NSError* error = nil;
    Check(!SPDFStoreClipboardImage([@"invalid" dataUsingEncoding:NSUTF8StringEncoding], directory, &error) && error,
          @"invalid image rejected");
    Check(![NSFileManager.defaultManager fileExistsAtPath:directory], @"invalid data creates no storage");
    NSBitmapImageRep* bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr pixelsWide:12 pixelsHigh:8
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    memset(bitmap.bitmapData, 128, bitmap.bytesPerRow * bitmap.pixelsHigh);
    for (NSNumber* format in @[@(NSBitmapImageFileTypePNG), @(NSBitmapImageFileTypeTIFF), @(NSBitmapImageFileTypeJPEG)]) {
        NSData* data = [bitmap representationUsingType:(NSBitmapImageFileType)format.integerValue properties:@{}];
        Check(data.length > 0, @"fixture encoded");
        error = nil;
        NSString* path = SPDFStoreClipboardImage(data, directory, &error);
        Check(path && !error, @"image stored");
        Check([[NSData dataWithContentsOfFile:path] isEqual:data], @"original image bytes retained");
        NSString* second = SPDFStoreClipboardImage(data, directory, &error);
        Check(second && ![second isEqual:path], @"repeat paste does not overwrite");
        Check([[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFilePosixPermissions] intValue] == 0600,
              @"capture is private");
        if (format.integerValue == NSBitmapImageFileTypePNG) {
            [board setData:data forType:NSPasteboardTypePNG];
            Check([SPDFClipboardImageData(board) isEqual:data], @"clipboard snapshot preserves bitmap");
            NSBitmapImageRep* read = [NSBitmapImageRep imageRepWithData:[NSData dataWithContentsOfFile:path]];
            Check(read.pixelsWide == 12 && read.pixelsHigh == 8 && read.hasAlpha && read.bitmapData[3] == 128, @"size and transparency retained");
        }
    }
    [board declareTypes:@[NSPasteboardTypeFileURL] owner:nil];
    Check(SPDFClipboardHasDocument(board), @"file paste available with no document");
    [board releaseGlobally];
    [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
    NSLog(@"Clipboard image tests passed");
} return 0; }
