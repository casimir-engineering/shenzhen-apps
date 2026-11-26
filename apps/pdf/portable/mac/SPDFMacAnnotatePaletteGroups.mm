// The Annotate palette's groups (SPDFMacAnnotatePaletteGroups.h).
#import "SPDFMacAnnotatePaletteGroups.h"

#import <objc/runtime.h>

#import "SPDFMacAnnotateColors.h"
#import "SPDFMacAnnotateLayersPanel.h"
#import "SPDFMacAnnotatePaletteButton.h"
#import "SPDFMacAnnotatePaletteSupport.h"
#import "SPDFMacAnnotateToolOptions.h"
#import "SPDFMacCollectionStyle.h"
#import "SPDFMacFillController.h"

// Windows Paint's two rows, left to right (§ 2 Colors).
const spdf_paint_color SPDFAnnotatePaletteColors[20] = {
    0x000000FFu, 0x7F7F7FFFu, 0x880015FFu, 0xED1C24FFu, 0xFF7F27FFu,  // black, grey 50 %, dark red, red, orange
    0xFFF200FFu, 0x22B14CFFu, 0x00A2E8FFu, 0x3F48CCFFu, 0xA349A4FFu,  // yellow, green, turquoise, indigo, purple
    0xFFFFFFFFu, 0xC3C3C3FFu, 0xB97A57FFu, 0xFFAEC9FFu, 0xFFC90EFFu,  // white, grey 25 %, brown, rose, gold
    0xEFE4B0FFu, 0xB5E61DFFu, 0x99D9EAFFu, 0x7092BEFFu, 0xC8BFE7FFu,  // light yellow, lime, light turquoise,
                                                                     // blue-grey, lavender
};

// A palette button (SPDFMacAnnotatePaletteButton.h): what it does (an op or a command, SPDFAnnotatePerform),
// or the menu it opens.
@interface NSButton (SPDFAnnotatePalette)
@property(nonatomic, strong) id annotatePayload;
@property(nonatomic, copy) NSMenu* (^annotateMenu)(void);
@end
static char kSPDFPayloadKey, kSPDFMenuKey;
@implementation NSButton (SPDFAnnotatePalette)
- (id)annotatePayload { return objc_getAssociatedObject(self, &kSPDFPayloadKey); }
- (void)setAnnotatePayload:(id)payload { objc_setAssociatedObject(self, &kSPDFPayloadKey, payload, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
- (NSMenu* (^)(void))annotateMenu { return objc_getAssociatedObject(self, &kSPDFMenuKey); }
- (void)setAnnotateMenu:(NSMenu* (^)(void))menu { objc_setAssociatedObject(self, &kSPDFMenuKey, menu, OBJC_ASSOCIATION_COPY_NONATOMIC); }
@end
typedef SPDFPaletteButton SPDFAnnotateButton;

// One group of row 1: its full and compact forms in one container, a line before it, and its menu for "More".
@interface SPDFAnnotateGroup : NSObject
@property(nonatomic, copy) NSString* title;
@property(nonatomic, strong) NSStackView* container;
@property(nonatomic, strong) NSView* line;
@property(nonatomic, strong) NSView* full;
@property(nonatomic, strong, nullable) NSView* compact;
@property(nonatomic, copy) NSMenu* (^menu)(void);
@property(nonatomic) CGFloat fullWidth, compactWidth;
@property(nonatomic) NSInteger form;  // 0 full, 1 compact, 2 in More
@end
@implementation SPDFAnnotateGroup
@end

@implementation SPDFMacAnnotatePaletteGroups {
    __weak SPDFMacFillController* _controller;
    SPDFAnnotateGroup* _selection;
    SPDFAnnotateGroup* _image;
    SPDFAnnotateGroup* _tools;
    SPDFAnnotateGroup* _brushes;
    SPDFAnnotateGroup* _shapes;
    SPDFAnnotateGroup* _colors;
    SPDFAnnotateGroup* _layers;
    NSArray<SPDFAnnotateGroup*>* _groups;
    SPDFAnnotateButton* _more;
    NSView* _moreLine;
    SPDFAnnotateGroup* _chosenGroup;  // the group holding the chosen tool (More shows it while it is in there)
    NSString* _chosenSymbol;
    NSString* _chosenLabel;
    SPDFAnnotateButton* _selectButton;
    SPDFAnnotateButton* _toolsCompact;
    SPDFAnnotateButton* _brushButton;
    SPDFAnnotateButton* _shapeButton;
    SPDFAnnotateButton* _layersButton;
    SPDFAnnotateButton* _colorsMenu;
    NSDictionary<NSString*, SPDFAnnotateButton*>* _toolButtons;
    NSArray<SPDFAnnotateButton*>* _imageButtons;
    SPDFMacAnnotateColorsView* _colorsView;
    SPDFMacAnnotateToolOptions* _options;
    NSString* _lastBrush;
    SPDFAnnotateDocumentKind _kind;
    CGFloat _width;
    NSInteger _collapseStep;
    BOOL _showsRow2;
}

- (instancetype)initWithController:(SPDFMacFillController*)controller {
    self = [super init];
    if (self) {
        _controller = controller;
        _lastBrush = @"brush";
        _enabled = YES;
        [self build];
    }
    return self;
}

#pragma mark - Building

- (SPDFAnnotateButton*)button:(NSString*)symbol label:(NSString*)label payload:(id)payload {
    SPDFAnnotateButton* button = SPDFPaletteIconButton(symbol, label, self, @selector(buttonClicked:));
    button.annotatePayload = payload;
    return button;
}

// A button that opens a menu: an icon (Rotate, Flip) or, with no symbol, the ▾ half of a split button.
- (SPDFAnnotateButton*)menuButton:(NSString*)symbol label:(NSString*)label menu:(NSMenu* (^)(void))menu {
    SPDFAnnotateButton* button = symbol.length ? [self button:symbol label:label payload:nil]
                                               : SPDFPaletteMenuButton(label, self, @selector(buttonClicked:));
    button.annotateMenu = menu;
    return button;
}

// A tool (or the group's icon) and its ▾, joined into one split button.
- (NSStackView*)split:(SPDFAnnotateButton*)main label:(NSString*)label menu:(NSMenu* (^)(void))menu {
    return SPDFPaletteSplit(main, [self menuButton:@"" label:label menu:menu]);
}

- (NSStackView*)stack:(NSArray<NSView*>*)views {
    NSStackView* stack = [NSStackView stackViewWithViews:views];
    stack.spacing = SPDFPaletteSpacing;
    stack.alignment = NSLayoutAttributeCenterY;
    stack.detachesHiddenViews = YES;
    [stack setHuggingPriority:NSLayoutPriorityRequired - 1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    return stack;
}

- (SPDFAnnotateGroup*)group:(NSString*)title full:(NSView*)full compact:(NSView*)compact menu:(NSMenu* (^)(void))menu {
    SPDFAnnotateGroup* group = [SPDFAnnotateGroup new];
    group.title = title;
    group.full = full;
    group.compact = compact;
    group.menu = menu;
    group.line = SPDFPaletteSeparator();
    group.container = [self stack:compact ? @[ group.line, full, compact ] : @[ group.line, full ]];
    compact.hidden = YES;
    return group;
}

- (void)build {
    __weak SPDFMacAnnotatePaletteGroups* weakSelf = self;
    __weak SPDFMacFillController* c = _controller;
    // Selection: the Select tool (pressed again: rectangular, then free-form) and its menu.
    _selectButton = [self button:@"cursorarrow" label:@"Select (S)" payload:nil];
    NSView* selection = [self split:_selectButton label:@"Selection tools and commands"
                               menu:^NSMenu* { return SPDFAnnotateSelectionMenu(c, nil); }];
    _selection = [self group:@"Selection" full:selection compact:nil menu:^NSMenu* { return SPDFAnnotateSelectionMenu(c, nil); }];
    // Image: Crop, Resize and skew, Rotate, Flip, and the rest in its menu.
    _imageButtons = @[
        [self button:@"crop" label:@"Crop" payload:@{@"op" : @"image.crop"}],
        [self button:@"arrow.up.left.and.arrow.down.right" label:@"Resize and skew… (⌥⌘I)" payload:SPDFAnnotateCommandResizeSheet],
        [self menuButton:@"rotate.right" label:@"Rotate" menu:^NSMenu* { return SPDFAnnotateRotateMenu(c, nil, @"auto"); }],
        [self menuButton:@"flip.horizontal" label:@"Flip" menu:^NSMenu* { return SPDFAnnotateFlipMenu(c, nil, @"auto"); }],
    ];
    NSMenu* (^imageMenu)(void) = ^NSMenu* { return SPDFAnnotateImageMenu(c, nil); };
    // The rest of the Image menu behind "…": a ▾ after Flip would read as Flip's own.
    _imageButtons = [_imageButtons arrayByAddingObject:[self menuButton:@"ellipsis.circle" label:@"More image commands"
                                                                   menu:imageMenu]];
    _image = [self group:@"Image" full:[self stack:_imageButtons]
                 compact:[self split:[self menuButton:@"photo" label:@"Image commands" menu:imageMenu] label:@"Image commands" menu:imageMenu]
                    menu:imageMenu];
    // Tools: Pen, Arrow, Pencil, Fill, Text box, Eraser, Color picker, Magnifier.
    NSMutableDictionary* tools = [NSMutableDictionary dictionary];
    NSMutableArray* toolViews = [NSMutableArray array];
    for (SPDFAnnotateEntry* tool in SPDFAnnotateTools()) {
        NSString* tip = SPDFAnnotateToolTip(tool, tool.key);
        SPDFAnnotateButton* b = [self button:tool.symbol label:tip payload:@{@"op" : @"tool.choose", @"tool" : tool.name}];
        b.accessibilityLabel = tool.label;
        tools[tool.name] = b;
        [toolViews addObject:b];
    }
    _toolButtons = tools;
    NSMenu* (^toolsMenu)(void) = ^NSMenu* { return SPDFAnnotateToolsMenu(c, nil); };
    _toolsCompact = [self menuButton:@"pencil.tip" label:@"Tools" menu:toolsMenu];
    _tools = [self group:@"Tools" full:[self stack:toolViews]
                 compact:[self split:_toolsCompact label:@"All tools" menu:toolsMenu]
                    menu:toolsMenu];
    // Brushes and Shapes: the last one used, and the menu of all of them.
    _brushButton = [self button:@"paintbrush.pointed" label:@"Brush (B)" payload:nil];
    _brushes = [self group:@"Brushes" full:[self split:_brushButton label:@"All brushes"
                                                   menu:^NSMenu* { return SPDFAnnotateBrushMenu(c, nil); }]
                   compact:nil menu:^NSMenu* { return SPDFAnnotateBrushMenu(c, nil); }];
    _shapeButton = [self button:@"rectangle" label:@"Shapes (U)" payload:nil];
    _shapes = [self group:@"Shapes" full:[self split:_shapeButton label:@"All shapes"
                                                 menu:^NSMenu* { return SPDFAnnotateShapeMenu(c, nil); }]
                  compact:nil menu:^NSMenu* { return SPDFAnnotateShapeMenu(c, nil); }];
    // Colors: Color 1 / Color 2, the palette and the custom colours; narrow, the swatches and a menu.
    _colorsView = [[SPDFMacAnnotateColorsView alloc] initWithController:_controller];
    _colorsMenu = [self menuButton:@"" label:@"Colors" menu:^NSMenu* { return SPDFAnnotateColorsMenu(c); }];
    _colorsMenu.hidden = YES;
    NSStackView* colors = [self stack:@[ _colorsView, _colorsMenu ]];
    colors.spacing = 0;  // narrow, the ▾ belongs to the swatches
    _colors = [self group:@"Colors" full:colors compact:nil
                     menu:^NSMenu* { return SPDFAnnotateColorsMenu(c); }];
    _layersButton = [self button:@"square.3.layers.3d" label:@"Layers (⇧⌘L)" payload:SPDFAnnotateCommandLayers];
    _layers = [self group:@"Layers" full:_layersButton compact:nil menu:^NSMenu* {
      NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Layers"];
      [menu addItem:SPDFAnnotateItem(@"Layers", @"", 0, SPDFAnnotateCommandLayers, c, nil)];
      return menu;
    }];
    _groups = @[ _selection, _image, _tools, _brushes, _shapes, _colors, _layers ];
    // More: the groups that do not fit. While the chosen tool is in there, it shows that tool's icon, chosen.
    _more = SPDFPaletteTitleButton(@"More", nil, @"More", self, @selector(buttonClicked:));
    _more.annotateMenu = ^NSMenu* { return [weakSelf moreMenu]; };
    _more.trailingChevron = YES;
    _more.hidden = YES;
    _moreLine = SPDFPaletteSeparator();
    _moreLine.hidden = YES;
    _options = [[SPDFMacAnnotateToolOptions alloc] initWithController:_controller];
}

- (NSArray<NSView*>*)row1ForKind:(SPDFAnnotateDocumentKind)kind {
    _kind = kind;
    NSMutableArray* views = [NSMutableArray array];
    for (SPDFAnnotateGroup* group in _groups) [views addObject:group.container];
    [views addObjectsFromArray:@[ _moreLine, _more ]];
    return views;
}

- (NSView*)row2ForSession:(SPDFMacAnnotateSession*)session {
    _showsRow2 = [_options showForSession:session kind:_kind];
    return _options;
}

- (BOOL)showsRow2 { return _showsRow2; }
- (CGFloat)tallestRow2Height { return 28; }

#pragma mark - Narrow windows

// What a group takes in row 1: the spacing before it, its line, the spacing after the line, then its buttons.
static CGFloat SPDFGroupWidth(CGFloat buttons) {
    return SPDFPaletteSpacing + SPDFPaletteSeparatorWidth + SPDFPaletteSpacing + buttons;
}

- (void)measure {
    if (_tools.fullWidth > 0) return;
    for (SPDFAnnotateGroup* group in _groups) {
        group.fullWidth = SPDFGroupWidth(ceil(group.full.fittingSize.width));
        group.compactWidth = group.compact ? SPDFGroupWidth(ceil(group.compact.fittingSize.width)) : group.fullWidth;
    }
    _colors.compactWidth = SPDFGroupWidth(SPDFMacAnnotateColorsCompactWidth + SPDFPaletteChevronWidth);
}

// The first thing in row 1 has no line before it (on a PDF the Fill & Sign group comes first and keeps them all).
- (BOOL)leadingLineShows { return _kind == SPDFAnnotateDocumentPDF; }

- (CGFloat)widthWithForms:(NSArray<NSNumber*>*)forms {
    CGFloat width = 0;
    BOOL more = NO, first = YES;
    for (NSUInteger i = 0; i < _groups.count; ++i) {
        NSInteger form = [forms[i] integerValue];
        if (form == 2) {
            more = YES;
            continue;
        }
        width += form == 1 ? _groups[i].compactWidth : _groups[i].fullWidth;
        if (first && !self.leadingLineShows) width -= SPDFPaletteSeparatorWidth + SPDFPaletteSpacing;
        first = NO;
    }
    // More is as wide as it will be: with the chosen tool's icon when that tool's group is among those in it.
    BOOL chosenInMore = _chosenGroup && [forms[[_groups indexOfObject:_chosenGroup]] integerValue] == 2;
    if (more) width += SPDFGroupWidth([_more contentWidthWithImage:chosenInMore ? SPDFAnnotateSymbol(_chosenSymbol, @"") : nil]) -
                       (first && !self.leadingLineShows ? SPDFPaletteSeparatorWidth + SPDFPaletteSpacing : 0);
    return width;
}

// The groups shrink in this order: Image, Colors and Tools to their icons; then into More: Image, Layers, Shapes,
// Brushes, Colors, Selection, Tools.
- (void)layoutRow1InWidth:(CGFloat)width {
    [self measure];
    NSMutableArray<NSNumber*>* forms = [NSMutableArray array];
    for (NSUInteger i = 0; i < _groups.count; ++i) [forms addObject:@0];
    NSArray* steps = @[ @[ _image, @1 ], @[ _colors, @1 ], @[ _tools, @1 ], @[ _image, @2 ], @[ _layers, @2 ],
                        @[ _shapes, @2 ], @[ _brushes, @2 ], @[ _colors, @2 ], @[ _selection, @2 ], @[ _tools, @2 ] ];
    _collapseStep = 0;
    for (NSArray* step in steps) {
        if ([self widthWithForms:forms] <= width) break;
        forms[[_groups indexOfObject:step[0]]] = step[1];
        _collapseStep += 1;
    }
    _width = [self widthWithForms:forms];
    BOOL more = NO;
    for (NSUInteger i = 0; i < _groups.count; ++i) {
        SPDFAnnotateGroup* group = _groups[i];
        NSInteger form = [forms[i] integerValue];
        more = more || form == 2;
        if (group.form == form) continue;
        group.form = form;
        group.container.hidden = form == 2;
        if (group == _colors) {
            _colorsView.compact = form == 1;
            _colorsMenu.hidden = form != 1;
        } else if (group.compact) {
            group.full.hidden = form == 1;
            group.compact.hidden = form != 1;
        }
    }
    _more.hidden = !more;
    // No line before the first thing shown (a picture has no Fill & Sign group before it).
    BOOL first = !self.leadingLineShows;
    for (SPDFAnnotateGroup* group in _groups) {
        if (group.form == 2) continue;
        group.line.hidden = first;
        first = NO;
    }
    _moreLine.hidden = !more || first;
    [self showChosenInMore];
}

// While the chosen tool's group is in More, More wears that tool's icon and the chosen look, so the tool in use is
// always visible as chosen.
- (void)showChosenInMore {
    BOOL inMore = _chosenGroup && _chosenGroup.form == 2;
    _more.image = inMore ? SPDFAnnotateSymbol(_chosenSymbol, @"") : nil;
    _more.state = inMore ? NSControlStateValueOn : NSControlStateValueOff;
    _more.toolTip = inMore ? [NSString stringWithFormat:@"More (%@ in use)", _chosenLabel] : @"More";
}

- (CGFloat)narrowestWidth { return 60; }
- (CGFloat)currentWidth { return _width; }
- (NSInteger)collapseStep { return _collapseStep; }

- (NSMenu*)moreMenu {
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@"More"];
    for (SPDFAnnotateGroup* group in _groups)
        if (group.form == 2) [menu addItemWithTitle:group.title action:nil keyEquivalent:@""].submenu = group.menu();
    return menu;
}

#pragma mark - Following the session

- (void)updateFromSession:(SPDFMacAnnotateSession*)session progress:(NSString*)progress {
    (void)progress;  // "3 of 12 filled" is the Fill & Sign group's, in the palette
    if (session) _kind = session.kind;  // one palette per window: px on pictures and canvases, pt on PDFs
    NSString* chosen = SPDFAnnotateChosenToolName(session);
    BOOL on = session != nil && _enabled;
    for (NSString* name in _toolButtons) {
        SPDFAnnotateButton* b = _toolButtons[name];
        b.state = [name isEqual:chosen] ? NSControlStateValueOn : NSControlStateValueOff;
        b.enabled = on;
    }
    SPDFAnnotateButton* textBox = _toolButtons[@"text_box"];
    textBox.toolTip = SPDFAnnotateToolTip(SPDFAnnotateEntryNamed(SPDFAnnotateTools(), @"text_box"),
                                          _kind == SPDFAnnotateDocumentPDF ? @"⇧T" : @"T");
    SPDFAnnotateEntry* current = SPDFAnnotateEntryNamed(SPDFAnnotateTools(), chosen);
    _toolsCompact.image = SPDFAnnotateSymbol(current.symbol ?: @"pencil.tip", @"Tools");
    _toolsCompact.state = current ? NSControlStateValueOn : NSControlStateValueOff;
    BOOL selecting = [chosen isEqual:@"select"] || [chosen isEqual:@"rect_select"] || [chosen isEqual:@"freeform_select"];
    _selectButton.state = selecting ? NSControlStateValueOn : NSControlStateValueOff;
    _selectButton.image = SPDFAnnotateSymbol([chosen isEqual:@"rect_select"] ? @"rectangle.dashed"
                                             : [chosen isEqual:@"freeform_select"] ? @"lasso" : @"cursorarrow", @"Select");
    _selectButton.toolTip = [chosen isEqual:@"rect_select"] ? @"Rectangular selection (S)"
                            : [chosen isEqual:@"freeform_select"] ? @"Free-form selection (S)" : @"Select (S)";
    if (SPDFAnnotateBrushIndex(chosen) > 0) _lastBrush = chosen;
    SPDFAnnotateEntry* brush = SPDFAnnotateEntryNamed(SPDFAnnotateBrushes(), _lastBrush);
    _brushButton.image = SPDFAnnotateSymbol(brush.symbol, brush.label);
    _brushButton.toolTip = [NSString stringWithFormat:@"%@ (B)", brush.label];
    _brushButton.state = SPDFAnnotateBrushIndex(chosen) > 0 ? NSControlStateValueOn : NSControlStateValueOff;
    SPDFAnnotateEntry* shape = SPDFAnnotateEntryNamed(SPDFAnnotateShapes(), session.shape ?: SPDFAnnotateToolOptions(@"shape")[@"shape"]);
    _shapeButton.image = SPDFAnnotateSymbol(shape.symbol ?: @"rectangle", shape.label ?: @"Shapes");
    _shapeButton.toolTip = [NSString stringWithFormat:@"%@ (U)", shape.label ?: @"Shapes"];
    _shapeButton.state = [chosen isEqual:@"shape"] ? NSControlStateValueOn : NSControlStateValueOff;
    _layersButton.state = SPDFAnnotateLayersPanelShown(_controller) ? NSControlStateValueOn : NSControlStateValueOff;
    // The group the chosen tool is in, for More.
    _chosenGroup = selecting ? _selection : current ? _tools : SPDFAnnotateBrushIndex(chosen) > 0 ? _brushes
                 : [chosen isEqual:@"shape"] ? _shapes : nil;
    _chosenSymbol = selecting ? ([chosen isEqual:@"rect_select"] ? @"rectangle.dashed" : [chosen isEqual:@"freeform_select"] ? @"lasso" : @"cursorarrow")
                  : current ? current.symbol : SPDFAnnotateBrushIndex(chosen) > 0 ? brush.symbol : shape.symbol ?: @"rectangle";
    _chosenLabel = selecting ? @"Select" : current ? current.label : SPDFAnnotateBrushIndex(chosen) > 0 ? brush.label
                 : shape.label ?: @"Shapes";
    [self showChosenInMore];
    for (SPDFAnnotateButton* b in @[ _selectButton, _brushButton, _shapeButton, _layersButton, _toolsCompact ]) b.enabled = on;
    for (SPDFAnnotateButton* b in _imageButtons) {
        NSString* tip = nil;
        b.enabled = on && (!b.annotatePayload || SPDFAnnotatePayloadEnabled(_controller, b.annotatePayload, &tip));
        b.toolTip = tip ?: b.accessibilityLabel;
    }
    [_colorsView updateFromSession:on ? session : nil];
    [self row2ForSession:session];
    SPDFAnnotateSyncLayersPanel(_controller);
}

#pragma mark - Clicks

- (void)buttonClicked:(SPDFAnnotateButton*)sender {
    SPDFMacFillController* c = _controller;
    SPDFMacAnnotateSession* session = SPDFAnnotateCurrentSession(c, YES);
    NSString* chosen = SPDFAnnotateChosenToolName(session);
    sender.state = NSControlStateValueOff;  // the session says what is chosen (updateFromSession)
    if (sender.annotateMenu) {
        NSMenu* menu = sender.annotateMenu();
        [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(sender.bounds) + 4) inView:sender];
    } else if (sender == _selectButton) {
        // Select, pressed again: Rectangular selection, then Free-form selection.
        NSString* next = [chosen isEqual:@"select"] ? @"rect_select" : [chosen isEqual:@"rect_select"] ? @"freeform_select" : @"select";
        SPDFAnnotateChooseTool(c, next, nil);
    } else if (sender == _brushButton) {
        if (SPDFAnnotateBrushIndex(chosen) > 0) {
            [SPDFAnnotateBrushMenu(c, nil) popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(sender.bounds) + 4)
                                                             inView:sender];
        } else {
            SPDFAnnotateChooseTool(c, _lastBrush, nil);
        }
    } else if (sender == _shapeButton) {
        if ([chosen isEqual:@"shape"])
            [SPDFAnnotateShapeMenu(c, nil) popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(sender.bounds) + 4)
                                                             inView:sender];
        else SPDFAnnotateChooseTool(c, @"shape", nil);
    } else if (sender == _toolButtons[@"eraser"] && [chosen isEqual:@"eraser"]) {
        // The Eraser, pressed again: Whole lines and Pixels in turn.
        BOOL pixels = [SPDFAnnotateToolOptions(@"eraser")[@"eraser"] isEqual:@"pixels"];
        SPDFAnnotateChooseTool(c, @"eraser", @{@"eraser" : pixels ? @"lines" : @"pixels"});
    } else if (sender.annotatePayload) {
        SPDFAnnotatePerform(c, sender.annotatePayload);
    }
    [c refreshChrome];
}

@end
