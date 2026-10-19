#import "SPDFMacMarkdownPageCanvasPrivate.h"

#import <CoreText/CoreText.h>

#import "SPDFMacContextPage.h"
#import "SPDFMacFitGeometry.h"
#import "SPDFMacUIHelpers.h"
#import "SPDFMacMarkdownPanController.h"
#import "SPDFMacMarkdownView.h"
#import "markdown/SPDFMarkdown.h"

static const CGFloat kSPDFMarkdownPageGap = 18.0;
static const CGFloat kSPDFMarkdownCanvasInset = 24.0;

@implementation SPDFMacMarkdownPageCanvas {
    SPDFMarkdownPaginationPlan* _plan;
    NSAttributedString* _attributedString;
    NSTrackingArea* _trackingArea;
    NSUInteger _dragAnchor;
    BOOL _draggingSelection;
}

// Expose the plan and rendered string to the canvas categories (see
// SPDFMacMarkdownPageCanvasPrivate.h).
@synthesize plan = _plan;
@synthesize attributedString = _attributedString;

- (instancetype)initWithPaginationPlan:(SPDFMarkdownPaginationPlan*)plan
                      attributedString:(NSAttributedString*)attributedString {
    NSParameterAssert(plan);
    NSParameterAssert(attributedString);
    self = [super initWithFrame:NSZeroRect];
    if (!self) return nil;
    _plan = plan;
    _attributedString = [attributedString copy];
    _selectedRange = NSMakeRange(0, 0);
    _searchRanges = @[];
    _activeSearchRange = NSMakeRange(0, 0);
    _activeSearchAlpha = 0.0;
    self.wantsLayer = YES;
    // PDF parity: when a hand pan releases the pointer, the hover cursor is
    // re-resolved for the current mouse location (endPan does the same).
    __weak SPDFMacMarkdownPageCanvas* weakSelf = self;
    self.spdf_panController.panDidEndHandler = ^{
      [weakSelf refreshCursorForMouseLocation];
    };
    return self;
}

- (BOOL)isFlipped {
    return YES;
}
- (BOOL)isOpaque {
    return YES;
}
- (BOOL)acceptsFirstResponder {
    return YES;
}
- (BOOL)acceptsFirstMouse:(NSEvent*)event {
    (void)event;
    return YES;
}
- (NSUInteger)pageCount {
    return _plan.pages.count;
}

- (void)setSelectedRange:(NSRange)selectedRange {
    if (selectedRange.location == NSNotFound || NSMaxRange(selectedRange) > _attributedString.length)
        selectedRange = NSMakeRange(0, 0);
    if (NSEqualRanges(_selectedRange, selectedRange)) return;
    _selectedRange = selectedRange;
    [self setNeedsDisplay:YES];
    if (self.selectionChangedHandler) self.selectionChangedHandler(selectedRange);
}

- (void)setSearchRanges:(NSArray<NSValue*>*)searchRanges {
    _searchRanges = [searchRanges copy] ?: @[];
    [self setNeedsDisplay:YES];
}

// Setting the active match (or its outline alpha) repaints only — scrolling to
// a match is the paged view's centerRange: responsibility.
- (void)setActiveSearchRange:(NSRange)activeSearchRange {
    if (activeSearchRange.location == NSNotFound || NSMaxRange(activeSearchRange) > _attributedString.length)
        activeSearchRange = NSMakeRange(0, 0);
    if (NSEqualRanges(_activeSearchRange, activeSearchRange)) return;
    _activeSearchRange = activeSearchRange;
    [self setNeedsDisplay:YES];
}

- (void)setActiveSearchAlpha:(CGFloat)activeSearchAlpha {
    activeSearchAlpha = MAX(0.0, MIN(1.0, activeSearchAlpha));
    if (fabs(activeSearchAlpha - _activeSearchAlpha) < 0.0001) return;
    _activeSearchAlpha = activeSearchAlpha;
    [self setNeedsDisplay:YES];
}

- (BOOL)isDraggingSelection {
    return _draggingSelection;
}

// Exact-fit vertical inset (see SPDFMacFitGeometry.h): the decorative canvas
// inset while pages are much shorter than the viewport, 0 at and beyond exact
// fit, and the vertical-centering split for a one-page document below fit.
- (CGFloat)verticalCanvasInset {
    return spdf_mac_vertical_canvas_inset(self.pageCount, _plan.configuration.paperSize.height,
                                          self.layoutViewportSize.height, kSPDFMarkdownCanvasInset);
}

- (NSRect)frameForPageAtIndex:(NSUInteger)pageIndex {
    if (pageIndex >= self.pageCount) return NSZeroRect;
    NSSize paper = _plan.configuration.paperSize;
    CGFloat x = floor(MAX(kSPDFMarkdownCanvasInset, (NSWidth(self.bounds) - paper.width) * 0.5));
    CGFloat y = [self verticalCanvasInset] + pageIndex * (paper.height + kSPDFMarkdownPageGap);
    return NSMakeRect(x, y, paper.width, paper.height);
}

- (NSInteger)pageIndexAtPoint:(NSPoint)point {
    return SPDFMacMarkdownPageIndexAtPoint(point, self.pageCount, [self frameForPageAtIndex:0],
                                           kSPDFMarkdownPageGap);
}

- (void)resizeForWidth:(CGFloat)width {
    NSSize paper = _plan.configuration.paperSize;
    CGFloat height = [self verticalCanvasInset] * 2.0 + self.pageCount * paper.height +
                     (self.pageCount ? self.pageCount - 1 : 0) * kSPDFMarkdownPageGap;
    self.frame = NSMakeRect(0, 0, MAX(width, paper.width + kSPDFMarkdownCanvasInset * 2.0), height);
}

- (NSInteger)pageIndexForVisibleRect:(NSRect)visibleRect {
    if (!self.pageCount) return -1;
    CGFloat inset = [self verticalCanvasInset];
    NSInteger first = MAX(0, (NSInteger)floor((NSMinY(visibleRect) - inset) /
                                              (_plan.configuration.paperSize.height + kSPDFMarkdownPageGap)));
    NSInteger last = MIN((NSInteger)self.pageCount - 1,
                         (NSInteger)ceil((NSMaxY(visibleRect) - inset) /
                                         (_plan.configuration.paperSize.height + kSPDFMarkdownPageGap)));
    NSInteger best = first;
    CGFloat bestArea = -1.0;
    for (NSInteger page = first; page <= last; ++page) {
        NSRect intersection = NSIntersectionRect(visibleRect, [self frameForPageAtIndex:(NSUInteger)page]);
        CGFloat area = NSWidth(intersection) * NSHeight(intersection);
        if (area > bestArea) {
            bestArea = area;
            best = page;
        }
    }
    return best;
}

- (void)drawRanges:(NSArray<NSValue*>*)ranges
             color:(NSColor*)color
           rounded:(BOOL)rounded
            onPage:(SPDFMarkdownPage*)page
         pageFrame:(NSRect)pageFrame {
    if (!ranges.count) return;
    [color setFill];
    [self enumeratePageLocalRectsForRanges:ranges
                                    onPage:page
                                usingBlock:^(NSRect rect) {
                                  NSRect highlight = NSOffsetRect(rect, NSMinX(pageFrame), NSMinY(pageFrame));
                                  if (rounded)
                                      [[NSBezierPath bezierPathWithRoundedRect:highlight xRadius:2.0
                                                                       yRadius:2.0] fill];
                                  else
                                      NSRectFillUsingOperation(highlight, NSCompositingOperationSourceOver);
                                }];
}

- (void)drawRect:(NSRect)dirtyRect {
    [(self.presentationMode ? NSColor.blackColor : self.viewportBackgroundColor) setFill];
    NSRectFill(dirtyRect);
    if (!self.pageCount) return;
    NSSize paper = _plan.configuration.paperSize;
    CGFloat inset = [self verticalCanvasInset];
    NSInteger first =
        MAX(0, (NSInteger)floor((NSMinY(dirtyRect) - inset) / (paper.height + kSPDFMarkdownPageGap)));
    NSInteger last = MIN((NSInteger)self.pageCount - 1,
                         (NSInteger)ceil((NSMaxY(dirtyRect) - inset) / (paper.height + kSPDFMarkdownPageGap)));
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    for (NSInteger pageIndex = first; pageIndex <= last; ++pageIndex) {
        NSRect pageFrame = [self frameForPageAtIndex:(NSUInteger)pageIndex];
        if (!NSIntersectsRect(pageFrame, dirtyRect)) continue;
        [self drawPaperBackgroundInFrame:pageFrame];
        CGContextSaveGState(context);
        CGContextTranslateCTM(context, NSMinX(pageFrame), NSMaxY(pageFrame));
        CGContextScaleCTM(context, 1, -1);
        [_plan drawPageAtIndex:(NSUInteger)pageIndex attributedString:_attributedString inContext:context];
        CGContextRestoreGState(context);
        [self drawPaperBorderInFrame:pageFrame];
        SPDFMarkdownPage* page = _plan.pages[(NSUInteger)pageIndex];
        // PDF-parity all-matches highlight: same calibrated fill and rounded
        // 2pt shape as SPDFDocumentView's page.highlights pass.
        [self drawRanges:_searchRanges
                   color:[NSColor colorWithCalibratedRed:1.0 green:0.84 blue:0.12 alpha:0.38]
                 rounded:YES
                  onPage:page
               pageFrame:pageFrame];
        if (_selectedRange.length)
            [self drawRanges:@[ [NSValue valueWithRange:_selectedRange] ]
                       color:[NSColor.selectedTextBackgroundColor colorWithAlphaComponent:0.42]
                     rounded:NO
                      onPage:page
                   pageFrame:pageFrame];
        [self drawActiveSearchOnPage:page pageFrame:pageFrame];
        [self drawCodeBoxControlsOnPage:page pageFrame:pageFrame];
    }
}

// The typographic extent of a fragment's line in page-content coordinates
// (its scale applied).
- (CGFloat)contentWidthOfFragment:(SPDFMarkdownPageFragment*)fragment {
    NSAttributedString* lineString = [_attributedString attributedSubstringFromRange:fragment.attributedRange];
    CTLineRef line = SPDFMarkdownCreateFragmentLine(lineString);
    double width = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    CFRelease(line);
    return width * MAX(fragment.scale, 0.001);
}

// Distance from a page-local x to the fragment's horizontal span (0 inside).
- (CGFloat)horizontalDistanceFromX:(CGFloat)localX toFragment:(SPDFMarkdownPageFragment*)fragment {
    CGFloat left = fragment.xOffset;
    CGFloat right = left + [self contentWidthOfFragment:fragment];
    if (localX < left) return left - localX;
    if (localX > right) return localX - right;
    return 0;
}

- (NSUInteger)characterIndexAtPoint:(NSPoint)point {
    NSSize paper = _plan.configuration.paperSize;
    NSInteger pageIndex =
        (NSInteger)floor((point.y - [self verticalCanvasInset]) / (paper.height + kSPDFMarkdownPageGap));
    if (pageIndex < 0 || pageIndex >= (NSInteger)self.pageCount) return NSNotFound;
    NSRect pageFrame = [self frameForPageAtIndex:(NSUInteger)pageIndex];
    if (!NSPointInRect(point, pageFrame)) return NSNotFound;
    NSRect printable = _plan.configuration.printableRect;
    CGFloat localY = point.y - NSMinY(pageFrame) - _plan.configuration.topContentInset;
    CGFloat pageLocalX = point.x - NSMinX(pageFrame) - NSMinX(printable);
    SPDFMarkdownPage* page = _plan.pages[(NSUInteger)pageIndex];
    // Fragments can share a vertical band (wrapped table cells sit side by
    // side within their row), so the hit target is the horizontally nearest
    // text fragment in the band; a band holding only zero-length spacers
    // resolves to the first spacer's location, matching the pre-table-layout
    // behavior for reserved bands.
    SPDFMarkdownPageFragment* best = nil;
    CGFloat bestDistance = CGFLOAT_MAX;
    SPDFMarkdownPageFragment* spacer = nil;
    for (SPDFMarkdownPageFragment* fragment in page.fragments) {
        if (localY < fragment.pageYOffset || localY > fragment.pageYOffset + fragment.height) continue;
        if (NSMaxRange(fragment.attributedRange) > _attributedString.length) continue;
        if (!fragment.attributedRange.length) {
            if (!spacer) spacer = fragment;
            continue;
        }
        CGFloat distance = [self horizontalDistanceFromX:pageLocalX toFragment:fragment];
        if (distance < bestDistance) {
            bestDistance = distance;
            best = fragment;
            if (distance <= 0) break;
        }
    }
    if (!best) return spacer ? spacer.attributedRange.location : NSNotFound;
    NSAttributedString* lineString = [_attributedString attributedSubstringFromRange:best.attributedRange];
    CTLineRef line = SPDFMarkdownCreateFragmentLine(lineString);
    CGFloat localX = (pageLocalX - best.xOffset) / MAX(best.scale, 0.001);
    CFIndex index = CTLineGetStringIndexForPosition(line, CGPointMake(localX, 0));
    CFRelease(line);
    if (index == kCFNotFound) return NSNotFound;
    return MIN(NSMaxRange(best.attributedRange), best.attributedRange.location + (NSUInteger)index);
}

- (NSUInteger)attributedLocationNearestToPoint:(NSPoint)point {
    if (!self.pageCount || !_attributedString.length) return NSNotFound;
    NSSize paper = _plan.configuration.paperSize;
    NSInteger pageIndex =
        (NSInteger)floor((point.y - [self verticalCanvasInset]) / (paper.height + kSPDFMarkdownPageGap));
    pageIndex = MAX(0, MIN(pageIndex, (NSInteger)self.pageCount - 1));
    if (pageIndex + 1 < (NSInteger)self.pageCount) {
        NSRect currentPage = [self frameForPageAtIndex:(NSUInteger)pageIndex];
        NSRect nextPage = [self frameForPageAtIndex:(NSUInteger)pageIndex + 1];
        if (point.y > NSMaxY(currentPage) && fabs(point.y - NSMinY(nextPage)) < fabs(point.y - NSMaxY(currentPage)))
            pageIndex++;
    }

    SPDFMarkdownPageFragment* nearest = nil;
    CGFloat nearestDistance = CGFLOAT_MAX;
    CGFloat nearestHorizontal = CGFLOAT_MAX;
    SPDFMarkdownPage* page = _plan.pages[(NSUInteger)pageIndex];
    NSRect pageFrame = [self frameForPageAtIndex:(NSUInteger)pageIndex];
    NSRect printable = _plan.configuration.printableRect;
    CGFloat pageLocalX = point.x - NSMinX(pageFrame) - NSMinX(printable);
    for (SPDFMarkdownPageFragment* fragment in page.fragments) {
        if (!fragment.attributedRange.length || NSMaxRange(fragment.attributedRange) > _attributedString.length)
            continue;
        CGFloat fragmentY = NSMinY(pageFrame) + _plan.configuration.topContentInset + fragment.pageYOffset;
        CGFloat distance =
            point.y < fragmentY ? fragmentY - point.y : MAX(0.0, point.y - (fragmentY + fragment.height));
        if (distance > nearestDistance + 0.5) continue;
        // Fragments sharing the vertical band (side-by-side table cells) tie
        // vertically; the horizontally nearest one wins.
        CGFloat horizontal = [self horizontalDistanceFromX:pageLocalX toFragment:fragment];
        if (distance < nearestDistance - 0.5 || horizontal < nearestHorizontal) {
            nearest = fragment;
            nearestDistance = MIN(nearestDistance, distance);
            nearestHorizontal = horizontal;
        }
    }
    if (!nearest) return NSNotFound;

    NSAttributedString* lineString = [_attributedString attributedSubstringFromRange:nearest.attributedRange];
    CTLineRef line = SPDFMarkdownCreateFragmentLine(lineString);
    CGFloat localX = (point.x - NSMinX(pageFrame) - NSMinX(printable) - nearest.xOffset) / MAX(nearest.scale, 0.001);
    CFIndex lineIndex = CTLineGetStringIndexForPosition(line, CGPointMake(localX, 0));
    CFRelease(line);
    if (lineIndex == kCFNotFound) lineIndex = localX <= 0.0 ? 0 : (CFIndex)nearest.attributedRange.length;
    return MIN(NSMaxRange(nearest.attributedRange), nearest.attributedRange.location + (NSUInteger)lineIndex);
}

- (NSRange)wordRangeAtIndex:(NSUInteger)index {
    NSString* string = _attributedString.string;
    __block NSRange found = NSMakeRange(index, 0);
    if (index < string.length)
        [string
            enumerateSubstringsInRange:NSMakeRange(0, string.length)
                               options:NSStringEnumerationByWords
                            usingBlock:^(NSString* substring, NSRange substringRange, NSRange enclosing, BOOL* stop) {
                              (void)substring;
                              (void)enclosing;
                              if (NSLocationInRange(index, substringRange)) {
                                  found = substringRange;
                                  *stop = YES;
                              }
                            }];
    if (found.length) return found;
    // Word enumeration skips the attachment character (U+FFFC), so a
    // double-click on an image resolves to exactly its attachment character —
    // checking just before the index too, since CTLine hit-testing returns
    // the caret index (after the character) for a right-half click.
    if (index < string.length && [string characterAtIndex:index] == NSAttachmentCharacter)
        return NSMakeRange(index, 1);
    if (index > 0 && index <= string.length && [string characterAtIndex:index - 1] == NSAttachmentCharacter)
        return NSMakeRange(index - 1, 1);
    return found;
}

- (void)mouseDown:(NSEvent*)event {
    if (!NSApp.active) [NSApp activateIgnoringOtherApps:YES];
    if (!self.window.keyWindow) [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:self];
    if (event.modifierFlags & NSEventModifierFlagControl) {
        [NSMenu popUpContextMenu:[self menuForEvent:event] withEvent:event forView:self];
        return;
    }
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSNumber* copyBlock = [self copyCodeBlockAtPoint:point];
    if (copyBlock) {
        _draggingSelection = NO;
        [self handleCopyCodeBlock:copyBlock.unsignedIntegerValue];
        return;
    }
    NSNumber* languageBlock = [self codeLanguageBlockAtPoint:point];
    if (languageBlock) {
        _draggingSelection = NO;
        if (self.chooseCodeLanguageHandler) self.chooseCodeLanguageHandler(languageBlock.unsignedIntegerValue);
        return;
    }
    NSUInteger index = [self characterIndexAtPoint:point];
    if (index == NSNotFound) {
        self.selectedRange = NSMakeRange(0, 0);
        return;
    }
    _dragAnchor = index;
    _draggingSelection = YES;
    if (event.clickCount >= 3) {
        NSRange line = NSMakeRange(index, 0);
        [_attributedString.string getLineStart:&line.location end:&line.length contentsEnd:NULL forRange:line];
        line.length -= line.location;
        self.selectedRange = line;
        _draggingSelection = NO;
    } else if (event.clickCount == 2) {
        self.selectedRange = [self wordRangeAtIndex:index];
        _draggingSelection = NO;
    } else
        self.selectedRange = NSMakeRange(index, 0);
}

// The tracking-area/mouseMoved: path is the single owner of the pointer
// cursor (see SPDFMacMarkdownPageCanvas+Cursor.mm), same mechanism as the PDF
// document view — cursor rects would fight it, so none are installed.
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_trackingArea) [self removeTrackingArea:_trackingArea];
    // ActiveAlways (matching SPDFDocumentView) so cursor feedback works over
    // unfocused windows; updateCursorForPointInWindow: guards against touching
    // the cursor when another window covers this one.
    _trackingArea = [[NSTrackingArea alloc]
        initWithRect:self.bounds
             options:NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingActiveAlways
               owner:self
            userInfo:nil];
    [self addTrackingArea:_trackingArea];
}

- (void)mouseDragged:(NSEvent*)event {
    if (!_draggingSelection) return;
    NSUInteger index = [self characterIndexAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (index == NSNotFound) return;
    NSUInteger start = MIN(_dragAnchor, index);
    self.selectedRange = NSMakeRange(start, MAX(_dragAnchor, index) - start);
    [self autoscroll:event];
}

- (void)mouseUp:(NSEvent*)event {
    BOOL activateLink = _draggingSelection && _selectedRange.length == 0 && event.clickCount == 1;
    _draggingSelection = NO;
    if (!activateLink) return;
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    // Only a click ON the link text opens it: the nearest-fragment index below
    // reaches across a table row's empty space (see pointIsOnLink:).
    if (![self pointIsOnLink:point]) return;
    NSUInteger index = [self characterIndexAtPoint:point];
    if (index == NSNotFound || index >= _attributedString.length) return;
    NSString* destination = [_attributedString attribute:SPDFMacMarkdownDestinationAttribute
                                                 atIndex:index
                                          effectiveRange:NULL];
    BOOL wiki = NO;
    if (!destination) {
        destination = [_attributedString attribute:SPDFMacMarkdownWikiDestinationAttribute
                                           atIndex:index
                                    effectiveRange:NULL];
        wiki = destination != nil;
    }
    if (destination.length && self.activateDestinationHandler) self.activateDestinationHandler(destination, wiki);
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    // The page paints concrete theme colors, but the canvas gutter
    // (windowBackgroundColor) and the system selection fill are
    // appearance-dynamic and must repaint when the system appearance flips.
    [self setNeedsDisplay:YES];
}

- (void)copy:(id)sender {
    (void)sender;
    if (!_selectedRange.length || NSMaxRange(_selectedRange) > _attributedString.length) {
        NSBeep();
        return;
    }
    if (self.reader) {
        [self.reader copySelection:self];
        return;
    }
    if (![self writeSelectionToPasteboard:NSPasteboard.generalPasteboard plainTextTransform:nil]) NSBeep();
}

- (NSMenu*)menuForEvent:(NSEvent*)event {
    NSMenu* menu = self.reader ? [self.reader contextMenuForDocumentView:self event:event] : [NSMenu new];
    // Right-clicking an image copies that image: the menu's Copy item is
    // retargeted to carry the hit image, so nothing depends on (or disturbs)
    // the current selection.
    [self spdf_retargetCopyItemInMenu:menu
                          forImageAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (!self.reader) {
        NSMenuItem* copy = [[NSMenuItem alloc] initWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@""];
        copy.target = self;
        copy.enabled = _selectedRange.length > 0;
        [menu addItem:copy];
    }
    NSUInteger index = [self characterIndexAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (index != NSNotFound && index < _attributedString.length) {
        NSNumber* kind = [_attributedString attribute:SPDFMarkdownBlockKindAttribute atIndex:index effectiveRange:NULL];
        NSNumber* block = [_attributedString attribute:SPDFMarkdownBlockIndexAttribute
                                               atIndex:index
                                        effectiveRange:NULL];
        if (kind.integerValue == SPDFMarkdownBlockKindCode && block) {
            [menu addItem:NSMenuItem.separatorItem];
            NSMenuItem* language = [[NSMenuItem alloc] initWithTitle:@"Choose Code Language..."
                                                              action:@selector(chooseCodeLanguage:)
                                                       keyEquivalent:@""];
            language.target = self;
            language.representedObject = block;
            [menu addItem:language];
        }
    }
    return menu;
}

- (void)chooseCodeLanguage:(NSMenuItem*)sender {
    NSNumber* block = sender.representedObject;
    if (block && self.chooseCodeLanguageHandler) self.chooseCodeLanguageHandler(block.unsignedIntegerValue);
}

@end
