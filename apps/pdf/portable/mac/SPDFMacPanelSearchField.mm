#import "SPDFMacPanelSearchField.h"
@implementation SPDFPanelSearchCell
- (NSRect)searchTextRectForBounds:(NSRect)bounds {
    NSRect rect=[super searchTextRectForBounds:bounds];
    if (!self.stringValue.length) rect.size.width=MAX(0,NSMaxX(bounds)-8-NSMinX(rect));
    return rect;
}
- (NSRect)drawingRectForBounds:(NSRect)bounds {
    // Layer-backed native fields clip their text layer to this rectangle,
    // independently of searchTextRectForBounds:. Keep the empty placeholder's
    // drawing area consistent with the space reclaimed from the clear button.
    return self.stringValue.length ? [super drawingRectForBounds:bounds]
                                   : [self searchTextRectForBounds:bounds];
}
- (void)drawFocusRingMaskWithFrame:(NSRect)frame inView:(NSView*)view {
    (void)view;
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(frame,.5,.5)
        xRadius:NSHeight(frame)/2 yRadius:NSHeight(frame)/2] fill];
}
@end
void SPDFConfigurePanelSearchField(NSSearchField* field) {
    NSString* text=field.stringValue, *placeholder=field.placeholderString;
    field.cell=[[SPDFPanelSearchCell alloc] initTextCell:text ?: @""];
    field.placeholderString=placeholder; field.bordered=YES; field.bezeled=YES;
    field.bezelStyle=NSTextFieldRoundedBezel; field.editable=YES; field.selectable=YES;
    field.font=[NSFont systemFontOfSize:13]; field.textColor=NSColor.labelColor;
    field.focusRingType=NSFocusRingTypeExterior; field.sendsSearchStringImmediately=YES;
    field.cell.usesSingleLineMode=YES; field.cell.scrollable=YES;
    field.cell.wraps=NO; field.cell.lineBreakMode=NSLineBreakByClipping;
}
