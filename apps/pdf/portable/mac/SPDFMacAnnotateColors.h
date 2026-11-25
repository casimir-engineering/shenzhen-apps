#pragma once
// The palette's Colors group (docs/plans/annotate.md § 2 Colors): the Color 1 / Color 2 swatches (click one to choose
// which the palette sets; X swaps them, D resets them), Paint's 20 colours in two rows, the 10 custom slots, and Edit
// colors (the macOS colour panel; the colour made there also goes into the next empty custom slot). Left-click a
// swatch sets the chosen colour (Color 1 unless Color 2 was clicked), right-click sets Color 2. Colours > Save Colors...
// and Get Colors... write and read a palette as .json or a Paint/RIFF .pal.
//
// Every change is colors.set or palette.set_custom through -[SPDFMacFillController applyOperation:tab:completion:].
#import <Cocoa/Cocoa.h>

@class SPDFMacFillController, SPDFMacAnnotateSession;

NS_ASSUME_NONNULL_BEGIN

@interface SPDFMacAnnotateColorsView : NSView
- (instancetype)initWithController:(SPDFMacFillController*)controller;
- (void)updateFromSession:(nullable SPDFMacAnnotateSession*)session;
// The compact form for a narrow palette: Color 1 / Color 2 only; the palette and custom slots go into a menu.
@property(nonatomic) BOOL compact;
@end

// Edit colors: the colour panel, its colour going to the chosen swatch (Color 1 unless Color 2 was chosen).
FOUNDATION_EXPORT void SPDFAnnotateOpenColorPanel(SPDFMacFillController* controller);
FOUNDATION_EXPORT void SPDFAnnotateSaveColorsFile(SPDFMacFillController* controller);
FOUNDATION_EXPORT void SPDFAnnotateGetColorsFile(SPDFMacFillController* controller);
// The palette's colours as a menu (the narrow palette's Colors button and the More menu): each item sets Color 1.
FOUNDATION_EXPORT NSMenu* SPDFAnnotateColorsMenu(SPDFMacFillController* controller);

NS_ASSUME_NONNULL_END
