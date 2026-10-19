#import "SPDFMarkdownTestSupport.h"

#import "../../markdown/SPDFMarkdownDocument.h"
#import "../../markdown/SPDFMarkdownImageRecolor.h"

// A Markdown page is drawn natively by AppKit, so it never passes through the
// core render tail where a PDF's pixels are recolored for the dark theme. Its
// embedded images therefore used to arrive at FULL BRIGHTNESS on dark paper --
// a white screenshot glaring out of a #1E1E1E page. These tests assert the
// pixels, not the plumbing: the same luma remap now runs at draw time, only in
// the dark theme, and only while the reader has not asked to keep image colors.

// A document whose only image is pure white -- the worst case, and the one that
// makes a missing recolor obvious.
static NSURL* SPDFCreateWhiteImageDocument(NSString** temporaryRoot) {
    NSString* root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:root
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
    NSBitmapImageRep* bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                      pixelsWide:120
                                                                      pixelsHigh:120
                                                                   bitsPerSample:8
                                                                 samplesPerPixel:4
                                                                        hasAlpha:YES
                                                                        isPlanar:NO
                                                                  colorSpaceName:NSCalibratedRGBColorSpace
                                                                     bytesPerRow:0
                                                                    bitsPerPixel:0];
    for (NSInteger y = 0; y < bitmap.pixelsHigh; ++y) {
        unsigned char* row = bitmap.bitmapData + y * bitmap.bytesPerRow;
        for (NSInteger x = 0; x < bitmap.pixelsWide; ++x) {
            row[x * 4 + 0] = 255;
            row[x * 4 + 1] = 255;
            row[x * 4 + 2] = 255;
            row[x * 4 + 3] = 255;
        }
    }
    NSData* PNG = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    [PNG writeToFile:[root stringByAppendingPathComponent:@"white.png"] atomically:YES];
    NSString* documentPath = [root stringByAppendingPathComponent:@"white.md"];
    [@"# White\n\n![White proof](white.png)\n" writeToFile:documentPath
                                               atomically:YES
                                                 encoding:NSUTF8StringEncoding
                                                    error:nil];
    *temporaryRoot = root;
    return [NSURL fileURLWithPath:documentPath];
}

// Rasterizes page 0 and returns the brightest pixel it painted. The image is
// the only near-white thing a dark page could contain, so the maximum is a
// direct read of "did the image stay bright?".
static int SPDFBrightestPixel(SPDFMarkdownPaginationPlan* plan, NSAttributedString* string) {
    size_t width = (size_t)plan.configuration.paperSize.width;
    size_t height = (size_t)plan.configuration.paperSize.height;
    unsigned char* pixels = (unsigned char*)calloc(width * height, 4);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = pixels ? CGBitmapContextCreate(pixels, width, height, 8, width * 4, space,
                                                          kCGImageAlphaPremultipliedLast)
                                  : NULL;
    CGColorSpaceRelease(space);
    int brightest = -1;
    if (context) {
        [plan drawPageAtIndex:0 attributedString:string inContext:context];
        for (size_t i = 0; i < width * height; ++i) {
            int value = MIN(MIN(pixels[i * 4], pixels[i * 4 + 1]), pixels[i * 4 + 2]);
            if (value > brightest) brightest = value;
        }
        CGContextRelease(context);
    }
    free(pixels);
    return brightest;
}

static SPDFMarkdownPaginationPlan* SPDFPlan(SPDFMarkdownDocument* document, SPDFMarkdownThemeVariant variant,
                                            BOOL preservesImageColors) {
    SPDFMarkdownPageConfiguration* configuration = SPDFMarkdownPageConfiguration.A4PortraitConfiguration;
    configuration.themeVariant = variant;
    configuration.preservesImageColors = preservesImageColors;
    return [document paginationPlanForConfiguration:configuration];
}

int main(void) {
    @autoreleasepool {
        NSString* root = nil;
        NSURL* documentURL = SPDFCreateWhiteImageDocument(&root);
        NSError* error = nil;

        SPDFMarkdownDocument* light = [SPDFMarkdownDocument documentWithURL:documentURL
                                                                   options:SPDFMarkdownRenderOptions.defaultOptions
                                                                     error:&error];
        SPDFExpect(light != nil, @"the white-image fixture parses");
        if (light) {
            NSAttributedString* string = light.renderedDocument.attributedString;
            int lightMax = SPDFBrightestPixel(SPDFPlan(light, SPDFMarkdownThemeVariantLight, NO), string);
            SPDFExpect(lightMax >= 250, @"the light theme leaves a white image white");
        }

        SPDFMarkdownRenderOptions* darkOptions =
            [SPDFMarkdownRenderOptions defaultOptionsForThemeVariant:SPDFMarkdownThemeVariantDark];
        SPDFMarkdownDocument* dark = [SPDFMarkdownDocument documentWithURL:documentURL
                                                                  options:darkOptions
                                                                    error:&error];
        SPDFExpect(dark != nil, @"the fixture parses for the dark theme");
        if (dark) {
            NSAttributedString* string = dark.renderedDocument.attributedString;

            // The bug: a white image on dark paper stayed white. The threshold
            // is the theme's own ink (#DCDDDE, 220) -- the brightest thing a
            // correctly recolored dark page can contain, since the heading text
            // is drawn in it. Anything above that is un-remapped image.
            int darkMax = SPDFBrightestPixel(SPDFPlan(dark, SPDFMarkdownThemeVariantDark, NO), string);
            SPDFExpect(darkMax <= 225, @"the dark theme recolors an embedded image instead of leaving it white");

            // "Keep Image Colors in Dark Theme" is honoured, exactly as it is
            // for a PDF's images.
            int preservedMax = SPDFBrightestPixel(SPDFPlan(dark, SPDFMarkdownThemeVariantDark, YES), string);
            SPDFExpect(preservedMax >= 250, @"keeping image colors leaves the image untouched on dark paper");

            // Export and print build LIGHT plans, so a saved PDF keeps the
            // document's own colors whatever the reader is showing.
            int exportMax = SPDFBrightestPixel(SPDFPlan(dark, SPDFMarkdownThemeVariantLight, NO), string);
            SPDFExpect(exportMax >= 250, @"a light plan never recolors, so exports keep the document's colors");
        }

        // The recolor itself: chroma survives, which is the whole point of a
        // luma remap over an inversion. Pure red must stay red, not become cyan.
        NSBitmapImageRep* red = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                       pixelsWide:4
                                                                       pixelsHigh:4
                                                                    bitsPerSample:8
                                                                  samplesPerPixel:4
                                                                         hasAlpha:YES
                                                                         isPlanar:NO
                                                                   colorSpaceName:NSCalibratedRGBColorSpace
                                                                      bytesPerRow:0
                                                                     bitsPerPixel:0];
        for (NSInteger i = 0; i < 16; ++i) {
            unsigned char* pixel = red.bitmapData + i * 4;
            pixel[0] = 220;
            pixel[1] = 20;
            pixel[2] = 20;
            pixel[3] = 255;
        }
        CGImageRef recolored = SPDFMarkdownCreateDarkRecoloredImage(red.CGImage);
        SPDFExpect(recolored != NULL, @"a bitmap can be recolored");

        // A cut-out background must stay invisible. A bitmap context is
        // premultiplied, so a transparent pixel arrives as (0,0,0,0); remapping
        // it directly produced near-ink with alpha 0, which composited as a
        // bright halo around the artwork and, once the minimap downscaled it,
        // as a white sheet behind the page.
        NSBitmapImageRep* cutout = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                          pixelsWide:4
                                                                          pixelsHigh:4
                                                                       bitsPerSample:8
                                                                     samplesPerPixel:4
                                                                            hasAlpha:YES
                                                                            isPlanar:NO
                                                                      colorSpaceName:NSCalibratedRGBColorSpace
                                                                         bytesPerRow:0
                                                                        bitsPerPixel:0];
        memset(cutout.bitmapData, 0, (size_t)(cutout.bytesPerRow * cutout.pixelsHigh));
        CGImageRef cutoutOut = SPDFMarkdownCreateDarkRecoloredImage(cutout.CGImage);
        SPDFExpect(cutoutOut != NULL, @"a fully transparent bitmap can be recolored");
        if (cutoutOut) {
            NSBitmapImageRep* got = [[NSBitmapImageRep alloc] initWithCGImage:cutoutOut];
            const unsigned char* pixel = got.bitmapData;
            SPDFExpect(pixel[3] == 0, @"a transparent pixel stays transparent");
            SPDFExpect(pixel[0] == 0 && pixel[1] == 0 && pixel[2] == 0,
                       @"a transparent pixel carries no color, so it cannot halo");
            CGImageRelease(cutoutOut);
        }
        if (recolored) {
            // Read the raw bytes: -colorAtX:y: round-trips through color
            // management and does not report what was actually written.
            NSBitmapImageRep* out = [[NSBitmapImageRep alloc] initWithCGImage:recolored];
            const unsigned char* pixel = out.bitmapData;
            SPDFExpect(pixel[0] > pixel[1] + 25 && pixel[0] > pixel[2] + 25,
                       @"the luma remap keeps a red image red instead of inverting it to cyan");
            CGImageRelease(recolored);
        }

        if (root) [NSFileManager.defaultManager removeItemAtPath:root error:nil];
    }
    return SPDFFinishTests(@"SPDFMarkdownImageRecolorTests");
}
