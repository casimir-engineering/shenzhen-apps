#pragma once
#import <Cocoa/Cocoa.h>
typedef NS_ENUM(NSInteger, SPDFMacAIChatPinMode) {
    SPDFMacAIChatPinNormal=0, SPDFMacAIChatPinApplication=1, SPDFMacAIChatPinAllApplications=2
};
// Constructed only when chat is explicitly opened. Never reads settings at launch.
@interface SPDFMacAIChatWindow : NSWindowController <NSWindowDelegate>
@property(nonatomic,readonly) SPDFMacAIChatPinMode pinMode;
@property(nonatomic,copy) void (^closed)(void);
@property(nonatomic,copy) void (^pinChanged)(NSInteger mode);
+ (NSURL*)defaultPreferencesURL;
- (instancetype)initWithContentView:(NSView*)view preferencesURL:(NSURL*)URL;
- (void)showRelativeToWindow:(NSWindow*)reader firstResponder:(NSResponder*)responder;
- (void)hide;
- (void)togglePinMode:(SPDFMacAIChatPinMode)mode;
- (void)setChatTitle:(NSString*)title;
@end
