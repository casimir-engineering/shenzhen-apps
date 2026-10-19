// Copy Download Link in ShenzhenPDF's menus: File ▸ Share, a tab's menu, and the expiry choice behind both and behind
// the Friends drop panel's "Copy link instead" (portable/friends/PROTOCOL.md § Links, Copying a download link).
//
// AppKit only, no coordinator, so the menus are tested headlessly. The words are ShenzhenPDF's own, because the menus
// exist while no helper runs. Every item carries an identifier under "szfriends.", so the reader's assistant never
// lists or presses it (portable/friends/mac/SZFriendsHost.h, AI boundaries).

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString* const SPDFMacFriendsShareMenuTitle;           // "Share"
extern NSString* const SPDFMacFriendsCopyDownloadLinkTitle;    // "Copy Download Link"
extern NSString* const SPDFMacFriendsCopyLinkInsteadTitle;     // "Copy link instead"
extern NSString* const SPDFMacFriendsShareItemIdentifier;      // "szfriends.share"
extern NSString* const SPDFMacFriendsCopyLinkItemIdentifier;   // "szfriends.copy-download-link"

// The expiry choice, 7 days first because it is the default: "For 7 Days", "For 1 Day", "For 30 Days". Each item's
// tag is its number of days and its representedObject is `object` (the document it is for; nil: the active one).
NSMenu* SPDFMacFriendsExpiryMenu(id _Nullable target, SEL _Nullable action, id _Nullable object);
// "Copy Download Link" with the expiry choice as its submenu.
NSMenuItem* SPDFMacFriendsCopyDownloadLinkItem(id target, SEL action, id _Nullable object);
// File ▸ Share ▸ Copy Download Link, placed after Copy Path (or last). Returns the Share item, or nil when the menu
// already has one; never a second copy.
NSMenuItem* _Nullable SPDFMacFriendsInstallShareItem(NSMenu* fileMenu, id target, SEL action);
void SPDFMacFriendsRemoveShareItem(NSMenu* fileMenu);
// The days an expiry item stands for (1, 7 or 30), or 0 for anything else.
NSInteger SPDFMacFriendsExpiryDays(id _Nullable sender);

NS_ASSUME_NONNULL_END
