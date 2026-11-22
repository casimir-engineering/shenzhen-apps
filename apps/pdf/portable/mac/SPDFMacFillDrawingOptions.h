#pragma once
// The palette's second row, shown only while Pen, Arrow, Eraser or Select is chosen: the colours and widths, the
// eraser's kind and sizes, and the bin that removes every pen line and arrow (docs/plans/fill-and-sign.md,
// "Pen and arrow"). Its buttons never take the keys, so Command-Z, Delete and the tool letters keep working.
#import <Cocoa/Cocoa.h>

#import "SPDFMacFillModel.h"

@protocol SPDFMacFillDrawingOptionsTarget <NSObject>
- (void)drawingOptionsChoseColor:(NSInteger)index;
- (void)drawingOptionsChoseWidth:(NSInteger)index;
- (void)drawingOptionsChoseEraserParts:(BOOL)parts;
- (void)drawingOptionsChoseEraserSize:(NSInteger)index;
- (void)drawingOptionsRemoveAll;
@end

@interface SPDFMacFillDrawingOptions : NSView
- (instancetype)initWithTarget:(id<SPDFMacFillDrawingOptionsTarget>)target;
// Shows what belongs to this tool, with the remembered choice marked. With the Select tool the colours and widths
// are usable only while the selection holds lines or arrows, and mark the selection's own colour and width
// (-1: they differ, nothing is marked).
- (void)showTool:(SPDFFillTool)tool selectionColor:(NSInteger)colorIndex width:(NSInteger)widthIndex
       styleable:(BOOL)styleable;
@end
