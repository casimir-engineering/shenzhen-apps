#pragma once
// The Fill & Sign palette: a pill at the top of the page area with Text, check, cross, Pen, Arrow, Eraser, Select,
// Signature and Done, the form's progress, the drawing options while a drawing tool is chosen, and a one-line hint the
// first time a form is filled. It floats over the pages; the document view keeps
// room above the first page (topReserve) so nothing on a page stays hidden under it.
#import <Cocoa/Cocoa.h>

@class SPDFMacFillController, SPDFFillSession;

@interface SPDFMacFillPalette : NSView
- (instancetype)initWithController:(SPDFMacFillController*)controller;
- (void)attachToContainer:(NSView*)container aboveView:(NSView*)view;
// note: a line shown under the tools in place of the first-form hint (nil: none).
- (void)updateFromSession:(SPDFFillSession*)session progress:(NSString*)progress note:(NSString*)note;
// The height to keep clear above the first page: as tall as the palette gets with any tool chosen, so choosing one
// never moves the pages.
- (CGFloat)reservedHeight;
@end
