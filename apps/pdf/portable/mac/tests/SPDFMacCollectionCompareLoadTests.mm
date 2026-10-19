#import "SPDFMacCollectionCompare.h"
#import <CoreText/CoreText.h>
#import <objc/runtime.h>

static int failures;
static NSUInteger pageRenders;
static IMP originalDraw;
static void CountDraw(id page, SEL selector, PDFDisplayBox box, CGContextRef context) {
    pageRenders++;
    ((void (*)(id,SEL,PDFDisplayBox,CGContextRef))originalDraw)(page,selector,box,context);
}
static void Expect(NSString* name, BOOL pass) {
    if (!pass) { fprintf(stderr,"FAIL: %s\n",name.UTF8String); failures++; }
}
static void DrawText(CGContextRef context, NSString* text, CGFloat x, CGFloat y) {
    NSAttributedString* attributed = [[NSAttributedString alloc] initWithString:text
        attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:12]}];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attributed);
    CGContextSetTextPosition(context,x,y); CTLineDraw(line,context); CFRelease(line);
}
static void WriteFigurePDF(NSURL* URL, NSArray<NSNumber*>* figures) {
    NSMutableData* data = [NSMutableData data];
    CGDataConsumerRef consumer = CGDataConsumerCreateWithCFData((__bridge CFMutableDataRef)data);
    CGRect box = CGRectMake(0,0,384,384);
    CGContextRef context = CGPDFContextCreate(consumer,&box,NULL); CGDataConsumerRelease(consumer);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    for (NSUInteger page = 0; page < figures.count; page++) {
        CGPDFContextBeginPage(context,NULL);
        DrawText(context,@"Shared supplier header",30,345);
        // A genuine raster figure beneath selectable repeated header text.
        CGContextRef bitmap = CGBitmapContextCreate(NULL,64,64,8,256,space,kCGImageAlphaPremultipliedLast);
        CGFloat identifier = figures[page].doubleValue;
        CGContextSetRGBFillColor(bitmap,identifier/6.0,.2,1-identifier/6.0,1);
        CGContextFillRect(bitmap,CGRectMake(0,0,64,64));
        CGContextSetRGBFillColor(bitmap,1,1,1,1);
        CGContextFillRect(bitmap,CGRectMake(identifier*7,10,5,44));
        CGImageRef image = CGBitmapContextCreateImage(bitmap);
        CGContextDrawImage(context,CGRectMake(64,100,256,192),image);
        CGImageRelease(image); CGContextRelease(bitmap);
        DrawText(context,[NSString stringWithFormat:@"Page %lu of %lu",page+1,figures.count],150,20);
        CGPDFContextEndPage(context);
    }
    CGColorSpaceRelease(space); CGPDFContextClose(context); CGContextRelease(context);
    [data writeToURL:URL atomically:YES];
}
static void CheckFigureInsertion(NSURL* oldURL, NSURL* newURL, NSUInteger insertion) {
    NSError* error = nil;
    pageRenders = 0;
    SPDFCollectionComparison* comparison = SPDFCollectionBuildComparison(oldURL,newURL,
        [NSProgress progressWithTotalUnitCount:1],&error);
    Expect(@"hybrid figure fixture retains repeated selectable header",[comparison.oldDocument.string
        containsString:@"Shared supplier header"]);
    BOOL aligned = comparison.pairs.count == 4;
    BOOL unchanged = aligned;
    for (NSUInteger slot = 0; slot < comparison.pairs.count; slot++) {
        SPDFCollectionPagePair* pair = comparison.pairs[slot];
        if (slot == insertion) {
            aligned &= pair.oldIndex == -1 && pair.newIndex == (NSInteger)slot;
            unchanged &= pair.addedRects.count == 1 && pair.removedRects.count == 0;
        } else {
            aligned &= pair.oldIndex == (NSInteger)(slot-(slot > insertion)) && pair.newIndex == (NSInteger)slot;
            unchanged &= !pair.removedRects.count && !pair.addedRects.count;
        }
    }
    Expect([NSString stringWithFormat:@"same-header figure insertion at %lu aligns following figures",insertion],aligned);
    Expect(@"unchanged figures remain unmarked despite changed page counters",unchanged);
    Expect(@"hybrid alignment renders unchanged pages only once per version",pageRenders == 7);
}
int main(void) {
    @autoreleasepool {
        NSURL* root = [NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL* oldURL = [root URLByAppendingPathComponent:@"old.md"];
        NSURL* newURL = [root URLByAppendingPathComponent:@"new.md"];
        NSString* old = @"---\npaper-size: A5\n---\n# Alpha\n\nOriginal specification.\n\n<!-- pagebreak -->\n\n# Beta\n\nUnchanged last page.\n";
        NSString* updated = @"---\npaper-size: A5\n---\n# Alpha\n\nOriginal specification.\n\n<!-- pagebreak -->\n\n# Inserted\n\nNew page.\n\n<!-- pagebreak -->\n\n# Beta\n\nUnchanged last page.\n";
        [old writeToURL:oldURL atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [updated writeToURL:newURL atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSError* error = nil;
        NSProgress* progress = [NSProgress progressWithTotalUnitCount:1];
        SPDFCollectionComparison* comparison = SPDFCollectionBuildComparison(oldURL,newURL,progress,&error);
        Expect(@"native Markdown comparison loads both versions",comparison != nil && !error);
        Expect(@"authored Markdown pagination is retained",comparison.oldDocument.pageCount == 2 &&
            comparison.updatedDocument.pageCount == 3 && comparison.pairs.count == 3);
        Expect(@"inserted Markdown page aligns unchanged following page",comparison.pairs.count == 3 &&
            comparison.pairs[1].oldIndex == -1 && comparison.pairs[2].oldIndex == 1 && comparison.pairs[2].newIndex == 2);
        Expect(@"page-number changes do not mark unchanged body content",comparison.pairs.count == 3 &&
            !comparison.pairs[0].removedRects.count && !comparison.pairs[0].addedRects.count &&
            !comparison.pairs[2].removedRects.count && !comparison.pairs[2].addedRects.count);
        Expect(@"rendered Markdown remains searchable",[comparison.updatedDocument.string containsString:@"Original specification"]);
        Expect(@"capture never changes either source",[[NSString stringWithContentsOfURL:oldURL
            encoding:NSUTF8StringEncoding error:nil] isEqual:old] && [[NSString stringWithContentsOfURL:newURL
            encoding:NSUTF8StringEncoding error:nil] isEqual:updated]);
        NSURL* figures = [root URLByAppendingPathComponent:@"figures.pdf"];
        NSURL* inserted = [root URLByAppendingPathComponent:@"figures-inserted.pdf"];
        WriteFigurePDF(figures,@[@1,@2,@3]);
        Method draw = class_getInstanceMethod(PDFPage.class,@selector(drawWithBox:toContext:));
        originalDraw = method_setImplementation(draw,(IMP)CountDraw);
        WriteFigurePDF(inserted,@[@4,@1,@2,@3]);
        CheckFigureInsertion(figures,inserted,0);
        WriteFigurePDF(inserted,@[@1,@4,@2,@3]);
        CheckFigureInsertion(figures,inserted,1);
        SPDFCollectionComparison* deletion = SPDFCollectionBuildComparison(inserted,figures,
            [NSProgress progressWithTotalUnitCount:1],nil);
        Expect(@"same-header figure deletion has the correct empty counterpart",deletion.pairs.count == 4 &&
            deletion.pairs[1].oldIndex == 1 && deletion.pairs[1].newIndex == -1 &&
            deletion.pairs[2].oldIndex == 2 && deletion.pairs[2].newIndex == 1);
        method_setImplementation(draw,originalDraw);
        NSProgress* cancelled = [NSProgress progressWithTotalUnitCount:1]; [cancelled cancel];
        Expect(@"cancelled comparison produces no partial result",!SPDFCollectionBuildComparison(oldURL,newURL,cancelled,nil));
        NSURL* missing = [root URLByAppendingPathComponent:@"missing.pdf"];
        error = nil;
        Expect(@"missing source is an explicit failure",!SPDFCollectionBuildComparison(oldURL,missing,progress,&error) && error);
        [NSFileManager.defaultManager removeItemAtURL:root error:nil];
        if (!failures) puts("SPDFMacCollectionCompareLoadTests passed");
    }
    return failures ? 1 : 0;
}
