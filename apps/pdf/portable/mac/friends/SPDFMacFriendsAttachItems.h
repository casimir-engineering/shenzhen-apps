// The `#` picker's items in ShenzhenPDF: open documents first, then Collection documents (brief § Interface, `#`).
//
// Each item is bound to an exact revision when it is listed, because selecting it inserts a chip that must send
// those bytes and no others (PROTOCOL.md § Intents, Files). Open documents bind the bytes on screen, through
// the same rules as a dragged tab. Collection documents bind their latest saved version: the original file when
// it still holds that version's size, otherwise the version's own archive copy, so a later edit of the original
// never changes what the chip sends. Matching is a case- and diacritic-insensitive substring of the title or
// file name, like the reader's Cmd+K open-document rows. Runs on a background queue; it reads and hashes files.

#import <Foundation/Foundation.h>
#import "SPDFMacFriendsRevision.h"

@class SZFriendsAttachableItem;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT const NSUInteger SPDFMacFriendsAttachItemLimit; // 30: one screen of the picker and some scrolling

// One open document: path (as the tab knows it), title, readOnly/workingPath (tab dictionary keys), and
// "inThisWindow" (@YES for this process's own tabs, @NO for tabs another window's process listed in session.yaml),
// and "current" (@YES for the tab on screen, which carries SPDFMacFriendsAttachCurrentBadge in the picker). Pass them
// most recently focused first, the tab on screen first of all.
NSArray<SZFriendsAttachableItem*>* SPDFMacFriendsAttachItems(NSString* query, NSArray<NSDictionary*>* openDocuments,
                                                            id<SPDFMacFriendsCollectionLookup> _Nullable lookup,
                                                            NSDate* now);

// The picker's search placeholder: the one `#` string the host supplies (PROTOCOL.md § Principles).
FOUNDATION_EXPORT NSString* const SPDFMacFriendsAttachPlaceholder;
// The pill on the tab on screen, which the picker lists first: "Current".
FOUNDATION_EXPORT NSString* const SPDFMacFriendsAttachCurrentBadge;

NS_ASSUME_NONNULL_END
