#pragma once
// What the controller's Annotate category (SPDFMacFillController+Annotate.mm) and its frontend operations
// (SPDFMacAnnotateFrontendOperations.mm), the canvas view and the status bar share. Mac UI A.
#import "SPDFMacFillController+Annotate.h"

@class SPDFMacAnnotateCanvasView;

NS_ASSUME_NONNULL_BEGIN

// The document kind Annotate sees in a tab: a canvas for the files a canvas or .szpaint tab shows, else by its path.
FOUNDATION_EXPORT SPDFAnnotateDocumentKind SPDFAnnotateKindForTab(SPDFDocumentTab* _Nullable tab);

// picture.add {path | clipboard} decoded, image.remove_background's subject mask from Vision; then `ready` with the
// input (valid during the call) or a failure answer.
FOUNDATION_EXPORT void SPDFAnnotatePrepareInput(NSDictionary* op, SPDFMacAnnotateSession* session, NSInteger page,
                                                void (^ready)(NSDictionary* _Nullable failure,
                                                              const spdf_paint_apply_input* _Nullable input));

// The status bar under the page area while Annotate shows (SPDFMacAnnotateStatusBar.mm); session nil hides it.
FOUNDATION_EXPORT void SPDFAnnotateUpdateStatusBar(SPDFMacFillController* controller,
                                                   SPDFMacAnnotateSession* _Nullable session);

@interface SPDFMacFillController (AnnotateShared)
- (void)annotateApplyFrontendOperation:(NSDictionary*)op info:(const spdf_paint_op_info*)info
                                   tab:(nullable SPDFDocumentTab*)tab completion:(SPDFAnnotateCompletion)completion;
- (void)annotateApplyFillOperation:(NSDictionary*)op info:(const spdf_paint_op_info*)info
                               tab:(nullable SPDFDocumentTab*)tab completion:(SPDFAnnotateCompletion)completion;
- (SPDFMacAnnotateCanvasView*)annotateEnsureCanvasView;
// Hooks in SPDFMacFillController.mm: the end of -refreshChrome, and -setOn: before the mode changes.
- (void)annotateChromeDidRefresh:(BOOL)showing;
- (void)annotateModeWillChange:(BOOL)on;
@end

NS_ASSUME_NONNULL_END
