#import "SPDFMacWindowShortcuts.h"

static SPDFWindowArrangementShortcut spdf_window_arrangement_shortcut_for_arrow_key(unsigned short keyCode) {
    switch (keyCode) {
        case 123:
        case 115:
            return SPDFWindowArrangementShortcutLeftHalf;
        case 124:
        case 119:
            return SPDFWindowArrangementShortcutRightHalf;
        case 126:
        case 116:
            return SPDFWindowArrangementShortcutTopHalf;
        case 125:
        case 121:
            return SPDFWindowArrangementShortcutBottomHalf;
        default:
            return SPDFWindowArrangementShortcutNone;
    }
}

static SPDFWindowArrangementShortcut spdf_window_arrangement_shortcut_for_character(unichar key) {
    if (key == 'f' || key == 'F') return SPDFWindowArrangementShortcutFill;
    if (key == 'c' || key == 'C') return SPDFWindowArrangementShortcutCenter;

    if (key == NSLeftArrowFunctionKey) return SPDFWindowArrangementShortcutLeftHalf;
    if (key == NSRightArrowFunctionKey) return SPDFWindowArrangementShortcutRightHalf;
    if (key == NSUpArrowFunctionKey) return SPDFWindowArrangementShortcutTopHalf;
    if (key == NSDownArrowFunctionKey) return SPDFWindowArrangementShortcutBottomHalf;
    if (key == NSHomeFunctionKey) return SPDFWindowArrangementShortcutLeftHalf;
    if (key == NSEndFunctionKey) return SPDFWindowArrangementShortcutRightHalf;
    if (key == NSPageUpFunctionKey) return SPDFWindowArrangementShortcutTopHalf;
    if (key == NSPageDownFunctionKey) return SPDFWindowArrangementShortcutBottomHalf;
    return SPDFWindowArrangementShortcutNone;
}

SPDFWindowArrangementShortcut spdf_window_arrangement_shortcut_for_event_fields(NSEventModifierFlags modifierFlags,
                                                                                unsigned short keyCode,
                                                                                NSString* charactersIgnoringModifiers,
                                                                                NSString* characters) {
    NSEventModifierFlags flags = modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if ((flags & NSEventModifierFlagControl) == 0) return SPDFWindowArrangementShortcutNone;
    if (flags & (NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagShift))
        return SPDFWindowArrangementShortcutNone;

    NSString* text = charactersIgnoringModifiers.length ? charactersIgnoringModifiers : (characters ?: @"");
    if (text.length > 0) {
        SPDFWindowArrangementShortcut shortcut =
            spdf_window_arrangement_shortcut_for_character([text characterAtIndex:0]);
        if (shortcut != SPDFWindowArrangementShortcutNone) return shortcut;
    }

    return spdf_window_arrangement_shortcut_for_arrow_key(keyCode);
}

SPDFWindowArrangementShortcut spdf_window_arrangement_shortcut_for_event(NSEvent* event) {
    if (!event || event.type != NSEventTypeKeyDown) return SPDFWindowArrangementShortcutNone;
    return spdf_window_arrangement_shortcut_for_event_fields(event.modifierFlags, event.keyCode,
                                                             event.charactersIgnoringModifiers, event.characters);
}

SEL spdf_window_arrangement_selector_for_shortcut(SPDFWindowArrangementShortcut shortcut) {
    switch (shortcut) {
        case SPDFWindowArrangementShortcutFill:
            return @selector(fillWindow:);
        case SPDFWindowArrangementShortcutCenter:
            return @selector(centerWindowInScreen:);
        case SPDFWindowArrangementShortcutLeftHalf:
            return @selector(moveWindowToLeftHalf:);
        case SPDFWindowArrangementShortcutRightHalf:
            return @selector(moveWindowToRightHalf:);
        case SPDFWindowArrangementShortcutTopHalf:
            return @selector(moveWindowToTopHalf:);
        case SPDFWindowArrangementShortcutBottomHalf:
            return @selector(moveWindowToBottomHalf:);
        case SPDFWindowArrangementShortcutNone:
            return NULL;
    }
    return NULL;
}
