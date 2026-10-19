#pragma once
#import <Cocoa/Cocoa.h>
NSViewController* SPDFGroupNamePromptContent(NSString* defaultName, BOOL creating, void (^accept)(NSString*));
void SPDFPresentGroupNamePrompt(NSView* anchor, NSRect rect, NSString* defaultName, BOOL creating, void (^accept)(NSString*));
