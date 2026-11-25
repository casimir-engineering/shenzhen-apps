#pragma once
// The Annotate palette's groups (docs/plans/annotate.md § 1, § 2): what SPDFMacFillPalette shows in its two rows once
// it is the Annotate palette. The palette stays the pill at the top of the page area and keeps reserving its room
// above the pages (topReserve); these groups are its contents.
//
// Row 1: on a PDF first the Fill & Sign group (Text, check | cross, Signature, and "3 of 12 filled" when the PDF has a
// form), then on every document: Selection, Image group, Tools group (Pen, Arrow, Pencil, Fill, Text box, Eraser,
// Color picker, Magnifier), Brushes, Shapes, Color 1 / Color 2, the colour palette, Layers, Done. On a narrow window
// groups collapse to their icons, then into a "More" menu; Done always last and named.
// Row 2: the chosen tool's options: size slider with its value (px on pictures, pt on PDFs), opacity slider (Pencil
// and brushes), the tool's own options; Shapes add Outline and Fill; Text box adds the text bar; Pen and Arrow keep
// Fill & Sign's colours and widths and also take Color 1 and the size slider.
//
// Every control sends an operation through -[SPDFMacFillController applyOperation:tab:completion:]: tool.choose for
// tools and options, colors.set and palette.set_custom for colours, image.* for the Image group, mode.set {on: false}
// for Done. The parity check (§ 6) lists each control with the operation it sends.
#import <Cocoa/Cocoa.h>

#import "SPDFMacAnnotateSession.h"

@class SPDFMacFillController;

NS_ASSUME_NONNULL_BEGIN

// Paint's 20 colours in two rows (black, grey 50 %, dark red, red, orange, yellow, green, turquoise, indigo, purple /
// white, grey 25 %, brown, rose, gold, light yellow, lime, light turquoise, blue-grey, lavender), 0xRRGGBBAA.
FOUNDATION_EXPORT const spdf_paint_color SPDFAnnotatePaletteColors[20];

@interface SPDFMacAnnotatePaletteGroups : NSObject

- (instancetype)initWithController:(SPDFMacFillController*)controller;

// Row 1's groups for a document kind, left to right (Done last), and row 2 for the session's tool. The palette lays
// them out, collapsing to icons and then "More" as the width shrinks (-layoutRow1InWidth:).
- (NSArray<NSView*>*)row1ForKind:(SPDFAnnotateDocumentKind)kind;
- (NSView*)row2ForSession:(SPDFMacAnnotateSession*)session;
- (void)layoutRow1InWidth:(CGFloat)width;

// The session's tool, colours or options changed (from a key, a menu, an agent): controls follow.
- (void)updateFromSession:(nullable SPDFMacAnnotateSession*)session progress:(nullable NSString*)progress;

// The tallest row 2 any tool has, so choosing a tool never moves the pages (SPDFMacFillPalette -reservedHeight).
@property(nonatomic, readonly) CGFloat tallestRow2Height;

@end

NS_ASSUME_NONNULL_END
