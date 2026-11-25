// Every tool's settings, remembered in <state>/Annotate/settings.json (SPDFAnnotateSettings, SPDFMacAnnotateSession.h),
// and the palette's UI-state operations: tool.choose (chooses the tool and keeps its options) and the colour
// operations' side in the session and settings (SPDFAnnotateApplyPaletteOperation, SPDFMacAnnotatePaletteSupport.h).
//
// Read the first time Annotate asks for a setting, never at launch; Fill & Sign's <state>/FillSign/drawing.json is
// read into it once (pen colour and width, the eraser's kind and size). Written 0.5 s after the last change, 0600,
// through a temporary file and a rename.
#import "SPDFMacAnnotatePaletteSupport.h"

#import "SPDFMacFillController.h"
#import "SPDFMacFillDrawingStyle.h"
#import "SPDFMacSignatureStore.h"
#import "SPDFMacStateDirectory.h"

#include <sys/stat.h>

static NSString* SPDFAnnotateSettingsPath(void) {
    return [[SPDFMacStateDirectoryPath() stringByAppendingPathComponent:@"Annotate"]
        stringByAppendingPathComponent:@"settings.json"];
}

@implementation SPDFAnnotateSettings {
    NSMutableDictionary<NSString*, NSDictionary*>* _tools;
    NSMutableDictionary* _view;
    NSArray<NSString*>* _custom;
    BOOL _importedFillSign;
}

+ (instancetype)shared {
    static SPDFAnnotateSettings* shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      shared = [SPDFAnnotateSettings new];
      [shared load];
    });
    return shared;
}

- (void)load {
    _tools = [NSMutableDictionary dictionary];
    _view = [@{@"statusbar" : @YES, @"rulers" : @NO, @"gridlines" : @NO, @"layers" : @NO} mutableCopy];
    _custom = @[];
    NSData* data = [NSData dataWithContentsOfFile:SPDFAnnotateSettingsPath()];
    NSDictionary* saved = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    if ([saved isKindOfClass:[NSDictionary class]]) {
        if ([saved[@"tools"] isKindOfClass:[NSDictionary class]])
            for (NSString* tool in saved[@"tools"])
                if ([saved[@"tools"][tool] isKindOfClass:[NSDictionary class]]) _tools[tool] = saved[@"tools"][tool];
        if ([saved[@"view"] isKindOfClass:[NSDictionary class]]) [_view addEntriesFromDictionary:saved[@"view"]];
        if ([saved[@"customColors"] isKindOfClass:[NSArray class]]) _custom = saved[@"customColors"];
        _importedFillSign = [saved[@"importedFillSign"] boolValue];
    }
    if (!_importedFillSign) [self importFillSign];
}

// Fill & Sign's pen colour and width and eraser choice become the Pen's, Arrow's and Eraser's, once.
- (void)importFillSign {
    _importedFillSign = YES;
    NSString* path = [[SPDFMacStateDirectoryPath() stringByAppendingPathComponent:@"FillSign"]
        stringByAppendingPathComponent:@"drawing.json"];
    NSData* data = [NSData dataWithContentsOfFile:path];
    NSDictionary* old = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    if (![old isKindOfClass:[NSDictionary class]]) return;
    NSMutableDictionary* line = [NSMutableDictionary dictionary];
    if ([old[@"color"] isKindOfClass:[NSNumber class]]) {
        NSInteger index = MAX(0, MIN([old[@"color"] integerValue], [SPDFMacFillDrawingStyle colorCount] - 1));
        SPDFFillRGB c = [SPDFMacFillDrawingStyle colorAtIndex:index];
        spdf_paint_color color = ((spdf_paint_color)lround(c.r * 255) << 24) | ((spdf_paint_color)lround(c.g * 255) << 16) |
                                 ((spdf_paint_color)lround(c.b * 255) << 8) | 0xFFu;
        line[@"color"] = SPDFAnnotateHex(color);
    }
    if ([old[@"width"] isKindOfClass:[NSNumber class]]) {
        NSInteger index = MAX(0, MIN([old[@"width"] integerValue], [SPDFMacFillDrawingStyle widthCount] - 1));
        line[@"width"] = @([SPDFMacFillDrawingStyle widthAtIndex:index]);
    }
    if (line.count) {
        _tools[@"pen"] = line;
        _tools[@"arrow"] = line;
    }
    NSMutableDictionary* eraser = [NSMutableDictionary dictionary];
    if ([old[@"eraser"] isKindOfClass:[NSString class]]) eraser[@"eraser"] = [old[@"eraser"] isEqual:@"parts"] ? @"pixels" : @"lines";
    if ([old[@"eraserSize"] isKindOfClass:[NSNumber class]]) {
        NSInteger index = MAX(0, MIN([old[@"eraserSize"] integerValue], [SPDFMacFillDrawingStyle eraserSizeCount] - 1));
        eraser[@"size"] = @([SPDFMacFillDrawingStyle eraserSizeAtIndex:index]);
    }
    if (eraser.count) _tools[@"eraser"] = eraser;
    [self scheduleWrite];
}

- (NSDictionary*)optionsForTool:(NSString*)toolName {
    return _tools[toolName] ?: @{};
}

- (void)setOptions:(NSDictionary*)options forTool:(NSString*)toolName {
    if (!toolName.length || !options.count) return;
    NSMutableDictionary* merged = [_tools[toolName] ?: @{} mutableCopy];
    for (NSString* key in options) {
        id value = options[key];
        if ([value isKindOfClass:[NSDictionary class]] && [merged[key] isKindOfClass:[NSDictionary class]]) {
            NSMutableDictionary* nested = [merged[key] mutableCopy];
            [nested addEntriesFromDictionary:value];
            value = nested;
        }
        merged[key] = value;
    }
    if ([merged isEqual:_tools[toolName]]) return;
    _tools[toolName] = merged;
    [self scheduleWrite];
}

- (BOOL)viewFlag:(NSString*)key { return [_view[key] boolValue]; }
- (void)setViewFlag:(NSString*)key on:(BOOL)on {
    if ([_view[key] boolValue] == on) return;
    _view[key] = @(on);
    [self scheduleWrite];
}

- (BOOL)showsStatusBar { return [self viewFlag:@"statusbar"]; }
- (void)setShowsStatusBar:(BOOL)on { [self setViewFlag:@"statusbar" on:on]; }
- (BOOL)showsRulers { return [self viewFlag:@"rulers"]; }
- (void)setShowsRulers:(BOOL)on { [self setViewFlag:@"rulers" on:on]; }
- (BOOL)showsGridlines { return [self viewFlag:@"gridlines"]; }
- (void)setShowsGridlines:(BOOL)on { [self setViewFlag:@"gridlines" on:on]; }
- (BOOL)showsLayers { return [self viewFlag:@"layers"]; }
- (void)setShowsLayers:(BOOL)on { [self setViewFlag:@"layers" on:on]; }

- (NSArray<NSString*>*)customColors {
    NSMutableArray* slots = [NSMutableArray array];
    for (NSUInteger i = 0; i < 10; ++i)
        [slots addObject:i < _custom.count && [_custom[i] isKindOfClass:[NSString class]] ? _custom[i] : @""];
    return slots;
}

- (void)setCustomColors:(NSArray<NSString*>*)customColors {
    if ([customColors isEqual:self.customColors]) return;
    _custom = [customColors copy] ?: @[];
    [self scheduleWrite];
}

- (void)scheduleWrite {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(write) object:nil];
    [self performSelector:@selector(write) withObject:nil afterDelay:0.5];
}

- (void)write {
    NSDictionary* all = @{@"version" : @1, @"tools" : _tools, @"view" : _view, @"customColors" : self.customColors,
                          @"importedFillSign" : @(_importedFillSign)};
    NSData* data = [NSJSONSerialization dataWithJSONObject:all options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:NULL];
    NSString* path = SPDFAnnotateSettingsPath();
    NSString* temp = [path stringByAppendingString:@".tmp"];
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions : @0700} error:NULL];
    if (![data writeToFile:temp options:0 error:NULL]) return;
    chmod(temp.fileSystemRepresentation, 0600);
    rename(temp.fileSystemRepresentation, path.fileSystemRepresentation);
}

@end

#pragma mark - tool.choose and the colours' side

static BOOL SPDFAnnotateToolFor(NSString* name, SPDFAnnotateTool* tool, NSInteger* brush) {
    NSDictionary* tools = @{
        @"form_text" : @(SPDFAnnotateToolFormText), @"form_mark" : @(SPDFAnnotateToolFormMark),
        @"form_signature" : @(SPDFAnnotateToolFormSignature), @"select" : @(SPDFAnnotateToolSelect),
        @"rect_select" : @(SPDFAnnotateToolRectSelect), @"freeform_select" : @(SPDFAnnotateToolFreeformSelect),
        @"pen" : @(SPDFAnnotateToolPen), @"arrow" : @(SPDFAnnotateToolArrow), @"pencil" : @(SPDFAnnotateToolPencil),
        @"fill" : @(SPDFAnnotateToolFill), @"text_box" : @(SPDFAnnotateToolTextBox), @"eraser" : @(SPDFAnnotateToolEraser),
        @"color_picker" : @(SPDFAnnotateToolColorPicker), @"magnifier" : @(SPDFAnnotateToolMagnifier),
        @"shape" : @(SPDFAnnotateToolShape),
    };
    if (tools[name]) {
        *tool = (SPDFAnnotateTool)[tools[name] integerValue];
        return YES;
    }
    NSInteger index = SPDFAnnotateBrushIndex(name);
    if (index <= 0) return NO;
    *tool = SPDFAnnotateToolBrush;
    *brush = index;
    return YES;
}

// On a PDF, Fill & Sign's own tools stay Fill & Sign's: the overlay keeps every event for them as today.
static void SPDFAnnotateChooseFillTool(SPDFMacFillController* controller, NSString* name, NSDictionary* options) {
    SPDFMacFillDrawingStyle* style = [SPDFMacFillDrawingStyle sharedStyle];
    if ([name isEqual:@"pen"] || [name isEqual:@"arrow"]) {
        spdf_paint_color color;
        if (SPDFAnnotateParseHex(options[@"color"], &color)) {
            SPDFFillRGB rgb = {((color >> 24) & 0xFF) / 255.0f, ((color >> 16) & 0xFF) / 255.0f, ((color >> 8) & 0xFF) / 255.0f};
            NSInteger index = [SPDFMacFillDrawingStyle indexOfColor:rgb];
            if (index >= 0) style.colorIndex = index;
        }
        NSInteger width = [SPDFMacFillDrawingStyle indexOfWidth:[options[@"width"] doubleValue]];
        if (width >= 0) style.widthIndex = width;
        [controller chooseTool:[name isEqual:@"pen"] ? SPDFFillToolPen : SPDFFillToolArrow];
    } else if ([name isEqual:@"eraser"]) {
        style.eraserParts = [options[@"eraser"] isEqual:@"pixels"];
        [controller chooseTool:SPDFFillToolEraser];
    } else if ([name isEqual:@"select"]) {
        [controller chooseTool:SPDFFillToolSelect];
    } else if ([name isEqual:@"form_text"]) {
        [controller chooseTool:SPDFFillToolText];
    } else if ([name isEqual:@"form_mark"]) {
        [controller session].markCross = [options[@"kind"] isEqual:@"cross"];
        [controller chooseTool:SPDFFillToolMark];
    } else if ([name isEqual:@"form_signature"]) {
        SPDFMacSignature* last = [[SPDFMacSignatureStore sharedStore] lastUsedForInitials:[options[@"kind"] isEqual:@"initials"]];
        if (last) [controller pickUpSignature:last];
        else [controller addSignatureWithInitials:[options[@"kind"] isEqual:@"initials"]];
    } else {
        // A canvas tool: what Fill & Sign was doing (a text box, lines waiting) is written first.
        [controller endInteraction];
    }
}

NSDictionary* SPDFAnnotateApplyPaletteOperation(SPDFMacFillController* controller, NSDictionary* op,
                                                SPDFDocumentTab* tab) {
    NSString* name = op[@"op"];
    BOOL active = !tab || tab == [controller.host fillTab];
    SPDFAnnotateDocumentKind kind = active ? SPDFAnnotateCurrentKind(controller) : SPDFAnnotateDocumentNone;
    SPDFMacAnnotateSession* session = active ? SPDFAnnotateCurrentSession(controller, YES)
                                             : [SPDFMacAnnotateSession existingSessionForTab:tab];
    if (!session || kind == SPDFAnnotateDocumentText) return nil;  // the routing answers (needs_pdf, not found)
    SPDFAnnotateSettings* settings = [SPDFAnnotateSettings shared];
    if ([name isEqual:@"colors.set"]) {
        spdf_paint_color c;
        if (SPDFAnnotateParseHex(op[@"color1"], &c)) session.color1 = c;
        if (SPDFAnnotateParseHex(op[@"color2"], &c)) session.color2 = c;
        return nil;  // the canvases keep their colours too (doc.state)
    }
    if ([name isEqual:@"palette.set_custom"]) {
        NSInteger index = [op[@"index"] integerValue];
        spdf_paint_color c;
        if (index >= 0 && index < 10 && SPDFAnnotateParseHex(op[@"color"], &c)) {
            NSMutableArray* slots = [settings.customColors mutableCopy];
            slots[index] = SPDFAnnotateHex(c);
            settings.customColors = slots;
        }
        return nil;
    }
    if ([name isEqual:@"view.set"]) {  // remembered for every window; the canvas view and status bar follow
        if ([op[@"statusbar"] isKindOfClass:[NSNumber class]]) settings.showsStatusBar = [op[@"statusbar"] boolValue];
        if ([op[@"rulers"] isKindOfClass:[NSNumber class]]) settings.showsRulers = [op[@"rulers"] boolValue];
        if ([op[@"gridlines"] isKindOfClass:[NSNumber class]]) settings.showsGridlines = [op[@"gridlines"] boolValue];
        if ([op[@"thumbnail"] isKindOfClass:[NSNumber class]]) [settings setOptions:@{@"thumbnail" : op[@"thumbnail"]} forTool:@"view"];
        return nil;
    }
    if (![name isEqual:@"tool.choose"]) return nil;
    NSString* toolName = op[@"tool"];
    SPDFAnnotateTool tool;
    NSInteger brush = session.brush;
    if (![toolName isKindOfClass:[NSString class]] || !SPDFAnnotateToolFor(toolName, &tool, &brush))
        return @{@"ok" : @NO, @"error" : @"invalid_argument", @"message" : @"There is no tool with that name."};
    if (tool <= SPDFAnnotateToolFormSignature && kind != SPDFAnnotateDocumentPDF)
        return @{@"ok" : @NO, @"error" : @"pdf_only", @"message" : @"Fill & Sign's form tools work on PDFs only."};
    NSDictionary* options = [op[@"options"] isKindOfClass:[NSDictionary class]] ? op[@"options"] : @{};
    [settings setOptions:options forTool:toolName];
    NSDictionary* merged = SPDFAnnotateToolOptions(toolName);
    if (tool == SPDFAnnotateToolColorPicker && session.tool != SPDFAnnotateToolColorPicker)
        session.toolBeforePicker = session.tool;
    session.tool = tool;
    session.brush = brush;
    if (tool == SPDFAnnotateToolShape && [merged[@"shape"] isKindOfClass:[NSString class]]) session.shape = merged[@"shape"];
    if (tool == SPDFAnnotateToolEraser) session.eraserPixels = [merged[@"eraser"] isEqual:@"pixels"];
    if (active && kind == SPDFAnnotateDocumentPDF) SPDFAnnotateChooseFillTool(controller, toolName, merged);
    return @{@"ok" : @YES, @"tool" : toolName, @"options" : merged};
}
