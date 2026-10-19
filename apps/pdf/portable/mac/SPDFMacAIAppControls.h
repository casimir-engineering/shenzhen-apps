#pragma once
#import <AppKit/AppKit.h>

// The assistant's app_controls tool, without the coordinator: listing the reader's menus and controls, and pressing
// or setting one the model picked from that list. ShenzhenMacDelegate (AIAppAccess) keeps the last list's targets.
//
// Some interface is never the assistant's to see or operate. Shenzhen Friends is one: without an `@` chip the
// assistant cannot see Friends at all (brief § AI boundaries), yet its button, dropdown rows, Settings section and
// confirmation alerts are ordinary buttons and fields. Any view, window or menu item whose identifier
// (NSUserInterfaceItemIdentification) starts with SPDFMacAIAppControlsHiddenPrefix is left out, with everything
// inside it, and cannot be operated even if it moves under such a view after the list was made.

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString* const SPDFMacAIAppControlsHiddenPrefix; // "szfriends."

// YES when `view`, one of its ancestors, or its window is hidden from the assistant.
BOOL SPDFMacAIAppControlsHidesView(NSView* _Nullable view);
// YES when the window's own identifier or its content view's carries the prefix (alerts, sheets, panels).
BOOL SPDFMacAIAppControlsHidesWindow(NSWindow* _Nullable window);
// YES when the item or a menu item above it carries the prefix.
BOOL SPDFMacAIAppControlsHidesMenuItem(NSMenuItem* _Nullable item);

// The inspect result ({"menus", "controls", "note"}) for `mainMenu` and the visible, unminiaturized `windows`.
// `targets` receives each listed row's id and the menu item or control it names.
NSDictionary* SPDFMacAIAppControlsInspect(NSMenu* _Nullable mainMenu, NSArray<NSWindow*>* windows,
                                          NSMutableDictionary* targets);

// "activate" or "set" (arguments: id, value) on a target from the last inspection.
NSDictionary* SPDFMacAIAppControlsOperate(NSString* operation, NSDictionary* arguments,
                                          NSDictionary* _Nullable targets);

NS_ASSUME_NONNULL_END
