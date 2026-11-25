#pragma once
// The palette's second row for Annotate's tools (docs/plans/annotate.md § 1 Row 2, § 2): the size slider with its
// value (px on pictures, pt on PDFs), the opacity slider (Pencil and brushes), and the tool's own options: the
// Eraser's Whole lines / Pixels, Fill's Tolerance and Contiguous, the Color picker's source, the Shapes' Outline and
// Fill, the Text box's text bar, and Transparent selection. Pen and Arrow show Fill & Sign's colours and widths
// (SPDFMacFillDrawingOptions, beside this row) and the size slider.
//
// Each change is tool.choose {tool, options} through -[SPDFMacFillController applyOperation:tab:completion:]; when a
// shape or a text box is selected it is also restyled with object.update {id, ...}. One row, 28 pt high, whatever the
// tool, so choosing a tool never moves the pages.
#import <Cocoa/Cocoa.h>

#import "SPDFMacAnnotateSession.h"

@class SPDFMacFillController;

NS_ASSUME_NONNULL_BEGIN

@interface SPDFMacAnnotateToolOptions : NSView
- (instancetype)initWithController:(SPDFMacFillController*)controller;
// Shows the options of the session's tool with the remembered values. NO when that tool has none to show.
- (BOOL)showForSession:(nullable SPDFMacAnnotateSession*)session kind:(SPDFAnnotateDocumentKind)kind;
@end

NS_ASSUME_NONNULL_END
