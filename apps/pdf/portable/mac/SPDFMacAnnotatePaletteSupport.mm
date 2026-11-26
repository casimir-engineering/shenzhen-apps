// What the Annotate palette, menus and keys share (SPDFMacAnnotatePaletteSupport.h): tables, colours, sending.
// The command items and the menus built from them are in SPDFMacAnnotateCommands.mm.
#import "SPDFMacAnnotatePaletteSupport.h"

#import "SPDFMacAnnotateCanvasView.h"
#import "SPDFMacAnnotateSymbols.h"

#import "SPDFMacAnnotateIntegration.h"
#import "SPDFMacFillController+Annotate.h"
#import "SPDFMacModels.h"

#pragma mark - Colours

NSString* SPDFAnnotateHex(spdf_paint_color c) {
    if ((c & 0xFFu) == 0xFFu) return [NSString stringWithFormat:@"#%06X", (unsigned)(c >> 8)];
    return [NSString stringWithFormat:@"#%08X", (unsigned)c];
}

BOOL SPDFAnnotateParseHex(NSString* hex, spdf_paint_color* color) {
    if (![hex isKindOfClass:[NSString class]] || ![hex hasPrefix:@"#"] || (hex.length != 7 && hex.length != 9)) return NO;
    unsigned value = 0;
    NSScanner* scanner = [NSScanner scannerWithString:[hex substringFromIndex:1]];
    if (![scanner scanHexInt:&value] || !scanner.isAtEnd) return NO;
    if (color) *color = hex.length == 7 ? ((spdf_paint_color)value << 8) | 0xFFu : (spdf_paint_color)value;
    return YES;
}

NSColor* SPDFAnnotateNSColor(spdf_paint_color c) {
    return [NSColor colorWithSRGBRed:((c >> 24) & 0xFF) / 255.0 green:((c >> 16) & 0xFF) / 255.0
                                blue:((c >> 8) & 0xFF) / 255.0 alpha:(c & 0xFF) / 255.0];
}

spdf_paint_color SPDFAnnotateColorFromNSColor(NSColor* color) {
    NSColor* rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace] ?: NSColor.blackColor;
    unsigned r = (unsigned)lround(MIN(1, MAX(0, rgb.redComponent)) * 255);
    unsigned g = (unsigned)lround(MIN(1, MAX(0, rgb.greenComponent)) * 255);
    unsigned b = (unsigned)lround(MIN(1, MAX(0, rgb.blueComponent)) * 255);
    unsigned a = (unsigned)lround(MIN(1, MAX(0, rgb.alphaComponent)) * 255);
    return (spdf_paint_color)((r << 24) | (g << 16) | (b << 8) | a);
}

NSString* SPDFAnnotatePaletteColorName(NSInteger index) {
    static NSArray* names;
    if (!names)
        names = @[ @"Black", @"Grey 50 %", @"Dark red", @"Red", @"Orange", @"Yellow", @"Green", @"Turquoise",
                   @"Indigo", @"Purple", @"White", @"Grey 25 %", @"Brown", @"Rose", @"Gold", @"Light yellow",
                   @"Lime", @"Light turquoise", @"Blue-grey", @"Lavender" ];
    return index >= 0 && index < (NSInteger)names.count ? names[index] : @"";
}

#pragma mark - Tables

@implementation SPDFAnnotateEntry
@end

static NSArray<SPDFAnnotateEntry*>* SPDFAnnotateTable(NSArray<NSArray<NSString*>*>* rows) {
    NSMutableArray* table = [NSMutableArray array];
    for (NSArray<NSString*>* row in rows) {
        SPDFAnnotateEntry* entry = [SPDFAnnotateEntry new];
        entry.name = row[0];
        entry.label = row[1];
        entry.symbol = row.count > 2 ? row[2] : @"";
        entry.key = row.count > 3 ? row[3] : @"";
        entry.hint = row.count > 4 ? row[4] : @"";
        [table addObject:entry];
    }
    return table;
}

NSArray<SPDFAnnotateEntry*>* SPDFAnnotateTools(void) {
    static NSArray* tools;
    if (!tools)
        tools = SPDFAnnotateTable(@[
            @[ @"pen", @"Pen", @"pencil.tip", @"P", @"Draws a line you can move or change later." ],
            @[ @"arrow", @"Arrow", @"arrow.up.right", @"A", @"Drag from the tail to the tip." ],
            @[ @"pencil", @"Pencil", @"pencil", @"N", @"Draws thin, hard-edged lines." ],
            @[ @"fill", @"Fill", @"spdf.paintbucket", @"F", @"Click an area to fill it with Color 1, or a shape to fill the shape. "
                                                             @"Right-click: Color 2." ],
            @[ @"text_box", @"Text box", @"character.textbox", @"⇧T", @"Click or drag a box, then type." ],
            @[ @"eraser", @"Eraser", @"eraser", @"E", @"Drag over what you want to remove." ],
            @[ @"color_picker", @"Color picker", @"eyedropper", @"I", @"Click to take a color as Color 1 (right-click: Color 2)." ],
            @[ @"magnifier", @"Magnifier", @"magnifyingglass", @"Z", @"Click to zoom in, Option-click to zoom out." ]
        ]);
    return tools;
}

NSArray<SPDFAnnotateEntry*>* SPDFAnnotateBrushes(void) {
    static NSArray* brushes;
    if (!brushes)
        brushes = SPDFAnnotateTable(@[
            @[ @"brush", @"Brush", @"paintbrush.pointed" ], @[ @"calligraphy1", @"Calligraphy brush 1", @"pencil.line" ],
            @[ @"calligraphy2", @"Calligraphy brush 2", @"pencil.and.outline" ], @[ @"airbrush", @"Airbrush", @"rays" ],
            @[ @"oil", @"Oil brush", @"paintbrush" ], @[ @"crayon", @"Crayon", @"scribble" ],
            @[ @"marker", @"Marker", @"highlighter" ], @[ @"natural_pencil", @"Natural pencil", @"pencil.and.scribble" ],
            @[ @"watercolor", @"Watercolor brush", @"drop.halffull" ]
        ]);
    return brushes;
}

NSArray<SPDFAnnotateEntry*>* SPDFAnnotateShapes(void) {
    static NSArray* shapes;
    if (!shapes)
        shapes = SPDFAnnotateTable(@[
            @[ @"line", @"Line", @"line.diagonal" ], @[ @"curve", @"Curve", @"scribble" ], @[ @"oval", @"Oval", @"oval" ],
            @[ @"rectangle", @"Rectangle", @"rectangle" ],
            @[ @"rounded_rectangle", @"Rounded rectangle", @"app" ], @[ @"polygon", @"Polygon", @"pentagon" ],
            @[ @"triangle", @"Triangle", @"triangle" ], @[ @"right_triangle", @"Right triangle", @"triangle.righthalf.filled" ],
            @[ @"diamond", @"Diamond", @"diamond" ], @[ @"pentagon", @"Pentagon", @"pentagon" ],
            @[ @"hexagon", @"Hexagon", @"hexagon" ], @[ @"right_arrow", @"Right arrow", @"arrowshape.right" ],
            @[ @"left_arrow", @"Left arrow", @"arrowshape.left" ], @[ @"up_arrow", @"Up arrow", @"arrowshape.up" ],
            @[ @"down_arrow", @"Down arrow", @"arrowshape.down" ], @[ @"star4", @"Four-point star", @"sparkle" ],
            @[ @"star5", @"Five-point star", @"star" ], @[ @"star6", @"Six-point star", @"staroflife" ],
            @[ @"rounded_callout", @"Rounded rectangular callout", @"bubble.left" ],
            @[ @"oval_callout", @"Oval callout", @"bubble.middle.bottom" ],
            @[ @"cloud_callout", @"Cloud callout", @"cloud" ], @[ @"heart", @"Heart", @"heart" ],
            @[ @"lightning", @"Lightning", @"bolt" ], @[ @"arrow_line", @"Arrow line", @"arrow.up.right" ]
        ]);
    return shapes;
}

NSArray<SPDFAnnotateEntry*>* SPDFAnnotateStyles(void) {
    static NSArray* styles;
    if (!styles)
        styles = SPDFAnnotateTable(@[
            @[ @"none", @"None" ], @[ @"solid", @"Solid color" ], @[ @"crayon", @"Crayon" ], @[ @"marker", @"Marker" ],
            @[ @"oil", @"Oil" ], @[ @"natural_pencil", @"Natural pencil" ], @[ @"watercolor", @"Watercolor" ]
        ]);
    return styles;
}

SPDFAnnotateEntry* SPDFAnnotateEntryNamed(NSArray<SPDFAnnotateEntry*>* table, NSString* name) {
    for (SPDFAnnotateEntry* entry in table)
        if ([entry.name isEqual:name]) return entry;
    return nil;
}

NSInteger SPDFAnnotateBrushIndex(NSString* name) {
    NSArray* brushes = SPDFAnnotateBrushes();
    for (NSUInteger i = 0; i < brushes.count; ++i)
        if ([[brushes[i] name] isEqual:name]) return (NSInteger)i + 1;
    return 0;
}

NSString* SPDFAnnotateBrushName(NSInteger index) {
    NSArray* brushes = SPDFAnnotateBrushes();
    return index >= 1 && index <= (NSInteger)brushes.count ? [brushes[index - 1] name] : @"brush";
}

NSImage* SPDFAnnotateSymbol(NSString* symbol, NSString* label) {
    if (!symbol.length) return nil;
    return SPDFAnnotateSymbolImage(symbol, label);
}

NSString* SPDFAnnotateToolTip(SPDFAnnotateEntry* tool, NSString* key) {
    NSString* name = key.length ? [NSString stringWithFormat:@"%@ (%@)", tool.label, key] : tool.label ?: @"";
    return tool.hint.length ? [NSString stringWithFormat:@"%@\n%@", name, tool.hint] : name;
}

#pragma mark - The document and its session

@interface ShenzhenMacDelegate (SPDFAnnotatePaletteReader)
- (SPDFMacFillController*)existingFillController;
@end

static ShenzhenMacDelegate* SPDFAnnotateReaderOf(SPDFMacFillController* controller) {
    id host = controller.host;
    return [host isKindOfClass:[ShenzhenMacDelegate class]] ? host : nil;
}

SPDFAnnotateDocumentKind SPDFAnnotateCurrentKind(SPDFMacFillController* controller) {
    if (!controller) return SPDFAnnotateDocumentNone;
    SPDFDocumentTab* tab = [controller.host fillTab];
    SPDFMacAnnotateSession* session = tab ? [SPDFMacAnnotateSession existingSessionForTab:tab] : nil;
    if (session) return session.kind;
    ShenzhenMacDelegate* reader = SPDFAnnotateReaderOf(controller);
    SPDFAnnotateDocumentKind kind = reader ? [reader annotateActiveDocumentKind] : SPDFAnnotateDocumentNone;
    if (kind != SPDFAnnotateDocumentNone) return kind;
    // Fill & Sign shows only on PDFs: until the integration names every kind, what it shows is a PDF.
    return [controller.host fillDocument] && ![controller.host fillHidden] ? SPDFAnnotateDocumentPDF
                                                                           : SPDFAnnotateDocumentNone;
}

SPDFMacAnnotateSession* SPDFAnnotateCurrentSession(SPDFMacFillController* controller, BOOL create) {
    SPDFDocumentTab* tab = [controller.host fillTab];
    if (!tab) return nil;
    SPDFMacAnnotateSession* session = [controller annotateSessionForTab:tab create:create];
    if (session || !create) return session ?: [SPDFMacAnnotateSession existingSessionForTab:tab];
    SPDFAnnotateDocumentKind kind = SPDFAnnotateCurrentKind(controller);
    if (kind == SPDFAnnotateDocumentNone || kind == SPDFAnnotateDocumentText) return nil;
    return [SPDFMacAnnotateSession sessionForTab:tab kind:kind path:[controller.host fillPath]];
}

NSString* SPDFAnnotateChosenToolName(SPDFMacAnnotateSession* session) {
    if (!session) return @"";
    switch (session.tool) {
        case SPDFAnnotateToolFormText: return @"form_text";
        case SPDFAnnotateToolFormMark: return @"form_mark";
        case SPDFAnnotateToolFormSignature: return @"form_signature";
        case SPDFAnnotateToolSelect: return @"select";
        case SPDFAnnotateToolRectSelect: return @"rect_select";
        case SPDFAnnotateToolFreeformSelect: return @"freeform_select";
        case SPDFAnnotateToolPen: return @"pen";
        case SPDFAnnotateToolArrow: return @"arrow";
        case SPDFAnnotateToolPencil: return @"pencil";
        case SPDFAnnotateToolFill: return @"fill";
        case SPDFAnnotateToolTextBox: return @"text_box";
        case SPDFAnnotateToolEraser: return @"eraser";
        case SPDFAnnotateToolColorPicker: return @"color_picker";
        case SPDFAnnotateToolMagnifier: return @"magnifier";
        case SPDFAnnotateToolBrush: return SPDFAnnotateBrushName(session.brush);
        case SPDFAnnotateToolShape: return @"shape";
    }
    return @"";
}

NSDictionary* SPDFAnnotateToolOptions(NSString* tool) {
    static NSDictionary* defaults;
    if (!defaults) {
        NSDictionary* brush = @{@"size" : @5, @"opacity" : @100};
        NSMutableDictionary* d = [@{
            @"pencil" : @{@"size" : @1, @"opacity" : @100},
            @"eraser" : @{@"size" : @4, @"eraser" : @"lines"},
            @"fill" : @{@"tolerance" : @0, @"contiguous" : @YES},
            @"color_picker" : @{@"from" : @"visible"},
            @"shape" : @{@"shape" : @"rectangle", @"outline" : @{@"style" : @"solid", @"width" : @3},
                         @"fill" : @{@"style" : @"none"}},
            @"text_box" : @{@"font" : @"Helvetica Neue", @"size" : @24, @"bold" : @NO, @"italic" : @NO,
                            @"underline" : @NO, @"strikethrough" : @NO, @"align" : @"left",
                            @"background" : @"transparent"},
            @"pen" : @{@"width" : @2}, @"arrow" : @{@"width" : @2},
            @"rect_select" : @{@"transparent" : @NO}, @"freeform_select" : @{@"transparent" : @NO},
        } mutableCopy];
        for (SPDFAnnotateEntry* entry in SPDFAnnotateBrushes()) d[entry.name] = brush;
        defaults = d;
    }
    NSMutableDictionary* options = [defaults[tool] ?: @{} mutableCopy];
    NSDictionary* saved = [[SPDFAnnotateSettings shared] optionsForTool:tool];
    for (NSString* key in saved) {
        // Nested styles merge so a remembered outline keeps its width when only its style was set.
        if ([options[key] isKindOfClass:[NSDictionary class]] && [saved[key] isKindOfClass:[NSDictionary class]]) {
            NSMutableDictionary* merged = [options[key] mutableCopy];
            [merged addEntriesFromDictionary:saved[key]];
            options[key] = merged;
        } else {
            options[key] = saved[key];
        }
    }
    return options;
}

NSString* SPDFAnnotateUnit(SPDFAnnotateDocumentKind kind) {
    return kind == SPDFAnnotateDocumentPDF ? @"pt" : @"px";
}

#pragma mark - Sending

void SPDFAnnotateSend(SPDFMacFillController* controller, NSDictionary* op, void (^completion)(NSDictionary*)) {
    if (!controller || !op) return;
    __weak SPDFMacFillController* weak = controller;
    // On a PDF every operation that acts on a page names the page in view (Repeat, menus, panels alike).
    [controller applyOperation:SPDFAnnotateOnCurrentPage(controller, op) tab:nil completion:^(NSDictionary* result) {
      if (completion) completion(result);
      [weak refreshChrome];
    }];
}

void SPDFAnnotateChooseTool(SPDFMacFillController* controller, NSString* tool, NSDictionary* options) {
    NSMutableDictionary* op = [@{@"op" : @"tool.choose", @"tool" : tool} mutableCopy];
    if (options.count) op[@"options"] = options;
    SPDFAnnotateSend(controller, op, nil);
}

NSDictionary* SPDFAnnotateOnCurrentPage(SPDFMacFillController* controller, NSDictionary* op) {
    const spdf_paint_op_info* info = spdf_paint_op_find([op[@"op"] UTF8String] ?: "");
    if (!info || !(info->flags & SPDF_PAINT_OP_NEEDS_PAGE) || op[@"page"]) return op;
    if (SPDFAnnotateCurrentKind(controller) != SPDFAnnotateDocumentPDF) return op;
    SPDFMacAnnotateSession* session = SPDFAnnotateCurrentSession(controller, NO);
    SPDFMacAnnotateCanvasView* view = controller.annotateCanvasView;
    NSInteger page = view.session == session && session ? [view pageInView] : MAX(0, session.currentPage);
    NSMutableDictionary* paged = [op mutableCopy];
    paged[@"page"] = @(page + 1);
    return paged;
}

NSDictionary* SPDFAnnotateDocState(SPDFMacFillController* controller) {
    if (!controller || SPDFAnnotateCurrentKind(controller) == SPDFAnnotateDocumentNone) return nil;
    __block NSDictionary* state = nil;
    NSDictionary* op = SPDFAnnotateOnCurrentPage(controller, @{@"op" : @"doc.state"});
    [controller applyOperation:op tab:nil completion:^(NSDictionary* result) {
      if ([result[@"ok"] boolValue]) state = result;
    }];
    return state;
}

NSArray<NSNumber*>* SPDFAnnotateSelectedObjectIds(NSDictionary* state) {
    id selection = state[@"selection"];
    id ids = [selection isKindOfClass:[NSDictionary class]] ? selection[@"objects"] : state[@"selectedObjects"];
    NSMutableArray* found = [NSMutableArray array];
    if ([ids isKindOfClass:[NSArray class]])
        for (id value in ids)
            if ([value isKindOfClass:[NSNumber class]]) [found addObject:value];
    return found;
}

BOOL SPDFAnnotateStateHasPixelSelection(NSDictionary* state) {
    id selection = state[@"selection"];
    if (![selection isKindOfClass:[NSDictionary class]]) return NO;
    id active = selection[@"active"] ?: selection[@"pixels"];
    return [active respondsToSelector:@selector(boolValue)] && [active boolValue];
}
