#import "SPDFMacPasteboardOwnership.h"
#import <objc/runtime.h>

// Every write to a pasteboard starts with -clearContents or -declareTypes:owner:, and each raises its change count.
// The count right after this process last wrote the general pasteboard: when it is still the count at quit, nothing
// wrote since and the pasteboard may hold data this process promised (an NSImage's converted types, say).
static NSInteger gOwnedGeneralChangeCount = -1;
static IMP gClearContents, gDeclareTypes;
static void NoteWrite(NSPasteboard* pasteboard) {
    if ([pasteboard.name isEqualToString:NSPasteboardNameGeneral]) gOwnedGeneralChangeCount = pasteboard.changeCount;
}
static NSInteger ClearContents(NSPasteboard* self, SEL sel) {
    NSInteger count = ((NSInteger(*)(id, SEL))gClearContents)(self, sel);
    NoteWrite(self);
    return count;
}
static NSInteger DeclareTypes(NSPasteboard* self, SEL sel, NSArray* types, id owner) {
    NSInteger count = ((NSInteger(*)(id, SEL, id, id))gDeclareTypes)(self, sel, types, owner);
    NoteWrite(self);
    return count;
}
@implementation NSPasteboard (SPDFMacPasteboardOwnership)
+ (void)load {
    gClearContents = method_setImplementation(class_getInstanceMethod(self, @selector(clearContents)), (IMP)ClearContents);
    gDeclareTypes = method_setImplementation(class_getInstanceMethod(self, @selector(declareTypes:owner:)),
                                             (IMP)DeclareTypes);
}
@end
BOOL spdf_mac_general_pasteboard_may_hold_our_data(void) {
    return gOwnedGeneralChangeCount >= 0 && NSPasteboard.generalPasteboard.changeCount == gOwnedGeneralChangeCount;
}
