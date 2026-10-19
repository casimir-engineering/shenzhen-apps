#import "SPDFMacMarkdownKeyboardPolicy.h"

SPDFMacMarkdownKeyAction spdf_mac_markdown_key_action(unsigned short keyCode, NSEventModifierFlags modifierFlags,
                                                      BOOL presentationMode, BOOL horizontallyScrollable) {
    NSEventModifierFlags flags = modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    BOOL commandOrControl = (flags & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) != 0;
    BOOL option = (flags & NSEventModifierFlagOption) != 0;
    BOOL shift = (flags & NSEventModifierFlagShift) != 0;
    BOOL left = keyCode == 123;
    BOOL right = keyCode == 124;
    BOOL down = keyCode == 125;
    BOOL up = keyCode == 126;
    BOOL anyArrow = left || right || up || down;

    if (keyCode == 53)
        return presentationMode ? SPDFMacMarkdownKeyActionExitPresentation : SPDFMacMarkdownKeyActionEscape;
    if (commandOrControl && !option && anyArrow) {
        if (left) return SPDFMacMarkdownKeyActionPreviousTab;
        if (right) return SPDFMacMarkdownKeyActionNextTab;
        return up ? SPDFMacMarkdownKeyActionPreviousPage : SPDFMacMarkdownKeyActionNextPage;
    }
    if (option && !commandOrControl && (left || right))
        return left ? SPDFMacMarkdownKeyActionPreviousPage : SPDFMacMarkdownKeyActionNextPage;
    if (flags & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption))
        return SPDFMacMarkdownKeyActionUnhandled;

    if (presentationMode) {
        if (keyCode == 115) return SPDFMacMarkdownKeyActionFirstPage;
        if (keyCode == 119) return SPDFMacMarkdownKeyActionLastPage;
        if (keyCode == 49 || keyCode == 36 || keyCode == 76) return SPDFMacMarkdownKeyActionNextPage;
        if (keyCode == 51) return SPDFMacMarkdownKeyActionPreviousPage;
        if (left || up || keyCode == 116) return SPDFMacMarkdownKeyActionPreviousPage;
        if (right || down || keyCode == 121) return SPDFMacMarkdownKeyActionNextPage;
    }
    if (shift && anyArrow) return left || up ? SPDFMacMarkdownKeyActionPreviousPage : SPDFMacMarkdownKeyActionNextPage;
    if (left || right) {
        if (!horizontallyScrollable)
            return left ? SPDFMacMarkdownKeyActionPreviousPage : SPDFMacMarkdownKeyActionNextPage;
        return left ? SPDFMacMarkdownKeyActionScrollLeft : SPDFMacMarkdownKeyActionScrollRight;
    }
    if (up || down) return up ? SPDFMacMarkdownKeyActionScrollUp : SPDFMacMarkdownKeyActionScrollDown;
    return SPDFMacMarkdownKeyActionUnhandled;
}
