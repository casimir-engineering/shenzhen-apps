// Draws every animal of the bundled set from its generated PDF, at 64 px and 28 px, on a light and a dark
// panel, into one PNG for review (avatars/preview/contact-sheet.png).
//
// WHY from the PDFs with Quartz rather than from the SVGs: AppKit draws the PDFs, so this shows exactly what
// the dropdown will show, including anything the SVG-to-PDF conversion changed. WHY 1x pixels: the smallest
// avatar is 28 pt, and at 1x that is 28 pixels, the hardest case for legibility; 2x only gets easier.
//
// Usage: SZFriendsContactSheet <manifest.json> <output.png>   (make -C portable friends-avatars-preview)

#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>

#import "avatars/SZFriendsAvatars.h"

static const CGFloat kColumns = 8;
static const CGFloat kCellWidth = 92;
static const CGFloat kCellHeight = 132;
static const CGFloat kMargin = 16;
static const CGFloat kTitleHeight = 22;

static void fillRGB(CGContextRef context, CGFloat r, CGFloat g, CGFloat b, CGRect rect) {
    CGContextSetRGBFillColor(context, r, g, b, 1);
    CGContextFillRect(context, rect);
}

static void drawPDF(CGContextRef context, NSString *path, CGRect target) {
    CGPDFDocumentRef document = CGPDFDocumentCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path]);
    CGPDFPageRef page = document ? CGPDFDocumentGetPage(document, 1) : NULL;
    if (!page) {
        // A missing or broken PDF must be impossible to overlook on the sheet.
        fillRGB(context, 1, 0, 0, target);
        if (document) CGPDFDocumentRelease(document);
        return;
    }
    CGRect box = CGPDFPageGetBoxRect(page, kCGPDFMediaBox);
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, target.origin.x, target.origin.y);
    CGContextScaleCTM(context, target.size.width / box.size.width, target.size.height / box.size.height);
    CGContextTranslateCTM(context, -box.origin.x, -box.origin.y);
    CGContextDrawPDFPage(context, page);
    CGContextRestoreGState(context);
    CGPDFDocumentRelease(document);
}

static void drawLabel(CGContextRef context, NSString *text, CGFloat centerX, CGFloat baselineY, CGFloat gray) {
    CTFontRef font = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 10, NULL);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat components[] = {gray, gray, gray, 1};
    CGColorRef color = CGColorCreate(space, components);
    NSDictionary *attributes = @{(__bridge id)kCTFontAttributeName : (__bridge id)font,
                                 (__bridge id)kCTForegroundColorAttributeName : (__bridge id)color};
    NSAttributedString *string = [[NSAttributedString alloc] initWithString:text attributes:attributes];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)string);
    CGFloat width = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    CGContextSetTextPosition(context, centerX - width / 2, baselineY);
    CTLineDraw(line, context);
    CFRelease(line);
    CGColorRelease(color);
    CGColorSpaceRelease(space);
    CFRelease(font);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) {
            fprintf(stderr, "usage: %s <manifest.json> <output.png>\n", argv[0]);
            return 2;
        }
        NSError *error = nil;
        SZFriendsAnimalSet *set = [SZFriendsAnimalSet setWithManifestAtPath:@(argv[1]) error:&error];
        if (!set) {
            fprintf(stderr, "contact sheet: %s\n", error.localizedDescription.UTF8String);
            return 1;
        }
        NSInteger rows = (set.count + (NSInteger)kColumns - 1) / (NSInteger)kColumns;
        CGFloat panelHeight = kTitleHeight + rows * kCellHeight;
        size_t width = (size_t)(kMargin * 2 + kColumns * kCellWidth);
        size_t height = (size_t)(kMargin * 3 + panelHeight * 2);

        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, 0, space,
                                                     (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        // Top-left origin: easier to lay out rows downwards. Text is drawn with a local flip below.
        CGContextTranslateCTM(context, 0, height);
        CGContextScaleCTM(context, 1, -1);
        fillRGB(context, 0.5, 0.5, 0.5, CGRectMake(0, 0, width, height));

        // Panel colors approximate macOS popover backgrounds in each appearance, where the dropdown lives.
        const CGFloat panelGray[2] = {0.95, 0.16};
        const CGFloat labelGray[2] = {0.35, 0.70};
        const char *titles[2] = {"Light", "Dark"};
        for (int panel = 0; panel < 2; panel++) {
            CGFloat top = kMargin + panel * (panelHeight + kMargin);
            CGFloat g = panelGray[panel];
            fillRGB(context, g, g, g, CGRectMake(kMargin, top, kColumns * kCellWidth, panelHeight));
            for (NSInteger i = 0; i < set.count; i++) {
                CGFloat x = kMargin + (i % (NSInteger)kColumns) * kCellWidth;
                CGFloat y = top + kTitleHeight + (i / (NSInteger)kColumns) * kCellHeight;
                CGFloat center = x + kCellWidth / 2;
                NSString *pdf = [set pdfPathAtIndex:i];
                // Drawn in a flipped context, so flip each image back to upright.
                for (int size = 0; size < 2; size++) {
                    CGFloat side = size == 0 ? 64 : 28;
                    CGFloat imageTop = size == 0 ? y + 6 : y + 78;
                    CGContextSaveGState(context);
                    CGContextTranslateCTM(context, 0, imageTop + side);
                    CGContextScaleCTM(context, 1, -1);
                    drawPDF(context, pdf, CGRectMake(floor(center - side / 2), 0, side, side));
                    CGContextRestoreGState(context);
                }
                CGContextSaveGState(context);
                CGContextTranslateCTM(context, 0, y + 124);
                CGContextScaleCTM(context, 1, -1);
                NSString *label = [NSString stringWithFormat:@"%ld %@", (long)i, [set nameAtIndex:i]];
                drawLabel(context, label, center, 0, labelGray[panel]);
                CGContextRestoreGState(context);
            }
            CGContextSaveGState(context);
            CGContextTranslateCTM(context, 0, top + 15);
            CGContextScaleCTM(context, 1, -1);
            drawLabel(context, @(titles[panel]), kMargin + 30, 0, labelGray[panel]);
            CGContextRestoreGState(context);
        }

        CGImageRef image = CGBitmapContextCreateImage(context);
        NSURL *url = [NSURL fileURLWithPath:@(argv[2])];
        CGImageDestinationRef destination =
            CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
        BOOL ok = destination != NULL;
        if (ok) {
            CGImageDestinationAddImage(destination, image, NULL);
            ok = CGImageDestinationFinalize(destination);
            CFRelease(destination);
        }
        CGImageRelease(image);
        CGContextRelease(context);
        CGColorSpaceRelease(space);
        if (!ok) {
            fprintf(stderr, "contact sheet: could not write %s\n", argv[2]);
            return 1;
        }
        printf("Wrote %s (%ld animals)\n", argv[2], (long)set.count);
    }
    return 0;
}
