#pragma once
// A number shown as a label beside a slider ("5 px", "80 %") that edits in place when clicked: the number shows
// selected, ready to type over. Up and Down step it by 1 (Shift: 10) at once; Return or a click elsewhere ends the
// editing and uses the number typed, Escape puts back the value it had. Return and Escape give the keys back to
// `keysView` (the canvas, so the tools' keys work again). Annotate's palette sliders and the Layers panel's opacity.
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface SPDFAnnotateValueField : NSTextField
// A field drawn as a small label in the palette's text colour.
+ (instancetype)valueFieldWithFontSize:(CGFloat)size tip:(NSString*)tip;
// Up or Down while editing: the value proposed (the one typed, stepped); shows it (the slider follows) and answers the
// number to show in the field, kept within range.
@property(nonatomic, copy, nullable) double (^stepped)(double proposed);
// The editing ended: `ok` with the number typed; NO (Escape, or no number) with the value it had before.
@property(nonatomic, copy, nullable) void (^ended)(double value, BOOL ok);
@property(nonatomic, copy, nullable) NSView* _Nullable (^keysView)(void);
@property(nonatomic, readonly) BOOL editing;  // being typed in (`ended` is called once it no longer is)
@end

NS_ASSUME_NONNULL_END
