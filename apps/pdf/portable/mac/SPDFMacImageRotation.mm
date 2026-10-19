#import "SPDFMacImageRotation.h"
#import "SPDFMacImageSave.h"
#import "SPDFMacCollectionPathPolicy.h"
#import <ImageIO/ImageIO.h>
#import <sys/stat.h>
#import "SPDFMacImageRotationPixels.h"

static BOOL Fail(NSString* message,NSError** error) {
    if(error) *error=[NSError errorWithDomain:@"ShenzhenPDF.ImageRotation" code:1
        userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
BOOL SPDFRotateImageAtPath(NSString* path,int degrees,NSError** error) {
    if(error) *error=nil;
    if(degrees!=90 && degrees!=-90) return Fail(@"Use a quarter turn.",error);
    if(SPDFMacPathIsCollectionArchive(path)) return Fail(@"Collection copies are read-only.",error);
    NSDictionary* identity=SPDFImageSaveDestinationIdentity(path);
    if(![identity[@"exists"] boolValue]) return Fail(@"The image is unavailable.",error);
    CGImageSourceRef source=CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],NULL);
    if(!source) return Fail(@"Could not decode this image.",error);
    CFStringRef type=CGImageSourceGetType(source);
    CFArrayRef writable=CGImageDestinationCopyTypeIdentifiers();
    BOOL supported=type && CFArrayContainsValue(writable,CFRangeMake(0,CFArrayGetCount(writable)),type);
    CFRelease(writable);
    if(!supported) { CFRelease(source); return Fail(@"This image format cannot be saved. Save a PNG copy before rotating.",error); }
    NSString* temporary=[path.stringByDeletingLastPathComponent stringByAppendingPathComponent:
        [@".szpdf-rotate-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    size_t count=CGImageSourceGetCount(source);
    CGImageDestinationRef destination=CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:temporary],type,count,NULL);
    BOOL ok=destination!=NULL;
    if(destination) {
        NSDictionary* properties=CFBridgingRelease(CGImageSourceCopyProperties(source,NULL));
        if(properties) CGImageDestinationSetProperties(destination,(__bridge CFDictionaryRef)properties);
    }
    BOOL metadataOnly=type && CFEqual(type,CFSTR("public.jpeg")) && count==1;
    if(ok && metadataOnly) {
        NSDictionary* properties=CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source,0,NULL));
        NSUInteger old=[properties[(__bridge NSString*)kCGImagePropertyOrientation] unsignedIntegerValue];
        if(old<1 || old>8) old=1;
        const NSUInteger clockwise[]={0,6,7,8,5,2,3,4,1};
        const NSUInteger anticlockwise[]={0,8,5,6,7,4,1,2,3};
        // JPEG orientation is honored by MuPDF. Preserve its compressed pixels
        // rather than introducing another lossy encode on each quarter turn.
        NSDictionary* options=@{(__bridge NSString*)kCGImageDestinationOrientation:
            @(degrees>0 ? clockwise[old] : anticlockwise[old])};
        ok=CGImageDestinationCopyImageSource(destination,source,(__bridge CFDictionaryRef)options,NULL);
    }
    for(size_t frame=0;ok && !metadataOnly && frame<count;frame++) {
        @autoreleasepool {
            NSMutableDictionary* properties=[CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source,frame,NULL)) mutableCopy];
            NSUInteger width=[properties[(__bridge NSString*)kCGImagePropertyPixelWidth] unsignedIntegerValue];
            NSUInteger height=[properties[(__bridge NSString*)kCGImagePropertyPixelHeight] unsignedIntegerValue];
            // Copy decoded samples with quarter-turn permutations. No color-space
            // conversion, resampling, or reduction of 16-bit/CMYK/alpha precision.
            if(!width || !height || width>32768 || height>32768 || width*height>64000000) { ok=NO; break; }
            CGImageRef image=CGImageSourceCreateImageAtIndex(source,frame,NULL);
            if(!image) { ok=NO; break; }
            NSUInteger orientation=[properties[(__bridge NSString*)kCGImagePropertyOrientation] unsignedIntegerValue];
            CGImageRef rotated=SPDFCopyQuarterTurnImage(image,orientation,degrees);
            CGImageRelease(image);
            // Unequal X/Y resolution must turn with the samples. Otherwise a
            // physically rotated scan can keep its old aspect ratio in MuPDF.
            BOOL swapAxes=orientation<5 || orientation>8;
            if(swapAxes) {
                id x=properties[(__bridge NSString*)kCGImagePropertyDPIWidth];
                id y=properties[(__bridge NSString*)kCGImagePropertyDPIHeight];
                if(x && y) {
                    properties[(__bridge NSString*)kCGImagePropertyDPIWidth]=y;
                    properties[(__bridge NSString*)kCGImagePropertyDPIHeight]=x;
                }
            }
            properties[(__bridge NSString*)kCGImagePropertyOrientation]=@1;
            // Pixel size and embedded thumbnail metadata belong to the new pixels.
            [properties removeObjectForKey:(__bridge NSString*)kCGImagePropertyPixelWidth];
            [properties removeObjectForKey:(__bridge NSString*)kCGImagePropertyPixelHeight];
            NSMutableDictionary* tiff=[properties[(__bridge NSString*)kCGImagePropertyTIFFDictionary] mutableCopy];
            if(tiff) {
                if(swapAxes) {
                    id x=tiff[(__bridge NSString*)kCGImagePropertyTIFFXResolution];
                    id y=tiff[(__bridge NSString*)kCGImagePropertyTIFFYResolution];
                    if(x && y) {
                        tiff[(__bridge NSString*)kCGImagePropertyTIFFXResolution]=y;
                        tiff[(__bridge NSString*)kCGImagePropertyTIFFYResolution]=x;
                    }
                }
                tiff[(__bridge NSString*)kCGImagePropertyTIFFOrientation]=@1;
                properties[(__bridge NSString*)kCGImagePropertyTIFFDictionary]=tiff;
            }
            if(rotated) CGImageDestinationAddImage(destination,rotated,(__bridge CFDictionaryRef)properties);
            else ok=NO;
            if(rotated) CGImageRelease(rotated);
        }
    }
    if(ok && !metadataOnly) ok=CGImageDestinationFinalize(destination);
    if(destination) CFRelease(destination); CFRelease(source);
    if(ok) {
        NSDictionary* attributes=[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        ok=[NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:attributes[NSFilePosixPermissions] ?: @0600}
            ofItemAtPath:temporary error:error];
    }
    if(ok && ![SPDFImageSaveDestinationIdentity(path) isEqual:identity]) {
        ok=Fail(@"The image changed while rotating. Try again.",error);
    }
    if(ok) ok=rename(temporary.fileSystemRepresentation,path.fileSystemRepresentation)==0;
    [NSFileManager.defaultManager removeItemAtPath:temporary error:nil];
    if(ok) return YES;
    if(error && *error) return NO;
    return Fail(@"Could not save the rotated image. The original was left unchanged. Save a PNG copy to rotate it.",error);
}
