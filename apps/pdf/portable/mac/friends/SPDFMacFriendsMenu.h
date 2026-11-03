// View ▸ Friends: the menu that carries Cmd+; and the commands Cmd+K finds for Friends.
//
// Added when Friends attaches (after the first paint) and removed when it detaches, like File ▸ Share, so nothing
// about Friends is in the menu bar or the palette while it is off. Cmd+; is free in the reader: its menus have no
// Spelling and Grammar items, and its text views bind nothing to it (Cmd+J, which Friends had first, is Add Comment…).
// The key equivalent is the character, so AppKit's automatic shortcut localization finds the key for it on layouts
// where ";" is elsewhere. The Windows and Linux readers have no Friends yet and so no Cmd+; / Ctrl+;. The palette
// lists these items as it lists every menu item, and finds them by the words in spdf_palette_menu_command_keywords()
// (SPDFMacPaletteResults.h) too.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString* const SPDFMacFriendsMenuTitle;           // "Friends (Beta)"
FOUNDATION_EXPORT NSString* const SPDFMacFriendsOpenTitle;           // "Open Friends"
FOUNDATION_EXPORT NSString* const SPDFMacFriendsCloseTitle;          // "Close Friends", while the dropdown is open
FOUNDATION_EXPORT NSString* const SPDFMacFriendsAddByIDTitle;        // "Add by ID…"
FOUNDATION_EXPORT NSString* const SPDFMacFriendsVisibleTitle;        // "Make Myself Visible"
FOUNDATION_EXPORT NSString* const SPDFMacFriendsSettingsTitle;       // "Friends Settings…"
// The key equivalent of Open Friends, and the tooltip suffix the title-bar button gets (" · ⌘;").
FOUNDATION_EXPORT NSString* const SPDFMacFriendsShortcutKey;         // ";"
FOUNDATION_EXPORT NSString* const SPDFMacFriendsShortcutToolTipSuffix;

// Item identifiers; the palette's keyword table is keyed by them.
FOUNDATION_EXPORT NSString* const SPDFMacFriendsMenuItemIdentifier;      // the View ▸ Friends submenu item
FOUNDATION_EXPORT NSString* const SPDFMacFriendsMenuSeparatorIdentifier; // the separator above it
FOUNDATION_EXPORT NSString* const SPDFMacFriendsOpenItemIdentifier;
FOUNDATION_EXPORT NSString* const SPDFMacFriendsAddByIDItemIdentifier;
FOUNDATION_EXPORT NSString* const SPDFMacFriendsVisibleItemIdentifier;
FOUNDATION_EXPORT NSString* const SPDFMacFriendsSettingsItemIdentifier;

// The actions the items send to `target`.
@protocol SPDFMacFriendsMenuActions <NSObject>
- (void)toggleFriends:(nullable id)sender;
- (void)addFriendByID:(nullable id)sender;
- (void)makeVisibleNearby:(nullable id)sender;
- (void)showFriendsSettings:(nullable id)sender;
@end

// Adds a separator and the Friends submenu at the end of `viewMenu`, every item aimed at `target` (held weakly by
// the items, so the caller keeps it). Returns the submenu item, or nil when one is already there.
NSMenuItem* _Nullable SPDFMacFriendsInstallMenu(NSMenu* viewMenu, id<SPDFMacFriendsMenuActions> target);
// Removes what SPDFMacFriendsInstallMenu added.
void SPDFMacFriendsRemoveMenu(NSMenu* viewMenu);
// `toolTip` with the shortcut after it, as the Search button shows ⌘K; unchanged when empty or already carrying it.
NSString* _Nullable SPDFMacFriendsToolTipWithShortcut(NSString* _Nullable toolTip);

NS_ASSUME_NONNULL_END
