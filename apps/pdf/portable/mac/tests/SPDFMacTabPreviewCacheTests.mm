// Tab hover thumbnails, headless: the page's orientation and shape survive from
// the file (/Rotate) through the core render to the thumbnail, page pixels are
// read in place, and thirty tabs at 2x fit the byte budget with the least
// recently hovered going first.
#import <Cocoa/Cocoa.h>
#include <mach/mach.h>

#import "SPDFMacTabPreviewCache.h"
#include "shenzhen_pdf_core.h"

static void expect(BOOL condition, NSString* message) {
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
}

// One 300 x 420 pt page per entry of `rotations`: a red band along its top edge
// and a black square in its bottom-left corner, with that /Rotate.
static NSString* WritePDF(NSArray<NSNumber*>* rotations) {
    NSMutableArray<NSData*>* objects = [NSMutableArray array];
    void (^add)(NSString*) = ^(NSString* body) { [objects addObject:[body dataUsingEncoding:NSASCIIStringEncoding]]; };
    NSString* content = @"1 0 0 rg 0 360 300 60 re f 0 0 0 rg 16 16 56 56 re f";
    add([NSString stringWithFormat:@"<</Length %lu>>stream\n%@\nendstream", (unsigned long)content.length, content]);
    NSInteger pages = 2 + (NSInteger)rotations.count;
    NSMutableArray* kids = [NSMutableArray array];
    for (NSNumber* rotation in rotations) {
        add([NSString stringWithFormat:@"<</Type/Page/Parent %ld 0 R/MediaBox[0 0 300 420]/Rotate %@/Contents 1 0 R>>",
                                       (long)pages, rotation]);
        [kids addObject:[NSString stringWithFormat:@"%lu 0 R", (unsigned long)objects.count]];
    }
    add([NSString stringWithFormat:@"<</Type/Pages/Kids[%@]/Count %lu>>", [kids componentsJoinedByString:@" "],
                                   (unsigned long)rotations.count]);
    add([NSString stringWithFormat:@"<</Type/Catalog/Pages %ld 0 R>>", (long)pages]);
    NSMutableData* out = [[@"%PDF-1.4\n" dataUsingEncoding:NSASCIIStringEncoding] mutableCopy];
    NSMutableArray* offsets = [NSMutableArray array];
    for (NSUInteger i = 0; i < objects.count; i++) {
        [offsets addObject:@(out.length)];
        [out appendData:[[NSString stringWithFormat:@"%lu 0 obj", (unsigned long)i + 1] dataUsingEncoding:NSASCIIStringEncoding]];
        [out appendData:objects[i]];
        [out appendData:[@"endobj\n" dataUsingEncoding:NSASCIIStringEncoding]];
    }
    NSMutableString* xref = [NSMutableString stringWithFormat:@"xref\n0 %lu\n0000000000 65535 f \n",
                                                               (unsigned long)objects.count + 1];
    for (NSNumber* offset in offsets) [xref appendFormat:@"%010lu 00000 n \n", offset.unsignedLongValue];
    NSUInteger start = out.length;
    [xref appendFormat:@"trailer<</Size %lu/Root %lu 0 R>>\nstartxref\n%lu\n%%%%EOF\n", (unsigned long)objects.count + 1,
                       (unsigned long)objects.count, (unsigned long)start];
    [out appendData:[xref dataUsingEncoding:NSASCIIStringEncoding]];
    NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"spdf-tab-preview-%d.pdf", getpid()]];
    expect([out writeToFile:path atomically:YES], @"could not write the fixture PDF");
    return path;
}

static NSString* Colour(NSBitmapImageRep* rep, double fx, double fy) {
    NSColor* c = [[rep colorAtX:(NSInteger)(fx * (rep.pixelsWide - 1)) y:(NSInteger)(fy * (rep.pixelsHigh - 1))]
        colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (c.redComponent > 0.7 && c.greenComponent < 0.3 && c.blueComponent < 0.3) return @"red";
    if (c.redComponent < 0.25 && c.greenComponent < 0.25 && c.blueComponent < 0.25) return @"black";
    return c.redComponent > 0.9 && c.greenComponent > 0.9 ? @"white" : @"other";
}

// Renders `page` the way a tab not shown since launch gets its thumbnail.
static NSBitmapImageRep* Thumbnail(spdf_document* doc, int page, NSSize* points) {
    float width = 0, height = 0;
    char err[256];
    expect(spdf_page_size(doc, page, &width, &height, err, sizeof err), @"page size");
    *points = SPDFTabPreviewPointSize(NSMakeSize(width, height), kSPDFTabPreviewMaxPoints);
    spdf_bitmap bitmap = {};
    expect(spdf_render_page_rgba_opts(doc, page, (float)(points->width * 2 / width), SPDF_RENDER_DEFAULT, NULL, &bitmap,
                                      err, sizeof err), @"render");
    CGImageRef image = SPDFTabPreviewCreateImageFromRGBA(bitmap.rgba, bitmap.width, bitmap.height, bitmap.stride);
    spdf_free_bitmap(&bitmap);
    CGImageRef thumbnail = SPDFTabPreviewCreateThumbnail(image, (size_t)points->width * 2, (size_t)points->height * 2);
    CGImageRelease(image);
    NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithCGImage:thumbnail];
    CGImageRelease(thumbnail);
    return rep;
}

static void check_orientation(void) {
    NSString* path = WritePDF(@[ @0, @90, @180, @270 ]);
    char err[256];
    spdf_document* doc = spdf_open(path.fileSystemRepresentation, err, sizeof err);
    expect(doc && spdf_page_count(doc) == 4, @"fixture opens with 4 pages");
    // The band is the page's top: where it ends up names the turn.
    NSArray* edges = @[ @"top", @"right", @"bottom", @"left" ];
    for (int page = 0; page < 4; page++) {
        NSSize points;
        NSBitmapImageRep* rep = Thumbnail(doc, page, &points);
        BOOL turned = page % 2 == 1;
        expect(turned ? (points.width == 220 && points.height == 157) : (points.width == 157 && points.height == 220),
               [NSString stringWithFormat:@"page %d thumbnail is %@ pt", page, NSStringFromSize(points)]);
        expect(rep.pixelsWide == (NSInteger)points.width * 2, @"thumbnail is drawn at 2x");
        NSDictionary* at = @{@"top" : Colour(rep, 0.5, 0.02), @"right" : Colour(rep, 0.98, 0.5),
                             @"bottom" : Colour(rep, 0.5, 0.98), @"left" : Colour(rep, 0.02, 0.5)};
        for (NSString* edge in edges)
            expect([at[edge] isEqual:@"red"] == [edge isEqual:edges[(NSUInteger)page]],
                   [NSString stringWithFormat:@"/Rotate %d: band expected on the %@ edge, found %@", page * 90,
                                              edges[(NSUInteger)page], at]);
    }
    spdf_close(doc);
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
}

static double FootprintMB(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
    return info.phys_footprint / 1048576.0;
}

static void check_in_place_pixels(void) {
    // Thirty page images like a restored session's (492 x 700), each scaled to a thumbnail once.
    NSMutableArray* pages = [NSMutableArray array];
    for (int i = 0; i < 30; i++) {
        NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:492 pixelsHigh:700
            bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
            bytesPerRow:0 bitsPerPixel:32];
        for (NSInteger y = 0; y < 700; y++)
            for (NSInteger x = 0; x < 492; x++) {
                unsigned char* p = rep.bitmapData + y * rep.bytesPerRow + x * 4;
                BOOL band = y < 100; // top rows of the bitmap: the page's top
                p[0] = 255, p[1] = band ? 0 : 255, p[2] = band ? 0 : 255, p[3] = 255;
            }
        [pages addObject:rep];
    }
    double before = FootprintMB();
    for (NSBitmapImageRep* rep in pages) @autoreleasepool { // what is kept, not what waits for the pool to drain
        CGImageRef source = SPDFTabPreviewCreateImageReadingRep(rep);
        expect(source != NULL, @"an 8-bit RGBA page image is read");
        CGImageRef thumbnail = SPDFTabPreviewCreateThumbnail(source, 155, 220);
        CGImageRelease(source);
        NSBitmapImageRep* out = [[NSBitmapImageRep alloc] initWithCGImage:thumbnail];
        CGImageRelease(thumbnail);
        expect([Colour(out, 0.5, 0.03) isEqual:@"red"] && [Colour(out, 0.5, 0.9) isEqual:@"white"],
               @"in-place pixels keep the page's top at the top");
    }
    double growth = FootprintMB() - before;
    // -[NSBitmapImageRep CGImage] kept 1.4 MB per page here: 41 MB.
    expect(growth < 8.0, [NSString stringWithFormat:@"scaling 30 page images grew memory by %.1f MB", growth]);
    NSBitmapImageRep* planar = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:8 pixelsHigh:8
        bitsPerSample:8 samplesPerPixel:3 hasAlpha:NO isPlanar:YES colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0
        bitsPerPixel:0];
    expect(SPDFTabPreviewCreateImageReadingRep(planar) == NULL, @"a layout it cannot read is refused, not misread");
}

static SPDFTabPreviewEntry* Entry(size_t width, size_t height) {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, 0, space,
                                                 kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
    SPDFTabPreviewEntry* entry = [[SPDFTabPreviewEntry alloc] initWithImage:image
                                                                  pointSize:NSMakeSize(width / 2.0, height / 2.0)
                                                                  pageIndex:0];
    CGImageRelease(image);
    return entry;
}

static void check_budget(void) {
    SPDFTabPreviewCache* cache = [[SPDFTabPreviewCache alloc] initWithByteBudget:kSPDFTabPreviewByteBudget];
    NSMutableArray* tabs = [NSMutableArray array];
    // Thirty A4 portrait tabs at 2x: 310 x 440 px each.
    NSSize points = SPDFTabPreviewPointSize(NSMakeSize(595, 842), kSPDFTabPreviewMaxPoints);
    for (int i = 0; i < 30; i++) {
        NSObject* tab = [NSObject new];
        [tabs addObject:tab];
        [cache setEntry:Entry((size_t)points.width * 2, (size_t)points.height * 2) forTab:tab];
    }
    expect(cache.count == 30, [NSString stringWithFormat:@"30 tabs at 2x keep every thumbnail (%lu kept, %.1f MB)",
                                                         (unsigned long)cache.count, cache.byteCount / 1048576.0]);
    expect(cache.byteCount <= kSPDFTabPreviewByteBudget, @"30 tabs at 2x stay within the budget");
    fprintf(stderr, "30 A4 tabs at 2x: %.1f MB of thumbnails (budget %.0f MB)\n", cache.byteCount / 1048576.0,
            kSPDFTabPreviewByteBudget / 1048576.0);
    // Hovering tab 0 makes it recent; twenty more tabs push out the oldest, not it.
    expect([cache entryForTab:tabs[0]] != nil, @"tab 0 is cached");
    for (int i = 0; i < 20; i++) {
        NSObject* tab = [NSObject new];
        [tabs addObject:tab];
        [cache setEntry:Entry((size_t)points.width * 2, (size_t)points.height * 2) forTab:tab];
    }
    expect(cache.byteCount <= kSPDFTabPreviewByteBudget, @"50 tabs stay within the budget");
    expect([cache entryForTab:tabs[0]] != nil, @"the most recently hovered tab is kept");
    expect([cache entryForTab:tabs[1]] == nil, @"the least recently used tab goes first");
    expect([cache entryForTab:tabs.lastObject] != nil, @"the newest tab is kept");
    // A closed tab takes its thumbnail with it.
    NSUInteger before = cache.count;
    @autoreleasepool {
        NSObject* closing = [NSObject new];
        [cache setEntry:Entry(64, 64) forTab:closing];
        expect(cache.count == before + 1, @"a small thumbnail is added");
    }
    expect(cache.count == before, @"a closed tab's thumbnail is released");
}

static void check_geometry(void) {
    expect(NSEqualSizes(SPDFTabPreviewPointSize(NSMakeSize(595, 842), 220), NSMakeSize(155, 220)), @"A4 portrait");
    expect(NSEqualSizes(SPDFTabPreviewPointSize(NSMakeSize(842, 595), 220), NSMakeSize(220, 155)), @"A4 landscape");
    expect(NSEqualSizes(SPDFTabPreviewPointSize(NSMakeSize(0, 842), 220), NSZeroSize), @"no page, no thumbnail");
    expect(SPDFTabPreviewPointSize(NSMakeSize(80, 2000), 220).width == 24, @"a receipt keeps a visible width");
}

int main(void) {
    @autoreleasepool {
        check_geometry();
        check_orientation();
        check_in_place_pixels();
        check_budget();
        printf("SPDF mac tab hover preview tests passed\n");
    }
    return 0;
}
