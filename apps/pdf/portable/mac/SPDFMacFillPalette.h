#pragma once
// The Fill & Sign palette: a pill at the top of the page area with Text, check, cross, Signature and Done, the form's
// progress, and a one-line hint the first time a form is filled. It floats over the pages; nothing reflows.
#import <Cocoa/Cocoa.h>

@class SPDFMacFillController, SPDFFillSession;

@interface SPDFMacFillPalette : NSView
- (instancetype)initWithController:(SPDFMacFillController*)controller;
- (void)attachToContainer:(NSView*)container aboveView:(NSView*)view;
- (void)updateFromSession:(SPDFFillSession*)session progress:(NSString*)progress;
@end
