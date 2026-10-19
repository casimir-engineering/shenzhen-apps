#pragma once
#import <Cocoa/Cocoa.h>
// Created only when chat is opened. The reader view and all its constraints stay intact.
@interface SPDFMacAIChatDock : NSObject <NSSplitViewDelegate>
@property(nonatomic,readonly) NSSplitView* split;
@property(nonatomic,copy) void (^resized)(CGFloat width);
- (instancetype)initWithReaderView:(NSView*)reader chatView:(NSView*)chat width:(CGFloat)width;
- (void)setVisible:(BOOL)visible;
@property(nonatomic,readonly) BOOL visible;
@end
