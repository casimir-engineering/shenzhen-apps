// SPDFMacAnnotateSymbols.h: the icons Annotate draws itself, and stand-ins for SF Symbols newer than macOS 12.
#import "SPDFMacAnnotateSymbols.h"

// Fill: a bucket tipped over, its handle, the paint's level and a drop falling, drawn on a 24-unit grid in 18 points.
static NSImage* SPDFAnnotatePaintBucket(NSString* label) {
    NSImage* image = [NSImage imageWithSize:NSMakeSize(18, 18) flipped:YES drawingHandler:^BOOL(NSRect rect) {
      (void)rect;
      [NSColor.blackColor set];
      NSAffineTransform* grid = [NSAffineTransform transform];
      [grid scaleBy:18.0 / 24.0];
      NSBezierPath* bucket = [NSBezierPath bezierPath];
      [bucket moveToPoint:NSMakePoint(19, 11)];
      [bucket lineToPoint:NSMakePoint(11, 3)];
      [bucket lineToPoint:NSMakePoint(2.4, 11.6)];
      [bucket curveToPoint:NSMakePoint(2.4, 14.4) controlPoint1:NSMakePoint(1.6, 12.4) controlPoint2:NSMakePoint(1.6, 13.6)];
      [bucket lineToPoint:NSMakePoint(7.6, 19.6)];
      [bucket curveToPoint:NSMakePoint(10.4, 19.6) controlPoint1:NSMakePoint(8.4, 20.4) controlPoint2:NSMakePoint(9.6, 20.4)];
      [bucket closePath];
      [bucket moveToPoint:NSMakePoint(5, 2)];  // the handle
      [bucket lineToPoint:NSMakePoint(10, 7)];
      [bucket moveToPoint:NSMakePoint(2, 13)];  // the paint's level
      [bucket lineToPoint:NSMakePoint(17, 13)];
      [bucket transformUsingAffineTransform:grid];
      bucket.lineWidth = 1.5;
      bucket.lineCapStyle = NSLineCapStyleRound;
      bucket.lineJoinStyle = NSLineJoinStyleRound;
      [bucket stroke];
      NSBezierPath* drop = [NSBezierPath bezierPath];
      [drop moveToPoint:NSMakePoint(22, 20)];
      [drop appendBezierPathWithArcWithCenter:NSMakePoint(20, 20) radius:2 startAngle:0 endAngle:180 clockwise:NO];
      [drop curveToPoint:NSMakePoint(20, 16) controlPoint1:NSMakePoint(18, 18.4) controlPoint2:NSMakePoint(19.7, 17.6)];
      [drop curveToPoint:NSMakePoint(22, 20) controlPoint1:NSMakePoint(20.3, 17.6) controlPoint2:NSMakePoint(22, 18.4)];
      [drop transformUsingAffineTransform:grid];
      [drop fill];
      return YES;
    }];
    image.accessibilityDescription = label;
    return image;
}

NSImage* SPDFAnnotateSymbolImage(NSString* symbol, NSString* label) {
    if (!symbol.length) return nil;
    NSImage* image = [symbol isEqualToString:@"spdf.paintbucket"] ? SPDFAnnotatePaintBucket(label) : nil;
    if (!image) image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:label];
    // Symbols from SF Symbols 4 and later (macOS 13+) stand in with their macOS 12 family member.
    static NSDictionary<NSString*, NSString*>* older;
    if (!older)
        older = @{@"pencil.line" : @"pencil", @"pencil.and.scribble" : @"scribble", @"drop.halffull" : @"drop",
                  @"triangle.righthalf.filled" : @"triangle", @"eraser" : @"delete.left", @"highlighter" : @"pencil.tip",
                  @"oval" : @"circle", @"diamond" : @"square.rotated", @"lasso" : @"scribble",
                  @"rectangle.dashed" : @"rectangle"};
    for (NSString* name = older[symbol]; !image && name; name = older[name])
        image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:label];
    if (!image) image = [NSImage imageWithSystemSymbolName:@"questionmark.square.dashed" accessibilityDescription:label];
    [image setTemplate:YES];
    return image;
}
