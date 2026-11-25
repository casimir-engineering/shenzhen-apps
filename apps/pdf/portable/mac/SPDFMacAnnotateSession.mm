// Annotate, per tab (SPDFMacAnnotateSession.h): the canvas, the tool state, the operations the canvas route applies
// and the tab's one undo stack. Saving, the kept layers and the settings file are in SPDFMacAnnotateSessionSaving.mm.
#import "SPDFMacAnnotateSessionPrivate.h"

#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>

#import "SPDFMacAnnotateImageIO.h"
#import "SPDFMacAnnotateIntegration.h"
#import "SPDFMacModels.h"
#import "SPDFMacStateDirectory.h"

static char kSPDFAnnotateSessionKey;
NSNotificationName const SPDFAnnotateSessionDidChangeNotification = @"SPDFAnnotateSessionDidChange";

#pragma mark - JSON

NSString* SPDFAnnotateJSONString(id object) {
    if (!object || ![NSJSONSerialization isValidJSONObject:object]) return @"{}";
    NSData* data = [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
}

NSDictionary* SPDFAnnotateErrorAnswer(NSString* code, NSString* message) {
    return @{@"ok": @NO, @"error": code ?: @"failed", @"message": message ?: @"That didn't work."};
}

NSDictionary* SPDFAnnotateParseAnswer(char* answer) {
    NSDictionary* result = nil;
    if (answer) {
        NSData* data = [NSData dataWithBytes:answer length:strlen(answer)];
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if ([parsed isKindOfClass:NSDictionary.class]) result = parsed;
        spdf_paint_free(answer);
    }
    return result ?: SPDFAnnotateErrorAnswer(@"failed", @"The canvas gave no answer.");
}

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

#pragma mark - Backing files of canvas and project tabs

NSString* SPDFAnnotateTabsFolder(void) {
    return [[SPDFMacStateDirectoryPath() stringByAppendingPathComponent:@"Annotate"]
        stringByAppendingPathComponent:@"Tabs"];
}

BOOL SPDFAnnotateIsBackingPath(NSString* path) {
    if (![path.pathExtension.lowercaseString isEqualToString:@"png"]) return NO;
    return [path.stringByDeletingLastPathComponent.stringByStandardizingPath
        isEqualToString:SPDFAnnotateTabsFolder().stringByStandardizingPath];
}

NSString* SPDFAnnotateProjectForBackingPath(NSString* path) {
    if (!SPDFAnnotateIsBackingPath(path)) return nil;
    NSData* data = [NSData dataWithContentsOfFile:[path.stringByDeletingPathExtension stringByAppendingPathExtension:@"json"]];
    NSDictionary* info = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    NSString* project = [info isKindOfClass:NSDictionary.class] ? info[@"project"] : nil;
    return [project isKindOfClass:NSString.class] && project.length ? project : nil;
}

#pragma mark - The session

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation SPDFMacAnnotateSession {
    NSMutableArray<NSNumber*>* _undoPages;  // the tab's steps, oldest first: a page (-1 the picture), or NSNotFound
    NSMutableArray<NSNumber*>* _redoPages;  // for a Fill & Sign step
    NSMutableDictionary<NSNumber*, NSDictionary*>* _states;
    NSMutableDictionary<NSNumber*, NSNumber*>* _stateGenerations;
}

+ (instancetype)existingSessionForTab:(SPDFDocumentTab*)tab {
    return tab ? objc_getAssociatedObject(tab, &kSPDFAnnotateSessionKey) : nil;
}

+ (instancetype)sessionForTab:(SPDFDocumentTab*)tab kind:(SPDFAnnotateDocumentKind)kind path:(NSString*)path {
    SPDFMacAnnotateSession* session = [self existingSessionForTab:tab];
    if (session || !tab) return session;
    session = [SPDFMacAnnotateSession new];
    session.tab = tab;
    session.kind = kind;
    session.path = path;
    objc_setAssociatedObject(tab, &kSPDFAnnotateSessionKey, session, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return session;
}

+ (void)discardSessionForTab:(SPDFDocumentTab*)tab {
    if (tab) objc_setAssociatedObject(tab, &kSPDFAnnotateSessionKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (instancetype)init {
    if ((self = [super init])) {
        _pageCanvases = [NSMutableDictionary dictionary];
        _undoPages = [NSMutableArray array];
        _redoPages = [NSMutableArray array];
        _states = [NSMutableDictionary dictionary];
        _stateGenerations = [NSMutableDictionary dictionary];
        _color1 = 0x000000FFu;
        _color2 = 0xFFFFFFFFu;
        _tool = SPDFAnnotateToolBrush;
        _brush = 1;
        _shape = @"rectangle";
        _eraserPixels = YES;
        _selectedObjects = @[];
        _currentPage = -1;
    }
    return self;
}

- (void)dealloc {
    [_autosaveTimer invalidate];
    spdf_paint_close(_canvas);
    for (NSValue* value in _pageCanvases.allValues) spdf_paint_close((spdf_paint_doc*)value.pointerValue);
}

- (spdf_paint_doc*)canvas {
    return _canvas;
}

- (BOOL)neverSaved {
    return self.kind == SPDFAnnotateDocumentCanvas && !self.projectPath && SPDFAnnotateIsBackingPath(self.path);
}

- (NSString*)paletteCopyNote {
    if (self.kind != SPDFAnnotateDocumentPicture || !self.loaded || self.writesInPlace) return nil;
    return SPDFAnnotateCopyNoteText;
}

- (void)setSelectedObjects:(NSArray<NSNumber*>*)selectedObjects {
    _selectedObjects = [selectedObjects copy] ?: @[];
    [NSNotificationCenter.defaultCenter postNotificationName:SPDFAnnotateSessionDidChangeNotification object:self];
}

#pragma mark Loading

- (BOOL)loadIfNeeded:(NSError**)error {
    if (error) *error = nil;
    if (self.loaded) return YES;
    if (self.kind == SPDFAnnotateDocumentPDF) return (self.loaded = YES);
    if (self.kind != SPDFAnnotateDocumentPicture && self.kind != SPDFAnnotateDocumentCanvas) return NO;
    NSString* path = self.path;
    char err[512] = {0};
    spdf_paint_doc* doc = NULL;
    SPDFAnnotateInstallFontResolver();  // text objects in kept layers are drawn on load
    if (SPDFAnnotateIsBackingPath(path)) self.projectPath = SPDFAnnotateProjectForBackingPath(path);
    if (self.projectPath) {
        doc = spdf_paint_read_project(self.projectPath.fileSystemRepresentation, err, sizeof(err));
        self.format = @"com.intuition.shenzhenpdf.szpaint";
        self.writesInPlace = YES;
    } else if ([path.pathExtension.lowercaseString isEqualToString:@"szpaint"]) {
        self.projectPath = path;
        doc = spdf_paint_read_project(path.fileSystemRepresentation, err, sizeof(err));
        self.format = @"com.intuition.shenzhenpdf.szpaint";
        self.writesInPlace = YES;
    } else {
        doc = [SPDFMacAnnotateSession openSidecarForPath:path];
        SPDFAnnotatePicture* picture = nil;
        NSError* decodeError = nil;
        if (!doc) {
            picture = SPDFAnnotateDecodePicture(path, &decodeError);
            if (picture) {
                spdf_paint_pixels pixels = picture.pixels;
                doc = spdf_paint_open_picture(&pixels, picture.dpi, picture.hasAlpha, err, sizeof(err));
            } else if (decodeError) {
                snprintf(err, sizeof(err), "%s", decodeError.localizedDescription.UTF8String);
            }
        }
        [self readPictureInfo:picture path:path];
    }
    if (!doc) {
        if (error)
            *error = [NSError errorWithDomain:@"ShenzhenPDF.Annotate" code:2 userInfo:@{
                NSLocalizedDescriptionKey: err[0] ? @(err) : @"This picture can't be opened in Annotate."}];
        return NO;
    }
    _canvas = doc;
    self.loaded = YES;
    int width = 0, height = 0;
    spdf_paint_size(doc, &width, &height);
    self.readerPixelSize = NSMakeSize(width, height);
    [self rememberFileStamp];
    // Kept layers may hold a resized canvas: the reader still lays out the file's own pixels.
    double fileWidth = [self.pictureProperties[(NSString*)kCGImagePropertyPixelWidth] doubleValue];
    double fileHeight = [self.pictureProperties[(NSString*)kCGImagePropertyPixelHeight] doubleValue];
    NSInteger orientation = [self.pictureProperties[(NSString*)kCGImagePropertyOrientation] integerValue];
    if (fileWidth > 0 && fileHeight > 0)
        self.readerPixelSize = orientation >= 5 && orientation <= 8 ? NSMakeSize(fileHeight, fileWidth)
                                                                    : NSMakeSize(fileWidth, fileHeight);
    // The core starts at black and white; the tab's colours are the session's.
    char* answer = NULL;
    NSString* colors = SPDFAnnotateJSONString(@{@"op": @"colors.set", @"color1": SPDFAnnotateColorString(self.color1),
                                                @"color2": SPDFAnnotateColorString(self.color2)});
    spdf_paint_apply(doc, colors.UTF8String, &answer);
    spdf_paint_free(answer);
    spdf_rect ignored;
    spdf_paint_take_damage(doc, &ignored);
    return YES;
}

// Format, metadata and whether the file can take the flattened picture back (§ Decisions, Formats that can't be
// written). With the kept layers loaded instead of the pixels, only the header is read.
- (void)readPictureInfo:(SPDFAnnotatePicture*)picture path:(NSString*)path {
    NSString* format = picture.format;
    NSDictionary* properties = picture.properties;
    BOOL writable = picture.writable;
    if (!picture) {
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
        if (source) {
            format = (__bridge NSString*)CGImageSourceGetType(source);
            properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
            NSArray* types = CFBridgingRelease(CGImageDestinationCopyTypeIdentifiers());
            writable = format && [types containsObject:format] && CGImageSourceGetCount(source) <= 1 &&
                       ![format isEqualToString:@"org.webmproject.webp"] &&
                       ![[UTType typeWithIdentifier:format] conformsToType:UTTypeRAWImage];
            CFRelease(source);
        }
    }
    self.format = format ?: @"public.png";
    self.pictureProperties = properties ?: @{};
    BOOL readOnly = self.tab.readOnly || ![NSFileManager.defaultManager isWritableFileAtPath:path];
    self.writesInPlace = writable && (!readOnly || SPDFAnnotateIsBackingPath(path));
}

#pragma mark Canvases

- (spdf_paint_doc*)canvasForPage:(NSInteger)page document:(spdf_document*)pdf create:(BOOL)create {
    if (self.kind != SPDFAnnotateDocumentPDF) return page < 0 ? _canvas : NULL;
    if (page < 0) return NULL;
    spdf_paint_doc* doc = (spdf_paint_doc*)_pageCanvases[@(page)].pointerValue;
    if (doc || !create || !pdf) return doc;
    char err[256];
    doc = spdf_paint_open_pdf_page(pdf, (int)page, err, sizeof(err));
    if (doc) _pageCanvases[@(page)] = [NSValue valueWithPointer:doc];
    return doc;
}

- (NSIndexSet*)openPages {
    NSMutableIndexSet* pages = [NSMutableIndexSet indexSet];
    for (NSNumber* page in _pageCanvases) [pages addIndex:page.unsignedIntegerValue];
    return pages;
}

- (spdf_paint_doc*)docForPage:(NSInteger)page {
    return page < 0 ? _canvas : (spdf_paint_doc*)_pageCanvases[@(page)].pointerValue;
}

#pragma mark Operations

- (NSDictionary*)applyCanvasOperation:(NSDictionary*)op page:(NSInteger)page
                                input:(const spdf_paint_apply_input*)input {
    spdf_paint_doc* doc = [self docForPage:page];
    if (!doc) return SPDFAnnotateErrorAnswer(@"not_found", @"That page isn't open in Annotate.");
    NSMutableDictionary* args = [op mutableCopy];
    [args removeObjectForKey:@"page"];  // the page picked the canvas; page canvases take their own coordinates
    char* answer = NULL;
    spdf_paint_status status = spdf_paint_apply_ex(doc, SPDFAnnotateJSONString(args).UTF8String, input, &answer);
    NSDictionary* result = SPDFAnnotateParseAnswer(answer);
    const spdf_paint_op_info* info = spdf_paint_op_find([op[@"op"] description].UTF8String);
    if (status != SPDF_PAINT_OK || !info) return result;
    if (info->flags & SPDF_PAINT_OP_READ_ONLY) return result;
    // The selection and colours change without a new picture: the kept doc.state is read again whatever the generation.
    [_states removeObjectForKey:@(page)];
    if (info->flags & SPDF_PAINT_OP_UNDOABLE) {
        [_undoPages addObject:@(page)];
        [_redoPages removeAllObjects];
    }
    if ([op[@"op"] isEqual:@"colors.set"]) {
        spdf_paint_color color;
        if (SPDFAnnotateParseColor(op[@"color1"], &color)) _color1 = color;
        if (SPDFAnnotateParseColor(op[@"color2"], &color)) _color2 = color;
    }
    if (page >= 0) self.currentPage = page;
    [self pruneSelectedObjects:doc page:page];
    [self noteChange];
    return result;
}

- (NSDictionary*)readOperation:(NSDictionary*)op page:(NSInteger)page {
    spdf_paint_doc* doc = [self docForPage:page];
    if (!doc) return nil;
    char* answer = NULL;
    spdf_paint_apply(doc, SPDFAnnotateJSONString(op).UTF8String, &answer);
    return SPDFAnnotateParseAnswer(answer);
}

- (NSDictionary*)stateForPage:(NSInteger)page {
    spdf_paint_doc* doc = [self docForPage:page];
    if (!doc) return nil;
    uint64_t generation = spdf_paint_generation(doc);
    NSNumber* key = @(page);
    if (_states[key] && _stateGenerations[key].unsignedLongLongValue == generation) return _states[key];
    NSDictionary* state = [self readOperation:@{@"op": @"doc.state"} page:page];
    if (![state[@"ok"] boolValue]) return nil;
    _states[key] = state;
    _stateGenerations[key] = @(generation);
    return state;
}

// An undo or a delete can take a selected object away: the selection keeps only what is still there.
- (void)pruneSelectedObjects:(spdf_paint_doc*)doc page:(NSInteger)page {
    (void)doc;
    if (!_selectedObjects.count) return;
    NSMutableSet* ids = [NSMutableSet set];
    for (NSDictionary* layer in [self stateForPage:page][@"layers"])
        if ([layer isKindOfClass:NSDictionary.class] && layer[@"id"]) [ids addObject:layer[@"id"]];
    NSMutableArray* kept = [NSMutableArray array];
    for (NSNumber* object in _selectedObjects)
        if ([ids containsObject:object]) [kept addObject:object];
    if (kept.count != _selectedObjects.count) _selectedObjects = kept;
}

- (void)noteChange {
    [NSNotificationCenter.defaultCenter postNotificationName:SPDFAnnotateSessionDidChangeNotification object:self];
    [self scheduleProjectAutosave];
}

#pragma mark History

- (void)recordFillStep {
    [_undoPages addObject:@(NSNotFound)];
    [_redoPages removeAllObjects];
}

- (BOOL)canUndo {
    return _undoPages.count > 0;
}

- (BOOL)canRedo {
    return _redoPages.count > 0;
}

static NSString* ActionName(const char* op) {
    if (!op) return nil;
    NSDictionary* names = @{
        @"paint.stroke": @"Painting", @"paint.fill": @"Fill", @"shape.add": @"Shape", @"text.add": @"Text Box",
        @"picture.add": @"Paste", @"object.move": @"Move", @"object.transform": @"Transform",
        @"object.update": @"Change", @"object.order": @"Depth", @"object.delete": @"Delete",
        @"select.delete": @"Delete", @"select.lift": @"Move Selection", @"canvas.resize": @"Canvas Size",
        @"image.crop": @"Crop", @"image.rotate": @"Rotate", @"image.flip": @"Flip", @"image.resize": @"Resize",
        @"image.skew": @"Skew", @"image.invert": @"Invert Colors", @"image.clear": @"Clear Image",
        @"pen.add": @"Pen Line", @"arrow.add": @"Arrow",
    };
    return names[@(op)] ?: @"Change";
}

- (NSString*)undoActionName {
    NSNumber* last = _undoPages.lastObject;
    if (!last) return nil;
    spdf_paint_doc* doc = last.integerValue == NSNotFound ? NULL : [self docForPage:last.integerValue];
    return doc ? ActionName(spdf_paint_undo_name(doc)) : @"Change";
}

- (NSString*)redoActionName {
    NSNumber* last = _redoPages.lastObject;
    if (!last) return nil;
    spdf_paint_doc* doc = last.integerValue == NSNotFound ? NULL : [self docForPage:last.integerValue];
    return doc ? ActionName(spdf_paint_redo_name(doc)) : @"Change";
}

- (NSDictionary*)step:(NSInteger)steps redo:(BOOL)redo {
    NSMutableArray<NSNumber*>* from = redo ? _redoPages : _undoPages;
    NSMutableArray<NSNumber*>* to = redo ? _undoPages : _redoPages;
    NSInteger done = 0;
    while (done < MAX(1, steps) && from.count) {
        NSNumber* entry = from.lastObject;
        [from removeLastObject];
        if (entry.integerValue == NSNotFound) {
            if (!self.fillStepHandler) continue;
            self.fillStepHandler(redo);
        } else {
            spdf_paint_doc* doc = [self docForPage:entry.integerValue];
            // A step the core dropped under its 1 GB cap is gone from this list too.
            if (!doc || (redo ? spdf_paint_redo(doc, 1) : spdf_paint_undo(doc, 1)) != SPDF_PAINT_OK) continue;
            if (entry.integerValue >= 0) self.currentPage = entry.integerValue;
            [self pruneSelectedObjects:doc page:entry.integerValue];
        }
        [to addObject:entry];
        done++;
    }
    if (!done)
        return SPDFAnnotateErrorAnswer(@"nothing_to_undo", redo ? @"There is nothing to redo." : @"There is nothing to undo.");
    [self noteChange];
    return redo ? @{@"ok": @YES, @"redone": @(done)} : @{@"ok": @YES, @"undone": @(done)};
}

- (NSDictionary*)undo:(NSInteger)steps {
    return [self step:steps redo:NO];
}

- (NSDictionary*)redo:(NSInteger)steps {
    return [self step:steps redo:YES];
}

- (NSDictionary*)repeatableOperation {
    NSNumber* last = _undoPages.lastObject;
    spdf_paint_doc* doc = last && last.integerValue != NSNotFound ? [self docForPage:last.integerValue] : NULL;
    const char* json = doc ? spdf_paint_last_operation(doc) : NULL;
    if (!json) return nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:json length:strlen(json)] options:0
                                                  error:NULL];
    if (![parsed isKindOfClass:NSDictionary.class]) return nil;
    NSMutableDictionary* op = [parsed mutableCopy];
    if (last.integerValue >= 0) op[@"page"] = @(last.integerValue + 1);
    return op;
}

- (BOOL)dirty {
    if (self.kind == SPDFAnnotateDocumentPDF) {
        for (NSValue* value in _pageCanvases.allValues)
            if (spdf_paint_is_dirty((spdf_paint_doc*)value.pointerValue)) return YES;
        return NO;
    }
    return _canvas && (spdf_paint_is_dirty(_canvas) || self.lastWriteFailed);
}

@end
#pragma clang diagnostic pop
