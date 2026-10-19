#import <Cocoa/Cocoa.h>
#import <ImageIO/ImageIO.h>
#import "SPDFMacImageRotation.h"
#import "SPDFMacImageRotationPixels.h"
#import "shenzhen_pdf_core.h"
static void Check(BOOL value,NSString* label) { if(!value) { NSLog(@"FAIL %@",label); exit(1); } }
static NSData* Decode(NSString* path) {
    CGImageSourceRef source=CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],NULL);
    CGImageRef image=CGImageSourceCreateImageAtIndex(source,0,NULL);
    NSData* bytes=CFBridgingRelease(CGDataProviderCopyData(CGImageGetDataProvider(image)));
    CGImageRelease(image); CFRelease(source); return bytes;
}
static void CheckReaderSize(NSString* path,BOOL rotated) {
    char error[1024]={}; spdf_document* doc=spdf_open(path.fileSystemRepresentation,error,sizeof(error));
    Check(doc!=NULL,@"rotated file reopens in MuPDF");
    float width=0,height=0; Check(spdf_page_size(doc,0,&width,&height,error,sizeof(error)),@"size available");
    if(!(rotated ? height>width : width>height)) NSLog(@"Size mismatch %@: %g x %g, portrait=%d",path,width,height,rotated);
    Check(rotated ? height>width : width>height,@"saved orientation is understood by reader after reopen"); spdf_close(doc);
}
static void CheckSamplePreservation(void) {
    // Wide-gamut 16-bit grayscale/alpha/RGB samples must not become 8-bit sRGB.
    for(NSNumber* gray in @[@NO,@YES]) {
        size_t pixel=gray.boolValue ? 2 : 8;
        NSMutableData* samples=[NSMutableData dataWithLength:8*4*pixel];
        uint16_t* values=(uint16_t*)samples.mutableBytes;
        for(size_t i=0;i<samples.length/2;i++) values[i]=(i*347)%65536;
        CGColorSpaceRef space=gray.boolValue ? CGColorSpaceCreateDeviceGray() :
            CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);
        CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)samples);
        CGBitmapInfo info=kCGBitmapByteOrder16Little | (gray.boolValue ? kCGImageAlphaNone : kCGImageAlphaLast);
        CGImageRef image=CGImageCreate(8,4,16,pixel*8,8*pixel,space,info,provider,NULL,false,kCGRenderingIntentDefault);
        Check(image!=NULL,@"16-bit sample fixture");
        for(int i=0;i<4;i++) {
            CGImageRef turned=SPDFCopyQuarterTurnImage(image,1,90);
            Check(turned && CGImageGetBitsPerComponent(turned)==16 &&
                CFEqual(CGImageGetColorSpace(turned),space),@"rotation preserves depth and color space");
            CGImageRelease(image); image=turned;
        }
        NSData* restored=CFBridgingRelease(CGDataProviderCopyData(CGImageGetDataProvider(image)));
        Check([samples isEqual:restored],@"four turns preserve every 16-bit/alpha sample");
        CGImageRelease(image); CGDataProviderRelease(provider); CGColorSpaceRelease(space);
    }
    // Existing mirrored EXIF orientations are normalized before the quarter turn.
    unsigned char pixels[]={1,2,3,4,5,6};
    CGColorSpaceRef gray=CGColorSpaceCreateDeviceGray();
    CGDataProviderRef provider=CGDataProviderCreateWithData(NULL,pixels,sizeof(pixels),NULL);
    CGImageRef image=CGImageCreate(3,2,8,8,3,gray,kCGImageAlphaNone,provider,NULL,false,kCGRenderingIntentDefault);
    CGImageRef turned=SPDFCopyQuarterTurnImage(image,2,90);
    NSData* output=CFBridgingRelease(CGDataProviderCopyData(CGImageGetDataProvider(turned)));
    unsigned char expected[]={6,3,5,2,4,1};
    Check([output isEqual:[NSData dataWithBytes:expected length:sizeof(expected)]],@"mirrored orientation plus clockwise turn");
    CGImageRelease(turned); CGImageRelease(image); CGDataProviderRelease(provider); CGColorSpaceRelease(gray);
    unsigned char packed[]={0xA0,0x60};
    gray=CGColorSpaceCreateDeviceGray();
    provider=CGDataProviderCreateWithData(NULL,packed,sizeof(packed),NULL);
    image=CGImageCreate(3,2,1,1,1,gray,kCGImageAlphaNone,provider,NULL,false,kCGRenderingIntentDefault);
    turned=SPDFCopyQuarterTurnImage(image,1,90);
    Check(turned && CGImageGetBitsPerComponent(turned)==1,@"monochrome rotation preserves packed bit depth");
    output=CFBridgingRelease(CGDataProviderCopyData(CGImageGetDataProvider(turned)));
    unsigned char packedExpected[]={0x40,0x80,0xC0};
    Check([output isEqual:[NSData dataWithBytes:packedExpected length:sizeof(packedExpected)]],@"packed samples and row padding rotate correctly");
    CGImageRelease(turned); CGImageRelease(image); CGDataProviderRelease(provider); CGColorSpaceRelease(gray);
}
int main(void) {
    @autoreleasepool {
        CheckSamplePreservation();
        NSString* root=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
        unsigned char pixels[8*4*4];
        for(NSUInteger i=0;i<sizeof(pixels);i+=4) { pixels[i]=(i/4)*5; pixels[i+1]=40; pixels[i+2]=220; pixels[i+3]=255; }
        CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef context=CGBitmapContextCreate(pixels,8,4,8,32,space,kCGImageAlphaPremultipliedLast);
        CGImageRef image=CGBitmapContextCreateImage(context); CGContextRelease(context); CGColorSpaceRelease(space);
        for(NSString* format in @[@"png",@"jpeg",@"tiff"]) {
            NSString* path=[root stringByAppendingPathComponent:[@"image" stringByAppendingPathExtension:format]];
            CFStringRef type=[format isEqual:@"png"] ? CFSTR("public.png") : [format isEqual:@"jpeg"] ? CFSTR("public.jpeg") : CFSTR("public.tiff");
            CGImageDestinationRef out=CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],type,1,NULL);
            CGImageDestinationAddImage(out,image,(__bridge CFDictionaryRef)@{(__bridge NSString*)kCGImagePropertyOrientation:@1});
            Check(CGImageDestinationFinalize(out),@"write asymmetric fixture"); CFRelease(out);
            NSData* originalPixels=Decode(path); CheckReaderSize(path,NO);
            NSError* error=nil;
            for(int turn=0;turn<4;turn++) { Check(SPDFRotateImageAtPath(path,90,&error),error.localizedDescription ?: @"rotate saved image"); CheckReaderSize(path,turn%2==0); }
            Check([originalPixels isEqual:Decode(path)],@"four turns preserve decoded pixels (including JPEG without reencoding)");
            Check(SPDFRotateImageAtPath(path,-90,&error),@"anticlockwise saves"); CheckReaderSize(path,YES);
            Check(SPDFRotateImageAtPath(path,90,&error),@"inverse clockwise saves"); CheckReaderSize(path,NO);
            NSData* original=[NSData dataWithContentsOfFile:path];
            Check(!SPDFRotateImageAtPath(path,45,&error),@"invalid angle rejected");
            Check([original isEqual:[NSData dataWithContentsOfFile:path]],@"failure never changes source");
        }
        NSString* scan=[root stringByAppendingPathComponent:@"unequal-resolution.png"];
        CGImageDestinationRef out=CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:scan],CFSTR("public.png"),1,NULL);
        CGImageDestinationAddImage(out,image,(__bridge CFDictionaryRef)@{
            (__bridge NSString*)kCGImagePropertyDPIWidth:@200,(__bridge NSString*)kCGImagePropertyDPIHeight:@50});
        Check(CGImageDestinationFinalize(out),@"scan with unequal X/Y resolution"); CFRelease(out);
        NSError* error=nil;
        Check(SPDFRotateImageAtPath(scan,90,&error),@"scan rotates with its resolution axes");
        CGImageSourceRef source=CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:scan],NULL);
        NSDictionary* properties=CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source,0,NULL));
        Check(fabs([properties[(__bridge NSString*)kCGImagePropertyDPIWidth] doubleValue]-50)<1 &&
            fabs([properties[(__bridge NSString*)kCGImagePropertyDPIHeight] doubleValue]-200)<1,
            @"unequal X/Y resolution metadata turns with pixels");
        CFRelease(source);
        CGImageRelease(image); [NSFileManager.defaultManager removeItemAtPath:root error:nil];
        puts("SPDFMacImageRotationTests passed");
    }
    return 0;
}
