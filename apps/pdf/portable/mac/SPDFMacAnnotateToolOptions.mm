// The palette's second row for Annotate's tools (SPDFMacAnnotateToolOptions.h).
#import "SPDFMacAnnotateToolOptions.h"

#import "SPDFMacAnnotatePaletteSupport.h"
#import "SPDFMacCollectionStyle.h"
#import "SPDFMacFillController.h"
#import "SPDFMacFillController+Annotate.h"

// A slider with its name and value ("Size  [----]  5 px").
@class SPDFAnnotateValueField;
@interface SPDFAnnotateValueSlider : NSStackView
@property(nonatomic, strong) NSSlider* slider;
@property(nonatomic, strong) SPDFAnnotateValueField* value;
@property(nonatomic, copy) NSString* key;
@property(nonatomic, copy) NSString* unit;
@end
@implementation SPDFAnnotateValueSlider
@end

// The value beside a slider, a field once clicked: the number shows selected, ready to type over.
@interface SPDFAnnotateValueField : NSTextField
@property(nonatomic) BOOL cancelled;  // Escape: the end of editing leaves the value as it was
@property(nonatomic) BOOL focusing;   // the click that started editing: it doesn't place a caret over the selection
@property(nonatomic) double original;  // what Escape goes back to
@end
@implementation SPDFAnnotateValueField
- (BOOL)acceptsFirstMouse:(NSEvent*)event { (void)event; return YES; }
- (BOOL)becomeFirstResponder {
    if (![super becomeFirstResponder]) return NO;
    self.cancelled = NO;
    self.focusing = NSApp.currentEvent.type == NSEventTypeLeftMouseDown;
    NSText* editor = self.currentEditor;
    editor.string = [self.stringValue componentsSeparatedByString:@" "].firstObject ?: @"";
    self.original = editor.string.doubleValue;
    [editor selectAll:nil];
    return YES;
}
- (void)mouseDown:(NSEvent*)event {
    if (self.focusing) {
        self.focusing = NO;
        return;
    }
    [super mouseDown:event];
}
@end

@interface SPDFMacAnnotateToolOptions () <NSTextFieldDelegate>
@end

@implementation SPDFMacAnnotateToolOptions {
    __weak SPDFMacFillController* _controller;
    NSStackView* _row;
    NSString* _tool;
    SPDFAnnotateValueSlider* _size;
    SPDFAnnotateValueSlider* _opacity;
    SPDFAnnotateValueSlider* _tolerance;
    NSSegmentedControl* _eraserKind;
    NSButton* _contiguous;
    NSButton* _transparent;
    NSPopUpButton* _pickFrom;
    NSPopUpButton* _outline;
    NSPopUpButton* _fill;
    NSPopUpButton* _font;
    NSComboBox* _fontSize;
    NSSegmentedControl* _styles;  // bold, italic, underline, strikethrough
    NSSegmentedControl* _align;
    NSPopUpButton* _background;
    NSArray<NSView*>* _all;
}

- (instancetype)initWithController:(SPDFMacFillController*)controller {
    if ((self = [super initWithFrame:NSZeroRect])) {
        _controller = controller;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        [self build];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }

- (SPDFAnnotateValueSlider*)slider:(NSString*)label key:(NSString*)key {
    SPDFAnnotateValueSlider* s = [[SPDFAnnotateValueSlider alloc] initWithFrame:NSZeroRect];
    s.key = key;
    NSTextField* name = SPDFCollectionText(label, 11, NSFontWeightRegular, YES);
    [name setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    s.slider = [NSSlider sliderWithValue:1 minValue:1 maxValue:100 target:self action:@selector(sliderMoved:)];
    s.slider.controlSize = NSControlSizeSmall;
    s.slider.refusesFirstResponder = YES;
    s.slider.toolTip = label;
    s.slider.translatesAutoresizingMaskIntoConstraints = NO;
    // On a narrow window the sliders give up width first (down to 64), then the pop-ups (SPDFOptionsSqueeze).
    NSLayoutConstraint* preferred = [s.slider.widthAnchor constraintEqualToConstant:110];
    preferred.priority = 600;
    preferred.active = YES;
    [s.slider.widthAnchor constraintGreaterThanOrEqualToConstant:64].active = YES;
    s.value = [SPDFAnnotateValueField labelWithString:@""];
    s.value.font = [NSFont systemFontOfSize:11];
    s.value.textColor = SPDFCollectionColor(@"text");
    s.value.editable = YES;  // looks like the label it was until clicked
    s.value.bezeled = NO;
    s.value.drawsBackground = NO;
    s.value.focusRingType = NSFocusRingTypeNone;
    s.value.delegate = self;
    s.value.toolTip = [label stringByAppendingString:@": click to type a value"];
    s.value.translatesAutoresizingMaskIntoConstraints = NO;
    [s.value.widthAnchor constraintEqualToConstant:44].active = YES;
    [s setViews:@[ name, s.slider, s.value ] inGravity:NSStackViewGravityLeading];
    s.spacing = 6;
    [s setHuggingPriority:NSLayoutPriorityRequired - 1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    return s;
}

- (NSPopUpButton*)popUp:(NSArray<NSString*>*)titles tip:(NSString*)tip action:(SEL)action {
    NSPopUpButton* popup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [popup addItemsWithTitles:titles];
    popup.controlSize = NSControlSizeSmall;
    popup.font = [NSFont systemFontOfSize:11];
    popup.target = self;
    popup.action = action;
    popup.toolTip = tip;
    popup.refusesFirstResponder = YES;
    // Narrow, its title is shortened ("Outline: Sol…") rather than anything overlapping or leaving the palette.
    popup.translatesAutoresizingMaskIntoConstraints = NO;
    [popup setContentCompressionResistancePriority:550 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [popup.widthAnchor constraintGreaterThanOrEqualToConstant:48].active = YES;
    return popup;
}

- (void)build {
    _size = [self slider:@"Size" key:@"size"];
    _opacity = [self slider:@"Opacity" key:@"opacity"];
    _opacity.unit = @"%";
    _tolerance = [self slider:@"Tolerance" key:@"tolerance"];
    _tolerance.unit = @"%";
    _tolerance.slider.minValue = 0;
    _eraserKind = [NSSegmentedControl segmentedControlWithLabels:@[ @"Whole lines", @"Pixels" ]
                                                    trackingMode:NSSegmentSwitchTrackingSelectOne target:self
                                                          action:@selector(eraserKindChosen:)];
    [_eraserKind setToolTip:@"Removes every pen line and arrow you touch" forSegment:0];
    [_eraserKind setToolTip:@"Erases what you rub, pixels and pen lines alike" forSegment:1];
    _contiguous = [NSButton checkboxWithTitle:@"Contiguous" target:self action:@selector(contiguousChanged:)];
    _contiguous.toolTip = @"Off: replaces that color everywhere";
    _transparent = [NSButton checkboxWithTitle:@"Transparent selection" target:self action:@selector(transparentChanged:)];
    _transparent.toolTip = @"Pixels in Color 2 stay behind when you move the selection";
    _pickFrom = [self popUp:@[ @"Pick from all layers", @"Pick from the active layer" ] tip:@"Where the color is read"
                     action:@selector(pickFromChosen:)];
    NSMutableArray* outline = [NSMutableArray array], *fill = [NSMutableArray array];
    for (SPDFAnnotateEntry* style in SPDFAnnotateStyles()) {
        BOOL none = [style.name isEqual:@"none"];
        [outline addObject:none ? @"No outline" : [@"Outline: " stringByAppendingString:style.label]];
        [fill addObject:none ? @"No fill" : [@"Fill: " stringByAppendingString:style.label]];
    }
    _outline = [self popUp:outline tip:@"Outline, in Color 1" action:@selector(styleChosen:)];
    _fill = [self popUp:fill tip:@"Fill, in Color 2" action:@selector(styleChosen:)];
    _font = [self popUp:@[] tip:@"Font" action:@selector(fontChosen:)];
    _fontSize = [[NSComboBox alloc] initWithFrame:NSZeroRect];
    [_fontSize addItemsWithObjectValues:@[ @8, @10, @12, @14, @18, @24, @36, @48, @72, @96, @144, @200, @400 ]];
    _fontSize.controlSize = NSControlSizeSmall;
    _fontSize.font = [NSFont systemFontOfSize:11];
    _fontSize.target = self;
    _fontSize.action = @selector(fontSizeChosen:);
    _fontSize.toolTip = @"Text size (8–400 pt)";
    _fontSize.translatesAutoresizingMaskIntoConstraints = NO;
    [_fontSize.widthAnchor constraintEqualToConstant:52].active = YES;
    _styles = [NSSegmentedControl segmentedControlWithImages:@[
        SPDFAnnotateSymbol(@"bold", @"Bold") ?: [NSImage new], SPDFAnnotateSymbol(@"italic", @"Italic") ?: [NSImage new],
        SPDFAnnotateSymbol(@"underline", @"Underline") ?: [NSImage new],
        SPDFAnnotateSymbol(@"strikethrough", @"Strikethrough") ?: [NSImage new]
    ] trackingMode:NSSegmentSwitchTrackingSelectAny target:self action:@selector(textStyleChosen:)];
    NSArray* styleTips = @[ @"Bold (⌘B)", @"Italic (⌘I)", @"Underline (⌘U)", @"Strikethrough" ];
    for (NSInteger i = 0; i < 4; ++i) [_styles setToolTip:styleTips[i] forSegment:i];
    _align = [NSSegmentedControl segmentedControlWithImages:@[
        SPDFAnnotateSymbol(@"text.alignleft", @"Align left") ?: [NSImage new],
        SPDFAnnotateSymbol(@"text.aligncenter", @"Center") ?: [NSImage new],
        SPDFAnnotateSymbol(@"text.alignright", @"Align right") ?: [NSImage new]
    ] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(alignChosen:)];
    [_align setToolTip:@"Align left" forSegment:0];
    [_align setToolTip:@"Center" forSegment:1];
    [_align setToolTip:@"Align right" forSegment:2];
    _background = [self popUp:@[ @"Transparent background", @"Opaque background (Color 2)" ] tip:@"Behind the text"
                       action:@selector(backgroundChosen:)];
    // Narrow, the background's long title gives way before the font's name does.
    [_background setContentCompressionResistancePriority:500 forOrientation:NSLayoutConstraintOrientationHorizontal];
    for (NSControl* c in @[ _eraserKind, _contiguous, _transparent, _styles, _align ]) {
        c.controlSize = NSControlSizeSmall;
        c.font = [NSFont systemFontOfSize:11];
        c.refusesFirstResponder = YES;
        // Buttons and segments keep their size; the pop-ups and sliders are what narrows.
        [c setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    }
    _all = @[ _eraserKind, _size, _opacity, _tolerance, _contiguous, _pickFrom, _outline, _fill, _font, _fontSize, _styles,
              _align, _background, _transparent ];
    _row = [NSStackView stackViewWithViews:_all];
    _row.spacing = 8;  // the text bar fits the narrowest window beside the sidebar
    _row.detachesHiddenViews = YES;
    _row.alignment = NSLayoutAttributeCenterY;
    _row.translatesAutoresizingMaskIntoConstraints = NO;
    // As wide as the options it shows, starting under the first tool, never spread across a wider palette.
    [_row setHuggingPriority:NSLayoutPriorityRequired - 1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self addSubview:_row];
    [NSLayoutConstraint activateConstraints:@[
        [_row.leadingAnchor constraintEqualToAnchor:self.leadingAnchor], [_row.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_row.centerYAnchor constraintEqualToAnchor:self.centerYAnchor], [self.heightAnchor constraintEqualToConstant:28],
    ]];
}

#pragma mark - Showing a tool's options

static NSArray* SPDFSizeRange(NSString* tool) {
    if ([tool isEqual:@"pencil"]) return @[ @1, @20 ];
    if ([tool isEqual:@"eraser"]) return @[ @4, @100 ];
    if ([tool isEqual:@"shape"]) return @[ @1, @50 ];
    if ([tool isEqual:@"pen"] || [tool isEqual:@"arrow"]) return @[ @0.5, @20 ];
    return @[ @1, @100 ];  // brushes
}

- (void)setSlider:(SPDFAnnotateValueSlider*)s value:(double)value {
    s.slider.doubleValue = value;
    s.value.stringValue = [NSString stringWithFormat:value < 10 && fmod(value, 1) ? @"%.1f %@" : @"%.0f %@", value, s.unit ?: @""];
}

- (BOOL)showForSession:(SPDFMacAnnotateSession*)session kind:(SPDFAnnotateDocumentKind)kind {
    NSString* tool = SPDFAnnotateChosenToolName(session);
    _tool = tool;
    NSDictionary* o = SPDFAnnotateToolOptions(tool);
    BOOL brush = SPDFAnnotateBrushIndex(tool) > 0, pencil = [tool isEqual:@"pencil"];
    BOOL eraser = [tool isEqual:@"eraser"], shape = [tool isEqual:@"shape"], text = [tool isEqual:@"text_box"];
    BOOL line = [tool isEqual:@"pen"] || [tool isEqual:@"arrow"];
    BOOL pixels = [o[@"eraser"] isEqual:@"pixels"];
    NSSet* shown = [NSMutableSet set];
    NSMutableSet* show = (NSMutableSet*)shown;
    if (brush || pencil || line || shape || (eraser && pixels)) [show addObject:_size];
    if (brush || pencil) [show addObject:_opacity];
    if (eraser) [show addObject:_eraserKind];
    if ([tool isEqual:@"fill"]) [show addObjectsFromArray:@[ _tolerance, _contiguous ]];
    if ([tool isEqual:@"color_picker"]) [show addObject:_pickFrom];
    if (shape) [show addObjectsFromArray:@[ _outline, _fill ]];
    if (text) [show addObjectsFromArray:@[ _font, _fontSize, _styles, _align, _background ]];
    if ([tool isEqual:@"rect_select"] || [tool isEqual:@"freeform_select"]) [show addObject:_transparent];
    for (NSView* v in _all) v.hidden = ![shown containsObject:v];
    if (!shown.count) return NO;
    NSArray* range = SPDFSizeRange(tool);
    _size.unit = SPDFAnnotateUnit(kind);
    _size.slider.minValue = [range[0] doubleValue];
    _size.slider.maxValue = [range[1] doubleValue];
    double size = shape ? [o[@"outline"][@"width"] doubleValue] : line ? [o[@"width"] doubleValue] : [o[@"size"] doubleValue];
    [self setSlider:_size value:size];
    [self setSlider:_opacity value:[o[@"opacity"] doubleValue]];
    [self setSlider:_tolerance value:[o[@"tolerance"] doubleValue]];
    _eraserKind.selectedSegment = pixels ? 1 : 0;
    _contiguous.state = [o[@"contiguous"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    _transparent.state = [o[@"transparent"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    [_pickFrom selectItemAtIndex:[o[@"from"] isEqual:@"layer"] ? 1 : 0];
    NSArray* styles = SPDFAnnotateStyles();
    for (NSPopUpButton* popup in @[ _outline, _fill ]) {
        NSString* style = o[popup == _outline ? @"outline" : @"fill"][@"style"];
        SPDFAnnotateEntry* entry = SPDFAnnotateEntryNamed(styles, style);
        [popup selectItemAtIndex:entry ? (NSInteger)[styles indexOfObject:entry] : 0];
    }
    if (text) [self showText:o];
    return YES;
}

- (void)showText:(NSDictionary*)o {
    if (_font.numberOfItems == 0) {  // the font list is read the first time the Text box is chosen
        NSArray* families = [NSFontManager.sharedFontManager.availableFontFamilies
            sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        [_font addItemsWithTitles:families];
        [_font.widthAnchor constraintLessThanOrEqualToConstant:150].active = YES;
    }
    if (![_font itemWithTitle:o[@"font"]]) [_font addItemWithTitle:o[@"font"] ?: @"Helvetica Neue"];
    [_font selectItemWithTitle:o[@"font"] ?: @"Helvetica Neue"];
    _fontSize.stringValue = [NSString stringWithFormat:@"%g", [o[@"size"] doubleValue]];
    NSArray* keys = @[ @"bold", @"italic", @"underline", @"strikethrough" ];
    for (NSInteger i = 0; i < 4; ++i) [_styles setSelected:[o[keys[i]] boolValue] forSegment:i];
    _align.selectedSegment = [o[@"align"] isEqual:@"center"] ? 1 : [o[@"align"] isEqual:@"right"] ? 2 : 0;
    [_background selectItemAtIndex:[o[@"background"] isEqual:@"transparent"] || !o[@"background"] ? 0 : 1];
}

#pragma mark - Changes

// tool.choose with the changed option, and object.update on the selected shape or text box.
- (void)setOptions:(NSDictionary*)options {
    SPDFMacFillController* controller = _controller;
    NSString* tool = _tool;
    if (!tool.length) return;
    SPDFAnnotateChooseTool(controller, tool, options);
    if (![tool isEqual:@"shape"] && ![tool isEqual:@"text_box"]) return;
    NSDictionary* state = SPDFAnnotateDocState(controller);
    NSArray* selected = SPDFAnnotateSelectedObjectIds(state);
    if (selected.count != 1) return;
    NSString* kind = nil;
    for (NSDictionary* layer in [state[@"layers"] isKindOfClass:[NSArray class]] ? state[@"layers"] : @[])
        if ([layer isKindOfClass:[NSDictionary class]] && [layer[@"id"] isEqual:selected[0]])
            kind = [layer[@"object"] isKindOfClass:[NSDictionary class]] ? layer[@"object"][@"kind"] : layer[@"kind"];
    BOOL matches = [tool isEqual:@"text_box"] ? [kind isEqual:@"text"] : kind && ![kind isEqual:@"text"];
    if (!matches) return;
    NSMutableDictionary* update = [options mutableCopy];
    [update removeObjectForKey:@"shape"];
    if (!update.count) return;
    update[@"op"] = @"object.update";
    update[@"id"] = selected[0];
    SPDFAnnotateSend(controller, SPDFAnnotateOnCurrentPage(controller, update), nil);
}

static SPDFAnnotateValueSlider* SPDFSliderOf(NSView* view) {
    while (view && ![view isKindOfClass:[SPDFAnnotateValueSlider class]]) view = view.superview;
    return (SPDFAnnotateValueSlider*)view;
}

- (void)sliderMoved:(NSSlider*)sender {
    if (NSApp.currentEvent.type == NSEventTypeLeftMouseDragged) {  // the value follows; the tool gets it once let go
        [self setSlider:SPDFSliderOf(sender) value:[self roundedValue:sender.doubleValue]];
        return;
    }
    [self apply:sender.doubleValue to:SPDFSliderOf(sender)];
}

- (double)roundedValue:(double)value {
    return value < 2 && [_tool isEqual:@"pen"] ? round(value * 2) / 2 : round(value);
}

// A value typed or stepped in a slider's field: kept within the slider's range, then shown and used as a slid one.
- (void)apply:(double)value to:(SPDFAnnotateValueSlider*)s {
    if (!s) return;
    value = [self roundedValue:MAX(s.slider.minValue, MIN(s.slider.maxValue, value))];
    [self setSlider:s value:value];
    if (s == _size && [_tool isEqual:@"shape"]) [self setOptions:@{@"outline" : @{@"width" : @(value)}}];
    else if (s == _size && ([_tool isEqual:@"pen"] || [_tool isEqual:@"arrow"])) [self setOptions:@{@"width" : @(value)}];
    else [self setOptions:@{s.key : @(value)}];
}

- (void)eraserKindChosen:(NSSegmentedControl*)sender {
    [self setOptions:@{@"eraser" : sender.selectedSegment == 1 ? @"pixels" : @"lines"}];
}

- (void)contiguousChanged:(NSButton*)sender {
    [self setOptions:@{@"contiguous" : @(sender.state == NSControlStateValueOn)}];
}

- (void)transparentChanged:(NSButton*)sender {
    (void)sender;
    SPDFAnnotatePerform(_controller, SPDFAnnotateCommandTransparent);
}

- (void)pickFromChosen:(NSPopUpButton*)sender {
    [self setOptions:@{@"from" : sender.indexOfSelectedItem == 1 ? @"layer" : @"visible"}];
}

- (void)styleChosen:(NSPopUpButton*)sender {
    NSArray* styles = SPDFAnnotateStyles();
    NSInteger index = sender.indexOfSelectedItem;
    if (index < 0 || index >= (NSInteger)styles.count) return;
    [self setOptions:@{sender == _outline ? @"outline" : @"fill" : @{@"style" : [styles[index] name]}}];
}

- (void)fontChosen:(NSPopUpButton*)sender {
    if (sender.titleOfSelectedItem) [self setOptions:@{@"font" : sender.titleOfSelectedItem}];
}

- (void)fontSizeChosen:(NSComboBox*)sender {
    double size = MIN(400, MAX(8, sender.doubleValue));
    sender.stringValue = [NSString stringWithFormat:@"%g", size];
    [self setOptions:@{@"size" : @(size)}];
}

- (void)textStyleChosen:(NSSegmentedControl*)sender {
    NSArray* keys = @[ @"bold", @"italic", @"underline", @"strikethrough" ];
    NSInteger i = sender.selectedSegment;
    if (i >= 0 && i < 4) [self setOptions:@{keys[i] : @([sender isSelectedForSegment:i])}];
}

- (void)alignChosen:(NSSegmentedControl*)sender {
    [self setOptions:@{@"align" : @[ @"left", @"center", @"right" ][MAX(0, MIN(2, sender.selectedSegment))]}];
}

- (void)backgroundChosen:(NSPopUpButton*)sender {
    SPDFMacAnnotateSession* session = SPDFAnnotateCurrentSession(_controller, NO);
    NSString* background = sender.indexOfSelectedItem == 1 ? SPDFAnnotateHex(session ? session.color2 : 0xFFFFFFFFu)
                                                           : @"transparent";
    [self setOptions:@{@"background" : background}];
}

#pragma mark - Typing a value

- (BOOL)control:(NSControl*)control textView:(NSTextView*)textView doCommandBySelector:(SEL)command {
    SPDFAnnotateValueSlider* s = SPDFSliderOf(control);
    if (!s || control != s.value) return NO;
    double step = command == @selector(moveUp:) ? 1 : command == @selector(moveDown:) ? -1
                : command == @selector(moveUpAndModifySelection:) ? 10 : command == @selector(moveDownAndModifySelection:) ? -10 : 0;
    if (step) {  // the slider follows at once; the tool gets the value when the editing ends (using it ends the editing)
        [self setSlider:s value:[self roundedValue:MAX(s.slider.minValue, MIN(s.slider.maxValue, textView.string.doubleValue + step))]];
        textView.string = [s.value.stringValue componentsSeparatedByString:@" "].firstObject ?: @"";
        [textView selectAll:nil];
        return YES;
    }
    if (command == @selector(cancelOperation:)) s.value.cancelled = YES;
    if (command != @selector(cancelOperation:) && command != @selector(insertNewline:)) return NO;
    // Return or Escape: back to the canvas, so the tools' keys work again; ending the editing applies or restores.
    NSView* canvas = (NSView*)_controller.annotateCanvasView;
    [control.window makeFirstResponder:canvas.window == control.window ? canvas : nil];
    return YES;
}

- (void)controlTextDidEndEditing:(NSNotification*)note {
    SPDFAnnotateValueField* field = note.object;
    SPDFAnnotateValueSlider* s = SPDFSliderOf(field);
    if (!s || field != s.value) return;
    NSScanner* scanner = [NSScanner scannerWithString:field.stringValue];
    double typed = 0;
    if (field.cancelled || ![scanner scanDouble:&typed]) [self setSlider:s value:field.original];
    else [self apply:typed to:s];
    field.cancelled = NO;
}

@end
