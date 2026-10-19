#import "SPDFMacClipboardImage.h"
#import <ImageIO/ImageIO.h>

static NSArray<NSString*>* ImageTypes(void) {
    return @[NSPasteboardTypePNG, NSPasteboardTypeTIFF, @"public.jpeg"];
}
BOOL SPDFClipboardHasDocument(NSPasteboard* pasteboard) {
    return [pasteboard.types containsObject:NSPasteboardTypeFileURL] ||
           [pasteboard availableTypeFromArray:ImageTypes()] != nil;
}
NSData* SPDFClipboardImageData(NSPasteboard* pasteboard) {
    NSString* type = [pasteboard availableTypeFromArray:ImageTypes()];
    return type ? [[pasteboard dataForType:type] copy] : nil;
}
NSString* SPDFStoreClipboardImage(NSData* data, NSString* directory, NSError** error) {
    CGImageSourceRef source = data.length ? CGImageSourceCreateWithData((__bridge CFDataRef)data, nullptr) : nullptr;
    CGImageRef image = source ? CGImageSourceCreateImageAtIndex(source, 0, nullptr) : nullptr;
    NSString* type = source ? (__bridge NSString*)CGImageSourceGetType(source) : nil;
    NSString* extension = [type isEqualToString:@"public.png"] ? @"png" :
        [type isEqualToString:@"public.tiff"] ? @"tiff" : [type isEqualToString:@"public.jpeg"] ? @"jpg" : nil;
    BOOL valid = image && extension;
    if (image) CGImageRelease(image);
    if (source) CFRelease(source);
    if (!valid) {
        if (error) *error = [NSError errorWithDomain:@"ShenzhenPDF.Clipboard" code:1
            userInfo:@{NSLocalizedDescriptionKey:@"The clipboard does not contain a readable image."}];
        return nil;
    }
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions:@0700} error:error]) return nil;
    NSString* filename = [NSString stringWithFormat:@"Pasted Image %@.%@", NSUUID.UUID.UUIDString, extension];
    NSString* path = [directory stringByAppendingPathComponent:filename];
    if (![data writeToFile:path options:NSDataWritingWithoutOverwriting | NSDataWritingFileProtectionComplete error:error]) return nil;
    [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:path error:nil];
    return path;
}
