#pragma once
// A context-menu item that acts the moment the mouse button comes up on it. A native item, once chosen, blinks
// (AppKit keeps it unhighlighted 34 ms, then highlighted 67 ms) and its menu fades out before the action is sent; this
// one closes its menu without animation and sends the action at once, so what it opens is on screen in the next frame.
//
// It draws its own NSMenuItem as macOS 26 draws a context menu's items: the image in the image column, the title in
// the menu font, the key equivalent in the trailing column, and, when highlighted, the system's capsule in the accent
// colour with the text in the selected-menu-item colour. Title, image, key equivalent, target, action and enabled
// state stay the item's own and can change after it is made instant. Return on a highlighted item, VoiceOver and
// keyboard navigation work as for any menu item with a view. Before macOS 26 the item is left native.
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// Gives `item` the instant behaviour (macOS 26 and later). Returns whether it did.
BOOL SPDFMacMakeMenuItemInstant(NSMenuItem* item);

// Where a highlighted row's capsule goes in a row of `bounds`: the native inset and radius. Pure, for tests.
NSRect SPDFMacInstantMenuItemHighlightRect(NSRect bounds);

NS_ASSUME_NONNULL_END
