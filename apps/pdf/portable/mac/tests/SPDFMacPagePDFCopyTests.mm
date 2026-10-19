#import "SPDFMacPagePDFCopy.h"
#import "SPDFMacContextPage.h"
#import <ImageIO/ImageIO.h>
#import <PDFKit/PDFKit.h>

static void Check(BOOL okay, NSString* message) {
    if (!okay) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static CGImageRef Image(NSUInteger width, NSUInteger height, unsigned char alpha) {
    NSMutableData* pixels = [NSMutableData dataWithLength:width*height*4];
    unsigned char* bytes = (unsigned char*)pixels.mutableBytes;
    for (NSUInteger i=0; i<pixels.length; i+=4) { bytes[i]=alpha; bytes[i+3]=alpha; }
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(bytes,width,height,8,width*4,space,kCGImageAlphaPremultipliedLast);
    CGImageRef image = CGBitmapContextCreateImage(context); CGContextRelease(context); CGColorSpaceRelease(space); return image;
}
static void ImageFile(NSString* path, BOOL tiff) {
    CGImageDestinationRef writer = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],
        tiff ? CFSTR("public.tiff") : CFSTR("public.png"), tiff ? 2 : 1, NULL);
    CGImageRef first = Image(40,20,128); CGImageDestinationAddImage(writer,first,NULL); CGImageRelease(first);
    if (tiff) { CGImageRef second = Image(20,60,255); CGImageDestinationAddImage(writer,second,NULL); CGImageRelease(second); }
    Check(CGImageDestinationFinalize(writer), @"fixture writes"); CFRelease(writer);
}
int main(int argc, const char* argv[]) {
    @autoreleasepool {
        Check(argc==2,@"repository required");
        NSPasteboard* board = [NSPasteboard pasteboardWithUniqueName];
        NSString* folder = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
        NSMutableArray* outputs = [NSMutableArray array];
        for (NSString* ext in @[@"png",@"tiff"]) {
            NSString* source = [folder stringByAppendingPathComponent:[@"Picture." stringByAppendingString:ext]];
            ImageFile(source,[ext isEqual:@"tiff"]);
            NSData* original = [NSData dataWithContentsOfFile:source];
            char message[1024]={}; spdf_document* document = spdf_open(source.fileSystemRepresentation,message,sizeof(message));
            Check(document!=NULL,@"image opens");
            // Counter remains on page one while context menu points at TIFF page two.
            NSInteger pointerPage=[ext isEqual:@"tiff"]?1:0;
            NSMenuItem* item=[NSMenuItem new]; item.representedObject=@(pointerPage);
            NSInteger selected=SPDFMacPageIndexForActionSender(item,-1,0);
            NSError* error=nil;
            SPDFMacPagePDFCopy* copy=SPDFCreatePagePDFCopy(document,selected,source,&error);
            Check(copy && SPDFWritePagePDFCopy(copy,board),error.localizedDescription ?: @"image page copies as PDF");
            [outputs addObject:copy.fileURL.URLByDeletingLastPathComponent];
            NSData* data=[board dataForType:NSPasteboardTypePDF];
            Check([data isEqual:copy.data] && [[board stringForType:NSPasteboardTypeFileURL] isEqual:copy.fileURL.absoluteString],
                @"private clipboard contains PDF bytes and usable file URL");
            PDFDocument* result=[[PDFDocument alloc] initWithData:data];
            Check(result.pageCount==1,@"copy is exactly one page");
            NSRect bounds=[[result pageAtIndex:0] boundsForBox:kPDFDisplayBoxMediaBox];
            Check([ext isEqual:@"tiff"] ? bounds.size.height>bounds.size.width*2 : bounds.size.width>bounds.size.height,
                @"copied dimensions match page under pointer, not current counter");
            Check([[NSData dataWithContentsOfFile:source] isEqual:original],@"copy never modifies source image");
            if ([ext isEqual:@"png"]) {
                CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
                CGPDFDocumentRef pdf=CGPDFDocumentCreateWithProvider(provider);
                unsigned char pixels[20*20*4]={}; CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
                CGContextRef context=CGBitmapContextCreate(pixels,20,20,8,80,space,kCGImageAlphaPremultipliedLast);
                CGPDFPageRef page=CGPDFDocumentGetPage(pdf,1);
                CGContextConcatCTM(context,CGPDFPageGetDrawingTransform(page,kCGPDFMediaBox,CGRectMake(0,0,20,20),0,YES));
                CGContextDrawPDFPage(context,page);
                Check(pixels[(10*20+10)*4+3]>100 && pixels[(10*20+10)*4+3]<160,@"PNG alpha survives PDF clipboard copy");
                CGContextRelease(context); CGColorSpaceRelease(space); CGPDFDocumentRelease(pdf); CGDataProviderRelease(provider);
            }
            NSInteger change=board.changeCount;
            Check(!SPDFCreatePagePDFCopy(document,9,source,&error) && !SPDFWritePagePDFCopy(nil,board) && board.changeCount==change,
                @"invalid page leaves clipboard untouched");
            spdf_close(document);
            // The previous PDF path still grafts an original page without rasterizing it.
            document=spdf_open(copy.fileURL.path.fileSystemRepresentation,message,sizeof(message));
            SPDFMacPagePDFCopy* copiedPDF=SPDFCreatePagePDFCopy(document,0,copy.fileURL.path,&error);
            Check(copiedPDF && [[PDFDocument alloc] initWithData:copiedPDF.data].pageCount==1,@"existing PDF copy remains available");
            [outputs addObject:copiedPDF.fileURL.URLByDeletingLastPathComponent]; spdf_close(document);
        }
        NSString* root=[@(argv[1]) stringByAppendingPathComponent:@"portable/mac"];
        NSString* actions=[NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:@"SPDFMacMarkdownFileActions.mm"] encoding:NSUTF8StringEncoding error:nil];
        NSString* menu=[NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:@"SPDFMacContextMenuIntegration.mm"] encoding:NSUTF8StringEncoding error:nil];
        Check([actions containsString:@"SPDFCreatePagePDFCopy(document, pageIndex, path, &error)"] &&
            [actions containsString:@"dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)"] &&
            [menu containsString:@"copyPage.enabled = [self canCopyPageAsPDFAtIndex:copyPageIndex]"],
            @"reader routes image copy off-thread and checks the context page");
        for (NSURL* output in outputs) [NSFileManager.defaultManager removeItemAtURL:output error:nil];
        [NSFileManager.defaultManager removeItemAtPath:folder error:nil]; [board releaseGlobally];
        printf("SPDFMacPagePDFCopyTests passed\n");
    }
    return 0;
}
