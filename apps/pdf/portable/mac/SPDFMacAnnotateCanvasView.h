#pragma once
// What Annotate draws over a picture or each PDF page, and the gestures that become operations (docs/plans/annotate.md
// § 1 The window, § 8 Mac). A transparent view kept just above the Fill & Sign overlay (SPDFMacFillOverlayView) while
// a canvas tool is chosen (its hitTest: lets every event through to the overlay for the PDF form tools), over the
// reader's page viewport, the same size; it scrolls nothing and hands scroll and zoom gestures on to the scroll view,
// as the overlay does. Page geometry comes from the overlay on every draw
// (-viewRectForPageRect:page:, -locateViewPoint:page:pagePoint:), so zoom, scrolling and tab switches need no
// bookkeeping.
//
// It draws, per visible page or the picture: the checkerboard under transparent pixels (8 x 8 pt squares, #FFFFFF /
// #E8E8E8 in light appearance, #3C3C3C / #323232 in dark; screen only), the composite tiles from spdf_paint_render
// (the picture's own Background included, nearest neighbour above 100 %; on a PDF everything above the page, which
// the reader already draws), the live preview of the stroke or shape being drawn, the marching ants, the selected
// objects' box with eight handles and a rotation handle, the canvas handles (right edge, bottom edge, corner:
// pictures and canvases only) with the dotted outline while one is dragged, rulers (px) and the gridlines (from 400 %).
//
// Gestures: a tool's mouse-down to mouse-up is previewed here and sent on release as ONE operation through
// -[SPDFMacFillController applyOperation:tab:completion:] (a stroke as one paint.stroke with every point, a drag as one
// object.move). The right button: right-click without moving (4 pt) or Control-click opens the context menu of what
// is under the pointer (SPDFAnnotateContextMenu, SPDFMacAnnotateIntegration.h); a right-drag with a pixel or shape
// tool draws with Color 2. Escape cancels the gesture in progress.
//
// On a PDF with a Fill & Sign form tool (Text, marks, Signature) chosen, the overlay keeps every event as today.
#import <Cocoa/Cocoa.h>

#import "SPDFMacAnnotateSession.h"

@class SPDFMacFillController, SPDFMacFillOverlayView;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const SPDFAnnotateCanvasPointerDidMoveNotification;

@interface SPDFMacAnnotateCanvasView : NSView

- (instancetype)initWithController:(SPDFMacFillController*)controller;
@property(nonatomic, weak, readonly) SPDFMacFillController* controller;

// Placed just above the overlay in its superview (the scroll view), same frame; removed with it.
- (void)attachBelowOverlay:(SPDFMacFillOverlayView*)overlay;
@property(nonatomic, weak, readonly, nullable) SPDFMacFillOverlayView* overlay;

// The tab's session; nil hides everything (Annotate off, a text document).
@property(nonatomic, weak, nullable) SPDFMacAnnotateSession* session;

// YES when the session's tool is one this view draws with (every tool but the PDF form group, and on a PDF Fill &
// Sign's own pen, arrow, whole-line eraser and Select): the view takes the events, else they reach the overlay.
- (BOOL)takesEventsForTool:(SPDFAnnotateTool)tool;

// A canvas changed (an operation, undo, redo, a reload): reads its damage (spdf_paint_take_damage) and redraws only
// those tiles. page -1: the picture.
- (void)canvasDidChangeOnPage:(NSInteger)page;
// The canvas size changed (canvas.resize, crop, rotate): the picture's page box follows; the reader re-lays it out.
- (void)canvasSizeDidChange;
// Tool, colours or options changed: cursor and live preview follow.
- (void)toolDidChange;

// Conversions for the status bar and the agents' coordinates: canvas units (px on pictures, pt on PDF pages from the
// page's top-left as displayed) for a point in this view, and back. NO when the point is on no page.
- (BOOL)canvasPointForViewPoint:(NSPoint)point page:(NSInteger* _Nullable)page canvasPoint:(NSPoint*)canvasPoint;
- (NSRect)viewRectForCanvasRect:(NSRect)rect page:(NSInteger)page;

// View menu options (also view.set): drawn here; the status bar is the integration's.
@property(nonatomic) BOOL showsRulers;
@property(nonatomic) BOOL showsGridlines;
@property(nonatomic) BOOL showsThumbnail;  // View > Thumbnail: the whole picture, small, floating, while zoomed in

// The text box being typed in is closed and its text sent (one text.add or object.update), before anything reads the
// canvas (tab switch, save, Done).
- (void)commitTextEditor;
// Escape: drops the gesture in progress (nothing is sent). YES when there was one.
- (BOOL)cancelGesture;

// View points per canvas unit on the picture (or the page under the pointer): 1 = 100 %.
- (CGFloat)zoomLevel;
// Becomes the window's first responder, so Escape, Delete, arrows and the tool letters reach Annotate.
- (void)takeKeys;
// Done: the canvas stays drawn over the page until the reader shows the written file (-releaseHeldFrame).
- (void)holdLastFrameUntilReload;
- (void)releaseHeldFrame;
@property(nonatomic, readonly) BOOL holdsLastFrame;

// For the status bar: the pointer in canvas units (hasPointer NO when it is off the canvas), and the size a canvas
// handle being dragged would give (NSZeroSize when none is). Posted as SPDFAnnotateCanvasPointerDidMoveNotification.
@property(nonatomic, readonly) BOOL hasPointer;
@property(nonatomic, readonly) NSPoint pointerPoint;
@property(nonatomic, readonly) NSInteger pointerPage;
@property(nonatomic, readonly) NSSize liveResizeSize;
// The size of what is selected (objects' box or the pixel selection's), NSZeroSize when nothing is.
- (NSSize)selectionSize;

@end

NS_ASSUME_NONNULL_END
