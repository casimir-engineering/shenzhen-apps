#import "SPDFMacIconGeometry.h"
#import "SPDFMacTabStripViewPrivate.h"
#import "SPDFMacTabTitleDrawing.h"
#import "SPDFMacCollectionTabIdentity.h"
#include <math.h>

@implementation SPDFTabStripView (Drawing)
- (void)drawTabAtIndex:(NSInteger)index
                inRect:(NSRect)tabRect
            attributes:(NSDictionary*)attrs
         dimAttributes:(NSDictionary*)dimAttrs {
    if (index < 0 || index >= (NSInteger)self.tabs.count || NSWidth(tabRect) < 40.0) return;
    (void)dimAttrs;

    BOOL selected = index == self.selectedIndex;
    SPDFDocumentTab* tab = self.tabs[(NSUInteger)index];
    BOOL missing = tab.missingFile;
    BOOL hovered = _hoverTabIndex == index;
    BOOL dark = [[self.effectiveAppearance bestMatchFromAppearancesWithNames:
        @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] isEqualToString:NSAppearanceNameDarkAqua];
    NSColor* accent = spdf_tab_group_accent(tab.group.colorName);
    NSColor* fill = missing ? [NSColor.systemRedColor colorWithAlphaComponent:selected ? 0.36 : 0.22]
        : selected ? spdf_tab_group_selected_fill(tab.group.colorName, dark)
        : [accent colorWithAlphaComponent:hovered ? 0.27 : 0.16];
    [fill setFill];
    [[NSBezierPath bezierPathWithRoundedRect:tabRect xRadius:6 yRadius:6] fill];

    if (SPDFTabIsCollectionCopy(tab)) {
        // Pale provenance is independent of membership: an ordinary Orange
        // group keeps its accent fill, while a moved saved copy keeps this rim.
        [[NSColor colorWithSRGBRed:0.96 green:0.84 blue:0.71 alpha:1] setStroke];
        NSBezierPath* rim = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(tabRect,.75,.75) xRadius:5.25 yRadius:5.25];
        rim.lineWidth = 1.25; [rim stroke];
    }

    NSString* title = [self titleForTabAtIndex:index];
    // Selection is carried by the fill, outline and font weight. Keeping one
    // foreground colour across every title avoids making an inactive document
    // look disabled, especially in the dark appearance.
    NSMutableDictionary* titleAttrs = [attrs mutableCopy];
    if (selected) titleAttrs[NSFontAttributeName] = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    CGFloat leftInset = 6.0;
    CGFloat rightInset = 6.0;

    // Unsaved clipboard captures use the same reserved space as read-only
    // files, with a red dot. The flag is cached on path assignment/restoration.
    BOOL showDot = (tab.unsavedPastedImage || tab.readOnly) && !missing;
    if (showDot) {
        // -rebuildReadOnlyTooltips computes the same rect via kReadOnlyDotLeftInset,
        // so the hover hit-area stays aligned with the drawn dot.
        NSRect dotRect = [self readOnlyDotRectForTabRect:tabRect
                                                diameter:kReadOnlyDotDiameter
                                               leftInset:kReadOnlyDotLeftInset];
        [(tab.unsavedPastedImage ? NSColor.systemRedColor : NSColor.systemOrangeColor) setFill];
        [[NSBezierPath bezierPathWithOvalInRect:dotRect] fill];
        // Reserve space so the (middle-ellipsis) title sits just right of the dot.
        leftInset = kReadOnlyDotLeftInset + kReadOnlyDotDiameter + kReadOnlyDotTitleGap;
    }

    NSRect titleRect = SPDFTabTitleRect(tabRect,leftInset,rightInset,title,titleAttrs);
    [NSGraphicsContext saveGraphicsState];
    NSRectClip(titleRect);
    CGContextRef graphics = NSGraphicsContext.currentContext.CGContext;
    if (hovered) CGContextBeginTransparencyLayer(graphics, NULL);
    SPDFDrawTabTitle(title, titleRect, titleAttrs);
    // The glyph geometry never changes on hover. Fade only the trailing region
    // into this tab's actual fill, then overlay the close control.
    if (hovered) {
        CGContextSetBlendMode(graphics, kCGBlendModeDestinationOut);
        NSRect fade = NSMakeRect(NSMaxX(titleRect)-34,NSMinY(titleRect),16,NSHeight(titleRect));
        CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
        CGFloat components[]={0,0,0,0, 0,0,0,1};
        CGFloat locations[]={0,1};
        CGGradientRef gradient=CGGradientCreateWithColorComponents(space,components,locations,2);
        CGContextDrawLinearGradient(graphics,gradient,CGPointMake(NSMinX(fade),NSMidY(fade)),
            CGPointMake(NSMaxX(fade),NSMidY(fade)),0);
        CGContextSetRGBFillColor(graphics,0,0,0,1);
        CGContextFillRect(graphics,CGRectMake(NSMaxX(titleRect)-18,NSMinY(titleRect),18,NSHeight(titleRect)));
        CGGradientRelease(gradient); CGColorSpaceRelease(space);
        CGContextEndTransparencyLayer(graphics);
    }
    [NSGraphicsContext restoreGraphicsState];
    if (!hovered) return;

    NSRect closeRect = [self closeCircleRectForTabRect:tabRect];
    NSBezierPath* closeCircle = [NSBezierPath bezierPathWithRoundedRect:closeRect xRadius:4 yRadius:4];
    NSColor* closeFill = selected ? [NSColor.labelColor colorWithAlphaComponent:0.13]
                                  : [NSColor.secondaryLabelColor colorWithAlphaComponent:0.13];
    [closeFill setFill];
    if (_hasLastHoverPoint && NSPointInRect(_lastHoverPoint,closeRect)) [closeCircle fill];

    NSColor* closeStroke = selected ? [NSColor.labelColor colorWithAlphaComponent:0.90]
                                    : [NSColor.secondaryLabelColor colorWithAlphaComponent:0.82];
    [closeStroke setStroke];
    NSBezierPath* closeX = [NSBezierPath bezierPath];
    closeX.lineWidth = 1.35;
    [closeX moveToPoint:NSMakePoint(NSMidX(closeRect) - 3.2, NSMidY(closeRect) - 3.2)];
    [closeX lineToPoint:NSMakePoint(NSMidX(closeRect) + 3.2, NSMidY(closeRect) + 3.2)];
    [closeX moveToPoint:NSMakePoint(NSMidX(closeRect) + 3.2, NSMidY(closeRect) - 3.2)];
    [closeX lineToPoint:NSMakePoint(NSMidX(closeRect) - 3.2, NSMidY(closeRect) + 3.2)];
    [closeX stroke];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [[NSColor clearColor] setFill];
    NSRectFill(self.bounds);

    NSParagraphStyle* tabTitleStyle = SPDFTabTitleParagraphStyle();
    NSDictionary* attrs = @{
        NSFontAttributeName : [NSFont systemFontOfSize:12 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName : NSColor.labelColor,
        NSParagraphStyleAttributeName : tabTitleStyle
    };
    // Kept as a separate argument while older callers/tests use the drawing
    // seam; it deliberately has the exact same foreground as attrs.
    NSDictionary* dimAttrs = @{
        NSFontAttributeName : [NSFont systemFontOfSize:12],
        NSForegroundColorAttributeName : NSColor.labelColor,
        NSParagraphStyleAttributeName : tabTitleStyle
    };

    [NSGraphicsContext saveGraphicsState];
    if ([self hasTabGroups]) NSRectClip(NSMakeRect([self leftInset],0,
        [self tabAreaRightWithOverflow:YES]-[self leftInset],NSHeight(self.bounds)));
    BOOL fadeEdges=[self hasTabGroups] && [self groupedHasOverflow];
    CGContextRef graphics=NSGraphicsContext.currentContext.CGContext;
    if (fadeEdges) CGContextBeginTransparencyLayer(graphics,NULL);
    [self drawTabGroups];
    NSInteger draggedIndex = [self isVisuallyReorderingTabs] ? _dragSourceTabIndex : -1;
    for (NSInteger i = 0; i < (NSInteger)self.tabs.count; ++i) {
        if (i == draggedIndex) continue;
        [NSGraphicsContext saveGraphicsState];
        if ([self hasTabGroups]) NSRectClip([self tabViewportRect]);
        [self drawTabAtIndex:i inRect:[self visualRectForTabAtIndex:i] attributes:attrs dimAttributes:dimAttrs];
        [NSGraphicsContext restoreGraphicsState];
    }
    if (draggedIndex >= 0) {
        [self drawTabAtIndex:draggedIndex
                      inRect:[self visualRectForTabAtIndex:draggedIndex]
                  attributes:attrs
               dimAttributes:dimAttrs];
    }

    if (fadeEdges) { [self fadeTabScrollEdges]; CGContextEndTransparencyLayer(graphics); }
    [NSGraphicsContext restoreGraphicsState];
    for (NSNumber* left in @[@YES,@NO]) {
        NSInteger count = [self tabScrollHiddenCountOnLeft:left.boolValue];
        if (count <= 0) continue;
        NSRect indicator = [self tabScrollIndicatorRectOnLeft:left.boolValue];
        [[NSColor.labelColor colorWithAlphaComponent:.07] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:indicator xRadius:6 yRadius:6] fill];
        NSString* label = [NSString stringWithFormat:@"+%ld",(long)count];
        [label drawInRect:NSInsetRect(indicator,1,4) withAttributes:@{
            NSFontAttributeName:[NSFont systemFontOfSize:12],NSForegroundColorAttributeName:NSColor.labelColor,
            NSParagraphStyleAttributeName:SPDFTabTitleParagraphStyle()}];
    }
    NSRect overflowRect = [self overflowRect];
    if (!NSIsEmptyRect(overflowRect)) {
        NSImage* icon = [NSImage imageWithSystemSymbolName:@"square.3.layers.3d" accessibilityDescription:@"All Groups"];
        icon = [icon imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[NSColor.labelColor]]];
        SPDFDrawVectorIcon(icon,NSInsetRect(overflowRect,6,6),YES);
    }

    NSRect plusRect = [self plusRect];

    NSDictionary* plusAttrs = @{
        NSFontAttributeName : [NSFont systemFontOfSize:16 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName : NSColor.labelColor
    };
    NSSize plusSize = [@"+" sizeWithAttributes:plusAttrs];
    [@"+" drawAtPoint:NSMakePoint(floor(NSMidX(plusRect) - plusSize.width / 2.0),
                                  floor(NSMidY(plusRect) - plusSize.height / 2.0))
        withAttributes:plusAttrs];

    [self drawGroupDropPreview];

    // Drop-insertion indicator: a thin rounded systemYellow line, full tab
    // height, centered in the gap where a hovering detached tab would insert.
    // Drawn last as a pure overlay so the existing tabs never shift.
    if (_dropIndicatorSlot >= 0) {
        CGFloat minXs[kMaxVisibleTabGeometry], midXs[kMaxVisibleTabGeometry], maxXs[kMaxVisibleTabGeometry];
        NSInteger arrayIndexes[kMaxVisibleTabGeometry];
        NSInteger visibleCount = [self collectVisibleTabGeometryMinXs:minXs midXs:midXs maxXs:maxXs
                                                         arrayIndexes:arrayIndexes];
        CGFloat centerX = spdf_tab_strip_drop_indicator_center_x(_dropIndicatorSlot, minXs, maxXs, visibleCount,
                                                                 kTabGap);
        if (!isnan(centerX)) {
            NSRect anyTabRect = [self rectForTabAtIndex:arrayIndexes[0]];
            NSRect lineRect = NSMakeRect(floor(centerX) - 1.0, NSMinY(anyTabRect), 2.0, NSHeight(anyTabRect));
            [NSColor.systemYellowColor setFill];
            [[NSBezierPath bezierPathWithRoundedRect:lineRect xRadius:1.0 yRadius:1.0] fill];
        }
    }
}

@end
