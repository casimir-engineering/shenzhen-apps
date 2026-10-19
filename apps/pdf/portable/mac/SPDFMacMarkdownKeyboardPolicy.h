#pragma once

#import <AppKit/AppKit.h>

typedef NS_ENUM(NSInteger, SPDFMacMarkdownKeyAction) {
    SPDFMacMarkdownKeyActionUnhandled = 0,
    SPDFMacMarkdownKeyActionEscape,
    SPDFMacMarkdownKeyActionExitPresentation,
    SPDFMacMarkdownKeyActionPreviousTab,
    SPDFMacMarkdownKeyActionNextTab,
    SPDFMacMarkdownKeyActionPreviousPage,
    SPDFMacMarkdownKeyActionNextPage,
    SPDFMacMarkdownKeyActionFirstPage,
    SPDFMacMarkdownKeyActionLastPage,
    SPDFMacMarkdownKeyActionScrollLeft,
    SPDFMacMarkdownKeyActionScrollRight,
    SPDFMacMarkdownKeyActionScrollUp,
    SPDFMacMarkdownKeyActionScrollDown,
};

SPDFMacMarkdownKeyAction spdf_mac_markdown_key_action(unsigned short keyCode, NSEventModifierFlags modifierFlags,
                                                      BOOL presentationMode, BOOL horizontallyScrollable);
