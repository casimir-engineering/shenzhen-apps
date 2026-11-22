#import "SPDFMacSignatureOutlines.h"

#import <CoreText/CoreText.h>

@implementation SPDFSignatureStroke {
    NSMutableArray<NSValue*>* _points;
    NSMutableArray<NSNumber*>* _times;
}
- (instancetype)init {
    if ((self = [super init])) {
        _points = [NSMutableArray array];
        _times = [NSMutableArray array];
    }
    return self;
}
- (NSMutableArray<NSValue*>*)points { return _points; }
- (NSMutableArray<NSNumber*>*)times { return _times; }
- (void)addPoint:(NSPoint)point time:(NSTimeInterval)time {
    NSValue* last = _points.lastObject;
    if (last && hypot(last.pointValue.x - point.x, last.pointValue.y - point.y) < 1.5) return;
    [_points addObject:[NSValue valueWithPoint:point]];
    [_times addObject:@(time)];
}
@end

static NSPoint P(SPDFSignatureStroke* s, NSInteger i) {
    i = MAX(0, MIN(i, (NSInteger)s.points.count - 1));
    return s.points[(NSUInteger)i].pointValue;
}

// Catmull-Rom through the points, as cubic Beziers: segment i runs from point i to point i + 1.
static void SPDFCatmullRomControls(SPDFSignatureStroke* s, NSInteger i, NSPoint* c1, NSPoint* c2) {
    NSPoint p0 = P(s, i - 1), p1 = P(s, i), p2 = P(s, i + 1), p3 = P(s, i + 2);
    *c1 = NSMakePoint(p1.x + (p2.x - p0.x) / 6.0, p1.y + (p2.y - p0.y) / 6.0);
    *c2 = NSMakePoint(p2.x - (p3.x - p1.x) / 6.0, p2.y - (p3.y - p1.y) / 6.0);
}

NSBezierPath* SPDFSignatureSmoothedStroke(SPDFSignatureStroke* stroke) {
    NSBezierPath* path = [NSBezierPath bezierPath];
    NSInteger count = (NSInteger)stroke.points.count;
    if (count == 0) return path;
    [path moveToPoint:P(stroke, 0)];
    if (count == 1) {
        [path lineToPoint:NSMakePoint(P(stroke, 0).x + 0.5, P(stroke, 0).y)];
        return path;
    }
    for (NSInteger i = 0; i + 1 < count; ++i) {
        NSPoint c1, c2;
        SPDFCatmullRomControls(stroke, i, &c1, &c2);
        [path curveToPoint:P(stroke, i + 1) controlPoint1:c1 controlPoint2:c2];
    }
    return path;
}

static void SPDFAppendOutline(CGMutablePathRef out, CGPathRef centerline, CGFloat width) {
    CGPathRef outline = CGPathCreateCopyByStrokingPath(centerline, NULL, width, kCGLineCapRound, kCGLineJoinRound, 4);
    if (outline) {
        CGPathAddPath(out, NULL, outline);
        CGPathRelease(outline);
    }
}

struct SPDFOutlineWriter {
    NSMutableString* text;
    CGRect box;
};

static NSString* SPDFNumber(CGFloat v) {
    NSString* s = [NSString stringWithFormat:@"%.3f", v];
    while ([s containsString:@"."] && ([s hasSuffix:@"0"] || [s hasSuffix:@"."])) s = [s substringToIndex:s.length - 1];
    return [s isEqual:@"-0"] ? @"0" : s;
}

static void SPDFWriteElement(void* info, const CGPathElement* element) {
    SPDFOutlineWriter* w = (SPDFOutlineWriter*)info;
    CGFloat h = MAX(0.001, w->box.size.height);
    auto pt = [&](CGPoint p) {
        return [NSString stringWithFormat:@"%@ %@", SPDFNumber((p.x - w->box.origin.x) / h),
                                          SPDFNumber((CGRectGetMaxY(w->box) - p.y) / h)];
    };
    switch (element->type) {
        case kCGPathElementMoveToPoint: [w->text appendFormat:@"M %@ ", pt(element->points[0])]; break;
        case kCGPathElementAddLineToPoint: [w->text appendFormat:@"L %@ ", pt(element->points[0])]; break;
        case kCGPathElementAddQuadCurveToPoint:
            [w->text appendFormat:@"Q %@ %@ ", pt(element->points[0]), pt(element->points[1])];
            break;
        case kCGPathElementAddCurveToPoint:
            [w->text appendFormat:@"C %@ %@ %@ ", pt(element->points[0]), pt(element->points[1]), pt(element->points[2])];
            break;
        case kCGPathElementCloseSubpath: [w->text appendString:@"Z "]; break;
    }
}

// Writes a filled path (y up) as outlines in the unit box, y down, a few thousand commands per string at most.
static NSArray<NSString*>* SPDFOutlinesFromPath(CGPathRef path, CGFloat* aspectOut) {
    if (!path || CGPathIsEmpty(path)) return nil;
    CGRect box = CGPathGetPathBoundingBox(path);
    if (box.size.width < 1 || box.size.height < 1) return nil;
    SPDFOutlineWriter writer = {[NSMutableString string], box};
    CGPathApply(path, &writer, SPDFWriteElement);
    if (aspectOut) *aspectOut = box.size.width / box.size.height;
    // One string per subpath group keeps each one short; the core fills them all together (non-zero).
    NSMutableArray* parts = [NSMutableArray array];
    for (NSString* chunk in [writer.text componentsSeparatedByString:@"Z "]) {
        NSString* trimmed = [chunk stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (trimmed.length) [parts addObject:[trimmed stringByAppendingString:@" Z"]];
    }
    return parts;
}

NSArray<NSString*>* SPDFSignatureOutlinesFromStrokes(NSArray<SPDFSignatureStroke*>* strokes, CGFloat penWidth,
                                                     CGFloat* aspectOut) {
    CGMutablePathRef all = CGPathCreateMutable();
    for (SPDFSignatureStroke* stroke in strokes) {
        NSInteger count = (NSInteger)stroke.points.count;
        if (count == 0) continue;
        if (count == 1) {
            CGMutablePathRef dot = CGPathCreateMutable();
            CGPathMoveToPoint(dot, NULL, P(stroke, 0).x, P(stroke, 0).y);
            CGPathAddLineToPoint(dot, NULL, P(stroke, 0).x + 0.5, P(stroke, 0).y);
            SPDFAppendOutline(all, dot, penWidth);
            CGPathRelease(dot);
            continue;
        }
        // Pieces of four segments, each as wide as the pen's speed allows: fast strokes draw thinner, as ink does.
        for (NSInteger start = 0; start + 1 < count; start += 4) {
            NSInteger end = MIN(start + 4, count - 1);
            CGFloat distance = 0;
            for (NSInteger i = start; i < end; ++i) distance += hypot(P(stroke, i + 1).x - P(stroke, i).x, P(stroke, i + 1).y - P(stroke, i).y);
            NSTimeInterval elapsed = MAX(0.004, stroke.times[(NSUInteger)end].doubleValue - stroke.times[(NSUInteger)start].doubleValue);
            CGFloat speed = distance / elapsed;  // points per second
            CGFloat width = penWidth * MAX(0.55, MIN(1.15, 1.25 - speed / 2400.0));
            CGMutablePathRef piece = CGPathCreateMutable();
            CGPathMoveToPoint(piece, NULL, P(stroke, start).x, P(stroke, start).y);
            for (NSInteger i = start; i < end; ++i) {
                NSPoint c1, c2;
                SPDFCatmullRomControls(stroke, i, &c1, &c2);
                CGPathAddCurveToPoint(piece, NULL, c1.x, c1.y, c2.x, c2.y, P(stroke, i + 1).x, P(stroke, i + 1).y);
            }
            SPDFAppendOutline(all, piece, width);
            CGPathRelease(piece);
        }
    }
    NSArray* outlines = SPDFOutlinesFromPath(all, aspectOut);
    CGPathRelease(all);
    return outlines;
}

NSArray<NSString*>* SPDFSignatureOutlinesFromText(NSString* text, NSFont* font, CGFloat* aspectOut) {
    text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!text.length || !font) return nil;
    NSAttributedString* string = [[NSAttributedString alloc] initWithString:text attributes:@{NSFontAttributeName : font}];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)string);
    CGMutablePathRef all = CGPathCreateMutable();
    CFArrayRef runs = CTLineGetGlyphRuns(line);
    for (CFIndex r = 0; r < CFArrayGetCount(runs); ++r) {
        CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, r);
        CTFontRef runFont = (CTFontRef)CFDictionaryGetValue(CTRunGetAttributes(run), kCTFontAttributeName);
        CFIndex count = CTRunGetGlyphCount(run);
        for (CFIndex g = 0; g < count; ++g) {
            CGGlyph glyph;
            CGPoint position;
            CTRunGetGlyphs(run, CFRangeMake(g, 1), &glyph);
            CTRunGetPositions(run, CFRangeMake(g, 1), &position);
            CGPathRef glyphPath = CTFontCreatePathForGlyph(runFont, glyph, NULL);
            if (!glyphPath) continue;
            CGAffineTransform move = CGAffineTransformMakeTranslation(position.x, position.y);
            CGPathAddPath(all, &move, glyphPath);
            CGPathRelease(glyphPath);
        }
    }
    CFRelease(line);
    NSArray* outlines = SPDFOutlinesFromPath(all, aspectOut);
    CGPathRelease(all);
    return outlines;
}

NSData* SPDFSignaturePictureFromImage(NSImage* image, CGFloat* aspectOut) {
    CGImageRef source = [image CGImageForProposedRect:NULL context:nil hints:nil];
    if (!source) return nil;
    size_t w = CGImageGetWidth(source), h = CGImageGetHeight(source);
    CGFloat scale = MIN(1.0, 1600.0 / (CGFloat)MAX(w, h));
    w = MAX((size_t)1, (size_t)(w * scale));
    h = MAX((size_t)1, (size_t)(h * scale));
    NSMutableData* pixels = [NSMutableData dataWithLength:w * h * 4];
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(pixels.mutableBytes, w, h, 8, w * 4, space,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!ctx) return nil;
    CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
    CGContextFillRect(ctx, CGRectMake(0, 0, w, h));
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), source);
    uint8_t* p = (uint8_t*)pixels.mutableBytes;
    // The paper's brightness: the 90th percentile, so a shadow or a dark edge does not decide it.
    NSUInteger histogram[256] = {0};
    for (size_t i = 0; i < w * h; ++i) histogram[(p[i * 4] * 299 + p[i * 4 + 1] * 587 + p[i * 4 + 2] * 114) / 1000]++;
    NSUInteger seen = 0, paper = 255;
    for (NSInteger v = 0; v < 256; ++v) {
        seen += histogram[v];
        if (seen >= (w * h) * 9 / 10) { paper = (NSUInteger)v; break; }
    }
    CGFloat inkLevel = paper * 0.55, paperLevel = paper * 0.82;
    size_t minX = w, minY = h, maxX = 0, maxY = 0;
    for (size_t y = 0; y < h; ++y)
        for (size_t x = 0; x < w; ++x) {
            uint8_t* px = p + (y * w + x) * 4;
            CGFloat lum = (px[0] * 299 + px[1] * 587 + px[2] * 114) / 1000.0;
            CGFloat alpha = MAX(0.0, MIN(1.0, (paperLevel - lum) / MAX(1.0, paperLevel - inkLevel)));
            // Premultiplied: darken the ink a little so a grey pencil scan still reads as a signature.
            for (int c = 0; c < 3; ++c) px[c] = (uint8_t)(px[c] * 0.6 * alpha);
            px[3] = (uint8_t)(alpha * 255);
            if (alpha > 0.25) {
                minX = MIN(minX, x); maxX = MAX(maxX, x);
                minY = MIN(minY, y); maxY = MAX(maxY, y);
            }
        }
    if (maxX <= minX || maxY <= minY) {
        CGContextRelease(ctx);
        return nil;
    }
    CGImageRef full = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    size_t pad = 4;
    // Bitmap rows run top-down in memory while CG crops in image space (top-left origin) too.
    CGRect crop = CGRectMake(minX > pad ? minX - pad : 0, minY > pad ? minY - pad : 0, 0, 0);
    crop.size.width = MIN((CGFloat)w, maxX + pad + 1) - crop.origin.x;
    crop.size.height = MIN((CGFloat)h, maxY + pad + 1) - crop.origin.y;
    CGImageRef cropped = CGImageCreateWithImageInRect(full, crop);
    CGImageRelease(full);
    if (!cropped) return nil;
    NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithCGImage:cropped];
    CGImageRelease(cropped);
    if (aspectOut) *aspectOut = crop.size.width / MAX(1.0, crop.size.height);
    return [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}
