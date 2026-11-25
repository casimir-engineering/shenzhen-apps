#pragma once
// Annotate for agents (docs/plans/annotate.md § 6 Agent surfaces): szpdf, the assistant and MCP, all generated from
// spdf_paint_schema() and all ending in -[SPDFMacFillController applyOperation:tab:completion:], so a new operation
// appears on every surface at once and an agent's edit is undone with Cmd-Z like the person's own.
//
// - szpdf (SPDFMacSzpdfAnnotate.mm, in the szpdf process, and the reader's side of its channel, in the app):
//     szpdf canvas new [--width W] [--height H] [--background C] [--front]      -> the new tab's id
//     szpdf annotate <file|tab> <op> [--key value ...] | --json '{...}'          -> the operation's answer
//     szpdf annotate <file|tab> --script ops.json                               -> each answer; stops at an error
//     szpdf annotate <file|tab> state [--page N]
//     szpdf annotate schema [op]
//   Annotate is turned on for the tab if it is off; the window does not come forward.
// - The assistant (SPDFMacAIToolsAnnotate.mm): annotate_apply {target, ops: [...]}, annotate_state {target, page?},
//   annotate_look {target, page?, region?} (the picture goes back to the model), canvas_new {width, height,
//   background}. Its edits are listed in the chat.
// - MCP (shenzhen-pdf-mcp.py): annotate_apply, annotate_state, annotate_render, canvas_new, through the szpdf channel.
#import <Foundation/Foundation.h>

#import "SPDFMacAITools.h"
#import "SPDFMacDelegatePrivate.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - szpdf, in its own process (SPDFMacSzpdfAnnotate.mm)

// `szpdf annotate ...` and `szpdf canvas ...`, parsed as the other commands are (SPDFMacSzpdfArguments.mm); the exit
// status, after printing the answer (SPDFMacSzpdfFinish). The command's flags map to the operation's arguments by
// name (--keep-ratio and --keepRatio both give keepRatio; numbers, booleans and JSON values are read as the schema
// types them).
FOUNDATION_EXPORT int SPDFMacSzpdfAnnotate(NSDictionary* command);
FOUNDATION_EXPORT int SPDFMacSzpdfCanvas(NSDictionary* command);
// The two commands' rows for the command table behind help and `szpdf schema` (SPDFMacSzpdfCommandTable).
FOUNDATION_EXPORT NSArray<NSDictionary*>* SPDFMacSzpdfAnnotateCommandRows(void);

// Annotate's answer ({"ok":false,"error":code,"message":...}) in szpdf's shape ({"error":{"code","message"}}).
FOUNDATION_EXPORT NSDictionary* SPDFAnnotateAgentAnswer(NSDictionary* answer);
// What applyOperations answered, as `szpdf annotate --script` and annotate_apply print it: {"ok", "results" (each
// reshaped), "applied" (how many succeeded), and at the first failure "error" and "failedAt", "tab", "windowId"}.
FOUNDATION_EXPORT NSDictionary* SPDFAnnotateScriptAnswer(NSDictionary* answer);

#pragma mark - Tabs for agents (SPDFMacSzpdfAnnotate.mm)

// The tab's id for agents, "tab-<pid>-<n>": given the first time it is asked for, kept for the tab's life, never
// reused in the process. A never-saved canvas has no path, so this is how agents name it.
FOUNDATION_EXPORT NSString* _Nullable SPDFAnnotateTabIdentifier(SPDFDocumentTab* _Nullable tab);

@interface ShenzhenMacDelegate (SPDFMacAnnotateAgentTabs)
// This window's tab showing a document path, or with that tab id; nil when there is none.
- (nullable SPDFDocumentTab*)annotateAgentTabForTarget:(NSString*)target;
// ops through the window's controller (applyOperations:tab:completion:); the answer, once, with "tab", "windowId" and
// "path" added.
- (void)annotateAgentApply:(NSArray<NSDictionary*>*)ops tab:(SPDFDocumentTab*)tab
                     reply:(void (^)(NSDictionary* answer))reply;
// canvas.new {width?, height?, background?} through the controller; the answer with the new tab's "tab" and
// "windowId". front: the window comes forward; otherwise it is only shown, behind, when it was not visible.
- (void)annotateAgentNewCanvas:(NSDictionary*)arguments front:(BOOL)front
                         reply:(void (^)(NSDictionary* answer))reply;
@end

#pragma mark - The reader's side of the szpdf channel (SPDFMacSzpdfAnnotate.mm)

@interface ShenzhenMacDelegate (SPDFMacAnnotateAgentServer)
// Channel commands "annotate" {target, ops | op, script?} and "canvas-new" {width, height, background, front}:
// finds the reader showing the target (a path or a tab id) and answers through applyOperations:tab:completion:.
+ (void)agentAnnotate:(NSDictionary*)request readers:(NSArray<ShenzhenMacDelegate*>*)readers
                reply:(void (^)(NSDictionary* answer))reply;
+ (void)agentCanvasNew:(NSDictionary*)request readers:(NSArray<ShenzhenMacDelegate*>*)readers
                 reply:(void (^)(NSDictionary* answer))reply;
@end

#pragma mark - The assistant (SPDFMacAIToolsAnnotate.mm)

// annotate_apply, annotate_state, annotate_look and canvas_new, their input schemas built from spdf_paint_schema().
FOUNDATION_EXPORT NSArray<NSDictionary*>* SPDFMacAIAnnotateToolDefinitions(void);

@interface SPDFMacAITools (Annotate)
// YES when name is one of the Annotate tools (completion is then called once with the result); NO leaves it to the
// other tools.
- (BOOL)performAnnotateTool:(NSString*)name arguments:(NSDictionary*)arguments
                 completion:(void (^)(NSDictionary* result))completion;
// undo_action / redo_action on an annotate_apply action ({"annotate": ...} in actions): history.undo or history.redo
// of its steps on its tab, refused when the document changed since (SPDFMacAIToolsRedo.mm calls it).
- (void)swapAnnotateAction:(BOOL)redo completion:(void (^)(NSDictionary* result))completion;
@end

NS_ASSUME_NONNULL_END
