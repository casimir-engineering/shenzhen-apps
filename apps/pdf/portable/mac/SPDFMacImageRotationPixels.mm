#import <Foundation/Foundation.h>
#import "SPDFMacImageRotationPixels.h"

CGImageRef SPDFCopyQuarterTurnImage(CGImageRef image, NSUInteger orientation, int degrees) {
    if(!image || (degrees!=90 && degrees!=-90)) return NULL;
    size_t width=CGImageGetWidth(image),height=CGImageGetHeight(image);
    size_t bits=CGImageGetBitsPerPixel(image),row=CGImageGetBytesPerRow(image);
    BOOL packed=bits==1 || bits==2 || bits==4;
    if(!width || !height || width>32768 || height>32768 || width*height>64000000 ||
       !bits || (!packed && bits%8) || bits>128) return NULL;
    size_t pixel=bits/8;
    if(row<(width*bits+7)/8) return NULL;
    NSData* original=CFBridgingRelease(CGDataProviderCopyData(CGImageGetDataProvider(image)));
    if(original.length<row*height) return NULL;
    if(orientation<1 || orientation>8) orientation=1;
    size_t orientedWidth=orientation>=5 ? height : width;
    size_t orientedHeight=orientation>=5 ? width : height;
    size_t targetWidth=orientedHeight,targetHeight=orientedWidth;
    size_t targetRow=(targetWidth*bits+7)/8;
    NSMutableData* samples=[NSMutableData dataWithLength:targetRow*targetHeight];
    const unsigned char* source=(const unsigned char*)original.bytes;
    unsigned char* target=(unsigned char*)samples.mutableBytes;
    for(size_t y=0;y<height;y++) for(size_t x=0;x<width;x++) {
        size_t ox=x,oy=y;
        // EXIF coordinates include mirrored orientations, not only rotations.
        switch(orientation) {
            case 2: ox=width-1-x; break;
            case 3: ox=width-1-x; oy=height-1-y; break;
            case 4: oy=height-1-y; break;
            case 5: ox=y; oy=x; break;
            case 6: ox=height-1-y; oy=x; break;
            case 7: ox=height-1-y; oy=width-1-x; break;
            case 8: ox=y; oy=width-1-x; break;
        }
        size_t tx=degrees>0 ? orientedHeight-1-oy : oy;
        size_t ty=degrees>0 ? ox : orientedWidth-1-ox;
        if(packed) {
            // Preserve packed monochrome/indexed scans, including row padding.
            unsigned value=(source[y*row+x*bits/8] >> (8-bits-x*bits%8)) & ((1u<<bits)-1);
            target[ty*targetRow+tx*bits/8] |= value << (8-bits-tx*bits%8);
        } else memcpy(target+ty*targetRow+tx*pixel,source+y*row+x*pixel,pixel);
    }
    CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)samples);
    CGImageRef result=CGImageCreate(targetWidth,targetHeight,CGImageGetBitsPerComponent(image),bits,
        targetRow,CGImageGetColorSpace(image),CGImageGetBitmapInfo(image),provider,
        CGImageGetDecode(image),false,CGImageGetRenderingIntent(image));
    CGDataProviderRelease(provider);
    return result;
}
