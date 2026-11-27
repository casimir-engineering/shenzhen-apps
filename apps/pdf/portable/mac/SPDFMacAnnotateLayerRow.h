#pragma once
// One row of the Layers panel (SPDFMacAnnotateLayersPanel.h). A layer's row: the disclosure triangle that shows or
// hides its objects, thumbnail over a checkerboard, name over how many objects it holds, the brush badge on the active
// layer, lock and eye, and while selected the opacity slider with its percentage, which can be typed
// (SPDFMacAnnotateValueField.h). An object's row, indented under its layer: thumbnail, name and eye.
#import <Cocoa/Cocoa.h>

#import "SPDFMacAnnotateValueField.h"
#include "spdf_paint.h"

NS_ASSUME_NONNULL_BEGIN

// A name that reads as a label and is typed over after a double-click: Return or a click elsewhere renames, Escape
// leaves it as it was.
@interface SPDFAnnotateNameField : NSTextField
@property(nonatomic, copy, nullable) void (^renamed)(NSString* name);
@property(nonatomic, copy, nullable) NSView* _Nullable (^keysView)(void);
- (void)beginRenaming;
@end

@interface SPDFAnnotateLayerRow : NSTableCellView
@property(nonatomic, strong) NSImageView* thumb;
@property(nonatomic, strong) SPDFAnnotateNameField* name;
@property(nonatomic, strong) NSTextField* detail;  // "3 objects" under a layer's name
@property(nonatomic, strong) NSImageView* badge;
@property(nonatomic, strong) NSButton* disclosure;
@property(nonatomic, strong) NSButton* lock;
@property(nonatomic, strong) NSLayoutConstraint* lockWidth;  // 0 where there is no lock (the base layer)
@property(nonatomic, strong) NSButton* eye;
@property(nonatomic, strong, nullable) NSSlider* opacity;  // made the first time the row shows it
@property(nonatomic, strong) SPDFAnnotateValueField* percent;
// A row laid out (a layer's, or an object's indented under it), its buttons and slider sending these actions to
// target (their tag is the row).
+ (instancetype)rowWithTarget:(id)target object:(BOOL)object eyeAction:(SEL)eyeAction lockAction:(SEL)lockAction
                 discloseAction:(SEL)discloseAction opacityAction:(SEL)opacityAction;
// The opacity shown, slider and percentage, or hidden.
- (void)showOpacity:(double)percent visible:(BOOL)visible;
@end

// The panel's list: a click on a row's percentage edits it at once (a table otherwise waits, as for a rename).
@interface SPDFAnnotateLayerTable : NSTableView
@end

// A layer thumbnail's bitmap (2 pixels per point) as an image.
FOUNDATION_EXPORT NSImage* _Nullable SPDFAnnotateThumbnailImage(const spdf_bitmap* bitmap);

NS_ASSUME_NONNULL_END
