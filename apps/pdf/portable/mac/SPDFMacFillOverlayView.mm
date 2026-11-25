#import "SPDFMacFillOverlayViewPrivate.h"

#import "SPDFMacDocumentView.h"
#import "SPDFMacFillController.h"
#import "SPDFMacFillEditor.h"
#import "SPDFMacModels.h"
#import "SPDFMacPageRendering.h"
#import "SPDFMacSignatureStore.h"

NSBezierPath* SPDFFillMarkPath(NSRect r, BOOL cross) {
    NSBezierPath* path = [NSBezierPath bezierPath];
    CGFloat w = NSWidth(r), h = NSHeight(r);
    if (cross) {
        [path moveToPoint:NSMakePoint(NSMinX(r) + 0.2 * w, NSMinY(r) + 0.2 * h)];
        [path lineToPoint:NSMakePoint(NSMinX(r) + 0.8 * w, NSMinY(r) + 0.8 * h)];
        [path moveToPoint:NSMakePoint(NSMinX(r) + 0.8 * w, NSMinY(r) + 0.2 * h)];
        [path lineToPoint:NSMakePoint(NSMinX(r) + 0.2 * w, NSMinY(r) + 0.8 * h)];
    } else {
        [path moveToPoint:NSMakePoint(NSMinX(r) + 0.15 * w, NSMinY(r) + 0.55 * h)];
        [path lineToPoint:NSMakePoint(NSMinX(r) + 0.40 * w, NSMinY(r) + 0.80 * h)];
        [path lineToPoint:NSMakePoint(NSMinX(r) + 0.85 * w, NSMinY(r) + 0.20 * h)];
    }
    path.lineWidth = MAX(1.0, 0.1 * MIN(w, h));
    path.lineCapStyle = NSLineCapStyleRound;
    path.lineJoinStyle = NSLineJoinStyleRound;
    return path;
}

@implementation SPDFMacFillOverlayView {
    __weak NSScrollView* _scrollView;
    __weak NSView* _observedDocumentView;
    NSTrackingArea* _tracking;
    // Under the pointer.
    NSInteger _hoverPage;
    NSPoint _hoverPoint;
    SPDFFillField* _hoverField;
    spdf_snap_result _hoverSnap;
    BOOL _hoverSnapValid;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent*)event { (void)event; return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

- (void)attachToScrollView:(NSScrollView*)scrollView {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self removeFromSuperview];
    _scrollView = scrollView;
    self.frame = scrollView.contentView.frame;
    self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [scrollView addSubview:self positioned:NSWindowAbove relativeTo:scrollView.contentView];
    NSClipView* clip = scrollView.contentView;
    clip.postsBoundsChangedNotifications = YES;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(viewportChanged:)
                                               name:NSViewBoundsDidChangeNotification object:clip];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(viewportChanged:)
                                               name:NSViewFrameDidChangeNotification object:clip];
    [self observeDocumentView];
    [self annotateAttachCanvasView];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)observeDocumentView {
    NSView* documentView = _scrollView.documentView;
    if (documentView == _observedDocumentView) return;
    if (_observedDocumentView)
        [NSNotificationCenter.defaultCenter removeObserver:self name:NSViewFrameDidChangeNotification
                                                    object:_observedDocumentView];
    _observedDocumentView = documentView;
    if (documentView)
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(viewportChanged:)
                                                   name:NSViewFrameDidChangeNotification object:documentView];
}

- (void)viewportChanged:(NSNotification*)note {
    (void)note;
    if (self.hidden) return;
    NSRect clipFrame = _scrollView.contentView.frame;
    if (!NSEqualRects(self.frame, clipFrame)) self.frame = clipFrame;
    [self observeDocumentView];
    [self.controller.editor layoutInOverlay:self];
    [self prefetchGeometry];
    self.needsDisplay = YES;
}

// Scrolling and zooming over the overlay behave as over the pages themselves.
- (void)scrollWheel:(NSEvent*)event { [[self documentView] scrollWheel:event]; }
- (void)magnifyWithEvent:(NSEvent*)event {
    [self.controller writePendingStrokes];  // lines waiting are written before the pages are zoomed
    [[self documentView] magnifyWithEvent:event];
}
// Any Command key (print, close, save, zoom...) may read the file: lines waiting are written first.
- (BOOL)performKeyEquivalent:(NSEvent*)event {
    if (!self.hidden && (event.modifierFlags & NSEventModifierFlagCommand)) [self.controller writePendingStrokes];
    return [super performKeyEquivalent:event];
}
- (void)smartMagnifyWithEvent:(NSEvent*)event { [[self documentView] smartMagnifyWithEvent:event]; }
- (void)swipeWithEvent:(NSEvent*)event { [[self documentView] swipeWithEvent:event]; }

// Lines and boxes of the pages in view (and one either side) are read in the background before the pointer needs them.
- (void)prefetchGeometry {
    NSArray<NSNumber*>* pages = [self visiblePages];
    if (!pages.count) return;
    NSInteger first = MAX(0, pages.firstObject.integerValue - 1);
    NSInteger last = MIN((NSInteger)[self documentView].pages.count - 1, pages.lastObject.integerValue + 1);
    for (NSInteger page = first; page <= last; ++page) [self.controller geometryForPage:page];
}

- (void)refresh {
    [self observeDocumentView];
    [self prefetchGeometry];
    if (self.selectedItem) {  // the page was read again after a change: keep the selection on the new copy
        SPDFFillItem* fresh = nil;
        for (SPDFFillItem* item in [self.controller itemsOnPage:self.selectedItem.page])
            if ([item.nm isEqual:self.selectedItem.nm]) fresh = item;
        self.selectedItem = fresh;
    }
    [self.controller.editor layoutInOverlay:self];
    self.needsDisplay = YES;
}

- (void)clearTransientState {
    self.hoverItem = nil;
    _hoverField = nil;
    _hoverSnapValid = NO;
    self.dragItem = nil;
    self.selectedItem = nil;
    self.focusedField = nil;
    self.focusedTargetRect = NSZeroRect;
    [self cancelDrawingGesture];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc]
        initWithRect:NSZeroRect
             options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
               owner:self
            userInfo:nil];
    [self addTrackingArea:_tracking];
}

#pragma mark - Geometry

- (SPDFDocumentView*)documentView {
    NSView* view = _scrollView.documentView;
    return [view isKindOfClass:SPDFDocumentView.class] ? (SPDFDocumentView*)view : nil;
}

- (SPDFRenderedPage*)renderedPage:(NSInteger)index {
    NSArray* pages = [self documentView].pages;
    return index >= 0 && index < (NSInteger)pages.count ? pages[(NSUInteger)index] : nil;
}

- (CGFloat)zoom {
    SPDFDocumentView* view = [self documentView];
    SPDFRenderedPage* page = [self renderedPage:view.currentPageIndex];
    NSRect rect = [view rectForPageAtIndex:view.currentPageIndex];
    CGFloat zoom = page && page.pageWidth > 0 ? NSWidth([self convertRect:rect fromView:view]) / page.pageWidth : 1;
    return zoom > 0.01 ? zoom : 1;
}

- (NSRect)viewRectForPageRect:(NSRect)rect page:(NSInteger)index {
    SPDFDocumentView* view = [self documentView];
    SPDFRenderedPage* page = [self renderedPage:index];
    if (!view || !page) return NSZeroRect;
    NSRect inDocument = spdf_mac_page_rect_to_view_rect(rect, [view rectForPageAtIndex:index], page);
    return [self convertRect:inDocument fromView:view];
}

- (BOOL)locateViewPoint:(NSPoint)point page:(NSInteger*)index pagePoint:(NSPoint*)pagePoint {
    SPDFDocumentView* view = [self documentView];
    if (!view) return NO;
    return [view point:[self convertPoint:point toView:view] fallsInPage:index pagePoint:pagePoint];
}

- (NSArray<NSNumber*>*)visiblePages {
    SPDFDocumentView* view = [self documentView];
    NSArray* pages = view.pages;
    if (!pages.count) return @[];
    NSRect visible = view.visibleRect;
    NSInteger center = MAX(0, MIN((NSInteger)pages.count - 1, [view pageIndexForVisibleRect:visible]));
    NSMutableArray* result = [NSMutableArray array];
    for (NSInteger i = center; i >= 0 && NSIntersectsRect([view rectForPageAtIndex:i], visible); --i)
        [result insertObject:@(i) atIndex:0];
    for (NSInteger i = center + 1; i < (NSInteger)pages.count && NSIntersectsRect([view rectForPageAtIndex:i], visible); ++i)
        [result addObject:@(i)];
    if (!result.count) [result addObject:@(center)];
    return result;
}

- (void)revealPageRect:(NSRect)rect page:(NSInteger)index {
    SPDFDocumentView* view = [self documentView];
    if (!view) return;
    NSRect inDocument = spdf_mac_page_rect_to_view_rect(NSInsetRect(rect, -24, -40), [view rectForPageAtIndex:index],
                                                        [self renderedPage:index]);
    // The palette covers the top of the viewport: what is revealed lands below it.
    inDocument.origin.y -= view.topReserve;
    inDocument.size.height += view.topReserve;
    [view scrollRectToVisible:inDocument];
}

- (spdf_snap_kind)resolveAt:(NSPoint)p page:(NSInteger)index purpose:(spdf_snap_purpose)purpose aspect:(CGFloat)aspect
                   snapping:(BOOL)snapping result:(spdf_snap_result*)out {
    memset(out, 0, sizeof(*out));
    const spdf_snap_geometry* geometry = snapping ? [self.controller geometryForPage:index] : NULL;
    if (geometry) {
        CGFloat radius = MAX(6.0, 14.0 / [self zoom]);
        return spdf_snap_resolve(geometry, (float)p.x, (float)p.y, (float)radius, purpose, (float)aspect, out);
    }
    SPDFRenderedPage* page = [self renderedPage:index];
    CGFloat pageWidth = page ? page.pageWidth : 612;
    if (purpose == SPDF_SNAP_FOR_TEXT) {
        out->font_size = 11;
        out->baseline = (float)p.y;
        out->place = spdf_fill_text_rect((float)p.x, (float)p.y, (float)MAX(40.0, MIN(220.0, pageWidth - p.x - 4)), 11, 1);
    } else if (purpose == SPDF_SNAP_FOR_MARK) {
        out->font_size = 10;
        out->place = SPDFFillRectToCore(NSMakeRect(p.x - 5, p.y - 5, 10, 10));
    } else {
        CGFloat width = 150, height = width / MAX(0.2, aspect);
        out->place = SPDFFillRectToCore(NSMakeRect(p.x - width / 2, p.y - height / 2, width, height));
    }
    out->target = out->place;
    out->kind = SPDF_SNAP_NONE;
    return SPDF_SNAP_NONE;
}

- (SPDFFillItem*)itemAt:(NSPoint)p page:(NSInteger)index {
    CGFloat slop = 3.0 / [self zoom];
    BOOL drawings = [self drawingsAnswerPointer];  // with Text, marks or Signature, lines let clicks through
    for (SPDFFillItem* item in [[self.controller itemsOnPage:index] reverseObjectEnumerator]) {
        if (item.isDrawing) {
            if (drawings && [self drawing:item isNear:p]) return item;
        } else if (NSPointInRect(p, NSInsetRect(item.rect, -slop, -slop))) {
            return item;
        }
    }
    return nil;
}

- (SPDFFillField*)fieldAt:(NSPoint)p page:(NSInteger)index {
    for (SPDFFillField* field in [[self.controller fieldsOnPage:index] reverseObjectEnumerator])
        if (!field.hidden && NSPointInRect(p, field.rect)) return field;
    return nil;
}

- (spdf_snap_purpose)purpose {
    SPDFFillTool tool = [self.controller session].tool;
    return tool == SPDFFillToolMark ? SPDF_SNAP_FOR_MARK : tool == SPDFFillToolSignature ? SPDF_SNAP_FOR_SIGNATURE
                                                                                        : SPDF_SNAP_FOR_TEXT;
}

#pragma mark - Drawing

- (NSColor*)accent {
    return NSColor.controlAccentColor;
}

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    if ([self documentView].liveZooming) return;
    SPDFFillSession* session = [self.controller session];
    NSColor* accent = [self accent];
    for (NSNumber* number in [self visiblePages]) {
        NSInteger index = number.integerValue;
        for (SPDFFillField* field in [self.controller fieldsOnPage:index]) {
            if (field.hidden || field.readOnly) continue;
            NSRect r = [self viewRectForPageRect:field.rect page:index];
            BOOL focused = [self.controller isFieldFocused:field] || field == _hoverField;
            [[accent colorWithAlphaComponent:field.filled ? 0.05 : 0.10] setFill];
            NSRectFillUsingOperation(r, NSCompositingOperationSourceOver);
            NSBezierPath* outline = [NSBezierPath bezierPathWithRect:NSInsetRect(r, 0.5, 0.5)];
            BOOL required = (field.flags & SPDF_FIELD_REQUIRED) != 0 && !field.filled;
            outline.lineWidth = focused ? 2 : required ? 1.5 : 1;
            [[accent colorWithAlphaComponent:focused ? 0.9 : required ? 0.7 : 0.35] setStroke];
            [outline stroke];
        }
        for (SPDFFillItem* item in [self.controller itemsOnPage:index]) {
            if (item.isDrawing) continue;  // lines show their selection in the drawing layer
            BOOL selected = [item.nm isEqual:self.selectedItem.nm];
            if (!selected && ![item.nm isEqual:self.hoverItem.nm]) continue;
            NSRect r = NSInsetRect([self viewRectForPageRect:item.rect page:index], -2, -2);
            NSBezierPath* outline = [NSBezierPath bezierPathWithRoundedRect:r xRadius:3 yRadius:3];
            outline.lineWidth = 1;
            if (!selected) {
                CGFloat dash[2] = {3, 2};
                [outline setLineDash:dash count:2 phase:0];
            }
            [[accent colorWithAlphaComponent:selected ? 0.9 : 0.6] setStroke];
            [outline stroke];
            if (selected && !item.text) {
                [accent setFill];
                NSRectFill([self resizeHandleForViewRect:r]);
            }
        }
        if (!NSIsEmptyRect(self.focusedTargetRect) && self.focusedTargetPage == index) {
            NSBezierPath* ring = [NSBezierPath bezierPathWithRect:
                NSInsetRect([self viewRectForPageRect:self.focusedTargetRect page:index], -1, -1)];
            ring.lineWidth = 2;
            [[accent colorWithAlphaComponent:0.9] setStroke];
            [ring stroke];
        }
    }
    [self drawDrawingLayer];
    if (self.dragItem) {
        NSRect r = [self viewRectForPageRect:self.dragRect page:self.dragItem.page];
        [[accent colorWithAlphaComponent:0.12] setFill];
        NSRectFillUsingOperation(r, NSCompositingOperationSourceOver);
        [[accent colorWithAlphaComponent:0.9] setStroke];
        [NSBezierPath strokeRect:NSInsetRect(r, 0.5, 0.5)];
        return;
    }
    // Nothing is offered where nothing can be added (a PDF that only allows filling in its own fields).
    BOOL placing = !session.hasSummary || session.summary.can_add_items;
    if (placing && _hoverSnapValid && !self.hoverItem && !_hoverField && !self.controller.editor &&
        !SPDFFillToolDraws(session.tool))
        [self drawHoverTarget:session];
}

- (NSRect)resizeHandleForViewRect:(NSRect)r {
    return NSMakeRect(NSMaxX(r) - 4, NSMaxY(r) - 4, 8, 8);
}

- (void)drawHoverTarget:(SPDFFillSession*)session {
    NSColor* accent = [self accent];
    NSRect target = [self viewRectForPageRect:SPDFFillRectFromCore(_hoverSnap.target) page:_hoverPage];
    NSRect place = [self viewRectForPageRect:SPDFFillRectFromCore(_hoverSnap.place) page:_hoverPage];
    if (_hoverSnap.kind != SPDF_SNAP_NONE && _hoverSnap.kind != SPDF_SNAP_FIELD) {
        [[accent colorWithAlphaComponent:0.12] setFill];
        NSRectFillUsingOperation(target, NSCompositingOperationSourceOver);
        [[accent colorWithAlphaComponent:0.55] setStroke];
        if (_hoverSnap.kind == SPDF_SNAP_UNDERLINE) {
            NSBezierPath* line = [NSBezierPath bezierPath];
            [line moveToPoint:NSMakePoint(NSMinX(target), NSMaxY(target))];
            [line lineToPoint:NSMakePoint(NSMaxX(target), NSMaxY(target))];
            line.lineWidth = 1.5;
            [line stroke];
        } else {
            [NSBezierPath strokeRect:NSInsetRect(target, 0.5, 0.5)];
        }
        for (int i = 0; _hoverSnap.cells && i < _hoverSnap.cell_count; ++i)
            [NSBezierPath strokeRect:NSInsetRect([self viewRectForPageRect:SPDFFillRectFromCore(_hoverSnap.cells[i])
                                                                      page:_hoverPage], 0.5, 0.5)];
    }
    if (session.tool == SPDFFillToolSignature && session.pickedSignature) {
        [session.pickedSignature drawInRect:place flipped:YES alpha:0.45];
    } else if (session.tool == SPDFFillToolMark || _hoverSnap.place_mark) {
        BOOL cross = session.markCross;
        if (NSEvent.modifierFlags & NSEventModifierFlagOption) cross = !cross;
        NSBezierPath* mark = SPDFFillMarkPath(place, cross);
        [[NSColor colorWithWhite:0 alpha:0.35] setStroke];
        [mark stroke];
    } else if (_hoverSnap.kind != SPDF_SNAP_FIELD) {
        // A caret where typing would start: on the baseline the text will sit on.
        CGFloat zoom = [self zoom];
        CGFloat size = MAX(6.0, _hoverSnap.font_size) * zoom;
        NSPoint base = [self viewRectForPageRect:NSMakeRect(_hoverSnap.place.x0, _hoverSnap.baseline, 0, 0)
                                            page:_hoverPage].origin;
        NSBezierPath* caret = [NSBezierPath bezierPath];
        [caret moveToPoint:NSMakePoint(base.x + 0.5, base.y - 0.8 * size)];
        [caret lineToPoint:NSMakePoint(base.x + 0.5, base.y + 0.2 * size)];
        caret.lineWidth = 1.5;
        [[accent colorWithAlphaComponent:0.8] setStroke];
        [caret stroke];
    }
}

#pragma mark - Hover

- (void)mouseMoved:(NSEvent*)event {
    if ([self annotateMouseMoved:event]) return;
    [self updateHover:[self convertPoint:event.locationInWindow fromView:nil] modifiers:event.modifierFlags];
}

- (void)mouseExited:(NSEvent*)event {
    (void)event;
    self.hoverItem = nil;
    _hoverField = nil;
    _hoverSnapValid = NO;
    self.needsDisplay = YES;
    [self.controller writePendingStrokes];  // the pointer left the pages
}

- (void)flagsChanged:(NSEvent*)event {
    [self updateHover:[self convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil]
            modifiers:event.modifierFlags];
}

- (void)updateHover:(NSPoint)point modifiers:(NSEventModifierFlags)modifiers {
    if ([self drawingHover:point]) {
        _hoverField = nil;
        _hoverSnapValid = NO;
        return;
    }
    NSInteger index = -1;
    NSPoint p = NSZeroPoint;
    SPDFFillItem* item = nil;
    SPDFFillField* field = nil;
    BOOL snapValid = NO;
    if (!self.hidden && [self locateViewPoint:point page:&index pagePoint:&p]) {
        item = [self itemAt:p page:index];
        field = item ? nil : [self fieldAt:p page:index];
        if (!item && !field) {
            SPDFFillSession* session = [self.controller session];
            CGFloat aspect = session.pickedSignature ? session.pickedSignature.aspect : 3;
            [self resolveAt:p page:index purpose:[self purpose] aspect:aspect
                   snapping:!(modifiers & NSEventModifierFlagCommand) result:&_hoverSnap];
            snapValid = YES;
        }
    }
    _hoverPage = index;
    _hoverPoint = p;
    self.hoverItem = item;
    _hoverField = field;
    _hoverSnapValid = snapValid;
    self.toolTip = field.readOnly ? @"This field can't be changed" : nil;
    self.needsDisplay = YES;
    NSCursor* cursor = NSCursor.arrowCursor;
    if (snapValid) {
        SPDFFillTool tool = [self.controller session].tool;
        cursor = tool == SPDFFillToolText && !_hoverSnap.place_mark ? NSCursor.IBeamCursor : NSCursor.crosshairCursor;
    } else if (item) {
        cursor = NSCursor.openHandCursor;
    } else if (field && !field.readOnly) {
        cursor = field.type == SPDF_FIELD_TEXT ? NSCursor.IBeamCursor : NSCursor.pointingHandCursor;
    }
    // After the page view's own cursor update for this move.
    dispatch_async(dispatch_get_main_queue(), ^{ if (!self.hidden) [cursor set]; });
}

#pragma mark - Hit testing and mouse

- (NSView*)hitTest:(NSPoint)point {
    if (self.hidden) return nil;
    NSView* hit = [super hitTest:point];
    if (hit && hit != self) return hit;  // the editor and its suggestions
    NSPoint local = [self convertPoint:point fromView:self.superview];
    NSInteger index;
    return [self locateViewPoint:local page:&index pagePoint:NULL] ? self : nil;
}

- (void)mouseDown:(NSEvent*)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger index;
    NSPoint p;
    if ([self annotateTakeMouseDown:event]) return;
    if (![self locateViewPoint:point page:&index pagePoint:&p] || [self drawingMouseDown:event]) return;
    [self.controller.editor commitAndClose];
    [self.window makeFirstResponder:self];
    SPDFFillItem* item = [self itemAt:p page:index];
    if (item) {
        [self trackItem:item page:index from:point event:event];
        return;
    }
    self.selectedItem = nil;
    self.focusedTargetRect = NSZeroRect;
    [self.controller clickOnPage:index at:p modifiers:event.modifierFlags];
    [self updateHover:point modifiers:event.modifierFlags];
}

@end
