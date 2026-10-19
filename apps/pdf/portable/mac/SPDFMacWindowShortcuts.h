#import <Cocoa/Cocoa.h>

typedef NS_ENUM(NSInteger, SPDFWindowArrangementShortcut) {
    SPDFWindowArrangementShortcutNone = 0,
    SPDFWindowArrangementShortcutFill,
    SPDFWindowArrangementShortcutCenter,
    SPDFWindowArrangementShortcutLeftHalf,
    SPDFWindowArrangementShortcutRightHalf,
    SPDFWindowArrangementShortcutTopHalf,
    SPDFWindowArrangementShortcutBottomHalf,
};

SPDFWindowArrangementShortcut spdf_window_arrangement_shortcut_for_event_fields(NSEventModifierFlags modifierFlags,
                                                                                unsigned short keyCode,
                                                                                NSString* charactersIgnoringModifiers,
                                                                                NSString* characters);
SPDFWindowArrangementShortcut spdf_window_arrangement_shortcut_for_event(NSEvent* event);
SEL spdf_window_arrangement_selector_for_shortcut(SPDFWindowArrangementShortcut shortcut);
