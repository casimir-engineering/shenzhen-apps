#pragma once
// One row of the Layers panel (SPDFMacAnnotateLayersPanel.h): thumbnail over a checkerboard, name, brush badge or
// lock, eye, and while selected the opacity slider with its percentage, which can be typed (SPDFMacAnnotateValueField.h).
#import <Cocoa/Cocoa.h>

#import "SPDFMacAnnotateValueField.h"
#include "spdf_paint.h"

NS_ASSUME_NONNULL_BEGIN

@interface SPDFAnnotateLayerRow : NSTableCellView
@property(nonatomic, strong) NSImageView* thumb;
@property(nonatomic, strong) NSTextField* name;
@property(nonatomic, strong) NSImageView* badge;
@property(nonatomic, strong) NSButton* eye;
@property(nonatomic, strong, nullable) NSSlider* opacity;  // made the first time the row shows it
@property(nonatomic, strong) SPDFAnnotateValueField* percent;
// A row laid out, its eye and slider sending these actions to target (their tag is the row).
+ (instancetype)rowWithTarget:(id)target eyeAction:(SEL)eyeAction opacityAction:(SEL)opacityAction;
// The opacity shown, slider and percentage, or hidden.
- (void)showOpacity:(double)percent visible:(BOOL)visible;
@end

// The panel's list: a click on a row's percentage edits it at once (a table otherwise waits, as for a rename).
@interface SPDFAnnotateLayerTable : NSTableView
@end

// A layer thumbnail's bitmap (2 pixels per point) as an image.
FOUNDATION_EXPORT NSImage* _Nullable SPDFAnnotateThumbnailImage(const spdf_bitmap* bitmap);

NS_ASSUME_NONNULL_END
