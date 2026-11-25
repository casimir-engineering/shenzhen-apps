// Tool names (tool.choose's) and the choices that carry from one tab to the next (SPDFMacAnnotateSessionPrivate.h):
// the last tool chosen on a picture or canvas, and Color 1 and Color 2, kept with the tools' settings in
// <state>/Annotate/settings.json under "current". Read when a session is made, never at launch.
#import "SPDFMacAnnotateSessionPrivate.h"

#import "SPDFMacAnnotateImageIO.h"

#pragma mark - Tool names

static NSArray<NSString*>* BrushNames(void) {
    // spdf_paint_brush order (core/spdf_paint_internal.h), which is the schema's.
    return @[@"pencil", @"brush", @"calligraphy1", @"calligraphy2", @"airbrush", @"oil", @"crayon", @"marker",
             @"natural_pencil", @"watercolor", @"eraser", @"color_eraser"];
}

static NSArray<NSString*>* ToolNames(void) {
    return @[@"form_text", @"form_mark", @"form_signature", @"select", @"rect_select", @"freeform_select", @"pen",
             @"arrow", @"pencil", @"fill", @"text_box", @"eraser", @"color_picker", @"magnifier", @"brush", @"shape"];
}

NSString* SPDFAnnotateToolName(SPDFAnnotateTool tool, NSInteger brush) {
    if (tool == SPDFAnnotateToolBrush) {
        NSArray* brushes = BrushNames();
        return brush >= 1 && brush <= 9 ? brushes[(NSUInteger)brush] : @"brush";
    }
    NSArray* names = ToolNames();
    return tool >= 0 && tool < (NSInteger)names.count ? names[(NSUInteger)tool] : @"";
}

BOOL SPDFAnnotateToolFromName(NSString* name, SPDFAnnotateTool* tool, NSInteger* brush) {
    if (![name isKindOfClass:NSString.class]) return NO;
    NSUInteger brushIndex = [BrushNames() indexOfObject:name];
    if (brushIndex != NSNotFound && brushIndex >= 1 && brushIndex <= 9) {
        if (tool) *tool = SPDFAnnotateToolBrush;
        if (brush) *brush = (NSInteger)brushIndex;
        return YES;
    }
    NSUInteger index = [ToolNames() indexOfObject:name];
    if (index == NSNotFound) return NO;
    if (tool) *tool = (SPDFAnnotateTool)index;
    if (brush && index == SPDFAnnotateToolBrush) *brush = 1;
    return YES;
}

#pragma mark - The choices that carry over

static NSString* const kCurrent = @"current";

void SPDFAnnotateRememberTool(SPDFAnnotateTool tool, NSInteger brush) {
    // Fill & Sign's own tools are a PDF's; every PDF starts on its Text again.
    if (tool <= SPDFAnnotateToolFormSignature) return;
    NSString* name = SPDFAnnotateToolName(tool, brush);
    SPDFAnnotateSettings* settings = SPDFAnnotateSettings.shared;
    if (name.length && ![[settings optionsForTool:kCurrent][@"tool"] isEqual:name])
        [settings setOptions:@{@"tool": name} forTool:kCurrent];
}

void SPDFAnnotateRememberColors(spdf_paint_color color1, spdf_paint_color color2) {
    NSDictionary* colors = @{@"color1": SPDFAnnotateColorString(color1), @"color2": SPDFAnnotateColorString(color2)};
    SPDFAnnotateSettings* settings = SPDFAnnotateSettings.shared;
    NSDictionary* kept = [settings optionsForTool:kCurrent];
    if (![kept[@"color1"] isEqual:colors[@"color1"]] || ![kept[@"color2"] isEqual:colors[@"color2"]])
        [settings setOptions:colors forTool:kCurrent];
}

void SPDFAnnotateAdoptRememberedChoices(SPDFMacAnnotateSession* session) {
    NSDictionary* kept = [SPDFAnnotateSettings.shared optionsForTool:kCurrent];
    spdf_paint_color color1 = session.color1, color2 = session.color2;
    SPDFAnnotateParseColor(kept[@"color1"], &color1);
    SPDFAnnotateParseColor(kept[@"color2"], &color2);
    session.color1 = color1;
    session.color2 = color2;
    if (session.kind == SPDFAnnotateDocumentPDF) {
        session.tool = SPDFAnnotateToolFormText;  // as Fill & Sign always started: clicking a field fills it
        return;
    }
    SPDFAnnotateTool tool = SPDFAnnotateToolBrush;
    NSInteger brush = 1;
    if (SPDFAnnotateToolFromName(kept[@"tool"], &tool, &brush) && tool > SPDFAnnotateToolFormSignature) {
        session.brush = tool == SPDFAnnotateToolBrush ? brush : session.brush;
        session.tool = tool;
    }
}
