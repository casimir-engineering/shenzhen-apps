#import "SPDFMacCollectionCompare.h"
#import <CoreText/CoreText.h>

extern void SPDFCollectionComparePair(SPDFCollectionPagePair*, PDFPage*, PDFPage*);
extern NSData* SPDFCollectionPagePixels(PDFPage*);
static int failures;
static void Expect(NSString* name, BOOL pass) {
    if (!pass) { fprintf(stderr,"FAIL: %s\n",name.UTF8String); failures++; }
}
static PDFPage* Page(NSString* text, BOOL image) {
    NSMutableData* data = [NSMutableData data];
    CGDataConsumerRef consumer = CGDataConsumerCreateWithCFData((__bridge CFMutableDataRef)data);
    CGRect box = CGRectMake(0,0,384,384);
    CGContextRef context = CGPDFContextCreate(consumer,&box,NULL);
    CGDataConsumerRelease(consumer);
    CGPDFContextBeginPage(context,NULL);
    NSAttributedString* string = [[NSAttributedString alloc] initWithString:text
        attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:14]}];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)string);
    CGContextSetTextPosition(context,30,320); CTLineDraw(line,context); CFRelease(line);
    if (image) {
        CGContextSetRGBFillColor(context,.15,.35,.8,1);
        CGContextFillRect(context,CGRectMake(60,60,96,72));
    }
    CGPDFContextEndPage(context); CGPDFContextClose(context); CGContextRelease(context);
    static NSMutableArray* documents;
    if (!documents) documents = [NSMutableArray array];
    PDFDocument* document = [[PDFDocument alloc] initWithData:data];
    [documents addObject:document];
    return [document pageAtIndex:0];
}
static void WriteEvidence(PDFPage* oldPage, PDFPage* newPage, SPDFCollectionPagePair* pair, NSString* path) {
    NSBitmapImageRep* bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:1000 pixelsHigh:570
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    NSGraphicsContext* graphics = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    CGContextRef context = graphics.CGContext;
    CGContextSetRGBFillColor(context,.94,.95,.97,1); CGContextFillRect(context,CGRectMake(0,0,1000,570));
    for (NSUInteger side = 0; side < 2; side++) {
        CGFloat x = side ? 520 : 30;
        NSString* heading = side ? @"NEW · Read-only · Added content" : @"OLD · Read-only · Removed content";
        NSAttributedString* text = [[NSAttributedString alloc] initWithString:heading
            attributes:@{NSFontAttributeName:[NSFont boldSystemFontOfSize:18]}];
        CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)text);
        CGContextSetTextPosition(context,x,525); CTLineDraw(line,context); CFRelease(line);
        CGContextSaveGState(context); CGContextTranslateCTM(context,x,45); CGContextScaleCTM(context,1.17,1.17);
        CGContextSetRGBFillColor(context,1,1,1,1); CGContextFillRect(context,CGRectMake(0,0,384,384));
        [(side ? newPage : oldPage) drawWithBox:kPDFDisplayBoxMediaBox toContext:context];
        CGContextSetRGBFillColor(context,side ? .05 : .87,side ? .65 : .12,side ? .28 : .15,.23);
        CGContextSetRGBStrokeColor(context,side ? .05 : .87,side ? .65 : .12,side ? .28 : .15,.8);
        CGContextSetLineWidth(context,1);
        for (NSValue* value in (side ? pair.addedRects : pair.removedRects)) {
            CGContextFillRect(context,value.rectValue); CGContextStrokeRect(context,value.rectValue);
        }
        CGContextRestoreGState(context);
    }
    NSData* png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    [png writeToFile:path atomically:YES];
}
int main(void) {
    @autoreleasepool {
        Expect(@"page insertion aligns later pages",[SPDFCollectionAlignPages(@[@"a",@"b",@"c"],
            @[@"a",@"insert",@"b",@"c"]) isEqual:@[@[@0,@0],@[@(-1),@1],@[@1,@2],@[@2,@3]]]);
        Expect(@"page deletion has an empty counterpart",[SPDFCollectionAlignPages(@[@"a",@"b",@"c"],
            @[@"a",@"c"]) isEqual:@[@[@0,@0],@[@1,@(-1)],@[@2,@1]]]);
        Expect(@"changed pages pair between stable anchors",[SPDFCollectionAlignPages(@[@"a",@"old",@"c"],
            @[@"a",@"new",@"c"]) isEqual:@[@[@0,@0],@[@1,@1],@[@2,@2]]]);
        Expect(@"duplicate pages keep a monotonic mapping",[SPDFCollectionAlignPages(@[@"a",@"a",@"b"],
            @[@"a",@"b"]) isEqual:@[@[@0,@0],@[@1,@(-1)],@[@2,@1]]]);
        PDFPage* old = Page(@"The blue widget",NO);
        SPDFCollectionPagePair* pair = [SPDFCollectionPagePair new];
        SPDFCollectionComparePair(pair,old,Page(@"The blue widget",NO));
        Expect(@"identical text and visuals have no differences",!pair.removedRects.count && !pair.addedRects.count);
        SPDFCollectionComparePair(pair,old,Page(@"The green widget",NO));
        Expect(@"text replacement has removed and added geometry",pair.removedRects.count && pair.addedRects.count);
        SPDFCollectionComparePair(pair,old,Page(@"The blue widget",YES));
        Expect(@"image-only addition is detected",pair.addedRects.count > 0);
        Expect(@"image addition does not label empty old space removed",!pair.removedRects.count);
        BOOL imageRegion = NO;
        for (NSValue* value in pair.addedRects) if (NSIntersectsRect(value.rectValue,NSMakeRect(60,60,96,72))) imageRegion = YES;
        Expect(@"visual highlight uses the correct page-space y coordinate",imageRegion);
        SPDFCollectionComparePair(pair,Page(@"",YES),Page(@"",NO));
        Expect(@"scanned image removal has red regions only",pair.removedRects.count && !pair.addedRects.count);
        SPDFCollectionComparePair(pair,nil,old);
        Expect(@"inserted page highlights only the new side",!pair.removedRects.count && pair.addedRects.count == 1);
        NSMutableArray* many = [NSMutableArray array];
        for (NSUInteger i = 0; i < 1000; i++) [many addObject:[NSString stringWithFormat:@"%lu",i]];
        NSMutableArray* inserted = [many mutableCopy];
        for (NSUInteger i = 0; i < 100; i++) [inserted insertObject:[NSString stringWithFormat:@"insert%lu",i] atIndex:1];
        NSArray* large = SPDFCollectionAlignPages(many,inserted);
        Expect(@"indexed anchors bridge more than 64 inserted pages",large.count == 1100 &&
            [large[101] isEqual:@[@1,@101]]);
        CFAbsoluteTime begin = CFAbsoluteTimeGetCurrent();
        Expect(@"large unchanged documents align",SPDFCollectionAlignPages(many,many).count == 1000);
        Expect(@"unchanged alignment has linear cost",CFAbsoluteTimeGetCurrent()-begin < 1);
        NSString* evidence = NSProcessInfo.processInfo.environment[@"SPDF_COLLECTION_COMPARE_EVIDENCE"];
        if (evidence.length) {
            PDFPage* revised = Page(@"The green widget",YES);
            SPDFCollectionComparePair(pair,old,revised);
            WriteEvidence(old,revised,pair,evidence);
        }
        if (!failures) puts("SPDFMacCollectionCompareTests passed");
    }
    return failures ? 1 : 0;
}
