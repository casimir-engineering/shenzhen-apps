#import <Foundation/Foundation.h>

#import "../SPDFMacMarkdownKeyboardPolicy.h"

#include <assert.h>
#include <stdio.h>

int main(void) {
    @autoreleasepool {
        assert(spdf_mac_markdown_key_action(116, 0, NO, NO) == SPDFMacMarkdownKeyActionUnhandled);
        assert(spdf_mac_markdown_key_action(121, 0, NO, NO) == SPDFMacMarkdownKeyActionUnhandled);
        assert(spdf_mac_markdown_key_action(49, 0, NO, NO) == SPDFMacMarkdownKeyActionUnhandled);
        assert(spdf_mac_markdown_key_action(36, 0, NO, NO) == SPDFMacMarkdownKeyActionUnhandled);
        assert(spdf_mac_markdown_key_action(51, 0, NO, NO) == SPDFMacMarkdownKeyActionUnhandled);
        assert(spdf_mac_markdown_key_action(126, 0, NO, NO) == SPDFMacMarkdownKeyActionScrollUp);
        assert(spdf_mac_markdown_key_action(125, 0, NO, NO) == SPDFMacMarkdownKeyActionScrollDown);
        assert(spdf_mac_markdown_key_action(123, 0, NO, YES) == SPDFMacMarkdownKeyActionScrollLeft);
        assert(spdf_mac_markdown_key_action(124, 0, NO, YES) == SPDFMacMarkdownKeyActionScrollRight);
        assert(spdf_mac_markdown_key_action(123, 0, NO, NO) == SPDFMacMarkdownKeyActionPreviousPage);
        assert(spdf_mac_markdown_key_action(124, 0, NO, NO) == SPDFMacMarkdownKeyActionNextPage);

        assert(spdf_mac_markdown_key_action(123, NSEventModifierFlagCommand, NO, NO) ==
               SPDFMacMarkdownKeyActionPreviousTab);
        assert(spdf_mac_markdown_key_action(124, NSEventModifierFlagControl, NO, NO) ==
               SPDFMacMarkdownKeyActionNextTab);
        assert(spdf_mac_markdown_key_action(126, NSEventModifierFlagCommand, NO, NO) ==
               SPDFMacMarkdownKeyActionPreviousPage);
        assert(spdf_mac_markdown_key_action(124, NSEventModifierFlagOption, NO, YES) ==
               SPDFMacMarkdownKeyActionNextPage);

        assert(spdf_mac_markdown_key_action(53, 0, YES, NO) == SPDFMacMarkdownKeyActionExitPresentation);
        assert(spdf_mac_markdown_key_action(115, 0, YES, NO) == SPDFMacMarkdownKeyActionFirstPage);
        assert(spdf_mac_markdown_key_action(119, 0, YES, NO) == SPDFMacMarkdownKeyActionLastPage);
        assert(spdf_mac_markdown_key_action(49, 0, YES, NO) == SPDFMacMarkdownKeyActionNextPage);
        assert(spdf_mac_markdown_key_action(51, 0, YES, NO) == SPDFMacMarkdownKeyActionPreviousPage);
        puts("SPDFMacMarkdownKeyboardPolicyTests passed");
    }
    return 0;
}
