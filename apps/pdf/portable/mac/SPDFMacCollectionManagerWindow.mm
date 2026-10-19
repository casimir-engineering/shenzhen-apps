#import "SPDFMacCollectionManagerWindow.h"
#import "SPDFMacCollectionWindowPrivate.h"
#import "SPDFMacCollectionWindowHistory.h"
@implementation SPDFCollectionManagerWindow
- (BOOL)performKeyEquivalent:(NSEvent*)event {
    NSEventModifierFlags flags=event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if ((flags & (NSEventModifierFlagCommand|NSEventModifierFlagControl|NSEventModifierFlagOption))==NSEventModifierFlagCommand &&
        [event.charactersIgnoringModifiers.lowercaseString isEqual:@"f"]) {
        SPDFMacCollectionWindow* manager=(SPDFMacCollectionWindow*)self.windowController;
        if ([manager.destination isEqual:@"History"]) [manager returnFromCollectionHistory:nil];
        else [manager showDestination:@"Documents"];
        [self makeFirstResponder:manager.search]; [manager.search selectText:nil];
        [manager persistManagerPreferences]; return YES;
    }
    return [super performKeyEquivalent:event];
}
@end
