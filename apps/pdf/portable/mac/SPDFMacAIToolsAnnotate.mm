// The assistant's Annotate tools (SPDFMacAnnotateAgents.h): annotate_apply, annotate_state, annotate_look and
// canvas_new. Their descriptions are generated from spdf_paint_schema() (SPDFAnnotateOperationReference), and every
// change goes through -[SPDFMacFillController applyOperations:tab:completion:], so it lands on the tab's own undo stack
// (Cmd-Z undoes it like the person's own) and answers exactly as `szpdf annotate --script` does. A call that changed
// something is listed in the chat and can be undone with undo_action, which refuses when the document changed since.
#import "SPDFMacAnnotateAgents.h"

#import "SPDFMacAIChatActivity.h"
#import "SPDFMacAIDocumentAvailability.h"
#import "SPDFMacAIToolsPrivate.h"
#import "SPDFMacAIToolsReader.h"
#import "SPDFMacModels.h"
#import "SPDFMacSzpdfInternal.h"

#import <CommonCrypto/CommonDigest.h>
#import <ImageIO/ImageIO.h>

#include "spdf_paint.h"

static NSDictionary* Refusal(NSString* message) { return @{@"error" : message}; }

static NSDictionary* Target(void) {
    return @{@"type" : @"string", @"description" : @"Document ID (doc:...) from list_workspace, or a canvas's tab id "
                                                   @"(tab-...) from canvas_new."};
}

static NSDictionary* Definition(NSString* name, NSString* description, NSDictionary* properties, NSArray* required) {
    return @{@"type" : @"function", @"function" : @{@"name" : name, @"description" : description,
        @"parameters" : @{@"type" : @"object", @"properties" : properties, @"required" : required, @"additionalProperties" : @NO}}};
}

// A schema property as the assistant's tool schema takes it: "$ref" resolved, a choice of forms given as text.
static NSDictionary* Plain(NSDictionary* property, NSString* description) {
    NSMutableDictionary* plain = [SPDFAnnotateResolvedProperty(property) mutableCopy];
    if (plain[@"anyOf"]) plain = [@{@"type" : @"string"} mutableCopy];
    if (description) plain[@"description"] = description;
    return plain;
}

NSArray<NSDictionary*>* SPDFMacAIAnnotateToolDefinitions(void) {
    NSDictionary* page = @{@"type" : @"integer", @"description" : @"On a PDF, the page from 1."};
    NSDictionary* canvas = SPDFAnnotateOperationSchema(@"canvas.new")[@"properties"];
    NSDictionary* rect = SPDFAnnotateResolvedProperty(@{@"$ref" : @"#/$defs/rect"});
    return @[
        Definition(@"annotate_apply",
                   [@"Change a picture, a blank canvas or a PDF page with Annotate's tools: draw and paint, fill, add "
                    @"shapes, text and pictures, move, restyle and reorder objects and layers, crop, resize and rotate, "
                    @"and on a PDF fill in its form (form.*). Explicitly user-requested only. Operations apply in "
                    @"order and stop at the first error; results gives each one's answer (new objects' ids among "
                    @"them). The page of a PDF itself can't be changed (page_locked); a text document is saved as a "
                    @"PDF first with doc.save_as_pdf. form.signature_place places the person's own saved signature; "
                    @"never draw one. Read annotate_state for ids first, and check the result with annotate_look. The "
                    @"person can undo each change with Cmd-Z; undo_action undoes the whole call.\n"
                    stringByAppendingString:SPDFAnnotateOperationReference()],
                   @{@"target" : Target(),
                     @"ops" : @{@"type" : @"array", @"minItems" : @1, @"maxItems" : @200,
                                @"description" : @"The operations, in order, as listed above.",
                                @"items" : @{@"type" : @"object", @"required" : @[ @"op" ],
                                             @"properties" : @{@"op" : @{@"type" : @"string", @"enum" : SPDFAnnotateOperationNames()}}}}},
                   @[ @"target", @"ops" ]),
        Definition(@"annotate_state",
                   @"Describe a document as Annotate sees it: its size, its layers and objects with their ids, kinds, "
                   @"bounds and settings, the selection, colours and unsaved changes; on a PDF, that page's, plus its "
                   @"form fields and what was placed on it. Read it before changing objects or layers by id.",
                   @{@"target" : Target(), @"page" : page}, @[ @"target" ]),
        Definition(@"annotate_look",
                   @"See a picture, canvas or PDF page as Annotate draws it, with everything added. The image is sent "
                   @"to your vision input and shown in chat. Look after changing something, before saying it is done.",
                   @{@"target" : Target(), @"page" : page,
                     @"region" : Plain(rect, @"Optional part to see: pixels on pictures and canvases, points on PDF "
                                             @"pages, from the top-left corner.")},
                   @[ @"target" ]),
        Definition(@"canvas_new", @"Open a new blank canvas in a tab with Annotate on (1000 x 1000 pixels and "
                                  @"transparent unless given). Answers its tab id for the other annotate tools.",
                   @{@"width" : Plain(canvas[@"width"], @"Pixels, 1 to 16384; default 1000."),
                     @"height" : Plain(canvas[@"height"], @"Pixels, 1 to 16384; default 1000."),
                     @"background" : Plain(canvas[@"background"], @"transparent (default) or a colour, #RRGGBB.")},
                   @[]),
    ];
}

// What the person reads in the chat for each change, in the past tense.
static NSString* Done(NSString* op) {
    static NSDictionary* words;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      words = @{@"canvas.resize" : @"Resized the canvas", @"canvas.properties" : @"Changed the picture's properties",
                @"image.resize" : @"Resized", @"image.skew" : @"Skewed", @"image.rotate" : @"Rotated",
                @"image.flip" : @"Flipped", @"image.crop" : @"Cropped", @"image.invert" : @"Inverted the colours",
                @"image.clear" : @"Cleared a layer", @"image.remove_background" : @"Removed the background",
                @"select.delete" : @"Deleted the selection", @"select.lift" : @"Lifted the selection",
                @"pen.add" : @"Drew a pen line", @"arrow.add" : @"Drew an arrow", @"erase.lines" : @"Erased lines",
                @"paint.stroke" : @"Painted a stroke", @"paint.fill" : @"Filled an area", @"shape.add" : @"Added a shape",
                @"text.add" : @"Added a text box", @"picture.add" : @"Added a picture", @"object.update" : @"Changed an object",
                @"object.move" : @"Moved", @"object.transform" : @"Transformed an object", @"object.order" : @"Changed the depth",
                @"object.merge_down" : @"Merged an object down", @"object.duplicate" : @"Duplicated an object",
                @"object.delete" : @"Deleted", @"layer.add" : @"Added a layer", @"layer.duplicate" : @"Duplicated a layer",
                @"layer.delete" : @"Deleted a layer", @"layer.merge_down" : @"Merged a layer down",
                @"layer.set" : @"Changed a layer", @"layer.order" : @"Reordered a layer",
                @"form.field_set" : @"Filled in a field", @"form.text_add" : @"Placed text", @"form.mark_add" : @"Placed a mark",
                @"form.signature_place" : @"Placed your signature", @"form.remove_drawings" : @"Removed the pen lines and arrows",
                @"form.remove_everything" : @"Removed everything added", @"form.save_final_copy" : @"Saved a final copy",
                @"history.undo" : @"Undid", @"history.redo" : @"Redid", @"doc.save" : @"Saved", @"doc.save_as" : @"Saved a copy",
                @"doc.save_as_pdf" : @"Saved it as a PDF", @"canvas.new" : @"Opened a new canvas"};
    });
    return words[op];
}

static NSString* Fingerprint(NSArray* results) {
    // What the person could change by hand; the view, tools and saving state are left out.
    NSSet* volatileKeys = [NSSet setWithArray:@[ @"zoom", @"view", @"tool", @"selection", @"colors", @"color1", @"color2",
                                                @"palette", @"dirty", @"file", @"path", @"tab", @"windowId", @"activeLayer" ]];
    id (^__block strip)(id) = nil;
    id (^stripper)(id) = ^id(id value) {
      if ([value isKindOfClass:NSDictionary.class]) {
          NSMutableDictionary* out = [NSMutableDictionary dictionary];
          for (NSString* key in value) if (![volatileKeys containsObject:key]) out[key] = strip(value[key]);
          return out;
      }
      if ([value isKindOfClass:NSArray.class]) {
          NSMutableArray* out = [NSMutableArray array];
          for (id item in value) [out addObject:strip(item)];
          return out;
      }
      return value;
    };
    strip = stripper;
    NSData* data = [NSJSONSerialization dataWithJSONObject:strip(results ?: @[]) options:NSJSONWritingSortedKeys error:nil];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString* hex = [NSMutableString string];
    for (size_t i = 0; i < sizeof(digest); i++) [hex appendFormat:@"%02x", digest[i]];
    strip = nil;
    return hex;
}

// Sizes doc.state may give: width/height, size {width, height} or [w, h].
static CGSize StateSize(NSDictionary* state) {
    for (id source in @[ state ?: @{}, state[@"size"] ?: @{}, state[@"canvas"] ?: @{} ]) {
        if ([source isKindOfClass:NSArray.class] && [source count] >= 2) return CGSizeMake([source[0] doubleValue], [source[1] doubleValue]);
        if ([source isKindOfClass:NSDictionary.class] && [source[@"width"] isKindOfClass:NSNumber.class])
            return CGSizeMake([source[@"width"] doubleValue], [source[@"height"] doubleValue]);
    }
    return CGSizeZero;
}

@implementation SPDFMacAITools (Annotate)

- (SPDFDocumentTab*)annotateTabForTarget:(NSString*)target {
    if (SPDFAnnotateIsTabIdentifier(target)) return [self.reader annotateAgentTabForTarget:target];
    for (NSString* path in [self.reader aiDocumentPaths])
        if ([SPDFAIDocumentIdentifier(path) isEqual:target]) return [self.reader annotateAgentTabForTarget:path];
    return nil;
}

// The answer as the model reads it: Annotate's errors in szpdf's shape, the document's own path as its ID.
- (NSDictionary*)modelAnswer:(NSDictionary*)answer tab:(SPDFDocumentTab*)tab {
    NSMutableDictionary* out = [(answer[@"results"] ? SPDFAnnotateScriptAnswer(answer) : SPDFAnnotateAgentAnswer(answer)) mutableCopy];
    NSMutableArray* results = [NSMutableArray array];
    for (NSDictionary* result in [out[@"results"] isKindOfClass:NSArray.class] ? out[@"results"] : @[]) {
        NSMutableDictionary* one = [result mutableCopy];
        if (tab.path && [one[@"file"] isEqual:tab.path]) one[@"file"] = SPDFAIDocumentIdentifier(tab.path);
        [results addObject:one];
    }
    if (out[@"results"]) out[@"results"] = results;
    if (tab.path && [out[@"file"] isEqual:tab.path]) out[@"file"] = SPDFAIDocumentIdentifier(tab.path);
    [out removeObjectForKey:@"windowId"];
    return out;
}

// Every page the operations named, then the document as a whole, then its form: what undo checks has not changed.
- (void)annotateFingerprint:(SPDFDocumentTab*)tab pages:(NSArray<NSNumber*>*)pages completion:(void (^)(NSString*))completion {
    NSMutableArray* ops = [NSMutableArray array];
    for (NSNumber* page in pages) [ops addObject:@{@"op" : @"doc.state", @"page" : page}];
    [ops addObject:@{@"op" : @"doc.state"}];
    [ops addObject:@{@"op" : @"form.state"}];
    [self.reader annotateAgentApply:ops tab:tab reply:^(NSDictionary* answer) { completion(Fingerprint(answer[@"results"])); }];
}

- (void)annotateApply:(NSArray*)ops tab:(SPDFDocumentTab*)tab target:(NSString*)target
           completion:(void (^)(NSDictionary*))completion {
    NSString* title = spdf_tab_display_name(tab) ?: tab.title ?: @"the document";
    id<SPDFMacAIActivityReporting> activity = self.activity;
    NSString* step = [activity beginStepWithTitle:[NSString stringWithFormat:@"Annotating %@", title] detail:nil
                                          options:SPDFMacAIActivityOptionsNone cancel:nil];
    [self.reader annotateAgentApply:ops tab:tab reply:^(NSDictionary* answer) {
      NSArray* results = [answer[@"results"] isKindOfClass:NSArray.class] ? answer[@"results"] : @[];
      NSMutableArray *lines = [NSMutableArray array], *pages = [NSMutableArray array];
      NSInteger steps = 0;
      BOOL history = NO;
      NSString* problem = nil;
      for (NSUInteger i = 0; i < results.count && i < ops.count; i++) {
          NSString* name = ops[i][@"op"];
          const spdf_paint_op_info* info = spdf_paint_op_find(name.UTF8String);
          if (![results[i][@"ok"] boolValue]) { problem = results[i][@"message"] ?: @"A change didn't work."; break; }
          if ([name hasPrefix:@"history."]) history = YES;
          if (info && (info->flags & SPDF_PAINT_OP_UNDOABLE)) steps++;
          if ([ops[i][@"page"] isKindOfClass:NSNumber.class] && ![pages containsObject:ops[i][@"page"]]) [pages addObject:ops[i][@"page"]];
          if (Done(name)) [lines addObject:Done(name)];
      }
      NSMutableDictionary* changes = [@{SPDFMacAIActivityStateKey : problem ? SPDFMacAIActivityStateFailed : SPDFMacAIActivityStateDone,
                                        SPDFMacAIActivityTitleKey : [NSString stringWithFormat:@"Annotated %@", title]} mutableCopy];
      if (lines.count) changes[SPDFMacAIActivityDetailKey] = [lines componentsJoinedByString:@"\n"];
      if (problem) changes[SPDFMacAIActivityStatusKey] = problem;
      if (step) [activity updateEntry:step changes:changes];
      NSMutableDictionary* visible = [[self modelAnswer:answer tab:tab] mutableCopy];
      if (steps == 0 || history) { completion(visible); return; }
      [self annotateFingerprint:tab pages:pages completion:^(NSString* fingerprint) {
        NSString* identifier = NSUUID.UUID.UUIDString;
        [self.actions addObject:@{@"id" : identifier, @"annotate" : @{@"tab" : SPDFAnnotateTabIdentifier(tab), @"steps" : @(steps),
                                                                    @"pages" : pages, @"fingerprint" : fingerprint}}];
        [self.redoActions removeAllObjects];
        if (self.actions.count > 32) [self.actions removeObjectAtIndex:0];
        visible[@"actionID"] = identifier;
        visible[@"undoable"] = @YES;
        completion(visible);
      }];
    }];
}

- (void)swapAnnotateAction:(BOOL)redo completion:(void (^)(NSDictionary*))completion {
    NSMutableArray* source = redo ? self.redoActions : self.actions;
    NSDictionary* action = source.lastObject, *record = action[@"annotate"];
    SPDFDocumentTab* tab = [self.reader annotateAgentTabForTarget:record[@"tab"] ?: @""];
    if (!tab) { completion(Refusal(@"The document was closed after this action.")); return; }
    [self annotateFingerprint:tab pages:record[@"pages"] completion:^(NSString* now) {
      if (![now isEqual:record[@"fingerprint"]]) {
          completion(Refusal(redo ? @"The document changed since this action was undone. Redo would overwrite your changes."
                                  : @"The document changed after this action. Undo would overwrite your changes."));
          return;
      }
      NSDictionary* op = @{@"op" : redo ? @"history.redo" : @"history.undo", @"steps" : record[@"steps"]};
      [self.reader annotateAgentApply:@[ op ] tab:tab reply:^(NSDictionary* answer) {
        NSDictionary* result = SPDFAnnotateAgentAnswer([answer[@"results"] firstObject]);
        if (result[@"error"]) { completion(Refusal(result[@"error"][@"message"] ?: @"Nothing to undo.")); return; }
        [self annotateFingerprint:tab pages:record[@"pages"] completion:^(NSString* after) {
          [source removeObjectIdenticalTo:action];
          if (!self.redoActions) self.redoActions = [NSMutableArray array];
          NSMutableDictionary* swapped = [record mutableCopy];
          swapped[@"fingerprint"] = after;
          [(redo ? self.actions : self.redoActions) addObject:@{@"id" : NSUUID.UUID.UUIDString, @"annotate" : swapped}];
          completion(@{redo ? @"redone" : @"undone" : @YES});
        }];
      }];
    }];
}

- (void)annotateLook:(SPDFDocumentTab*)tab arguments:(NSDictionary*)arguments completion:(void (^)(NSDictionary*))completion {
    NSMutableDictionary* state = [@{@"op" : @"doc.state"} mutableCopy];
    if (arguments[@"page"]) state[@"page"] = arguments[@"page"];
    [self.reader annotateAgentApply:@[ state ] tab:tab reply:^(NSDictionary* first) {
      NSDictionary* described = [first[@"results"] firstObject];
      if (![described[@"ok"] boolValue]) { completion([self modelAnswer:described tab:tab]); return; }
      NSDictionary* region = arguments[@"region"];
      CGSize size = region ? CGSizeMake([region[@"w"] doubleValue], [region[@"h"] doubleValue]) : StateSize(described);
      double longest = MAX(size.width, size.height), scale = longest > 0 ? MIN(2.0, 1600.0 / longest) : 1;
      NSString* folder = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"ShenzhenPDF-AI-" stringByAppendingString:NSUUID.UUID.UUIDString]];
      NSString* picture = [folder stringByAppendingPathComponent:@"page.png"];
      if (![NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:NO
                                                    attributes:@{NSFilePosixPermissions : @0700} error:nil]) {
          completion(Refusal(@"The picture could not be prepared."));
          return;
      }
      NSMutableDictionary* render = [@{@"op" : @"doc.render", @"out" : picture, @"scale" : @(MAX(scale, 0.01))} mutableCopy];
      for (NSString* key in @[ @"page", @"region" ]) if (arguments[key]) render[key] = arguments[key];
      [self.reader annotateAgentApply:@[ render ] tab:tab reply:^(NSDictionary* answer) {
        NSDictionary* result = [answer[@"results"] firstObject];
        CGImageSourceRef source = [result[@"ok"] boolValue] ? CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:picture], NULL) : NULL;
        NSDictionary* properties = source ? CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL)) : nil;
        if (source) CFRelease(source);
        NSNumber *width = properties[(id)kCGImagePropertyPixelWidth], *height = properties[(id)kCGImagePropertyPixelHeight];
        unsigned long long bytes = [[NSFileManager.defaultManager attributesOfItemAtPath:picture error:nil] fileSize];
        if (!width || !height || bytes > 8 * 1024 * 1024) {
            [NSFileManager.defaultManager removeItemAtPath:folder error:nil];
            completion(width ? Refusal(@"The picture is too large to look at; ask for a region.") : [self modelAnswer:result tab:tab]);
            return;
        }
        NSString* name = spdf_tab_display_name(tab) ?: tab.title ?: @"Canvas";
        NSString* caption = arguments[@"page"] ? [NSString stringWithFormat:@"%@ · page %@", name, arguments[@"page"]] : name;
        if (region) caption = [caption stringByAppendingString:@" · detail"];
        completion(@{@"rendered" : @YES, @"page" : arguments[@"page"] ?: NSNull.null, @"pixelWidth" : width,
                     @"pixelHeight" : height, @"scale" : render[@"scale"],
                     @"_localPreview" : @{@"path" : picture, @"kind" : @"annotate", @"caption" : caption,
                                          @"pixelWidth" : width, @"pixelHeight" : height}});
      }];
    }];
}

- (BOOL)performAnnotateTool:(NSString*)name arguments:(NSDictionary*)arguments
                 completion:(void (^)(NSDictionary*))completion {
    if (![@[ @"annotate_apply", @"annotate_state", @"annotate_look", @"canvas_new" ] containsObject:name]) return NO;
    if ([name isEqual:@"canvas_new"]) {
        id<SPDFMacAIActivityReporting> activity = self.activity;
        [self.reader annotateAgentNewCanvas:arguments front:NO reply:^(NSDictionary* answer) {
          NSDictionary* result = SPDFAnnotateAgentAnswer(answer);
          if (!result[@"error"]) {
              NSString* step = [activity beginStepWithTitle:@"Opened a new canvas" detail:nil options:SPDFMacAIActivityOptionsNone cancel:nil];
              if (step) [activity updateEntry:step changes:@{SPDFMacAIActivityStateKey : SPDFMacAIActivityStateDone}];
          }
          NSMutableDictionary* visible = [result mutableCopy];
          [visible removeObjectForKey:@"windowId"];
          completion(visible);
        }];
        return YES;
    }
    NSString* target = arguments[@"target"];
    SPDFDocumentTab* tab = [self annotateTabForTarget:target];
    if (!tab) {
        completion(Refusal(SPDFAnnotateIsTabIdentifier(target) ? @"No tab has that id; it was closed. Use canvas_new for a new canvas."
                                                               : [self.reader aiClosedDocumentMessage:target]));
        return YES;
    }
    if ([name isEqual:@"annotate_look"]) {
        id region = arguments[@"region"];
        if (region && (![region isKindOfClass:NSDictionary.class] || [region[@"w"] doubleValue] <= 0 || [region[@"h"] doubleValue] <= 0))
            completion(Refusal(@"region is {x, y, w, h} with a positive width and height."));
        else [self annotateLook:tab arguments:arguments completion:completion];
        return YES;
    }
    if ([name isEqual:@"annotate_state"]) {
        NSMutableDictionary* state = [@{@"op" : @"doc.state"} mutableCopy];
        if (arguments[@"page"]) state[@"page"] = arguments[@"page"];
        [self.reader annotateAgentApply:@[ state, @{@"op" : @"form.state"} ] tab:tab reply:^(NSDictionary* answer) {
          NSArray* results = [self modelAnswer:answer tab:tab][@"results"];
          NSMutableDictionary* out = [results.firstObject mutableCopy] ?: [NSMutableDictionary dictionary];
          NSMutableDictionary* form = results.count > 1 ? [results[1] mutableCopy] : nil;
          [form removeObjectForKey:@"ok"];
          if (form && !form[@"error"]) out[@"form"] = form;
          out[@"tab"] = answer[@"tab"];
          completion(out);
        }];
        return YES;
    }
    NSArray* ops = arguments[@"ops"];
    BOOL valid = [ops isKindOfClass:NSArray.class] && ops.count >= 1 && ops.count <= 200;
    for (id op in valid ? ops : @[])
        valid = valid && [op isKindOfClass:NSDictionary.class] && [op[@"op"] isKindOfClass:NSString.class];
    if (!valid) completion(Refusal(@"ops is a list of 1 to 200 operations, each an object with \"op\"."));
    else [self annotateApply:ops tab:tab target:target completion:completion];
    return YES;
}

@end
