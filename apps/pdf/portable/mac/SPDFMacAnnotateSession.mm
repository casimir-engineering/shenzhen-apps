// Annotate, per tab (SPDFMacAnnotateSession.h).
//
// WAVE 0 STUB (Mac UI A implements): sessions are found and made through the tab; everything else does nothing or
// answers not_implemented.
#import "SPDFMacAnnotateSession.h"

#import <objc/runtime.h>

#import "SPDFMacModels.h"

static char kSPDFAnnotateSessionKey;

static NSDictionary* SPDFAnnotateNotBuilt(void) {
    return @{@"ok": @NO, @"error": @"not_implemented", @"message": @"Annotate is not built yet."};
}

NSString* SPDFAnnotateToolName(SPDFAnnotateTool tool, NSInteger brush) {
    (void)tool; (void)brush;
    return @"";
}

BOOL SPDFAnnotateToolFromName(NSString* name, SPDFAnnotateTool* tool, NSInteger* brush) {
    (void)name; (void)tool; (void)brush;
    return NO;
}

// SPDFAnnotateSettings is implemented in SPDFMacAnnotateSettings.mm (Mac UI B).

@interface SPDFMacAnnotateSession ()
@property(nonatomic, weak, readwrite) SPDFDocumentTab* tab;
@property(nonatomic, readwrite) SPDFAnnotateDocumentKind kind;
@end

@implementation SPDFMacAnnotateSession

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
    session.color1 = 0x000000FFu;
    session.color2 = 0xFFFFFFFFu;
    objc_setAssociatedObject(tab, &kSPDFAnnotateSessionKey, session, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return session;
}

+ (void)discardSessionForTab:(SPDFDocumentTab*)tab {
    if (tab) objc_setAssociatedObject(tab, &kSPDFAnnotateSessionKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (BOOL)loadIfNeeded:(NSError**)error {
    if (error) *error = nil;
    return NO;
}

- (spdf_paint_doc*)canvasForPage:(NSInteger)page document:(spdf_document*)pdf create:(BOOL)create {
    (void)page; (void)pdf; (void)create;
    return NULL;
}

- (NSIndexSet*)openPages {
    return [NSIndexSet indexSet];
}

- (NSDictionary*)applyCanvasOperation:(NSDictionary*)op page:(NSInteger)page
                                input:(const spdf_paint_apply_input*)input {
    (void)op; (void)page; (void)input;
    return SPDFAnnotateNotBuilt();
}

- (void)recordFillStep {
}

- (NSDictionary*)undo:(NSInteger)steps {
    (void)steps;
    return SPDFAnnotateNotBuilt();
}

- (NSDictionary*)redo:(NSInteger)steps {
    (void)steps;
    return SPDFAnnotateNotBuilt();
}

- (void)saveWithCompletion:(void (^)(NSError*))completion {
    if (completion) completion(nil);
}

- (void)saveAsPath:(NSString*)path format:(NSString*)format quality:(CGFloat)quality
        completion:(void (^)(NSError*))completion {
    (void)path; (void)format; (void)quality;
    if (completion) completion(nil);
}

- (void)scheduleProjectAutosave {
}

- (BOOL)flushForClose:(BOOL)quitting error:(NSError**)error {
    (void)quitting;
    if (error) *error = nil;
    return YES;
}

@end
