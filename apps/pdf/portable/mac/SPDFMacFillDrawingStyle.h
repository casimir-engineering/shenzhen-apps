#pragma once
// The pen's colours and widths, the eraser's kind and sizes, and the choice remembered between launches
// (docs/plans/fill-and-sign.md, "Pen and arrow"). Read from <state>/FillSign/drawing.json the first time a drawing
// tool is chosen, never at launch; written (0600, temp then rename) on every change.
#import <Cocoa/Cocoa.h>

#import "SPDFMacFillModel.h"

@interface SPDFMacFillDrawingStyle : NSObject
+ (instancetype)sharedStyle;

@property(nonatomic) NSInteger colorIndex;       // Red (default), Blue, Green, Black
@property(nonatomic) NSInteger widthIndex;       // Thin, Medium (default), Thick
@property(nonatomic) BOOL eraserParts;           // NO: whole lines (default)
@property(nonatomic) NSInteger eraserSizeIndex;  // Small, Medium (default), Large
@property(nonatomic, readonly) SPDFFillRGB color;
@property(nonatomic, readonly) CGFloat width;       // page points
@property(nonatomic, readonly) CGFloat eraserSize;  // screen points across

+ (NSInteger)colorCount;
+ (SPDFFillRGB)colorAtIndex:(NSInteger)index;
+ (NSString*)colorNameAtIndex:(NSInteger)index;
+ (NSInteger)indexOfColor:(SPDFFillRGB)color;  // -1 when it is none of ours
+ (NSInteger)widthCount;
+ (CGFloat)widthAtIndex:(NSInteger)index;
+ (NSString*)widthNameAtIndex:(NSInteger)index;
+ (NSInteger)indexOfWidth:(CGFloat)width;      // -1 when it is none of ours
+ (NSInteger)eraserSizeCount;
+ (CGFloat)eraserSizeAtIndex:(NSInteger)index;
+ (NSString*)eraserSizeNameAtIndex:(NSInteger)index;
@end

// A colour as the page images show it on the display whose colour space is `display` (the window's): their pixels go
// to the screen unconverted.
NSColor* SPDFFillDeviceColor(SPDFFillRGB color, CGFloat alpha, NSColorSpace* display);
// The colour a line shows on screen: as written, or recoloured the way the dark reading theme recolours the page's
// own pixels, so a line drawn over the page and the same line in the page image match.
NSColor* SPDFFillScreenColor(SPDFFillRGB color, BOOL darkPages, NSColorSpace* display);
