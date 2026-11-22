#pragma once
// Turning what the signature sheet collects into what the core places: filled outlines in a box one unit high, y down
// (spdf_fill_add_signature_paths), or a cropped PNG with the paper made transparent (spdf_fill_add_signature_png).
#import <Cocoa/Cocoa.h>

// One stroke of the drawing pad: points in pad coordinates (y up) with the time each was reached.
@interface SPDFSignatureStroke : NSObject
@property(nonatomic, readonly) NSMutableArray<NSValue*>* points;
@property(nonatomic, readonly) NSMutableArray<NSNumber*>* times;
- (void)addPoint:(NSPoint)point time:(NSTimeInterval)time;
@end

// Smoothed strokes as a path to draw while signing (stroked, not filled).
NSBezierPath* SPDFSignatureSmoothedStroke(SPDFSignatureStroke* stroke);
// Filled outlines of the strokes: thinner where the pen moved fast, round ends. nil when nothing was drawn.
NSArray<NSString*>* SPDFSignatureOutlinesFromStrokes(NSArray<SPDFSignatureStroke*>* strokes, CGFloat penWidth,
                                                     CGFloat* aspectOut);
// Glyph outlines of text in font (nothing embedded: the letters become shapes). nil for empty text.
NSArray<NSString*>* SPDFSignatureOutlinesFromText(NSString* text, NSFont* font, CGFloat* aspectOut);
// A photo or scan: dark ink kept, light paper made transparent, cropped to the ink. nil when no ink was found.
NSData* SPDFSignaturePictureFromImage(NSImage* image, CGFloat* aspectOut);
