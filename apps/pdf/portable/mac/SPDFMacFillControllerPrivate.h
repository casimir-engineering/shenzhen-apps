#pragma once
// State the controller's categories share (SPDFMacFillController+Edits.mm, +Interaction.mm, +Focus.mm).
#import "SPDFMacFillController.h"

@class SPDFMacSignature;

@interface SPDFMacFillController ()
@property(nonatomic, strong, readwrite) SPDFMacFillOverlayView* overlay;
@property(nonatomic, strong, readwrite) SPDFMacFillPalette* palette;
@property(nonatomic, strong, readwrite) SPDFMacFillEditor* editor;
@property(nonatomic) BOOL busy;  // a change is being written: re-entrant flushes wait
// Signatures placed in this window, so undoing the removal of a signature kept only once can put it back.
@property(nonatomic, strong, readonly) NSMutableDictionary<NSString*, SPDFMacSignature*>* usedSignatures;
@end

@interface SPDFMacFillController (InteractionShared)
- (SPDFFillField*)fieldAt:(NSPoint)p page:(NSInteger)page;
- (void)activateField:(SPDFFillField*)field;
- (void)openEditorForNewTextOnPage:(NSInteger)page snap:(const spdf_snap_result*)snap;
@end
