// The operations the frontend carries out (route "frontend" in the operation table, docs/plans/annotate.md § 6):
// history across the tab, saving, the clipboard, the mode, the view and the tool; and the inputs the core can't work
// out itself (a picture to decode, Vision's subject mask). Mac UI A.
#import "SPDFMacAnnotateOperations.h"
#import "SPDFMacAnnotateAgents.h"
#import "SPDFMacFillController+AnnotatePDF.h"

#import <Vision/Vision.h>

#import "SPDFMacAnnotateCanvasView.h"
#import "SPDFMacAnnotateColors.h"
#import "SPDFMacAnnotateImageIO.h"
#import "SPDFMacAnnotateIntegration.h"
#import "SPDFMacAnnotateSessionPrivate.h"
#import "SPDFMacFillControllerPrivate.h"
#import "SPDFMacModels.h"

static NSDictionary* OK(NSDictionary* extra) {
    NSMutableDictionary* answer = [@{@"ok": @YES} mutableCopy];
    [answer addEntriesFromDictionary:extra ?: @{}];
    return answer;
}

static NSDictionary* Failure(NSError* error, NSString* code) {
    return SPDFAnnotateErrorAnswer(code, error.localizedDescription ?: @"That didn't work.");
}

// The selected object's or the selection's box, or the whole canvas, as doc.copy and remove_background's scope.
static spdf_rect ScopeRegion(SPDFMacAnnotateSession* session, NSInteger page, NSString* scope, spdf_paint_id* object) {
    spdf_rect none = {0, 0, 0, 0};
    *object = 0;
    NSDictionary* state = [session stateForPage:page];
    NSDictionary* selection = [state[@"selection"] isKindOfClass:NSDictionary.class] ? state[@"selection"] : nil;
    NSDictionary* bounds = [selection[@"bounds"] isKindOfClass:NSDictionary.class] ? selection[@"bounds"] : nil;
    BOOL wantsObject = [scope isEqual:@"object"] || ([scope isEqual:@"auto"] && !bounds);
    if (wantsObject && session.selectedObjects.count) {
        *object = (spdf_paint_id)session.selectedObjects.firstObject.unsignedIntValue;
        for (NSDictionary* layer in state[@"layers"])
            if ([layer[@"id"] unsignedIntValue] == *object) {
                NSDictionary* box = layer[@"bounds"] ?: layer[@"object"][@"bounds"];
                if ([box isKindOfClass:NSDictionary.class]) bounds = box;
            }
    }
    if ((![scope isEqual:@"image"]) && bounds)
        return (spdf_rect){[bounds[@"x"] floatValue], [bounds[@"y"] floatValue],
                           [bounds[@"x"] floatValue] + [bounds[@"w"] floatValue],
                           [bounds[@"y"] floatValue] + [bounds[@"h"] floatValue]};
    *object = 0;
    return none;
}

static BOOL RenderScope(SPDFMacAnnotateSession* session, NSInteger page, NSString* scope, float maxSide,
                        spdf_bitmap* out) {
    spdf_paint_doc* doc = [session canvasForPage:page document:NULL create:NO];
    if (!doc) return NO;
    spdf_paint_id object = 0;
    spdf_paint_render_options options;
    memset(&options, 0, sizeof(options));
    options.region = ScopeRegion(session, page, scope ?: @"auto", &object);
    // A pixel selection gives its own pixels (a lasso's shape), not the whole box around it.
    if (!object && options.region.x1 > options.region.x0) options.flags |= SPDF_PAINT_RENDER_SELECTED_ONLY;
    if (object) {
        options.layers = &object;
        options.layer_count = 1;
    }
    int width = 0, height = 0;
    spdf_paint_size(doc, &width, &height);
    float w = options.region.x1 > options.region.x0 ? options.region.x1 - options.region.x0 : width;
    float h = options.region.y1 > options.region.y0 ? options.region.y1 - options.region.y0 : height;
    options.scale = maxSide > 0 && MAX(w, h) > maxSide ? maxSide / MAX(w, h) : 1;
    if (session.kind == SPDFAnnotateDocumentPDF) options.scale *= 2;  // a page's added pixels are 2 per point
    char err[256];
    return spdf_paint_render(doc, &options, out, err, sizeof(err)) == SPDF_PAINT_OK;
}

#pragma mark - Inputs

void SPDFAnnotatePrepareInput(NSDictionary* op, SPDFMacAnnotateSession* session, NSInteger page,
                              void (^ready)(NSDictionary* failure, const spdf_paint_apply_input* input)) {
    spdf_paint_apply_input input;
    memset(&input, 0, sizeof(input));
    NSString* name = op[@"op"];
    if ([name isEqual:@"picture.add"]) {
        SPDFAnnotatePicture* picture = nil;
        NSError* error = nil;
        if ([op[@"path"] isKindOfClass:NSString.class])
            picture = SPDFAnnotateDecodePicture([op[@"path"] stringByExpandingTildeInPath], &error);
        else if ([op[@"clipboard"] boolValue])
            picture = SPDFAnnotatePictureFromPasteboard(NSPasteboard.generalPasteboard);
        else {
            ready(nil, NULL);  // png_base64: the core decodes it
            return;
        }
        if (!picture) {
            ready(SPDFAnnotateErrorAnswer(@"io_error", error.localizedDescription ?: @"There is no picture on the "
                                                                                     @"clipboard."), NULL);
            return;
        }
        spdf_paint_pixels pixels = picture.pixels;
        input.picture = &pixels;
        ready(nil, &input);
        return;
    }
    if ([name isEqual:@"image.remove_background"]) {
        if (@available(macOS 14.0, *)) {
            spdf_bitmap bitmap = {0, 0, 0, NULL};
            if (!RenderScope(session, page, op[@"scope"], 2048, &bitmap)) {
                ready(SPDFAnnotateErrorAnswer(@"failed", @"The picture couldn't be read for Remove background."), NULL);
                return;
            }
            CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            CGContextRef context = CGBitmapContextCreate(bitmap.rgba, (size_t)bitmap.width, (size_t)bitmap.height, 8,
                                                         (size_t)bitmap.stride, srgb,
                                                         kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
            CGImageRef image = context ? CGBitmapContextCreateImage(context) : NULL;
            if (context) CGContextRelease(context);
            CGColorSpaceRelease(srgb);
            NSMutableData* mask = nil;
            if (image) {
                VNGenerateForegroundInstanceMaskRequest* request = [VNGenerateForegroundInstanceMaskRequest new];
                VNImageRequestHandler* handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
                NSError* error = nil;
                VNInstanceMaskObservation* found = nil;
                if ([handler performRequests:@[request] error:&error]) found = request.results.firstObject;
                CVPixelBufferRef buffer = found ? [found generateScaledMaskForImageForInstances:found.allInstances
                                                                             fromRequestHandler:handler
                                                                                          error:&error]
                                                : NULL;
                if (buffer) {
                    CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
                    size_t w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer);
                    size_t stride = CVPixelBufferGetBytesPerRow(buffer);
                    const unsigned char* base = (const unsigned char*)CVPixelBufferGetBaseAddress(buffer);
                    mask = [NSMutableData dataWithLength:w * h];
                    unsigned char* dst = (unsigned char*)mask.mutableBytes;
                    for (size_t y = 0; y < h; ++y) {
                        const float* row = (const float*)(base + y * stride);
                        for (size_t x = 0; x < w; ++x) dst[y * w + x] = (unsigned char)lroundf(MAX(0, MIN(1, row[x])) * 255);
                    }
                    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
                    input.mask_width = (int)w;
                    input.mask_height = (int)h;
                    input.mask_stride = (int)w;
                    CVPixelBufferRelease(buffer);
                }
                CGImageRelease(image);
            }
            spdf_free_bitmap(&bitmap);
            if (!mask) {
                ready(SPDFAnnotateErrorAnswer(@"failed", @"No main subject was found in this picture."), NULL);
                return;
            }
            input.mask = (const unsigned char*)mask.bytes;
            ready(nil, &input);
            return;
        }
        ready(SPDFAnnotateErrorAnswer(@"failed", @"Remove background needs macOS 14 or later."), NULL);
        return;
    }
    ready(nil, NULL);
}

#pragma mark - Frontend operations

@implementation SPDFMacFillController (AnnotateFrontend)

- (ShenzhenMacDelegate*)annotateReader {
    id host = self.host;
    return [host isKindOfClass:ShenzhenMacDelegate.class] ? host : nil;
}

- (void)annotateApplyFrontendOperation:(NSDictionary*)op info:(const spdf_paint_op_info*)info
                                   tab:(SPDFDocumentTab*)tab completion:(SPDFAnnotateCompletion)completion {
    (void)info;
    NSString* name = op[@"op"];
    ShenzhenMacDelegate* reader = [self annotateReader];
    BOOL active = tab && tab == [self.host fillTab];
    if ([name isEqual:@"canvas.new"]) {
        spdf_paint_color background = 0;
        if (op[@"background"] && ![op[@"background"] isEqual:@"transparent"])
            SPDFAnnotateParseColor(op[@"background"], &background);
        NSInteger width = op[@"width"] ? [op[@"width"] integerValue] : SPDF_PAINT_DEFAULT_SIZE;
        NSInteger height = op[@"height"] ? [op[@"height"] integerValue] : SPDF_PAINT_DEFAULT_SIZE;
        SPDFDocumentTab* made = [reader annotateNewCanvasWidth:width height:height background:background
                                                         front:[op[@"front"] boolValue]];
        // The new tab's id is its name for agents: a never-saved canvas has no file of its own to name.
        completion(made ? OK(@{@"tab": SPDFAnnotateTabIdentifier(made) ?: @"", @"title": SPDFAnnotateUntitledCanvasTitle})
                        : SPDFAnnotateErrorAnswer(@"failed", @"The canvas couldn't be made."));
        return;
    }
    if ([name isEqual:@"doc.save_as_pdf"]) {
        // Without a path it asks no one: notes.md becomes notes.pdf beside it (notes 2.pdf if that is taken).
        NSString* path = [op[@"path"] isKindOfClass:NSString.class] ? op[@"path"] : nil;
        if (!path.length && tab.path.length) {
            NSString* base = tab.path.stringByDeletingPathExtension;
            path = [base stringByAppendingPathExtension:@"pdf"];
            for (int n = 2; [NSFileManager.defaultManager fileExistsAtPath:path] && n < 1000; n++)
                path = [[base stringByAppendingFormat:@" %d", n] stringByAppendingPathExtension:@"pdf"];
        }
        [reader annotateSaveTextDocumentAsPDF:path completion:^(SPDFDocumentTab* made, NSError* error) {
            completion(made ? OK(@{@"path": made.path ?: @"", @"tab": SPDFAnnotateTabIdentifier(made) ?: @""})
                            : error ? Failure(error, @"io_error")
                                    : SPDFAnnotateErrorAnswer(@"cancelled", @"Nothing was saved."));
        }];
        return;
    }
    SPDFMacAnnotateSession* session = [self annotateSessionForTab:tab create:YES];
    NSError* error = nil;
    if (!session || ![session loadIfNeeded:&error]) {
        completion(SPDFAnnotateErrorAnswer(@"io_error", error.localizedDescription ?: @"Annotate can't open this."));
        return;
    }
    SPDFMacAnnotateCanvasView* view = self.annotateCanvasView.session == session ? self.annotateCanvasView : nil;
    if ([name isEqual:@"history.undo"] || [name isEqual:@"history.redo"]) {
        NSInteger steps = op[@"steps"] ? [op[@"steps"] integerValue] : 1;
        BOOL undo = [name isEqual:@"history.undo"], pdf = session.kind == SPDFAnnotateDocumentPDF && active;
        // Fill & Sign's steps from before Annotate's stack existed stay on its own undo manager.
        if (pdf && !(undo ? session.canUndo : session.canRedo) && (undo ? [self canUndo] : [self canRedo])) {
            undo ? [self undo] : [self redo];
            completion(undo ? @{@"ok": @YES, @"undone": @1} : @{@"ok": @YES, @"redone": @1});
            return;
        }
        if (pdf && ![self annotatePrepareForPDFChange]) {
            completion(SPDFAnnotateErrorAnswer(@"cancelled", @"This document can't be changed right now."));
            return;
        }
        NSDictionary* result = undo ? [session undo:steps] : [session redo:steps];
        if (pdf)  // the pages undone are written back as annotations, in one save (pages left as they were: none)
            [self annotateWritePDFPages:[self annotateCanvasesOfPages:session.openPages] error:NULL];
        [view canvasSizeDidChange];
        [view canvasDidChangeOnPage:session.kind == SPDFAnnotateDocumentPDF ? session.currentPage : -1];
        if (active) [self.host fillStateDidChange];
        completion(result);
        return;
    }
    if ([name isEqual:@"doc.save"]) {
        if (session.neverSaved || (session.kind == SPDFAnnotateDocumentPicture && !session.writesInPlace)) {
            completion(SPDFAnnotateErrorAnswer(@"needs_save_as", session.neverSaved
                ? @"This canvas has never been saved: give doc.save_as a path."
                : @"This picture can't be written in its own format: give doc.save_as a path (PNG)."));
            return;
        }
        [session saveWithCompletion:^(NSError* e) { completion(e ? Failure(e, @"io_error") : OK(nil)); }];
        return;
    }
    if ([name isEqual:@"doc.save_as"]) {
        NSString* path = [op[@"path"] stringByExpandingTildeInPath];
        [session saveAsPath:path format:op[@"format"] quality:[op[@"quality"] doubleValue]
                 completion:^(NSError* e) { completion(e ? Failure(e, @"io_error") : OK(@{@"path": path})); }];
        return;
    }
    if ([name isEqual:@"palette.save"] || [name isEqual:@"palette.load"]) {
        completion(SPDFAnnotatePaletteFileOperation(self, op[@"path"], [name isEqual:@"palette.save"]));
        return;
    }
    if ([name isEqual:@"doc.copy"]) {
        spdf_bitmap bitmap = {0, 0, 0, NULL};
        NSInteger page = session.kind == SPDFAnnotateDocumentPDF
                             ? ([op[@"page"] integerValue] > 0 ? [op[@"page"] integerValue] - 1 : session.currentPage)
                             : -1;
        NSString* out = [op[@"out"] stringByExpandingTildeInPath];  // Copy to file: the same pixels, as a PNG file
        BOOL ok = RenderScope(session, page, op[@"scope"], 0, &bitmap) &&
                  (out ? [SPDFAnnotateEncodePicture(&bitmap, @"png", nil, 0, NULL) writeToFile:out atomically:YES]
                       : SPDFAnnotateWriteToPasteboard(&bitmap, NSPasteboard.generalPasteboard));
        spdf_free_bitmap(&bitmap);
        completion(ok ? OK(out ? @{@"path": out} : nil)
                      : SPDFAnnotateErrorAnswer(@"failed", out ? @"The PNG file couldn't be written." : @"Nothing could be copied."));
        return;
    }
    if ([name isEqual:@"mode.set"]) {
        BOOL on = [op[@"on"] boolValue];
        if (active) {
            if (on != [reader annotateShowing]) [reader toggleAnnotate:nil];
        } else if (!on) {
            [session saveWithCompletion:nil];
        }
        completion(OK(@{@"on": @(active ? [reader annotateShowing] : on)}));
        return;
    }
    if ([name isEqual:@"view.zoom"]) {
        if (!active) {
            completion(SPDFAnnotateErrorAnswer(@"not_shown", @"Zoom applies to the document in front."));
            return;
        }
        [reader annotateZoomTo:op[@"level"] atCanvasPoint:nil];
        completion(OK(@{@"zoom": @([view zoomLevel])}));
        return;
    }
    if ([name isEqual:@"view.set"]) {
        SPDFAnnotateSettings* settings = SPDFAnnotateSettings.shared;
        if (op[@"rulers"]) settings.showsRulers = [op[@"rulers"] boolValue];
        if (op[@"gridlines"]) settings.showsGridlines = [op[@"gridlines"] boolValue];
        if (op[@"statusbar"]) settings.showsStatusBar = [op[@"statusbar"] boolValue];
        if (op[@"thumbnail"]) self.annotateEnsureCanvasView.showsThumbnail = [op[@"thumbnail"] boolValue];
        [self annotateEnsureCanvasView].showsRulers = settings.showsRulers;
        [self annotateEnsureCanvasView].showsGridlines = settings.showsGridlines;
        SPDFAnnotateUpdateStatusBar(self, [reader annotateShowing] ? [reader annotateActiveSession] : nil);
        completion(OK(@{@"rulers": @(settings.showsRulers), @"gridlines": @(settings.showsGridlines),
                        @"statusbar": @(settings.showsStatusBar),
                        @"thumbnail": @(self.annotateEnsureCanvasView.showsThumbnail)}));
        return;
    }
    if ([name isEqual:@"tool.choose"]) {
        SPDFAnnotateTool tool;
        NSInteger brush = session.brush;
        if (!SPDFAnnotateToolFromName(op[@"tool"], &tool, &brush)) {
            completion(SPDFAnnotateErrorAnswer(@"invalid_argument", @"There is no such tool."));
            return;
        }
        NSDictionary* options = [op[@"options"] isKindOfClass:NSDictionary.class] ? op[@"options"] : @{};
        if (tool == SPDFAnnotateToolShape && [options[@"shape"] isKindOfClass:NSString.class]) session.shape = options[@"shape"];
        if (tool == SPDFAnnotateToolEraser && options[@"eraser"]) session.eraserPixels = ![options[@"eraser"] isEqual:@"lines"];
        if (tool == SPDFAnnotateToolColorPicker && session.tool != SPDFAnnotateToolColorPicker)
            session.toolBeforePicker = session.tool;
        session.tool = tool;
        session.brush = brush;
        if (options.count) [SPDFAnnotateSettings.shared setOptions:options forTool:SPDFAnnotateToolName(tool, brush)];
        [view toolDidChange];
        [session noteChange];
        completion(OK(@{@"tool": SPDFAnnotateToolName(tool, brush)}));
        return;
    }
    completion(SPDFAnnotateErrorAnswer(@"unknown_op", @"There is no such operation."));
}

// -setOn:'s hook. Done on a picture or canvas writes it into its file; the canvas keeps being drawn over the page
// until the reader shows the written file, so no frame shows the picture as it was.
- (void)annotateModeWillChange:(BOOL)on {
    SPDFMacAnnotateSession* session = [self annotateSessionForTab:nil create:NO];
    if (on || !session.loaded || session.kind == SPDFAnnotateDocumentPDF) return;
    SPDFMacAnnotateCanvasView* view = self.annotateCanvasView;
    [view cancelGesture];
    if (!session.dirty && !session.pageStale) return;
    if (view.session == session) [view holdLastFrameUntilReload];
    __weak SPDFMacFillController* weakSelf = self;
    if (session.neverSaved || !session.writesInPlace) {
        // A never-saved canvas keeps its pixels in <state>/Annotate; a WebP or RAW keeps its changes there.
        BOOL ask = !session.neverSaved && session.dirty;
        [session flushForClose:YES error:NULL];
        ShenzhenMacDelegate* reader = [self annotateReader];
        if (!ask) {
            [reader annotateShowWrittenPictureOfSession:session];
            return;
        }
        // Done saves: a WebP or RAW drawn on asks where its PNG copy goes, once the palette has gone; the drawing stays
        // in view until the panel closes.
        dispatch_async(dispatch_get_main_queue(), ^{
            [reader annotateAskWhereToSaveSession:session completion:^(BOOL saved) {
                (void)saved;
                [reader annotateShowWrittenPictureOfSession:session];
            }];
        });
        return;
    }
    [session saveWithCompletion:^(NSError* error) {
        if (error && error.code != NSUserCancelledError)
            [weakSelf.host fillShowError:@"Couldn't save the picture" detail:error.localizedDescription];
        [[weakSelf annotateReader] annotateShowWrittenPictureOfSession:session];
    }];
}

@end
