#import <Cocoa/Cocoa.h>

#import "../SPDFMacWindowShortcuts.h"

static int gFailureCount = 0;

static void expect_shortcut(NSString* label,
                            SPDFWindowArrangementShortcut expected,
                            NSEventModifierFlags flags,
                            unsigned short keyCode,
                            NSString* charactersIgnoringModifiers) {
    SPDFWindowArrangementShortcut actual = spdf_window_arrangement_shortcut_for_event_fields(
        flags, keyCode, charactersIgnoringModifiers, charactersIgnoringModifiers);
    if (actual != expected) {
        fprintf(stderr, "FAIL %s: expected %ld, got %ld\n", label.UTF8String, (long)expected, (long)actual);
        ++gFailureCount;
    }
}

static void expect_selector(NSString* label, SPDFWindowArrangementShortcut shortcut, SEL expected) {
    SEL actual = spdf_window_arrangement_selector_for_shortcut(shortcut);
    if (actual != expected) {
        fprintf(stderr, "FAIL %s: expected %s, got %s\n", label.UTF8String, expected ? sel_getName(expected) : "NULL",
                actual ? sel_getName(actual) : "NULL");
        ++gFailureCount;
    }
}

int main(int argc, char** argv) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        NSEventModifierFlags controlFunction = NSEventModifierFlagControl | NSEventModifierFlagFunction;
        NSEventModifierFlags controlNumericPad = NSEventModifierFlagControl | NSEventModifierFlagNumericPad;
        expect_shortcut(@"control+function+f", SPDFWindowArrangementShortcutFill, controlFunction, 3, @"f");
        expect_shortcut(@"control+function+c", SPDFWindowArrangementShortcutCenter, controlFunction, 8, @"c");
        expect_shortcut(@"control+function+left char", SPDFWindowArrangementShortcutLeftHalf, controlFunction, 123,
                        [NSString stringWithFormat:@"%C", (unichar)NSLeftArrowFunctionKey]);
        expect_shortcut(@"control+function+right char", SPDFWindowArrangementShortcutRightHalf, controlFunction, 124,
                        [NSString stringWithFormat:@"%C", (unichar)NSRightArrowFunctionKey]);
        expect_shortcut(@"control+function+up char", SPDFWindowArrangementShortcutTopHalf, controlFunction, 126,
                        [NSString stringWithFormat:@"%C", (unichar)NSUpArrowFunctionKey]);
        expect_shortcut(@"control+function+down char", SPDFWindowArrangementShortcutBottomHalf, controlFunction, 125,
                        [NSString stringWithFormat:@"%C", (unichar)NSDownArrowFunctionKey]);
        expect_shortcut(@"control+function+home char", SPDFWindowArrangementShortcutLeftHalf, controlFunction, 115,
                        [NSString stringWithFormat:@"%C", (unichar)NSHomeFunctionKey]);
        expect_shortcut(@"control+function+end char", SPDFWindowArrangementShortcutRightHalf, controlFunction, 119,
                        [NSString stringWithFormat:@"%C", (unichar)NSEndFunctionKey]);
        expect_shortcut(@"control+function+page-up char", SPDFWindowArrangementShortcutTopHalf, controlFunction, 116,
                        [NSString stringWithFormat:@"%C", (unichar)NSPageUpFunctionKey]);
        expect_shortcut(@"control+function+page-down char", SPDFWindowArrangementShortcutBottomHalf, controlFunction,
                        121, [NSString stringWithFormat:@"%C", (unichar)NSPageDownFunctionKey]);

        expect_shortcut(@"control+numpad+left keycode", SPDFWindowArrangementShortcutLeftHalf, controlNumericPad, 123,
                        @"");
        expect_shortcut(@"control+numpad+right keycode", SPDFWindowArrangementShortcutRightHalf, controlNumericPad, 124,
                        @"");
        expect_shortcut(@"control+numpad+up keycode", SPDFWindowArrangementShortcutTopHalf, controlNumericPad, 126,
                        @"");
        expect_shortcut(@"control+numpad+down keycode", SPDFWindowArrangementShortcutBottomHalf, controlNumericPad, 125,
                        @"");

        expect_shortcut(@"control+left fallback keycode", SPDFWindowArrangementShortcutLeftHalf,
                        NSEventModifierFlagControl, 123, @"");
        expect_shortcut(@"control+home fallback keycode", SPDFWindowArrangementShortcutLeftHalf,
                        NSEventModifierFlagControl, 115, @"");
        expect_shortcut(@"control+end fallback keycode", SPDFWindowArrangementShortcutRightHalf,
                        NSEventModifierFlagControl, 119, @"");
        expect_shortcut(@"control+page-up fallback keycode", SPDFWindowArrangementShortcutTopHalf,
                        NSEventModifierFlagControl, 116, @"");
        expect_shortcut(@"control+page-down fallback keycode", SPDFWindowArrangementShortcutBottomHalf,
                        NSEventModifierFlagControl, 121, @"");
        expect_shortcut(@"control+f fallback outside text input", SPDFWindowArrangementShortcutFill,
                        NSEventModifierFlagControl, 3, @"f");
        expect_shortcut(@"command modifier rejects window shortcut", SPDFWindowArrangementShortcutNone,
                        controlFunction | NSEventModifierFlagCommand, 3, @"f");
        expect_shortcut(@"option modifier rejects window shortcut", SPDFWindowArrangementShortcutNone,
                        controlFunction | NSEventModifierFlagOption, 3, @"f");
        expect_shortcut(@"shift modifier rejects window shortcut", SPDFWindowArrangementShortcutNone,
                        controlFunction | NSEventModifierFlagShift, 3, @"f");

        expect_selector(@"fill selector", SPDFWindowArrangementShortcutFill, @selector(fillWindow:));
        expect_selector(@"center selector", SPDFWindowArrangementShortcutCenter, @selector(centerWindowInScreen:));
        expect_selector(@"left selector", SPDFWindowArrangementShortcutLeftHalf, @selector(moveWindowToLeftHalf:));
        expect_selector(@"right selector", SPDFWindowArrangementShortcutRightHalf, @selector(moveWindowToRightHalf:));
        expect_selector(@"top selector", SPDFWindowArrangementShortcutTopHalf, @selector(moveWindowToTopHalf:));
        expect_selector(@"bottom selector", SPDFWindowArrangementShortcutBottomHalf,
                        @selector(moveWindowToBottomHalf:));
        expect_selector(@"none selector", SPDFWindowArrangementShortcutNone, NULL);
    }
    if (gFailureCount > 0) return 1;
    printf("SPDFMacWindowShortcutsTests passed\n");
    return 0;
}
