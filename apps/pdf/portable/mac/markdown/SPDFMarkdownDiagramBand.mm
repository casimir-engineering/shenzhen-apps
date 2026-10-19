#import "SPDFMarkdownDiagramBand.h"

#import <CoreText/CoreText.h>

#import "SPDFMarkdownPaginator.h"
#import "SPDFMarkdownRenderInternal.h"

// The page side of the diagram seam: a resolved layout becomes ONE atomic band
// of positioned canonical text lines (measurement), ONE shape decoration
// (planning), and plain Core Graphics vector painting (drawing). No bitmap
// exists anywhere on this path, so a diagram is crisp at any zoom and its
// labels are real, selectable, searchable text in the page and in the export.

@implementation SPDFMarkdownDiagramBlockInfo
- (instancetype)initWithLayout:(SPDFMarkdownDiagramLayout*)layout
                   labelRanges:(NSArray<NSValue*>*)labelRanges
                     topMargin:(CGFloat)topMargin
                  bottomMargin:(CGFloat)bottomMargin
                   depthIndent:(CGFloat)depthIndent {
    self = [super init];
    if (self) {
        _layout = layout;
        _labelRanges = [labelRanges copy];
        _topMargin = MAX(0, topMargin);
        _bottomMargin = MAX(0, bottomMargin);
        _depthIndent = MAX(0, depthIndent);
        _xOrigin = _depthIndent;
    }
    return self;
}
- (instancetype)infoWithXOrigin:(CGFloat)xOrigin {
    SPDFMarkdownDiagramBlockInfo* copy = [[SPDFMarkdownDiagramBlockInfo alloc] initWithLayout:self.layout
                                                                                 labelRanges:self.labelRanges
                                                                                   topMargin:self.topMargin
                                                                                bottomMargin:self.bottomMargin
                                                                                 depthIndent:self.depthIndent];
    copy->_xOrigin = MAX(0, xOrigin);
    return copy;
}
@end

SPDFMarkdownPaginationItem* SPDFMarkdownMeasureDiagramItem(SPDFMarkdownRenderedBlock* block,
                                                           NSAttributedString* text, CGFloat containerWidth) {
    SPDFMarkdownDiagramBlockInfo* info = block.diagramInfo;
    SPDFMarkdownDiagramLayout* layout = info.layout;
    if (!layout || layout.size.width <= 0 || layout.size.height <= 0) return nil;
    // The diagram stays centered in the printable column, after its list
    // indentation; a diagram wider than the column was already fitted by the
    // render seam, so this can only ever add air, never a clip.
    CGFloat available = MAX(0, containerWidth - info.depthIndent);
    CGFloat xOrigin = info.depthIndent + MAX(0, (available - layout.size.width) / 2);
    SPDFMarkdownDiagramBlockInfo* bound = [info infoWithXOrigin:xOrigin];

    NSMutableArray<SPDFMarkdownTextLine*>* lines = [NSMutableArray array];
    // The zero-length spacer spans the whole band (margins included), so the
    // band height, the shape decoration envelope and hit-testing all see the
    // diagram's true extent even where no label reaches its edges.
    [lines addObject:[[SPDFMarkdownTextLine alloc]
                         initWithAttributedRange:NSMakeRange(block.attributedRange.location, 0)
                                          height:info.topMargin + layout.size.height + info.bottomMargin
                                         xOffset:0
                                  baselineOffset:0
                                 rowLocalYOffset:0]];
    NSArray<SPDFMarkdownDiagramLabel*>* labels = layout.labels;
    for (NSUInteger index = 0; index < labels.count && index < bound.labelRanges.count; ++index) {
        NSRange range = bound.labelRanges[index].rangeValue;
        if (!range.length || NSMaxRange(range) > text.length) continue;
        SPDFMarkdownDiagramLabel* label = labels[index];
        NSFont* font = label.font;
        // The label draws as one CTLine at an explicit x, so its centering
        // comes from the same typographic width the drawing pass will use.
        CTLineRef line = SPDFMarkdownCreateFragmentLine([text attributedSubstringFromRange:range]);
        CGFloat width = (CGFloat)CTLineGetTypographicBounds(line, NULL, NULL, NULL);
        CFRelease(line);
        CGFloat x = NSMinX(label.frame);
        if (label.alignment == NSTextAlignmentCenter) x = NSMidX(label.frame) - width / 2;
        else if (label.alignment == NSTextAlignmentRight) x = NSMaxX(label.frame) - width;
        [lines addObject:[[SPDFMarkdownTextLine alloc]
                             initWithAttributedRange:range
                                              height:NSHeight(label.frame)
                                             xOffset:bound.xOrigin + x
                                      baselineOffset:ceil(font.ascender)
                                     rowLocalYOffset:info.topMargin + NSMinY(label.frame)]];
    }
    return [[SPDFMarkdownPaginationItem alloc] initWithBlockIndex:block.blockIndex
                                                             kind:block.kind
                                                     headingLevel:block.level
                                                     tableRowInfo:nil
                                                      diagramInfo:bound
                                                       bandLayout:YES
                                                            lines:lines];
}

NSUInteger SPDFMarkdownAppendDiagramDecoration(NSArray<SPDFMarkdownPageFragment*>* fragments,
                                               NSUInteger startIndex, NSUInteger runEnd,
                                               SPDFMarkdownPaginationItem* item,
                                               NSMutableArray<SPDFMarkdownPageDecoration*>* decorations) {
    SPDFMarkdownDiagramBlockInfo* info = item.diagramInfo;
    SPDFMarkdownPageFragment* first = startIndex < fragments.count ? fragments[startIndex] : nil;
    if (info && first) {
        // The band is atomic, so its first fragment is the spacer that starts
        // at the band's top; an over-tall band's uniform scale is the
        // fragment's own scale.
        CGFloat scale = first.scale;
        NSRect rect = NSMakeRect(info.xOrigin * scale, first.pageYOffset + info.topMargin * scale,
                                 info.layout.size.width * scale, info.layout.size.height * scale);
        [decorations addObject:[[SPDFMarkdownPageDecoration alloc]
                                   initWithType:SPDFMarkdownPageDecorationTypeDiagram
                                           rect:rect
                                     blockIndex:item.blockIndex
                                  diagramLayout:info.layout]];
    }
    return runEnd + 1;
}

// --- Drawing -------------------------------------------------------------------

static void SPDFDiagramSetColor(CGContextRef context, NSColor* resolved, CGFloat alpha, BOOL stroke) {
    NSColor* color = [resolved colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!color) color = NSColor.clearColor;
    CGFloat components[4] = {color.redComponent, color.greenComponent, color.blueComponent,
                             color.alphaComponent * MAX(0, MIN(1, alpha))};
    if (stroke) {
        CGContextSetRGBStrokeColor(context, components[0], components[1], components[2], components[3]);
    } else {
        CGContextSetRGBFillColor(context, components[0], components[1], components[2], components[3]);
    }
}

static void SPDFDiagramAddShapePath(CGContextRef context, SPDFMarkdownDiagramShape* shape) {
    CGContextBeginPath(context);
    switch (shape.kind) {
        case SPDFMarkdownDiagramShapeRectangle: {
            CGRect rect = shape.rect;
            if (shape.cornerRadius > 0.01) {
                CGPathRef path = CGPathCreateWithRoundedRect(rect, shape.cornerRadius, shape.cornerRadius, NULL);
                CGContextAddPath(context, path);
                CGPathRelease(path);
            } else {
                CGContextAddRect(context, rect);
            }
            return;
        }
        case SPDFMarkdownDiagramShapeEllipse:
            CGContextAddEllipseInRect(context, shape.rect);
            return;
        case SPDFMarkdownDiagramShapePolygon:
        case SPDFMarkdownDiagramShapePolyline: {
            NSArray<NSValue*>* points = shape.points;
            if (points.count < 2) return;
            NSPoint start = points.firstObject.pointValue;
            CGContextMoveToPoint(context, start.x, start.y);
            for (NSUInteger index = 1; index < points.count; ++index) {
                NSPoint point = points[index].pointValue;
                CGContextAddLineToPoint(context, point.x, point.y);
            }
            if (shape.kind == SPDFMarkdownDiagramShapePolygon) CGContextClosePath(context);
            return;
        }
        case SPDFMarkdownDiagramShapePieSlice: {
            // Angles are degrees in the diagram's own y-down space: 0 at three
            // o'clock, a positive sweep running clockwise on screen.
            CGFloat start = shape.startAngle * (CGFloat)M_PI / 180;
            CGFloat end = (shape.startAngle + shape.sweepAngle) * (CGFloat)M_PI / 180;
            CGContextMoveToPoint(context, shape.center.x, shape.center.y);
            CGContextAddArc(context, shape.center.x, shape.center.y, shape.radius, start, end, 0);
            CGContextClosePath(context);
            return;
        }
    }
}

void SPDFMarkdownDrawDiagramShapes(CGContextRef context, SPDFMarkdownDiagramLayout* layout, CGRect rect,
                                   SPDFMarkdownThemeVariant variant) {
    if (!context || !layout || layout.size.width <= 0 || rect.size.width <= 0) return;
    CGFloat scale = rect.size.width / layout.size.width;
    CGContextSaveGState(context);
    // Diagram-local space is y-DOWN from the box's top-left corner.
    CGContextTranslateCTM(context, CGRectGetMinX(rect), CGRectGetMaxY(rect));
    CGContextScaleCTM(context, scale, -scale);
    for (SPDFMarkdownDiagramShape* shape in layout.shapes) {
        BOOL fills = (shape.fillRole != SPDFMarkdownDiagramRoleNone || shape.authorFillColor) &&
                     shape.fillAlpha > 0;
        BOOL strokes = (shape.strokeRole != SPDFMarkdownDiagramRoleNone || shape.authorStrokeColor) &&
                       shape.strokeAlpha > 0 && shape.lineWidth > 0;
        if (!fills && !strokes) continue;
        if (fills) {
            SPDFDiagramSetColor(context, SPDFMarkdownDiagramShapeFillColor(shape, variant), shape.fillAlpha,
                                NO);
            SPDFDiagramAddShapePath(context, shape);
            CGContextFillPath(context);
        }
        if (strokes) {
            SPDFDiagramSetColor(context, SPDFMarkdownDiagramShapeStrokeColor(shape, variant),
                                shape.strokeAlpha, YES);
            CGContextSetLineWidth(context, shape.lineWidth);
            if (shape.dashLength > 0) {
                CGFloat pattern[2] = {shape.dashLength, shape.dashLength * 0.75};
                CGContextSetLineDash(context, 0, pattern, 2);
            } else {
                CGContextSetLineDash(context, 0, NULL, 0);
            }
            SPDFDiagramAddShapePath(context, shape);
            CGContextStrokePath(context);
        }
    }
    CGContextRestoreGState(context);
}
