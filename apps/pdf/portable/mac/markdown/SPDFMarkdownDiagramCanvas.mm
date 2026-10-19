#import "SPDFMarkdownDiagramInternal.h"

// The vector geometry model — shapes, labels, the resolved layout — plus the
// recorder every emitter draws into and the role -> concrete color resolution.
// Nothing here rasterizes: a diagram leaves this file as pure geometry in
// diagram-local, y-down points, and is painted later by the page draw path
// (shapes) and the text pipeline (labels).

@implementation SPDFMarkdownDiagramShape
- (instancetype)init {
    self = [super init];
    if (self) {
        _points = @[];
        _fillAlpha = 1;
        _strokeAlpha = 1;
        _lineWidth = 1;
    }
    return self;
}
@end

@implementation SPDFMarkdownDiagramLabelSpan
@end

@implementation SPDFMarkdownDiagramLabel
- (instancetype)init {
    self = [super init];
    if (self) {
        _text = @"";
        _fontSize = 12;
        _spans = @[];
        _role = SPDFMarkdownDiagramRoleText;
    }
    return self;
}
- (NSFont*)font {
    return self.semibold ? [NSFont systemFontOfSize:self.fontSize weight:NSFontWeightSemibold]
                         : [NSFont systemFontOfSize:self.fontSize];
}
- (NSFont*)fontForSpan:(SPDFMarkdownDiagramLabelSpan*)span {
    return SPDFMarkdownDiagramEmphasizedFont(self.font, span.bold, span.italic);
}
@end

@interface SPDFMarkdownDiagramLayout ()
@property(nonatomic, readwrite) NSSize size;
@property(nonatomic, readwrite, copy) NSArray<SPDFMarkdownDiagramShape*>* shapes;
@property(nonatomic, readwrite, copy) NSArray<SPDFMarkdownDiagramLabel*>* labels;
@end

@implementation SPDFMarkdownDiagramLayout
@end

NSColor* SPDFMarkdownDiagramRoleColor(SPDFMarkdownDiagramRole role, SPDFMarkdownThemeVariant variant) {
    SPDFMarkdownDiagramPalette* palette = [SPDFMarkdownDiagramPalette paletteForVariant:variant];
    switch (role) {
        case SPDFMarkdownDiagramRolePaper:
            return palette.paperColor;
        case SPDFMarkdownDiagramRoleNodeFill:
            return palette.nodeFillColor;
        case SPDFMarkdownDiagramRoleNodeStroke:
            return palette.nodeStrokeColor;
        case SPDFMarkdownDiagramRoleText:
            return palette.textColor;
        case SPDFMarkdownDiagramRoleSecondary:
            return palette.secondaryColor;
        case SPDFMarkdownDiagramRoleAccent:
            return palette.accentColor;
        case SPDFMarkdownDiagramRoleCritical:
            return palette.criticalColor;
        case SPDFMarkdownDiagramRoleRamp0:
        case SPDFMarkdownDiagramRoleRamp1:
        case SPDFMarkdownDiagramRoleRamp2:
        case SPDFMarkdownDiagramRoleRamp3:
        case SPDFMarkdownDiagramRoleRamp4:
        case SPDFMarkdownDiagramRoleRamp5: {
            NSUInteger index = (NSUInteger)(role - SPDFMarkdownDiagramRoleRamp0);
            return palette.accentRamp[index % palette.accentRamp.count];
        }
        case SPDFMarkdownDiagramRoleNone:
        default:
            return NSColor.clearColor;
    }
}

NSColor* SPDFMarkdownDiagramShapeFillColor(SPDFMarkdownDiagramShape* shape, SPDFMarkdownThemeVariant variant) {
    return shape.authorFillColor ? SPDFMarkdownDiagramAuthorColor(shape.authorFillColor, variant)
                                 : SPDFMarkdownDiagramRoleColor(shape.fillRole, variant);
}

NSColor* SPDFMarkdownDiagramShapeStrokeColor(SPDFMarkdownDiagramShape* shape, SPDFMarkdownThemeVariant variant) {
    return shape.authorStrokeColor ? SPDFMarkdownDiagramAuthorColor(shape.authorStrokeColor, variant)
                                   : SPDFMarkdownDiagramRoleColor(shape.strokeRole, variant);
}

NSColor* SPDFMarkdownDiagramLabelColor(SPDFMarkdownDiagramLabel* label, SPDFMarkdownThemeVariant variant) {
    return label.authorColor ? SPDFMarkdownDiagramAuthorColor(label.authorColor, variant)
                             : SPDFMarkdownDiagramRoleColor(label.role, variant);
}

SPDFMarkdownDiagramRole SPDFMarkdownDiagramRampRole(NSUInteger index) {
    return (SPDFMarkdownDiagramRole)(SPDFMarkdownDiagramRoleRamp0 + (NSInteger)(index % 6));
}

// --- The recorder --------------------------------------------------------------

@implementation SPDFMarkdownDiagramCanvas {
    NSMutableArray<SPDFMarkdownDiagramShape*>* _shapes;
    NSMutableArray<SPDFMarkdownDiagramLabel*>* _labels;
}
- (instancetype)init {
    self = [super init];
    if (self) {
        _shapes = [NSMutableArray array];
        _labels = [NSMutableArray array];
    }
    return self;
}
- (NSArray<SPDFMarkdownDiagramShape*>*)shapes { return _shapes; }
- (NSArray<SPDFMarkdownDiagramLabel*>*)labels { return _labels; }

- (SPDFMarkdownDiagramShape*)appendShape:(SPDFMarkdownDiagramShape*)shape {
    [_shapes addObject:shape];
    return shape;
}

- (SPDFMarkdownDiagramShape*)addRect:(NSRect)rect
                              radius:(CGFloat)cornerRadius
                                fill:(SPDFMarkdownDiagramRole)fill
                              stroke:(SPDFMarkdownDiagramRole)stroke
                               width:(CGFloat)lineWidth {
    SPDFMarkdownDiagramShape* shape = [SPDFMarkdownDiagramShape new];
    shape.kind = SPDFMarkdownDiagramShapeRectangle;
    shape.rect = rect;
    shape.cornerRadius = MAX(0, MIN(cornerRadius, MIN(NSWidth(rect), NSHeight(rect)) / 2));
    shape.fillRole = fill;
    shape.strokeRole = stroke;
    shape.lineWidth = lineWidth;
    return [self appendShape:shape];
}

- (SPDFMarkdownDiagramShape*)addEllipse:(NSRect)rect
                                   fill:(SPDFMarkdownDiagramRole)fill
                                 stroke:(SPDFMarkdownDiagramRole)stroke
                                  width:(CGFloat)lineWidth {
    SPDFMarkdownDiagramShape* shape = [SPDFMarkdownDiagramShape new];
    shape.kind = SPDFMarkdownDiagramShapeEllipse;
    shape.rect = rect;
    shape.fillRole = fill;
    shape.strokeRole = stroke;
    shape.lineWidth = lineWidth;
    return [self appendShape:shape];
}

- (SPDFMarkdownDiagramShape*)addPolygon:(NSArray<NSValue*>*)points
                                   fill:(SPDFMarkdownDiagramRole)fill
                                 stroke:(SPDFMarkdownDiagramRole)stroke
                                  width:(CGFloat)lineWidth {
    SPDFMarkdownDiagramShape* shape = [SPDFMarkdownDiagramShape new];
    shape.kind = SPDFMarkdownDiagramShapePolygon;
    shape.points = points;
    shape.fillRole = fill;
    shape.strokeRole = stroke;
    shape.lineWidth = lineWidth;
    return [self appendShape:shape];
}

- (SPDFMarkdownDiagramShape*)addPolyline:(NSArray<NSValue*>*)points
                                  stroke:(SPDFMarkdownDiagramRole)stroke
                                   width:(CGFloat)lineWidth
                                    dash:(CGFloat)dashLength {
    SPDFMarkdownDiagramShape* shape = [SPDFMarkdownDiagramShape new];
    shape.kind = SPDFMarkdownDiagramShapePolyline;
    shape.points = points;
    shape.fillRole = SPDFMarkdownDiagramRoleNone;
    shape.strokeRole = stroke;
    shape.lineWidth = lineWidth;
    shape.dashLength = dashLength;
    return [self appendShape:shape];
}

- (SPDFMarkdownDiagramShape*)addLineFrom:(NSPoint)start
                                      to:(NSPoint)end
                                  stroke:(SPDFMarkdownDiagramRole)stroke
                                   width:(CGFloat)lineWidth
                                    dash:(CGFloat)dashLength {
    return [self addPolyline:@[ [NSValue valueWithPoint:start], [NSValue valueWithPoint:end] ]
                      stroke:stroke
                       width:lineWidth
                        dash:dashLength];
}

- (SPDFMarkdownDiagramShape*)addPieSliceAt:(NSPoint)center
                                    radius:(CGFloat)radius
                                startAngle:(CGFloat)startAngle
                                     sweep:(CGFloat)sweepAngle
                                      fill:(SPDFMarkdownDiagramRole)fill
                                    stroke:(SPDFMarkdownDiagramRole)stroke
                                     width:(CGFloat)lineWidth {
    SPDFMarkdownDiagramShape* shape = [SPDFMarkdownDiagramShape new];
    shape.kind = SPDFMarkdownDiagramShapePieSlice;
    shape.center = center;
    shape.radius = radius;
    shape.startAngle = startAngle;
    shape.sweepAngle = sweepAngle;
    shape.fillRole = fill;
    shape.strokeRole = stroke;
    shape.lineWidth = lineWidth;
    return [self appendShape:shape];
}

- (NSArray<SPDFMarkdownDiagramLabel*>*)addText:(NSString*)text
                                       inRect:(NSRect)rect
                                         font:(NSFont*)font
                                         role:(SPDFMarkdownDiagramRole)role
                                    alignment:(NSTextAlignment)alignment {
    if (!text.length || NSWidth(rect) <= 0) return @[];
    NSMutableArray<SPDFMarkdownDiagramLabel*>* added = [NSMutableArray array];
    CGFloat lineHeight = SPDFMarkdownDiagramLineHeight(font);
    CGFloat y = NSMinY(rect);
    // A label stores size + weight, not a font object, so the measurement pass
    // can rebuild the exact same face: compare against the semibold system
    // face at this size instead of guessing from descriptor traits.
    BOOL semibold = [font.fontName
        isEqualToString:[NSFont systemFontOfSize:font.pointSize weight:NSFontWeightSemibold].fontName];
    for (NSAttributedString* line in SPDFMarkdownDiagramWrapAttributedText(
             SPDFMarkdownDiagramAttributedLabel(text, font), NSWidth(rect))) {
        if (!line.length) continue;  // a label that was nothing but markup
        SPDFMarkdownDiagramLabel* label = [SPDFMarkdownDiagramLabel new];
        label.text = line.string;
        label.spans = SPDFMarkdownDiagramLabelSpans(line);
        label.frame = NSMakeRect(NSMinX(rect), y, NSWidth(rect), lineHeight);
        label.alignment = alignment;
        label.fontSize = font.pointSize;
        label.semibold = semibold;
        label.role = role;
        [_labels addObject:label];
        [added addObject:label];
        y += lineHeight;
    }
    return added;
}
@end

// --- Closing a canvas ----------------------------------------------------------

static NSArray<NSValue*>* SPDFDiagramScalePoints(NSArray<NSValue*>* points, CGFloat factor) {
    NSMutableArray<NSValue*>* scaled = [NSMutableArray arrayWithCapacity:points.count];
    for (NSValue* value in points) {
        NSPoint point = value.pointValue;
        [scaled addObject:[NSValue valueWithPoint:NSMakePoint(point.x * factor, point.y * factor)]];
    }
    return scaled;
}

static NSRect SPDFDiagramScaleRect(NSRect rect, CGFloat factor) {
    return NSMakeRect(NSMinX(rect) * factor, NSMinY(rect) * factor, NSWidth(rect) * factor,
                      NSHeight(rect) * factor);
}

CGFloat SPDFMarkdownDiagramBoxFit(NSSize naturalSize, NSSize contentBox) {
    if (naturalSize.width <= 0 || naturalSize.height <= 0) return 0;
    CGFloat fit = 1.0;
    if (contentBox.width > 0) fit = MIN(fit, contentBox.width / naturalSize.width);
    if (contentBox.height > 0) fit = MIN(fit, contentBox.height / naturalSize.height);
    return fit;
}

SPDFMarkdownDiagramLayout* SPDFMarkdownDiagramFinishLayout(SPDFMarkdownDiagramCanvas* canvas, NSSize naturalSize,
                                                           NSSize contentBox) {
    if (naturalSize.width <= 0 || naturalSize.height <= 0) return nil;
    if (naturalSize.width > SPDFMarkdownDiagramMaximumDimension ||
        naturalSize.height > SPDFMarkdownDiagramMaximumDimension)
        return nil;
    // One common factor fits an over-sized diagram to the page box: geometry
    // and label font sizes shrink together, so the drawing never clips and
    // never re-wraps. Fitting BOTH axes here is what keeps the pagination band
    // from having to squeeze an over-tall diagram a second time.
    CGFloat fit = SPDFMarkdownDiagramBoxFit(naturalSize, contentBox);
    NSArray<SPDFMarkdownDiagramShape*>* shapes = canvas.shapes;
    NSArray<SPDFMarkdownDiagramLabel*>* labels = canvas.labels;
    if (fit < 1.0) {
        NSMutableArray<SPDFMarkdownDiagramShape*>* scaledShapes =
            [NSMutableArray arrayWithCapacity:shapes.count];
        for (SPDFMarkdownDiagramShape* shape in shapes) {
            SPDFMarkdownDiagramShape* copy = [SPDFMarkdownDiagramShape new];
            copy.kind = shape.kind;
            copy.rect = SPDFDiagramScaleRect(shape.rect, fit);
            copy.cornerRadius = shape.cornerRadius * fit;
            copy.points = SPDFDiagramScalePoints(shape.points, fit);
            copy.center = NSMakePoint(shape.center.x * fit, shape.center.y * fit);
            copy.radius = shape.radius * fit;
            copy.startAngle = shape.startAngle;
            copy.sweepAngle = shape.sweepAngle;
            copy.fillRole = shape.fillRole;
            copy.strokeRole = shape.strokeRole;
            copy.fillAlpha = shape.fillAlpha;
            copy.strokeAlpha = shape.strokeAlpha;
            copy.lineWidth = shape.lineWidth * fit;
            copy.dashLength = shape.dashLength * fit;
            copy.authorFillColor = shape.authorFillColor;
            copy.authorStrokeColor = shape.authorStrokeColor;
            [scaledShapes addObject:copy];
        }
        NSMutableArray<SPDFMarkdownDiagramLabel*>* scaledLabels =
            [NSMutableArray arrayWithCapacity:labels.count];
        for (SPDFMarkdownDiagramLabel* label in labels) {
            SPDFMarkdownDiagramLabel* copy = [SPDFMarkdownDiagramLabel new];
            copy.text = label.text;
            copy.frame = SPDFDiagramScaleRect(label.frame, fit);
            copy.alignment = label.alignment;
            copy.fontSize = label.fontSize * fit;
            copy.semibold = label.semibold;
            copy.spans = label.spans;  // ranges into `text`: size-independent
            copy.role = label.role;
            copy.authorColor = label.authorColor;
            [scaledLabels addObject:copy];
        }
        shapes = scaledShapes;
        labels = scaledLabels;
    }
    SPDFMarkdownDiagramLayout* layout = [SPDFMarkdownDiagramLayout new];
    layout.size = NSMakeSize(floor(naturalSize.width * fit), floor(naturalSize.height * fit));
    layout.shapes = shapes;
    layout.labels = labels;
    return layout;
}
