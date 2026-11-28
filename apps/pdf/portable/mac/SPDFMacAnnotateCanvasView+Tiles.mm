// The composite tiles of the canvas view (SPDFMacAnnotateCanvasViewPrivate.h): cached 256 x 256 device-pixel tiles
// per page and scale; a change only drops the tiles under its damage (spdf_paint_take_damage), so an 8000 x 8000
// picture redraws what one stroke touched, not the picture.
//
// A picture's or canvas's tiles hold the screen's own pixels, worked out here and drawn one to one on whole screen
// pixels: at 100 % and above each shows the canvas pixel under its centre (pixels are squares, as in Paint and
// Preview); below, a blend of the composite at the power of two at or above the screen's scale. Scaled by the window
// server instead, the edge of a part drawn again could come out differently from the same pixels drawn as part of
// the whole, and keep that until the next redraw of the whole: a stroke's release would change it. A PDF page's
// tiles are rendered at a power of two up to 8 pixels per point and scaled smoothly.
#import "SPDFMacAnnotateCanvasViewPrivate.h"

#include <vector>

static const int kTileSide = 256;  static const NSUInteger kMaxTiles = 600;  // device pixels; ~150 MB at most

@implementation SPDFMacAnnotateCanvasView (Tiles)

static NSString* TileKey(NSInteger page, int level, int tx, int ty) {
    return [NSString stringWithFormat:@"%ld:%d:%d:%d", (long)page, level, tx, ty];
}

static NSString* ScreenTileKey(NSInteger page, double device, int tx, int ty) {
    return [NSString stringWithFormat:@"%ld:d%.17g:%d:%d", (long)page, device, tx, ty];
}

// A tile's box in canvas units: at a level (render scale 2^level), or a screen tile ("d" and the screen pixels per
// canvas unit).
static NSRect TileRect(NSString* scale, int tx, int ty) {
    CGFloat unit = [scale hasPrefix:@"d"] ? kTileSide / [scale substringFromIndex:1].doubleValue
                                          : kTileSide / ldexp(1.0, scale.intValue);
    return NSMakeRect(tx * unit, ty * unit, unit, unit);
}

- (void)dropTilesOnPage:(NSInteger)page inRect:(NSRect)rect {
    NSString* prefix = [NSString stringWithFormat:@"%ld:", (long)page];
    for (NSString* key in _tiles.allKeys) {
        if (![key hasPrefix:prefix]) continue;
        NSArray* parts = [key componentsSeparatedByString:@":"];
        NSRect tile = TileRect(parts[1], [parts[2] intValue], [parts[3] intValue]);
        if ([parts[1] hasPrefix:@"d"])  // a screen pixel blends the composite's pixels around its centre
            tile = NSInsetRect(tile, -2 * MAX(1.0, 1 / [parts[1] substringFromIndex:1].doubleValue), -2 * MAX(1.0, 1 / [parts[1] substringFromIndex:1].doubleValue));
        if (NSIsEmptyRect(rect) || NSIntersectsRect(tile, rect)) [_tiles removeObjectForKey:key];
    }
}

- (int)levelForPage:(NSInteger)page {
    CGFloat device = [self scaleForPage:page] * (self.window.backingScaleFactor ?: 2.0);
    int level = (int)ceil(log2(MAX(device, 1.0 / 64)));
    if (page < 0) return MIN(level, 0);  // a picture's own pixels: never more than one tile pixel per canvas pixel
    return MAX(-6, MIN(level, 3));       // a PDF page's objects stay sharp up to 8 pixels per point
}

- (double)screenTileScaleForPage:(NSInteger)page {
    return page < 0 ? [self scaleForPage:page] * (self.window.backingScaleFactor ?: 2.0) : 0;
}

static CGImageRef MakeImage(const unsigned char* rgba, int width, int height, size_t stride) {
    NSData* data = [NSData dataWithBytes:rgba length:stride * (size_t)height];
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGImageRef image = CGImageCreate((size_t)width, (size_t)height, 8, 32, stride, srgb,
                                     kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big, provider, NULL, false,
                                     kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(srgb);
    return image;
}

- (void)keepTile:(CGImageRef)image key:(NSString*)key prefix:(NSString*)keep {
    if (_tiles.count >= kMaxTiles) {  // tiles of other scales go first
        for (NSString* other in _tiles.allKeys)
            if (![other hasPrefix:keep]) [_tiles removeObjectForKey:other];
        if (_tiles.count >= kMaxTiles) [_tiles removeAllObjects];
    }
    _tiles[key] = CFBridgingRelease(image);
}

- (CGImageRef)tileOnPage:(NSInteger)page level:(int)level tx:(int)tx ty:(int)ty doc:(spdf_paint_doc*)doc {
    NSString* key = TileKey(page, level, tx, ty);
    id cached = _tiles[key];
    if (cached) return (__bridge CGImageRef)cached;
    int width = 0, height = 0;
    spdf_paint_size(doc, &width, &height);
    NSRect rect = NSIntersectionRect(TileRect([NSString stringWithFormat:@"%d", level], tx, ty), NSMakeRect(0, 0, width, height));
    if (NSIsEmptyRect(rect)) return NULL;
    spdf_paint_render_options options;
    memset(&options, 0, sizeof(options));
    options.region = (spdf_rect){(float)NSMinX(rect), (float)NSMinY(rect), (float)NSMaxX(rect), (float)NSMaxY(rect)};
    options.scale = (float)ldexp(1.0, level);
    if (page >= 0) options.flags |= SPDF_PAINT_RENDER_SKIP_LOCKED_BACKGROUND;
    spdf_bitmap bitmap = {0, 0, 0, NULL};
    char err[256];
    if (spdf_paint_render(doc, &options, &bitmap, err, sizeof(err)) != SPDF_PAINT_OK || !bitmap.rgba) return NULL;
    CGImageRef image = MakeImage(bitmap.rgba, bitmap.width, bitmap.height, (size_t)bitmap.stride);
    spdf_free_bitmap(&bitmap);
    if (!image) return NULL;
    [self keepTile:image key:key prefix:[NSString stringWithFormat:@"%ld:%d:", (long)page, level]];
    return image;
}

// Screen pixels [tx, ty] x 256 of the canvas shown at `device` screen pixels per canvas pixel. From 100 % each shows
// the canvas pixel under its centre; below, a blend of the four pixels around its centre in the composite at the
// power of two at or above it (the canvas's own pixels at most). Worked out from each pixel's own place, never from
// the part drawn: the same pixel always comes out the same.
- (CGImageRef)screenTileOnPage:(NSInteger)page device:(double)device tx:(int)tx ty:(int)ty doc:(spdf_paint_doc*)doc {
    NSString* key = ScreenTileKey(page, device, tx, ty);
    id cached = _tiles[key];
    if (cached) return (__bridge CGImageRef)cached;
    int width = 0, height = 0;
    spdf_paint_size(doc, &width, &height);
    long x0 = (long)tx * kTileSide, y0 = (long)ty * kTileSide;
    long x1 = MIN(x0 + kTileSide, (long)ceil(width * device - 1e-6)), y1 = MIN(y0 + kTileSide, (long)ceil(height * device - 1e-6));
    if (x1 <= x0 || y1 <= y0) return NULL;
    BOOL sharp = [self scaleForPage:page] >= 1.0;
    double source = sharp ? 1.0 : ldexp(1.0, MIN(0, (int)ceil(log2(device) - 1e-9)));  // composite pixels per canvas pixel
    long sw = (long)ceil(width * source - 1e-6), sh = (long)ceil(height * source - 1e-6);
    double k = source / device;  // composite pixels per screen pixel
    int w = (int)(x1 - x0), h = (int)(y1 - y0);
    // Each screen column (row): the composite's column (row) at or left of its centre and the weight of the next.
    std::vector<long> ci((size_t)w), ri((size_t)h);
    std::vector<float> cf((size_t)w), rf((size_t)h);
    for (int i = 0; i < w; ++i) {
        double u = sharp ? floor((x0 + i + 0.5) * k) : (x0 + i + 0.5) * k - 0.5, f = floor(u);
        ci[(size_t)i] = MAX(0L, MIN((long)f, sw - 1)), cf[(size_t)i] = sharp || f < 0 || f >= sw - 1 ? 0 : (float)(u - f);
    }
    for (int j = 0; j < h; ++j) {
        double v = sharp ? floor((y0 + j + 0.5) * k) : (y0 + j + 0.5) * k - 0.5, f = floor(v);
        ri[(size_t)j] = MAX(0L, MIN((long)f, sh - 1)), rf[(size_t)j] = sharp || f < 0 || f >= sh - 1 ? 0 : (float)(v - f);
    }
    long cx0 = ci.front(), cx1 = MIN(ci.back() + 2, sw), cy0 = ri.front(), cy1 = MIN(ri.back() + 2, sh);
    spdf_paint_render_options options;
    memset(&options, 0, sizeof(options));
    options.region = (spdf_rect){(float)(cx0 / source), (float)(cy0 / source), (float)(MIN((double)width, cx1 / source)),
                                 (float)(MIN((double)height, cy1 / source))};
    options.scale = (float)source;
    spdf_bitmap bitmap = {0, 0, 0, NULL};
    char err[256];
    if (spdf_paint_render(doc, &options, &bitmap, err, sizeof(err)) != SPDF_PAINT_OK || !bitmap.rgba) return NULL;
    std::vector<uint8_t> pixels((size_t)w * (size_t)h * 4);
    for (int j = 0; j < h; ++j) {
        long r0 = MIN(ri[(size_t)j] - cy0, (long)bitmap.height - 1), r1 = MIN(r0 + 1, (long)bitmap.height - 1);
        const uint8_t *a = bitmap.rgba + (size_t)r0 * bitmap.stride, *b = bitmap.rgba + (size_t)r1 * bitmap.stride;
        uint8_t* out = pixels.data() + (size_t)j * (size_t)w * 4;
        float fy = rf[(size_t)j];
        for (int i = 0; i < w; ++i, out += 4) {
            long c0 = MIN(ci[(size_t)i] - cx0, (long)bitmap.width - 1), c1 = MIN(c0 + 1, (long)bitmap.width - 1);
            float fx = cf[(size_t)i];
            if (fx == 0 && fy == 0) { memcpy(out, a + c0 * 4, 4); continue; }
            for (int n = 0; n < 4; ++n) {
                float top = a[c0 * 4 + n] + (a[c1 * 4 + n] - a[c0 * 4 + n]) * fx;
                float bottom = b[c0 * 4 + n] + (b[c1 * 4 + n] - b[c0 * 4 + n]) * fx;
                out[n] = (uint8_t)lrintf(top + (bottom - top) * fy);
            }
        }
    }
    spdf_free_bitmap(&bitmap);
    CGImageRef image = MakeImage(pixels.data(), w, h, (size_t)w * 4);
    if (!image) return NULL;
    [self keepTile:image key:key prefix:[NSString stringWithFormat:@"%ld:d%.17g:", (long)page, device]];
    return image;
}

static void DrawImage(CGContextRef context, CGImageRef image, NSRect rect) {
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, NSMinX(rect), NSMaxY(rect));
    CGContextScaleCTM(context, 1, -1);
    CGContextDrawImage(context, CGRectMake(0, 0, NSWidth(rect), NSHeight(rect)), image);
    CGContextRestoreGState(context);
}

// A picture at 100 % and above: its screen tiles one to one, from the canvas's corner put on a whole screen pixel.
- (void)drawScreenTilesOfPage:(NSInteger)page visible:(NSRect)visible device:(double)device doc:(spdf_paint_doc*)doc
                      context:(CGContextRef)context {
    CGFloat backing = self.window.backingScaleFactor ?: 2.0;
    NSRect canvas = [self canvasRectForPage:page];
    CGFloat ox = round(NSMinX(canvas) * backing) / backing, oy = round(NSMinY(canvas) * backing) / backing;
    int tx0 = (int)floor((NSMinX(visible) - ox) * backing / kTileSide), tx1 = (int)floor(((NSMaxX(visible) - ox) * backing - 1e-3) / kTileSide);
    int ty0 = (int)floor((NSMinY(visible) - oy) * backing / kTileSide), ty1 = (int)floor(((NSMaxY(visible) - oy) * backing - 1e-3) / kTileSide);
    CGContextSetInterpolationQuality(context, kCGInterpolationNone);
    for (int ty = MAX(0, ty0); ty <= ty1; ++ty)
        for (int tx = MAX(0, tx0); tx <= tx1; ++tx) {
            CGImageRef tile = [self screenTileOnPage:page device:device tx:tx ty:ty doc:doc];
            if (tile)
                DrawImage(context, tile, NSMakeRect(ox + tx * kTileSide / backing, oy + ty * kTileSide / backing,
                                                    CGImageGetWidth(tile) / backing, CGImageGetHeight(tile) / backing));
        }
}

- (void)drawCanvasOfPage:(NSInteger)page inRect:(NSRect)dirty context:(CGContextRef)context {
    spdf_paint_doc* doc = [self docForPage:page];
    NSRect canvas = [self canvasRectForPage:page];
    NSRect visible = NSIntersectionRect(NSIntersectionRect(canvas, dirty), self.visibleRect);
    if (!doc || NSIsEmptyRect(visible)) return;
    if (page < 0) [self drawCheckerboardInRect:visible];
    CGContextSaveGState(context);
    CGContextClipToRect(context, NSRectToCGRect(visible));
    CGContextSetShouldAntialias(context, false);  // no hairline seams between tiles
    double device = [self screenTileScaleForPage:page];
    if (device > 0) {
        [self drawScreenTilesOfPage:page visible:visible device:device doc:doc context:context];
        CGContextRestoreGState(context);
        return;
    }
    CGFloat scale = [self scaleForPage:page];
    int level = [self levelForPage:page];
    CGFloat unit = kTileSide / ldexp(1.0, level);
    NSRect area = NSMakeRect((NSMinX(visible) - NSMinX(canvas)) / scale, (NSMinY(visible) - NSMinY(canvas)) / scale,
                             NSWidth(visible) / scale, NSHeight(visible) / scale);
    int tx0 = (int)floor(NSMinX(area) / unit), tx1 = (int)floor((NSMaxX(area) - 0.001) / unit);
    int ty0 = (int)floor(NSMinY(area) / unit), ty1 = (int)floor((NSMaxY(area) - 0.001) / unit);
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);  // below 100 %: smoothly
    for (int ty = MAX(0, ty0); ty <= ty1; ++ty)
        for (int tx = MAX(0, tx0); tx <= tx1; ++tx) {
            CGImageRef tile = [self tileOnPage:page level:level tx:tx ty:ty doc:doc];
            if (!tile) continue;
            NSRect rect = NSMakeRect(NSMinX(canvas) + tx * unit * scale, NSMinY(canvas) + ty * unit * scale,
                                     CGImageGetWidth(tile) / ldexp(1.0, level) * scale,
                                     CGImageGetHeight(tile) / ldexp(1.0, level) * scale);
            DrawImage(context, tile, rect);
        }
    CGContextRestoreGState(context);
}

@end
