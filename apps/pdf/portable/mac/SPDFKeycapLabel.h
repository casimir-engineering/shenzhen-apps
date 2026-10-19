#import <Cocoa/Cocoa.h>

// Label used for the key caps in the keyboard-shortcut help panel. Unlike a
// plain NSTextField label, it vertically centers its single line of text when
// the field is taller than the text (the caps are fixed at 22pt tall).
@interface SPDFKeycapLabel : NSTextField
@end
